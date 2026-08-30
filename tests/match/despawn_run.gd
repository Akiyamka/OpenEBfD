extends SceneTree

## Slice C5's own regression suite -- see docs/architecture/network-multiplayer.md,
## "Slice C5, decided 2026-08-21: deferred despawn, and the defect that changed
## its shape." Deliberately not folded into tests/match/entity_state_run.gd,
## whose own doc comment scopes it to hot state (position/health/shields/
## owner_player_id) wiring, not despawn.
##
## The defect this pins down: Building.sim_tick() used to check nothing on
## death, so a building killed mid-frame kept ticking its turret's reload
## countdown -- and its refinery dock cooldown, and AuthoredFireController's
## shot committal -- for every remaining simulation tick of that same engine
## frame. FrameTickDriver.MAX_TICKS_PER_FRAME is 5, so up to five ticks can
## run with no engine frame boundary between them; a real match reaches that
## condition under ordinary frame-time variance, not just under test. Driving
## Match.advance_ticks(1) directly, twice, with no await between, reproduces
## exactly that condition without waiting on real frame timing or depending
## on the test runner's own frame pacing.
##
## The second case pins a defect this suite's own review round found rather
## than shipped with the original slice: Unit.prepare_model_for_corpse() used
## to set _simulation_halted itself, which made the request_despawn() call
## right after it (on the same, ordinary corpse-branch death every unit with
## a matched death clip takes) a silent no-op -- see request_despawn()'s
## idempotence guard. That leaked the node and its id, inside a real Match,
## specifically -- see this case's own doc comment for why the existing
## no-Match suites' is_queued_for_deletion() assertions could not have named
## it directly.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const HKGunTurretScene := preload("res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn")
const UnitScene := preload("res://scenes/units/unit.tscn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"a building killed mid-frame stops ticking its turret's reload countdown on the "
			+ "very next tick, with no engine frame in between",
		_test_dead_building_stops_ticking_same_frame
	)
	await _run_case(
		"a unit killed on the corpse branch inside a real Match halts immediately and is "
			+ "actually freed once the tick's drain runs",
		_test_dead_unit_corpse_branch_halts_and_drains
	)

	if _failures > 0:
		printerr("Despawn tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Despawn tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	# A runtime error aborts the case function where it stands, leaving
	# _failures untouched -- which would print PASS for a case that never
	# reached an assertion. See tests/match/entity_state_run.gd's identical
	# copy of this guard for why this suite cannot simply extend
	# tests/support/suite.gd instead (its cases await).
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


func _test_dead_building_stops_ticking_same_frame() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 3:
		await process_frame

	# The fixture's own buildings (ATConYard, ATSmWindtrap) are not combat
	# buildings and carry no CombatTurret to observe -- HKGunTurret is the
	# same scene tests/combat/defensive_building_run.gd already uses for
	# exactly that reason.
	var building := HKGunTurretScene.instantiate() as Building
	building.owner_player_id = 1
	match_instance.get_node("Buildings").add_child(building)
	# One frame so _ready() runs: add_to_group("buildings") and turret
	# construction both happen there, and Match's group loop below only ever
	# sees a building once it has actually joined "buildings".
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

	turret.reload_ticks_remaining = 5
	match_instance.advance_ticks(1)
	# The canary. Without this, a turret that never ticked at all -- e.g. one
	# this suite failed to wire into the "buildings" group at all -- would
	# also leave reload_ticks_remaining unchanged after death below, and the
	# real assertion at the bottom of this case would pass for the wrong
	# reason: not because request_despawn() halted it, but because nothing
	# was ever ticking it in the first place.
	_expect(
		turret.reload_ticks_remaining == 4,
		"sanity check: a live building's turret must decrement reload_ticks_remaining on an ordinary tick"
	)

	# The real death path, not a direct request_despawn() call: take_damage()
	# routes through BuildingDeathSequence exactly like a killed building in a
	# real match, so this also proves the call-site wiring from Step 3, not
	# just Building.sim_tick()'s own guard.
	building.take_damage(building.max_health + building.max_shields + 10.0, &"")
	_expect(
		building.is_simulation_halted(),
		"a lethal hit must halt the building's simulation immediately, in the same call that dealt it"
	)

	# No process_frame between these two ticks -- and so no engine frame, and
	# no apply_pending_releases() drain -- between them: this is exactly the
	# mid-frame condition FrameTickDriver.MAX_TICKS_PER_FRAME's five-tick
	# allowance makes possible, reproduced directly instead of waited for.
	match_instance.advance_ticks(1)
	_expect(
		turret.reload_ticks_remaining == 4,
		"a dead building's turret must not keep reloading on a tick that runs before the frame that killed it ends"
	)

	match_instance.queue_free()
	await process_frame


## Names the specific hazard this suite's review round found: prepare_model_
## for_corpse() (scripts/units/unit.gd) used to set _simulation_halted itself,
## a few statements before UnitDeathSequence.begin()'s own call to
## request_despawn() -- which opens with `if _simulation_halted: return`, so
## the pre-set flag made that call a silent no-op. index.request_release()
## and the queue_free() fallback both never ran: the unit was halted but
## never actually freed or released, on the ordinary death path every unit
## with a matched death clip takes. tests/units/death_animation_run.gd's five
## is_queued_for_deletion() assertions (no Match in the tree, so
## request_despawn() takes its queue_free() fallback) would have caught this
## too, but only as an unexplained failure in a suite about corpses and
## animation clips, not as a case that names what actually broke: the
## interaction between prepare_model_for_corpse() and request_despawn()
## inside a real Match, where request_release() -- not queue_free() -- is the
## path that must fire.
##
## Default UnitScene is ATInfantry (scenes/units/unit.tscn); "Shot" is the
## same cause tests/units/death_animation_run.gd's _test_infantry_death uses
## to reliably reach the corpse branch (InfantryDeathStrategy has a Shot_
## candidate).
func _test_dead_unit_corpse_branch_halts_and_drains() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 3:
		await process_frame

	var unit := UnitScene.instantiate() as Unit
	unit.owner_player_id = 1
	match_instance.get_node("Units").add_child(unit)
	await process_frame
	_expect(unit.entity_id != 0, "the unit must be registered with the match's EntityNodeIndex before this case means anything")

	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"Shot")

	_expect(
		unit.is_simulation_halted(),
		"a lethal hit on the corpse branch must halt the unit's simulation immediately, in the same call that dealt it"
	)
	# Immediately after take_damage(), before any tick has drained the queue:
	# request_despawn() took the index.request_release() branch (a live Match
	# is in the tree), not the queue_free() fallback, so the node must not be
	# queued for deletion yet. This is what distinguishes "halted" from
	# "freed" -- collapsing them back into one moment is exactly what the
	# pre-set-flag bug did.
	_expect(
		not unit.is_queued_for_deletion(),
		"the unit must not be freed yet -- deferred despawn means the node is only queued for deletion once the tick drains"
	)

	match_instance.advance_ticks(1)
	_expect(
		unit.is_queued_for_deletion(),
		"the unit must be actually freed once apply_pending_releases() drains the tick that killed it -- this is the "
			+ "specific case a pre-set _simulation_halted flag makes fail, by making request_despawn() a no-op"
	)

	match_instance.queue_free()
	await process_frame
