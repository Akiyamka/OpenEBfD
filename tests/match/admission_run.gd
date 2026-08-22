extends SceneTree

## Slice C6b's own regression suite -- see docs/architecture/network-multiplayer.md,
## "Slice C6, decided 2026-08-22: deferred spawn, and the group that had to
## be split first." Structured on tests/match/despawn_run.gd exactly: C5's
## despawn queue is this queue's mirror at the other end of the tick (admit
## -> simulate -> retire, Match._advance_simulation_tick()'s own doc comment),
## and despawn_run.gd is the closest model for proving a deferred-queue
## guarantee by driving a real Match rather than trusting the suite staying
## green.
##
## The claim under test is "created during tick N, not simulated until tick
## N+1". The first case proves it directly against a real shot fired inside a
## real Match; the rest pin scripts/match/sim_admission_queue.gd's own
## semantics (mirroring tests/sim/entity_registry_run.gd's despawn-queue
## cases) and the one shared entry point every C6b call site routes through,
## MatchLookup.request_sim_entry() (scripts/match/match_lookup.gd).

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATRocketTurretScene := preload("res://assets/converted/buildings/ATRocketTurret/ATRocketTurret.scn")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const SimAdmissionQueueScript := preload("res://scripts/match/sim_admission_queue.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"a projectile a real building fires mid-tick is not admitted into \"sim_projectiles\" "
			+ "for the rest of the tick it was fired on, and starts traveling on the next",
		_test_projectile_admission_deferred_to_next_tick
	)
	await _run_case(
		"apply_pending_entries() joins every queued entry and clears the pending queue",
		_test_drains_every_queued_entry
	)
	await _run_case(
		"a second apply_pending_entries() with nothing requested since the last call returns 0",
		_test_second_drain_returns_zero
	)
	await _run_case(
		"a node freed between request_entry() and apply_pending_entries() is skipped, not an error",
		_test_freed_node_is_skipped
	)
	await _run_case(
		"a projectile built with no Match in the tree joins its group immediately",
		_test_no_match_fallback_joins_immediately
	)

	if _failures > 0:
		printerr("Admission tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Admission tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	# A runtime error aborts the case function where it stands, leaving
	# _failures untouched -- which would print PASS for a case that never
	# reached an assertion. See tests/match/despawn_run.gd's identical copy
	# of this guard.
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


## Fires a real shot from a real ATRocketTurret inside a real Match -- the
## identical setup tests/match/demo_boot_run.gd's
## _test_match_loop_drives_building_fire uses to prove Building.sim_tick()
## reaches the tick loop at all: same building (ATRocketTurretScene), same
## 8-world-unit offset behind ScoutA to keep the shot over the flat ground
## the rest of that suite already treats as flat, same weapon_fired-signal
## capture of the firing instant.
##
## ATRocketTurret, not HKGunTurret, is the probe deliberately, and for a
## sharper reason than demo_boot_run.gd's own (avoiding an instant hitscan
## with nothing to watch travel): HKGunTurret_B's speed is -1, which makes it
## is_hitscan(), and CombatProjectile.launch() resolves a hitscan bullet
## synchronously, inside launch() itself, via _resolve_hitscan() -- before
## this projectile has even been handed to the admission queue's pending
## list, let alone before any drain could run. Its position is therefore
## already settled at its impact point the instant it is created, regardless
## of admission timing, which would prove nothing about the guarantee this
## case exists to pin down. Rocket_B has positive speed and is not hitscan
## (checked directly, resources/combat/bullets/Rocket_B.tres), so its
## position genuinely depends on whether sim_tick() has run at all.
##
## The load-bearing half of this case is captured synchronously from inside
## the weapon_fired handler, which Building.sim_tick() calls from deep
## within Match._advance_simulation_tick()'s "sim_buildings" loop -- the same
## call stack that created the projectile. Checking group membership there
## needs no frame-timing assumption: apply_pending_entries() only ever runs
## as the first statement of _advance_simulation_tick(), and this tick's own
## call is still on the stack, so it provably has not run again yet. The
## awaited half afterward (waiting for admission, then for travel) relies on
## the same one-due-tick-per-awaited-frame assumption every other
## demo_boot_run.gd case in this style already relies on.
func _test_projectile_admission_deferred_to_next_tick() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var target := match_instance.get_node("Units/ScoutA") as Unit
	target.set_owner_player_id(2)
	target.stop_at_current_position()

	var building := ATRocketTurretScene.instantiate() as Building
	building.owner_player_id = 1
	building.position = target.global_position + Vector3(0.0, 0.0, -8.0)
	match_instance.add_child(building)
	await process_frame

	var fired_projectiles: Array = []
	var fired_in_group: Array[bool] = []
	var fired_positions: Array[Vector3] = []
	building.weapon_fired.connect(func(projectiles: Array, _fired_target: Variant, _weapon_index: int) -> void:
		for projectile in projectiles:
			fired_projectiles.append(projectile)
			fired_in_group.append(projectile.is_in_group(CombatProjectileScript.SIM_PROJECTILES_GROUP))
			fired_positions.append(projectile.global_position)
	)
	_expect(
		building.command_attack(target),
		"a real ATRocketTurret must accept a real enemy unit as an explicit target"
	)

	# Same 900-frame settle budget as demo_boot_run.gd's own
	# _test_match_loop_drives_building_fire, for the identical scenario.
	var frames := 0
	while fired_projectiles.is_empty() and frames < 900:
		await process_frame
		frames += 1
	_expect(
		not fired_projectiles.is_empty(),
		"a real building must fire from the match loop alone within the settle budget -- if this "
			+ "times out, Building.sim_tick() never ran"
	)
	if fired_projectiles.is_empty():
		building.free()
		match_instance.queue_free()
		await process_frame
		return

	var probe: Object = fired_projectiles[0]
	var launch_position: Vector3 = fired_positions[0]
	_expect(
		not fired_in_group[0],
		"a projectile born mid-tick, from inside Building.sim_tick(), must not already be a member "
			+ "of \"sim_projectiles\" at the instant it is created -- admission is deferred to the "
			+ "next tick's drain, not granted synchronously the way add_to_group() used to grant it. "
			+ "This is the whole guarantee C6b adds; everything below is corroboration, not the proof."
	)

	# The positive control starts here: wait for the queue to actually admit
	# it, then for it to actually move. Without this half, the assertion
	# above would also pass for a projectile that is queued and then never
	# admitted at all -- see SimAdmissionQueue's own doc comment for the one
	# call site (CombatTurret.try_fire_at()'s launch()-fails branch) where a
	# queued entry is legitimately never admitted, which is exactly the
	# failure mode this positive control is here to rule out for the
	# ordinary, successful case.
	var join_frames := 0
	while is_instance_valid(probe) \
	and not probe.is_in_group(CombatProjectileScript.SIM_PROJECTILES_GROUP) \
	and join_frames < 60:
		await process_frame
		join_frames += 1
	_expect(
		is_instance_valid(probe) and probe.is_in_group(CombatProjectileScript.SIM_PROJECTILES_GROUP),
		"the projectile must join \"sim_projectiles\" within a handful of ticks after being fired -- "
			+ "if this times out, apply_pending_entries() is never draining it at all"
	)
	_expect(
		is_instance_valid(probe) and probe.state == CombatProjectileScript.State.FLYING,
		"the probe must still be flying right after joining, or the position comparison below would "
			+ "not isolate admission timing from an unrelated impact"
	)
	if is_instance_valid(probe) and probe.state == CombatProjectileScript.State.FLYING:
		_expect(
			probe.global_position != launch_position,
			"a real, admitted Rocket_B shot must actually have traveled from its launch position -- "
				+ "the positive control for the \"not yet admitted\" assertion above, without which "
				+ "that assertion would also pass for a projectile that never moves at all"
		)

	for projectile in fired_projectiles:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	building.free()
	match_instance.queue_free()
	await process_frame


## The admission-side counterpart of
## tests/sim/entity_registry_run.gd's _test_take_pending_releases_request_order
## -- but not its order assertion. That test can check order directly because
## take_pending_releases() *returns* a PackedInt32Array, an observable
## sequence. apply_pending_entries() has no such return: its only effect per
## entry is add_to_group(), which lands in Godot group membership -- a set,
## not a sequence -- so there is nothing here to assert order against without
## pinning get_nodes_in_group()'s own iteration order, which is Godot's to
## decide, not this queue's, and is already recorded as a separate, known gap
## in Match._advance_simulation_tick()'s own doc comment (multi-shot volley
## resolution order, owned by phase 4). See SimAdmissionQueue's own doc
## comments (scripts/match/sim_admission_queue.gd) for the same distinction
## stated once, generally.
##
## What is actually observable and worth asserting instead: three separately
## requested, still-live, in-tree nodes each join the specific group they
## asked for on one drain, the returned count matches, and the pending queue
## is empty afterward. "A second drain with nothing freshly requested returns
## 0" is its own dedicated case below (_test_second_drain_returns_zero),
## mirroring entity_registry_run.gd's own split between
## _test_take_pending_releases_request_order and
## _test_take_pending_releases_clears_queue.
func _test_drains_every_queued_entry() -> void:
	var queue := SimAdmissionQueueScript.new()
	var node_a := Node.new()
	var node_b := Node.new()
	var node_c := Node.new()
	root.add_child(node_a)
	root.add_child(node_b)
	root.add_child(node_c)
	var group_a := &"admission_run_drain_group_a"
	var group_b := &"admission_run_drain_group_b"
	var group_c := &"admission_run_drain_group_c"

	queue.request_entry(node_c, group_c)
	queue.request_entry(node_a, group_a)
	queue.request_entry(node_b, group_b)
	_expect(queue.pending_entry_count() == 3, "three requests must be pending before the drain")

	var joined := queue.apply_pending_entries()
	_expect(joined == 3, "all three live, in-tree nodes must join on this drain")
	_expect(queue.pending_entry_count() == 0, "apply_pending_entries() must clear the pending queue")
	_expect(node_a.is_in_group(group_a), "node_a must have joined the specific group it requested")
	_expect(node_b.is_in_group(group_b), "node_b must have joined the specific group it requested")
	_expect(node_c.is_in_group(group_c), "node_c must have joined the specific group it requested")
	# _test_second_drain_returns_zero below is the dedicated case for "a
	# second drain with nothing freshly requested returns 0" -- not repeated
	# here.

	for node in [node_a, node_b, node_c]:
		node.queue_free()
	await process_frame


## Mirrors tests/sim/entity_registry_run.gd's
## _test_take_pending_releases_clears_queue.
func _test_second_drain_returns_zero() -> void:
	var queue := SimAdmissionQueueScript.new()
	var node := Node.new()
	root.add_child(node)

	queue.request_entry(node, &"admission_run_second_drain_group")
	queue.apply_pending_entries()
	_expect(
		queue.apply_pending_entries() == 0,
		"a second apply_pending_entries() with nothing requested since the last call must return 0, "
			+ "not the same node again"
	)

	node.queue_free()
	await process_frame


## The queue-side half of CombatTurret.try_fire_at()'s launch()-fails branch
## (see SimAdmissionQueue.apply_pending_entries()'s own doc comment): a node
## that requested entry and was freed before the drain must not be treated
## as an error, and must not end up in the group it asked for. free(), not
## queue_free(): the point is a node that is already gone -- is_instance_valid()
## already false -- by the time the drain runs, which queue_free()'s
## end-of-frame deferral would not reliably reproduce without an extra await.
func _test_freed_node_is_skipped() -> void:
	var queue := SimAdmissionQueueScript.new()
	var node := Node.new()
	root.add_child(node)
	var group := &"admission_run_freed_group"

	queue.request_entry(node, group)
	node.free()

	var joined := queue.apply_pending_entries()
	_expect(joined == 0, "a node freed between request_entry() and the drain must not count as joined")
	_expect(
		get_nodes_in_group(group).is_empty(),
		"a freed node must not end up in the group it requested -- apply_pending_entries() must "
			+ "skip it silently, not error"
	)


## The fallback every C6b call site relies on to keep working with no Match
## in the tree at all -- see MatchLookup.request_sim_entry()'s own doc
## comment, which gives this the identical reasoning
## Unit.request_despawn()'s queue_free() fallback already carries: most
## combat suites in this repo build a CombatProjectile directly, with no
## Match anywhere in the tree (see tests/combat/*), and nothing would ever
## call apply_pending_entries() to drain a queue for them.
##
## How much this actually guards today was checked, not assumed, and the
## obvious stronger claim ("without the fallback every no-Match combat suite
## would silently stop being simulated") turned out to be false: nothing
## outside this file walks "sim_projectiles", "sim_linger_effects" or
## "sim_spice_mounds" at all. tests/combat/support/sim_tick_pump.gd calls
## entity.sim_tick() directly on the single entity it is handed rather than
## walking any group, and with the fallback removed
## tests/combat/projectile_flight_run.gd still passed its 60 assertions. So
## this case is currently the fallback's only binding, and the message below
## claims only that.
##
## Neither the case nor the fallback is therefore droppable. The fallback is
## still the correct behaviour -- a no-Match node's group membership works
## exactly as it did before C6b -- and the first fixture that does drive a
## group walk with no Match in the tree needs that guard already standing,
## not rediscovered by a suite that times out instead of failing.
func _test_no_match_fallback_joins_immediately() -> void:
	var projectile := CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.is_in_group(CombatProjectileScript.SIM_PROJECTILES_GROUP),
		"a projectile built with no Match anywhere in the tree must join \"sim_projectiles\" "
			+ "immediately from its own _ready() -- MatchLookup.request_sim_entry()'s no-queue "
			+ "fallback -- which is what keeps such a node's group membership behaving exactly as "
			+ "it did before C6b. This case is currently that fallback's only binding: the existing "
			+ "no-Match suites drive sim_tick() directly rather than through a group walk (see this "
			+ "case's doc comment)"
	)
	projectile.queue_free()
	await process_frame
