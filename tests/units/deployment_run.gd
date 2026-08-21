extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
## Slice B2 moved Unit's deploy-alignment countdown off _physics_process and
## onto sim_tick(), which no engine callback drives -- Match does. With no
## Match in this fixture, `await physics_frame` alone advances nothing, and
## the alignment loop below would spin out its 60 frames in silence. See that
## helper's own doc comment: it was written for exactly this failure and
## already names three suites that hit it before this one.
const SimTickPumpScript := preload("res://tests/combat/support/sim_tick_pump.gd")

const UnitDeploymentControllerScript := preload("res://scripts/units/unit_deployment_controller.gd")
const UnitRosterControllerScript := preload("res://scripts/units/unit_roster_controller.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const MCVModelScene := preload("res://assets/converted/models/G_MCV_h0/G_MCV_h0.scn")
const ATConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const HKConYardScene := preload("res://assets/converted/buildings/HKConYard/HKConYard.scn")
const ORConYardScene := preload("res://assets/converted/buildings/ORConYard/ORConYard.scn")
const ORFactoryScene := preload("res://assets/converted/buildings/ORFactory/ORFactory.scn")
const AtKindjalModelScene := preload("res://assets/converted/models/AT_Kindjal_H0/AT_Kindjal_H0.scn")
const CombatDeployStrategyScript := preload("res://scripts/units/combat_deploy_strategy.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


class FakeGrid extends RefCounted:
	var buildable := true

	func is_loaded() -> bool:
		return true

	func grid_to_world(cell: Vector2i, centered: bool = true) -> Vector3:
		var offset := 0.5 if centered else 0.0
		return Vector3(float(cell.x) + offset, 0.0, float(cell.y) + offset)

	func world_to_grid(position: Vector3) -> Vector2i:
		return Vector2i(floori(position.x), floori(position.z))

	func cell_debug(_cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": buildable}


class FakeMCV extends Node3D:
	signal deployment_animation_finished

	var config_id: StringName = &"ATMCV"
	var owner_player_id := -1
	var unit_config: Resource
	var deploying := false
	var deployment_calls := 0
	var deployment_facing := Vector3.ZERO
	var finished_consumed = null

	func deploy(facing_direction: Vector3 = Vector3.ZERO) -> bool:
		if deploying:
			return false
		deploying = true
		deployment_calls += 1
		deployment_facing = facing_direction
		return true

	func is_deploying() -> bool:
		return deploying

	func finish_deployment(consumed: bool) -> void:
		deploying = false
		finished_consumed = consumed

	func owner_player():
		return get_node("/root/Players").player(owner_player_id)

	## Slice C5: UnitDeploymentController's deploy-completion path now calls
	## unit.call("request_despawn") instead of unit.queue_free() directly (see
	## scripts/units/unit_deployment_controller.gd). This fixture has no Match
	## in the tree, so no MatchLookupScript stub gives it a resolvable entity
	## id -- a real Unit in that situation takes request_despawn()'s
	## queue_free() fallback (see that method's own doc comment), which this
	## mirrors directly rather than duck-typing the whole method.
	func request_despawn() -> void:
		queue_free()


## Unit.deploy()/undeploy()/finish_deployment() call set_hold_position on the
## unit's own navigation controller; this records every call so the combat
## deploy test can assert immobility is held across the whole
## DEPLOYING->DEPLOYED->UNDEPLOYING span and released only on the
## UNDEPLOYING->TRAVEL edge.
class FakeHoldNavigation extends RefCounted:
	var held: Dictionary = {}
	var hold_calls: Array[bool] = []

	func set_hold_position(unit: Node3D, active: bool) -> void:
		held[unit] = active
		hold_calls.append(active)

	func is_held(unit: Node3D) -> bool:
		return bool(held.get(unit, false))


class FakeNavigation extends RefCounted:
	var commands: Array[Dictionary] = []

	func command_move(
			units: Array, target: Vector3, move_mode: int, exit_position := Vector3.INF
		) -> Array:
		commands.append({
			"units": units,
			"target": target,
			"move_mode": move_mode,
			"exit_position": exit_position,
		})
		return units


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_case("rules define three concrete MCV units", _test_three_mcv_rules)
	await _run_case("MCV uses its authored stop transition", _test_unit_deployment_animation)
	await _run_case("each MCV deploys its directly linked Construction Yard", _test_house_construction_yards)
	await _run_case("each Construction Yard packs into its linked MCV and preserves the move order", _test_house_construction_yard_undeployment)
	await _run_case("an incomplete Construction Yard rejects packing", _test_incomplete_construction_yard_undeployment)
	await _run_case("captured factory produces its own concrete MCV", _test_captured_factory_mcv)
	await _run_case("invalid terrain rejects deployment before locking the MCV", _test_invalid_site)
	await _run_case("Kindjal toggles into stationary combat mode and back", _test_combat_deploy_toggle)
	await _run_case("a combat-deployable unit is data-driven, excluding IMADVSardaukar", _test_combat_deploy_eligibility)
	if _failures > 0:
		printerr("UnitDeployment tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("UnitDeployment tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_three_mcv_rules() -> void:
	var rules = root.get_node("Rules")
	_expect(rules.unit(&"MCV") == null, "the old shared MCV rules entry must not exist")
	var cases := [
		[&"ATMCV", &"Atreides", &"ATFactory", &"ATConYard"],
		[&"HKMCV", &"Harkonnen", &"HKFactory", &"HKConYard"],
		[&"ORMCV", &"Ordos", &"ORFactory", &"ORConYard"],
	]
	for house_case in cases:
		var config: Resource = rules.unit(house_case[0])
		_expect(config != null, "%s must have its own rules entry" % house_case[0])
		if config == null:
			continue
		_expect(
			StringName(String(config.field(&"house", ""))) == house_case[1],
			"%s must carry its factory technology house" % house_case[0]
		)
		var primary_buildings: Array = config.list(&"primary_buildings")
		_expect(
			primary_buildings.size() == 1
				and StringName(String(primary_buildings[0])) == house_case[2],
			"%s must be produced only by %s" % [house_case[0], house_case[2]]
		)
		var resources: Array = config.link(&"resources", [])
		_expect(
			resources.size() == 1
				and StringName(String((resources[0] as Dictionary).get("target", ""))) == house_case[3],
			"%s must deploy only %s" % [house_case[0], house_case[3]]
		)
		var con_yard_config: Resource = rules.building(house_case[3])
		var con_yard_resources: Array = con_yard_config.link(&"resources", []) \
			if con_yard_config != null else []
		_expect(
			con_yard_resources.size() == 1
				and StringName(String((con_yard_resources[0] as Dictionary).get("target", ""))) == house_case[0],
			"%s must pack only into %s" % [house_case[3], house_case[0]]
		)


func _test_unit_deployment_animation() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	unit.config_id = &"ATMCV"
	var visual_root := unit.get_node("VisualRoot") as Node3D
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	visual_root.add_child(MCVModelScene.instantiate())
	world.add_child(unit)
	unit.global_rotation.y = deg_to_rad(45.0)

	var finished := [0]
	unit.deployment_animation_finished.connect(func() -> void: finished[0] += 1)
	_expect(unit.deploy(Vector3.FORWARD), "a stationary MCV must accept the shared deploy command")
	_expect(unit.is_deploying(), "deploy must lock the unit until strategy handoff")
	var player := unit.get_node("VisualRoot").find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(
		player != null and player.current_animation != &"Move_Stop",
		"the deployment transition must wait for axis alignment"
	)
	_expect(
		is_equal_approx(unit.global_rotation.y, deg_to_rad(45.0)),
		"deployment alignment must not snap the MCV rotation"
	)
	_expect(not unit.prepare_navigation_order(Vector3(20.0, 0.0, 20.0)), "a deploying unit must reject new movement orders")
	var deploy_pump := SimTickPumpScript.new()
	for frame in 60:
		if player != null and player.current_animation == &"Move_Stop":
			break
		await physics_frame
		deploy_pump.advance(unit, root.get_physics_process_delta_time())
	_expect(
		is_zero_approx(angle_difference(unit.global_rotation.y, 0.0)),
		"the MCV must align with the future building axis before its transition"
	)
	_expect(player != null and player.current_animation == &"Move_Stop", "the source-backed Move_Stop transition must play after alignment")
	if player != null:
		player.animation_finished.emit(&"Move_Stop")
	_expect(finished[0] == 1, "the strategy handoff must wait for the authored transition to finish")
	unit.finish_deployment(false)
	_expect(not unit.is_deploying(), "a failed handoff must release the MCV")
	world.queue_free()
	await process_frame


func _test_house_construction_yards() -> void:
	var players = root.get_node("Players")
	players.reset_for_match()
	var rules = root.get_node("Rules")
	var cases := [
		[1, &"Atreides", &"ATMCV", &"ATConYard", Vector3(20.0, 0.0, 20.0), deg_to_rad(20.0), PI, Vector3(21.0, 0.0, 18.0)],
		[2, &"Harkonnen", &"HKMCV", &"HKConYard", Vector3(100.0, 0.0, 20.0), deg_to_rad(70.0), -PI * 0.5, Vector3(99.0, 0.0, 21.0)],
		[3, &"Ordos", &"ORMCV", &"ORConYard", Vector3(180.0, 0.0, 20.0), deg_to_rad(160.0), 0.0, Vector3(181.0, 0.0, 22.0)],
		# An Atreides player can own an Ordos-produced MCV after capturing
		# ORFactory; the unit remains ORMCV regardless of its current owner.
		[4, &"Atreides", &"ORMCV", &"ORConYard", Vector3(260.0, 0.0, 20.0), deg_to_rad(-110.0), PI * 0.5, Vector3(262.0, 0.0, 21.0)],
	]
	for house_case in cases:
		players.create_player(house_case[0], String(house_case[1]), Color.WHITE, house_case[1])

	var world := Node3D.new()
	root.add_child(world)
	var buildings := Node3D.new()
	buildings.name = "Buildings"
	world.add_child(buildings)
	var controller = UnitDeploymentControllerScript.new()
	world.add_child(controller)
	controller.setup(FakeGrid.new(), buildings)

	for case_index in cases.size():
		var house_case: Array = cases[case_index]
		var mcv := FakeMCV.new()
		mcv.name = "MCV_%s_%s" % [String(house_case[1]), String(house_case[2])]
		mcv.config_id = house_case[2]
		mcv.owner_player_id = house_case[0]
		mcv.unit_config = rules.unit(house_case[2])
		mcv.position = house_case[4]
		mcv.rotation.y = house_case[5]
		mcv.add_to_group("units")
		world.add_child(mcv)

		_expect(
			controller.can_issue_deploy(mcv),
			"%s MCV must expose deployment availability at its valid site" % house_case[1]
		)
		var result: Dictionary = controller.try_deploy(mcv)
		_expect(bool(result.get("started", false)), "%s MCV must pass its valid site check" % house_case[1])
		var expected_facing: Vector3 = Basis(Vector3.UP, house_case[6]) * Vector3.BACK
		_expect(
			mcv.deployment_facing.is_equal_approx(expected_facing),
			"%s must align with %s before deployment" % [house_case[2], house_case[3]]
		)
		_expect(buildings.get_child_count() == case_index, "the building must not appear before the unit animation finishes")
		mcv.deployment_animation_finished.emit()
		_expect(mcv.finished_consumed == true, "the MCV must be consumed only after a successful handoff")
		var con_yard := buildings.get_child(buildings.get_child_count() - 1) as Building
		_expect(
			con_yard.config_id == house_case[3],
			"%s-owned %s must deploy %s" % [house_case[1], house_case[2], house_case[3]]
		)
		_expect(
			absf(angle_difference(con_yard.global_rotation.y, house_case[6])) < 0.0001,
			"%s must inherit %s's direction rounded to 90 degrees" % [house_case[3], house_case[2]]
		)
		_expect(
			con_yard.global_position.is_equal_approx(house_case[7]),
			"%s must deploy one footprint cell ahead of %s (expected %s, got %s)"
				% [house_case[3], house_case[2], house_case[7], con_yard.global_position]
		)
		_expect(con_yard.owner_player_id == house_case[0], "the Construction Yard must preserve MCV ownership")
		_expect(not con_yard.is_construction_complete(), "the new Construction Yard must remain under construction")
		var state_player := con_yard.get_node("StatePlayer") as AnimationPlayer
		_expect(state_player.current_animation == &"construct", "the building handoff must start its authored construct clip")
		var build_state := con_yard.get_node_or_null("States/Build") as Node3D
		var idle_state := con_yard.get_node_or_null("States/Idle") as Node3D
		_expect(
			build_state != null and build_state.visible,
			"%s must show its folded construct model during the handoff" % house_case[3]
		)
		_expect(
			idle_state != null and not idle_state.visible,
			"%s must hide its completed model during the handoff" % house_case[3]
		)
		_expect(players.main_base_for_player(house_case[0]) == null, "an incomplete Construction Yard must not become the main base")
		state_player.animation_finished.emit(&"construct")
		_expect(con_yard.is_construction_complete(), "the authored construct clip must finish construction")
		_expect(players.main_base_for_player(house_case[0]) == con_yard, "the completed Construction Yard must become the player's main base")
		await process_frame

	world.queue_free()
	await process_frame


func _test_house_construction_yard_undeployment() -> void:
	var players = root.get_node("Players")
	players.reset_for_match()
	var _rules = root.get_node("Rules")
	var cases := [
		[1, &"Atreides", &"ATConYard", &"ATMCV", ATConYardScene, Vector3(20.0, 0.0, 120.0), 0.0],
		[2, &"Harkonnen", &"HKConYard", &"HKMCV", HKConYardScene, Vector3(100.0, 0.0, 120.0), PI * 0.5],
		[3, &"Ordos", &"ORConYard", &"ORMCV", ORConYardScene, Vector3(180.0, 0.0, 120.0), PI],
	]
	for house_case in cases:
		players.create_player(house_case[0], String(house_case[1]), Color.WHITE, house_case[1])

	var world := Node3D.new()
	root.add_child(world)
	var buildings := Node3D.new()
	buildings.name = "Buildings"
	world.add_child(buildings)
	var units := Node3D.new()
	units.name = "Units"
	world.add_child(units)
	var navigation := FakeNavigation.new()
	var controller = UnitDeploymentControllerScript.new()
	world.add_child(controller)
	controller.setup(FakeGrid.new(), buildings, units, navigation)

	for house_case in cases:
		var building := (house_case[4] as PackedScene).instantiate() as Building
		building.owner_player_id = house_case[0]
		buildings.add_child(building)
		building.global_position = house_case[5]
		building.global_rotation.y = house_case[6]
		var expected_facing := building.exit_direction()
		var expected_spawn := building.global_position + expected_facing * -0.8
		var expected_exit := building.production_exit_position()
		var move_target: Vector3 = house_case[5] + Vector3(24.0, 0.0, 18.0)

		var result: Dictionary = controller.try_undeploy(
			building, move_target, NavConstantsScript.MoveMode.FORMATION
		)
		_expect(bool(result.get("handled", false)) and bool(result.get("started", false)), "%s must accept an ordinary move command as packing" % house_case[2])
		_expect(not building.is_queued_for_deletion(), "the Construction Yard must remain until its deconstruct animation finishes")
		var state_player := building.get_node("StatePlayer") as AnimationPlayer
		_expect(state_player.current_animation == &"deconstruct", "%s must play its authored deconstruct clip while packing" % house_case[2])
		_expect(units.get_child_count() == 0, "the MCV must not appear before packing finishes")

		state_player.animation_finished.emit(&"deconstruct")
		_expect(building.is_queued_for_deletion(), "the packed Construction Yard must release its world node")
		_expect(units.get_child_count() == 1, "packing must spawn exactly one MCV")
		if units.get_child_count() == 0:
			continue
		var unit := units.get_child(0) as Unit
		_expect(unit.config_id == house_case[3], "%s must pack into its concrete %s" % [house_case[2], house_case[3]])
		_expect(
			unit.unit_definition != null and unit.unit_definition.config_id == house_case[3],
			"the packed MCV must receive its concrete native definition"
		)
		_expect(unit.owner_player_id == house_case[0], "the packed MCV must preserve Construction Yard ownership")
		_expect(unit.global_position.is_equal_approx(expected_spawn), "the packed MCV must honor the runtime forward offset from the Construction Yard")
		_expect(SpatialOrientationScript.world_forward(unit).dot(expected_facing) > 0.999, "the packed MCV must face out of the Construction Yard")
		_expect(unit.get_node("VisualRoot").get_child(0).scene_file_path == MCVModelScene.resource_path, "the packed MCV must use the converted MCV model")
		_expect(navigation.commands.size() == 1, "the spawned MCV must immediately receive the triggering move order")
		if not navigation.commands.is_empty():
			var command: Dictionary = navigation.commands[0]
			_expect(command["units"] == [unit], "the inherited movement command must target the new MCV")
			_expect(command["target"] == move_target, "the inherited movement command must preserve the clicked destination")
			_expect(command["move_mode"] == NavConstantsScript.MoveMode.FORMATION, "the inherited movement command must preserve its mode")
			_expect(command["exit_position"].is_equal_approx(expected_exit), "the MCV must first clear the old Construction Yard footprint")
		navigation.commands.clear()
		unit.queue_free()
		await process_frame

	world.queue_free()
	await process_frame


func _test_incomplete_construction_yard_undeployment() -> void:
	var players = root.get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Atreides", Color.BLUE, &"Atreides")
	var world := Node3D.new()
	root.add_child(world)
	var buildings := Node3D.new()
	world.add_child(buildings)
	var units := Node3D.new()
	world.add_child(units)
	var navigation := FakeNavigation.new()
	var controller = UnitDeploymentControllerScript.new()
	world.add_child(controller)
	controller.setup(FakeGrid.new(), buildings, units, navigation)
	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = 1
	buildings.add_child(building)
	building.begin_construction()

	var result: Dictionary = controller.try_undeploy(building, Vector3(20.0, 0.0, 20.0))
	_expect(bool(result.get("handled", false)) and not bool(result.get("started", false)), "an incomplete Construction Yard move must be handled as rejected packing")
	_expect(not building.is_queued_for_deletion() and units.get_child_count() == 0, "rejected packing must leave the incomplete building intact")
	_expect(navigation.commands.is_empty(), "rejected packing must not issue a movement command")
	world.queue_free()
	await process_frame


func _test_captured_factory_mcv() -> void:
	var players = root.get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Atreides captor", Color.BLUE, &"Atreides")
	players.local_player_id = 1
	var world := Node3D.new()
	root.add_child(world)
	var buildings := Node3D.new()
	buildings.name = "Buildings"
	world.add_child(buildings)
	var units := Node3D.new()
	units.name = "Units"
	world.add_child(units)

	var factory := ORFactoryScene.instantiate() as Building
	factory.owner_player_id = 1
	buildings.add_child(factory)
	var parent_marker := FakeMCV.new()
	parent_marker.owner_player_id = 99
	parent_marker.add_to_group("units")
	units.add_child(parent_marker)
	var roster = UnitRosterControllerScript.new()
	world.add_child(roster)
	roster.setup([&"ORMCV"])
	_expect(
		roster._spawn_completed_unit(&"ORMCV", &"ORFactory"),
		"the captured ORFactory must be able to produce ORMCV"
	)
	var produced: Unit
	for candidate in units.get_children():
		if candidate is Unit and candidate.config_id == &"ORMCV":
			produced = candidate
			break
	_expect(produced != null, "captured-factory production must create ORMCV")
	_expect(
		produced != null and produced.owner_player_id == 1,
		"ORMCV must belong to the player that owns the captured ORFactory"
	)
	if produced == null:
		world.queue_free()
		await process_frame
		return
	produced.global_position = Vector3(200.0, 0.0, 120.0)
	produced.stop_at_current_position()

	var deployment = UnitDeploymentControllerScript.new()
	world.add_child(deployment)
	deployment.setup(FakeGrid.new(), buildings)
	var result: Dictionary = deployment.try_deploy(produced)
	_expect(bool(result.get("started", false)), "the Ordos MCV must start deployment under Atreides ownership")
	var animation_player := produced.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	animation_player.animation_finished.emit(&"Move_Stop")
	var con_yard := buildings.get_child(buildings.get_child_count() - 1) as Building
	_expect(con_yard.config_id == &"ORConYard", "the captured ORFactory MCV must deploy ORConYard")
	_expect(con_yard.owner_player_id == 1, "the deployed ORConYard must still belong to the Atreides player")
	world.queue_free()
	await process_frame


func _test_invalid_site() -> void:
	var players = root.get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Atreides", Color.BLUE, &"Atreides")
	var rules = root.get_node("Rules")
	var world := Node3D.new()
	root.add_child(world)
	var buildings := Node3D.new()
	world.add_child(buildings)
	var grid := FakeGrid.new()
	grid.buildable = false
	var controller = UnitDeploymentControllerScript.new()
	world.add_child(controller)
	controller.setup(grid, buildings)
	var mcv := FakeMCV.new()
	mcv.config_id = &"ATMCV"
	mcv.owner_player_id = 1
	mcv.unit_config = rules.unit(&"ATMCV")
	mcv.add_to_group("units")
	world.add_child(mcv)

	_expect(
		not controller.can_issue_deploy(mcv),
		"an invalid MCV site must be rejected by cursor-facing validation"
	)
	var result: Dictionary = controller.try_deploy(mcv)
	_expect(bool(result.get("handled", false)) and not bool(result.get("started", false)), "an invalid MCV site must be handled as a rejected deployment")
	_expect(mcv.deployment_calls == 0 and not mcv.deploying, "site validation must happen before the MCV is locked")
	_expect(buildings.get_child_count() == 0, "a rejected deployment must not spawn a building")
	world.queue_free()
	await process_frame


func _test_combat_deploy_toggle() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	unit.config_id = &"ATKindjal"
	world.add_child(unit)
	unit.replace_visual_scene(AtKindjalModelScene)
	var nav := FakeHoldNavigation.new()
	unit.set_navigation_controller(nav)

	_expect(
		not unit.is_deploying() and not unit.is_deployed(),
		"a fresh Kindjal must start in travel mode"
	)
	_expect(
		_active_turret_ids(unit) == [&"ATKindjalGun"],
		"travel mode must expose only the travel turret"
	)
	_expect(not nav.is_held(unit), "an undeployed unit must not hold its nav position")

	var previous_target := unit.global_position + Vector3(0.0, 0.0, -5.0)
	_expect(unit.command_attack(previous_target), "the travel gun must accept an attack target")
	_expect(unit.deploy(), "a travel-mode Kindjal must accept the deploy command")
	_expect(unit.is_deploying() and not unit.is_deployed(), "deploy must enter the DEPLOYING transition")
	_expect(_active_turret_ids(unit).is_empty(), "no turret may be active mid-transition")
	_expect(nav.is_held(unit), "DEPLOYING must hold the unit in place")
	_expect(
		not unit.prepare_navigation_order(Vector3(20.0, 0.0, 20.0)),
		"a deploying unit must reject new movement orders"
	)

	unit.finish_deployment(true)
	_expect(unit.is_deployed() and not unit.is_deploying(), "a consumed DEPLOYING finish must land in DEPLOYED")
	_expect(
		not unit.has_attack_order(),
		"deploying must discard the previous weapon set's attack target"
	)
	_expect(
		_active_turret_ids(unit) == [&"ATKindjalBigGun"],
		"deployed mode must expose only the deployed turret"
	)
	_expect(nav.is_held(unit), "DEPLOYED must keep holding the unit in place")
	var deployed_turret = unit.combat()._active_turrets()[0]
	var near_enemy := Doubles.PhysicsCombatTarget.new(
		deployed_turret.muzzle_origin() + Vector3(0.0, 0.0, -3.0)
	)
	var far_enemy := Doubles.PhysicsCombatTarget.new(
		deployed_turret.muzzle_origin() + Vector3(0.0, 0.0, -6.0)
	)
	world.add_child(near_enemy)
	world.add_child(far_enemy)
	near_enemy.add_to_group(&"units")
	far_enemy.add_to_group(&"units")
	unit.combat().advance(0.1)
	var selected_target: WeakRef = unit.combat()._target_acquisition._targets.get(
		deployed_turret.weapon_index()
	) as WeakRef
	_expect(
		selected_target != null and selected_target.get_ref() == near_enemy,
		"the deployed gun must acquire the nearest target anew"
	)
	_expect(
		not unit.prepare_navigation_order(Vector3(20.0, 0.0, 20.0)),
		"a deployed unit must reject new movement orders"
	)

	_expect(unit.undeploy(), "a deployed Kindjal must accept the undeploy command")
	_expect(unit.is_deploying() and not unit.is_deployed(), "undeploy must enter the UNDEPLOYING transition")
	_expect(_active_turret_ids(unit).is_empty(), "no turret may be active mid-transition")
	_expect(nav.is_held(unit), "UNDEPLOYING must still hold the unit in place")

	unit.finish_deployment(true)
	_expect(
		not unit.is_deploying() and not unit.is_deployed(),
		"a consumed UNDEPLOYING finish must land back in TRAVEL"
	)
	_expect(
		_active_turret_ids(unit) == [&"ATKindjalGun"],
		"travel mode must be restored after undeploying"
	)
	_expect(not nav.is_held(unit), "TRAVEL must release the nav hold")
	_expect(
		unit.prepare_navigation_order(Vector3(20.0, 0.0, 20.0)),
		"a travel-mode unit must accept movement orders again"
	)

	world.queue_free()
	await process_frame


func _active_turret_ids(unit: Unit) -> Array[StringName]:
	var ids: Array[StringName] = []
	for turret in unit.combat()._active_turrets():
		ids.append(turret.config.config_id)
	return ids


func _test_combat_deploy_eligibility() -> void:
	var strategy := CombatDeployStrategyScript.new()
	var world := Node3D.new()
	root.add_child(world)

	var kindjal := UnitScene.instantiate() as Unit
	kindjal.config_id = &"ATKindjal"
	world.add_child(kindjal)
	_expect(strategy.can_handle(kindjal), "ATKindjal must be combat-deployable")

	var mortar := UnitScene.instantiate() as Unit
	mortar.config_id = &"ORMortar"
	world.add_child(mortar)
	_expect(strategy.can_handle(mortar), "ORMortar must be combat-deployable")

	var kobra := UnitScene.instantiate() as Unit
	kobra.config_id = &"ORKobra"
	world.add_child(kobra)
	_expect(strategy.can_handle(kobra), "ORKobra must be combat-deployable")

	var sardaukar := UnitScene.instantiate() as Unit
	sardaukar.config_id = &"IMADVSardaukar"
	world.add_child(sardaukar)
	_expect(
		not strategy.can_handle(sardaukar),
		"IMADVSardaukar must not be combat-deployable despite its knife/gun turret pair"
	)

	world.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
