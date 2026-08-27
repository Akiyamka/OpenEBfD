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
##
## Slice C4 adds owner_player_id, for both kinds again, and it is the one
## field of the four where "the setter is the only chokepoint" is not the
## whole story: the setter can only write into the store once _entity_id is
## nonzero, and owner_player_id is routinely assigned *before* that -- every
## fixture and demo scene sets it as a scene property (Godot applies those
## during PackedScene.instantiate(), before add_child()), and
## MatchSnapshot._restore_entities() does the identical thing on every load.
## _test_boot_populates_the_store_owner_player_id already exercises that
## path incidentally, because match_fixture.tscn's units and buildings are
## themselves examples of it, but incidental coverage is not what closes a
## slice: _test_owner_assigned_before_registration_reaches_the_store below
## manufactures the exact scenario directly -- construct a node, assign
## owner_player_id, *then* add_child() it -- so it fails specifically, and
## only, if Unit._register_entity_id() / Building._register_entity_id()'s
## registration-time push (scripts/sim/entity_state.gd's own "Registration-
## time push" section) regresses, independent of whatever the fixture scene
## happens to author.
##
## Slice R1 gives buildings the one field C2 gave only units -- position --
## and the three cases it adds at the bottom of this file are deliberately
## shaped as the building-side copies of the unit cases at the top, because
## the claim being proved is the same claim: the store is authoritative and
## the node is a view. _test_building_position_reaches_the_store is the
## positive half, _test_building_store_outlives_a_direct_node_poke is the
## disagreement that proves which side wins, and
## _test_building_position_write_to_a_dead_id_is_refused is the refusal path
## tests/sim/entity_state_run.gd's _test_write_released_id_refused states
## against a bare store, restated here through
## Building.set_simulation_position() so that the node's half of that
## contract -- it still moves, keeping the symptom loud -- is pinned too.
## That last case pushes exactly one deliberate "write refused" error.
##
## Slice R2 adds the read half -- Unit.simulation_position() and
## Building.simulation_position() -- and its three cases are shaped by the
## same argument the C2 cases above are, one step further on. Agreement
## proves nothing: an accessor that simply returned `global_position` would
## pass a test asserting store and answer match, and that accessor is exactly
## the one this program exists to remove. So
## _test_simulation_position_outlives_a_direct_node_poke reuses the rogue
## write the C2 and R1 poke cases already perform and then asks the *node*
## where it is -- the answer must be the store's value and must differ from
## the node's own field, for a unit and for a building both.
## _test_simulation_position_falls_back_with_no_match covers the other half
## of the accessor's contract, the one its doc comment calls its one danger:
## with no Match in the tree there is no store to be authoritative, entity_id
## is 0, and the method must answer from the node without reaching
## SimEntityState.position() for an id it has no entry for -- which would
## push an error rather than return.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
const SNAPSHOT_TEST_PATH := "user://entity_state_snapshot_test.json"

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
	await _run_case(
		"every fixture unit and building already has a store owner_player_id once the match "
			+ "finishes booting",
		_test_boot_populates_the_store_owner_player_id
	)
	await _run_case(
		"owner_player_id writes reach the store for both a unit and a building",
		_test_owner_player_id_writes_reach_the_store_for_units_and_buildings
	)
	await _run_case(
		"a unit or building whose owner_player_id is assigned before add_child() still ends up "
			+ "with the right owner in the store once it registers",
		_test_owner_assigned_before_registration_reaches_the_store
	)
	await _run_case(
		"every fixture building already has a store position once the match finishes booting, "
			+ "and a building added afterward lands in the store exactly where it was told to",
		_test_building_position_reaches_the_store
	)
	await _run_case(
		"a direct write to a building's global_position that bypasses set_simulation_position "
			+ "does not move the store -- disagreement resolves in the store's favour",
		_test_building_store_outlives_a_direct_node_poke
	)
	await _run_case(
		"a building position write for an id the registry reports dead is refused, the node still "
			+ "moves, and no other id's stored position is disturbed",
		_test_building_position_write_to_a_dead_id_is_refused
	)
	await _run_case(
		"simulation_position() answers from the store for a unit and for a building",
		_test_simulation_position_answers_from_the_store
	)
	await _run_case(
		"simulation_position() keeps answering the store's value after global_position is poked "
			+ "behind its back -- for a unit and for a building",
		_test_simulation_position_outlives_a_direct_node_poke
	)
	await _run_case(
		"simulation_position() falls back to the node for a unit with no Match in the tree",
		_test_simulation_position_falls_back_with_no_match
	)
	await _run_case(
		"an entity MatchSnapshot restores into a live Match lands in the store, not only on "
			+ "the node",
		_test_snapshot_restore_reaches_the_store
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


## Every fixture unit and building sets owner_player_id as a scene property
## (see tests/fixtures/match_fixture.tscn: ScoutA=1, OrdosAPC=2, ATConYard=1,
## ATSmWindtrap=1), which Godot applies during PackedScene.instantiate() --
## before add_child(), before _ready(), before _entity_id exists. So this
## case incidentally exercises the pre-registration path C4 exists to close,
## the same way ScoutA/ATConYard's authored health already made
## _test_boot_populates_the_store_health_and_shields prove the ordinary
## lifecycle path for that field.
## _test_owner_assigned_before_registration_reaches_the_store below proves
## the same claim on purpose, independent of what this fixture happens to
## author.
func _test_boot_populates_the_store_owner_player_id() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame
	await process_frame

	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")

	var expected_owner := {
		"Units/ScoutA": 1,
		"Units/OrdosAPC": 2,
		"Buildings/ATConYard": 1,
		"Buildings/ATSmWindtrap": 1,
	}
	for path in expected_owner:
		# Bare `=`, not `:=`: entity_id/owner_player_id exist on Unit and
		# Building but not on Node, the static type get_node() returns --
		# see _test_boot_populates_the_store_health_and_shields's own
		# comment for why this stays dynamically typed.
		var entity = match_instance.get_node(path)
		_expect(int(entity.entity_id) != 0, "%s must have a nonzero entity_id by boot" % path)
		if store == null:
			continue
		_expect(
			store.has_owner_player_id(entity.entity_id),
			"%s must already have a store owner_player_id once the match has booted" % path
		)
		if store.has_owner_player_id(entity.entity_id):
			_expect(
				store.owner_player_id(entity.entity_id) == int(expected_owner[path]),
				"%s's store owner_player_id must match its scene-authored value" % path
			)
			_expect(
				store.owner_player_id(entity.entity_id) == int(entity.owner_player_id),
				"%s's store owner_player_id must match its mirrored owner_player_id field after boot" % path
			)

	match_instance.queue_free()
	await process_frame


## Direct assignment to `.owner_player_id`, not set_owner_player_id() or any
## one gameplay caller: this isolates the property setter's own behaviour,
## the same reasoning _test_health_writes_reach_the_store_for_units_and_buildings
## gives for health/shields. Both entities are already registered (added by
## the fixture at boot), so this is the ordinary post-registration write
## path -- _test_owner_assigned_before_registration_reaches_the_store below
## covers the other one.
func _test_owner_player_id_writes_reach_the_store_for_units_and_buildings() -> void:
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

	unit.owner_player_id = 3
	building.owner_player_id = 2

	_expect(
		store.owner_player_id(unit.entity_id) == 3,
		"the unit's store owner_player_id must match its mirrored owner_player_id field after a direct write"
	)
	_expect(
		store.owner_player_id(building.entity_id) == 2,
		"the building's store owner_player_id must match its mirrored owner_player_id field after a direct write"
	)

	match_instance.queue_free()
	await process_frame


## The specific regression this slice exists to close, proven directly
## rather than only incidentally (see this file's own header comment and
## _test_boot_populates_the_store_owner_player_id's). A freshly instantiated
## Unit and Building both get owner_player_id assigned *before* add_child()
## -- exactly what a scene's exported value and
## MatchSnapshot._restore_entities() both do in production (see
## scripts/sim/entity_state.gd's "Registration-time push" section) -- so
## _entity_id is still 0 when the property setter runs and its own store
## write is skipped. Only Unit._register_entity_id() / Building.
## _register_entity_id() pushing the mirror's current value into the store
## at registration time can make this case pass; removing that push fails
## it specifically, even though
## _test_owner_player_id_writes_reach_the_store_for_units_and_buildings above
## keeps passing.
func _test_owner_assigned_before_registration_reaches_the_store() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 3:
		await process_frame

	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return

	var unit := UnitScene.instantiate() as Unit
	unit.owner_player_id = 3
	_expect(unit.entity_id == 0, "sanity check: a freshly instantiated unit must not be registered yet")
	match_instance.get_node("Units").add_child(unit)
	await process_frame

	_expect(unit.entity_id != 0, "the unit must be registered once it has entered the tree")
	_expect(
		store.has_owner_player_id(unit.entity_id),
		"a unit whose owner_player_id was assigned before add_child() must still have a store "
			+ "owner_player_id once it registers"
	)
	if store.has_owner_player_id(unit.entity_id):
		_expect(
			store.owner_player_id(unit.entity_id) == 3,
			"the store's owner_player_id must match the value assigned before registration, not 0 or "
				+ "PlayerDataScript.NEUTRAL_PLAYER_ID"
		)

	var building := ConYardScene.instantiate() as Building
	building.owner_player_id = 2
	_expect(building.entity_id == 0, "sanity check: a freshly instantiated building must not be registered yet")
	match_instance.get_node("Buildings").add_child(building)
	await process_frame

	_expect(building.entity_id != 0, "the building must be registered once it has entered the tree")
	_expect(
		store.has_owner_player_id(building.entity_id),
		"a building whose owner_player_id was assigned before add_child() must still have a store "
			+ "owner_player_id once it registers"
	)
	if store.has_owner_player_id(building.entity_id):
		_expect(
			store.owner_player_id(building.entity_id) == 2,
			"the store's owner_player_id must match the value assigned before registration"
		)

	unit.queue_free()
	building.queue_free()
	match_instance.queue_free()
	await process_frame


## Slice R1's positive case, in two halves that fail for different reasons.
## The first half is Match._place_on_map()'s snap-to-ground loop over
## scene-authored buildings, the exact counterpart of the unit loop
## _test_boot_populates_the_store above covers -- if R1 had routed only the
## placement path and left that loop writing global_position directly, every
## fixture building would boot with no store position at all and nothing else
## in this suite would notice.
## The second half is the setter's own contract, on a building the boot loop
## never touched, and it asserts an exact value rather than agreement with the
## node: a store that blindly followed whatever the node held would also show
## the two agreeing, so agreement alone proves nothing about who wrote what.
## The "no store position yet" check before the write is what makes the
## after-the-write assertion mean this call and not the fixture's own boot.
func _test_building_position_reaches_the_store() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return

	for building_name in ["ATConYard", "ATSmWindtrap"]:
		var building := match_instance.get_node("Buildings/%s" % building_name) as Building
		_expect(building.entity_id != 0, "%s must have a nonzero entity_id by boot" % building_name)
		_expect(
			store.has_position(building.entity_id),
			"%s must already have a store position once the match has booted" % building_name
		)
		if store.has_position(building.entity_id):
			_expect(
				store.position(building.entity_id).is_equal_approx(building.global_position),
				"%s's store position must match its mirrored global_position after boot" % building_name
			)

	var placed := ConYardScene.instantiate() as Building
	placed.owner_player_id = 1
	match_instance.get_node("Buildings").add_child(placed)
	await process_frame
	_expect(placed.entity_id != 0, "a building added to a running match must register on entering the tree")
	_expect(
		not store.has_position(placed.entity_id),
		"sanity check: a building added after _place_on_map() has already run must have no store position yet"
	)

	var target := Vector3(12.5, 3.25, -7.75)
	placed.set_simulation_position(target)
	_expect(
		store.has_position(placed.entity_id),
		"set_simulation_position() must give the building a store position"
	)
	if store.has_position(placed.entity_id):
		_expect(
			store.position(placed.entity_id).is_equal_approx(target),
			"the store must hold exactly the position set_simulation_position() was handed"
		)
	_expect(
		placed.global_position.is_equal_approx(target),
		"the node must mirror the same position the store was given"
	)

	placed.queue_free()
	match_instance.queue_free()
	await process_frame


## The building-side copy of _test_store_outlives_a_direct_node_poke, and it
## pins why global-position-bypasses-store exists rather than merely that
## Building.set_simulation_position() works. A suite in which store and node
## always agree cannot tell an authoritative store from a store that copies
## the node; this forces the disagreement the checker rule forbids in
## scripts/ and shows the store keeps answering with its own last written
## value. Reading the store, not the node, is how a snapshot, a checksum or a
## replay would settle it.
func _test_building_store_outlives_a_direct_node_poke() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var building := match_instance.get_node("Buildings/ATConYard") as Building
	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return
	_expect(
		store.has_position(building.entity_id),
		"ATConYard must already have a store position from boot before this case pokes it"
	)
	if not store.has_position(building.entity_id):
		match_instance.queue_free()
		return

	var trusted_position: Vector3 = store.position(building.entity_id)
	var rogue_position := trusted_position + Vector3(999.0, 0.0, 999.0)
	# Bypasses set_simulation_position() on purpose -- this is exactly the
	# direct write the architecture rule forbids in scripts/, reproduced here
	# to prove what the store does when it happens anyway.
	building.global_position = rogue_position

	_expect(
		building.global_position.is_equal_approx(rogue_position),
		"the node itself must show the rogue write -- otherwise this case is not testing a real disagreement"
	)
	_expect(
		store.position(building.entity_id).is_equal_approx(trusted_position),
		"the store must keep its own last written value instead of silently following a direct node write"
	)
	_expect(
		not store.position(building.entity_id).is_equal_approx(building.global_position),
		"store and node must actually disagree here, and the store's answer -- not the node's -- must be trusted"
	)

	match_instance.queue_free()
	await process_frame


## The refusal path, stated through the node rather than the bare store the
## way tests/sim/entity_state_run.gd's _test_write_released_id_refused states
## it. Two things are being pinned that the bare-store case cannot see. First,
## SimEntityState.set_position() refuses a dead id instead of writing into
## whatever stale slot the array still holds for it, and refusing does not
## disturb any other id's slot -- the neighbour check is what would catch a
## refusal that resized or shifted the array on its way out. Second,
## Building.set_simulation_position() writes the node anyway, which is a
## deliberate choice with its own paragraph in that method's doc comment: the
## push_error is the signal, and a building that quietly failed to move would
## be a second bug stacked on the logged one.
##
## The id is killed through EntityNodeIndex.release_id() rather than
## request_despawn(): request_release() only queues the kill for the next
## tick's drain, which would make this case depend on tick timing to prove
## something that has nothing to do with ticks. release_id() is the same
## release_id() Building._exit_tree() already calls, applied one step early.
##
## This case pushes exactly one "write refused" error, deliberately. It is
## the only one this suite produces.
func _test_building_position_write_to_a_dead_id_is_refused() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var store = match_instance.entity_state()
	var index = match_instance.entity_index()
	_expect(store != null, "Match must expose a live SimEntityState")
	_expect(index != null, "Match must expose a live EntityNodeIndex")
	if store == null or index == null:
		match_instance.queue_free()
		return

	var neighbour := match_instance.get_node("Buildings/ATSmWindtrap") as Building
	_expect(
		store.has_position(neighbour.entity_id),
		"the neighbouring building must have a store position for the no-corruption check to mean anything"
	)
	if not store.has_position(neighbour.entity_id):
		match_instance.queue_free()
		return
	var neighbour_position: Vector3 = store.position(neighbour.entity_id)

	var doomed := ConYardScene.instantiate() as Building
	doomed.owner_player_id = 1
	match_instance.get_node("Buildings").add_child(doomed)
	await process_frame
	var doomed_id: int = doomed.entity_id
	_expect(doomed_id != 0, "the building must be registered before its id can be killed")

	var accepted := Vector3(20.0, 1.0, 20.0)
	doomed.set_simulation_position(accepted)
	_expect(
		store.has_position(doomed_id) and store.position(doomed_id).is_equal_approx(accepted),
		"positive control: while the id is alive the same call must land in the store"
	)

	index.release_id(doomed_id)
	_expect(
		not index.registry().is_alive(doomed_id),
		"sanity check: the released id must be dead before the refused write is attempted"
	)

	var refused := accepted + Vector3(500.0, 0.0, 500.0)
	doomed.set_simulation_position(refused)

	_expect(
		not store.has_position(doomed_id),
		"a write for a dead id must be refused, leaving nothing readable for that id"
	)
	_expect(
		doomed.global_position.is_equal_approx(refused),
		"the node must still move on a refused write, keeping the symptom loud rather than quiet"
	)
	_expect(
		store.position(neighbour.entity_id).is_equal_approx(neighbour_position),
		"a refused write must leave every other id's stored position exactly as it was"
	)

	doomed.queue_free()
	match_instance.queue_free()
	await process_frame


## Slice R2's positive case. Deliberately weak on its own -- it cannot tell an
## accessor that reads the store from one that returns `global_position`,
## because boot leaves the two in agreement. It is here for the reason the
## boot cases above are: it fails if the method is not wired to the store at
## all, for either kind, and it fails before the disagreement case below can
## report something more confusing.
func _test_simulation_position_answers_from_the_store() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return

	var unit := match_instance.get_node("Units/OrdosAPC") as Unit
	_expect(
		store.has_position(unit.entity_id),
		"OrdosAPC must already have a store position from boot"
	)
	if store.has_position(unit.entity_id):
		_expect(
			unit.simulation_position().is_equal_approx(store.position(unit.entity_id)),
			"Unit.simulation_position() must answer with the store's position"
		)

	var building := match_instance.get_node("Buildings/ATConYard") as Building
	_expect(
		store.has_position(building.entity_id),
		"ATConYard must already have a store position from boot"
	)
	if store.has_position(building.entity_id):
		_expect(
			building.simulation_position().is_equal_approx(store.position(building.entity_id)),
			"Building.simulation_position() must answer with the store's position"
		)

	match_instance.queue_free()
	await process_frame


## The case that carries the meaning, and the one the mutation "make
## simulation_position() return global_position unconditionally" must break.
## The poke is the same bypassing write _test_store_outlives_a_direct_node_poke
## and its building twin perform, but what is asserted afterwards is different:
## those two ask the *store* and prove it did not follow the node, while this
## one asks the *node* and proves it does not answer for itself. A test that
## only checked store and accessor agree would pass against an accessor that
## never touches the store at all.
func _test_simulation_position_outlives_a_direct_node_poke() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		match_instance.queue_free()
		return

	var unit := match_instance.get_node("Units/OrdosAPC") as Unit
	var building := match_instance.get_node("Buildings/ATConYard") as Building
	_expect(
		store.has_position(unit.entity_id) and store.has_position(building.entity_id),
		"both entities must already have a store position before this case pokes them"
	)
	if not (store.has_position(unit.entity_id) and store.has_position(building.entity_id)):
		match_instance.queue_free()
		return

	var trusted_unit_position: Vector3 = store.position(unit.entity_id)
	var trusted_building_position: Vector3 = store.position(building.entity_id)
	var unit_poke := trusted_unit_position + Vector3(777.0, 0.0, -777.0)
	var building_poke := trusted_building_position + Vector3(-555.0, 0.0, 555.0)
	# Bypasses set_simulation_position() on purpose, exactly as the C2 and R1
	# poke cases above do -- global-position-bypasses-store forbids this shape
	# in scripts/, and tests/ is deliberately outside the checker's zone.
	unit.global_position = unit_poke
	building.global_position = building_poke

	_expect(
		unit.global_position.is_equal_approx(unit_poke)
			and building.global_position.is_equal_approx(building_poke),
		"the nodes must show the rogue writes -- otherwise this case tests no real disagreement"
	)
	_expect(
		unit.simulation_position().is_equal_approx(trusted_unit_position),
		"Unit.simulation_position() must keep answering the store's value, not the poked node's"
	)
	_expect(
		not unit.simulation_position().is_equal_approx(unit.global_position),
		"Unit.simulation_position() must actually differ from global_position here -- an answer that "
			+ "agrees with the node is an answer that came from the node"
	)
	_expect(
		building.simulation_position().is_equal_approx(trusted_building_position),
		"Building.simulation_position() must keep answering the store's value, not the poked node's"
	)
	_expect(
		not building.simulation_position().is_equal_approx(building.global_position),
		"Building.simulation_position() must actually differ from global_position here, for the same "
			+ "reason the unit's must"
	)

	match_instance.queue_free()
	await process_frame


## The fallback, which the accessor's own doc comment names as its one danger
## and which is nonetheless required: most of tests/units/* and tests/combat/*
## build a Unit with no Match anywhere, entity_id stays 0 for its whole life,
## and there is no store to be authoritative over. Two things are pinned. The
## answer is the node's own position, and it keeps tracking the node when the
## node moves -- so a unit outside a match behaves exactly as it did before
## this method existed. And nothing reaches SimEntityState: with entity_id 0
## the accessor never calls position(), which would push an error for an id
## with no entry rather than return one. That second half is why the guard is
## `has_position()` and not merely a null check on the store.
func _test_simulation_position_falls_back_with_no_match() -> void:
	var unit := UnitScene.instantiate() as Unit
	unit.position = Vector3(11.0, 2.0, -4.0)
	get_root().add_child(unit)
	await process_frame

	_expect(
		unit.entity_id == 0,
		"sanity check: with no Match in the tree the unit must never have been given an entity id"
	)
	_expect(
		unit.simulation_position().is_equal_approx(unit.global_position),
		"with no store to answer from, simulation_position() must return the node's own position"
	)

	var moved := unit.global_position + Vector3(3.0, 0.0, 9.0)
	unit.global_position = moved
	_expect(
		unit.simulation_position().is_equal_approx(moved),
		"the fallback must keep tracking the node, so a unit outside a match behaves exactly as it "
			+ "did before this method existed"
	)

	unit.queue_free()
	await process_frame


## MatchSnapshot's restore used to write `entity.global_transform` and stop
## there, which left the store with no entry at all for a live entity: neither
## Unit._register_entity_id() nor Building's pushes a position, only an owner.
## The visible consequence was slice B4's interpolation silently skipping every
## restored entity, because it checks has_position() first; the structural one
## is that any migrated reader (slice R2 onward) would get Vector3.INF and a
## push_error for an entity standing in plain sight.
##
## Driven inside a real Match rather than in tests/match/snapshot_run.gd,
## deliberately: that suite's fixture (tests/fixtures/snapshot_fixture.tscn) is
## a bare Node3D with no Match anywhere in it, so MatchLookup finds nothing,
## entity_id stays 0 and the store is never involved -- the defect is invisible
## there by construction, which is exactly why it survived slice C2.
##
## The control is the node's own transform: it must land where it was saved
## whether or not the store hears about it, so asserting only that would pass
## against the defect. What distinguishes them is has_position() and the store
## agreeing with the node.
func _test_snapshot_restore_reaches_the_store() -> void:
	var snapshot = MatchSnapshotScript.new(SNAPSHOT_TEST_PATH)
	snapshot.erase()

	var source := MatchFixtureScene.instantiate()
	get_root().add_child(source)
	for _warmup in 5:
		await process_frame
	var saved_position: Vector3 = (source.get_node("Units/OrdosAPC") as Unit).global_position
	var save_result: Dictionary = snapshot.save(source.get_node("Buildings"), source.get_node("Units"))
	_expect(bool(save_result.get("ok", false)), "the snapshot must be written before it can be restored")
	source.queue_free()
	await process_frame

	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame
	# The fixture boots with its own OrdosAPC, so clear the Units root first:
	# restoring on top of it would leave two nodes contending for the name and
	# make "the restored one" ambiguous.
	for child in match_instance.get_node("Units").get_children():
		match_instance.get_node("Units").remove_child(child)
		child.queue_free()
	await process_frame

	var restore_result: Dictionary = snapshot.restore(
		match_instance.get_node("Buildings"), match_instance.get_node("Units")
	)
	_expect(bool(restore_result.get("ok", false)), "the snapshot must restore into the live match")
	await process_frame

	var restored := match_instance.get_node_or_null("Units/OrdosAPC") as Unit
	_expect(restored != null, "the saved OrdosAPC must exist after the restore")
	if restored == null:
		snapshot.erase()
		match_instance.queue_free()
		await process_frame
		return

	var store = match_instance.entity_state()
	_expect(store != null, "Match must expose a live SimEntityState")
	if store == null:
		snapshot.erase()
		match_instance.queue_free()
		await process_frame
		return

	# Control: true with the defect present as well as absent.
	_expect(
		restored.global_position.is_equal_approx(saved_position),
		"control: the restored node must stand where it was saved -- if this fails the case below "
			+ "proves nothing about the store"
	)
	_expect(restored.entity_id != 0, "the restored entity must have registered an id")
	_expect(
		store.has_position(restored.entity_id),
		"the store must hold a position for a restored entity -- writing global_transform alone "
			+ "leaves has_position() false for something standing in plain sight"
	)
	if store.has_position(restored.entity_id):
		_expect(
			store.position(restored.entity_id).is_equal_approx(restored.global_position),
			"the store's position for a restored entity must agree with the node it was mirrored from"
		)

	snapshot.erase()
	match_instance.queue_free()
	await process_frame
