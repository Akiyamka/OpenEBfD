extends SceneTree

## The E2 parity gate drives two real matches through an identical, rich
## input sequence. The arms deliberately do not coexist: Match's simulation
## loop iterates tree-wide groups, so a live first arm would tick under the
## second arm's advance_ticks() call.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimPlaceBuildingCommandScript := preload("res://scripts/sim/commands/place_building_command.gd")
const SimUnitOrderCommandScript := preload("res://scripts/sim/commands/unit_order_command.gd")

const WINDOW_TICKS := 40
const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case("frameless and framed windows agree on the observed simulation state", _test_parity_gate)
	await _run_case("a deferred in-boundary write makes the gate fail without spoiling its start control", _test_in_boundary_control)
	await _run_case("invulnerability can diverge outside the hash boundary while the hash stays equal", _test_out_of_boundary_control)
	if _failures > 0:
		printerr("Frameless parity tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Frameless parity tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	if _assertions == assertions_before:
		_failures += 1
		printerr("FAIL: %s: the case ended before asserting anything" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_parity_gate() -> void:
	var result := await _run_two_arms(false, false)
	_expect(bool(result["starts_equal"]), "setup control: the arms must enter the measured window at equal tick, hash and ids")
	_expect(bool(result["ticks_equal"]), "both arms must advance exactly WINDOW_TICKS ticks")
	_expect(bool(result["scenario_ran"]), "the scenario must place a building, queue a unit, attack, and kill an entity")
	_expect(bool(result["hashes_equal"]), "no-frame and frame-interleaved windows must end with the same observed-state hash")


func _test_in_boundary_control() -> void:
	var result := await _run_two_arms(true, false)
	_expect(bool(result["starts_equal"]), "the deliberate deferred write must happen after the equal-start control")
	_expect(not bool(result["hashes_equal"]), "a deferred write to a stored position must make final hashes differ")
	_expect(bool(result["ticks_equal"]), "the failing control must still run the same tick count in both arms")


func _test_out_of_boundary_control() -> void:
	var result := await _run_two_arms(false, true)
	_expect(bool(result["starts_equal"]), "the invulnerability control must also begin from equal state")
	_expect(
		bool(result["frameless_invulnerable"]) != bool(result["framed_invulnerable"]),
		"the timer-owned invulnerable field must differ after frames run in only one arm"
	)
	_expect(bool(result["hashes_equal"]), "invulnerable is outside SimEntityState, so its divergence must not change the hash")


func _run_two_arms(defer_position_write: bool, diverge_invulnerability: bool) -> Dictionary:
	var frameless: Variant = await _boot_arm()
	var frameless_inputs := _prepare_scenario(frameless)
	var frameless_start := _snapshot(frameless, frameless_inputs)
	var frameless_final := await _run_window(frameless, frameless_inputs, false, defer_position_write, diverge_invulnerability)
	await _teardown_arm(frameless)

	var framed: Variant = await _boot_arm()
	var framed_inputs := _prepare_scenario(framed)
	var framed_start := _snapshot(framed, framed_inputs)
	var framed_final := await _run_window(framed, framed_inputs, true, defer_position_write, diverge_invulnerability)
	await _teardown_arm(framed)
	return {
		"starts_equal": frameless_start["tick"] == framed_start["tick"]
			and frameless_start["hash"] == framed_start["hash"]
			and frameless_start["ids"] == framed_start["ids"]
			and frameless_start["inputs"] == framed_start["inputs"],
		"ticks_equal": frameless_final["tick"] == framed_final["tick"]
			and frameless_final["tick"] - frameless_start["tick"] == WINDOW_TICKS,
		"hashes_equal": frameless_final["hash"] == framed_final["hash"],
		"scenario_ran": bool(frameless_final["scenario_ran"]) and bool(framed_final["scenario_ran"]),
		"frameless_invulnerable": frameless_final["invulnerable"],
		"framed_invulnerable": framed_final["invulnerable"],
	}


func _boot_arm() -> Variant:
	var match_instance := MatchFixtureScene.instantiate()
	# Setup frames are intentionally outside the measured window. Disabling the
	# Match process keeps FrameTickDriver from adding ticks while they land.
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	return match_instance


func _prepare_scenario(match_instance) -> Dictionary:
	var controller := match_instance.get_node("BuildingController") as BuildingController
	var placement_cell := _first_buildable_barracks_cell(match_instance, controller)
	var queue = controller.building_queue_for_player(1)
	queue.start(&"ATBarracks", "Barracks", 0, 1)
	queue.advance_tick(0)

	var place := SimPlaceBuildingCommandScript.new()
	place.player_id = 1
	place.building_id = &"ATBarracks"
	place.nav_cell = placement_cell
	place.rotation_quarter_turns = 0
	match_instance._command_bus.submit_at(place, 1)
	var produce := SimUnitOrderCommandScript.new()
	produce.player_id = 1
	produce.unit_id = &"ATMCV"
	produce.button_index = MOUSE_BUTTON_LEFT
	produce.quantity = 1
	match_instance._command_bus.submit_at(produce, 2)

	var scout := match_instance.get_node("Units/ScoutA") as Unit
	var ordos_apc := match_instance.get_node("Units/OrdosAPC") as Unit
	var victim := match_instance.get_node("Buildings/ATSmWindtrap") as Building
	ordos_apc.command_attack(scout)
	return {
		"placement_cell": placement_cell,
		"scout_id": scout.entity_id,
		"attacker_id": ordos_apc.entity_id,
		"victim_id": victim.entity_id,
		"victim": victim,
		"attacker": ordos_apc,
	}


func _snapshot(match_instance, inputs: Dictionary) -> Dictionary:
	return {
		"tick": match_instance.current_tick(),
		"hash": match_instance.entity_state().state_hash(),
		"ids": {
			"scout": inputs["scout_id"], "attacker": inputs["attacker_id"], "victim": inputs["victim_id"],
		},
		"inputs": {"place": inputs["placement_cell"], "unit": &"ATMCV", "kill_tick": 3},
	}


func _run_window(
		match_instance, inputs: Dictionary, framed: bool, defer_position_write: bool, diverge_invulnerability: bool
	) -> Dictionary:
	var attacker := inputs["attacker"] as Unit
	var victim := inputs["victim"] as Building
	if defer_position_write:
		attacker.call_deferred("set_simulation_position", attacker.simulation_position() + Vector3(3.0, 0.0, 0.0))
	if diverge_invulnerability:
		attacker.grant_temporary_invulnerability(0.01)
	for tick_index in WINDOW_TICKS:
		if tick_index == 3 and is_instance_valid(victim):
			victim.request_despawn()
		if tick_index == 4:
			var production = match_instance.get_node("UnitProductionSystem") as UnitProductionSystem
			production.spawn_completed_unit(1, &"ATMCV", &"ATConYard")
			var produced_scout := match_instance.get_node_or_null("Units/ATMCV") as Unit
			if produced_scout != null:
				produced_scout.stop_at_current_position()
		match_instance.advance_ticks(1)
		if framed:
			await process_frame
	var barracks_present := _has_building(match_instance, &"ATBarracks")
	var scout_produced := _has_unit(match_instance, &"ATMCV")
	var victim_released: bool = not match_instance.entity_index().registry().is_alive(int(inputs["victim_id"]))
	return {
		"tick": match_instance.current_tick(),
		"hash": match_instance.entity_state().state_hash(),
		"scenario_ran": barracks_present and scout_produced and victim_released and attacker.has_attack_order(),
		"invulnerable": attacker.invulnerable,
	}


func _teardown_arm(match_instance) -> void:
	match_instance.queue_free()
	await process_frame
	await process_frame
	for group_name in SIM_GROUPS:
		_expect(get_nodes_in_group(group_name).is_empty(), "teardown must leave %s empty before the next arm" % group_name)


func _has_building(match_instance, config_id: StringName) -> bool:
	for node in match_instance.get_node("Buildings").get_children():
		var building := node as Building
		if building != null and building.config_id == config_id:
			return true
	return false


func _has_unit(match_instance, config_id: StringName) -> bool:
	for node in match_instance.get_node("Units").get_children():
		var unit := node as Unit
		if unit != null and unit.config_id == config_id:
			return true
	return false


func _first_buildable_barracks_cell(match_instance, controller: BuildingController) -> Vector2i:
	var config = controller._building_config(&"ATBarracks")
	var occupy_rows: Array[String] = controller._building_occupy_rows(config)
	controller._building_placement.begin(&"ATBarracks", "Barracks", occupy_rows)
	var grid = match_instance.terrain.navigation_grid
	var center: Vector2i = grid.world_to_grid((match_instance.get_node("Buildings/ATConYard") as Building).global_position)
	for radius in range(4, 24):
		for x in range(-radius, radius + 1):
			for y in [-radius, radius]:
				var candidate := center + Vector2i(x, y)
				if controller._building_placement.evaluate_at_hover_cell(candidate) == BuildingPlacement.PlaceResult.AVAILABLE:
					controller._building_placement.cancel()
					return candidate
	controller._building_placement.cancel()
	return Vector2i.ZERO
