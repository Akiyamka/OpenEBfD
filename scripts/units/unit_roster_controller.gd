class_name UnitRosterController
extends Node

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")
const SimUnitOrderCommandScript := preload("res://scripts/sim/commands/unit_order_command.gd")

## docs/mechanics/production.md section 3 "unit production": the roster half
## only. The Infantry/Vehicles panel tabs list the units the technology tree
## currently unlocks -- primary production building owned, its upgrade
## purchased when the unit demands one (upgraded_primary_required), and the
## map tech level cap -- all via the same TechnologyTree.is_available() the
## building grid uses. A queue belongs to a production-building type; its
## primary instance supplies the spawn location and rally point.

signal status_changed(status: String)
signal unit_option_state_changed(option_state: BuildingOptionState)

const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingDefinitionCatalogScript := preload(
	"res://scripts/buildings/building_definition_catalog.gd"
)
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const BuildingAvailabilityTrackerScript := preload(
	"res://scripts/buildings/building_availability_tracker.gd"
)

const UNIT_POPULATION_LIMIT := 1000
const UNIT_QUEUE_CAPACITY := 100

## Same extension point as BuildingController.max_tech_level -- a future
## map/mission tech-level cap (see TechnologyTree.UNLIMITED_TECH_LEVEL).
var max_tech_level: int = TechnologyTreeScript.UNLIMITED_TECH_LEVEL
## The command bus handle_unit_intent() submits SimUnitOrderCommands to, and a
## matching way to ask "what tick would a command submitted right now
## target" -- injected together by setup(), in production by Match.
## _setup_unit_roster_controller() and in tests by
## tests/match/support/command_pump.gd, the same way UnitCommandController's
## are (see that class's own _command_bus field comment). Unlike
## BuildingController, every left/right click on a unit slot needs one -- see
## handle_unit_intent()'s doc comment for why there is no local interaction-
## mode branch to peel off first.
var _command_bus: SimCommandBus
var _submit_tick_provider: Callable

var _unit_ids: Array[StringName] = []
var _unit_definitions: Dictionary = {}
var _technology_tree: TechnologyTree = TechnologyTreeScript.new()
## Cached per-id availability, refreshed only when the tracker reports that
## something the technology tree reads has changed.
var _unit_availability: Dictionary = {}
var _availability_tracker := BuildingAvailabilityTrackerScript.new()
var _production_queues: Dictionary = {}
## BuildingQueue owns the unit currently under construction.  The remaining
## entries are FIFO orders for that same production-building type; this keeps
## the gradual-payment implementation shared with building construction while
## allowing the documented 100-unit production queue.
var _pending_unit_ids: Dictionary = {}
static var _unit_scene_catalog := UnitSceneCatalogScript.shared()
static var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()


func setup(
		unit_ids: Array[StringName],
		command_bus: SimCommandBus = null,
		submit_tick_provider: Callable = Callable()
) -> void:
	_unit_ids = unit_ids.duplicate()
	_command_bus = command_bus
	_submit_tick_provider = submit_tick_provider
	_load_unit_definitions()
	_availability_tracker.bind(self)
	_refresh_availability_if_dirty()
	_refresh_unit_option_states()


func _exit_tree() -> void:
	_availability_tracker.unbind()


func process(_delta: float) -> void:
	if _refresh_availability_if_dirty():
		_refresh_unit_option_states()


## Simulation half of the old process(delta): production-order progress,
## driven from MatchClock rather than frame delta. See
## match.gd::_advance_simulation_tick() for why this and the sibling
## controllers' advance_tick() run in a fixed order.
func advance_tick() -> void:
	if _process_unit_orders():
		_refresh_unit_option_states()


## Unit availability depends on which buildings the player owns and whether they
## are upgraded, both of which change as buildings are placed, upgraded, sold or
## lost elsewhere on the map. It used to be re-derived every frame, which meant
## an O(unit ids x buildings) TechnologyTree scan per frame -- 3 ms of the frame
## once a base was standing, the single largest cost in it. The tracker reports
## when any of those facts actually changed; between changes the cache below
## answers.
##
## Same out-of-tree rule as BuildingController._refresh_availability_if_dirty():
## outside the tree nothing is available, and that is recomputed unconditionally
## rather than gated on the flag, so a stale cached "true" cannot outlive the
## controller's own teardown.
func _refresh_availability_if_dirty() -> bool:
	if not is_inside_tree():
		var no_buildings: Array[Node] = []
		return _recompute_availability(null, no_buildings)
	if not _availability_tracker.consume_dirty():
		return false
	return _recompute_availability(_local_player(), _availability_tracker.buildings())


## One buildings array for the whole roster, not one per unit id -- rebuilding
## it per id is what made the scan quadratic.
func _recompute_availability(player, buildings: Array[Node]) -> bool:
	var changed := false
	for unit_id in _unit_ids:
		var config: Resource = _unit_definitions.get(unit_id)
		var available: bool = config != null and player != null \
			and _technology_tree.is_available(config, player, buildings, max_tech_level)
		if available == _unit_availability.get(unit_id, false):
			continue
		_unit_availability[unit_id] = available
		changed = true
	return changed


## The command-bus seam for the sidebar's unit slots (see
## docs/architecture/network-multiplayer.md, "Layering" -- "commands" vs
## "simulation"). Unlike BuildingController's build order, no click here ever
## opens an interaction mode of its own -- a finished unit order just spawns,
## with no placement step to preview -- so every left/right click on a unit
## slot becomes a SimUnitOrderCommand; execute_unit_order_command() replays
## the same _on_unit_slot_left_pressed()/_on_unit_slot_right_pressed() logic
## that used to run synchronously here, against the queue as it stands on the
## tick the bus schedules it for. See SimUnitOrderCommand's doc comment.
func handle_unit_intent(unit_id: StringName, button_index: int, quantity := 1) -> bool:
	if not _unit_ids.has(unit_id):
		return false
	if button_index == MOUSE_BUTTON_LEFT or button_index == MOUSE_BUTTON_RIGHT:
		_submit_unit_order_command(unit_id, button_index, quantity)
	return true


## The issue side of a unit-order click: immediate, and split from execution
## on purpose, exactly as every other command (see SimUnitOrderCommand's doc
## comment). A controller with no command bus wired in is a wiring mistake,
## not a supported mode -- see the _command_bus field comment.
func _submit_unit_order_command(unit_id: StringName, button_index: int, quantity: int) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"UnitRosterController._submit_unit_order_command(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_unit_roster_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
		return
	var command := SimUnitOrderCommandScript.new()
	var players = AutoloadLookupScript.roster(self)
	if players != null:
		command.player_id = players.local_player_id
	command.unit_id = unit_id
	command.button_index = button_index
	command.quantity = quantity
	_command_bus.submit(command, _submit_tick_provider.call())


## The execution side of a unit-order click: Match._advance_simulation_tick()
## calls this with the SimUnitOrderCommand it just drained, on the tick the
## bus scheduled it for.
func execute_unit_order_command(command: SimUnitOrderCommand) -> void:
	match command.button_index:
		MOUSE_BUTTON_LEFT:
			_on_unit_slot_left_pressed(command.unit_id, command.quantity)
		MOUSE_BUTTON_RIGHT:
			_on_unit_slot_right_pressed(command.unit_id, command.quantity)


func _on_unit_slot_left_pressed(unit_id: StringName, quantity: int) -> void:
	if not _is_unit_available(unit_id):
		status_changed.emit("%s is not available" % String(unit_id))
		return
	var config: Resource = _unit_definitions.get(unit_id)
	var production_building_id := _production_building_id(config)
	if production_building_id == &"":
		status_changed.emit("No production building is available for %s" % String(unit_id))
		return
	var queue := _queue_for(production_building_id)
	var order = queue.current_order()
	if order != null and order.building_id == unit_id and order.manually_paused:
		queue.resume()
		status_changed.emit("%s production resumed" % order.display_name)
		_refresh_unit_option_states()
		return
	var quantity_to_add := clampi(quantity, 1, UNIT_QUEUE_CAPACITY)
	var remaining_capacity := UNIT_QUEUE_CAPACITY - _unit_queue_size(production_building_id)
	if remaining_capacity <= 0:
		status_changed.emit("%s production queue is full" % production_building_id)
		return
	quantity_to_add = mini(quantity_to_add, remaining_capacity)
	var pending := _pending_queue_for(production_building_id)
	for _index in quantity_to_add:
		pending.append(unit_id)
	_start_next_unit_order(production_building_id)
	status_changed.emit("%s queued +%d (%d)" % [String(unit_id), quantity_to_add, _unit_queue_size(production_building_id)])
	_refresh_unit_option_states()


func _on_unit_slot_right_pressed(unit_id: StringName, quantity: int) -> void:
	var config: Resource = _unit_definitions.get(unit_id)
	var production_building_id := _production_building_id(config)
	if production_building_id == &"":
		return
	var queue := _queue_for(production_building_id)
	var order = queue.current_order()
	if order == null:
		return
	if order.manually_paused:
		var removed := _remove_queued_units(production_building_id, unit_id, clampi(quantity, 1, UNIT_QUEUE_CAPACITY))
		if removed.is_empty():
			return
		var refunded := int(removed.get("refund", 0))
		status_changed.emit("%s removed from production queue x%d; refunded %d" % [String(unit_id), int(removed.get("count", 0)), refunded])
	else:
		if order.building_id != unit_id:
			return
		queue.pause()
		status_changed.emit("%s production paused" % order.display_name)
	_refresh_unit_option_states()


func _process_unit_orders() -> bool:
	var player := _local_player()
	if player == null:
		return false
	var changed := false
	for production_building_id in _production_queues.keys():
		var queue: BuildingQueue = _production_queues[production_building_id]
		var order = queue.current_order()
		if order == null:
			continue
		if not order.ready:
			changed = queue.advance_tick(player.money, Callable(player, "spend_money")) or changed
			order = queue.current_order()
		if order != null and order.ready and _spawn_completed_unit(order.building_id, StringName(production_building_id)):
			queue.take_ready()
			status_changed.emit("%s completed" % order.display_name)
			_start_next_unit_order(StringName(production_building_id))
			changed = true
	return changed


func _spawn_completed_unit(unit_id: StringName, production_building_id: StringName) -> bool:
	var player := _local_player()
	var building := _production_building_for(production_building_id, player.player_id if player != null else -1)
	if building == null:
		return false
	var parent := _units_parent(building)
	if parent == null or _owned_unit_count(player.player_id) >= UNIT_POPULATION_LIMIT:
		return false

	var unit := _unit_scene_catalog.instantiate(unit_id, UnitScene) as Unit
	if unit == null:
		return false
	unit.name = String(unit_id)
	unit.config_id = unit_id
	parent.add_child(unit)
	# Units begin just inside the producer's front edge, then immediately move
	# toward that building's own rally point.
	var spawn_position = building.call("production_spawn_position") if building.has_method("production_spawn_position") else building.global_position
	unit.set_simulation_position(spawn_position)
	unit.face_direction(_production_exit_direction(building))
	unit.set_owner_player_id(player.player_id)
	var rally_point = building.call("rally_point_position") if building.has_method("rally_point_position") else _default_rally_point(building)
	# The exit point walks the unit straight out through the building's front
	# before regular routing toward the rally point takes over.
	var exit_point: Vector3 = building.call("production_exit_position") if building.has_method("production_exit_position") else Vector3.INF
	if unit.has_method("begin_hangar_takeoff") and unit.unit_definition != null and bool(unit.unit_definition.can_fly):
		unit.begin_hangar_takeoff(rally_point, exit_point)
	else:
		unit.move_to(rally_point, exit_point)
	return true


## Specialized units keep their own script/scene lifecycle while remaining
## compatible with the Unit production and navigation contracts.
func _scene_for_unit(unit_id: StringName) -> PackedScene:
	# Kept as a small compatibility seam for tests and callers that only need
	# the PackedScene. Actual production uses catalog.instantiate(), which also
	# configures the visual for the generic fallback path.
	return _unit_scene_catalog.scene_for(unit_id, UnitScene)


func _production_building_id(config: Resource) -> StringName:
	if config == null:
		return &""
	var primary_buildings: Array[StringName] = []
	primary_buildings.assign(config.primary_building_ids)
	var player := _local_player()
	var player_id := player.player_id if player != null else -1
	if player != null:
		for building_id in primary_buildings:
			var definition := _building_definition_catalog.definition(building_id)
			if definition != null and definition.house_id == player.house_id \
			and _production_building_for(building_id, player_id) != null:
				return building_id
	for building_id in primary_buildings:
		if _production_building_for(building_id, player_id) != null:
			return building_id
	return &""


func _production_building_for(building_id: StringName, player_id: int) -> Node3D:
	if building_id == &"" or not is_inside_tree():
		return null
	var players = AutoloadLookupScript.roster(self)
	if players != null:
		var primary = players.primary_building(player_id, String(building_id)) as Node3D
		if _is_owned_production_building(primary, building_id, player_id):
			return primary

	for node in get_tree().get_nodes_in_group("buildings"):
		var candidate := node as Node3D
		if not _is_owned_production_building(candidate, building_id, player_id):
			continue
		if players != null:
			players.designate_primary_building(candidate, player_id, String(building_id))
		return candidate
	return null


func _is_owned_production_building(building: Node3D, building_id: StringName, player_id: int) -> bool:
	return (
		EntityQueryScript.is_live(building)
		and StringName(String(building.get("config_id"))) == building_id
		and EntityQueryScript.is_owned_by(building, player_id)
		and _is_building_construction_complete(building)
	)


func _queue_for(production_building_id: StringName) -> BuildingQueue:
	var queue: BuildingQueue = _production_queues.get(production_building_id)
	if queue == null:
		queue = BuildingQueueScript.new()
		_production_queues[production_building_id] = queue
	return queue


func _pending_queue_for(production_building_id: StringName) -> Array[StringName]:
	if not _pending_unit_ids.has(production_building_id):
		var pending: Array[StringName] = []
		_pending_unit_ids[production_building_id] = pending
	return _pending_unit_ids[production_building_id]


func _unit_queue_size(production_building_id: StringName) -> int:
	var queue := _queue_for(production_building_id)
	return (1 if queue.has_order() else 0) + _pending_queue_for(production_building_id).size()


func _queued_unit_count(production_building_id: StringName, unit_id: StringName) -> int:
	var count := 0
	var queue: BuildingQueue = _production_queues.get(production_building_id)
	var order = queue.current_order() if queue != null else null
	if order != null and order.building_id == unit_id:
		count += 1
	for queued_unit_id in _pending_queue_for(production_building_id):
		if queued_unit_id == unit_id:
			count += 1
	return count


func _remove_queued_units(production_building_id: StringName, unit_id: StringName, quantity: int) -> Dictionary:
	var pending := _pending_queue_for(production_building_id)
	var removed_count := 0
	for index in range(pending.size() - 1, -1, -1):
		if removed_count >= quantity:
			break
		if pending[index] == unit_id:
			pending.remove_at(index)
			removed_count += 1

	var refunded := 0
	var queue := _queue_for(production_building_id)
	var order = queue.current_order()
	if removed_count < quantity and order != null and order.building_id == unit_id:
		refunded = queue.cancel()
		removed_count += 1
		var player := _local_player()
		if player != null and refunded > 0:
			player.add_money(refunded)
		_start_next_unit_order(production_building_id)
		# Pausing belongs to the queue, not merely to the item that was
		# removed. Keep a following item paused as well.
		queue.pause()

	return {"count": removed_count, "refund": refunded} if removed_count > 0 else {}


func _start_next_unit_order(production_building_id: StringName) -> void:
	var queue := _queue_for(production_building_id)
	if queue.has_order():
		return
	var pending := _pending_queue_for(production_building_id)
	if pending.is_empty():
		return
	var unit_id: StringName = pending.pop_front()
	var config: Resource = _unit_definitions.get(unit_id)
	if config == null:
		push_warning("Unit rules config not found for queued unit: %s" % String(unit_id))
		_start_next_unit_order(production_building_id)
		return
	if not queue.start(
		unit_id,
		String(unit_id),
		maxi(int(config.cost), 0),
		RuleTicksScript.order_sim_ticks(config.build_time_ticks)
	):
		push_warning("Unit could not be started from production queue: %s" % String(unit_id))


func _units_parent(building: Node3D) -> Node:
	return EntityQueryScript.units_parent(get_tree(), building.get_parent())


func _owned_unit_count(player_id: int) -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group("units"):
		if EntityQueryScript.is_owned_by(node, player_id):
			count += 1
	return count


func _default_rally_point(building: Node3D) -> Vector3:
	return building.global_position + _production_exit_direction(building) * 2.0


func _production_exit_direction(building: Node3D) -> Vector3:
	return EntityQueryScript.exit_direction(building)


func _load_unit_definitions() -> void:
	for unit_id in _unit_ids:
		var config: Resource = _unit_scene_catalog.definition_for(unit_id)
		if config == null:
			push_warning("Unit definition not found: %s" % String(unit_id))
			continue
		_unit_definitions[unit_id] = config


## Reads the cache _refresh_availability_if_dirty() maintains, the same way the
## building grid reads BuildingCatalogView.is_available(). Deliberately not a
## live recompute: this is called once per configured id per option-state
## refresh, on top of every unit intent.
func _is_unit_available(unit_id: StringName) -> bool:
	return bool(_unit_availability.get(unit_id, false))


func _is_building_construction_complete(building: Node) -> bool:
	return EntityQueryScript.is_operational(building)


func _refresh_unit_option_states() -> void:
	for unit_id in _unit_ids:
		var state := BuildingOptionStateScript.State.DISABLED
		var progress := 0.0
		var status_text := ""
		var queue_quantity := 0
		if _is_unit_available(unit_id):
			state = BuildingOptionStateScript.State.AVAILABLE
			var production_building_id := _production_building_id(_unit_definitions.get(unit_id))
			var queue: BuildingQueue = _production_queues.get(production_building_id)
			var order = queue.current_order() if queue != null else null
			if order != null:
				var queued_count := _queued_unit_count(production_building_id, unit_id)
				queue_quantity = queued_count
				if order.building_id == unit_id:
					state = BuildingOptionStateScript.State.READY if order.ready else BuildingOptionStateScript.State.PROGRESS
					progress = order.progress_percent()
					status_text = "PAUSED" if order.manually_paused else ""
				elif queued_count > 0:
					state = BuildingOptionStateScript.State.PROGRESS
				else:
					state = BuildingOptionStateScript.State.BLOCKED
		unit_option_state_changed.emit(BuildingOptionStateScript.new(
			unit_id, state, progress, status_text, _unit_tooltip(unit_id), queue_quantity
		))


func _unit_tooltip(unit_id: StringName) -> String:
	var config: Resource = _unit_definitions.get(unit_id)
	if config == null:
		return String(unit_id)

	var cost := int(config.cost)
	# Seconds from the actual simulation ticks the order will run for, not the
	# pre-conversion rules-domain ideal -- the duration the player really waits.
	var sim_ticks := RuleTicksScript.to_sim_ticks(config.build_time_ticks)
	var build_seconds := float(sim_ticks) * MatchClockScript.SECONDS_PER_TICK
	return "%s\nCost: %d\nBuild: %.1fs" % [String(unit_id), cost, build_seconds]


func _local_player() -> PlayerData:
	if not is_inside_tree():
		return null
	var players = AutoloadLookupScript.roster(self)
	if players == null:
		return null
	return players.local_player() as PlayerData
