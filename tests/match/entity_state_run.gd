extends SceneTree

## Proves the wiring, not the parts -- the SimEntityState counterpart to
## tests/match/entity_id_run.gd. Every case in tests/sim/entity_state_run.gd
## drives SimEntityState directly and would keep passing even if
## Unit.set_simulation_position() never called set_position() at all, because
## nothing there boots a real Match. This suite boots the real match fixture
## and asserts on the running match's own SimEntityState after letting units
## move through nothing but the ordinary command surface (move_to()) and the
## real tick loop -- the same shape entity_id_run.gd uses for registration and
## demo_boot_run.gd's _test_match_loop_drives_* cases use for the tick.
##
## docs/architecture/network-multiplayer.md, phase 3's C2 paragraph, is what
## this binds: "SimEntityState owns the write; the node's global_position
## becomes a mirror updated from it." A mirror that merely happens to agree
## with the store proves nothing about which one is authoritative -- only a
## case where they are made to disagree, and the store is shown to keep
## answering with its own last written value rather than the node's, proves
## that. _test_store_outlives_a_direct_node_poke is that case.
##
## Slice C3 adds health and shields, for both units and buildings, and the
## health/shields cases below are shaped differently from the position cases
## above for a reason worth stating: there is no poke case for health or
## shields the way _test_store_outlives_a_direct_node_poke exists for
## position. Health and shields are custom GDScript properties with their
## own `set(value)` on Unit and Building (scripts/units/unit.gd,
## scripts/buildings/building.gd) -- every assignment to `.health` or
## `.shields`, from any file, already runs through that setter, because
## GDScript gives a property with a setter no second name a caller could
## assign to instead. So unlike `global_position`, which is a plain Node3D
## field any code could poke directly, there is no code path left that
## writes the node's mirror without also writing the store: the two cannot
## be made to disagree. _test_health_writes_reach_the_store_for_units_and_buildings
## proves the positive claim this leaves -- store and mirror agree, for both
## kinds -- and _test_health_clamp_lands_in_the_store proves the clamp
## specifically, which is the one place the two really could still diverge
## if the store were ever handed the unclamped value by mistake.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"every fixture unit already has a store position once the match finishes booting",
		_test_boot_populates_the_store
	)
	await _run_case(
		"a unit moving under the real match loop leaves the store carrying the same "
			+ "positions the node ends up with, and previous_position() genuinely differs from it",
		_test_match_loop_drives_store_position
	)
	await _run_case(
		"a direct write to global_position that bypasses set_simulation_position "
			+ "does not move the store -- disagreement resolves in the store's favour",
		_test_store_outlives_a_direct_node_poke
	)
	await _run_case(
		"every fixture unit and building already has store health and shields once the match "
			+ "finishes booting",
		_test_boot_populates_the_store_health_and_shields
	)
	await _run_case(
		"health and shields writes reach the store for both a unit and a building",
		_test_health_writes_reach_the_store_for_units_and_buildings
	)
	await _run_case(
		"a write above max_health/max_shields lands clamped in the store, not only in the mirror",
		_test_health_clamp_lands_in_the_store
	)

	if _failures > 0:
		printerr("Entity state wiring tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Entity state wiring tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	# A runtime error aborts the case function where it stands, leaving
	# _failures untouched -- which would print PASS for a case that never
	# reached an assertion. tests/support/suite.gd guards against this and
	# this suite cannot extend it (its cases await), so the guard is repeated
	# here rather than dropped -- the same reasoning tests/match/entity_id_run.gd
	# gives for its own copy of this helper.
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


## _place_on_map() (match.gd) snaps every scene-authored unit to the ground
## and stops it, on the local player's very first frames -- slice C2 routed
## that write through Unit.set_simulation_position() too, not just the tick
## systems named in the design doc's C2 paragraph. If that one had been missed,
## every case below would still pass off later ticks alone, so it gets its own
## case rather than being assumed by the ones that move a unit.
func _test_boot_populates_the_store() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame
	await process_frame

	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")

	for unit_name in [&"ScoutA", &"OrdosAPC"]:
		var unit := match_instance.get_node("Units/%s" % unit_name) as Unit
		_expect(unit.entity_id != 0, "%s must have a nonzero entity_id by boot" % unit_name)
		_expect(
			store != null and store.has_position(unit.entity_id),
			"%s must already have a store position once the match has booted" % unit_name
		)
		if store != null and store.has_position(unit.entity_id):
			_expect(
				store.position(unit.entity_id).is_equal_approx(unit.global_position),
				"%s's store position must match its mirrored global_position after boot" % unit_name
			)

	match_instance.queue_free()
	await process_frame


## ScoutA is deliberately sent 5 world units along a single axis: far enough
## that arrival_radius (0.2 by default) cannot be reached inside this case's
## short real-time sampling window (its speed is a fraction of a world unit
## per tick -- see demo_boot_run.gd's own _test_unit_movement_animations,
## which uses the identical +3.0 offset idiom against a 20-frame budget), so
## the unit is still travelling at every checkpoint below.
func _test_match_loop_drives_store_position() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var unit := match_instance.get_node("Units/ScoutA") as Unit
	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return

	unit.move_to(unit.global_position + Vector3(5.0, 0.0, 0.0))

	# First checkpoint: enough ticks for the order to actually start moving
	# the unit, not merely enough for the order to be accepted.
	var started_msec := Time.get_ticks_msec()
	var frames := 0
	while Time.get_ticks_msec() - started_msec < 200 and frames < 400:
		await process_frame
		frames += 1
		if unit.velocity.length_squared() > 0.0001:
			break
	_expect(unit.velocity.length_squared() > 0.0001, "ScoutA must be moving before this case's checkpoints mean anything")

	var mid_store_position: Vector3 = store.position(unit.entity_id)
	var mid_node_position: Vector3 = unit.global_position
	_expect(
		mid_store_position.is_equal_approx(mid_node_position),
		"mid-flight, the store's position must match the node's mirrored global_position"
	)

	# Second checkpoint, well after the first: the unit must have travelled
	# further, and previous_position() -- unused by anything until B4 reads it
	# -- must now genuinely differ from the current value instead of merely
	# equalling it the way a single, first-ever write would (see
	# SimEntityState's own doc comment on why the first write seeds
	# previous_position() equal to itself).
	var settle_msec := Time.get_ticks_msec()
	while Time.get_ticks_msec() - settle_msec < 150:
		await process_frame

	var late_store_position: Vector3 = store.position(unit.entity_id)
	var late_node_position: Vector3 = unit.global_position
	_expect(
		late_store_position.is_equal_approx(late_node_position),
		"after further ticks, the store's position must still match the node's mirrored global_position"
	)
	_expect(
		not late_store_position.is_equal_approx(mid_store_position),
		"ScoutA must have kept moving between the two checkpoints, or this case proves nothing about multiple ticks"
	)
	var previous: Vector3 = store.previous_position(unit.entity_id)
	_expect(
		previous.is_finite(),
		"previous_position() must be a real value while the unit is alive and has been written at least once"
	)
	_expect(
		not previous.is_equal_approx(late_store_position),
		"previous_position() must genuinely differ from position() while the unit is still moving tick over tick"
	)

	match_instance.queue_free()
	await process_frame


## The binding claim of decision 3 after C2: the store is authoritative, the
## node is only a view over it. A mirror that always happens to agree proves
## nothing about which one is in charge -- this forces a disagreement by
## poking global_position directly, the exact bypass the
## global-position-bypasses-store architecture rule exists to catch in
## production code, and shows the store does not follow the node's rogue
## write. Reading the store, not the node, is how a snapshot, a checksum or a
## replay would settle the disagreement.
func _test_store_outlives_a_direct_node_poke() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var unit := match_instance.get_node("Units/OrdosAPC") as Unit
	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return
	_expect(
		store.has_position(unit.entity_id),
		"OrdosAPC must already have a store position from boot before this case pokes it"
	)

	var trusted_position: Vector3 = store.position(unit.entity_id)
	var rogue_position := trusted_position + Vector3(999.0, 0.0, 999.0)
	# Bypasses set_simulation_position() on purpose -- this is exactly the
	# direct write the new architecture rule forbids in scripts/, reproduced
	# here to prove what the store does when it happens anyway.
	unit.global_position = rogue_position

	_expect(
		unit.global_position.is_equal_approx(rogue_position),
		"the node itself must show the rogue write -- otherwise this case is not testing a real disagreement"
	)
	_expect(
		store.position(unit.entity_id).is_equal_approx(trusted_position),
		"the store must keep its own last written value instead of silently following a direct node write"
	)
	_expect(
		not store.position(unit.entity_id).is_equal_approx(unit.global_position),
		"store and node must actually disagree here, and the store's answer -- not the node's -- must be the one trusted"
	)

	match_instance.queue_free()
	await process_frame


## Boot alone -- Unit._ready() and Building._ready() both run `health =
## max_health` and `shields = max_shields` before this case ever touches
## either node -- so this proves the setter's store write fires from the
## ordinary object lifecycle, not only from a write this test manufactures.
func _test_boot_populates_the_store_health_and_shields() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame
	await process_frame

	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")

	var unit_paths: Array[String] = ["Units/ScoutA", "Units/OrdosAPC"]
	var building_paths: Array[String] = ["Buildings/ATConYard", "Buildings/ATSmWindtrap"]
	for path in unit_paths + building_paths:
		# Bare `=`, not `:=`: entity_id/health/shields exist on Unit and
		# Building but not on Node, the static type get_node() returns, so
		# this deliberately stays dynamically typed rather than risk a
		# member-not-found parse error on the shared Node type.
		var entity = match_instance.get_node(path)
		_expect(int(entity.entity_id) != 0, "%s must have a nonzero entity_id by boot" % path)
		if store == null:
			continue
		_expect(
			store.has_health(entity.entity_id),
			"%s must already have store health once the match has booted" % path
		)
		_expect(
			store.has_shields(entity.entity_id),
			"%s must already have store shields once the match has booted" % path
		)
		if store.has_health(entity.entity_id):
			_expect(
				is_equal_approx(store.health(entity.entity_id), float(entity.health)),
				"%s's store health must match its mirrored health field after boot" % path
			)
		if store.has_shields(entity.entity_id):
			_expect(
				is_equal_approx(store.shields(entity.entity_id), float(entity.shields)),
				"%s's store shields must match its mirrored shields field after boot" % path
			)

	match_instance.queue_free()
	await process_frame


## Direct assignment to `.health`/`.shields`, not take_damage() or the repair
## service: any caller -- combat, repair, or this test -- reaches the
## identical property setter (see this file's own header comment on why that
## makes them equivalent for what this case is proving), so assigning
## directly isolates the setter's own behaviour from any one gameplay
## caller's balance data.
func _test_health_writes_reach_the_store_for_units_and_buildings() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 3:
		await process_frame

	var unit := match_instance.get_node("Units/ScoutA") as Unit
	var building := match_instance.get_node("Buildings/ATConYard") as Building
	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return

	unit.max_shields = 40.0
	building.max_shields = 60.0

	unit.health = unit.max_health * 0.5
	unit.shields = 25.0
	building.health = building.max_health * 0.25
	building.shields = 15.0

	_expect(
		is_equal_approx(store.health(unit.entity_id), unit.health),
		"the unit's store health must match its mirrored health field after a direct write"
	)
	_expect(
		is_equal_approx(store.shields(unit.entity_id), unit.shields),
		"the unit's store shields must match its mirrored shields field after a direct write"
	)
	_expect(
		is_equal_approx(store.health(building.entity_id), building.health),
		"the building's store health must match its mirrored health field after a direct write"
	)
	_expect(
		is_equal_approx(store.shields(building.entity_id), building.shields),
		"the building's store shields must match its mirrored shields field after a direct write"
	)

	match_instance.queue_free()
	await process_frame


## Binds the design doc's clamp note directly: "clampf(value, 0.0,
## max_health): the clamp is a simulation decision -- it changes the value
## that gets stored -- so it has to happen on the way into the store, not
## only on the way into the mirror, or the two hold different numbers."
## Passing set_health()/set_shields() the raw, unclamped `value` argument
## instead of the setter's own `clamped` local would leave the store holding
## the over-range number while the mirror shows the correctly clamped one --
## this case fails the moment that happens, on both bounds and for both a
## unit and a building.
func _test_health_clamp_lands_in_the_store() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 3:
		await process_frame

	var unit := match_instance.get_node("Units/ScoutA") as Unit
	var building := match_instance.get_node("Buildings/ATConYard") as Building
	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return

	unit.max_shields = 40.0
	building.max_shields = 60.0

	# Above max_health/max_shields.
	unit.health = unit.max_health + 5000.0
	unit.shields = unit.max_shields + 5000.0
	building.health = building.max_health + 5000.0
	building.shields = building.max_shields + 5000.0
	_expect(unit.health == unit.max_health, "sanity check: the node's own clamp already caps the unit's health")
	_expect(
		is_equal_approx(store.health(unit.entity_id), unit.max_health),
		"an over-max health write must land clamped to max_health in the store, not the raw over-max value"
	)
	_expect(
		is_equal_approx(store.shields(unit.entity_id), unit.max_shields),
		"an over-max shields write must land clamped to max_shields in the store"
	)
	_expect(
		is_equal_approx(store.health(building.entity_id), building.max_health),
		"a building's over-max health write must land clamped in the store exactly as a unit's does"
	)
	_expect(
		is_equal_approx(store.shields(building.entity_id), building.max_shields),
		"a building's over-max shields write must land clamped in the store"
	)

	# Below zero: the other bound of the same clamp.
	unit.health = -100.0
	building.shields = -100.0
	_expect(
		is_equal_approx(store.health(unit.entity_id), 0.0),
		"a below-zero health write must land clamped to 0.0 in the store, not the raw negative value"
	)
	_expect(
		is_equal_approx(store.shields(building.entity_id), 0.0),
		"a below-zero shields write must land clamped to 0.0 in the store"
	)

	match_instance.queue_free()
	await process_frame
