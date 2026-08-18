extends SceneTree

## Proves the wiring, not the parts: every case in
## tests/sim/entity_registry_run.gd exercises SimEntityRegistry directly and
## would keep passing even if Unit._ready()/Building._ready() never called
## MatchLookupScript.entity_index().register() at all, because nothing there
## boots a real Match. This suite boots the real match fixture and asserts on
## its own self-registered state without ever calling register() itself --
## the same shape as tests/match/demo_boot_run.gd's
## _test_match_loop_drives_the_clock and friends for the tick loop.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"every unit and building in the fixture gets a distinct nonzero entity_id",
		_test_every_entity_has_a_distinct_id
	)
	await _run_case(
		"the index round-trips a live unit's id back to that same node",
		_test_node_for_round_trips
	)
	await _run_case(
		"freeing an entity releases its id, and the id is never reissued",
		_test_freed_entity_releases_and_never_reissues_its_id
	)

	if _failures > 0:
		printerr("Entity id wiring tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Entity id wiring tests: %d assertions passed" % _assertions)
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
	# here rather than dropped: a wiring test that can pass by crashing
	# defeats its own reason to exist.
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


func _test_every_entity_has_a_distinct_id() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame

	var seen_ids: Dictionary = {}
	var entity_count := 0
	for unit in get_root().get_tree().get_nodes_in_group("units"):
		entity_count += 1
		_expect(unit.entity_id != 0, "%s (unit) must have a nonzero entity_id" % unit.name)
		_expect(not seen_ids.has(unit.entity_id), "%s (unit) reused entity_id %d" % [unit.name, unit.entity_id])
		seen_ids[unit.entity_id] = true
	for building in get_root().get_tree().get_nodes_in_group("buildings"):
		entity_count += 1
		_expect(building.entity_id != 0, "%s (building) must have a nonzero entity_id" % building.name)
		_expect(
			not seen_ids.has(building.entity_id),
			"%s (building) reused entity_id %d" % [building.name, building.entity_id]
		)
		seen_ids[building.entity_id] = true
	_expect(entity_count > 0, "the fixture must contain at least one unit or building to make this assertion meaningful")

	match_instance.queue_free()
	# queue_free() defers the actual removal to this frame's teardown, and
	# until that runs this Match is still a member of MatchLookupScript.GROUP.
	# Without waiting for it here, the next case's fresh Match could lose the
	# race for get_first_node_in_group() to this one on its way out, and its
	# entities would silently register into the wrong (dying) index.
	await process_frame


func _test_node_for_round_trips() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame

	var index = match_instance.entity_index()
	_expect(index != null, "Match must expose a live EntityNodeIndex")
	var unit := match_instance.get_node("Units/ScoutA")
	_expect(
		index != null and index.node_for(unit.entity_id) == unit,
		"index.node_for(unit.entity_id) must round-trip back to the same node"
	)
	_expect(
		index != null and index.id_for(unit) == unit.entity_id,
		"index.id_for(unit) must agree with unit.entity_id"
	)

	match_instance.queue_free()
	# queue_free() defers the actual removal to this frame's teardown, and
	# until that runs this Match is still a member of MatchLookupScript.GROUP.
	# Without waiting for it here, the next case's fresh Match could lose the
	# race for get_first_node_in_group() to this one on its way out, and its
	# entities would silently register into the wrong (dying) index.
	await process_frame


func _test_freed_entity_releases_and_never_reissues_its_id() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame

	var index = match_instance.entity_index()
	var unit := match_instance.get_node("Units/ScoutA")
	var freed_id: int = unit.entity_id

	unit.queue_free()
	# queue_free() defers actual deletion but Unit._exit_tree() (which
	# releases the id) runs synchronously once the node leaves the tree --
	# await a process frame so that deferred removal has actually happened.
	await process_frame

	_expect(index.node_for(freed_id) == null, "node_for() must return null once the bound entity is freed")
	_expect(not index.registry().is_alive(freed_id), "the released id must report dead in the registry")

	var building := match_instance.get_node("Buildings/ATConYard")
	var reissued_id: int = 0
	for _i in 5:
		var new_unit_scene := load("res://scenes/units/unit.tscn") as PackedScene
		var new_unit := new_unit_scene.instantiate()
		match_instance.get_node("Units").add_child(new_unit)
		reissued_id = new_unit.entity_id
		if reissued_id == freed_id:
			break
	_expect(reissued_id != freed_id, "a freed entity's id must never be reissued to a later entity")
	_expect(
		building.entity_id != freed_id,
		"a freed unit's id must not collide with an existing building's id either"
	)

	match_instance.queue_free()
	# queue_free() defers the actual removal to this frame's teardown, and
	# until that runs this Match is still a member of MatchLookupScript.GROUP.
	# Without waiting for it here, the next case's fresh Match could lose the
	# race for get_first_node_in_group() to this one on its way out, and its
	# entities would silently register into the wrong (dying) index.
	await process_frame
