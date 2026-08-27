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
##
## Slice C6c's cases live here too rather than in a suite of their own: C6c
## is admission for units and buildings, which is exactly this file's
## subject, and its navigation half is a consequence of that admission rather
## than a separate topic. Those cases carry the same claim to the two kinds
## the tick walks that also have a view-side group -- a unit and a building
## created mid-tick -- and then to the system that has to agree with the tick
## about who is simulated: UnitNavigationSystem, which since C6c registers an
## agent from a tick-domain drain instead of a frame-domain call_deferred(),
## and refuses to register a node the tick has not admitted at all.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATRocketTurretScene := preload("res://assets/converted/buildings/ATRocketTurret/ATRocketTurret.scn")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const SimAdmissionQueueScript := preload("res://scripts/match/sim_admission_queue.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")


## Stands in for ReplayPlayer at ReplayPlayer's own, named position in
## Match._advance_simulation_tick(): play_tick() runs after
## apply_pending_entries() (the admission drain, the tick's first statement)
## and before both the command loop and UnitNavigationSystem.sim_tick(). That
## is the only property the C6c cases below need from it, and it is exactly
## where a building placed by a real command is created -- one statement
## later, inside the command loop the stub sits directly above.
##
## Why a stand-in rather than the real path: reaching that point in the tick
## through a genuine SimPlaceBuildingCommand needs a ready build order, the
## credits for it, and a legal placement cell, none of which this suite is
## about. Match's own _replay_player field is used nowhere else in match.gd
## except its construction, so swapping it costs nothing else in the tick.
##
## The hook fires once and clears itself: the cases below advance two ticks
## and only the first may create anything.
class TickHookReplayPlayer extends ReplayPlayer:
	var hook := Callable()

	func play_tick(_command_bus: SimCommandBus, _tick: int) -> void:
		if not hook.is_valid():
			return
		var once := hook
		hook = Callable()
		once.call()


## Duck-typed stand-in for a SpiceMound, joined to "sim_spice_mounds" so
## Match._advance_simulation_tick()'s walk of that group calls sim_tick() on
## it. That walk is the *last* group loop of the tick -- only
## apply_pending_releases() follows it -- so whatever this probe samples is
## the state of the tick at its very end. "Not admitted for the remainder of
## the tick that created it" is a claim about that moment, and this is the
## cheapest honest way to stand there.
class TickEndProbe extends Node:
	var on_tick := Callable()

	func sim_tick() -> void:
		if on_tick.is_valid():
			on_tick.call()


## A Node3D in no group at all, for the gate case: NavAgentRegistry.
## register_unit() must refuse it. Deliberately not a Unit -- a Unit would
## join "sim_units" through the admission queue and stop being the thing
## under test.
##
## The two no-op tick methods are not decoration: the case's positive control
## puts this node into "sim_units" by hand, and from that moment
## Match._advance_simulation_tick()'s two walks of that group call both of
## them on it. simulation_position() is there for the same reason and was
## added by slice R3: once this node is in "sim_units" the navigation system
## registers it as a ground agent, and GroundNavigation.tick() asks every
## agent's node where it is through that duck-typed accessor rather than
## reading global_position. Without it the case still passed while printing a
## "Nonexistent function" script error every tick.
class UnregisteredProbeUnit extends Node3D:
	func sim_tick() -> void:
		pass

	func sim_tick_combat() -> void:
		pass

	func simulation_position() -> Vector3:
		return global_position


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
	await _run_case(
		"a unit created mid-tick inside a real Match is not in \"sim_units\" for the rest of "
			+ "that tick, and is on the next",
		_test_unit_admission_deferred_to_next_tick
	)
	await _run_case(
		"a building created mid-tick inside a real Match is not in \"sim_buildings\" for the "
			+ "rest of that tick, and is on the next",
		_test_building_admission_deferred_to_next_tick
	)
	await _run_case(
		"navigation holds no agent for a unit the tick has not admitted, and holds one once "
			+ "the drain has run",
		_test_navigation_agent_waits_for_admission
	)
	await _run_case(
		"NavAgentRegistry.register_unit() refuses a node outside \"sim_units\" and creates no agent",
		_test_registry_refuses_a_node_outside_sim_units
	)
	await _run_case(
		"a building whose admission is still pending survives navigation's drain and gets its "
			+ "blocker refresh on the tick that admits it",
		_test_pending_building_blocker_refresh_survives_a_drain
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


## Installs the two tick-position stand-ins declared at the top of this file
## into `match_instance` and returns them as [spawner, probe]: a
## TickHookReplayPlayer standing where ReplayPlayer stands (after the
## admission drain, before navigation and the command loop) and a
## TickEndProbe standing in the tick's last group loop. Between them they
## bracket everything Match._advance_simulation_tick() does, which is what
## "for the remainder of the tick that created it" needs in order to mean
## anything.
func _install_tick_hooks(match_instance: Node) -> Array:
	var spawner := TickHookReplayPlayer.new()
	match_instance.set("_replay_player", spawner)
	var probe := TickEndProbe.new()
	match_instance.add_child(probe)
	# Joined directly rather than through request_sim_entry(): this probe is
	# scaffolding, not a subject, and it has to be sampling from the very
	# first tick these cases drive.
	probe.add_to_group(&"sim_spice_mounds")
	return [spawner, probe]


## Slice C6c's load-bearing case for units, the direct counterpart of this
## suite's opening projectile case. The unit is created from inside a tick,
## between the admission drain and every one of that tick's own systems, so
## the whole rest of the tick runs after it exists -- including both passes
## over "sim_units". If admission were still the synchronous add_to_group()
## Unit._ready() used to make, this unit would be simulated on the tick that
## created it.
##
## Two positive controls, because the load-bearing assertion is a negative
## and a negative passes for free if the unit never really came into being:
## entity_id proves _ready() ran to completion inside a live Match (identity
## is not deferred, only the tick's iteration source), and the "units"
## membership proves the shared, view-side group was joined on the birth
## frame exactly as before. The reference unit sampled alongside is the third
## control, on the probe itself: ScoutA must read as a "sim_units" member on
## both ticks, or the probe is not running and every sample below is
## vacuously false.
func _test_unit_admission_deferred_to_next_tick() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var reference := match_instance.get_node("Units/ScoutA") as Unit
	var hooks := _install_tick_hooks(match_instance)
	var spawner: TickHookReplayPlayer = hooks[0]
	var probe: TickEndProbe = hooks[1]

	var spawned: Array[Unit] = []
	var sim_group_at_birth: Array[bool] = []
	var view_group_at_birth: Array[bool] = []
	var entity_id_at_birth: Array[int] = []
	spawner.hook = func() -> void:
		var unit := UnitScene.instantiate() as Unit
		unit.owner_player_id = 1
		unit.position = reference.global_position + Vector3(6.0, 0.0, 6.0)
		match_instance.get_node("Units").add_child(unit)
		spawned.append(unit)
		sim_group_at_birth.append(unit.is_in_group(Unit.SIM_UNITS_GROUP))
		view_group_at_birth.append(unit.is_in_group("units"))
		entity_id_at_birth.append(unit.entity_id)

	var samples: Array[bool] = []
	var reference_samples: Array[bool] = []
	probe.on_tick = func() -> void:
		samples.append(
			not spawned.is_empty() and spawned[0].is_in_group(Unit.SIM_UNITS_GROUP)
		)
		reference_samples.append(reference.is_in_group(Unit.SIM_UNITS_GROUP))

	# No await between these two: an awaited frame drives ticks of its own
	# (Match._process -> FrameTickDriver), and "the next tick" has to mean the
	# next one, not the next few.
	match_instance.call("_advance_simulation_tick")
	match_instance.call("_advance_simulation_tick")

	_expect(spawned.size() == 1, "the stand-in replay player must have created exactly one unit")
	_expect(samples.size() == 2, "the tick-end probe must have sampled exactly the two ticks driven above")
	if spawned.size() != 1 or samples.size() != 2:
		match_instance.queue_free()
		await process_frame
		return

	_expect(
		entity_id_at_birth[0] != 0,
		"positive control: the unit must already hold an entity id at the instant it is created -- "
			+ "identity is not what C6c defers, only the tick's iteration source"
	)
	_expect(
		view_group_at_birth[0],
		"positive control: the unit must be in the shared \"units\" group on its birth frame -- "
			+ "deferring that group too would leave a freshly spawned unit unselectable and "
			+ "invisible to the UI, which is the view regression C6c refuses to buy"
	)
	_expect(
		not sim_group_at_birth[0],
		"a unit created mid-tick must not already be in \"sim_units\" at the instant it is created: "
			+ "Unit._ready() requests admission, it does not grant it"
	)
	_expect(
		not samples[0],
		"the unit must still be outside \"sim_units\" at the tick's last group loop -- the whole "
			+ "remainder of the tick that created it ran without it being simulated"
	)
	_expect(
		samples[1],
		"the unit must be in \"sim_units\" on the very next tick, whose apply_pending_entries() "
			+ "admits it -- without this the case above would also pass for a unit never admitted at all"
	)
	_expect(
		reference_samples.size() == 2 and reference_samples[0] and reference_samples[1],
		"positive control: a unit that was already in the match must read as a \"sim_units\" member "
			+ "on both ticks, or the probe is not running and every sample above is vacuous"
	)

	match_instance.queue_free()
	await process_frame


## The building half of the case above, same shape and same controls.
## Buildings matter separately rather than by analogy: Building._ready()
## joins the shared "buildings" group with an add_to_group() call of its own
## (units inherit theirs from 99 .tscn files), so the two halves of the split
## sit next to each other there and a single wrong edit collapses both.
func _test_building_admission_deferred_to_next_tick() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var reference := match_instance.get_node("Buildings/ATConYard") as Building
	var anchor := match_instance.get_node("Units/ScoutA") as Unit
	var hooks := _install_tick_hooks(match_instance)
	var spawner: TickHookReplayPlayer = hooks[0]
	var probe: TickEndProbe = hooks[1]

	var spawned: Array[Building] = []
	var sim_group_at_birth: Array[bool] = []
	var view_group_at_birth: Array[bool] = []
	var entity_id_at_birth: Array[int] = []
	spawner.hook = func() -> void:
		var building := ATRocketTurretScene.instantiate() as Building
		building.owner_player_id = 1
		building.position = anchor.global_position + Vector3(0.0, 0.0, -12.0)
		match_instance.get_node("Buildings").add_child(building)
		spawned.append(building)
		sim_group_at_birth.append(building.is_in_group(Building.SIM_BUILDINGS_GROUP))
		view_group_at_birth.append(building.is_in_group("buildings"))
		entity_id_at_birth.append(building.entity_id)

	var samples: Array[bool] = []
	var reference_samples: Array[bool] = []
	probe.on_tick = func() -> void:
		samples.append(
			not spawned.is_empty() and spawned[0].is_in_group(Building.SIM_BUILDINGS_GROUP)
		)
		reference_samples.append(reference.is_in_group(Building.SIM_BUILDINGS_GROUP))

	match_instance.call("_advance_simulation_tick")
	match_instance.call("_advance_simulation_tick")

	_expect(spawned.size() == 1, "the stand-in replay player must have created exactly one building")
	_expect(samples.size() == 2, "the tick-end probe must have sampled exactly the two ticks driven above")
	if spawned.size() != 1 or samples.size() != 2:
		match_instance.queue_free()
		await process_frame
		return

	_expect(
		entity_id_at_birth[0] != 0,
		"positive control: the building must already hold an entity id at the instant it is created"
	)
	_expect(
		view_group_at_birth[0],
		"positive control: the building must be in the shared \"buildings\" group on its birth "
			+ "frame -- placement, selection and the side panel all read that group"
	)
	_expect(
		not sim_group_at_birth[0],
		"a building created mid-tick must not already be in \"sim_buildings\" at the instant it is created"
	)
	_expect(
		not samples[0],
		"the building must still be outside \"sim_buildings\" at the tick's last group loop"
	)
	_expect(
		samples[1],
		"the building must be in \"sim_buildings\" on the very next tick, whose "
			+ "apply_pending_entries() admits it"
	)
	_expect(
		reference_samples.size() == 2 and reference_samples[0] and reference_samples[1],
		"positive control: the fixture's own ATConYard must read as a \"sim_buildings\" member on "
			+ "both ticks, or the probe is not running"
	)

	match_instance.queue_free()
	await process_frame


## The other half of C6c, and the reason it could not be split off into its
## own slice: deferring a unit's admission while UnitNavigationSystem still
## picked it up off "units" at the end of the engine frame would leave
## navigation driving a unit the tick does not simulate.
##
## The negative here is the interesting one -- navigation must hold no agent
## for a unit whose admission is still pending -- and it needs both controls
## to mean anything: the reference unit must hold an agent throughout (the
## navigation system is alive and holding agents at all), and the spawned
## unit must hold one on the admitting tick (the pending list really does
## register it, rather than dropping it on the floor).
func _test_navigation_agent_waits_for_admission() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var reference := match_instance.get_node("Units/ScoutA") as Unit
	var navigation: UnitNavigationSystem = match_instance.get_node("UnitNavigationSystem")
	var hooks := _install_tick_hooks(match_instance)
	var spawner: TickHookReplayPlayer = hooks[0]
	var probe: TickEndProbe = hooks[1]

	var spawned: Array[Unit] = []
	spawner.hook = func() -> void:
		var unit := UnitScene.instantiate() as Unit
		unit.owner_player_id = 1
		unit.position = reference.global_position + Vector3(6.0, 0.0, 6.0)
		match_instance.get_node("Units").add_child(unit)
		spawned.append(unit)

	var agent_samples: Array[bool] = []
	var reference_samples: Array[bool] = []
	probe.on_tick = func() -> void:
		var has_agent: bool = not spawned.is_empty() \
			and navigation._agents.has(spawned[0].get_instance_id())
		agent_samples.append(has_agent)
		var reference_has_agent: bool = navigation._agents.has(reference.get_instance_id())
		reference_samples.append(reference_has_agent)

	match_instance.call("_advance_simulation_tick")
	match_instance.call("_advance_simulation_tick")

	_expect(agent_samples.size() == 2, "the tick-end probe must have sampled exactly the two ticks driven above")
	if agent_samples.size() != 2:
		match_instance.queue_free()
		await process_frame
		return

	_expect(
		reference_samples[0] and reference_samples[1],
		"positive control: a unit the match started with must hold a navigation agent on both "
			+ "ticks -- if it does not, the negative below proves nothing about admission"
	)
	_expect(
		not agent_samples[0],
		"navigation must hold no agent for a unit the tick has not admitted: _on_tree_node_added() "
			+ "only queues it, and the drain at the top of sim_tick() refuses to register a node "
			+ "outside \"sim_units\""
	)
	_expect(
		agent_samples[1],
		"navigation must hold an agent for that unit on the tick that admits it -- the pending "
			+ "entry is re-tried, not dropped, which is what stops the negative above from passing "
			+ "for a unit navigation simply forgot"
	)

	match_instance.queue_free()
	await process_frame


## The gate itself, in isolation from any tick: NavAgentRegistry.register_unit()
## (scripts/units/navigation/shared/nav_agent_registry.gd) refuses a node
## outside "sim_units" the same way it already refuses a unit whose transform
## a transport anchor owns. This is what makes "navigation never drives a unit
## the tick does not simulate" structural rather than a convention every
## caller has to remember -- command_move(), command_dock(),
## assign_attack_arcs() and resume_unit() all call register_unit()
## unconditionally and obey it without knowing it exists.
##
## Driven through the navigation system a real Match owns, because the
## registry needs a live grid to derive a movement profile from and the
## fixture already has one. The same node is registered twice, before and
## after joining the group: the second call is the positive control, without
## which the first would also pass for a node the registry rejects for some
## unrelated reason.
func _test_registry_refuses_a_node_outside_sim_units() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var navigation: UnitNavigationSystem = match_instance.get_node("UnitNavigationSystem")
	var probe := UnregisteredProbeUnit.new()
	match_instance.get_node("Units").add_child(probe)
	probe.global_position = (match_instance.get_node("Units/ScoutA") as Unit).global_position \
		+ Vector3(10.0, 0.0, 10.0)

	_expect(
		not probe.is_in_group(Unit.SIM_UNITS_GROUP),
		"the probe must start outside \"sim_units\", or this case tests nothing"
	)
	_expect(
		navigation.register_unit(probe) == 0,
		"register_unit() must return 0 for a node the tick does not simulate"
	)
	_expect(
		not navigation._agents.has(probe.get_instance_id()),
		"a refused registration must leave no agent behind -- returning 0 while still building the "
			+ "agent dictionary entry would be the same defect with a politer return value"
	)

	probe.add_to_group(Unit.SIM_UNITS_GROUP)
	var agent_id := navigation.register_unit(probe)
	_expect(
		agent_id != 0,
		"positive control: the identical node must register once it is in \"sim_units\" -- without "
			+ "this the refusal above could be any other rejection in register_unit()"
	)
	_expect(
		navigation._agents.has(probe.get_instance_id()),
		"positive control: the accepted registration must actually create an agent"
	)

	match_instance.queue_free()
	await process_frame


## The case that proves UnitNavigationSystem's pending list *waits* rather
## than dropping what it cannot register yet, which is the one rule in C6c
## that is required rather than defensive.
##
## The ordering it reproduces is the one a command-placed building really has:
## created after the tick's admission drain and before
## UnitNavigationSystem.sim_tick(), so at the moment navigation drains, the
## building is in "buildings" (its _ready() joined that immediately) but not
## yet in "sim_buildings" (the admission queue admits it at the start of the
## *next* tick). A drain that discarded what it could not register would leave
## the building's cells open until the periodic BLOCKER_REFRESH_SECONDS sweep
## happened to come round -- a delay measured in seconds, and in frames rather
## than ticks.
##
## That periodic sweep is deliberately parked out of the way below: without
## that, a sweep landing on the admitting tick would block the cells for a
## reason that has nothing to do with the drain, and the case would pass with
## the pending list removed entirely.
##
## The controls: the fixture's own ATConYard must read as blocked on both
## ticks (the blocked-cell probe works and the blocker set is populated at
## all), and the new building's own cells must read as *unblocked* on the
## first tick and blocked on the second -- each rules out the other's
## degenerate answer.
func _test_pending_building_blocker_refresh_survives_a_drain() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var navigation: UnitNavigationSystem = match_instance.get_node("UnitNavigationSystem")
	var anchor := match_instance.get_node("Units/ScoutA") as Unit
	var reference := match_instance.get_node("Buildings/ATConYard") as Building
	var reference_cells := _body_cells(reference, navigation)
	# Twelve ticks of headroom at MatchClock's 25 Hz against
	# BLOCKER_REFRESH_SECONDS' 0.5 s, for the two ticks driven below.
	navigation._blocker_refresh_remaining = UnitNavigationSystem.BLOCKER_REFRESH_SECONDS

	var hooks := _install_tick_hooks(match_instance)
	var spawner: TickHookReplayPlayer = hooks[0]
	var probe: TickEndProbe = hooks[1]

	var spawned: Array[Building] = []
	var spawned_cells: Array[Vector2i] = []
	spawner.hook = func() -> void:
		var building := ATRocketTurretScene.instantiate() as Building
		building.owner_player_id = 1
		building.position = anchor.global_position + Vector3(0.0, 0.0, -12.0)
		match_instance.get_node("Buildings").add_child(building)
		spawned.append(building)
		spawned_cells.append_array(_body_cells(building, navigation))

	var blocked_samples: Array[bool] = []
	var pending_samples: Array[int] = []
	var reference_samples: Array[bool] = []
	probe.on_tick = func() -> void:
		blocked_samples.append(_any_blocked(navigation, spawned_cells))
		pending_samples.append(navigation._pending_building_entries.size())
		reference_samples.append(_any_blocked(navigation, reference_cells))

	match_instance.call("_advance_simulation_tick")
	match_instance.call("_advance_simulation_tick")

	_expect(spawned.size() == 1, "the stand-in replay player must have created exactly one building")
	_expect(blocked_samples.size() == 2, "the tick-end probe must have sampled exactly the two ticks driven above")
	_expect(not reference_cells.is_empty(), "ATConYard must contribute at least one solid \"b\" cell to sample")
	_expect(not spawned_cells.is_empty(), "the placed ATRocketTurret must contribute at least one solid \"b\" cell")
	if spawned.size() != 1 or blocked_samples.size() != 2 \
	or reference_cells.is_empty() or spawned_cells.is_empty():
		match_instance.queue_free()
		await process_frame
		return

	_expect(
		reference_samples[0] and reference_samples[1],
		"positive control: a building the match started with must keep its cells blocked across "
			+ "both ticks, or the blocked-cell probe is reading nothing"
	)
	_expect(
		not blocked_samples[0],
		"the new building's cells must still be open at the end of the tick that created it: "
			+ "NavBlockerTracker rebuilds from \"sim_buildings\", which does not list it yet"
	)
	_expect(
		pending_samples[0] == 1,
		"navigation's pending list must still be holding that building after a drain that could "
			+ "not register it -- this is the \"stays queued\" rule, and the only assertion in this "
			+ "suite that fails if the drain discards what it cannot yet admit"
	)
	_expect(
		blocked_samples[1],
		"the building's cells must be blocked on the tick that admits it, from the drain's own "
			+ "refresh rather than from the periodic sweep parked out of range above"
	)
	_expect(
		pending_samples[1] == 0,
		"and the pending entry must be gone once it has been handled"
	)

	match_instance.queue_free()
	await process_frame


## The solid ("b") navigation cells `building` occupies, computed exactly the
## way NavBlockerTracker.refresh_building_blockers() computes them so the
## comparison below is against the same cells that code would block.
func _body_cells(building: Building, navigation: UnitNavigationSystem) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var config := building.building_definition
	if config == null:
		return cells
	var rows: Array = config.occupy_rows
	var footprint: Dictionary = BuildingFootprintScript.nav_cells_by_marker(
		building, rows, navigation.runtime_map.grid, UnitNavigationSystem.OCCUPY_CELL_SPAN
	)
	for cell in footprint:
		if String(footprint[cell]).to_lower() == "b":
			cells.append(cell)
	return cells


func _any_blocked(navigation: UnitNavigationSystem, cells: Array[Vector2i]) -> bool:
	for cell in cells:
		if navigation.runtime_map.is_blocked(cell):
			return true
	return false
