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
## Same scene tests/match/despawn_run.gd uses for the identical reason: the
## fixture's own buildings (ATConYard, ATSmWindtrap) carry no CombatTurret to
## observe.
const HKGunTurretScene := preload("res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn")

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
	await _run_case(
		"a unit added beside a dying Match registers with the live one, not the dying one",
		_test_unit_beside_a_dying_match_registers_with_the_live_match
	)
	await _run_case(
		"two simultaneously live matches each resolve their own fixture, not each other's",
		_test_two_simultaneously_live_matches_each_resolve_their_own_fixture
	)
	await _run_case(
		"every unit and building is in both its view group and its tick-only sim group",
		_test_every_unit_and_building_is_in_both_its_view_group_and_its_sim_group
	)
	await _run_case(
		"a node removed from its tick-only sim group, but left in the view group, stops being ticked",
		_test_removing_sim_group_membership_stops_ticking_without_touching_the_view_group
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


## Regression case for docs/architecture/network-multiplayer.md's phase 3
## "A finding this slice reported wrongly" paragraph: MatchLookupScript used
## to resolve the running match with get_first_node_in_group(GROUP) alone,
## with no is_queued_for_deletion() check, so a Unit entering the tree beside
## a dying Match took its entity id from a registry about to disappear.
## Built directly rather than relied on from a suite that happens to
## reproduce it (demo_boot_run.gd's ~1700 refused writes never say which
## unit hit this path or when) -- two Match instances, the first
## queue_free()d without a frame in between so it is still group-member #1,
## then a fresh Unit added under the second.
func _test_unit_beside_a_dying_match_registers_with_the_live_match() -> void:
	var match_one := MatchFixtureScene.instantiate()
	get_root().add_child(match_one)
	await process_frame

	match_one.queue_free()
	# Deliberately not awaited -- see every other case's own comment on this
	# above. Here that is the point rather than a hazard to guard against:
	# match_one must still be a member of MatchLookupScript.GROUP for both
	# add_child() calls below, which is the exact scenario this case exists
	# to build. match_two is still created only after match_one.queue_free(),
	# but that ordering is now a choice about which scenario this case
	# builds, not a workaround for a limitation MatchLookup still has: with
	# ancestor resolution, two fully live matches at once no longer misroute
	# either one's fixture (see
	# _test_two_simultaneously_live_matches_each_resolve_their_own_fixture
	# below, which builds exactly that and asserts on it). This case keeps
	# the queue_free()-then-create order because a dying match beside a live
	# one is its own scenario, distinct from two live matches, and worth its
	# own regression rather than folding into the other.
	var match_two := MatchFixtureScene.instantiate()
	get_root().add_child(match_two)
	# Not awaited either: match_two's whole fixture -- including the units
	# whose own registration this case is not testing -- resolves
	# synchronously inside this add_child() call, the same as the new unit
	# below. Waiting here would cost nothing for match_two's own fixture,
	# but it would also let match_one's deferred removal actually run before
	# the new unit ever looks the group up, proving nothing.

	var unit_scene := load("res://scenes/units/unit.tscn") as PackedScene
	var unit := unit_scene.instantiate()
	# ScoutA's own authored position (tests/fixtures/match_fixture.tscn) --
	# guarantees the terrain raycast in
	# UnitTerrainAlignment.snap_body_to_terrain() actually hits the map both
	# matches share a copy of, instead of gambling on whatever a default
	# (0, 0, 0) happens to sit over.
	unit.position = Vector3(129.6, 8.0, 22.2)
	match_two.get_node("Units").add_child(unit)
	# add_child() on a parent already inside the tree runs
	# _enter_tree()/_ready() synchronously, with no frame boundary before
	# control returns here -- see MatchLookupScript's own doc comment on
	# _enter_tree() ordering. unit._register_entity_id() has therefore
	# already resolved (or misresolved) a match by this point.

	_expect(
		unit.entity_id != 0,
		"the unit must still get an id -- match_two is live in the group, so this is not the " +
			"no-Match-in-the-tree case MatchLookupScript already tolerates"
	)

	var match_two_index = match_two.entity_index()
	_expect(
		match_two_index != null and match_two_index.registry().is_alive(unit.entity_id),
		"the unit's id must resolve in match_two's registry -- the live match, not the dying one"
	)
	# Guards against a fix that just returns null whenever the first
	# candidate is dying, instead of walking on to the live one: that would
	# leave entity_id at 0 and already fail the check above, but checking
	# match_one's own registry too rules out the id having been taken from
	# the wrong (dying) registry and merely happening to also look unbound
	# in match_two's.
	var match_one_index = match_one.entity_index()
	_expect(
		match_one_index != null and not match_one_index.registry().is_alive(unit.entity_id),
		"match_one's own registry must not know this id either"
	)

	var store = match_two.entity_state()
	var started_msec := Time.get_ticks_msec()
	var frames := 0
	while frames < 400 and Time.get_ticks_msec() - started_msec < 500:
		await process_frame
		frames += 1
		if store != null and store.has_position(unit.entity_id):
			break
	_expect(
		store != null and store.has_position(unit.entity_id),
		"the unit must pick up a position from match_two's own tick loop within the timeout"
	)
	var pos = store.position(unit.entity_id)
	_expect(
		pos.is_finite(),
		"match_two.entity_state().position(unit.entity_id) must be finite once the unit has a position"
	)

	match_two.queue_free()
	await process_frame


## Second regression case, for what ancestor resolution newly makes true
## rather than what it merely stops breaking: two Matches simultaneously
## live, neither one dying, is a case group-position resolution could never
## get right at all -- not "usually right, wrong for a frame during
## teardown" like the case above, but wrong for as long as both matches
## exist. get_first_node_in_group(GROUP) can only ever return one candidate,
## so whichever match sits second in the group would have had its entire
## fixture -- ScoutA, OrdosAPC, the lot -- register into the *first* match's
## registry instead of its own, permanently, with no queue_free() involved
## anywhere. The previous slice's own report named this as a real defect it
## could not fix from a resolver that only knew how to skip a dying
## candidate; ancestor resolution fixes it as a side effect of answering the
## right question (ownership, not position), so this asserts on it directly
## rather than leaving it as a claim.
##
## Both matches stay alive for the whole case -- no queue_free(), no
## ordering trick -- which is the point: this is the ordinary "two matches
## exist" shape, not the teardown-window shape the case above builds.
##
## Asserts via node_for() identity rather than registry().is_alive(id),
## deliberately: each match's EntityNodeIndex allocates ids from its own
## _next_id counter starting at 1 (scripts/sim/entity_registry.gd), and
## match_one and match_two instantiate the identical fixture scene in the
## identical order, so match_one's ScoutA and match_two's ScoutA routinely
## end up with the *same* id number in their own independent registries.
## is_alive(id) cannot tell those two apart -- asking match_one's registry
## "is scout_two's id alive" collapses to asking "is scout_one's id alive"
## whenever the numbers coincide, which would make the cross-match
## assertion fail on fully correct code purely by coincidence. node_for(id)
## does not have that problem: it returns a Node, and comparing that Node's
## identity to the specific scout under test is correct whether the id
## numbers happen to match or not.
func _test_two_simultaneously_live_matches_each_resolve_their_own_fixture() -> void:
	var match_one := MatchFixtureScene.instantiate()
	get_root().add_child(match_one)
	await process_frame

	var match_two := MatchFixtureScene.instantiate()
	get_root().add_child(match_two)
	await process_frame

	var scout_one := match_one.get_node("Units/ScoutA")
	var scout_two := match_two.get_node("Units/ScoutA")
	_expect(
		scout_one.entity_id != 0 and scout_two.entity_id != 0,
		"both matches' ScoutA must register an id -- two live matches is not the no-Match case"
	)

	var index_one = match_one.entity_index()
	var index_two = match_two.entity_index()
	_expect(
		index_one != null and index_two != null,
		"both matches must expose a live EntityNodeIndex while both are alive"
	)

	_expect(
		index_one != null and index_one.node_for(scout_one.entity_id) == scout_one,
		"match_one's ScoutA must round-trip through match_one's own registry"
	)
	_expect(
		index_two != null and index_two.node_for(scout_one.entity_id) != scout_one,
		"match_one's ScoutA must not be the node match_two's registry hands back for that id"
	)
	_expect(
		index_two != null and index_two.node_for(scout_two.entity_id) == scout_two,
		"match_two's ScoutA must round-trip through match_two's own registry"
	)
	_expect(
		index_one != null and index_one.node_for(scout_two.entity_id) != scout_two,
		"match_two's ScoutA must not be the node match_one's registry hands back for that id"
	)

	match_one.queue_free()
	match_two.queue_free()
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


## Slice C6a's own suite -- see docs/architecture/network-multiplayer.md,
## "Slice C6, decided 2026-08-22: deferred spawn, and the group that had to
## be split first." A suite that only checked group membership at rest would
## pass identically whether Unit._ready()/Building._ready() ever reached the
## tick-only group at all -- as long as "units"/"buildings" themselves stayed
## correct, nothing here would fail. This case is that claim, checked
## directly rather than assumed: every member of "units" must also be a
## member of "sim_units", and vice versa, so a future reader adding a unit
## kind that skips one of the two sees a failure here, not silence.
##
## C6a's own wording for the claim was "identical at every instant". Slice
## C6c narrowed it, deliberately and by exactly one drain: Unit._ready() and
## Building._ready() now *request* entry into the tick-only group through the
## admission queue instead of joining it themselves, so between an entity's
## creation and the next apply_pending_entries() the two memberships differ
## by that entity. What is still true, and what this case asserts, is that
## they are identical once the tick has run -- which is why the explicit tick
## below is part of the assertion rather than setup noise. The narrower claim
## is the whole point of C6b/C6c; the divergence *during* a tick has its own
## cases in tests/match/admission_run.gd.
func _test_every_unit_and_building_is_in_both_its_view_group_and_its_sim_group() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	# Driven directly rather than left to the awaited frame above: an awaited
	# frame advances the clock by however much wall time it happened to take
	# and is not guaranteed to produce a tick at all, which would leave this
	# case asserting the mid-tick divergence instead of the settled state.
	match_instance.call("_advance_simulation_tick")

	var tree := get_root().get_tree()
	var view_units := tree.get_nodes_in_group("units")
	var sim_units := tree.get_nodes_in_group("sim_units")
	_expect(not view_units.is_empty(), "the fixture must have at least one unit to make this assertion meaningful")
	_expect(
		view_units.size() == sim_units.size(),
		"\"units\" has %d members, \"sim_units\" has %d -- membership must be identical once the tick has run" \
			% [view_units.size(), sim_units.size()]
	)
	for unit in view_units:
		_expect(sim_units.has(unit), "%s is in \"units\" but missing from \"sim_units\"" % unit.name)
	for unit in sim_units:
		_expect(view_units.has(unit), "%s is in \"sim_units\" but missing from \"units\"" % unit.name)

	var view_buildings := tree.get_nodes_in_group("buildings")
	var sim_buildings := tree.get_nodes_in_group("sim_buildings")
	_expect(
		not view_buildings.is_empty(), "the fixture must have at least one building to make this assertion meaningful"
	)
	_expect(
		view_buildings.size() == sim_buildings.size(),
		"\"buildings\" has %d members, \"sim_buildings\" has %d" % [view_buildings.size(), sim_buildings.size()]
	)
	for building in view_buildings:
		_expect(sim_buildings.has(building), "%s is in \"buildings\" but missing from \"sim_buildings\"" % building.name)
	for building in sim_buildings:
		_expect(view_buildings.has(building), "%s is in \"sim_buildings\" but missing from \"buildings\"" % building.name)

	match_instance.queue_free()
	await process_frame


## The property C6b will actually depend on, and the one a suite that only
## checks membership at rest (the case above) cannot see at all: membership
## in "units"/"buildings" is identical to "sim_units"/"sim_buildings" at
## every instant *today*, because nothing yet defers one from the other.
## C6b changes exactly that -- an entity's entry into the tick-only group
## alone -- so this proves the tick already keys off the tick-only group,
## not the shared one, ahead of that split actually landing.
##
## Unit half: _previous_global_position is the observable.
## Unit._advance_locomotion_tick(), called once per tick from sim_tick() with
## no early-out before this line, unconditionally overwrites it with that
## tick's global_position -- so a sentinel value written directly into it
## survives untouched exactly when, and only when, sim_tick() does not run
## this unit this tick. Chosen over reload_ticks_remaining for this half
## because ScoutA (the fixture's plain scout) is not guaranteed to carry a
## weapon, while every Unit, armed or not, runs _advance_locomotion_tick().
##
## Building half: reload_ticks_remaining is the observable, the same one
## tests/match/despawn_run.gd already uses and for the identical reason --
## the fixture's own buildings carry no CombatTurret, so a HKGunTurret is
## added for this case alone.
##
## Both halves drive match_instance.call("_advance_simulation_tick") directly
## rather than await process_frame, so the case controls exactly one tick per
## call instead of however many FrameTickDriver decides a frame owes.
func _test_removing_sim_group_membership_stops_ticking_without_touching_the_view_group() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame

	var scout := match_instance.get_node("Units/ScoutA")
	_expect(
		scout.is_in_group("units") and scout.is_in_group("sim_units"),
		"ScoutA must start in both \"units\" and \"sim_units\""
	)
	var sentinel := Vector3(4321.5, 4321.5, 4321.5)
	scout.set("_previous_global_position", sentinel)
	scout.remove_from_group("sim_units")
	_expect(scout.is_in_group("units"), "removing \"sim_units\" must not remove \"units\" too")
	match_instance.call("_advance_simulation_tick")
	var after_removal: Vector3 = scout.get("_previous_global_position")
	_expect(
		after_removal == sentinel,
		"a unit left in \"units\" but removed from \"sim_units\" must not be ticked"
	)
	# Positive control -- without it, a suite where ScoutA was never ticked at
	# all (e.g. because "sim_units" was wired to nothing, or this fixture's
	# Match never reaches the tick loop) would pass the assertion above for
	# the wrong reason: not because removal stopped the tick, but because
	# nothing was ever ticking ScoutA in the first place.
	scout.add_to_group("sim_units")
	match_instance.call("_advance_simulation_tick")
	var after_rejoin: Vector3 = scout.get("_previous_global_position")
	_expect(
		after_rejoin != sentinel,
		"sanity check: rejoining \"sim_units\" must make the unit tick again"
	)

	var building := HKGunTurretScene.instantiate() as Building
	building.owner_player_id = 1
	match_instance.get_node("Buildings").add_child(building)
	# One frame so _ready() runs: add_to_group("buildings")/add_to_group(
	# "sim_buildings") and turret construction all happen there.
	await process_frame
	_expect(building.combat_turrets.size() == 1, "HKGunTurret must create one runtime turret to observe")
	if building.combat_turrets.is_empty():
		match_instance.queue_free()
		await process_frame
		return
	# Bare CombatTurret annotation, not `:=`: Building.combat_turrets is a
	# plain untyped Array (scripts/buildings/building.gd), so indexing it
	# returns Variant -- project.godot makes Variant-inferred `var x :=
	# untyped.method()` a parse error that fails this whole file, not merely
	# a failed assertion.
	var turret: CombatTurret = building.combat_turrets[0]
	_expect(
		building.is_in_group("buildings") and building.is_in_group("sim_buildings"),
		"a freshly placed building must start in both \"buildings\" and \"sim_buildings\""
	)

	turret.reload_ticks_remaining = 5
	building.remove_from_group("sim_buildings")
	_expect(building.is_in_group("buildings"), "removing \"sim_buildings\" must not remove \"buildings\" too")
	match_instance.call("_advance_simulation_tick")
	_expect(
		turret.reload_ticks_remaining == 5,
		"a building left in \"buildings\" but removed from \"sim_buildings\" must not be ticked"
	)
	# Positive control, same reason as the unit half above.
	building.add_to_group("sim_buildings")
	match_instance.call("_advance_simulation_tick")
	_expect(
		turret.reload_ticks_remaining == 4,
		"sanity check: rejoining \"sim_buildings\" must make the building tick again"
	)

	match_instance.queue_free()
	await process_frame
