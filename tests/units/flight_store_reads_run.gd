extends SceneTree

## Slice R5's binding for the flight migration, and the first one in this
## program that runs on the real path rather than at a test double.
##
## R3 and R4 both reported the same structural fact and could only name it:
## inside a match SimEntityState and the node hold the same number, so
## `unit.global_position` and `unit.simulation_position()` return the same
## value, no integration suite can tell a store reader from a node reader, and
## the binding has to live where a disagreement can be manufactured. For those
## two slices that meant a double -- `FakeUnit.set_simulation_position_override()`
## in tests/navigation/run.gd -- because the modules they migrated are
## duck-typed on a `Node3D` and their suites have no `Match` in the tree at all.
##
## Flight is different, and that is what this file is for. `UnitFlightController`
## is constructed by `Unit` itself (Unit._apply_unit_definition(), only when
## `unit_definition.can_fly`), holds a real `Unit` in `_unit`, and is driven
## with one. So the disagreement can be manufactured on the real object: boot
## the real match fixture, add a real flying unit under it, then write the store
## behind the node's back with `store.set_position(id, ...)` and leave
## `global_position` where it was. That is exactly the rogue write
## tests/match/entity_state_run.gd's poke cases already perform, used here as a
## fixture rather than as the thing under test -- there is no double anywhere in
## this file, no `simulation_position()` stand-in, and nothing that could answer
## correctly because a fake was told to.
##
## Every case has the same three steps, and the middle one is the point: put the
## unit somewhere, split the store away from the node, drive one real flight
## step, and assert the controller followed the **store**. Most cases also
## assert the split was real -- that a node-side read would genuinely have
## produced a different answer -- because a case where the two agree passes
## either way and proves nothing.
##
## One fixture, booted once, and every case runs synchronously against it. That
## is deliberate rather than thrifty: with no `await` inside a case the match
## cannot tick between the poke and the step, so nothing re-mirrors the store
## from the node in the middle of a measurement -- which is precisely what
## `Unit.navigation_step()` and `UnitTerrainAlignment.snap_body_to_terrain()`
## would do on the very next tick, both of them ending in
## `set_simulation_position()` and closing any divergence they find. A real
## unit's store/node disagreement survives exactly until its next simulation
## tick, so these cases take their measurement inside that window instead of
## pretending the window is wider than it is.

const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
## ATADVCarryall: Circles = FALSE and advanced_carryall = TRUE, so it can enter
## the landing and pickup sequences without also being a fixed-wing aircraft.
const FlyerScene := preload("res://scenes/units/atadv_carryall.tscn")
## Carryall: Circles = TRUE, the fixed-wing horizontal integrator's own unit.
const CirclesFlyerScene := preload("res://scenes/units/carryall.tscn")
const UnitFlightControllerScript := preload(
	"res://scripts/units/navigation/unit_flight_controller.gd"
)
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

## Somewhere on the fixture map's terrain, clear of the three authored units at
## x 121..130, z 22..29.
const FLYER_HOME := Vector3(126.0, 20.0, 34.0)
const CIRCLES_HOME := Vector3(112.0, 20.0, 34.0)
## Far enough off the fixture map that Unit._terrain_hit_at() finds nothing, so
## the two altitude samplers fall back to the position they were handed -- which
## is how a terrain probe's *input* becomes observable at all.
const OFF_MAP := Vector3(5000.0, 60.0, 5000.0)

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	await process_frame
	var fixture: Node = MatchFixtureScene.instantiate()
	get_root().add_child(fixture)
	for _warmup in 5:
		await process_frame

	var store = fixture.call("entity_state")
	_expect(store != null, "the match fixture must expose a live SimEntityState")
	if store == null:
		_finish()
		return

	var flyer: Unit = await _add_flyer(fixture, FlyerScene, FLYER_HOME, store)
	var circles_flyer: Unit = await _add_flyer(fixture, CirclesFlyerScene, CIRCLES_HOME, store)
	if flyer == null or circles_flyer == null:
		_finish()
		return
	_expect(
		bool(circles_flyer._flight_controller.circles),
		"the Carryall fixture unit must be a Circles aircraft, or its cases test the wrong integrator"
	)

	_run("cruise flight moves from the store's position, not the node's",
		_test_cruise_advance_reads_the_store.bind(flyer, store))
	_run("the hangar walk-out integrates from the store's position",
		_test_hangar_exit_reads_the_store.bind(flyer, store))
	_run("whether there is a hangar walk-out at all is decided from the store",
		_test_hangar_takeoff_decision_reads_the_store.bind(flyer, store))
	_run("takeoff samples the ground under the store's position",
		_test_takeoff_ground_sample_reads_the_store.bind(flyer, store))
	_run("the takeoff/land climb keeps the store's horizontal position",
		_test_vertical_transition_reads_the_store.bind(flyer, store))
	_run("the pickup descent keeps the store's horizontal position",
		_test_pickup_landing_reads_the_store.bind(flyer, store))
	_run("a pickup with no landing point given lands on the store's position",
		_test_begin_pickup_reads_the_store.bind(flyer, store))
	_run("the post-pickup climb resumes from the store's position and altitude",
		_test_complete_pickup_reads_the_store.bind(flyer, store))
	_run("the landing approach is measured from the store's position",
		_test_landing_approach_reads_the_store.bind(flyer, store))
	_run("cruise altitude probes the terrain under the store's position",
		_test_cruise_altitude_reads_the_store.bind(flyer, store))
	_run("configure() takes its first cruise altitude from the store",
		_test_configure_reads_the_store.bind(flyer, store))
	_run("Circles steering aims from the store's position",
		_test_circles_desired_velocity_reads_the_store.bind(circles_flyer, store))
	_run("the Circles integrator steps off the store's position",
		_test_circles_integrator_reads_the_store.bind(circles_flyer, store))
	_run("a Circles order completes on the store's position",
		_test_circles_arrival_reads_the_store.bind(circles_flyer, store))
	_run("the close-target departure leg is planned from the store's position",
		_test_circles_departure_reads_the_store.bind(circles_flyer, store))

	fixture.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	if _failures > 0:
		printerr(
			"Flight store-read tests: %d failures after %d assertions"
				% [_failures, _assertions]
		)
		quit(1)
		return
	print("Flight store-read tests: %d assertions passed" % _assertions)
	quit(0)


## Adds a real flying unit under the running Match and waits for it to become a
## simulated entity: an id from Unit._register_entity_id(), and a store position
## it earned by being ticked (the GROUNDED branch of UnitFlightController.advance()
## snaps to terrain through set_simulation_position()). Both are asserted rather
## than assumed -- a unit with no store entry would make simulation_position()
## fall back to the node and every case below would pass while proving nothing.
func _add_flyer(fixture: Node, scene: PackedScene, home: Vector3, store) -> Unit:
	var flyer: Unit = scene.instantiate()
	flyer.position = home
	fixture.get_node("Units").add_child(flyer)
	for _settle in 30:
		await process_frame
		if flyer.entity_id != 0 and store.has_position(flyer.entity_id):
			break
	_expect(flyer.entity_id != 0, "%s must be registered as an entity by the match" % flyer.name)
	_expect(
		flyer.entity_id != 0 and store.has_position(flyer.entity_id),
		"%s must have earned a store position from the tick before any case pokes it" % flyer.name
	)
	_expect(
		flyer._flight_controller != null,
		"%s must own a UnitFlightController, or there is nothing here to bind" % flyer.name
	)
	if flyer.entity_id == 0 or not store.has_position(flyer.entity_id) \
	or flyer._flight_controller == null:
		return null
	return flyer


func _run(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	test.call()
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


## Returns the controller to a known cruising state and the unit to a known
## place, store and node agreeing, so a case starts from the same tree the
## previous one did. Cases run back to back against one fixture (see the class
## comment), and a leftover landing target or pickup phase would otherwise leak
## across them.
func _reset(unit: Unit, home: Vector3):
	var controller = unit._flight_controller
	controller.phase = UnitFlightControllerScript.Phase.CRUISING
	controller._phase_elapsed = 0.0
	controller._landing_target = Vector3.INF
	controller._landing_allowed_cells.clear()
	controller._post_takeoff_move_target = Vector3.INF
	controller._post_takeoff_exit_point = Vector3.INF
	controller._transition_active = false
	controller._transition_clip = &""
	controller._vertical_avoidance_offset = 0.0
	controller._vertical_avoidance_target = 0.0
	controller._pickup_transition_finished = false
	controller._pickup_landing_target = Vector3.INF
	controller.clear_circles_order()
	controller._circles_order_completed = false
	unit.set_simulation_position(home)
	return controller


## The split every case is built on: write SimEntityState directly and leave the
## node where it stands. This is the identical bypass
## tests/match/entity_state_run.gd's poke cases perform -- there, to prove the
## store does not follow the node; here, to make the two answer differently
## while a real flight step reads one of them.
func _split(unit: Unit, store, store_position: Vector3) -> void:
	store.set_position(unit.entity_id, store_position)
	_expect(
		not unit.global_position.is_equal_approx(store_position),
		"the node must keep its own position, or this case is not a real disagreement"
	)
	_expect(
		unit.simulation_position().is_equal_approx(store_position),
		"simulation_position() must answer the poked store value"
	)


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## advance()'s CRUISING branch reads the unit's position and writes it straight
## back out on the next line with a new altitude. Reading the node there would
## copy the mirror into the store once per tick, which is the store's own value
## laundered through the view.
func _test_cruise_advance_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(30.0, 0.0, -20.0)
	_split(unit, store, store_position)
	controller.cruise_altitude = store_position.y

	controller.advance(MatchClockScript.SECONDS_PER_TICK)

	var landed: Vector3 = store.position(unit.entity_id)
	_expect(
		_horizontal_distance(landed, store_position) < 0.001,
		"cruise must keep the store's horizontal position, not the node's (landed at %s)" % landed
	)
	_expect(
		_horizontal_distance(landed, node_position) > 1.0,
		"the node and the store were far enough apart for this to mean something"
	)


## _advance_hangar_exit() reads the position twice: once to measure the offset
## to the exit point, once as the base of the step it writes. The second read is
## the argument of set_simulation_position() and is not the same call -- it
## moved to the store like every other read in the file.
func _test_hangar_exit_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(-40.0, 0.0, 25.0)
	var exit_point := store_position + Vector3(60.0, 0.0, 0.0)
	_split(unit, store, store_position)
	controller.phase = UnitFlightControllerScript.Phase.HANGAR_EXIT
	controller._post_takeoff_exit_point = exit_point

	var delta := MatchClockScript.SECONDS_PER_TICK
	var step: float = maxf(unit.navigation_move_speed(), 0.0) * delta
	controller.advance(delta)

	var landed: Vector3 = store.position(unit.entity_id)
	_expect(
		step > 0.0,
		"the fixture aircraft must have a nonzero move speed, or this case cannot see a step"
	)
	_expect(
		absf(_horizontal_distance(landed, store_position) - step) < 0.01,
		"the walk-out must step exactly one tick's travel from the store's position (moved %.3f, expected %.3f)"
			% [_horizontal_distance(landed, store_position), step]
	)
	_expect(
		_horizontal_distance(landed, node_position) > 1.0,
		"integrating from the node would have left the unit somewhere else entirely"
	)


## begin_hangar_takeoff() compares the exit point against the unit's position to
## decide whether there is a walk-out at all. Both halves are asserted: an exit
## point on top of the store's position must skip HANGAR_EXIT, and one on top of
## the node's must not.
func _test_hangar_takeoff_decision_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(0.0, 0.0, 45.0)
	_split(unit, store, store_position)

	controller.begin_hangar_takeoff(store_position, store_position + Vector3(0.01, 0.0, 0.0))
	_expect(
		controller.phase == UnitFlightControllerScript.Phase.TAKING_OFF,
		"an exit point the store is already standing on must climb straight away, not walk out"
	)

	controller = _reset(unit, FLYER_HOME)
	node_position = unit.global_position
	store_position = node_position + Vector3(0.0, 0.0, 45.0)
	_split(unit, store, store_position)
	controller.begin_hangar_takeoff(store_position, node_position + Vector3(0.01, 0.0, 0.0))
	_expect(
		controller.phase == UnitFlightControllerScript.Phase.HANGAR_EXIT,
		"an exit point on the node rather than the store is still a walk-out for the simulation"
	)


## _start_takeoff() samples the terrain under the unit for the lower endpoint of
## the climb. The sample's *input* is only observable where the two positions
## get different answers, so the store is put off the map, where
## Unit._terrain_hit_at() finds nothing and _sample_ground_altitude() falls back
## to the position it was handed.
func _test_takeoff_ground_sample_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	_split(unit, store, OFF_MAP)

	controller.begin_takeoff_toward(OFF_MAP, Vector3.INF)

	_expect(
		absf(controller.ground_altitude - OFF_MAP.y) < 0.001,
		"the ground sample must be taken at the store's position (got %.3f, expected %.3f)"
			% [controller.ground_altitude, OFF_MAP.y]
	)
	_expect(
		absf(node_position.y - OFF_MAP.y) > 1.0,
		"the node's own altitude must differ, or this case cannot tell the two samples apart"
	)


## _advance_vertical_transition() replaces only the altitude; the horizontal
## half of the position it writes is the one it just read. The motion target is
## left INF so flight_advance_transition_motion() -- which would move the unit
## before the read -- is skipped, isolating the read itself.
func _test_vertical_transition_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(22.0, 0.0, 18.0)
	_split(unit, store, store_position)
	controller.phase = UnitFlightControllerScript.Phase.TAKING_OFF
	controller.ground_altitude = store_position.y
	controller.cruise_altitude = store_position.y + 24.0

	controller.advance(MatchClockScript.SECONDS_PER_TICK)

	var landed: Vector3 = store.position(unit.entity_id)
	_expect(
		_horizontal_distance(landed, store_position) < 0.001,
		"the climb must keep the store's horizontal position (landed at %s)" % landed
	)
	_expect(
		_horizontal_distance(landed, node_position) > 1.0,
		"the node and the store were far enough apart for this to mean something"
	)
	_expect(
		landed.y > store_position.y,
		"the climb must actually have lifted the aircraft, or the phase never advanced"
	)


## _advance_pickup_landing() has the same shape as the climb above: the altitude
## is lerped, the horizontal half comes from the read. The landing target is
## left INF for the same reason -- to skip the motion call that would otherwise
## move the unit first.
func _test_pickup_landing_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(-18.0, 0.0, -26.0)
	_split(unit, store, store_position)
	controller.phase = UnitFlightControllerScript.Phase.PICKUP_LAND
	controller._pickup_landing_target = Vector3.INF
	controller._pickup_landing_start_altitude = store_position.y
	controller._pickup_landing_altitude = store_position.y - 10.0

	controller.advance(MatchClockScript.SECONDS_PER_TICK)

	var landed: Vector3 = store.position(unit.entity_id)
	_expect(
		_horizontal_distance(landed, store_position) < 0.001,
		"the pickup descent must keep the store's horizontal position (landed at %s)" % landed
	)
	_expect(
		_horizontal_distance(landed, node_position) > 1.0,
		"the node and the store were far enough apart for this to mean something"
	)


## flight_begin_pickup_sequence() reads the position twice when it is given no
## landing point: once as the landing point itself, once (`.y` only) as the
## altitude the descent starts from. The `.y` half is a position read like any
## other -- the node's y is a mirror of the same store value, since B4's
## interpolation offsets `visual_root` and never the body.
func _test_begin_pickup_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(12.0, 9.0, -33.0)
	_split(unit, store, store_position)

	controller.flight_begin_pickup_sequence(Vector3.INF, 0.0)

	_expect(
		controller._pickup_landing_target.is_equal_approx(store_position),
		"the landing point must be the store's position (got %s)" % controller._pickup_landing_target
	)
	_expect(
		absf(controller._pickup_landing_start_altitude - store_position.y) < 0.001,
		"the descent must start from the store's altitude (got %.3f, expected %.3f)"
			% [controller._pickup_landing_start_altitude, store_position.y]
	)
	_expect(
		absf(node_position.y - store_position.y) > 1.0,
		"the node's own altitude must differ, or the `.y` half of this case proves nothing"
	)


## flight_complete_pickup_sequence() reads the position twice as well: the move
## target the aircraft resumes at the top of the climb, and (`.y` only) the
## altitude the climb starts from.
func _test_complete_pickup_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(-27.0, 11.0, 14.0)
	_split(unit, store, store_position)

	controller.flight_complete_pickup_sequence()

	_expect(
		controller._post_takeoff_move_target.is_equal_approx(store_position),
		"the resumed move target must be the store's position (got %s)"
			% controller._post_takeoff_move_target
	)
	_expect(
		absf(controller.ground_altitude - store_position.y) < 0.001,
		"the climb must start from the store's altitude (got %.3f, expected %.3f)"
			% [controller.ground_altitude, store_position.y]
	)
	_expect(
		absf(node_position.y - store_position.y) > 1.0,
		"the node's own altitude must differ, or the `.y` half of this case proves nothing"
	)


## _landing_approach_reached() decides when the Land clip takes ownership of
## horizontal motion. A target inside the approach radius of the store but far
## outside it from the node must start the descent.
func _test_landing_approach_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(0.0, 0.0, 300.0)
	_split(unit, store, store_position)
	var radius: float = controller.flight_landing_approach_radius()
	var target := store_position + Vector3(0.05, 0.0, 0.0)

	_expect(
		_horizontal_distance(target, node_position) > radius,
		"the landing target must be out of approach range of the node (%.2f away, radius %.2f)"
			% [_horizontal_distance(target, node_position), radius]
	)
	_expect(
		controller.flight_request_land(target, {}),
		"an advanced carryall must accept a land request while cruising"
	)
	_expect(
		controller.phase == UnitFlightControllerScript.Phase.LANDING,
		"the descent must start, because the store -- not the node -- is already at the target"
	)


## _advance_cruise_altitude() probes the terrain under the aircraft to decide
## what altitude to settle toward. Same trick as the takeoff sample: off the map
## the probe finds nothing and _sample_flight_altitude() falls back to the
## position it was handed, which makes the probe's input observable.
func _test_cruise_altitude_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	_split(unit, store, OFF_MAP)
	controller.cruise_altitude = OFF_MAP.y

	controller._advance_cruise_altitude(MatchClockScript.SECONDS_PER_TICK)

	_expect(
		absf(controller.cruise_altitude - OFF_MAP.y) < 0.01,
		"a probe taken at the store's position finds no terrain and holds the altitude (got %.3f)"
			% controller.cruise_altitude
	)
	var node_hit: Dictionary = unit.flight_terrain_hit_at(node_position)
	_expect(
		not node_hit.is_empty(),
		"the node must be standing over real terrain, or the two probes cannot differ"
	)
	if not node_hit.is_empty():
		var node_target: float = (node_hit["position"] as Vector3).y \
			+ UnitFlightControllerScript.BASE_FLIGHT_ALTITUDE + controller.height_offset
		_expect(
			absf(node_target - OFF_MAP.y) > 1.0,
			"a probe under the node would have pulled toward a different altitude entirely"
		)


## configure() takes the aircraft's first cruise altitude from where it is
## standing. This is the one site in the file where the accessor's fallback is
## load-bearing in production -- configure() normally runs inside _ready(),
## before the unit's first set_simulation_position() -- but by the time this
## case calls it again the store has an entry, so the store is what answers.
func _test_configure_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, FLYER_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(0.0, 37.0, 0.0)
	_split(unit, store, store_position)

	controller.configure(unit, unit.unit_definition)

	var expected: float = store_position.y \
		+ UnitFlightControllerScript.BASE_FLIGHT_ALTITUDE + controller.height_offset
	_expect(
		absf(controller.cruise_altitude - expected) < 0.001,
		"the first cruise altitude must be measured from the store (got %.3f, expected %.3f)"
			% [controller.cruise_altitude, expected]
	)
	_expect(
		absf(node_position.y - store_position.y) > 1.0,
		"the node's own altitude must differ, or this case proves nothing"
	)


## circles_desired_velocity() is the nominal velocity AirNavigation steers a
## fixed-wing aircraft with for the whole tick. Its direction is the bearing
## from the aircraft to its steering target.
func _test_circles_desired_velocity_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, CIRCLES_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(0.0, 0.0, 80.0)
	var destination := node_position + Vector3(80.0, 0.0, 0.0)
	controller.set_circles_order(destination)
	_split(unit, store, store_position)

	var velocity: Vector3 = controller.circles_desired_velocity()
	var from_store := destination - store_position
	from_store.y = 0.0
	var from_node := destination - node_position
	from_node.y = 0.0

	_expect(
		not velocity.is_zero_approx(),
		"a Circles aircraft under order must produce a steering velocity"
	)
	_expect(
		velocity.normalized().is_equal_approx(from_store.normalized()),
		"the bearing must be taken from the store's position (got %s, expected %s)"
			% [velocity.normalized(), from_store.normalized()]
	)
	_expect(
		not from_node.normalized().is_equal_approx(from_store.normalized()),
		"the two bearings must genuinely differ, or this case passes either way"
	)


## advance_circles_flight() integrates the aircraft forward one tick from where
## it is. `steering_velocity` is passed as zero so the function also takes its
## own steering target from the position, exercising both reads.
func _test_circles_integrator_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, CIRCLES_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(-70.0, 0.0, 40.0)
	controller.set_circles_order(store_position + Vector3(90.0, 0.0, 0.0))
	_split(unit, store, store_position)

	var delta := MatchClockScript.SECONDS_PER_TICK
	controller.advance_circles_flight(Vector3.ZERO, delta)

	var landed: Vector3 = store.position(unit.entity_id)
	var travelled := _horizontal_distance(landed, store_position)
	var step := maxf(unit.navigation_move_speed(), 0.0) * delta
	_expect(step > 0.0, "the fixture aircraft must have a nonzero move speed")
	_expect(
		absf(travelled - step) < 0.01,
		"one tick of fixed-wing flight must step exactly one tick's travel off the store's "
			+ "position (moved %.3f, expected %.3f)" % [travelled, step]
	)
	_expect(
		_horizontal_distance(landed, node_position) > 1.0,
		"integrating from the node would have left the aircraft somewhere else entirely"
	)


## _reached() is the arrival verdict that completes a Circles order, and it is a
## simulation decision rather than a display one: a destination the store is
## already sitting on must finish the order even though the node is 80 units
## away from it.
func _test_circles_arrival_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, CIRCLES_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(0.0, 0.0, 80.0)
	controller.set_circles_order(store_position)
	_split(unit, store, store_position)

	controller.advance_circles_flight(Vector3.ZERO, MatchClockScript.SECONDS_PER_TICK)

	_expect(
		controller.consume_circles_order_completed(),
		"an order the store has already arrived at must complete"
	)
	_expect(
		_horizontal_distance(store_position, node_position) > float(unit.arrival_radius),
		"the node must be nowhere near the destination, or arrival was never in question"
	)


## _plan_close_target_departure() reads the position twice: once to test whether
## the destination is inside two turn radii, once as the base of the departure
## waypoint it plans. Both must come from the store, or a close order would be
## judged against one point and planned from another.
func _test_circles_departure_reads_the_store(unit: Unit, store) -> void:
	var controller = _reset(unit, CIRCLES_HOME)
	var node_position := unit.global_position
	var store_position := node_position + Vector3(0.0, 0.0, 90.0)
	_split(unit, store, store_position)

	controller.set_circles_order(store_position + Vector3(0.5, 0.0, 0.0))

	_expect(
		controller._circles_departure.is_finite(),
		"a destination inside two turn radii of the store must get a departure leg"
	)
	if controller._circles_departure.is_finite():
		_expect(
			_horizontal_distance(controller._circles_departure, store_position)
				< _horizontal_distance(controller._circles_departure, node_position),
			"the departure waypoint must be planned from the store's position, not the node's"
		)
