class_name HarvesterController
extends RefCounted

## The resource-unit loop: drive to a spice field, eat it, drive to a refinery,
## unload, repeat. Attached to a Unit whose definition has a spice capacity.
##
## Two state machines run side by side -- harvest and unload -- plus the cycle
## driver that closes the loop between them and the pending-order queue that
## lets an animation finish before a new player order takes effect.
##
## Holds no model nodes: the authored clips are played through the unit, which
## owns the AnimationPlayers.

const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")

const HARVEST_START_ANIMATION := &"Harv_Eat_Start"
const HARVEST_HOLD_ANIMATION := &"Harv_Eat_Hold"
const HARVEST_END_ANIMATION := &"Harv_Eat_End"
const UNLOAD_START_ANIMATION := &"Harv_Unload_Start"
const UNLOAD_HOLD_ANIMATION := &"Harv_Unload_Hold"
const UNLOAD_END_ANIMATION := &"Harv_Unload_End"
const HARVEST_HOLD_SECONDS := 0.3
const HARVEST_CARGO_FRACTION_PER_CYCLE := 0.2
const HARVEST_APPROACH_RADIUS_CELLS := 2.0
const UNLOAD_UPDATES_PER_SECOND := 20.0
const ORIGINAL_UNLOAD_RATE_PER_UPDATE := 2.0
const UNLOAD_HOLD_FALLBACK_SECONDS := 0.05
const AUTO_SEARCH_RETRY_SECONDS := 1.0
const INVALID_DOCK := -1

enum HarvestPhase { NONE, TRAVEL, START, HOLD, END }
enum UnloadPhase { NONE, APPROACH, WAIT_DOCK, PARK, START, HOLD, END, RETURN_FRONT }
enum PendingOrder { NONE, MOVE, HARVEST, UNLOAD }

var _unit: CharacterBody3D
var unload_rate_per_update := ORIGINAL_UNLOAD_RATE_PER_UPDATE
var _harvest_phase := HarvestPhase.NONE
var _harvest_phase_remaining := 0.0
var _harvest_spice_layer = null
var _harvest_grid = null
var _harvest_target_cell := Vector2i(-1, -1)
var _harvest_exit_refinery: Node = null
var _harvest_exit_grid = null
var _issuing_harvest_move := false
var _unload_phase := UnloadPhase.NONE
var _unload_phase_remaining := 0.0
var _unload_refinery: Node = null
var _unload_grid = null
var _unload_dock := INVALID_DOCK
var _unload_interrupted := false
var _unload_credit_accumulator := 0.0
var _issuing_unload_move := false
var _issuing_main_base_move := false
var _pending_order := PendingOrder.NONE
var _pending_order_data: Dictionary = {}
var _harvest_cycle_enabled := false
var _cycle_spice_layer = null
var _cycle_grid = null
var _assigned_refinery: Node = null
var _return_main_base: Node3D = null
var _auto_spice_cell_filter := Callable()
var _auto_search_cooldown := 0.0


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func dispose() -> void:
	_unit = null


## Both machines advance every simulation tick, then the cycle driver closes
## the loop between them; that order is what lets a finished harvest hand
## straight over to the trip home within the same tick.
func advance(delta: float) -> void:
	advance_harvest_order(delta)
	advance_unload_order(delta)
	advance_harvest_cycle(delta)


func prepare_navigation_order(
		world_position: Vector3, exit_point := Vector3.INF, move_mode := 0
	) -> bool:
	if _issuing_harvest_move or _issuing_unload_move or _issuing_main_base_move:
		return true
	_harvest_cycle_enabled = false
	_return_main_base = null
	if _is_unload_animating():
		_queue_pending_order(PendingOrder.MOVE, {
			"position": world_position,
			"exit_point": exit_point,
			"move_mode": move_mode,
		})
		_interrupt_unload_animation()
		return false
	_cancel_unload_immediately()
	cancel_harvest_order()
	return true


## Registering with the navigation system re-issues whatever order was pending,
## which comes back through prepare_navigation_order. Marking the handoff keeps
## that re-issue from being mistaken for a new player order and cancelling the
## very trip it is restoring.
func begin_navigation_handoff() -> void:
	_issuing_harvest_move = has_harvest_order()
	_issuing_unload_move = has_unload_order()
	_issuing_main_base_move = _return_main_base != null


func end_navigation_handoff() -> void:
	_issuing_harvest_move = false
	_issuing_unload_move = false
	_issuing_main_base_move = false


func can_harvest_spice() -> bool:
	return _unit.max_spice > 0.0


func command_harvest(spice_layer, navigation_grid, cell: Vector2i) -> bool:
	if not can_harvest_spice() or spice_layer == null or navigation_grid == null:
		return false
	_enable_harvest_cycle(spice_layer, navigation_grid)
	if _is_unload_animating():
		_queue_pending_order(PendingOrder.HARVEST, {
			"spice_layer": spice_layer,
			"grid": navigation_grid,
			"cell": cell,
		})
		_interrupt_unload_animation()
		return true
	_cancel_unload_immediately()
	if _unit.spice >= _unit.max_spice:
		advance_harvest_cycle()
		return true
	_start_harvest_order(spice_layer, navigation_grid, cell)
	return true


func _start_harvest_order(
		spice_layer, navigation_grid, cell: Vector2i,
		exit_refinery: Node = null, exit_grid = null
	) -> void:
	cancel_harvest_order()
	_harvest_spice_layer = spice_layer
	_harvest_grid = navigation_grid
	_harvest_target_cell = cell
	_harvest_exit_refinery = exit_refinery
	_harvest_exit_grid = exit_grid
	_harvest_phase = HarvestPhase.TRAVEL
	_move_to_harvest_cell(cell)


func can_unload_at(refinery: Node) -> bool:
	return _is_valid_owned_refinery(refinery)


func command_unload(refinery: Node, navigation_grid, spice_layer = null) -> bool:
	if navigation_grid == null or not can_unload_at(refinery):
		return false
	_assigned_refinery = refinery
	_return_main_base = null
	if spice_layer != null:
		_enable_harvest_cycle(spice_layer, navigation_grid)
	if _is_unload_animating():
		_queue_pending_order(PendingOrder.UNLOAD, {
			"refinery": refinery,
			"grid": navigation_grid,
		})
		_interrupt_unload_animation()
		return true
	cancel_harvest_order()
	_cancel_unload_immediately()
	_start_unload_order(refinery, navigation_grid)
	return true


## A manual unload order and every later automatic trip use this refinery
## until it is destroyed, captured, or explicitly replaced by another manual
## unload order.
func assigned_refinery() -> Node:
	if not _is_valid_owned_refinery(_assigned_refinery):
		_assigned_refinery = null
	return _assigned_refinery


## The future fog-of-war layer can install a player-specific predicate here.
## Explicitly clicked harvest cells remain valid manual targets; the predicate
## applies only when the harvester autonomously chooses its next field.
func set_auto_spice_cell_filter(candidate_filter: Callable) -> void:
	_auto_spice_cell_filter = candidate_filter
	_auto_search_cooldown = 0.0


## Public for deterministic feature tests. The runtime advances this after
## both action state machines, closing the harvest -> unload -> harvest loop.
func advance_harvest_cycle(delta := 0.0) -> void:
	if not _harvest_cycle_enabled:
		return
	if _assigned_refinery != null and not _is_valid_owned_refinery(_assigned_refinery):
		_assigned_refinery = null
	if has_harvest_order() or has_unload_order() or _pending_order != PendingOrder.NONE:
		return
	if _cycle_spice_layer == null or _cycle_grid == null or _unit.max_spice <= 0.0:
		return
	_auto_search_cooldown = maxf(_auto_search_cooldown - maxf(float(delta), 0.0), 0.0)
	if _auto_search_cooldown > 0.0:
		return
	if _unit.spice >= _unit.max_spice:
		var refinery := assigned_refinery()
		if refinery == null:
			refinery = _nearest_owned_refinery()
			_assigned_refinery = refinery
		if refinery == null:
			if _return_to_primary_main_base():
				# Returning to the main base is the terminal fallback for this
				# cycle. A refinery built later must not pull the harvester away
				# without a new player order.
				_harvest_cycle_enabled = false
			else:
				_auto_search_cooldown = AUTO_SEARCH_RETRY_SECONDS
			return
		_return_main_base = null
		_start_unload_order(refinery, _cycle_grid)
		return
	var origin: Vector2i = _cycle_grid.call("world_to_grid", _unit.global_position)
	var next_cell: Vector2i = _cycle_spice_layer.call(
		"nearest_spice_cell", origin, 1, -1, _auto_spice_cell_filter
	)
	if next_cell.x < 0 or next_cell.y < 0:
		_auto_search_cooldown = AUTO_SEARCH_RETRY_SECONDS
		return
	_start_harvest_order(_cycle_spice_layer, _cycle_grid, next_cell)


func _start_unload_order(refinery: Node, navigation_grid) -> void:
	_unload_refinery = refinery
	_unload_grid = navigation_grid
	_unload_dock = INVALID_DOCK
	_unload_interrupted = false
	_unload_credit_accumulator = 0.0
	_unload_phase_remaining = 0.0
	if _try_reserve_dock_and_park():
		return
	_unload_phase = UnloadPhase.APPROACH
	# All pads are occupied, including the central one. Queue outside the
	# footprint instead of targeting the building centre occupied by the
	# central harvester.
	_issue_unload_move(refinery.call("refinery_front_position") as Vector3)


func has_unload_order() -> bool:
	return _unload_phase != UnloadPhase.NONE


func unload_phase() -> int:
	return _unload_phase


func unload_dock() -> int:
	return _unload_dock


func cancel_harvest_order() -> void:
	var was_animating := _is_harvest_animating()
	_harvest_phase = HarvestPhase.NONE
	_harvest_phase_remaining = 0.0
	_harvest_spice_layer = null
	_harvest_grid = null
	_harvest_target_cell = Vector2i(-1, -1)
	_harvest_exit_refinery = null
	_harvest_exit_grid = null
	if was_animating:
		_unit.restore_movement_animation()


func has_harvest_order() -> bool:
	return _harvest_phase != HarvestPhase.NONE


## The three phases that play an authored clip, as opposed to driving or
## waiting. Both machines are asked this constantly, and the answer means the
## same thing for either: the harvester currently owns its own animation, so
## movement and idle animation must keep their hands off it, and a new order
## has to wait for the clip to end rather than cutting it mid-frame.
func _is_harvest_animating() -> bool:
	return _harvest_phase in [HarvestPhase.START, HarvestPhase.HOLD, HarvestPhase.END]


func _is_unload_animating() -> bool:
	return _unload_phase in [UnloadPhase.START, UnloadPhase.HOLD, UnloadPhase.END]


func has_active_order() -> bool:
	return (
		has_harvest_order()
		or has_unload_order()
		or _pending_order != PendingOrder.NONE
		or _harvest_cycle_enabled
	)


## Stop must also break the autonomous harvest/refinery loop; cancelling only
## the current route would otherwise make the harvester immediately choose a
## new field or resume unloading on the next process tick.
func cancel_all_orders() -> bool:
	var had_harvester_order := (
		has_harvest_order()
		or has_unload_order()
		or _pending_order != PendingOrder.NONE
		or _harvest_cycle_enabled
	)
	if not had_harvester_order:
		return false
	_harvest_cycle_enabled = false
	_cycle_spice_layer = null
	_cycle_grid = null
	_assigned_refinery = null
	_return_main_base = null
	_auto_search_cooldown = 0.0
	_pending_order = PendingOrder.NONE
	_pending_order_data.clear()
	cancel_harvest_order()
	_cancel_unload_immediately()
	return true


func harvest_target_cell() -> Vector2i:
	return _harvest_target_cell


## Public for deterministic fixed-delta feature tests; runtime calls it from
## Unit.sim_tick(), once per simulation tick, so the credits it eventually
## produces (see advance_unload_order() below) land on the same tick on every
## client regardless of frame rate.
func advance_harvest_order(delta: float) -> void:
	if _harvest_phase == HarvestPhase.NONE:
		return
	if _harvest_spice_layer == null or _harvest_grid == null or _unit.max_spice <= 0.0:
		_finish_harvest_order()
		return
	if _unit.spice >= _unit.max_spice:
		_finish_harvest_order()
		return
	if _harvest_phase == HarvestPhase.TRAVEL:
		if not _is_close_to_harvest_cell(_harvest_target_cell):
			return
		if int(_harvest_spice_layer.call("spice_at", _harvest_target_cell)) <= 0:
			_retarget_or_finish_harvest()
			return
		_unit.stop_at_current_position()
		_begin_harvest_phase(HarvestPhase.START)

	var remaining_delta := maxf(delta, 0.0)
	var transitions := 0
	while _is_harvest_animating() and transitions < 4:
		if _harvest_phase_remaining > remaining_delta:
			_harvest_phase_remaining -= remaining_delta
			break
		remaining_delta -= _harvest_phase_remaining
		_harvest_phase_remaining = 0.0
		_advance_harvest_phase()
		transitions += 1


## Public for deterministic feature tests. Runtime calls this from
## Unit.sim_tick(); fixed-rate credit conversion is accumulated on the
## simulation tick rather than the render frame, so which tick a credit lands
## on -- and therefore what it can fund -- no longer depends on frame timing.
func advance_unload_order(delta: float) -> void:
	if _unload_phase == UnloadPhase.NONE:
		return
	if not _is_valid_owned_refinery(_unload_refinery):
		_interrupt_invalid_refinery()
		if _unload_phase == UnloadPhase.NONE:
			return

	match _unload_phase:
		UnloadPhase.APPROACH:
			if not _is_close_to_world(_unit.target_position):
				return
			_unit.stop_at_current_position()
			_unload_phase = UnloadPhase.WAIT_DOCK
		UnloadPhase.WAIT_DOCK:
			_try_reserve_dock_and_park()
			return
		UnloadPhase.PARK:
			if not bool(_unload_refinery.call("refinery_dock_reserved_by", _unload_dock, _unit)):
				_unload_dock = INVALID_DOCK
				if _try_reserve_dock_and_park():
					return
				_unload_phase = UnloadPhase.APPROACH
				_issue_unload_move(
					_unload_refinery.call("refinery_front_position") as Vector3
				)
				return
			var dock_position := _unload_refinery.call("refinery_dock_world_position", _unload_dock) as Vector3
			if not _is_close_to_world(dock_position):
				return
			_unit.stop_at_current_position()
			_set_unload_navigation_hold(true)
			var dock_facing := _unload_refinery.call(
				"refinery_dock_facing_direction", _unload_dock
			) as Vector3
			if not _unit.turn_toward(dock_facing, delta):
				return
			_begin_unload_phase(UnloadPhase.START)
		UnloadPhase.RETURN_FRONT:
			if _is_close_to_world(_unit.target_position):
				_finish_unload_order()
			return

	var remaining_delta := maxf(delta, 0.0)
	var transitions := 0
	while _is_unload_animating() and transitions < 256:
		var segment := minf(_unload_phase_remaining, remaining_delta)
		if _unload_phase == UnloadPhase.HOLD and not _unload_interrupted:
			_transfer_unload_credits(segment)
		_unload_phase_remaining -= segment
		remaining_delta -= segment
		if _unload_phase_remaining > 0.0:
			break
		_advance_unload_phase()
		transitions += 1
		if remaining_delta <= 0.0:
			break


func _try_reserve_dock_and_park() -> bool:
	if not _is_valid_owned_refinery(_unload_refinery):
		return false
	var reserved := int(_unload_refinery.call("try_reserve_refinery_dock", _unit))
	if reserved == INVALID_DOCK:
		return false
	var dock_position := _unload_refinery.call("refinery_dock_world_position", reserved) as Vector3
	if not dock_position.is_finite():
		_unload_refinery.call("abandon_refinery_dock", _unit)
		return false
	_unload_dock = reserved
	_unload_phase = UnloadPhase.PARK
	_issue_dock_move(dock_position)
	return true


func _advance_unload_phase() -> void:
	match _unload_phase:
		UnloadPhase.START:
			_begin_unload_phase(UnloadPhase.END if _unload_interrupted else UnloadPhase.HOLD)
		UnloadPhase.HOLD:
			if _unload_interrupted or _unit.spice <= 0.0:
				_begin_unload_phase(UnloadPhase.END)
			else:
				_begin_unload_phase(UnloadPhase.HOLD)
		UnloadPhase.END:
			_set_unload_navigation_hold(false)
			_release_unload_dock()
			if _pending_order != PendingOrder.NONE:
				_finish_unload_order(false)
				_execute_pending_order()
			elif not _is_valid_owned_refinery(_unload_refinery):
				_finish_unload_order(false)
			elif _try_resume_harvest_from_dock():
				return
			else:
				_unload_phase = UnloadPhase.RETURN_FRONT
				_unload_phase_remaining = 0.0
				# Keep the per-agent dock-cell exception until the harvester has
				# actually cleared the refinery footprint. A generic move issued
				# from inside the pad would route around a building corner.
				_issue_dock_move(_unload_refinery.call("refinery_front_position") as Vector3)


func _begin_unload_phase(phase: UnloadPhase) -> void:
	_unload_phase = phase
	match phase:
		UnloadPhase.START:
			_set_unload_navigation_hold(true)
			_unload_phase_remaining = _unit.play_action_animation(UNLOAD_START_ANIMATION)
		UnloadPhase.HOLD:
			_unload_phase_remaining = maxf(
				_unit.play_action_animation(UNLOAD_HOLD_ANIMATION), UNLOAD_HOLD_FALLBACK_SECONDS
			)
		UnloadPhase.END:
			_unload_phase_remaining = _unit.play_action_animation(UNLOAD_END_ANIMATION)


func _transfer_unload_credits(delta: float) -> void:
	if delta <= 0.0 or _unit.spice <= 0.0:
		return
	var player = _unit.owner_player()
	if player == null:
		_interrupt_unload_animation()
		return
	_unload_credit_accumulator += delta * unload_rate_per_update * UNLOAD_UPDATES_PER_SECOND
	var credits := mini(floori(_unload_credit_accumulator), floori(_unit.spice))
	if credits <= 0:
		return
	_unload_credit_accumulator -= float(credits)
	_unit.spice -= float(credits)
	player.add_money(credits)


func _advance_harvest_phase() -> void:
	match _harvest_phase:
		HarvestPhase.START:
			_begin_harvest_phase(HarvestPhase.HOLD)
		HarvestPhase.HOLD:
			_collect_harvest_cycle()
			_begin_harvest_phase(HarvestPhase.END)
		HarvestPhase.END:
			if _unit.spice >= _unit.max_spice:
				_finish_harvest_order()
			elif int(_harvest_spice_layer.call("spice_at", _harvest_target_cell)) <= 0:
				_retarget_or_finish_harvest()
			else:
				_begin_harvest_phase(HarvestPhase.START)


func _begin_harvest_phase(phase: HarvestPhase) -> void:
	_harvest_phase = phase
	match phase:
		HarvestPhase.START:
			_harvest_phase_remaining = _unit.play_action_animation(HARVEST_START_ANIMATION)
		HarvestPhase.HOLD:
			_unit.play_action_animation(HARVEST_HOLD_ANIMATION)
			_harvest_phase_remaining = HARVEST_HOLD_SECONDS
		HarvestPhase.END:
			_harvest_phase_remaining = _unit.play_action_animation(HARVEST_END_ANIMATION)


func _collect_harvest_cycle() -> void:
	var remaining_capacity := maxi(floori(_unit.max_spice - _unit.spice), 0)
	var cycle_capacity := maxi(ceili(_unit.max_spice * HARVEST_CARGO_FRACTION_PER_CYCLE), 1)
	var requested := mini(remaining_capacity, cycle_capacity)
	if requested <= 0:
		return
	var collected := int(_harvest_spice_layer.call("take_spice", _harvest_target_cell, requested))
	_unit.spice += float(collected)


func _try_resume_harvest_from_dock() -> bool:
	if not _harvest_cycle_enabled or _cycle_spice_layer == null or _cycle_grid == null \
	or _unit.spice >= _unit.max_spice:
		return false
	# A refinery's rally point is a field-search origin, not a destination for
	# the departing harvester. This lets the player steer the automatic
	# economy loop toward a preferred spice field without making the harvester
	# visit the flag first.
	var search_origin := _unit.global_position
	if is_instance_valid(_unload_refinery) \
	and _unload_refinery.has_method("rally_point_position"):
		search_origin = _unload_refinery.call("rally_point_position") as Vector3
	var origin: Vector2i = _cycle_grid.call("world_to_grid", search_origin)
	var next_cell: Vector2i = _cycle_spice_layer.call(
		"nearest_spice_cell", origin, 1, -1, _auto_spice_cell_filter
	)
	if next_cell.x < 0 or next_cell.y < 0:
		return false
	var exit_refinery := _unload_refinery
	var exit_grid = _unload_grid
	_finish_unload_order(false)
	_start_harvest_order(_cycle_spice_layer, _cycle_grid, next_cell, exit_refinery, exit_grid)
	return true


func _retarget_or_finish_harvest() -> void:
	var next_cell: Vector2i = _harvest_spice_layer.call(
		"nearest_spice_cell", _harvest_target_cell, 1, -1, _auto_spice_cell_filter
	)
	if next_cell.x < 0 or next_cell.y < 0:
		_finish_harvest_order()
		return
	_harvest_target_cell = next_cell
	_harvest_phase = HarvestPhase.TRAVEL
	_harvest_phase_remaining = 0.0
	_move_to_harvest_cell(next_cell)


func _enable_harvest_cycle(spice_layer, navigation_grid) -> void:
	_harvest_cycle_enabled = true
	_cycle_spice_layer = spice_layer
	_cycle_grid = navigation_grid
	_return_main_base = null
	_auto_search_cooldown = 0.0


func _nearest_owned_refinery() -> Node:
	if not _unit.is_inside_tree():
		return null
	var nearest: Node = null
	var nearest_distance_squared := INF
	# "sim_buildings", not "buildings": reached only from
	# advance_harvest_cycle(), called from advance() which Unit.sim_tick()
	# drives -- picking an auto-unload destination is a simulation decision
	# and must not target a refinery the tick does not yet simulate.
	for candidate_variant in _unit.get_tree().get_nodes_in_group("sim_buildings"):
		var candidate := candidate_variant as Node
		if not _is_valid_owned_refinery(candidate) or not candidate is Node3D:
			continue
		var offset := (candidate as Node3D).global_position - _unit.global_position
		offset.y = 0.0
		var distance_squared := offset.length_squared()
		if distance_squared < nearest_distance_squared:
			nearest = candidate
			nearest_distance_squared = distance_squared
	return nearest


func _return_to_primary_main_base() -> bool:
	var players = AutoloadLookupScript.roster(_unit)
	var main_base: Node3D = players.call("main_base_for_player", _unit.owner_player_id) \
		if players != null and players.has_method("main_base_for_player") else null
	if not _is_valid_owned_main_base(main_base):
		_return_main_base = null
		return false
	if _return_main_base == main_base:
		return true
	_return_main_base = main_base
	_issuing_main_base_move = true
	_unit.move_to(main_base.global_position)
	_issuing_main_base_move = false
	return true


func _is_valid_owned_main_base(main_base: Node) -> bool:
	if not EntityQueryScript.is_live(main_base) or not main_base is Node3D:
		return false
	if main_base.has_method("is_owned_by"):
		return bool(main_base.call("is_owned_by", _unit.owner_player_id))
	return EntityQueryScript.is_owned_by(main_base, _unit.owner_player_id)


func _move_to_harvest_cell(cell: Vector2i) -> void:
	var exit_refinery := _harvest_exit_refinery
	var exit_grid = _harvest_exit_grid
	_harvest_exit_refinery = null
	_harvest_exit_grid = null
	_issuing_harvest_move = true
	var target: Vector3 = _harvest_grid.call("grid_to_world", cell)
	var departed := false
	if _is_valid_owned_refinery(exit_refinery):
		var cells := exit_refinery.call("refinery_dock_navigation_cells", exit_grid) as Dictionary
		departed = _unit.navigation_command_depart(target, cells)
	if not departed:
		_unit.move_to(target)
	_issuing_harvest_move = false


func _is_close_to_harvest_cell(cell: Vector2i) -> bool:
	var target: Vector3 = _harvest_grid.call("grid_to_world", cell)
	var cell_dimensions: Vector2 = _harvest_grid.call("cell_size")
	# Crowd navigation parks large units on non-overlapping footprint blocks.
	# A size-3 harvester beside another harvester can therefore have its centre
	# three cells from the clicked spice cell while its hull is already touching
	# the field. Scale the action radius to the authored footprint instead of
	# making every harvester fight for the same central parking block.
	var footprint_cells := float(_unit.unit_definition.size) if _unit.unit_definition != null else 1.0
	var approach_cells := maxf(HARVEST_APPROACH_RADIUS_CELLS, footprint_cells)
	var approach_radius := maxf(cell_dimensions.x, cell_dimensions.y) * approach_cells
	var offset := target - _unit.global_position
	offset.y = 0.0
	if offset.length() <= maxf(approach_radius, _unit.arrival_radius):
		return true
	# Crowd navigation may park a later size-3 harvester outside the nominal
	# action radius because nearer non-overlapping blocks already belong to its
	# peers. Reaching that navigation-owned safe destination is still arrival;
	# otherwise the gameplay state remains in TRAVEL forever with no route left.
	return _unit.is_navigation_managed() and _is_close_to_world(_unit.target_position)


func _finish_harvest_order() -> void:
	var was_animating := _is_harvest_animating()
	_unit.stop_at_current_position()
	_harvest_phase = HarvestPhase.NONE
	_harvest_phase_remaining = 0.0
	_harvest_spice_layer = null
	_harvest_grid = null
	_harvest_target_cell = Vector2i(-1, -1)
	if was_animating:
		_unit.restore_movement_animation()


func _set_unload_navigation_hold(active: bool) -> void:
	if _unit.is_navigation_managed():
		_unit.set_navigation_hold(active)


func _issue_unload_move(position: Vector3) -> void:
	_set_unload_navigation_hold(false)
	_issuing_unload_move = true
	_unit.move_to(position)
	_issuing_unload_move = false


func _issue_dock_move(position: Vector3) -> void:
	_set_unload_navigation_hold(false)
	var cells := _unload_refinery.call("refinery_dock_navigation_cells", _unload_grid) as Dictionary
	_issuing_unload_move = true
	var docked: bool = _unit.navigation_command_dock(position, cells)
	_issuing_unload_move = false
	if not docked:
		_issue_unload_move(position)


func _is_close_to_world(target: Vector3) -> bool:
	var offset := target - _unit.global_position
	offset.y = 0.0
	var tolerance: float = _unit.navigation_arrival_tolerance(maxf(_unit.arrival_radius, 0.35))
	return offset.length() <= tolerance


func _is_valid_owned_refinery(refinery: Node) -> bool:
	if not EntityQueryScript.is_live(refinery):
		return false
	if not refinery.has_method("is_refinery") or not bool(refinery.call("is_refinery")):
		return false
	if refinery.has_method("is_owned_by"):
		return bool(refinery.call("is_owned_by", _unit.owner_player_id))
	return EntityQueryScript.is_owned_by(refinery, _unit.owner_player_id)


func _interrupt_invalid_refinery() -> void:
	_pending_order = PendingOrder.NONE
	_pending_order_data.clear()
	if _is_unload_animating():
		_interrupt_unload_animation()
		return
	_cancel_unload_immediately()


func _interrupt_unload_animation() -> void:
	if not _is_unload_animating():
		return
	_unload_interrupted = true


func _cancel_unload_immediately() -> void:
	if _unload_phase == UnloadPhase.NONE:
		return
	if is_instance_valid(_unload_refinery) and _unload_dock != INVALID_DOCK:
		if _unload_phase == UnloadPhase.PARK:
			_unload_refinery.call("release_refinery_dock", _unit)
		else:
			_unload_refinery.call("abandon_refinery_dock", _unit)
	_finish_unload_order(false)


func cancel_unload_order() -> void:
	_pending_order = PendingOrder.NONE
	_pending_order_data.clear()
	if _is_unload_animating():
		_interrupt_unload_animation()
	else:
		_cancel_unload_immediately()


func _release_unload_dock() -> void:
	if is_instance_valid(_unload_refinery) and _unload_dock != INVALID_DOCK:
		_unload_refinery.call("release_refinery_dock", _unit)
	_unload_dock = INVALID_DOCK


func _finish_unload_order(stop_unit := true) -> void:
	_set_unload_navigation_hold(false)
	if stop_unit:
		_unit.stop_at_current_position()
	_unload_phase = UnloadPhase.NONE
	_unload_phase_remaining = 0.0
	_unload_refinery = null
	_unload_grid = null
	_unload_dock = INVALID_DOCK
	_unload_interrupted = false
	_unload_credit_accumulator = 0.0


func _queue_pending_order(kind: PendingOrder, data: Dictionary) -> void:
	_pending_order = kind
	_pending_order_data = data.duplicate()


func _execute_pending_order() -> void:
	var kind := _pending_order
	var data := _pending_order_data.duplicate()
	_pending_order = PendingOrder.NONE
	_pending_order_data.clear()
	match kind:
		PendingOrder.MOVE:
			var position := data.get("position", _unit.global_position) as Vector3
			var exit_point := data.get("exit_point", Vector3.INF) as Vector3
			var move_mode := int(data.get("move_mode", 0))
			# Outside the navigation system this goes through the unit's own
			# move_to, which comes back through prepare_navigation_order --
			# harmless here: the queued order already cleared the cycle, and
			# neither machine is running by the time it drains.
			if not _unit.navigation_command_move(position, move_mode, exit_point):
				_unit.move_to(position, exit_point)
		PendingOrder.HARVEST:
			if _unit.spice >= _unit.max_spice:
				advance_harvest_cycle()
			else:
				_start_harvest_order(data.get("spice_layer"), data.get("grid"), data.get("cell", Vector2i(-1, -1)))
		PendingOrder.UNLOAD:
			var refinery := data.get("refinery") as Node
			if _is_valid_owned_refinery(refinery):
				_start_unload_order(refinery, data.get("grid"))


## The one rules value the unit facade does not own. Capacity does not come
## through here: it is what attached this module in the first place.
func apply_definition(definition: Resource) -> void:
	if definition == null:
		return
	unload_rate_per_update = maxf(float(definition.unload_rate), 0.0)


## While an authored harvest or unload clip is playing, the unit's ordinary
## movement and idle animation must keep their hands off the model, and the
## clip's own completion must not be routed to them either.
func owns_animation() -> bool:
	return _is_harvest_animating() or _is_unload_animating()
