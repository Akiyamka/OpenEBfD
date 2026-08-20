extends SceneTree
## Flying-unit movement/altitude/avoidance/animation-state-machine tests.
## Follows the _expect/_run_case convention from tests/units/deployment_run.gd
## and the FakeUnit duck-typed-Node3D convention from tests/navigation/run.gd.

const UnitScene := preload("res://scenes/units/unit.tscn")
const ATOrniScene := preload("res://scenes/units/at_orni.tscn")
const CarryallScene := preload("res://scenes/units/carryall.tscn")
const ATADVCarryallScene := preload("res://scenes/units/atadv_carryall.tscn")
const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const UnitNavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")
const UnitLocalAvoidanceScript := preload("res://scripts/units/navigation/unit_local_avoidance.gd")
const UnitNavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
const AirNavigationScript := preload("res://scripts/units/navigation/air/air_navigation.gd")
const UnitFlightControllerScript := preload("res://scripts/units/navigation/unit_flight_controller.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


## Duck-typed test double for the vertical-avoidance and building-ignoring
## tests: only implements the flight-facing surface UnitLocalAvoidance calls
## via has_method()/call(), not a real UnitFlightController.
class FakeFlyingUnit extends Node3D:
	var airborne := true
	var last_vertical_offset := 0.0
	var move_speed := 5.0

	func flight_is_airborne_phase() -> bool:
		return airborne

	func flight_set_vertical_offset(value: float) -> void:
		last_vertical_offset = value

	func navigation_move_speed() -> float:
		return move_speed


class FakeLockedFlyingUnit extends FakeFlyingUnit:
	var last_navigation_velocity := Vector3.INF

	func flight_navigation_is_locked() -> bool:
		return true

	func navigation_step(value: Vector3, _delta: float) -> void:
		last_navigation_velocity = value


class FakeSpatialHash extends RefCounted:
	func nearby(_position: Vector3, _buckets: Dictionary, _radius: float) -> Array:
		return []


class FakeLateralAvoidance extends RefCounted:
	var calls := 0

	func separation_velocity(_agent: Dictionary, _nearby: Array) -> Vector3:
		calls += 1
		return Vector3(99.0, 0.0, 0.0)

func _initialize() -> void:
	await process_frame
	_run_case("generated UnitDefinitions carry the correct flight flags", _test_definition_flags)
	_run_case("a flight controller exists only for CanFly units", _test_flight_controller_gating)
	_run_case("hangar spawn moves outside before climbing to height_offset", _test_hangar_takeoff_sequence)
	_run_case("every flying scene exposes the airborne animation state machine", _test_flight_clip_catalog)
	_run_case("flyers transition between Fly and Hover", _test_flyer_cruise_animation)
	_run_case("Circles flyers cruise continuously with banked turns", _test_circles_fixed_wing_cruise)
	_run_case("Circles Stop enters idle cruise", _test_circles_stop_enters_idle_cruise)
	_run_case("air orders share their clamped destination with Circles flight", _test_circles_order_uses_bounded_destination)
	_run_case("locked flight rejects lateral separation", _test_locked_flight_rejects_lateral_separation)
	_run_case("pickup clips hold docking height before Takeoff ascends", _test_pickup_takeoff_altitude)
	_run_case("a non-Ornithopter, non-carrier flyer can never land", _test_non_ornithopter_never_lands)
	_run_case("an Ornithopter can land, then take off again on its next order", _test_ornithopter_land_takeoff_round_trip)
	_run_case("converging air agents separate vertically, then decay back to level", _test_vertical_avoidance)
	_run_case("cruise altitude reacts slowly to narrow terrain peaks", _test_cruise_altitude_inertia)
	_run_case("buildings block routes/collision only while landing, not at cruise", _test_buildings_ignored_at_cruise)
	if _failures > 0:
		printerr("Flight tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Flight tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_definition_flags() -> void:
	var at_orni := load("res://resources/units/definitions/ATOrni.tres")
	var hk_gunship := load("res://resources/units/definitions/HKGunship.tres")
	var carryall := load("res://resources/units/definitions/Carryall.tres")
	var atadv_carryall := load("res://resources/units/definitions/ATADVCarryall.tres")
	var stunt := load("res://resources/units/definitions/StuntATADVCarryall.tres")

	_expect(bool(at_orni.can_fly) and bool(at_orni.ornithoptor),
		"ATOrni must fly and be an Ornithopter")
	_expect(not bool(at_orni.carryall) and not bool(at_orni.advanced_carryall),
		"ATOrni must not be any kind of carryall")
	_expect(bool(hk_gunship.ornithoptor), "HKGunship must be an Ornithopter")
	_expect(bool(carryall.carryall) and not bool(carryall.ornithoptor),
		"Carryall must be a plain carryall, not an Ornithopter")
	_expect(bool(carryall.circles), "Carryall must preserve Rules.txt Circles = TRUE")
	_expect(bool(atadv_carryall.advanced_carryall) and not bool(atadv_carryall.carryall),
		"ATADVCarryall must be an advanced carryall, not a plain one")
	_expect(not bool(atadv_carryall.circles), "ATADVCarryall must preserve Rules.txt Circles = FALSE")
	_expect(not bool(stunt.can_fly),
		"StuntATADVCarryall is a cosmetic ground-locked variant and must not fly")


func _test_flight_controller_gating() -> void:
	var flyer := ATOrniScene.instantiate()
	root.add_child(flyer)
	_expect(flyer.has_method("flight_is_airborne_phase"), "Unit must expose flight_is_airborne_phase")
	_expect(not flyer.flight_is_airborne_phase(), "a freshly spawned flyer starts grounded, not airborne")
	_expect(flyer.flight_is_landed(), "a freshly spawned flyer counts as landed")
	flyer.free()

	var ground := UnitScene.instantiate()
	root.add_child(ground)
	ground.setup(&"ATInfantry")
	_expect(not ground.flight_is_airborne_phase(), "a ground unit is never airborne")
	_expect(ground.flight_is_landed(), "a ground unit is always considered landed")
	ground.free()


func _test_hangar_takeoff_sequence() -> void:
	var flyer: Unit = ATOrniScene.instantiate()
	root.add_child(flyer)
	# ATOrni's authored turn_rate is slow and can_move_any_direction is false;
	# bypass turning entirely (an instance-only override, not the shared
	# UnitDefinition resource) so this test isolates takeoff/cruise altitude
	# and animation behavior from unrelated turn-rate timing.
	flyer.can_move_any_direction = true
	# Far enough that 20 ticks of forward movement never gets within
	# arrival_radius of it — a near rally point oscillates back and forth
	# across arrival_radius every tick (velocity*delta far exceeds the radius),
	# flickering between Fly and Hover non-deterministically.
	var rally: Vector3 = flyer.global_position + Vector3(1000.0, 0.0, 0.0)
	var exit_point: Vector3 = flyer.global_position + Vector3(4.0, 0.0, 0.0)
	flyer.begin_hangar_takeoff(rally, exit_point)

	var player := _first_player_with(flyer, &"Takeoff")
	_expect(player != null, "the converted Ornithopter model must have a Takeoff clip")
	if player != null:
		_expect(player.current_animation == &"Move", "a hangar spawn must move toward its exit before Takeoff")

	var spawn_y: float = flyer.global_position.y
	var moved_out := false
	# 125 ticks at the 25 Hz simulation rate matches the old budget of 100
	# calls at a hand-picked 0.05s delta (100 * 0.05 = 125 * SECONDS_PER_TICK
	# = 5.0s): sim_tick() no longer takes a delta, it always advances by
	# exactly one tick, so the loop count is what has to grow instead.
	for i in 125:
		flyer.sim_tick()
		if flyer._flight_controller.flight_is_taking_off():
			moved_out = true
			break
		_expect(is_equal_approx(flyer.global_position.y, spawn_y),
			"the aircraft must remain at spawn height while leaving the hangar")

	_expect(moved_out, "the aircraft must reach the hangar exit and begin Takeoff")
	_expect(flyer.global_position.distance_to(exit_point) <= flyer.arrival_radius + 0.001,
		"Takeoff must begin only after the aircraft reaches the building exit")
	if player != null:
		_expect(player.current_animation == &"Takeoff", "reaching the hangar exit must start Takeoff")

	var takeoff_start: Vector3 = flyer.global_position
	var last_y: float = flyer.global_position.y
	var climbed := false
	# 100 ticks preserves the old 4.0s budget (20 * 0.2 = 100 * SECONDS_PER_TICK).
	for i in 100:
		flyer.sim_tick()
		_expect(flyer.global_position.y >= last_y - 0.0001,
			"altitude must climb monotonically during takeoff")
		if flyer.global_position.y > last_y + 0.0001:
			climbed = true
		last_y = flyer.global_position.y
		if not flyer._flight_controller.flight_is_taking_off():
			break

	_expect(climbed, "altitude must have actually increased during takeoff")
	var takeoff_horizontal := flyer.global_position - takeoff_start
	takeoff_horizontal.y = 0.0
	_expect(takeoff_horizontal.length() > 0.01,
		"an aircraft with a rally order must move toward it while taking off")
	_expect(flyer.global_position.distance_to(rally) < takeoff_start.distance_to(rally),
		"takeoff motion must reduce the remaining distance to the rally point")
	_expect(is_equal_approx(flyer.global_position.y,
		UnitFlightControllerScript.BASE_FLIGHT_ALTITUDE
		+ float(flyer.unit_definition.height_offset) * UnitFlightControllerScript.HEIGHT_OFFSET_WORLD_SCALE),
		"takeoff must finish at the base flight level plus scaled height_offset above ground")
	_expect(flyer.flight_is_airborne_phase(), "the unit must be cruising once the climb completes")
	if player != null:
		_expect(player.current_animation == &"Fly",
			"once cruising toward the rally point, the animation must switch to Fly")
	flyer.free()


func _test_flight_clip_catalog() -> void:
	var definitions := DirAccess.open("res://resources/units/definitions")
	_expect(definitions != null, "generated unit definitions must be readable")
	if definitions == null:
		return
	for file_name in definitions.get_files():
		if file_name.get_extension() != "tres":
			continue
		var definition = load("res://resources/units/definitions/%s" % file_name)
		if definition == null or not bool(definition.can_fly):
			continue
		var packed := load(String(definition.scene_path)) as PackedScene
		var flyer := packed.instantiate() as Unit if packed != null else null
		_expect(flyer != null, "%s flying scene must instantiate" % definition.config_id)
		if flyer == null:
			continue
		root.add_child(flyer)
		for clip_name in [&"Fly", &"Hover", &"FlyToHover", &"HoverToFly"]:
			_expect(
				_first_player_with(flyer, clip_name) != null,
				"%s must expose the %s flight clip" % [definition.config_id, clip_name]
			)
		flyer.free()


func _test_flyer_cruise_animation() -> void:
	for model_case in [
		{"name": "ATOrni", "scene": ATOrniScene},
		{"name": "Carryall", "scene": CarryallScene},
		{"name": "ATADVCarryall", "scene": ATADVCarryallScene},
	]:
		var flyer: Unit = (model_case["scene"] as PackedScene).instantiate()
		root.add_child(flyer)
		flyer.can_move_any_direction = true
		var target := flyer.global_position + Vector3(1000.0, 0.0, 0.0)
		flyer.begin_hangar_takeoff(target, Vector3.INF)
		var player := _first_player_with(flyer, &"Fly")
		_expect(
			player != null,
			"the converted %s model must expose its Fly clip" % model_case["name"]
		)
		_fast_forward_takeoff(flyer)
		for _frame in 4:
			flyer.sim_tick()
		_expect(
			flyer.flight_is_airborne_phase(),
			"%s must reach cruise" % model_case["name"]
		)
		_expect(
			player != null and player.current_animation == &"Fly",
			"a moving %s must cruise with Fly" % model_case["name"]
		)
		if player != null:
			_expect(
				player.get_animation(&"Fly").loop_mode == Animation.LOOP_LINEAR,
				"the %s Fly clip must loop for the whole cruise" % model_case["name"]
			)
			if bool(flyer.unit_definition.circles):
				flyer.flight_set_movement_animation(false)
				_expect(player.current_animation == &"Fly",
					"a stopping Circles flyer must remain in Fly")
				flyer.free()
				continue
			flyer.flight_set_movement_animation(false)
			_expect(
				player.current_animation == &"FlyToHover",
				"a stopping %s must transition through FlyToHover" % model_case["name"]
			)
			player.animation_finished.emit(&"FlyToHover")
			_expect(
				player.current_animation == &"Hover"
				and player.get_animation(&"Hover").loop_mode == Animation.LOOP_LINEAR,
				"a stopped %s must loop Hover" % model_case["name"]
			)
			flyer.flight_set_movement_animation(true)
			_expect(
				player.current_animation == &"HoverToFly",
				"a restarting %s must transition through HoverToFly" % model_case["name"]
			)
			player.animation_finished.emit(&"HoverToFly")
			_expect(
				player.current_animation == &"Fly",
				"a moving %s must return to Fly" % model_case["name"]
			)
		flyer.free()


func _test_circles_fixed_wing_cruise() -> void:
	var circling: Unit = CarryallScene.instantiate()
	root.add_child(circling)
	circling.begin_hangar_takeoff(circling.global_position, Vector3.INF)
	_fast_forward_takeoff(circling)
	var player := _first_player_with(circling, &"Fly")
	circling.flight_set_circles_order(circling.global_position)
	var start := circling.global_position
	var yaw_before := circling.global_rotation.y
	# A single sim_tick() call is a single step of exactly
	# MatchClockScript.SECONDS_PER_TICK -- the formulas below measure "how far
	# does one step move/turn the aircraft", so they must use that same
	# constant rather than the 0.05 this suite used to hand-pick per call.
	circling.sim_tick()
	var offset := circling.global_position - start
	offset.y = 0.0
	_expect(offset.length() > 0.1,
		"an idle Circles flyer must keep moving")
	_expect(
		is_equal_approx(
			offset.length(),
			circling.navigation_move_speed() / 3.0 * MatchClockScript.SECONDS_PER_TICK
		),
		"idle Circles speed must be exactly one third of its maximum speed"
	)
	_expect(player != null and player.current_animation == &"Fly",
		"idle Circles flight must use Fly rather than Hover")
	var idle_yaw_step := absf(angle_difference(yaw_before, circling.global_rotation.y))
	var expected_idle_yaw_step := circling.turn_rate \
		* UnitFlightControllerScript.MOVEMENT_UPDATES_PER_SECOND \
		* UnitFlightControllerScript.IDLE_CRUISE_TURN_RATE_SCALE \
		* MatchClockScript.SECONDS_PER_TICK
	_expect(is_equal_approx(idle_yaw_step, expected_idle_yaw_step),
		"idle cruising must use the broad one-sixth-turn-rate orbit")
	var idle_radius := circling.navigation_move_speed() \
		* UnitFlightControllerScript.IDLE_CRUISE_SPEED_SCALE \
		/ (circling.turn_rate * UnitFlightControllerScript.MOVEMENT_UPDATES_PER_SECOND \
		* UnitFlightControllerScript.IDLE_CRUISE_TURN_RATE_SCALE)
	_expect(idle_radius >= 20.0,
		"Carryall idle cruise radius must be broadly expanded (got %.2f)" % idle_radius)

	var forward := circling.facing_direction()
	var behind := circling.global_position - forward * 60.0
	start = circling.global_position
	circling.flight_set_circles_order(behind)
	circling.sim_tick()
	offset = circling.global_position - start
	offset.y = 0.0
	_expect(offset.length() > 0.1,
		"a Circles flyer must continue forward while turning toward a rear order")
	_expect(absf(circling._flight_controller._visual_bank) > 0.01,
		"a non-zero yaw rate must produce a visible bank")
	var reached_behind := false
	# 625 ticks preserves the old 25.0s budget (500 * 0.05 = 625 * SECONDS_PER_TICK).
	for _frame in 625:
		circling.sim_tick()
		if not circling._flight_controller.circles_order_is_active():
			reached_behind = true
			break
	_expect(reached_behind,
		"a rear order must complete through forward curved flight rather than a turn in place")
	var ordered_bank_sign := -signf(circling._flight_controller._circles_idle_turn_sign)
	circling.sim_tick()
	_expect(signf(circling._flight_controller._visual_bank) == ordered_bank_sign,
		"idle cruising must preserve the final non-zero ordered-turn bank direction")

	var close_target := circling.global_position - circling.facing_direction()
	circling.flight_set_circles_order(close_target)
	circling.sim_tick()
	_expect(circling._flight_controller._circles_departure.is_finite(),
		"a close target must first receive a forward departure manoeuvre")
	var reached_close := false
	# Same 625-tick budget as the "reached_behind" loop above, same reason.
	for _frame in 625:
		circling.sim_tick()
		if not circling._flight_controller.circles_order_is_active():
			reached_close = true
			break
	_expect(reached_close,
		"a close rear target must complete after its one planned departure manoeuvre")
	start = circling.global_position
	circling.sim_tick()
	offset = circling.global_position - start
	offset.y = 0.0
	_expect(
		is_equal_approx(
			offset.length(),
			circling.navigation_move_speed() / 3.0 * MatchClockScript.SECONDS_PER_TICK
		),
		"completing a close order must resume one-third-speed idle cruising"
	)
	circling.free()

	var stationary: Unit = ATADVCarryallScene.instantiate()
	root.add_child(stationary)
	stationary.begin_hangar_takeoff(stationary.global_position, Vector3.INF)
	_fast_forward_takeoff(stationary)
	player = _first_player_with(stationary, &"FlyToHover")
	stationary.flight_set_movement_animation(false)
	if player != null and player.current_animation == &"FlyToHover":
		player.animation_finished.emit(&"FlyToHover")
	start = stationary.global_position
	# 25 ticks preserves the old single-call 1.0s budget (25 * SECONDS_PER_TICK
	# = 1.0s), so this still confirms the hover point holds over a full second,
	# not just one 0.04s tick.
	for _tick in 25:
		stationary.sim_tick()
	offset = stationary.global_position - start
	offset.y = 0.0
	_expect(offset.length() < 0.001,
		"a Circles = FALSE flyer must stay at its hover point")
	stationary.free()


func _test_circles_stop_enters_idle_cruise() -> void:
	var navigation := UnitNavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(_make_grid()), "test navigation system must initialize")
	var circling: Unit = CarryallScene.instantiate()
	root.add_child(circling)
	navigation.register_unit(circling)
	circling.begin_hangar_takeoff(circling.global_position + Vector3(80.0, 0.0, 0.0), Vector3.INF)
	_fast_forward_takeoff(circling)
	circling.flight_set_circles_order(circling.global_position + circling.facing_direction() * 80.0)
	_expect(circling.has_active_move_order(), "a Circles move must be active before Stop")
	navigation.stop(circling)
	_expect(not circling.has_active_move_order(), "Stop must clear the Circles active-order state")
	var start := circling.global_position
	circling.navigation_step(Vector3.ZERO, 0.05)
	var offset := circling.global_position - start
	offset.y = 0.0
	_expect(is_equal_approx(offset.length(), circling.navigation_move_speed() / 3.0 * 0.05),
		"Stop must retain one-third-speed idle cruising rather than stop the aircraft")
	circling.free()
	navigation.free()


func _test_circles_order_uses_bounded_destination() -> void:
	var grid := _make_grid()
	var runtime_map := UnitNavigationMapScript.new()
	_expect(runtime_map.setup(grid), "test runtime map must initialize")
	var air := AirNavigationScript.new()
	air.setup(FakeAirFacade.new(), runtime_map)
	var circling: Unit = CarryallScene.instantiate()
	root.add_child(circling)
	circling.begin_hangar_takeoff(circling.global_position, Vector3.INF)
	_fast_forward_takeoff(circling)
	var agent := {
		"unit": circling,
		"id": 1,
		"hold": false,
		"destination": circling.global_position,
	}
	var outside := Vector3(-100.0, 0.0, 10000.0)
	air.route_agent(agent, circling.global_position, outside)
	_expect((agent["destination"] as Vector3).is_equal_approx(air.clamp_to_bounds(outside)),
		"air agent destination must be clamped")
	_expect(circling._flight_controller._circles_destination.is_equal_approx(agent["destination"] as Vector3),
		"Circles controller must receive the same clamped destination as its agent")
	circling.free()


func _test_locked_flight_rejects_lateral_separation() -> void:
	var air := AirNavigationScript.new()
	var avoidance := FakeLateralAvoidance.new()
	var spatial_hash := FakeSpatialHash.new()
	var locked := FakeLockedFlyingUnit.new()
	root.add_child(locked)
	var agent := {
		"unit": locked,
		"id": 1,
		"radius": 1.0,
		"pass_mask": MapNavigationGrid.PASS_AIR,
		"hold": false,
		"destination": Vector3(20.0, 0.0, 0.0),
	}
	var agents := {locked.get_instance_id(): agent}
	air.setup(FakeAirFacade.new(), null, avoidance, agents, spatial_hash)
	air.tick(0.05, [agent], {})
	_expect(locked.last_navigation_velocity.is_zero_approx(),
		"landing/pickup lock must receive zero horizontal navigation velocity")
	_expect(avoidance.calls == 0,
		"landing/pickup lock must not receive a lateral-separation velocity")
	locked.free()


func _test_pickup_takeoff_altitude() -> void:
	var carrier: Unit = ATADVCarryallScene.instantiate()
	root.add_child(carrier)
	carrier.global_position = Vector3(5.0, 9.0, 5.0)
	carrier.flight_begin_pickup_sequence(carrier.global_position, 2.0)
	# 100 ticks preserves the old 4.0s budget (20 * 0.2 = 100 * SECONDS_PER_TICK).
	for _frame in 100:
		carrier.sim_tick()
		if carrier.flight_pickup_transition_finished():
			break
	_expect(carrier.flight_pickup_transition_finished(),
		"Land clip must complete before docking clip test")
	_expect(is_equal_approx(carrier.global_position.y, 11.0),
		"transport landing clearance must stop its root above terrain")
	var docking_y := carrier.global_position.y
	carrier.flight_advance_pickup(UnitFlightControllerScript.Phase.PICKUP_START)
	_assert_stationary_transport_clip(carrier, docking_y, &"StartPickup")
	carrier.flight_advance_pickup(UnitFlightControllerScript.Phase.PICKUP_LIFT)
	_assert_stationary_transport_clip(carrier, docking_y, &"Pickup")
	carrier.flight_advance_pickup(UnitFlightControllerScript.Phase.PICKUP_END)
	_assert_stationary_transport_clip(carrier, docking_y, &"EndPickup")
	carrier.flight_complete_pickup_sequence()
	var previous_y := carrier.global_position.y
	# 100 ticks preserves the old 4.0s budget (40 * 0.1 = 100 * SECONDS_PER_TICK).
	for _frame in 100:
		carrier.sim_tick()
		var current_y := carrier.global_position.y
		_expect(current_y > previous_y + 0.0001,
			"Takeoff must raise the transport on every tick")
		previous_y = current_y
		if carrier.flight_transport_takeoff_finished():
			break
	_expect(carrier.flight_transport_takeoff_finished(),
		"Takeoff must finish at cruise altitude")
	_expect(previous_y > docking_y + 0.01,
		"Takeoff must perform the complete vertical ascent")
	carrier.free()


func _assert_stationary_transport_clip(
	carrier: Unit, docking_y: float, phase_name: StringName
) -> void:
	# 100 ticks preserves the old 4.0s budget (40 * 0.1 = 100 * SECONDS_PER_TICK).
	for _frame in 100:
		carrier.sim_tick()
		_expect(is_equal_approx(carrier.global_position.y, docking_y),
			"%s must hold the transport at docking height" % phase_name)
		if carrier.flight_pickup_transition_finished():
			break
	_expect(carrier.flight_pickup_transition_finished(),
		"%s docking clip must complete" % phase_name)


func _test_non_ornithopter_never_lands() -> void:
	var flyer: Unit = UnitScene.instantiate()
	root.add_child(flyer)
	flyer.setup(&"ATADP")
	_expect(bool(flyer.unit_definition.can_fly)
		and not bool(flyer.unit_definition.ornithoptor)
		and not bool(flyer.unit_definition.carryall)
		and not bool(flyer.unit_definition.advanced_carryall),
		"ATADP must fly but carry none of the landing-capable flags")

	flyer.begin_hangar_takeoff(flyer.global_position, Vector3.INF)
	_fast_forward_takeoff(flyer)
	_expect(flyer.flight_is_airborne_phase(), "must reach cruise before testing the landing gate")

	var accepted: bool = flyer.flight_request_land(flyer.global_position, {})
	_expect(not accepted, "a non-Ornithopter, non-carrier flyer must reject a landing request")
	_expect(flyer.flight_is_airborne_phase(), "the rejected landing request must leave the unit airborne")
	flyer.free()


func _test_ornithopter_land_takeoff_round_trip() -> void:
	var flyer: Unit = ATOrniScene.instantiate()
	root.add_child(flyer)
	flyer.can_move_any_direction = true
	flyer.begin_hangar_takeoff(flyer.global_position, Vector3.INF)
	_fast_forward_takeoff(flyer)
	_expect(flyer.flight_is_airborne_phase(), "must reach cruise before requesting a landing")

	# No terrain collider exists in this synthetic test, so _sample_ground_altitude
	# falls back to the target position's own Y — give it a ground-level Y (0.0)
	# rather than the flyer's current cruise-altitude Y, or there is nothing to
	# descend to.
	var land_target: Vector3 = Vector3(flyer.global_position.x + 60.0, 0.0, flyer.global_position.z)
	var accepted: bool = flyer.flight_request_land(land_target, {})
	_expect(accepted, "an Ornithopter must be allowed to request a landing")

	var player := _first_player_with(flyer, &"Land")
	if player != null:
		_expect(player.current_animation != &"Land",
			"a distant landing request must approach before playing Land")

	var approach_y := flyer.global_position.y
	var landing_started := false
	# 125 ticks preserves the old 5.0s budget (100 * 0.05 = 125 * SECONDS_PER_TICK).
	for _frame in 125:
		flyer.sim_tick()
		if flyer._flight_controller.phase == UnitFlightControllerScript.Phase.LANDING:
			landing_started = true
			break
		_expect(is_equal_approx(flyer.global_position.y, approach_y),
			"the aircraft must stay at cruise height before entering the Land radius")
	_expect(landing_started, "the aircraft must begin Land on its final approach")
	var land_start_offset := land_target - flyer.global_position
	land_start_offset.y = 0.0
	_expect(land_start_offset.length() > flyer.arrival_radius + 0.01,
		"Land must begin before the aircraft is directly over its destination")
	_expect(land_start_offset.length() <= flyer._flight_controller.flight_landing_approach_radius() + 0.01,
		"Land must begin only after entering its speed-and-duration approach radius")
	if player != null:
		_expect(player.current_animation == &"Land", "final approach must play Land")

	var last_y: float = flyer.global_position.y
	var last_distance := land_start_offset.length()
	var descended := false
	# 50 ticks preserves the old 2.0s budget (20 * 0.1 = 50 * SECONDS_PER_TICK).
	for i in 50:
		flyer.sim_tick()
		_expect(flyer.global_position.y <= last_y + 0.0001,
			"altitude must descend monotonically while landing")
		if flyer.global_position.y < last_y - 0.0001:
			descended = true
		last_y = flyer.global_position.y
		var remaining := land_target - flyer.global_position
		remaining.y = 0.0
		_expect(remaining.length() <= last_distance + 0.0001,
			"the Land clip must keep moving horizontally toward its destination")
		last_distance = remaining.length()
		if flyer.flight_is_landed():
			break

	_expect(descended, "altitude must have actually decreased while landing")
	_expect(flyer.flight_is_landed(), "the unit must be landed once the descent completes")
	var landed_offset := land_target - flyer.global_position
	landed_offset.y = 0.0
	_expect(landed_offset.length() <= 0.001,
		"the horizontal landing approach must finish at the requested point")

	var far_target: Vector3 = flyer.global_position + Vector3(30.0, 0.0, 0.0)
	var takeoff_start := flyer.global_position
	flyer.move_to(far_target)
	_expect(flyer.flight_is_airborne_phase(), "ordering a landed flyer to move must start a fresh takeoff")
	if player != null:
		_expect(player.current_animation == &"Takeoff", "re-launch must play Takeoff again")
	# 100 ticks preserves the old 4.0s budget (40 * 0.1 = 100 * SECONDS_PER_TICK).
	for _frame in 100:
		flyer.sim_tick()
		if not flyer._flight_controller.flight_is_taking_off():
			break
	var takeoff_offset := flyer.global_position - takeoff_start
	takeoff_offset.y = 0.0
	_expect(takeoff_offset.length() > 0.01,
		"a landed aircraft must move toward its order while Takeoff raises it")
	_expect(flyer.global_position.distance_to(far_target) < takeoff_start.distance_to(far_target),
		"Takeoff must reduce the remaining distance to an existing move target")
	_expect(is_equal_approx(flyer.global_position.y,
		UnitFlightControllerScript.BASE_FLIGHT_ALTITUDE
		+ float(flyer.unit_definition.height_offset) * UnitFlightControllerScript.HEIGHT_OFFSET_WORLD_SCALE),
		"re-launch must climb back to the base flight level plus scaled height_offset above ground")
	flyer.free()


func _test_vertical_avoidance() -> void:
	var air := AirNavigationScript.new()
	var low_id := FakeFlyingUnit.new()
	root.add_child(low_id)
	var high_id := FakeFlyingUnit.new()
	root.add_child(high_id)
	var agent_low := {"id": 1, "unit": low_id, "pass_mask": MapNavigationGrid.PASS_AIR}
	var agent_high := {"id": 2, "unit": high_id, "pass_mask": MapNavigationGrid.PASS_AIR}

	air._resolve_vertical_conflict(agent_low, [agent_high])
	_expect(is_equal_approx(low_id.last_vertical_offset, AirNavigationScript.VERTICAL_SEPARATION_OFFSET),
		"the lower agent id must take the positive (fly-over) offset")
	air._resolve_vertical_conflict(agent_high, [agent_low])
	_expect(is_equal_approx(high_id.last_vertical_offset, -AirNavigationScript.VERTICAL_SEPARATION_OFFSET),
		"the higher agent id must take the negative (fly-under) offset")

	air._decay_vertical_offset(agent_low)
	_expect(is_equal_approx(low_id.last_vertical_offset, 0.0),
		"clearing the conflict must retarget the offset back to zero")

	# The controller blends toward the target exponentially rather than
	# snapping — verify it actually moves partway, then converges to ~0.
	var controller := UnitFlightControllerScript.new()
	controller.flight_set_vertical_offset(AirNavigationScript.VERTICAL_SEPARATION_OFFSET)
	controller._advance_vertical_avoidance(0.1)
	_expect(controller._vertical_avoidance_offset > 0.0
		and controller._vertical_avoidance_offset < AirNavigationScript.VERTICAL_SEPARATION_OFFSET,
		"the blend must move partway toward the target on a single tick, not snap")
	controller.flight_set_vertical_offset(0.0)
	for i in 30:
		controller._advance_vertical_avoidance(0.2)
	_expect(absf(controller._vertical_avoidance_offset) < 0.01,
		"the offset must decay back toward zero once clear")

	low_id.free()
	high_id.free()


func _test_cruise_altitude_inertia() -> void:
	var response := UnitFlightControllerScript.TERRAIN_ALTITUDE_RESPONSE
	var altitude := 16.0
	var peak_target := 36.0
	var brief_peak_seconds := 0.2
	var blend := 1.0 - exp(-response * brief_peak_seconds)
	altitude = lerpf(altitude, peak_target, blend)
	_expect(altitude < 18.0,
		"a narrow 20-unit terrain peak must not make an aircraft climb sharply")

	var hover_seconds := 20.0
	blend = 1.0 - exp(-response * hover_seconds)
	altitude = lerpf(altitude, peak_target, blend)
	_expect(altitude > 35.0,
		"an aircraft hovering above high terrain must eventually approach its terrain-relative altitude")


## Duck-typed stand-in for the facade methods AirNavigation.desired_velocity
## actually needs (arrival_tolerance) — deliberately not a real
## UnitNavigationSystem, since the whole point of this test is that the air
## pipeline never touches the grid at all.
class FakeAirFacade extends RefCounted:
	func arrival_tolerance(_unit: Node3D) -> float:
		return 0.2


func _test_buildings_ignored_at_cruise() -> void:
	var grid := _make_grid()
	var runtime_map := UnitNavigationMapScript.new()
	runtime_map.setup(grid)
	var blocked_cell := Vector2i(10, 10)
	runtime_map.replace_blocked_cells({blocked_cell: true})

	var planner := UnitNavigationPlannerScript.new()
	planner.setup(runtime_map)
	_expect(not planner.is_open(blocked_cell, MapNavigationGrid.PASS_VEHICLE, 0),
		"route planning must still treat the building cell as blocked for a ground pass mask")

	# Air no longer builds a grid profile or consults ground solidity at all —
	# its steering is a straight line to the destination regardless of what
	# blocks ground traffic there (see air/air_navigation.gd).
	var air := AirNavigationScript.new()
	air.setup(FakeAirFacade.new())
	var flyer := FakeFlyingUnit.new()
	root.add_child(flyer)
	flyer.global_position = grid.grid_to_world(Vector2i(8, 10))
	var destination := grid.grid_to_world(Vector2i(12, 10))
	var agent := {
		"unit": flyer,
		"id": 1,
		"pass_mask": MapNavigationGrid.PASS_AIR,
		"hold": false,
		"destination": destination,
	}
	var velocity: Vector3 = air.desired_velocity(agent)
	var direct := destination - flyer.global_position
	direct.y = 0.0
	_expect(not velocity.is_zero_approx() and velocity.normalized().is_equal_approx(direct.normalized()),
		"a flying agent must steer straight through a cell that blocks ground traffic")
	flyer.free()


func _fast_forward_takeoff(unit: Node3D) -> void:
	# 100 ticks at the 25 Hz simulation rate = 4.0s (100 * SECONDS_PER_TICK),
	# preserving the old 20 * 0.2s budget: comfortably past both the authored
	# clip length and the DEFAULT_TAKEOFF_SECONDS/DEFAULT_LAND_SECONDS fallback.
	# sim_tick() no longer takes a delta -- it always advances by exactly one
	# tick -- so the loop count is what has to grow to keep the same budget.
	for i in 100:
		unit.sim_tick()


func _first_player_with(unit: Node3D, clip_name: StringName) -> AnimationPlayer:
	for node in unit.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		if player.has_animation(clip_name):
			return player
	return null


func _make_grid() -> MapNavigationGrid:
	var total := MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE
	var cpf := PackedInt32Array()
	var terrain := PackedInt32Array()
	var source_x := PackedInt32Array()
	var source_y := PackedInt32Array()
	var spice := PackedByteArray()
	var pass_mask := PackedInt32Array()
	var movement_cost := PackedFloat32Array()
	var buildable := PackedByteArray()
	for array in [cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable]:
		array.resize(total)
	terrain.fill(MapNavigationGrid.TERRAIN_ROCK)
	pass_mask.fill(MapNavigationGrid.PASS_GROUND | MapNavigationGrid.PASS_AIR)
	movement_cost.fill(1.0)
	buildable.fill(1)
	var grid := MapNavigationGrid.new()
	grid.load_generated(
		"test", AABB(Vector3.ZERO, Vector3(256.0, 1.0, 256.0)), 1.0,
		cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable, {}, {}
	)
	return grid


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
