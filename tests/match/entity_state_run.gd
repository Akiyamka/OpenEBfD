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
