extends SceneTree

const UnitCommandControllerScript := preload("res://scripts/match/unit_command_controller.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 1000


class FakeUnit extends Node3D:
	var player = null
	var config_id: StringName
	var selected := false
	var move_targets: Array[Vector3] = []
	var attack_targets: Array = []
	var rejected_attack_targets: Array = []
	var attack_capable := true
	var active_order := false
	var stop_commands := 0

	func set_selected(active: bool) -> void:
		selected = active

	func move_to(target: Vector3) -> void:
		move_targets.append(target)
		active_order = true

	func has_active_order() -> bool:
		return active_order

	func can_attack(target_or_position: Variant) -> bool:
		return attack_capable and target_or_position not in rejected_attack_targets

	func command_attack(target_or_position: Variant) -> bool:
		if not can_attack(target_or_position):
			return false
		attack_targets.append(target_or_position)
		active_order = true
		return true

	func cancel_all_orders() -> bool:
		if not active_order:
			return false
		stop_commands += 1
		active_order = false
		return true

	func is_owned_by(player_id: int) -> bool:
		return player != null and player.player_id == player_id

	func owner_player():
		return player


class FakeHarvester extends FakeUnit:
	var harvest_commands: Array[Dictionary] = []
	var unload_commands: Array[Dictionary] = []
	var cancelled_harvest_orders := 0
	var defer_navigation_orders := false
	var prepared_move_targets: Array[Vector3] = []

	func _init() -> void:
		attack_capable = false

	func can_harvest_spice() -> bool:
		return true


	func command_harvest(spice_layer, navigation_grid, cell: Vector2i) -> bool:
		harvest_commands.append({"spice_layer": spice_layer, "grid": navigation_grid, "cell": cell})
		return true

	func cancel_harvest_order() -> void:
		cancelled_harvest_orders += 1

	func can_unload_at(refinery: Node) -> bool:
		return refinery.has_method("is_refinery") and bool(refinery.call("is_refinery")) \
			and refinery.is_owned_by(player.player_id)

	func command_unload(refinery: Node, navigation_grid, spice_layer = null) -> bool:
		unload_commands.append({
			"refinery": refinery, "grid": navigation_grid, "spice_layer": spice_layer
		})
		return true

	func prepare_navigation_order(target: Vector3, _exit_point := Vector3.INF, _move_mode := 0) -> bool:
		prepared_move_targets.append(target)
		if defer_navigation_orders:
			return false
		cancel_harvest_order()
		return true


class FakeCarriedCargo extends FakeUnit:
	func can_receive_commands() -> bool:
		return false

	func can_remain_selected() -> bool:
		return false


class FakeLockedCarrier extends FakeUnit:
	func can_receive_commands() -> bool:
		return false

	func can_remain_selected() -> bool:
		return true


class FakeBuilding extends Node3D:
	var player = null
	var selected := false
	var rally_points: Array[Vector3] = []
	var refinery := false
	var ai_manufacturing := true
	var attack_capable := false
	var attack_targets: Array = []
	var active_order := false
	var stop_commands := 0

	func set_selected(active: bool) -> void:
		selected = active

	func is_owned_by(player_id: int) -> bool:
		return player != null and player.player_id == player_id

	func owner_player():
		return player

	func set_rally_point(target: Vector3) -> void:
		rally_points.append(target)

	func can_set_rally_point() -> bool:
		return ai_manufacturing

	func is_refinery() -> bool:
		return refinery

	func can_attack(_target_or_position: Variant) -> bool:
		return attack_capable

	func command_attack(target_or_position: Variant) -> bool:
		if not can_attack(target_or_position):
			return false
		attack_targets.append(target_or_position)
		active_order = true
		return true

	func has_active_order() -> bool:
		return active_order

	func cancel_all_orders() -> bool:
		if not active_order:
			return false
		stop_commands += 1
		active_order = false
		return true


class FakeUnitCommandController extends UnitCommandController:
	var raycast_hits: Array[Dictionary] = []
	var raycast_masks: Array[int] = []
	var screen_positions: Dictionary = {}
	var cursor_time_msec := 0

	func _raycast(_screen_position: Vector2, collision_mask: int = 0xffffffff) -> Dictionary:
		raycast_masks.append(collision_mask)
		return raycast_hits.pop_front() if not raycast_hits.is_empty() else {}

	func _screen_position_for_entity(entity):
		return screen_positions.get(entity, null)

	func _cursor_time_msec() -> int:
		return cursor_time_msec


class FakeNavigation extends RefCounted:
	var commands: Array[Dictionary] = []
	var move_allowed := true
	var move_queries: Array[Dictionary] = []

	func can_move_to(units: Array, target: Vector3) -> bool:
		move_queries.append({"units": units.duplicate(), "target": target})
		return move_allowed

	func command_move(units: Array, target: Vector3, mode: int, exit_point := Vector3.INF) -> Array:
		var accepted := []
		for unit in units:
			if unit.has_method("prepare_navigation_order") \
			and not bool(unit.call("prepare_navigation_order", target, exit_point, mode)):
				continue
			accepted.append(unit)
		if not accepted.is_empty():
			commands.append({"units": accepted, "target": target, "mode": mode})
		return accepted


class FakeTargetAbility extends RefCounted:
	func definitions(_selection: Array[Node]) -> Array[Dictionary]:
		return [{"id": &"test_target", "slot": &"pickup", "keycode": KEY_F, "enabled": true}]

	func cursor_for(_id: StringName, _selection: Array[Node], _target, _position: Vector3) -> int:
		return CursorManagerScript.CursorType.DN5

	func execute(_id: StringName, _selection: Array[Node], _target, _position: Vector3) -> Dictionary:
		return {"ok": true, "message": "done"}


## A combat-deploy-style unit (Kindjal/Mortar/Kobra): unlike the MCV, `D` or a
## repeated left-click on the same selected unit must toggle both directions
## through one entry point, and the unit itself (not a separate building)
## stays immobile while `deployed`.
class FakeToggleUnit extends FakeUnit:
	var deployed := false
	var deploying := false

	func is_deployed() -> bool:
		return deployed

	func is_deploying() -> bool:
		return deploying

	func set_deployed_for_test(value: bool) -> void:
		deployed = value


class FakeDeploymentController extends RefCounted:
	var calls: Array[Node] = []
	var undeployment_calls: Array[Dictionary] = []
	var deployment_entities: Array[Node] = []
	var deployable_entities: Array[Node] = []
	var undeployable_entities: Array[Node] = []
	var availability_queries := 0
	var result := {
		"handled": true,
		"started": true,
		"message": "ATConYard deployment started",
	}
	var undeployment_result := {
		"handled": true,
		"started": true,
		"message": "ATConYard packing into ATMCV",
	}

	## Mirrors UnitDeploymentController.try_deploy's real contract: one entry
	## point that routes to undeploy when the unit reports itself deployed.
	func try_deploy(unit: Node) -> Dictionary:
		calls.append(unit)
		if unit.has_method("is_deployed") and unit.has_method("set_deployed_for_test"):
			var now_deployed := not bool(unit.call("is_deployed"))
			unit.call("set_deployed_for_test", now_deployed)
			return {
				"handled": true,
				"started": true,
				"message": "%s %s" % [String(unit.name), "deployed" if now_deployed else "undeployed"],
			}
		return result

	func can_issue_deploy(unit: Node3D) -> bool:
		availability_queries += 1
		return unit in deployable_entities

	func can_handle(unit: Node3D) -> bool:
		return unit in deployment_entities

	func try_undeploy(building: Node, target: Vector3, move_mode: int) -> Dictionary:
		undeployment_calls.append({
			"building": building, "target": target, "move_mode": move_mode
		})
		return undeployment_result

	func can_undeploy(building: Node) -> bool:
		return building in undeployable_entities


class FakeNavigationGrid extends MapNavigationGrid:
	func is_loaded() -> bool:
		return true

	func world_to_grid(world_position: Vector3) -> Vector2i:
		return Vector2i(floori(world_position.x), floori(world_position.z))

	func cell_debug(grid_position: Vector2i) -> Dictionary:
		return {"source_tile": grid_position, "terrain_name": "sand"}


class FakeSpiceLayer extends RefCounted:
	var spice_cells: Dictionary = {}

	func has_spice(cell: Vector2i) -> bool:
		return int(spice_cells.get(cell, 0)) > 0


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Atreides Commander", Color.BLUE, &"Atreides", [&"Fremen"])
	var enemy_player = players.create_player(2, "Ordos Rival", Color.GREEN, &"Ordos")
	var neutral_player = players.neutral_player()
	players.local_player_id = 1
	players.set_relation(1, 2, PlayerData.Relation.ENEMY)

	_run_case("selection ownership and movement", _test_selection_ownership_and_movement.bind(local_player, enemy_player))
	_run_case("carried cargo remains attackable but cannot be selected", _test_carried_cargo_targeting.bind(local_player, enemy_player))
	_run_case("locked transport remains selected while cargo is pruned", _test_transport_selection_lock.bind(local_player))
	_run_case("targeting right-click cancels and D keeps deployment", _test_target_mode_input_priority.bind(local_player))
	await _test_target_hotkey_input_dispatch(local_player)
	_run_case("right click and Ctrl route target-specific attack orders", _test_attack_orders.bind(local_player, enemy_player, neutral_player))
	_run_case("clicking the selected unit again requests deployment", _test_repeated_click_deployment.bind(local_player))
	_run_case("rectangle unit selection", _test_rectangle_unit_selection.bind(local_player, enemy_player))
	_run_case("J modifies movement formation", _test_formation_modifier.bind(local_player))
	_run_case("S stops all selected units", _test_stop_shortcut.bind(local_player))
	_run_case("spice click issues harvester order", _test_harvester_order.bind(local_player))
	_run_case("owned refinery click issues unload order", _test_unload_order.bind(local_player, enemy_player))
	_run_case("building selection", _test_building_selection.bind(local_player))
	_run_case(
		"selected defensive buildings receive attack orders",
		_test_building_attack_order.bind(local_player, enemy_player)
	)
	_run_case("Construction Yard move command requests undeployment", _test_building_move_undeployment.bind(local_player))
	_run_case("command and selection cursors follow pointer context", _test_context_cursors.bind(local_player, enemy_player))
	_run_case("D toggles deploy and undeploy", _test_deploy_key_toggles.bind(local_player))
	_run_case("a repeated left-click on a deployed unit requests undeploy", _test_repeated_click_undeploy.bind(local_player))
	_run_case("a deployed unit rejects move orders with a generic status", _test_deployed_unit_move_rejected.bind(local_player))
	players.reset_for_match()
	if _failures > 0:
		printerr("UnitCommandController tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("UnitCommandController tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	var completed: Variant = test.call(token)
	if completed != token:
		_failures += 1
		printerr("FAIL: %s: case did not return its completion token" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_selection_ownership_and_movement(token: int, local_player, enemy_player) -> int:
	var commands := FakeUnitCommandController.new()
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var local_unit := _make_unit("Scout", local_player)
	var enemy_unit := _make_unit("Raider", enemy_player)
	root.add_child(local_unit)
	root.add_child(enemy_unit)
	var local_collider := Node.new()
	local_unit.add_child(local_collider)
	var enemy_collider := Node.new()
	enemy_unit.add_child(enemy_collider)

	commands.raycast_hits.append({"collider": local_collider})
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT)), "left click must be handled")
	_expect(local_unit.selected, "ancestor group unit must be selected")
	_expect(commands.selection_text() == "Scout selected | owner: Atreides Commander (Atreides/Fremen, ally)", "selected owner text must match legacy format")
	_expect(statuses.back().is_empty() and commands.raycast_masks == [0xffffffff], "selection uses the all-layers raycast")

	commands.raycast_hits.append({"collider": enemy_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(not local_unit.selected and not enemy_unit.selected, "enemy units must not become selected")
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT)), "enemy move click must still be handled")
	_expect(enemy_unit.move_targets.is_empty() and commands.selection_text() == "No entity selected", "enemy click leaves no commandable selection")
	_expect(commands.raycast_masks == [0xffffffff, 0xffffffff], "enemy move must not issue a terrain raycast")

	commands.raycast_hits.append({"collider": local_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(3.0, 7.0, 4.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(enemy_unit.selected == false and local_unit.move_targets == [Vector3(3.0, 7.0, 4.0)], "owned unit moves to terrain hit")
	_expect(commands.raycast_masks.back() == 1, "movement uses terrain mask one")
	_expect(statuses.back() == "Moving to 3.0, 4.0", "movement status keeps legacy text without nav grid")
	commands._refresh_idle_status()
	_expect(statuses.back() == "Moving to 3.0, 4.0", "movement status remains while the order is active")
	local_unit.active_order = false
	commands._refresh_idle_status()
	_expect(statuses.back() == "Idle", "finishing the selected unit's order reports Idle")

	commands.raycast_hits.append({})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(commands.selection_text() == "No entity selected", "selection miss clears selection")
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT)), "right click with no selection is handled")

	commands.queue_free()
	local_unit.queue_free()
	enemy_unit.queue_free()
	return token


func _test_carried_cargo_targeting(token: int, local_player, enemy_player) -> int:
	var commands := FakeUnitCommandController.new()
	root.add_child(commands)
	var attacker := _make_unit("Attacker", local_player)
	var cargo := FakeCarriedCargo.new()
	cargo.name = "CarriedCargo"
	cargo.player = enemy_player
	cargo.add_to_group("units")
	root.add_child(attacker)
	root.add_child(cargo)
	var collider := Node.new()
	cargo.add_child(collider)
	_expect(commands._find_selectable_entity(collider) == cargo,
		"resolver must retain carried cargo as a damageable target")
	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(not cargo.selected and commands.selection_text() == "No entity selected",
		"command-locked cargo must not become a player selection")
	commands._set_selection([attacker])
	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(attacker.attack_targets == [cargo], "carried cargo must remain independently attackable")
	commands.queue_free()
	attacker.queue_free()
	cargo.queue_free()
	return token


func _test_transport_selection_lock(token: int, local_player) -> int:
	var commands := FakeUnitCommandController.new()
	root.add_child(commands)
	var carrier := FakeLockedCarrier.new()
	carrier.name = "DockingCarryall"
	carrier.player = local_player
	carrier.add_to_group("units")
	root.add_child(carrier)
	commands._set_selection([carrier])
	commands._prune_uncommandable_selection()
	_expect(carrier.selected and commands.selection_text().begins_with("DockingCarryall selected"),
		"a command-locked carrier must remain selected throughout docking animation")
	commands.queue_free()
	carrier.queue_free()
	return token


func _test_target_mode_input_priority(token: int, local_player) -> int:
	var commands := FakeUnitCommandController.new()
	root.add_child(commands)
	var unit := FakeToggleUnit.new()
	unit.name = "Deployable"
	unit.player = local_player
	unit.add_to_group("units")
	root.add_child(unit)
	commands._set_selection([unit])
	commands._target_abilities.configure(null, [FakeTargetAbility.new()])
	commands._target_abilities.selection_changed([unit])
	commands.handle_unhandled_input(_key_event(KEY_F, true))
	_expect(commands.has_active_target_ability(), "F must enter target mode before input-priority checks")
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(not commands.has_active_target_ability() and unit.move_targets.is_empty(),
		"right click in target mode must only cancel and never issue a normal order")
	var deployment := FakeDeploymentController.new()
	deployment.deployment_entities.append(unit)
	commands._deployment_controller = deployment
	commands.handle_unhandled_input(_key_event(KEY_F, true))
	commands.handle_unhandled_input(_key_event(KEY_D, true))
	_expect(not commands.has_active_target_ability() and deployment.calls == [unit],
		"D must cancel target mode then retain its ordinary deployment behavior")
	commands.queue_free()
	unit.queue_free()
	return token


func _test_target_hotkey_input_dispatch(local_player) -> void:
	_current_case = "target ability hotkey precedes focused GUI input"
	var failures_before := _failures
	var commands := FakeUnitCommandController.new()
	commands.setup(null, null, null, null, null, null, [FakeTargetAbility.new()])
	root.add_child(commands)
	var unit := FakeToggleUnit.new()
	unit.name = "Carryall"
	unit.player = local_player
	unit.add_to_group("units")
	root.add_child(unit)
	commands._set_selection([unit])
	var focused_edit := LineEdit.new()
	root.add_child(focused_edit)
	focused_edit.grab_focus()
	await process_frame
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = KEY_F
	Input.parse_input_event(event)
	await process_frame
	_expect(
		commands.has_active_target_ability(),
		"physical F must enter target mode through Godot input even while GUI owns keyboard focus"
	)
	commands.cancel_target_ability()
	focused_edit.queue_free()
	commands.queue_free()
	unit.queue_free()
	await process_frame
	if failures_before == _failures:
		print("PASS: %s" % _current_case)


func _test_attack_orders(token: int, local_player, enemy_player, neutral_player) -> int:
	var commands := FakeUnitCommandController.new()
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var attacker := _make_unit("Trooper", local_player)
	var unable := _make_unit("Harvester", local_player)
	unable.attack_capable = false
	var ally := _make_unit("Ally", local_player)
	ally.config_id = &"ATAPC"
	var enemy := _make_unit("Enemy", enemy_player)
	var neutral := _make_unit("Neutral", neutral_player)
	for unit in [attacker, unable, ally, enemy, neutral]:
		root.add_child(unit)
	var ally_collider := Node.new()
	var enemy_collider := Node.new()
	var neutral_collider := Node.new()
	ally.add_child(ally_collider)
	enemy.add_child(enemy_collider)
	neutral.add_child(neutral_collider)
	commands._set_selection([attacker, unable])

	commands.raycast_hits.append({"collider": enemy_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(attacker.attack_targets == [enemy], "ordinary right click must attack an enemy entity")
	_expect(unable.attack_targets.is_empty(), "a mixed selection must omit units unable to attack the target")
	_expect(attacker.move_targets.is_empty(), "an enemy attack click must not also become movement")
	_expect(statuses.back() == "Attacking Enemy", "a single capable unit must produce an attack status")

	commands.raycast_hits.append({"collider": ally_collider})
	commands.raycast_hits.append({"position": Vector3(4.0, 0.0, 6.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(attacker.attack_targets == [enemy], "ordinary right click must not attack an allied entity")
	_expect(attacker.move_targets.back() == Vector3(4.0, 0.0, 6.0), "an allied click without Ctrl remains movement")

	commands.raycast_hits.append({"collider": neutral_collider})
	commands.raycast_hits.append({"position": Vector3(8.0, 0.0, 10.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(attacker.attack_targets == [enemy], "ordinary right click must not attack a neutral entity")
	_expect(attacker.move_targets.back() == Vector3(8.0, 0.0, 10.0), "a neutral click without Ctrl remains movement")

	commands.raycast_hits.append({"collider": ally_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT, true, Vector2.ZERO, true))
	_expect(
		statuses.back() == "Attacking ATAPC",
		"attack status must prefer the rules id over an autogenerated node name"
	)
	commands.raycast_hits.append({"collider": neutral_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT, true, Vector2.ZERO, true))
	var ground_target := Vector3(12.0, 0.0, 14.0)
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": ground_target})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT, true, Vector2.ZERO, true))
	_expect(
		attacker.attack_targets == [enemy, ally, neutral, ground_target],
		"Ctrl+right click must force allied, neutral, and attack-ground targets"
	)

	attacker.rejected_attack_targets.append(enemy)
	commands.raycast_hits.append({"collider": enemy_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(attacker.attack_targets.size() == 4, "an incompatible target must not receive an attack order")
	_expect(statuses.back() == "Selected units cannot attack this target", "an incompatible attack click must explain the rejection")
	commands.raycast_hits.append({"collider": enemy_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == UnitCommandControllerScript.NO_CURSOR_OVERRIDE,
		"an enemy that no selected unit can attack must not show the attack cursor"
	)
	attacker.rejected_attack_targets.erase(enemy)
	commands.raycast_hits.append({"collider": enemy_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.ATTACK,
		"an attackable enemy must use the dedicated attack cursor"
	)
	commands.handle_unhandled_input(_key_event(KEY_CTRL, true))
	commands.raycast_hits.append({"collider": ally_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.ATTACK,
		"held Ctrl must show the attack cursor over an attackable ally"
	)
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": ground_target})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.ATTACK,
		"held Ctrl must show the attack cursor over attackable ground"
	)
	commands.handle_unhandled_input(_key_event(KEY_CTRL, false))

	commands.queue_free()
	for unit in [attacker, unable, ally, enemy, neutral]:
		unit.queue_free()
	return token


func _test_repeated_click_deployment(token: int, local_player) -> int:
	var deployment := FakeDeploymentController.new()
	var commands := FakeUnitCommandController.new()
	commands.setup(null, null, null, null, deployment)
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var mcv := _make_unit("ATMCV", local_player)
	root.add_child(mcv)
	var collider := Node.new()
	mcv.add_child(collider)
	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(deployment.calls.is_empty(), "the first click must only select the MCV")

	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(deployment.calls == [mcv], "the next click on the same selected unit must request deploy")
	_expect(mcv.selected, "the MCV must remain selected during its deployment animation")
	_expect(statuses.back() == "ATConYard deployment started", "deployment status must reach the shared selection label")

	commands.queue_free()
	mcv.queue_free()
	return token


func _test_building_selection(token: int, local_player) -> int:
	var commands := FakeUnitCommandController.new()
	root.add_child(commands)

	var building := FakeBuilding.new()
	building.name = "Construction Yard"
	building.player = local_player
	building.add_to_group("buildings")
	root.add_child(building)
	var collider := Node.new()
	building.add_child(collider)

	commands.raycast_hits.append({"collider": collider})
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT)), "building click must be handled")
	_expect(building.selected, "owned building must use the shared selection flow")
	_expect(commands.selection_text() == "Construction Yard selected | owner: Atreides Commander (Atreides/Fremen, ally)", "building selection must include ownership")

	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(6.0, 0.0, 9.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(building.selected, "right click must not clear a stationary building selection")
	_expect(building.rally_points == [Vector3(6.0, 0.0, 9.0)], "right click on a building must set its rally point")
	_expect(commands.raycast_masks == [0xffffffff, 2, 1], "building rally points must separate entity and terrain raycasts")

	commands.queue_free()
	building.queue_free()
	return token


func _test_building_attack_order(
	token: int, local_player, enemy_player
	) -> int:
	var commands := FakeUnitCommandController.new()
	var statuses: Array[String] = []
	commands.status_changed.connect(
		func(status: String) -> void: statuses.append(status)
	)
	root.add_child(commands)
	var turret := FakeBuilding.new()
	turret.name = "ATRocketTurret"
	turret.player = local_player
	turret.ai_manufacturing = false
	turret.attack_capable = true
	turret.add_to_group("buildings")
	root.add_child(turret)
	var enemy := _make_unit("Enemy", enemy_player)
	enemy.config_id = &"Enemy"
	root.add_child(enemy)
	var enemy_collider := Node.new()
	enemy.add_child(enemy_collider)
	commands._set_selection([turret])
	commands.raycast_hits.append({"collider": enemy_collider})
	commands.handle_unhandled_input(
		_mouse_event(MOUSE_BUTTON_RIGHT)
	)
	_expect(
		turret.attack_targets == [enemy],
		"right click on an enemy must route through the building combat API"
	)
	_expect(
		statuses.back() == "Attacking Enemy",
		"a single selected turret must report the shared attack status"
	)
	commands.raycast_hits.append({"collider": enemy_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) \
			== CursorManagerScript.CursorType.ATTACK,
		"an attackable enemy must expose the turret's attack cursor"
	)
	var ground_target := Vector3(12.0, 0.0, 14.0)
	commands.handle_unhandled_input(_key_event(KEY_CTRL, true))
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": ground_target})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) \
			== CursorManagerScript.CursorType.ATTACK,
		"a stationary turret's attack-ground command must expose its attack cursor"
	)
	commands.handle_unhandled_input(_key_event(KEY_CTRL, false))
	commands._refresh_idle_status()
	_expect(
		statuses.back() == "Attacking Enemy",
		"the building's active attack order must keep the status non-idle"
	)
	turret.active_order = false
	commands._refresh_idle_status()
	_expect(
		statuses.back() == "Idle",
		"finishing a building attack order must report Idle"
	)
	commands.queue_free()
	turret.queue_free()
	enemy.queue_free()
	return token


func _test_building_move_undeployment(token: int, local_player) -> int:
	var deployment := FakeDeploymentController.new()
	var commands := FakeUnitCommandController.new()
	commands.setup(null, null, null, null, deployment)
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var con_yard := FakeBuilding.new()
	con_yard.name = "ATConYard"
	con_yard.player = local_player
	# Real Construction Yards never carry Rules.txt's AiManufacturing flag;
	# undeployment must not depend on the ordinary rally-point capability.
	con_yard.ai_manufacturing = false
	con_yard.add_to_group("buildings")
	root.add_child(con_yard)
	deployment.undeployable_entities.append(con_yard)
	var collider := Node.new()
	con_yard.add_child(collider)

	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(24.0, 0.0, 30.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))

	_expect(deployment.undeployment_calls.size() == 1, "a selected Construction Yard must route its move command through undeployment")
	if not deployment.undeployment_calls.is_empty():
		var request: Dictionary = deployment.undeployment_calls[0]
		_expect(request["building"] == con_yard, "the undeployment request must retain the selected building")
		_expect(request["target"] == Vector3(24.0, 0.0, 30.0), "the undeployment request must retain the clicked move target")
		_expect(request["move_mode"] == NavConstantsScript.MoveMode.FREE, "the undeployment request must retain the movement mode")
	_expect(con_yard.rally_points.is_empty(), "a handled Construction Yard move must not become a rally point")
	_expect(statuses.back() == "ATConYard packing into ATMCV", "the packing status must reach the shared selection label")

	commands.queue_free()
	con_yard.queue_free()
	return token


func _test_context_cursors(token: int, local_player, enemy_player) -> int:
	var navigation := FakeNavigation.new()
	var deployment := FakeDeploymentController.new()
	var terrain := MapLoader.new()
	terrain.navigation_grid = FakeNavigationGrid.new()
	terrain.spice_layer = FakeSpiceLayer.new()
	var commands := FakeUnitCommandController.new()
	commands.setup(null, terrain, navigation, null, deployment)
	root.add_child(commands)

	var scout := _make_unit("Scout", local_player)
	var tank := _make_unit("Tank", local_player)
	var mcv := _make_unit("ATMCV", local_player)
	var enemy := _make_unit("Raider", enemy_player)
	root.add_child(scout)
	root.add_child(tank)
	root.add_child(mcv)
	root.add_child(enemy)
	var scout_collider := Node.new()
	var tank_collider := Node.new()
	var mcv_collider := Node.new()
	var enemy_collider := Node.new()
	scout.add_child(scout_collider)
	tank.add_child(tank_collider)
	mcv.add_child(mcv_collider)
	enemy.add_child(enemy_collider)

	var barracks := FakeBuilding.new()
	barracks.name = "ATBarracks"
	barracks.player = local_player
	barracks.add_to_group("buildings")
	root.add_child(barracks)
	commands._set_selection([barracks])
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(8.0, 0.0, 10.0)})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.PLACE_FLAG,
		"a valid building rally point must use the place-flag cursor"
	)
	commands.raycast_hits.append({})
	commands.raycast_hits.append({})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.CANT_PLACE_FLAG,
		"a rally point outside terrain must use the cant-place-flag cursor"
	)
	var windtrap := FakeBuilding.new()
	windtrap.name = "ATSmWindtrap"
	windtrap.player = local_player
	windtrap.ai_manufacturing = false
	windtrap.add_to_group("buildings")
	root.add_child(windtrap)
	commands._set_selection([windtrap])
	commands.raycast_hits.append({})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == UnitCommandControllerScript.NO_CURSOR_OVERRIDE,
		"a building without AiManufacturing must not expose a rally-point cursor"
	)
	commands.raycast_hits.append({})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(
		windtrap.rally_points.is_empty(),
		"a building without AiManufacturing must reject right-click rally points"
	)

	commands._set_selection([])
	commands.raycast_hits.append({"collider": scout_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.OVER_UNIT,
		"an unselected owned unit must use the row-six selection cursor"
	)
	deployment.deployment_entities.append(mcv)
	deployment.deployable_entities.append(mcv)
	commands.raycast_hits.append({"collider": mcv_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.OVER_UNIT,
		"an unselected deploy-capable MCV must still use the selection cursor"
	)
	_expect(
		deployment.availability_queries == 0,
		"deployment availability must not be checked before the selected MCV is hovered"
	)
	commands._set_selection([mcv])
	commands.raycast_hits.append({"collider": mcv_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.DEPLOY,
		"a selected MCV at a valid site must use the deploy cursor"
	)
	_expect(deployment.availability_queries == 1, "the first selected-MCV hover must check deployment")
	deployment.deployable_entities.erase(mcv)
	mcv.position.x += 4.0
	commands.raycast_hits.append({"collider": mcv_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.DEPLOY,
		"deployment cursor checks must retain their result during the one-second interval"
	)
	_expect(
		deployment.availability_queries == 1,
		"a moving selected MCV must not trigger another deployment check in the same second"
	)
	commands.cursor_time_msec += UnitCommandControllerScript.DEPLOYMENT_CURSOR_CHECK_INTERVAL_MSEC
	commands.raycast_hits.append({"collider": mcv_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.CANT_DEPLOY,
		"an invalid site must use Cant Deploy at the next one-second check"
	)
	_expect(deployment.availability_queries == 2, "deployment availability must update once per second")
	commands._set_selection([scout])
	commands.raycast_hits.append({"collider": scout_collider})
	commands.raycast_hits.append({"position": Vector3(12.0, 0.0, 14.0)})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.MOVE,
		"the selected unit itself must not use the row-six cursor"
	)

	commands.raycast_hits.append({"collider": tank_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.OVER_UNIT,
		"another selectable unit must keep the row-six cursor"
	)
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(20.0, 0.0, 22.0)})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.MOVE,
		"a valid movement point must use the row-two cursor"
	)
	_expect(
		navigation.move_queries.back()["units"] == [scout],
		"movement cursor validation must use the selected movable units"
	)
	navigation.move_allowed = false
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(30.0, 0.0, 32.0)})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.CANT_MOVE,
		"an invalid movement point must use the row-four cursor"
	)
	commands.raycast_hits.append({})
	commands.raycast_hits.append({})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.CANT_MOVE,
		"missing terrain must use the row-four cursor while a movable unit is selected"
	)

	var harvester := FakeHarvester.new()
	harvester.name = "Harvester"
	harvester.player = local_player
	harvester.add_to_group("units")
	root.add_child(harvester)
	var refinery := FakeBuilding.new()
	refinery.name = "ATRefinery"
	refinery.player = local_player
	refinery.refinery = true
	refinery.add_to_group("buildings")
	root.add_child(refinery)
	var refinery_collider := Node.new()
	refinery.add_child(refinery_collider)
	commands._set_selection([harvester])
	commands.raycast_hits.append({"collider": refinery_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.ENTER,
		"a selected harvester over its refinery must use the row-five interaction cursor"
	)
	navigation.move_allowed = true
	terrain.spice_layer.spice_cells[Vector2i(50, 52)] = 100
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(50.2, 0.0, 52.7)})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == CursorManagerScript.CursorType.ATTACK,
		"a harvester over spice must use the Attack cursor for its gather order"
	)

	commands._set_selection([])
	commands.raycast_hits.append({"collider": enemy_collider})
	_expect(
		commands._command_cursor_at(Vector2.ZERO) == UnitCommandControllerScript.NO_CURSOR_OVERRIDE,
		"an entity that cannot be selected must leave the pointer cursor unchanged"
	)
	navigation.move_allowed = false
	commands._set_selection([scout])
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(40.0, 0.0, 42.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(
		navigation.commands.is_empty(),
		"a row-four destination must reject the movement order itself"
	)
	_expect(
		commands.raycast_masks == [2, 1, 2, 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 2, 2, 1, 2, 1, 2, 1, 2, 2, 1, 2, 2, 1],
		"cursor context must keep entity and terrain raycasts on their dedicated layers"
	)

	commands.queue_free()
	scout.queue_free()
	tank.queue_free()
	mcv.queue_free()
	enemy.queue_free()
	harvester.queue_free()
	refinery.queue_free()
	barracks.queue_free()
	windtrap.queue_free()
	terrain.free()
	return token


func _test_rectangle_unit_selection(token: int, local_player, enemy_player) -> int:
	var commands := FakeUnitCommandController.new()
	root.add_child(commands)
	var scout := _make_unit("Scout", local_player)
	var tank := _make_unit("Tank", local_player)
	var enemy := _make_unit("Raider", enemy_player)
	root.add_child(scout)
	root.add_child(tank)
	root.add_child(enemy)
	commands.screen_positions = {
		scout: Vector2(20.0, 20.0),
		tank: Vector2(70.0, 60.0),
		enemy: Vector2(50.0, 50.0),
	}

	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT, true, Vector2(10.0, 10.0))), "drag start must be handled")
	_expect(commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT, false, Vector2(100.0, 100.0))), "drag release must be handled")
	_expect(scout.selected and tank.selected and not enemy.selected, "rectangle selects only owned units inside it")
	_expect(commands.selection_text() == "2 units selected", "rectangle selection must describe the group")

	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(4.0, 5.0, 6.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(scout.move_targets == [Vector3(4.0, 5.0, 6.0)] and tank.move_targets == [Vector3(4.0, 5.0, 6.0)], "right click commands every selected unit")

	commands.queue_free()
	scout.queue_free()
	tank.queue_free()
	enemy.queue_free()
	return token


func _test_formation_modifier(token: int, local_player) -> int:
	var navigation := FakeNavigation.new()
	var commands := FakeUnitCommandController.new()
	commands.setup(null, null, navigation)
	root.add_child(commands)
	var unit := _make_unit("FormationScout", local_player)
	root.add_child(unit)
	var collider := Node.new()
	unit.add_child(collider)

	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(not commands.handle_unhandled_input(_key_event(KEY_J, true)), "J press must not consume unrelated input")
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(12.0, 0.0, 14.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(navigation.commands.size() == 1, "J plus right click must issue one navigation command")
	_expect(navigation.commands[0]["mode"] == NavConstantsScript.MoveMode.FORMATION, "held J must select formation movement")

	commands.handle_unhandled_input(_key_event(KEY_J, false))
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(16.0, 0.0, 18.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(navigation.commands[1]["mode"] == NavConstantsScript.MoveMode.FREE, "releasing J must restore free movement")

	commands.queue_free()
	unit.queue_free()
	return token


func _test_stop_shortcut(token: int, local_player) -> int:
	var commands := FakeUnitCommandController.new()
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)
	var scout := _make_unit("StopScout", local_player)
	var tank := _make_unit("StopTank", local_player)
	root.add_child(scout)
	root.add_child(tank)
	scout.active_order = true
	tank.active_order = true
	commands._set_selection([scout, tank])

	var stop_event := _key_event(KEY_S, true)
	_expect(commands.handle_unhandled_input(stop_event), "S press must be consumed as a unit command")
	_expect(
		scout.stop_commands == 1 and tank.stop_commands == 1,
		"S must cancel every selected unit's orders"
	)
	_expect(not scout.active_order and not tank.active_order, "S must leave all selected units idle")
	_expect(statuses.back() == "2 orders stopped", "group Stop must report how many orders stopped")

	stop_event.echo = true
	commands.handle_unhandled_input(stop_event)
	commands.handle_unhandled_input(_key_event(KEY_S, false))
	_expect(
		scout.stop_commands == 1 and tank.stop_commands == 1,
		"key echo and release must not repeat the Stop command"
	)

	scout.active_order = true
	tank.active_order = true
	var physical_stop := _key_event(KEY_NONE, true)
	physical_stop.physical_keycode = KEY_S
	commands.handle_unhandled_input(physical_stop)
	_expect(
		scout.stop_commands == 2 and tank.stop_commands == 2,
		"the physical S key must work independently of the keyboard layout"
	)
	var status_count := statuses.size()
	commands.handle_unhandled_input(physical_stop)
	_expect(
		scout.stop_commands == 2 and tank.stop_commands == 2 \
		and statuses.size() == status_count,
		"Stop must ignore selected entities that no longer have an active order"
	)

	var building := FakeBuilding.new()
	building.player = local_player
	building.attack_capable = true
	building.active_order = true
	building.rally_points.append(Vector3(9.0, 0.0, 12.0))
	building.add_to_group("buildings")
	root.add_child(building)
	commands._set_selection([building])
	commands.handle_unhandled_input(_key_event(KEY_S, true))
	_expect(
		building.stop_commands == 1 and not building.active_order,
		"Stop must cancel a selected building's attack order"
	)
	_expect(
		building.rally_points == [Vector3(9.0, 0.0, 12.0)],
		"Stop must preserve a selected building's rally point"
	)
	_expect(statuses.back() == "Stopped", "a stopped building attack must report status")

	commands.queue_free()
	scout.queue_free()
	tank.queue_free()
	building.queue_free()
	return token


func _test_harvester_order(token: int, local_player) -> int:
	var navigation := FakeNavigation.new()
	var terrain := MapLoader.new()
	terrain.navigation_grid = FakeNavigationGrid.new()
	terrain.spice_layer = FakeSpiceLayer.new()
	terrain.spice_layer.spice_cells[Vector2i(12, 14)] = 200
	var commands := FakeUnitCommandController.new()
	commands.setup(null, terrain, navigation)
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var harvester := FakeHarvester.new()
	harvester.name = "Harvester"
	harvester.player = local_player
	harvester.add_to_group("units")
	root.add_child(harvester)
	var collider := Node.new()
	harvester.add_child(collider)
	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))

	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(12.4, 0.0, 14.8)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(harvester.harvest_commands.size() == 1, "a spice-cell click must issue the dedicated harvesting order")
	_expect(harvester.harvest_commands[0]["cell"] == Vector2i(12, 14), "the harvesting order must retain the clicked navigation cell")
	_expect(navigation.commands.is_empty() and harvester.move_targets.is_empty(), "a harvester spice order must not also become a generic move")
	_expect(statuses.back().begins_with("Harvesting spice at 12.4, 14.8"), "the command status must identify resource collection")

	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(20.0, 0.0, 21.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(harvester.cancelled_harvest_orders == 1, "a later ordinary move must cancel the harvesting order")
	_expect(navigation.commands.size() == 1 and navigation.commands[0]["units"] == [harvester], "an empty-cell click must retain ordinary movement")

	commands.queue_free()
	harvester.queue_free()
	terrain.free()
	return token


func _test_unload_order(token: int, local_player, enemy_player) -> int:
	var navigation := FakeNavigation.new()
	var terrain := MapLoader.new()
	terrain.navigation_grid = FakeNavigationGrid.new()
	terrain.spice_layer = FakeSpiceLayer.new()
	var commands := FakeUnitCommandController.new()
	commands.setup(null, terrain, navigation)
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var harvester := FakeHarvester.new()
	harvester.name = "Harvester"
	harvester.player = local_player
	harvester.add_to_group("units")
	root.add_child(harvester)
	var harvester_collider := Node.new()
	harvester.add_child(harvester_collider)
	commands.raycast_hits.append({"collider": harvester_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))

	var owned_refinery := FakeBuilding.new()
	owned_refinery.name = "ATRefinery"
	owned_refinery.player = local_player
	owned_refinery.refinery = true
	owned_refinery.add_to_group("buildings")
	root.add_child(owned_refinery)
	var owned_collider := Node.new()
	owned_refinery.add_child(owned_collider)
	commands.raycast_hits.append({"collider": owned_collider})
	commands.raycast_hits.append({"position": Vector3(8.0, 0.0, 9.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(harvester.unload_commands.size() == 1, "an owned refinery click must issue the dedicated unloading order")
	_expect(harvester.unload_commands[0]["refinery"] == owned_refinery, "the unloading order must retain the clicked refinery")
	_expect(harvester.unload_commands[0]["spice_layer"] == terrain.spice_layer, "manual unloading must retain the spice layer needed to resume the cycle")
	_expect(navigation.commands.is_empty(), "a valid unloading click must not also become generic movement")
	_expect(statuses.back().begins_with("Unloading at ATRefinery"), "the command status must identify the refinery")
	_expect(commands.raycast_masks.slice(-2) == [2, 1], "an unload click must resolve the layer-two refinery separately from layer-one terrain")

	harvester.defer_navigation_orders = true
	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(12.0, 0.0, 13.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(harvester.prepared_move_targets.back() == Vector3(12.0, 0.0, 13.0), "navigation must prepare the direct move through the unit API")
	_expect(navigation.commands.is_empty(), "a move deferred until UnloadEnd must not reach navigation immediately")
	harvester.defer_navigation_orders = false

	var enemy_refinery := FakeBuilding.new()
	enemy_refinery.name = "ORRefinery"
	enemy_refinery.player = enemy_player
	enemy_refinery.refinery = true
	enemy_refinery.add_to_group("buildings")
	root.add_child(enemy_refinery)
	var enemy_collider := Node.new()
	enemy_refinery.add_child(enemy_collider)
	commands.raycast_hits.append({"collider": enemy_collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))
	_expect(harvester.unload_commands.size() == 1, "an enemy refinery must not accept an unloading order")
	_expect(navigation.commands.is_empty(), "an unarmed harvester must not turn an enemy attack click into movement")

	commands.queue_free()
	harvester.queue_free()
	owned_refinery.queue_free()
	enemy_refinery.queue_free()
	terrain.free()
	return token


func _make_unit(unit_name: String, player) -> FakeUnit:
	var unit := FakeUnit.new()
	unit.name = unit_name
	unit.player = player
	unit.add_to_group("units")
	return unit


func _mouse_event(
		button_index: int,
		pressed := true,
		position := Vector2(10.0, 10.0),
		ctrl_pressed := false
	) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = pressed
	event.position = position
	event.ctrl_pressed = ctrl_pressed
	return event


func _key_event(keycode: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = pressed
	return event


func _test_deploy_key_toggles(token: int, local_player) -> int:
	var deployment := FakeDeploymentController.new()
	var commands := FakeUnitCommandController.new()
	commands.setup(null, null, null, null, deployment)
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var unit := FakeToggleUnit.new()
	unit.name = "ATKindjal"
	unit.player = local_player
	unit.add_to_group("units")
	root.add_child(unit)
	deployment.deployment_entities.append(unit)
	commands._set_selection([unit])

	_expect(
		commands.handle_unhandled_input(_key_event(KEY_D, true)),
		"D must be handled as a command input"
	)
	_expect(deployment.calls == [unit], "D must issue a deploy command to the selected unit")
	_expect(unit.is_deployed(), "D must deploy a travel-mode unit")
	_expect(statuses.back() == "ATKindjal deployed", "the deploy status must reach the selection label")

	commands.handle_unhandled_input(_key_event(KEY_D, true))
	_expect(deployment.calls.size() == 2, "a second D press must issue another deploy command")
	_expect(not unit.is_deployed(), "D must undeploy an already-deployed unit")
	_expect(statuses.back() == "ATKindjal undeployed", "the undeploy status must reach the selection label")

	commands.queue_free()
	unit.queue_free()
	return token


func _test_repeated_click_undeploy(token: int, local_player) -> int:
	var deployment := FakeDeploymentController.new()
	var commands := FakeUnitCommandController.new()
	commands.setup(null, null, null, null, deployment)
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var unit := FakeToggleUnit.new()
	unit.name = "ORKobra"
	unit.player = local_player
	unit.add_to_group("units")
	unit.deployed = true
	root.add_child(unit)
	deployment.deployment_entities.append(unit)
	var collider := Node.new()
	unit.add_child(collider)

	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(deployment.calls.is_empty(), "the first click must only select the deployed unit")

	commands.raycast_hits.append({"collider": collider})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT))
	_expect(deployment.calls == [unit], "the repeated click on a deployed unit must request undeploy")
	_expect(not unit.is_deployed(), "the repeated click must undeploy the unit")
	_expect(statuses.back() == "ORKobra undeployed", "the undeploy status must reach the selection label")

	commands.queue_free()
	unit.queue_free()
	return token


func _test_deployed_unit_move_rejected(token: int, local_player) -> int:
	var navigation := FakeNavigation.new()
	var commands := FakeUnitCommandController.new()
	commands.setup(null, null, navigation, null, null)
	var statuses: Array[String] = []
	commands.status_changed.connect(func(status: String) -> void: statuses.append(status))
	root.add_child(commands)

	var unit := FakeToggleUnit.new()
	unit.name = "ORMortar"
	unit.player = local_player
	unit.add_to_group("units")
	unit.deployed = true
	root.add_child(unit)
	commands._set_selection([unit])

	commands.raycast_hits.append({})
	commands.raycast_hits.append({"position": Vector3(12.0, 0.0, 8.0)})
	commands.handle_unhandled_input(_mouse_event(MOUSE_BUTTON_RIGHT))

	_expect(navigation.commands.is_empty(), "a deployed unit must issue no navigation command")
	_expect(unit.move_targets.is_empty(), "a deployed unit must not receive a direct move order")
	_expect(
		statuses.back() == "Unit cannot move while deployed",
		"the rejection status must be generic, not MCV-specific"
	)

	commands.queue_free()
	unit.queue_free()
	return token


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
