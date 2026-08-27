extends SceneTree

## Slice R4's binding for the navigation system-and-shared migration.
##
## No integration suite can catch a mistake in this migration, and that is
## structural rather than an oversight. Inside a match SimEntityState and the
## node hold the same number, so `unit.global_position` and
## `unit.simulation_position()` return the same value and every assertion in
## tests/navigation/run.gd, demo_boot_run.gd or harvester_run.gd passes with
## either read -- slice R2 measured exactly that on the harvester (103
## assertions before, 103 after) and slice R3 measured it again from the other
## side (making the real Unit.simulation_position() answer from the node breaks
## two assertions in the whole repository, neither of them on a navigation
## path). The migration is therefore held by exactly two things: the
## `global-position-read-bypasses-store` rule in tools/architecture_rules.toml,
## and a manufactured disagreement at the test double. This file is the second
## one for R4.
##
## It deliberately reuses tests/navigation/run.gd's own FakeUnit rather than
## defining its own, and that is the whole reason this suite can be trusted.
## The disagreement mechanism is FakeUnit._simulation_position (slice R3): a
## store-side position that simulation_position() returns, defaulting to
## Vector3.INF meaning "no separate store value, answer from the node". A
## second copy of that double here would mean mutating one copy left the other
## answering correctly, so the mutation "make FakeUnit.simulation_position()
## ignore the override" -- the check that tells a real binding case apart from
## one that merely asserts the two agree -- would stop proving anything about
## half the cases. One definition, one mutation, every case fails.
##
## Why this is a separate file rather than more cases in
## tests/navigation/run.gd: that file is 3028 lines and already one of the two
## pre-existing max-file-lines offenders (limit 2600). R3 added 173 lines to it
## and argued a separate suite would duplicate ~60 lines of scaffolding for no
## net reduction; at R4's volume that argument inverts, and the duplicated
## scaffolding here is _make_grid() and _expect() and nothing else, because the
## double itself is shared instead of copied.
##
## Every case follows the same three-step shape, and the middle step is the one
## that matters: build the situation, split the node and the store apart, then
## assert the module followed the store. Most cases also assert the split is
## real -- that a node-side read would genuinely have answered differently --
## because a case where the two agree passes either way and proves nothing.

const NavigationSuiteScript := preload("res://tests/navigation/run.gd")
const NavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	var grid := _make_grid()
	await _run(_test_agent_seeds_read_the_store_position.bind(grid))
	await _run(_test_spatial_hash_buckets_read_the_store_position.bind(grid))
	await _run(_test_orca_neighbours_read_the_store_position.bind(grid))
	await _run(_test_departure_access_reads_the_store_position.bind(grid))
	await _run(_test_attack_arcs_read_the_store_position.bind(grid))
	await _run(_test_direct_line_recheck_reads_the_store_position.bind(grid))
	await _run(_test_reroute_queue_routes_from_the_store_position.bind(grid))
	await _run(_test_destination_reached_reads_the_store_position.bind(grid))
	await _run(_test_stop_and_hold_seed_the_store_position.bind(grid))
	await _run(_test_command_move_routes_from_the_store_position.bind(grid))
	await _run(_test_firing_anchor_blockers_read_the_store_position.bind(grid))
	await _run(_test_transport_cargo_probe_reads_the_store_position.bind(grid))
	await _run(_test_reachability_reads_the_store_position.bind(grid))

	if _failures > 0:
		printerr(
			"Navigation store-read tests: %d failures after %d assertions"
				% [_failures, _assertions]
		)
		quit(1)
		return
	print("Navigation store-read tests: %d assertions passed" % _assertions)
	quit(0)


## Runs one case and then lets the frame end, which is what actually frees the
## nodes the case queue_free()d. tests/navigation/run.gd does not need this --
## it never looks at a scene-tree group -- but
## _test_transport_cargo_probe_reads_the_store_position does: the probe it
## exercises walks the whole "sim_units" group, which FakeUnit joins in its own
## _init(), so a previous case's leftovers would still be standing in it.
func _run(test: Callable) -> void:
	var assertions_before := _assertions
	test.call()
	if _assertions == assertions_before:
		_failures += 1
		printerr("FAIL: a case ended before asserting anything")
	await process_frame


## The store-side position a case wants a unit to report, set before the node is
## moved somewhere else. Returns the unit so a case reads as one statement.
func _make_unit(navigation, node_position: Vector3, store_position: Vector3) -> Node3D:
	var unit: Node3D = NavigationSuiteScript.FakeUnit.new()
	root.add_child(unit)
	unit.global_position = node_position
	unit.call("set_simulation_position_override", store_position)
	navigation.register_unit(unit)
	return unit


func _make_navigation(grid: MapNavigationGrid, purpose: String):
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for %s" % purpose)
	return navigation


## NavAgentRegistry.register_unit(). `destination`, `steering_target` and
## `claim_center` are all seeded from the unit's position at registration, and
## all three are simulation state the tick reads back afterwards -- arrival is
## measured against `destination` every tick, and the parking claim search
## centres on `claim_center`. Seeding them from the node would let a mirror
## value in through the one door every later store read then inherits it from.
func _test_agent_seeds_read_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "agent seeds")
	var node_position := Vector3(20.5, 0.0, 20.5)
	var store_position := Vector3(28.5, 0.0, 24.5)
	var unit := _make_unit(navigation, node_position, store_position)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]

	_expect(
		unit.global_position.distance_to(node_position) < 0.001
			and unit.call("simulation_position").distance_to(store_position) < 0.001,
		"the node and the store must genuinely disagree here -- otherwise this case tests nothing"
	)
	for field in ["destination", "steering_target", "claim_center"]:
		_expect(
			(agent[field] as Vector3).distance_to(store_position) < 0.001,
			("register_unit() must seed `%s` from the stored position, not the node "
				+ "(got %s, wanted %s)") % [field, agent[field], store_position]
		)

	navigation.queue_free()
	unit.queue_free()


## NavSpatialHash.build(). This read had to travel with the ground-navigation
## group rather than after it: GroundNavigation.tick() has queried these buckets
## with a store position since slice R3, so keying them off the node would file
## an agent in one bucket and look for it in another. The observable is direct
## -- which bucket the agent lands in -- and the two readings are placed more
## than one CELL_BUCKET_SIZE apart so they cannot land in the same one.
func _test_spatial_hash_buckets_read_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "spatial hash buckets")
	var node_position := Vector3(40.5, 0.0, 40.5)
	var store_position := Vector3(60.5, 0.0, 60.5)
	var unit := _make_unit(navigation, node_position, store_position)
	var agents: Array[Dictionary] = [navigation._agents[unit.get_instance_id()]]

	var store_key: Vector2i = navigation.spatial_hash.bucket_key(store_position)
	var node_key: Vector2i = navigation.spatial_hash.bucket_key(node_position)
	_expect(store_key != node_key,
		"the two readings must fall in different buckets -- otherwise this case tests nothing")
	var buckets: Dictionary = navigation.spatial_hash.build(agents)
	_expect(buckets.has(store_key),
		"the agent must be filed in the bucket its stored position belongs to (%s)" % store_key)
	_expect(not buckets.has(node_key),
		"the agent must not be filed in the bucket its node happens to stand in (%s)" % node_key)

	navigation.queue_free()
	unit.queue_free()


## OrcaAvoidance.resolve_velocity(), both of its reads at once. Whether a
## neighbour is inside `reach` at all is decided by `other_pos - own_pos`, so
## moving only one of the two nodes would leave the other read untested: here
## the moving unit's node is thrown 100 m along +X and the neighbour's 100 m
## along +Z, which makes the node-side separation ~141 m -- far outside reach --
## while the stored separation is 2 m, head-on into the preferred velocity.
func _test_orca_neighbours_read_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "ORCA neighbours")
	var base := Vector3(70.5, 0.0, 70.5)
	var unit := _make_unit(navigation, base + Vector3.RIGHT * 100.0, base)
	var other := _make_unit(navigation, base + Vector3.BACK * 100.0, base + Vector3.RIGHT * 2.0)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var other_agent: Dictionary = navigation._agents[other.get_instance_id()]

	var node_separation := unit.global_position.distance_to(other.global_position)
	var store_separation: float = unit.call("simulation_position").distance_to(
		other.call("simulation_position")
	)
	_expect(node_separation > 100.0 and store_separation < 3.0,
		("the two readings must disagree about whether these units are neighbours at all "
			+ "(node %.1f m apart, store %.1f m)") % [node_separation, store_separation])

	var nearby: Array = [agent, other_agent]
	var result: Dictionary = navigation.avoidance.resolve_velocity(
		agent, Vector3.RIGHT * float(unit.get("move_speed")), 0.05, nearby, {}
	)
	_expect((result["friends"] as Array).has(other),
		("ORCA must treat a friendly two metres ahead of the stored position as a constraining "
			+ "neighbour, however far away its node has been moved"))
	var velocity: Vector3 = result["velocity"]
	_expect(velocity.length() < float(unit.get("move_speed")) - 0.01,
		("the neighbour's half-plane must actually bite: the resolved speed (%.2f) has to fall "
			+ "below the requested one (%.2f)") % [velocity.length(), float(unit.get("move_speed"))])

	navigation.queue_free()
	unit.queue_free()
	other.queue_free()


## GroundPathFollower.release_departure_access_if_clear(), both of its reads.
## The first decides whether the body has cleared the refinery apron -- the node
## is parked on a no-stop cell, where a node-side read would keep the departure
## exception open forever, while the store stands on ordinary ground. The second
## is the route planned on clearing it: a wall between the stored position and
## the destination means a store-side route cannot be a straight line, while the
## node (already past the wall) has a clear one.
func _test_departure_access_reads_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "departure access")
	var wall := {}
	for z in range(90, 111):
		wall[Vector2i(100, z)] = true
	var apron := {Vector2i(105, 100): true}
	navigation.runtime_map.replace_blocked_cells(wall, apron)

	var store_position := Vector3(90.5, 0.0, 100.5)
	var node_position := Vector3(105.5, 0.0, 100.5)
	var destination := Vector3(110.5, 0.0, 100.5)
	var unit := _make_unit(navigation, node_position, store_position)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	agent["destination"] = destination
	agent["departure_access"] = true
	agent["allowed_cells"] = {Vector2i(105, 100): true}

	_expect(
		navigation.path_follower.has_clear_line(node_position, destination, agent)
			and not navigation.path_follower.has_clear_line(store_position, destination, agent),
		"the wall must separate the two readings -- otherwise this case tests nothing"
	)
	navigation.path_follower.release_departure_access_if_clear(agent)
	_expect(not bool(agent["departure_access"]),
		("the departure exception must be released from the stored position, which stands on "
			+ "ordinary ground -- the node is parked on a no-stop apron cell"))
	_expect(not bool(agent["direct_path"]),
		("the route planned on release must start at the stored position, which has a wall "
			+ "between it and the destination -- a node-side start has a clear line"))
	_expect(not (agent["path"] as Array).is_empty(),
		"that route must be a real planned path around the wall, not an empty one")

	navigation.queue_free()
	unit.queue_free()


## AttackArcAllocator.assign_arcs(), both reads. Each shooter's bearing is its
## own side of the group's approach vector, so freezing two stored positions on
## opposite sides of the target and then swapping the nodes across that axis
## makes the two readings hand out opposite slots.
func _test_attack_arcs_read_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "attack arcs")
	var target := Vector3(140.5, 0.0, 140.5)
	var low_store := Vector3(130.5, 0.0, 137.5)
	var high_store := Vector3(130.5, 0.0, 143.5)
	var low := _make_unit(navigation, low_store, low_store)
	var high := _make_unit(navigation, high_store, high_store)
	# The nodes swap sides; the stored positions do not.
	low.global_position = high_store
	high.global_position = low_store

	var squad: Array[Node3D] = [low, high]
	var assigned: Array[Node3D] = navigation.assign_attack_arcs(squad, target, 12.0)
	_expect(assigned.size() == 2, "both shooters must receive an arc slot")
	var low_direction: Vector3 = low.get("attack_arc_direction")
	var high_direction: Vector3 = high.get("attack_arc_direction")
	_expect(low_direction.z < 0.0,
		("the shooter stored on the -Z flank must be sent to the -Z side of the arc, not the "
			+ "side its swapped node stands on (got %s)") % low_direction)
	_expect(high_direction.z > 0.0,
		("the shooter stored on the +Z flank must be sent to the +Z side of the arc (got %s)")
			% high_direction)

	navigation.queue_free()
	low.queue_free()
	high.queue_free()


## NavBlockerTracker.agent_route_intersects(). A direct-path agent keeps no
## corridor to diff a blocker change against, so the tracker re-runs the exact
## predicate that approved the straight line -- and route_agent() has approved
## it from a store position since slice R3. An empty `changed_lookup` is passed
## on purpose: it makes the destination-block loop above the read a no-op, so
## the answer is the line check and nothing else.
func _test_direct_line_recheck_reads_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "direct-line recheck")
	var wall := {}
	for z in range(150, 171):
		wall[Vector2i(160, z)] = true
	navigation.runtime_map.replace_blocked_cells(wall)

	var store_position := Vector3(150.5, 0.0, 160.5)
	var node_position := Vector3(165.5, 0.0, 160.5)
	var destination := Vector3(170.5, 0.0, 160.5)
	var unit := _make_unit(navigation, node_position, store_position)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	agent["destination"] = destination
	agent["direct_path"] = true

	_expect(
		navigation.path_follower.has_clear_line(node_position, destination, agent)
			and not navigation.path_follower.has_clear_line(store_position, destination, agent),
		"the wall must separate the two readings -- otherwise this case tests nothing"
	)
	_expect(navigation.blocker_tracker.agent_route_intersects(agent, {}),
		("a direct line drawn from the stored position no longer clears the wall, so the route "
			+ "must be reported as invalidated -- the node's own line still clears it"))

	navigation.queue_free()
	unit.queue_free()


## NavBlockerTracker.process_reroute_queue(). The reroute plans the agent's
## replacement route from where the simulation says it stands, exactly as
## command_move() and command_dock() now do. Same wall geometry as the case
## above, so a store-side start cannot produce a straight line and a node-side
## start cannot produce anything else.
func _test_reroute_queue_routes_from_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "reroute queue")
	var wall := {}
	for z in range(150, 171):
		wall[Vector2i(160, z)] = true
	navigation.runtime_map.replace_blocked_cells(wall)

	var store_position := Vector3(150.5, 0.0, 160.5)
	var node_position := Vector3(165.5, 0.0, 160.5)
	var destination := Vector3(170.5, 0.0, 160.5)
	var unit := _make_unit(navigation, node_position, store_position)
	var key := unit.get_instance_id()
	var agent: Dictionary = navigation._agents[key]
	agent["destination"] = destination
	agent["command_id"] = 1
	agent["direct_path"] = true

	_expect(
		navigation.path_follower.has_clear_line(node_position, destination, agent)
			and not navigation.path_follower.has_clear_line(store_position, destination, agent),
		"the wall must separate the two readings -- otherwise this case tests nothing"
	)
	navigation.blocker_tracker._reroute_queue.append(key)
	navigation.blocker_tracker.process_reroute_queue()
	var rerouted: Dictionary = navigation._agents[key]
	_expect(not bool(rerouted["direct_path"]),
		("the reroute must plan from the stored position, which has a wall between it and the "
			+ "destination -- planning from the node would approve a straight line"))
	_expect(not (rerouted["path"] as Array).is_empty(),
		"the reroute must produce a real planned path around the wall")

	navigation.queue_free()
	unit.queue_free()


## UnitNavigationSystem.destination_reached(). Arrival is a simulation answer --
## Unit's own transitions and both transports gate on it -- and since slice B4
## the view moves between ticks, so the node is exactly the wrong thing to
## measure it against. The node is parked on the destination while the store
## keeps the unit six metres short of it.
func _test_destination_reached_reads_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "destination arrival")
	var store_position := Vector3(60.5, 0.0, 60.5)
	var destination := store_position + Vector3.RIGHT * 6.0
	var unit := _make_unit(navigation, destination, store_position)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	agent["destination"] = destination

	_expect(
		unit.global_position.distance_to(destination) < 0.001
			and unit.call("simulation_position").distance_to(store_position) < 0.001,
		"the node and the store must genuinely disagree here -- otherwise this case tests nothing"
	)
	_expect(not navigation.destination_reached(unit, destination),
		("the store still has this unit six metres short of its destination, so navigation must "
			+ "not report arrival however close the node's mirror has been moved"))

	navigation.queue_free()
	unit.queue_free()


## UnitNavigationSystem.stop() and set_hold_position(), which both pin the
## agent's destination to wherever the unit now stands. That destination is
## simulation state the tick measures arrival against every tick afterwards, not
## a note about where the node happens to be drawn.
func _test_stop_and_hold_seed_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "stop and hold")
	var store_position := Vector3(80.5, 0.0, 80.5)
	var node_position := Vector3(88.5, 0.0, 84.5)
	var unit := _make_unit(navigation, node_position, store_position)
	var key := unit.get_instance_id()
	# register_unit() seeds `destination` from the same reading, so move it
	# somewhere neither answer would produce before asking stop() to reset it.
	navigation._agents[key]["destination"] = Vector3(200.5, 0.0, 200.5)

	navigation.stop(unit)
	_expect(
		(navigation._agents[key]["destination"] as Vector3).distance_to(store_position) < 0.001,
		"stop() must pin the destination to the stored position, not the node (got %s)"
			% navigation._agents[key]["destination"]
	)
	navigation._agents[key]["destination"] = Vector3(200.5, 0.0, 200.5)
	navigation.set_hold_position(unit, true)
	_expect(
		(navigation._agents[key]["destination"] as Vector3).distance_to(store_position) < 0.001,
		"set_hold_position() must pin the destination to the stored position, not the node (got %s)"
			% navigation._agents[key]["destination"]
	)

	navigation.queue_free()
	unit.queue_free()


## UnitNavigationSystem.command_move()'s _route_agent() call. command_depart()
## and command_dock() make the identical call with the identical argument one
## screen below it, so this case binds the shape all three share. Same wall
## geometry as the reroute case: a route planned from the stored position cannot
## be a straight line, one planned from the node cannot be anything else.
func _test_command_move_routes_from_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "command routing")
	var wall := {}
	for z in range(90, 111):
		wall[Vector2i(100, z)] = true
	navigation.runtime_map.replace_blocked_cells(wall)

	var store_position := Vector3(90.5, 0.0, 100.5)
	var node_position := Vector3(105.5, 0.0, 100.5)
	var destination := Vector3(110.5, 0.0, 100.5)
	var unit := _make_unit(navigation, node_position, store_position)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]

	_expect(
		navigation.path_follower.has_clear_line(node_position, destination, agent)
			and not navigation.path_follower.has_clear_line(store_position, destination, agent),
		"the wall must separate the two readings -- otherwise this case tests nothing"
	)
	var assignments: Array[Dictionary] = navigation.command_move([unit], destination)
	_expect(not assignments.is_empty(), "the move order must be accepted")
	var routed: Dictionary = navigation._agents[unit.get_instance_id()]
	_expect(not bool(routed["direct_path"]),
		("command_move() must route from the stored position, which has a wall between it and "
			+ "the target -- routing from the node would approve a straight line"))
	_expect(not (routed["path"] as Array).is_empty(),
		"the accepted order must produce a real planned path around the wall")

	navigation.queue_free()
	unit.queue_free()


## UnitNavigationSystem._firing_anchor_blockers(), both of its reads: the range
## filter that decides whether an anchored friendly is close enough to matter,
## and the position recorded for the perch it occupies. Which perches a firing
## line already holds decides where an arriving shooter is sent, so both are
## tick decisions.
func _test_firing_anchor_blockers_read_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "firing-anchor blockers")
	var target := Vector3(180.5, 0.0, 180.5)
	var anchor_store := target + Vector3.RIGHT * 2.0
	var anchor_node := target + Vector3.RIGHT * 100.0
	var shooter := _make_unit(navigation, target + Vector3.BACK * 8.0, target + Vector3.BACK * 8.0)
	var anchored := _make_unit(navigation, anchor_node, anchor_store)
	navigation._agents[anchored.get_instance_id()]["firing_anchor"] = true

	var blockers: Array[Dictionary] = navigation._firing_anchor_blockers(shooter, target, 10.0)
	_expect(blockers.size() == 1,
		("the anchored friendly is two metres from the target by the store and a hundred by its "
			+ "node, so only a store-side range filter keeps it (got %d blockers)")
			% blockers.size())
	if blockers.size() == 1:
		_expect((blockers[0]["position"] as Vector3).distance_to(anchor_store) < 0.001,
			("the recorded blocker perch must be the stored position, not the node's (got %s)")
				% blockers[0]["position"])

	navigation.queue_free()
	shooter.queue_free()
	anchored.queue_free()


## UnitNavigationSystem.can_place_transport_cargo(). The probe runs from
## AdvancedCarryallTransport.advance() on the simulation tick and has to agree
## with that tick about who occupies the drop point -- which is the same reason
## its loop walks "sim_units" rather than "units". The negative control comes
## first here: with the blocker's store and node both far away the drop is
## legal, and only moving the *store* onto the drop point may refuse it.
func _test_transport_cargo_probe_reads_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "transport drop probe")
	var drop := Vector3(200.5, 0.0, 200.5)
	var far := Vector3(230.5, 0.0, 230.5)
	var cargo := _make_unit(navigation, Vector3(210.5, 0.0, 210.5), Vector3(210.5, 0.0, 210.5))
	var blocker := _make_unit(navigation, far, far)

	_expect(navigation.can_place_transport_cargo(cargo, drop),
		"negative control: an unoccupied drop point must be legal")
	blocker.call("set_simulation_position_override", drop)
	_expect(blocker.global_position.distance_to(drop) > 20.0,
		"the blocker's node must stay far from the drop point -- otherwise this case tests nothing")
	_expect(not navigation.can_place_transport_cargo(cargo, drop),
		("the store puts a friendly exactly on the drop point, so the probe must refuse it "
			+ "however far away that friendly's node is drawn"))

	navigation.queue_free()
	cargo.queue_free()
	blocker.queue_free()


## UnitNavigationSystem._ground_target_is_reachable(), reached here through
## can_move_to(). command_move() rejects an order outright on this answer, so
## the component the unit is asked from has to be the one the simulation says it
## stands in. The unit's node stands next to the target on open ground; its
## stored position is sealed inside a one-cell pocket with no way out.
func _test_reachability_reads_the_store_position(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "target reachability")
	var pocket := {}
	for x in range(219, 222):
		for z in range(219, 222):
			if x != 220 or z != 220:
				pocket[Vector2i(x, z)] = true
	navigation.runtime_map.replace_blocked_cells(pocket)

	var sealed_position := Vector3(220.5, 0.0, 220.5)
	var node_position := Vector3(229.5, 0.0, 230.5)
	var target := Vector3(230.5, 0.0, 230.5)
	var unit := _make_unit(navigation, node_position, sealed_position)

	_expect(not navigation.can_move_to([unit], target),
		("the store seals this unit inside a one-cell pocket, so no target outside it is "
			+ "reachable -- however open the ground its node stands on happens to be"))
	# Same node, same target, same walls: only the store's answer changes.
	unit.call("set_simulation_position_override", Vector3.INF)
	_expect(navigation.can_move_to([unit], target),
		("positive control: with no separate store value the accessor falls back to the node, "
			+ "which stands on open ground, and the identical order must now be accepted"))

	navigation.queue_free()
	unit.queue_free()


## Copied from tests/navigation/run.gd rather than shared, unlike FakeUnit: a
## grid is inert data with no behaviour to mutate, so a second copy cannot make
## a mutation miss anything. FakeUnit is shared for exactly the opposite reason.
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
	printerr("FAIL: %s" % message)
