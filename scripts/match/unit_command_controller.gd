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
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")
const SimAttackCommandScript := preload("res://scripts/sim/commands/attack_command.gd")
const SelectionClassifierScript := preload("res://scripts/match/selection_classifier.gd")

var _camera: Camera3D
var _terrain: MapLoader
var _selection_rectangle = null
var _navigation
var _deployment_controller
## The command bus this controller submits SimCommands to, and a matching
## way to ask "what tick would a command submitted right now target" --
## injected together, in production by Match._setup_unit_command_controller()
## and in tests by tests/match/support/command_pump.gd (see CommandPump.bus()
## and .next_orderable_tick()), the same way camera/terrain/navigation are.
## A controller built with neither wired in may still be driven for
## selection/hover/cursor cases -- most of tests/match/unit_command_run.gd
## never issues a command -- but asking it to issue one is a wiring mistake,
## not a supported mode; see _stop_selected_entities()'s guard.
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
## vs "simulation"). This only resolves the current selection to stable
## entity ids and submits one SimStopCommand; cancelling the orders
## themselves, and therefore knowing how many actually stopped, only happens
## once CommandExecutor._execute_stop() runs on the tick this command is
## scheduled for (see on_command_executed() for how that result finds its way
## back to status_changed).
##
## A controller with no command bus wired in is a wiring mistake, not a
## supported mode -- see the _command_bus field comment. Every suite that
## exercises this method wires one in via tests/match/support/command_pump.gd;
## the loud failure below is what would have caught the alternative (silently
## dropping the order, or silently reviving the pre-command-bus immediate
## cancel this method used to fall back to).
func _stop_selected_entities() -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"UnitCommandController._stop_selected_entities(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_unit_command_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
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
		SimMoveCommandScript.TYPE_ID:
			_emit_move_status(command as SimMoveCommand, result)
		SimAttackCommandScript.TYPE_ID:
			_emit_attack_status(result)


## The feedback half of the Move split (see _command_move()): assembles
## exactly the status text and voice line _command_move() used to build
## inline, now from the result CommandExecutor._execute_move() computed
## against the tick this command was scheduled for, plus the two fields
## (target, move_mode) that are plain data on the command itself and need no
## resolution against the world at all.
##
## "had_movable" absent (false) is CommandExecutor's signal for the branch
## _command_move() used to take when partition.movable was empty outright --
## a rally-point-or-nothing order, never a moving/harvesting/unloading one --
## see _execute_move()'s doc comment for why that flag exists instead of
## being inferred from the three entity arrays.
func _emit_move_status(command: SimMoveCommand, result: Dictionary) -> void:
	if bool(result.get("rejected", false)):
		var target := command.target
		status_changed.emit("Cannot move to %.1f, %.1f" % [target.x, target.z])
		return

	var deploying_entities := int(result.get("deploying", 0))
	var rally_buildings: Array = result.get("rally_buildings", [])
	var undeployment_messages: Array = result.get("undeployment_messages", [])

	if not bool(result.get("had_movable", false)):
		if rally_buildings.is_empty() and undeployment_messages.is_empty():
			if deploying_entities > 0:
				status_changed.emit(
					"Unit cannot move while deployed" if deploying_entities == 1
					else "%d units cannot move while deployed" % deploying_entities
				)
			return
		var labels: Array[String] = []
		if not rally_buildings.is_empty():
			var rally_target := command.target
			var rally_label := "Rally point set to %.1f, %.1f" % [rally_target.x, rally_target.z]
			if rally_buildings.size() > 1:
				rally_label = "Rally point set for %d buildings" % rally_buildings.size()
			labels.append(rally_label)
		for message in undeployment_messages:
			labels.append(String(message))
		if not labels.is_empty():
			status_changed.emit(" | ".join(labels))
		return

	var moving_entities: Array[Node] = result.get("moving_entities", [])
	var harvesting_entities: Array[Node] = result.get("harvesting_entities", [])
	var unloading_entities: Array[Node] = result.get("unloading_entities", [])
	var target_entity: Node = result.get("target_entity", null)

	var feedback_entities: Array[Node] = []
	feedback_entities.append_array(moving_entities)
	feedback_entities.append_array(harvesting_entities)
	feedback_entities.append_array(unloading_entities)
	_play_voice_feedback(&"Move", feedback_entities)

	var target := command.target
	# Mirrors _command_move()'s old nav-debug computation exactly, reading
	# _terrain -- a Node this controller already holds for cursor purposes,
	# not anything CommandExecutor resolved -- against the command's plain
	# Vector3 target. It stays here, view-side, rather than in the result:
	# it is debug/cosmetic text about static terrain data, not a verdict
	# about the command's effect.
	var target_cell := Vector2i(-1, -1)
	if _terrain != null and _terrain.navigation_grid != null and _terrain.navigation_grid.is_loaded():
		target_cell = _terrain.navigation_grid.world_to_grid(target)
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
		if not moving_entities.is_empty() and command.move_mode == NavConstantsScript.MoveMode.FORMATION else ""
	var deployment_status := " | %d unit(s) cannot move while deployed" % deploying_entities \
		if deploying_entities > 0 else ""
	var undeployment_status := " | %s" % " | ".join(undeployment_messages) \
		if not undeployment_messages.is_empty() else ""
	status_changed.emit("%s%s%s%s%s" % [
		movement_label, nav_status, formation_status, deployment_status, undeployment_status
	])


## The feedback half of the Attack split (see _issue_attack_order()):
## assembles exactly the status text and voice line _issue_attack_order() used
## to build inline, now from the result CommandExecutor._execute_attack()
## computed against the tick this command was scheduled for.
##
## "rejected" (accepted list came back empty) is the only failure case --
## there is no equivalent of Move's "Cannot move to ..." because an attack
## order's target is never itself invalid the way a movement destination can
## be; every unit either individually can or cannot engage it.
func _emit_attack_status(result: Dictionary) -> void:
	if bool(result.get("rejected", false)):
		status_changed.emit("Selected units cannot attack this target")
		return
	var accepted: Array[Node] = result.get("accepted", [])
	_play_voice_feedback(&"Attack", accepted)
	var target_or_position = result.get("target_or_position")
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


## Right-click-on-an-enemy and Ctrl-click-on-the-ground both land here, and
## both are the same order -- SimAttackCommand distinguishes them only by
## whether target_entity_id is nonzero (see that class's doc comment), so
## this function makes exactly one issue-time decision (which of the two this
## click was) and hands both cases to the same _issue_attack_order().
func _command_at(screen_position: Vector2, force_attack: bool) -> void:
	if _selected_entities.is_empty():
		return
	var entity_hit := _raycast(screen_position, ENTITY_SELECTION_COLLISION_MASK)
	var target_entity = _find_selectable_entity(entity_hit.get("collider") as Node)
	if target_entity != null and (force_attack or _is_enemy_target(target_entity)):
		_issue_attack_order(target_entity, entity_hit.get("position", Vector3.ZERO) as Vector3)
		return
	if force_attack:
		var terrain_hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
		if terrain_hit.is_empty():
			status_changed.emit("No attack target")
			return
		_issue_attack_order(null, terrain_hit["position"] as Vector3)
		return
	_command_move(screen_position, target_entity)


## The issue side of Attack: immediate, and split from execution -- see
## _stop_selected_entities()'s doc comment for the same split done once
## already, and docs/architecture/network-multiplayer.md, "Layering".
## `target_entity` null means attack-ground at `position`; non-null means an
## entity-target attack, with `position` carried alongside it purely as the
## dead-target fallback described on SimAttackCommand.target_entity_id's doc
## comment.
##
## What stays here: the selection, and resolving entity_ids from
## _controllable_entities() -- exactly like _stop_selected_entities() and
## _command_move(), a foreign or uncontrollable unit is silently excluded from
## entity_ids, never an aborted order the way an older, pre-command-bus
## version of this method used to abort with "Cannot command this player" the
## moment it hit one. Every per-entity attack verdict -- is_deploying(),
## can_attack(), command_attack() itself, and arc assignment -- moves to
## CommandExecutor._execute_attack(), because whether a unit can attack this
## target is a verdict about the world that must be read identically by every
## client on the tick the order actually executes, not at the click that
## merely scheduled it.
func _issue_attack_order(target_entity, position: Vector3) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"UnitCommandController._issue_attack_order(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_unit_command_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
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
	var command := SimAttackCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.entity_ids = entity_ids
	command.target = position
	if target_entity != null and &"entity_id" in target_entity:
		command.target_entity_id = int(target_entity.get(&"entity_id"))
	_command_bus.submit(command, _submit_tick_provider.call())


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


## The issue side of Move: immediate, and split from execution on purpose --
## see _stop_selected_entities()'s doc comment for the same split done once
## already, and docs/architecture/network-multiplayer.md, "Layering". Unlike
## Stop, one click here can fan out into a plain move, a harvest order, an
## unload order, a rally point, or an undeployment request, often several at
## once for one selection -- but every one of those is a verdict about the
## world (can this entity reach that target, is it still deployed, is there
## spice under the cursor), and the command executes on a later tick than the
## click, so the verdict has to be read from the world as it stands on that
## tick, identically on every client. That is why _partition_selection(),
## _can_issue_movement_order() and the harvest/unload classification loop
## that used to live here moved to CommandExecutor._execute_move() instead of
## staying inline: at input delay 0 (phase 2's single-player default) reading
## the world now versus reading it next tick coincide, but the moment phase 5
## raises the delay, a verdict computed here would be a per-client decision,
## which is a desync.
##
## What stays here is what genuinely cannot move: the selection, the raycast
## that turns screen_position into a world fact, and reading the formation
## modifier -- see the module doc comment at the top of this file for the
## full split. The status text, the voice line and the nav debug string all
## move to on_command_executed() too, for the same reason Stop's did: they
## describe what the command turned out to do, which is only known once
## CommandExecutor has actually done it.
func _command_move(screen_position: Vector2, target_entity = null) -> void:
	if _selected_entities.is_empty():
		return
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"UnitCommandController._command_move(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_unit_command_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
		return
	var hit := _raycast(screen_position, TERRAIN_COLLISION_MASK)
	if hit.is_empty():
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

	var target: Vector3 = hit["position"]
	var move_mode := (
		NavConstantsScript.MoveMode.FORMATION
		if _formation_modifier_down
		else NavConstantsScript.MoveMode.FREE
	)
	var command := SimMoveCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.entity_ids = entity_ids
	command.target = target
	if target_entity != null and &"entity_id" in target_entity:
		command.target_entity_id = int(target_entity.get(&"entity_id"))
	command.move_mode = move_mode
	_command_bus.submit(command, _submit_tick_provider.call())


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


## One classification pass over the selection, shared by the two cursor
## guards that answer whether a move order is possible at all
## (_can_issue_movement_order(), _has_movement_or_rally_selection()). The
## move command itself no longer calls this: it submits every controllable
## entity's id and lets CommandExecutor classify against the world as it
## stands on the execution tick instead -- see _command_move()'s doc
## comment. Every per-entity verdict below comes from _classifier(), the one
## place shared with CommandExecutor's own copy of this loop
## (scripts/match/selection_classifier.gd); only the loop itself -- and the
## foreign/movement_capable bookkeeping CommandExecutor has no use for --
## stays local to this cursor-facing caller.
func _partition_selection() -> SelectionPartition:
	var partition := SelectionPartitionScript.new()
	var classifier := _classifier()
	for entity in _selected_entities:
		if not is_instance_valid(entity):
			continue
		if not _can_control(entity):
			continue
		var can_move := classifier.can_move_directly(entity)
		var can_rally := not can_move \
			and (classifier.can_set_rally_point(entity) or classifier.can_undeploy(entity))
		partition.movement_capable = partition.movement_capable or can_move or can_rally
		if classifier.is_immobilized_by_deployment(entity):
			partition.immobilized += 1
			continue
		if can_move:
			partition.movable.append(entity)
		elif can_rally:
			partition.rally.append(entity)
	return partition


## Fresh every call rather than cached, because _navigation and
## _deployment_controller can each be assigned directly by a test fixture
## outside setup() (see tests/match/unit_command_run.gd) -- a cached
## classifier built once in setup() would silently go stale against that.
func _classifier() -> SelectionClassifier:
	return SelectionClassifierScript.new(_deployment_controller, _navigation)


## The selection reduced to what this player may actually command. Seven guards
## used to open with this same pair of checks inline.
func _controllable_entities() -> Array[Node]:
	var result: Array[Node] = []
	for entity in _selected_entities:
		if is_instance_valid(entity) and _can_control(entity):
			result.append(entity)
	return result


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


## Both per-entity checks below -- the deployment-transition gate and the
## attack verdict itself -- come from _classifier() (scripts/match/
## selection_classifier.gd), the same object CommandExecutor._execute_attack()
## asks the identical two questions of; only this aggregating loop stays
## local, for the reason that file's doc comment gives for keeping every
## bucketing pass with its own caller.
func _can_issue_attack_order(target_or_position: Variant) -> bool:
	var classifier := _classifier()
	for entity in _controllable_entities():
		if classifier.is_deploying(entity):
			continue
		if classifier.can_attack(entity, target_or_position):
			return true
	return false


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
	return _classifier().can_interact_with(_controllable_entities(), target)


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


func _can_issue_movement_order(target: Vector3) -> bool:
	var partition := _partition_selection()
	return _classifier().can_reach(partition.movable, partition.rally, target)


func _has_rally_point_selection() -> bool:
	var classifier := _classifier()
	for entity in _controllable_entities():
		if classifier.can_set_rally_point(entity):
			return true
	return false


## Note this ignores deployment: a selected Kindjal that is currently deployed
## still counts, so the cursor reports "cannot move there" rather than dropping
## its override and looking like an unrelated selection.
func _has_movement_or_rally_selection() -> bool:
	return _partition_selection().movement_capable


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
