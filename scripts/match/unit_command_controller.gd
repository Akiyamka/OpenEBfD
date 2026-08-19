class_name UnitCommandController
extends Node

signal status_changed(status: String)
signal target_ability_mode_changed(active: bool)

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")
const SoundEventPlayerScript := preload("res://scripts/audio/sound_event_player.gd")
const UnitVoiceCatalogScript := preload("res://scripts/audio/unit_voice_catalog.gd")
const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const TerrainProbeScript := preload("res://scripts/world/terrain_probe.gd")
const SelectionPartitionScript := preload("res://scripts/match/selection_partition.gd")
const SelectionTargetAbilityControllerScript := preload(
	"res://scripts/match/selection_target_ability_controller.gd"
)
const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")

var _camera: Camera3D
var _terrain: MapLoader
var _selection_rectangle = null
var _navigation
var _deployment_controller
## The command bus this controller submits SimCommands to, and a matching
## way to ask "what tick would a command submitted right now target" --
## injected together by Match._setup_unit_command_controller(), the same way
## camera/terrain/navigation are. Both are null in every suite that builds
## this controller directly with no Match in the tree (see
## tests/match/unit_command_run.gd), which is exactly the case
## _stop_selected_entities() falls back to its pre-command-bus behaviour
## for -- see that method.
var _command_bus: SimCommandBus
var _submit_tick_provider: Callable
# Units and buildings are protocol-compatible group members in runtime and
# tests, not one concrete class. Both expose ownership and selection methods.
var _selected_entities: Array[Node] = []
var _hovered_entity = null
var _drag_start: Vector2 = Vector2.INF
var _formation_modifier_down := false
var _attack_modifier_down := false

const DRAG_SELECTION_THRESHOLD := 8.0
const TERRAIN_COLLISION_MASK := 1
const ENTITY_SELECTION_COLLISION_MASK := 2
const COMMAND_CURSOR_OVERRIDE := &"unit_command"
const COMMAND_CURSOR_PRIORITY := 25
const NO_CURSOR_OVERRIDE := -1
const DEPLOYMENT_CURSOR_CHECK_INTERVAL_MSEC := 1000

var _deployment_cursor_entity_id := 0
var _deployment_cursor_last_check_msec := -DEPLOYMENT_CURSOR_CHECK_INTERVAL_MSEC
var _deployment_cursor_result := NO_CURSOR_OVERRIDE
var _selected_orders_active := -1
var _voice_catalog := UnitVoiceCatalogScript.new()
var _voice_player
var _target_abilities = SelectionTargetAbilityControllerScript.new()


func _ready() -> void:
	_voice_player = SoundEventPlayerScript.new()
	_voice_player.name = "UnitVoiceFeedback"
	add_child(_voice_player)


func setup(
		command_camera: Camera3D,
		command_terrain: MapLoader,
		navigation = null,
		selection_rectangle = null,
		deployment_controller = null,
		ability_bar = null,
		target_ability_handlers: Array = [],
		command_bus: SimCommandBus = null,
		submit_tick_provider: Callable = Callable()
	) -> void:
	_camera = command_camera
	_terrain = command_terrain
	_navigation = navigation
	_selection_rectangle = selection_rectangle
	_deployment_controller = deployment_controller
	_command_bus = command_bus
	_submit_tick_provider = submit_tick_provider
	_target_abilities.configure(ability_bar, target_ability_handlers)
	if not _target_abilities.status_changed.is_connected(_on_target_ability_status_changed):
		_target_abilities.status_changed.connect(_on_target_ability_status_changed)
	if not _target_abilities.mode_changed.is_connected(_on_target_ability_mode_changed):
		_target_abilities.mode_changed.connect(_on_target_ability_mode_changed)


func process() -> void:
	_prune_uncommandable_selection()
	_refresh_idle_status()
	_target_abilities.refresh()
	var hovered_control := get_viewport().gui_get_hovered_control()
	if hovered_control != null and hovered_control.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		_clear_command_cursor()
		return
	if _target_abilities.is_active():
		_update_target_ability_cursor(get_viewport().get_mouse_position())
	else:
		_update_command_cursor(get_viewport().get_mouse_position())


func _exit_tree() -> void:
	var cursors: Variant = _cursor_manager()
	if cursors != null:
		cursors.clear_override(COMMAND_CURSOR_OVERRIDE)


## Target-ability hotkeys must be offered before GUI focus gets a chance to
## consume an ordinary letter key. Match's `_unhandled_input` never sees such
## an event, while button presses bypass that path entirely. Keeping only the
## generic target-ability dispatcher here makes keyboard and button activation
## equivalent without moving normal RTS keys out of Match's priority chain.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and _target_abilities.handle_key(event):
		get_viewport().set_input_as_handled()


func handle_unhandled_input(event: InputEvent) -> bool:
	if event is InputEventKey:
		if _target_abilities.handle_key(event):
			return true
		if _is_attack_modifier(event):
			_attack_modifier_down = event.pressed
			return false
		if _is_formation_modifier(event):
			_formation_modifier_down = event.pressed
			return false
		if _is_stop_key(event):
			if event.pressed and not event.echo:
				_stop_selected_entities()
			return true
		if _is_deploy_key(event):
			if event.pressed and not event.echo:
				# D deliberately keeps its ordinary deployment behaviour.  It is
				# not a target ability, so leave a map-targeting mode before issuing
				# the deploy command rather than allowing both modes to coexist.
				_target_abilities.cancel()
				_deploy_selected_entities()
			return true
	if event is InputEventMouseMotion:
		if _target_abilities.is_active():
			_update_target_ability_cursor(event.position)
			return true
		if _is_dragging():
			_update_drag_selection(event.position)
			return true
		_update_hover(event.position)
		return false
	if not event is InputEventMouseButton:
		return false
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if _target_abilities.is_active():
				if event.pressed:
					_execute_target_ability(event.position)
				return true
			if event.pressed:
				_begin_drag_selection(event.position)
			else:
				_finish_drag_selection(event.position)
			return true
		MOUSE_BUTTON_RIGHT:
			if _target_abilities.is_active() and event.pressed:
				_target_abilities.cancel()
				return true
			if event.pressed:
				_command_at(event.position, event.ctrl_pressed or _attack_modifier_down)
				return true
	return false


func selection_text(status := "") -> String:
	if _selected_entities.is_empty():
		return status if not status.is_empty() else "No entity selected"

	var text := ""
	if _selected_entities.size() == 1:
		var entity: Node = _selected_entities.front()
		text = "%s selected | %s" % [entity.name, _owner_status(entity)]
	else:
		text = "%d units selected" % _selected_entities.size()
	if not status.is_empty():
		text += " | %s" % status
	return text


func _refresh_idle_status() -> void:
	if _selected_entities.is_empty():
		_selected_orders_active = -1
		return
	var has_units := false
	var active := false
	for entity in _selected_entities:
		if not is_instance_valid(entity) or not entity.has_method("has_active_order"):
			continue
		has_units = true
		if bool(entity.call("has_active_order")):
			active = true
			break
	if not has_units:
		_selected_orders_active = -1
		return
	var next_state := 1 if active else 0
	if next_state == _selected_orders_active:
		return
	_selected_orders_active = next_state
	if not active:
		status_changed.emit("Idle")


func _begin_drag_selection(screen_position: Vector2) -> void:
	_drag_start = screen_position
	# Keep click selection responsive and preserve the established press-based
	# input behaviour. A real drag replaces this temporary selection on release.
	_select_at(screen_position)


func _update_drag_selection(screen_position: Vector2) -> void:
	if _selection_rectangle != null:
		_selection_rectangle.show_between(_drag_start, screen_position)


func _finish_drag_selection(screen_position: Vector2) -> void:
	if not _is_dragging():
		return
	var drag_distance := _drag_start.distance_to(screen_position)
	if _selection_rectangle != null:
		_selection_rectangle.clear()
	if drag_distance >= DRAG_SELECTION_THRESHOLD:
		_select_units_in_rectangle(Rect2(_drag_start, screen_position - _drag_start).abs())
	_drag_start = Vector2.INF


func _is_dragging() -> bool:
	return _drag_start != Vector2.INF


func _select_at(screen_position: Vector2) -> void:
	var selected: Array[Node] = []

	var hit := _raycast(screen_position)
	if not hit.is_empty():
		var entity = _find_selectable_entity(hit.get("collider") as Node)
		if entity != null and _can_control(entity):
			if _is_repeated_single_selection(entity) and _try_deploy(entity):
				return
			selected.append(entity)
	_set_selection(selected)
	status_changed.emit("")


func _is_repeated_single_selection(entity: Node) -> bool:
	return _selected_entities.size() == 1 and _selected_entities.front() == entity


func _try_deploy(entity: Node) -> bool:
	if _deployment_controller == null or not entity.is_in_group("units"):
		return false
	var result: Dictionary = _deployment_controller.call("try_deploy", entity)
	if not bool(result.get("handled", false)):
		return false
	status_changed.emit(String(result.get("message", "")))
	return true


func _is_deploy_key(event: InputEventKey) -> bool:
	return event.keycode == KEY_D or event.physical_keycode == KEY_D


func _is_stop_key(event: InputEventKey) -> bool:
	return event.keycode == KEY_S or event.physical_keycode == KEY_S


## The issue side of Stop: immediate, and split from execution on purpose
## (see docs/architecture/network-multiplayer.md, "Layering" -- "commands"
## vs "simulation"). With a command bus wired in (the real game, via
## Match._setup_unit_command_controller()) this only resolves the current
## selection to stable entity ids and submits one SimStopCommand; cancelling
## the orders themselves, and therefore knowing how many actually stopped,
## only happens once CommandExecutor._execute_stop() runs on the tick this
## command is scheduled for (see on_command_executed() for how that result
## finds its way back to status_changed).
##
## Without a bus -- every suite that builds this controller directly, with
## no Match anywhere in the tree, see tests/match/unit_command_run.gd --
## this falls back to the old immediate behaviour unchanged: cancel orders
## right here and report the count synchronously. Those fixtures' fake
## entities have no entity_id at all, so this is not merely a convenience
## fallback, it is the only path that does not reach for a property they do
## not have.
func _stop_selected_entities() -> void:
	if _command_bus == null:
		_emit_stop_status(_cancel_orders_immediately())
		return
	var entity_ids := PackedInt32Array()
	for entity in _controllable_entities():
		# entity_id == 0 -- including "this entity type has no such
		# property at all" -- means "never registered with a Match" (see
		# scripts/sim/entity_registry.gd): skip it rather than submit a
		# command CommandExecutor could never resolve back to this entity.
		if not &"entity_id" in entity:
			continue
		var id := int(entity.get(&"entity_id"))
		if id != 0:
			entity_ids.append(id)
	if entity_ids.is_empty():
		return
	var command := SimStopCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.entity_ids = entity_ids
	_command_bus.submit(command, _submit_tick_provider.call())


## The pre-command-bus behaviour, preserved verbatim as the fallback
## _stop_selected_entities() uses when no bus is wired in, and reused as
## CommandExecutor._execute_stop()'s model for what "cancelling" means on
## the execution side -- see that method.
func _cancel_orders_immediately() -> int:
	var stopped := 0
	for entity in _controllable_entities():
		if not entity.has_method("cancel_all_orders"):
			continue
		if bool(entity.call("cancel_all_orders")):
			stopped += 1
	return stopped


func _emit_stop_status(stopped: int) -> void:
	if stopped == 1:
		status_changed.emit("Stopped")
	elif stopped > 1:
		status_changed.emit("%d orders stopped" % stopped)


## The feedback half of the Stop split (see _stop_selected_entities()):
## Match._advance_simulation_tick() calls this with the command it just
## drained and executed, plus the result CommandExecutor computed, so the
## "N orders stopped" status this controller used to emit synchronously can
## still be emitted -- just no longer on the same frame as the click.
##
## With input_delay_ticks == 0 (phase 2's single-player default, see
## SimCommandBus) that lag is at most one tick, effectively invisible. Once
## phase 5 raises the delay for real network play, this necessarily arrives
## noticeably late relative to the click that caused it, and hiding that gap
## behind an optimistic guess of the outcome is phase 6's job, not this
## method's -- see decision 8 and "Layering" in
## docs/architecture/network-multiplayer.md ("the acknowledgement is
## cosmetic and immediate ... while the order itself executes on its
## scheduled tick"). Nothing here may guess ahead of the tick; it only
## reports what CommandExecutor already found to be true.
func on_command_executed(command: SimCommand, result: Dictionary) -> void:
	match command.type_id():
		SimStopCommandScript.TYPE_ID:
			_emit_stop_status(int(result.get("stopped", 0)))


## The first `D` binding in the project. Applies to every selected
## controllable entity the deployment controller can handle: toggles the MCV
## (deploy into its Construction Yard) as well as the combat-deploy units
## (Kindjal/Mortar/Kobra, toggling stationary combat mode both ways).
func _deploy_selected_entities() -> void:
	if _deployment_controller == null:
		return
	var messages: Array[String] = []
	for entity in _controllable_entities():
		if not entity.is_in_group("units"):
			continue
		if not _deployment_controller.has_method("can_handle") \
		or not bool(_deployment_controller.call("can_handle", entity)):
			continue
		var result: Dictionary = _deployment_controller.call("try_deploy", entity)
		if not bool(result.get("handled", false)):
			continue
		var message := String(result.get("message", ""))
		if not message.is_empty():
			messages.append(message)
	if not messages.is_empty():
		status_changed.emit(" | ".join(messages))


func _select_units_in_rectangle(rectangle: Rect2) -> void:
	var selected: Array[Node] = []
	for unit in get_tree().get_nodes_in_group("units"):
		if not _can_control(unit):
			continue
		var screen_position = _screen_position_for_entity(unit)
		if screen_position is Vector2 and rectangle.has_point(screen_position):
			selected.append(unit)
	_set_selection(selected)
	status_changed.emit("")


func _command_at(screen_position: Vector2, force_attack: bool) -> void:
	if _selected_entities.is_empty():
		return
	var entity_hit := _raycast(screen_position, ENTITY_SELECTION_COLLISION_MASK)
	var target_entity = _find_selectable_entity(entity_hit.get("collider") as Node)
	if target_entity != null and (force_attack or _is_enemy_target(target_entity)):
		_issue_attack_order(target_entity)
		return
	if force_attack:
		var terrain_hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
		if terrain_hit.is_empty():
			status_changed.emit("No attack target")
			return
		_issue_attack_order(terrain_hit["position"] as Vector3)
		return
	_command_move(screen_position, target_entity)


func _issue_attack_order(target_or_position: Variant) -> void:
	var accepted: Array[Node] = []
	for entity in _selected_entities:
		if not _can_control(entity):
			status_changed.emit("Cannot command this player")
			return
		if entity.has_method("is_deploying") and bool(entity.call("is_deploying")):
			continue
		if not _can_attack(entity, target_or_position):
			continue
		if bool(entity.call("command_attack", target_or_position)):
			accepted.append(entity)
	if accepted.is_empty():
		status_changed.emit("Selected units cannot attack this target")
		return
	_assign_attack_arcs(accepted, target_or_position)
	_play_voice_feedback(&"Attack", accepted)
	if target_or_position is Vector3:
		var target: Vector3 = target_or_position
		var label := "Attacking ground at %.1f, %.1f" % [target.x, target.z]
		if accepted.size() > 1:
			label += " with %d units" % accepted.size()
		status_changed.emit(label)
		return
	var target_name := _command_target_name(target_or_position)
	var label := "Attacking %s" % target_name
	if accepted.size() > 1:
		label += " with %d units" % accepted.size()
	status_changed.emit(label)


## Spreads one attack command into an arc around the target.
##
## An attack order is otherwise entirely per-unit: every shooter runs the same
## perch search, converges on the same cell, and the first arrivals stop on the
## max-range ring and wall the rest out of weapon range. Handing each unit its
## own bearing is what turns that queue into a firing line -- see
## AttackArcAllocator for the geometry.
##
## Left alone deliberately: a lone shooter (nothing to spread), a building or
## other stationary attacker (no bearing to take), and anything that cannot
## engage this target at all.
func _assign_attack_arcs(accepted: Array[Node], target_or_position: Variant) -> void:
	if _navigation == null or not _navigation.has_method("assign_attack_arcs"):
		return
	var target := Vector3.INF
	if target_or_position is Vector3:
		target = target_or_position
	elif target_or_position is Node3D:
		target = (target_or_position as Node3D).global_position
	if not target.is_finite():
		return
	var shooters: Array[Node3D] = []
	# The pitch is measured on the tightest arc anyone will actually stand on,
	# so the shortest engagement range in the group wins.
	var engagement_radius := INF
	for entity in accepted:
		var unit := entity as Node3D
		if unit == null or not unit.has_method("attack_engagement_radius") \
		or not unit.has_method("set_attack_arc_direction"):
			continue
		var radius := float(unit.call("attack_engagement_radius", target_or_position))
		if radius <= 0.0:
			continue
		shooters.append(unit)
		engagement_radius = minf(engagement_radius, radius)
	if shooters.size() <= 1 or not is_finite(engagement_radius):
		return
	_navigation.call("assign_attack_arcs", shooters, target, engagement_radius)


func _command_target_name(target_or_position: Variant) -> String:
	if not target_or_position is Object:
		return "target"
	var target_object := target_or_position as Object
	for property in target_object.get_property_list():
		if StringName(String(property.get("name", ""))) != &"config_id":
			continue
		var config_name := String(target_object.get(&"config_id"))
		if not config_name.is_empty():
			return config_name
		break
	return String((target_object as Node).name) if target_object is Node else "target"


func _command_move(screen_position: Vector2, target_entity = null) -> void:
	if _selected_entities.is_empty():
		return

	var partition := _partition_selection()
	if partition.foreign:
		status_changed.emit("Cannot command this player")
		return
	var movable_entities := partition.movable
	var rally_buildings := partition.rally
	var deploying_entities := partition.immobilized
	if partition.is_empty():
		if deploying_entities > 0:
			status_changed.emit(
				"Unit cannot move while deployed" if deploying_entities == 1
				else "%d units cannot move while deployed" % deploying_entities
			)
		return

	var hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
	if hit.is_empty():
		return

	var target: Vector3 = hit["position"]
	if not _can_interact_with(target_entity) and not _can_issue_movement_order(target):
		status_changed.emit("Cannot move to %.1f, %.1f" % [target.x, target.z])
		return
	var move_mode := (
		NavConstantsScript.MoveMode.FORMATION
		if _formation_modifier_down
		else NavConstantsScript.MoveMode.FREE
	)
	var ordinary_rally_buildings: Array[Node] = []
	var undeployment_messages: Array[String] = []
	for building in rally_buildings:
		var undeployment := _request_undeployment(building, target, move_mode)
		if undeployment.is_empty():
			ordinary_rally_buildings.append(building)
			continue
		undeployment_messages.append(String(undeployment.get("message", "")))
	rally_buildings = ordinary_rally_buildings
	if movable_entities.is_empty():
		for building in rally_buildings:
			building.call("set_rally_point", target)
		var labels: Array[String] = []
		if not rally_buildings.is_empty():
			var rally_label := "Rally point set to %.1f, %.1f" % [target.x, target.z]
			if rally_buildings.size() > 1:
				rally_label = "Rally point set for %d buildings" % rally_buildings.size()
			labels.append(rally_label)
		labels.append_array(undeployment_messages)
		if not labels.is_empty():
			status_changed.emit(" | ".join(labels))
		return

	var target_cell := Vector2i(-1, -1)
	var spice_target := false
	if _terrain != null and _terrain.navigation_grid != null and _terrain.navigation_grid.is_loaded():
		target_cell = _terrain.navigation_grid.world_to_grid(target)
		spice_target = _terrain.spice_layer != null and bool(_terrain.spice_layer.call("has_spice", target_cell))

	var harvesting_entities: Array[Node] = []
	var unloading_entities: Array[Node] = []
	var moving_entities: Array[Node] = []
	for entity in movable_entities:
		var can_unload := target_entity != null \
			and entity.has_method("can_unload_at") \
			and bool(entity.call("can_unload_at", target_entity)) \
			and entity.has_method("command_unload")
		if can_unload and _terrain != null and _terrain.navigation_grid != null \
		and bool(entity.call(
			"command_unload", target_entity, _terrain.navigation_grid, _terrain.spice_layer
		)):
			unloading_entities.append(entity)
			continue
		var can_harvest := entity.has_method("can_harvest_spice") \
			and bool(entity.call("can_harvest_spice")) \
			and entity.has_method("command_harvest")
		if spice_target and can_harvest \
		and bool(entity.call("command_harvest", _terrain.spice_layer, _terrain.navigation_grid, target_cell)):
			harvesting_entities.append(entity)
			continue
		moving_entities.append(entity)

	if not moving_entities.is_empty():
		if _navigation != null:
			_navigation.command_move(moving_entities, target, move_mode)
		else:
			for entity in moving_entities:
				entity.move_to(target)
	var feedback_entities: Array[Node] = []
	feedback_entities.append_array(moving_entities)
	feedback_entities.append_array(harvesting_entities)
	feedback_entities.append_array(unloading_entities)
	_play_voice_feedback(&"Move", feedback_entities)
	var nav_status := ""
	if target_cell.x >= 0:
		var debug: Dictionary = _terrain.navigation_grid.cell_debug(target_cell)
		nav_status = " | nav %s tile %s terrain %s" % [
			str(target_cell),
			str(debug.get("source_tile", "?")),
			str(debug.get("terrain_name", "?")),
		]
	var movement_label := _movement_label(
		target, target_entity, unloading_entities, harvesting_entities, moving_entities
	)
	var formation_status := " | formation" \
		if not moving_entities.is_empty() and move_mode == NavConstantsScript.MoveMode.FORMATION else ""
	var deployment_status := " | %d unit(s) cannot move while deployed" % deploying_entities \
		if deploying_entities > 0 else ""
	var undeployment_status := " | %s" % " | ".join(undeployment_messages) \
		if not undeployment_messages.is_empty() else ""
	status_changed.emit("%s%s%s%s%s" % [
		movement_label, nav_status, formation_status, deployment_status, undeployment_status
	])


## What the order turned out to be. One click can split the selection three
## ways, so the label names whatever dominates -- unloading, then harvesting,
## then plain movement -- and counts the rest as "other units".
func _movement_label(
	target: Vector3,
	target_entity,
	unloading_entities: Array[Node],
	harvesting_entities: Array[Node],
	moving_entities: Array[Node]
) -> String:
	var others := " | moving %d other units" % moving_entities.size() \
		if not moving_entities.is_empty() else ""
	if not unloading_entities.is_empty():
		var refinery := String(target_entity.name)
		if unloading_entities.size() > 1:
			return "Unloading %d harvesters at %s%s" % [
				unloading_entities.size(), refinery, others
			]
		return "Unloading at %s%s" % [refinery, others]
	if not harvesting_entities.is_empty():
		if harvesting_entities.size() > 1:
			return "Harvesting spice with %d units at %.1f, %.1f%s" % [
				harvesting_entities.size(), target.x, target.z, others
			]
		return "Harvesting spice at %.1f, %.1f%s" % [target.x, target.z, others]
	if moving_entities.size() > 1:
		return "Moving %d units to %.1f, %.1f" % [moving_entities.size(), target.x, target.z]
	return "Moving to %.1f, %.1f" % [target.x, target.z]


## One classification pass over the selection, shared by the move command and
## by the two guards that answer whether a move order is possible at all.
func _partition_selection() -> SelectionPartition:
	var partition := SelectionPartitionScript.new()
	for entity in _selected_entities:
		if not is_instance_valid(entity):
			continue
		if not _can_control(entity):
			partition.foreign = true
			continue
		var can_move: bool = entity.has_method("move_to")
		var can_rally: bool = not can_move \
			and (_can_set_rally_point(entity) or _can_undeploy(entity))
		partition.movement_capable = partition.movement_capable or can_move or can_rally
		if _is_immobilized_by_deployment(entity):
			partition.immobilized += 1
			continue
		if can_move:
			partition.movable.append(entity)
		elif can_rally:
			partition.rally.append(entity)
	return partition


## The selection reduced to what this player may actually command. Seven guards
## used to open with this same pair of checks inline.
func _controllable_entities() -> Array[Node]:
	var result: Array[Node] = []
	for entity in _selected_entities:
		if is_instance_valid(entity) and _can_control(entity):
			result.append(entity)
	return result


func _request_undeployment(entity: Node, target: Vector3, move_mode: int) -> Dictionary:
	if _deployment_controller == null or not entity.is_in_group("buildings") \
	or not _deployment_controller.has_method("try_undeploy"):
		return {}
	var result: Dictionary = _deployment_controller.call(
		"try_undeploy", entity, target, move_mode
	)
	return result if bool(result.get("handled", false)) else {}


func _is_formation_modifier(event: InputEventKey) -> bool:
	return event.keycode == KEY_J or event.physical_keycode == KEY_J


func _is_attack_modifier(event: InputEventKey) -> bool:
	return event.keycode == KEY_CTRL or event.physical_keycode == KEY_CTRL


func _clear_selection() -> void:
	for entity in _selected_entities:
		if is_instance_valid(entity):
			var callback := Callable(self, "_on_selected_entity_exiting").bind(entity)
			if entity.tree_exiting.is_connected(callback):
				entity.tree_exiting.disconnect(callback)
			entity.set_selected(false)
	_selected_entities.clear()


func _set_selection(entities: Array[Node]) -> void:
	_clear_selection()
	_selected_orders_active = -1
	for entity in entities:
		if entity == null or not is_instance_valid(entity):
			continue
		_selected_entities.append(entity)
		entity.set_selected(true)
		var callback := Callable(self, "_on_selected_entity_exiting").bind(entity)
		if not entity.tree_exiting.is_connected(callback):
			entity.tree_exiting.connect(callback, CONNECT_ONE_SHOT)
	_target_abilities.selection_changed(_selected_entities)
	_play_voice_feedback(&"Selection", _selected_entities)


func has_active_target_ability() -> bool:
	return _target_abilities.is_active()


func cancel_target_ability() -> void:
	_target_abilities.cancel()


func _prune_uncommandable_selection() -> void:
	var retained: Array[Node] = []
	var changed := false
	for entity in _selected_entities:
		var retain_selection := is_instance_valid(entity) and (
			not entity.has_method("can_remain_selected") \
			or bool(entity.call("can_remain_selected"))
		)
		if retain_selection:
			retained.append(entity)
		else:
			if is_instance_valid(entity):
				var callback := Callable(self, "_on_selected_entity_exiting").bind(entity)
				if entity.tree_exiting.is_connected(callback):
					entity.tree_exiting.disconnect(callback)
				entity.set_selected(false)
			changed = true
	if changed:
		_selected_entities = retained
		_target_abilities.selection_changed(_selected_entities)


func _on_target_ability_status_changed(status: String) -> void:
	status_changed.emit(status)


func _on_target_ability_mode_changed(ability_id: StringName) -> void:
	target_ability_mode_changed.emit(not ability_id.is_empty())
	if ability_id.is_empty():
		_clear_command_cursor()


func _execute_target_ability(screen_position: Vector2) -> void:
	var entity_hit := _raycast(screen_position, ENTITY_SELECTION_COLLISION_MASK)
	var target = _find_selectable_entity(entity_hit.get("collider") as Node)
	var terrain_hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
	var position: Vector3 = terrain_hit.get("position", Vector3.INF)
	_target_abilities.execute(target, position)


func _update_target_ability_cursor(screen_position: Vector2) -> void:
	var cursors: Variant = _cursor_manager()
	if cursors == null:
		return
	var entity_hit := _raycast(screen_position, ENTITY_SELECTION_COLLISION_MASK)
	var target = _find_selectable_entity(entity_hit.get("collider") as Node)
	var terrain_hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
	var position: Vector3 = terrain_hit.get("position", Vector3.INF)
	cursors.set_override(
		COMMAND_CURSOR_OVERRIDE,
		_target_abilities.cursor_for(target, position),
		COMMAND_CURSOR_PRIORITY
	)


func _play_voice_feedback(kind: StringName, entities: Array[Node]) -> void:
	if _voice_player == null or AudioServer.get_driver_name() == "Dummy":
		return
	var units: Array[Node] = []
	for entity in entities:
		if entity != null and is_instance_valid(entity) and entity.is_in_group("units"):
			units.append(entity)
	if units.is_empty():
		return
	var owner = units.front().call("owner_player") if units.front().has_method("owner_player") else null
	if owner == null:
		return
	var profile: UnitVoiceProfile
	if units.size() > 1:
		profile = _voice_catalog.group_profile_for_house(owner.house_id)
	else:
		var definition = units.front().get("unit_definition")
		profile = _voice_catalog.profile_for_unit(definition, owner.house_id)
	if profile == null:
		return
	var event_path := ""
	match kind:
		&"Selection":
			event_path = profile.selection_event_path
		&"Move":
			event_path = profile.move_event_path
		&"Attack":
			event_path = profile.attack_event_path
	if event_path.is_empty():
		return
	_voice_player.play_event(load(event_path) as SoundEvent)


func _on_selected_entity_exiting(entity: Node) -> void:
	_selected_entities.erase(entity)
	_target_abilities.selection_changed(_selected_entities)
	_selected_orders_active = -1
	status_changed.emit("")


func _update_hover(screen_position: Vector2) -> void:
	var hovered = null
	var hit := _raycast(screen_position)
	if not hit.is_empty():
		hovered = _find_selectable_entity(hit.get("collider") as Node)
	if hovered == _hovered_entity:
		return
	if _hovered_entity != null and _hovered_entity.has_method("set_hovered"):
		_hovered_entity.set_hovered(false)
	_hovered_entity = hovered
	if _hovered_entity != null and _hovered_entity.has_method("set_hovered"):
		_hovered_entity.set_hovered(true)


func _update_command_cursor(screen_position: Vector2) -> void:
	var cursors: Variant = _cursor_manager()
	if cursors == null:
		return
	var cursor := _command_cursor_at(screen_position)
	if cursor == NO_CURSOR_OVERRIDE:
		_clear_command_cursor()
	else:
		cursors.set_override(COMMAND_CURSOR_OVERRIDE, cursor, COMMAND_CURSOR_PRIORITY)


func _clear_command_cursor() -> void:
	var cursors: Variant = _cursor_manager()
	if cursors != null:
		cursors.clear_override(COMMAND_CURSOR_OVERRIDE)


func _command_cursor_at(screen_position: Vector2) -> int:
	if _is_dragging():
		return NO_CURSOR_OVERRIDE
	var entity_hit := _raycast(screen_position, ENTITY_SELECTION_COLLISION_MASK)
	var entity = _find_selectable_entity(entity_hit.get("collider") as Node)
	var entity_attack_intent := entity != null \
		and (_attack_modifier_down or _is_enemy_target(entity))
	if entity_attack_intent:
		return CursorManagerScript.CursorType.ATTACK \
			if _can_issue_attack_order(entity) else NO_CURSOR_OVERRIDE
	var deployment_cursor := _deployment_cursor_for(entity)
	if deployment_cursor != NO_CURSOR_OVERRIDE:
		return deployment_cursor
	if _can_interact_with(entity):
		return CursorManagerScript.CursorType.ENTER
	if entity != null and not _selected_entities.has(entity) and _can_control(entity):
		return CursorManagerScript.CursorType.OVER_UNIT
	if _selected_entities.is_empty():
		return NO_CURSOR_OVERRIDE
	return _terrain_command_cursor_at(screen_position)


## Resolve terrain orders by intent before considering movement capabilities.
## A stationary entity can still contribute an attack-ground command, while
## ordinary terrain hover remains silent when no move/rally command exists.
func _terrain_command_cursor_at(screen_position: Vector2) -> int:
	if _attack_modifier_down:
		var attack_hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
		if attack_hit.is_empty():
			return NO_CURSOR_OVERRIDE
		var attack_target: Vector3 = attack_hit["position"]
		return CursorManagerScript.CursorType.ATTACK \
			if _can_issue_attack_order(attack_target) else NO_CURSOR_OVERRIDE

	if not _has_movement_or_rally_selection():
		return NO_CURSOR_OVERRIDE
	var terrain_hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
	if terrain_hit.is_empty():
		if _has_rally_point_selection():
			return CursorManagerScript.CursorType.CANT_PLACE_FLAG
		return CursorManagerScript.CursorType.CANT_MOVE
	var target: Vector3 = terrain_hit["position"]
	if not _can_issue_movement_order(target):
		if _has_rally_point_selection():
			return CursorManagerScript.CursorType.CANT_PLACE_FLAG
		return CursorManagerScript.CursorType.CANT_MOVE
	if _has_rally_point_selection():
		return CursorManagerScript.CursorType.PLACE_FLAG
	if _can_gather_at(target):
		return CursorManagerScript.CursorType.ATTACK
	return CursorManagerScript.CursorType.MOVE


func _can_issue_attack_order(target_or_position: Variant) -> bool:
	for entity in _controllable_entities():
		if entity.has_method("is_deploying") and bool(entity.call("is_deploying")):
			continue
		if _can_attack(entity, target_or_position):
			return true
	return false


func _can_attack(entity: Node, target_or_position: Variant) -> bool:
	if not entity.has_method("command_attack") or not entity.has_method("can_attack"):
		return false
	return bool(entity.call("can_attack", target_or_position))


func _is_enemy_target(target) -> bool:
	if target == null:
		return false
	var players = _players()
	if players == null:
		return false
	var owner_id := PlayerDataScript.NEUTRAL_PLAYER_ID
	if target.has_method("combat_owner_player_id"):
		owner_id = int(target.call("combat_owner_player_id"))
	elif target.has_method("owner_player"):
		var target_owner = target.call("owner_player")
		if target_owner != null:
			owner_id = int(target_owner.player_id)
	return players.relation_between(players.local_player_id, owner_id) \
		== PlayerDataScript.Relation.ENEMY


func _can_interact_with(target) -> bool:
	if target == null or not target.is_in_group("buildings"):
		return false
	for entity in _controllable_entities():
		if entity.has_method("can_unload_at") and entity.has_method("command_unload") \
		and bool(entity.call("can_unload_at", target)):
			return true
	return false


func _deployment_cursor_for(entity) -> int:
	if not entity is Node3D \
	or _selected_entities.size() != 1 \
	or _selected_entities.front() != entity \
	or not _can_control(entity) \
	or _deployment_controller == null \
	or not _deployment_controller.has_method("can_handle") \
	or not bool(_deployment_controller.call("can_handle", entity)):
		return NO_CURSOR_OVERRIDE

	# The combat-deploy check (a handful of state-flag reads, no world
	# validation) is cheap enough to resolve every call; only the MCV's
	# BuildingPlacement footprint probe below needs the throttle.
	if _deployment_controller.has_method("is_combat_deploy_candidate") \
	and bool(_deployment_controller.call("is_combat_deploy_candidate", entity)):
		return _deploy_cursor_for(entity)

	# A full Construction Yard footprint check is expensive. It is only needed
	# while the pointer is over the one selected MCV, and its cursor result does
	# not need frame-rate resolution while that unit moves across the grid.
	var entity_id: int = entity.get_instance_id()
	var now_msec: int = _cursor_time_msec()
	if entity_id != _deployment_cursor_entity_id \
	or _deployment_cursor_result == NO_CURSOR_OVERRIDE \
	or now_msec - _deployment_cursor_last_check_msec >= DEPLOYMENT_CURSOR_CHECK_INTERVAL_MSEC:
		_deployment_cursor_entity_id = entity_id
		_deployment_cursor_last_check_msec = now_msec
		_deployment_cursor_result = _deploy_cursor_for(entity)
	return _deployment_cursor_result


## Whether the deployment controller would accept a deploy order right now.
## Both branches of _deployment_cursor_for() ask this -- the cheap combat check
## every call, the MCV's footprint probe on a throttle -- and both answer it
## the same way.
func _deploy_cursor_for(entity) -> int:
	return (
		CursorManagerScript.CursorType.DEPLOY
		if _deployment_controller.has_method("can_issue_deploy")
		and bool(_deployment_controller.call("can_issue_deploy", entity))
		else CursorManagerScript.CursorType.CANT_DEPLOY
	)


func _cursor_time_msec() -> int:
	return Time.get_ticks_msec()


func _can_gather_at(target: Vector3) -> bool:
	if _terrain == null or _terrain.navigation_grid == null \
	or not _terrain.navigation_grid.is_loaded() or _terrain.spice_layer == null:
		return false
	var target_cell: Vector2i = _terrain.navigation_grid.world_to_grid(target)
	if not bool(_terrain.spice_layer.call("has_spice", target_cell)):
		return false
	for entity in _controllable_entities():
		if entity.has_method("can_harvest_spice") and entity.has_method("command_harvest") \
		and bool(entity.call("can_harvest_spice")):
			return true
	return false


## Both transition states and the fully-deployed state reject movement: a
## combat-deployed unit (Kindjal/Mortar/Kobra) is immobile for its whole
## DEPLOYING -> DEPLOYED -> UNDEPLOYING span, not just while transitioning.
func _is_immobilized_by_deployment(entity: Node) -> bool:
	return (
		(entity.has_method("is_deploying") and bool(entity.call("is_deploying")))
		or (entity.has_method("is_deployed") and bool(entity.call("is_deployed")))
	)


func _can_issue_movement_order(target: Vector3) -> bool:
	var partition := _partition_selection()
	if not partition.rally.is_empty():
		return true
	if partition.movable.is_empty():
		return false
	if _navigation != null and _navigation.has_method("can_move_to"):
		return bool(_navigation.call("can_move_to", partition.movable, target))
	return true


func _has_rally_point_selection() -> bool:
	for entity in _controllable_entities():
		if _can_set_rally_point(entity):
			return true
	return false


## Note this ignores deployment: a selected Kindjal that is currently deployed
## still counts, so the cursor reports "cannot move there" rather than dropping
## its override and looking like an unrelated selection.
func _has_movement_or_rally_selection() -> bool:
	return _partition_selection().movement_capable


func _can_undeploy(entity: Node) -> bool:
	return _deployment_controller != null and entity.is_in_group("buildings") \
		and _deployment_controller.has_method("can_undeploy") \
		and bool(_deployment_controller.call("can_undeploy", entity))


func _can_set_rally_point(entity: Node) -> bool:
	if not entity.has_method("set_rally_point"):
		return false
	return not entity.has_method("can_set_rally_point") \
		or bool(entity.call("can_set_rally_point"))


func _find_selectable_entity(node: Node):
	var current := node
	while current != null:
		if current.is_in_group("units") or current.is_in_group("buildings"):
			# This resolver is also used by attacks and target abilities, not just
			# selection.  A carried cargo is unselectable/command-locked through
			# the later control checks but must remain a damageable target.
			return current
		current = current.get_parent()
	return null


func _screen_position_for_entity(entity):
	if _camera == null or not entity is Node3D:
		return null
	if _camera.is_position_behind(entity.global_position):
		return null
	return _camera.unproject_position(entity.global_position)


## Default mask covers terrain (bit 1) and units/buildings (bit 2) only —
## corpses sit on their own bit 3 (see DeathCorpse) and must never block a
## click aimed at a unit standing behind one.
func _raycast(screen_position: Vector2, collision_mask: int = 3) -> Dictionary:
	if _camera == null:
		return {}

	return TerrainProbeScript.screen_pick(
		_camera, get_viewport().get_world_3d(), screen_position, collision_mask
	)


func _can_control(unit) -> bool:
	var players = _players()
	return players != null and unit.is_owned_by(players.local_player_id) \
		and (not unit.has_method("can_receive_commands") or bool(unit.call("can_receive_commands")))


func _owner_status(unit) -> String:
	var unit_owner = unit.owner_player()
	if unit_owner == null:
		return "owner: missing"
	if unit_owner.is_neutral:
		return "owner: neutral"

	var players = _players()
	var relation := "unknown"
	if players != null:
		match players.relation_between(players.local_player_id, unit_owner.player_id):
			PlayerDataScript.Relation.ALLY:
				relation = "ally"
			PlayerDataScript.Relation.ENEMY:
				relation = "enemy"
			_:
				relation = "neutral"

	var faction := String(unit_owner.house_id)
	if unit_owner.has_subhouses():
		var subhouses := []
		for subhouse_id in unit_owner.subhouse_ids:
			subhouses.append(String(subhouse_id))
		faction += "/%s" % ", ".join(subhouses)
	return "owner: %s (%s, %s)" % [unit_owner.nickname, faction, relation]


func _players():
	return AutoloadLookupScript.roster(self)


func _cursor_manager() -> Variant:
	return AutoloadLookupScript.cursors(self)
