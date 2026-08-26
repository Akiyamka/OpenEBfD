extends SceneTree

## Slice B4's regression suite -- see docs/architecture/network-multiplayer.md,
## phase 3's B4 entry. Structured on tests/match/entity_state_run.gd and
## tests/match/admission_run.gd: a real match fixture, a real tick driven
## explicitly, and assertions on the running match's own state rather than on
## a reconstruction of it.
##
## Every case drives Match._advance_simulation_tick() by hand and sets the
## driver's sub-tick accumulator by hand, then calls the view's own _process()
## directly, because an awaited frame advances the clock by however much wall
## time it happened to take and is not guaranteed to produce a tick at all --
## the same reason slice C6c's cases in demo_boot_run.gd stopped awaiting
## frames. The one case that deliberately does await frames
## (_test_global_position_is_never_interpolated) asserts a property that must
## hold at *every* fraction, including whichever ones real frame timing throws
## up, so there the nondeterminism is exactly the point.
##
## What each case is really guarding, since a green suite is not evidence on
## its own -- these were checked by mutation, and the mutations are recorded in
## this slice's commit message:
##
## - Interpolation writing nothing at all fails cases 2, 5, 6 and 7.
## - A hardcoded fraction of 1.0 -- the model always sitting on the current
##   tick, which is what "no interpolation" looks like from outside once the
##   offset is non-zeroable -- fails case 2 specifically, which is why case 2
##   asserts all three of 0.0, 0.5 and 1.0 rather than merely that something
##   moved.
## - Interpolation also writing global_position fails case 3, and only case 3.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const FrameTickDriverScript := preload("res://scripts/match/frame_tick_driver.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const SelectionHaloBindingScript := preload("res://scripts/ui/selection_halo_binding.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
## HK_General's converted model carries no authored #^^0 halo attachment. 9 of
## this project's 99 unit scenes are in that position -- measured by scanning
## every scenes/units/*.tscn's model for the `halo_anchor` meta the converter
## writes for #^^0 (converters/model_bake_builder.gd), and confirmed against
## the raw XBF. It stands in for all nine here.
const HKGeneralScene := preload("res://scenes/units/hk_general.tscn")

## Comfortably below one tick of any interesting movement and far above
## float32 noise on world coordinates in the 100-unit range, which is where the
## fixture's units live.
const POSITION_EPSILON := 0.002
## The smallest one-tick span _drive_until_moving() will accept as "moving".
## Measured, not guessed: the *first* tick on which ScoutA's stored position
## changes at all is a terrain snap, which moves it about 0.005 world units on
## the Y axis alone -- only 2.5x POSITION_EPSILON, far too thin a margin for
## assertions that then split that span in half. ScoutA travels 6 world units
## per second, or 0.24 per 25 Hz tick, so waiting for real horizontal movement
## costs a handful more driven ticks and buys two orders of magnitude of
## headroom.
const MINIMUM_BLEND_SPAN := 0.05

var _assertions := 0
var _failures := 0
var _current_case := ""
var _bullets := Bullets.new()


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"FrameTickDriver reports the sub-tick remainder pending_ticks() left behind, clamped to [0, 1]",
		_test_driver_reports_the_sub_tick_remainder
	)
	await _run_case(
		"a moving unit's model sits on the previous tick at fraction 0, halfway at 0.5 and on the "
			+ "current tick at 1",
		_test_visual_blends_between_two_ticks
	)
	await _run_case(
		"the span a unit blends across is a whole tick of travel, not a mid-tick intermediate",
		_test_blend_span_is_a_whole_tick
	)
	await _run_case(
		"global_position is never anything but the current tick's stored value, at any fraction",
		_test_global_position_is_never_interpolated
	)
	await _run_case(
		"a unit that has not moved shows no visual offset at all, so a standing unit cannot jitter",
		_test_standing_unit_has_no_visual_offset
	)
	await _run_case(
		"a jump larger than MAX_INTERPOLATION_DISTANCE snaps instead of sliding, and one just "
			+ "under it still blends",
		_test_teleport_snaps_instead_of_blending
	)
	await _run_case(
		"a projectile's visual blends between its own two consecutive tick positions, and a "
			+ "hitscan bullet is untouched",
		_test_projectile_visual_blends_between_ticks
	)
	await _run_case(
		"a selection halo on a model with no #^^0 anchor follows the interpolated model, and one "
			+ "with an anchor follows it without being told",
		_test_selection_halo_follows_the_interpolated_model
	)

	if _failures > 0:
		printerr("Interpolation tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Interpolation tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	# A runtime error aborts the case function where it stands, leaving
	# _failures untouched -- which would print PASS for a case that never
	# reached an assertion. Copied from tests/match/admission_run.gd, which
	# copied it from tests/match/despawn_run.gd.
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


## The fixture, warmed up far enough that Match._place_on_map() has run and
## every scene-authored unit already has a store position.
func _boot() -> Node:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 6:
		await process_frame
	return match_instance


func _teardown(match_instance: Node) -> void:
	match_instance.queue_free()
	await process_frame


## Pokes the running driver's accumulator to an exact sub-tick remainder.
## Reaching into a private field rather than feeding pending_ticks() a
## contrived delta: pending_ticks() would also *run* whatever whole ticks that
## delta covers, which is the one thing these cases need to keep under their
## own control. Callers read the fraction straight back out through the public
## accessor, so a renamed field fails loudly instead of quietly leaving the
## accumulator wherever real frame timing left it.
func _set_fraction(match_instance: Node, fraction: float) -> void:
	var driver: FrameTickDriver = match_instance.get("_tick_driver")
	driver.set("_accumulator", fraction * MatchClockScript.SECONDS_PER_TICK)


func _fraction(match_instance: Node) -> float:
	return float(match_instance.call("interpolation_fraction"))


## Where `unit`'s rendered model should sit in world space, computed from the
## store and the fraction alone -- deliberately not from visual_root's own
## local position, which is the thing under test.
func _expected_visual_world(
	unit: Unit, previous: Vector3, current: Vector3, fraction: float
) -> Vector3:
	var rest: Vector3 = unit.get("_visual_root_rest_position")
	return unit.to_global(rest) + (previous.lerp(current, fraction) - current)


## How far `unit`'s model currently sits from its authored rest position, in
## unit-local space -- 0 when nothing is being interpolated.
func _visual_offset_length(unit: Unit) -> float:
	var rest: Vector3 = unit.get("_visual_root_rest_position")
	return unit.visual_root.position.distance_to(rest)


## Sends ScoutA off on a real move order and drives whole ticks by hand until
## the store genuinely holds two different consecutive positions for it --
## the precondition every blend assertion below rests on, and one a single
## first-ever write does not satisfy (SimEntityState.set_position() seeds
## previous == current on the first write for an id).
func _drive_until_moving(match_instance: Node, unit: Unit) -> bool:
	var store = match_instance.entity_state()
	unit.move_to(unit.global_position + Vector3(10.0, 0.0, 0.0))
	for _tick in 60:
		match_instance.call("_advance_simulation_tick")
		if not store.has_position(unit.entity_id):
			continue
		var previous: Vector3 = store.previous_position(unit.entity_id)
		var current: Vector3 = store.position(unit.entity_id)
		if previous.distance_to(current) > MINIMUM_BLEND_SPAN:
			return true
	return false


func _test_driver_reports_the_sub_tick_remainder() -> void:
	var driver := FrameTickDriverScript.new()
	_expect(
		is_zero_approx(driver.interpolation_fraction()),
		"a driver that has never been given a delta must report 0.0, not a leftover"
	)
	var half_tick := 0.5 * MatchClockScript.SECONDS_PER_TICK
	_expect(
		driver.pending_ticks(half_tick) == 0,
		"half a tick must not come due as a whole tick -- the positive control for the fraction below"
	)
	_expect(
		absf(driver.interpolation_fraction() - 0.5) < 0.0001,
		"half a tick banked with no tick due must read as fraction 0.5"
	)
	# 1.75 ticks on top of the half already banked: two whole ticks come due
	# and exactly a quarter of a tick must be left behind. That is the property
	# the whole slice reads -- pending_ticks() consumes the whole ticks and
	# nothing else. The awkward 1.75 is deliberate: a rounder 1.5 would land
	# on 2.0 ticks exactly, whose remainder is 0.0, which is also what a
	# "consume everything" bug produces, so it would prove nothing.
	_expect(
		driver.pending_ticks(1.75 * MatchClockScript.SECONDS_PER_TICK) == 2,
		"1.75 ticks on top of 0.5 already banked must come due as 2 whole ticks"
	)
	_expect(
		absf(driver.interpolation_fraction() - 0.25) < 0.0001,
		"after the whole ticks are consumed the remainder must be 0.25, not 0.0 and not 2.25"
	)
	# The clamp. MAX_TICKS_PER_FRAME is 5, and a delta far past it subtracts
	# every due tick from the accumulator, not only the five it returns -- so
	# the fraction after a clamped frame is still a fraction.
	_expect(
		driver.pending_ticks(40.0 * MatchClockScript.SECONDS_PER_TICK)
			== FrameTickDriverScript.MAX_TICKS_PER_FRAME,
		"a 40-tick delta must be clamped to MAX_TICKS_PER_FRAME"
	)
	var clamped_fraction := driver.interpolation_fraction()
	_expect(
		clamped_fraction >= 0.0 and clamped_fraction <= 1.0,
		"even after the MAX_TICKS_PER_FRAME clamp the fraction must stay inside [0, 1], got %f"
			% clamped_fraction
	)


func _test_visual_blends_between_two_ticks() -> void:
	var match_instance: Node = await _boot()
	var scout := match_instance.get_node("Units/ScoutA") as Unit
	_expect(
		_drive_until_moving(match_instance, scout),
		"ScoutA must hold two different consecutive tick positions in the store before a blend "
			+ "means anything -- if this fails, nothing below is testing interpolation"
	)
	var store = match_instance.entity_state()
	var previous: Vector3 = store.previous_position(scout.entity_id)
	var current: Vector3 = store.position(scout.entity_id)

	var fractions: Array[float] = [0.0, 0.5, 1.0]
	for fraction in fractions:
		_set_fraction(match_instance, fraction)
		_expect(
			absf(_fraction(match_instance) - fraction) < 0.0001,
			(
				"the match must report the fraction this case just set (%f), or the poke missed "
				+ "and every assertion below is measuring frame timing instead"
			) % fraction
		)
		scout.call("_process", 0.0)
		var expected := _expected_visual_world(scout, previous, current, fraction)
		var actual: Vector3 = scout.visual_root.global_position
		_expect(
			actual.distance_to(expected) < POSITION_EPSILON,
			(
				"at fraction %f the model must sit at %v, got %v (previous tick %v, current tick %v)"
			) % [fraction, expected, actual, previous, current]
		)

	# The positive control for all three at once: fraction 0 and fraction 1
	# must not land in the same place, or the assertions above would pass just
	# as happily for an implementation that ignores the fraction entirely.
	_set_fraction(match_instance, 0.0)
	scout.call("_process", 0.0)
	var at_zero: Vector3 = scout.visual_root.global_position
	_set_fraction(match_instance, 1.0)
	scout.call("_process", 0.0)
	var at_one: Vector3 = scout.visual_root.global_position
	_expect(
		at_zero.distance_to(at_one) > POSITION_EPSILON,
		(
			"fraction 0 and fraction 1 must render the model in different places -- they came out "
			+ "%f apart, which means the blend is not reading the fraction at all"
		) % at_zero.distance_to(at_one)
	)
	_expect(
		absf(at_zero.distance_to(at_one) - previous.distance_to(current)) < POSITION_EPSILON,
		(
			"the span the model covers between fraction 0 and 1 must be exactly one tick's worth "
			+ "of movement (%f), got %f -- anything more is extrapolation"
		) % [previous.distance_to(current), at_zero.distance_to(at_one)]
	)

	await _teardown(match_instance)


## The regression case for the defect slice B4's own sweep found, and the
## reason SimEntityState.begin_tick() exists -- see that store's doc comment.
## Every managed ground unit is written twice per tick, once by
## Unit.navigation_step() for the horizontal step and once by
## UnitTerrainAlignment.snap_body_to_terrain() for the vertical correction. The
## store used to shift current into previous on every write, so
## previous_position() came back holding the horizontal step: a mid-tick
## intermediate whose X and Z are identical to position()'s, leaving a blend
## span of the terrain snap's Y alone -- measured at 0.005 world units against
## the 0.24 the unit actually covered. Every other case in this suite passed
## with that bug in place, because they only ever asked whether the blend used
## whatever span the store reported.
func _test_blend_span_is_a_whole_tick() -> void:
	var match_instance: Node = await _boot()
	var scout := match_instance.get_node("Units/ScoutA") as Unit
	_expect(
		_drive_until_moving(match_instance, scout),
		"ScoutA must be moving before its per-tick span means anything"
	)
	# One more driven tick, so the pair below is one deliberate tick's worth of
	# travel rather than whatever the loop above happened to stop on.
	match_instance.call("_advance_simulation_tick")
	var store = match_instance.entity_state()
	var previous: Vector3 = store.previous_position(scout.entity_id)
	var current: Vector3 = store.position(scout.entity_id)
	var expected_travel := scout.velocity.length() * MatchClockScript.SECONDS_PER_TICK
	_expect(
		expected_travel > 0.1,
		(
			"ScoutA must be travelling fast enough for this case to distinguish a whole tick from "
			+ "a terrain snap -- one tick at its current speed is %f world units"
		) % expected_travel
	)
	var horizontal := Vector3(current.x - previous.x, 0.0, current.z - previous.z)
	_expect(
		horizontal.length() > 0.9 * expected_travel,
		(
			"the horizontal distance between previous_position() and position() must be a whole "
			+ "tick of travel (about %f world units), got %f -- if this is ~0 the store is "
			+ "reporting a mid-tick intermediate again"
		) % [expected_travel, horizontal.length()]
	)
	_expect(
		previous.distance_to(current) < 1.5 * expected_travel,
		(
			"and no more than a whole tick: got %f against an expected %f"
		) % [previous.distance_to(current), expected_travel]
	)
	await _teardown(match_instance)


func _test_global_position_is_never_interpolated() -> void:
	var match_instance: Node = await _boot()
	var scout := match_instance.get_node("Units/ScoutA") as Unit
	_expect(
		_drive_until_moving(match_instance, scout),
		"ScoutA must be moving, or a mirror that never changes would pass this case trivially"
	)
	var store = match_instance.entity_state()

	# Half of this case is deterministic: every fraction the slice can produce,
	# both endpoints included, driven by hand.
	var offsets_seen := 0
	var fractions: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]
	for fraction in fractions:
		_set_fraction(match_instance, fraction)
		scout.call("_process", 0.0)
		var stored: Vector3 = store.position(scout.entity_id)
		_expect(
			scout.global_position == stored,
			(
				"at fraction %f global_position must still be exactly the current tick's stored "
				+ "value %v, got %v -- the whole slice rests on this"
			) % [fraction, stored, scout.global_position]
		)
		if _visual_offset_length(scout) > POSITION_EPSILON:
			offsets_seen += 1
	_expect(
		offsets_seen > 0,
		"at least one of those fractions must actually have offset the model -- otherwise this "
			+ "case proves global_position is untouched by an interpolation that is not happening"
	)

	# The other half runs on real frames, at whatever fractions real frame
	# timing produces, with real ticks landing in between. Nothing here
	# controls when a tick happens, which is exactly why it is worth sampling:
	# the property must hold at every instant, not only at the five above.
	for _frame in 12:
		await process_frame
		if not store.has_position(scout.entity_id):
			continue
		var stored_now: Vector3 = store.position(scout.entity_id)
		_expect(
			scout.global_position == stored_now,
			(
				"on a real frame global_position must still be exactly the stored tick value %v, "
				+ "got %v"
			) % [stored_now, scout.global_position]
		)

	await _teardown(match_instance)


func _test_standing_unit_has_no_visual_offset() -> void:
	var match_instance: Node = await _boot()
	var scout := match_instance.get_node("Units/ScoutA") as Unit

	# The positive control first, in the same case: while it is moving the
	# model really does leave its rest position.
	_expect(
		_drive_until_moving(match_instance, scout),
		"ScoutA must move first, so that 'no offset' below means 'stopped', not 'never worked'"
	)
	_set_fraction(match_instance, 0.0)
	scout.call("_process", 0.0)
	_expect(
		_visual_offset_length(scout) > POSITION_EPSILON,
		"a moving unit at fraction 0 must have its model offset from rest, or the negative "
			+ "assertion below proves nothing"
	)

	scout.stop_at_current_position()
	var store = match_instance.entity_state()
	var settled := false
	for _tick in 40:
		match_instance.call("_advance_simulation_tick")
		var previous: Vector3 = store.previous_position(scout.entity_id)
		var current: Vector3 = store.position(scout.entity_id)
		if previous.distance_to(current) <= POSITION_EPSILON:
			settled = true
			break
	_expect(settled, "a stopped ScoutA must reach two identical consecutive tick positions")

	var fractions: Array[float] = [0.0, 0.5, 1.0]
	for fraction in fractions:
		_set_fraction(match_instance, fraction)
		scout.call("_process", 0.0)
		_expect(
			_visual_offset_length(scout) <= POSITION_EPSILON,
			(
				"a unit whose previous and current tick positions are the same must show no "
				+ "visual offset at fraction %f -- got %f"
			) % [fraction, _visual_offset_length(scout)]
		)

	await _teardown(match_instance)


func _test_teleport_snaps_instead_of_blending() -> void:
	var match_instance: Node = await _boot()
	var scout := match_instance.get_node("Units/ScoutA") as Unit
	var base := scout.global_position

	# Just under the threshold: still ordinary movement as far as this rule is
	# concerned, so it must still blend. This is the positive control -- without
	# it a threshold of zero would pass the teleport assertions below.
	var near_jump := Unit.MAX_INTERPOLATION_DISTANCE - 1.0
	scout.set_simulation_position(base)
	scout.set_simulation_position(base + Vector3(near_jump, 0.0, 0.0))
	_set_fraction(match_instance, 0.0)
	scout.call("_process", 0.0)
	_expect(
		absf(_visual_offset_length(scout) - near_jump) < POSITION_EPSILON,
		(
			"a %f-unit step is below MAX_INTERPOLATION_DISTANCE and must still blend the full "
			+ "span at fraction 0, got an offset of %f"
		) % [near_jump, _visual_offset_length(scout)]
	)

	# Well past it: a transport drop, a factory exit, a scattered survivor.
	var far_jump := Unit.MAX_INTERPOLATION_DISTANCE + 50.0
	scout.set_simulation_position(base)
	scout.set_simulation_position(base + Vector3(far_jump, 0.0, 0.0))
	var fractions: Array[float] = [0.0, 0.5, 1.0]
	for fraction in fractions:
		_set_fraction(match_instance, fraction)
		scout.call("_process", 0.0)
		_expect(
			_visual_offset_length(scout) <= POSITION_EPSILON,
			(
				"a %f-unit relocation must snap the model onto the current tick at fraction %f "
				+ "rather than sliding it across the map, got an offset of %f"
			) % [far_jump, fraction, _visual_offset_length(scout)]
		)

	await _teardown(match_instance)


func _test_projectile_visual_blends_between_ticks() -> void:
	var match_instance: Node = await _boot()

	# Launched high above the fixture's terrain and aimed horizontally, so
	# there is nothing for it to collide with and it is still flying at every
	# checkpoint below. StraightBomb: speed 24 (0.96 world units per 25 Hz
	# tick) with 9 tiles of range against an 8-unit shot, so it has better than
	# eight ticks of flight to be sampled in.
	var origin := Vector3(120.0, 60.0, 20.0)
	var projectile = CombatProjectileScript.new()
	match_instance.add_child(projectile)
	var launched: bool = projectile.launch(
		_bullets.runtime_bullet(&"StraightBomb"),
		Bullets.emission(origin, Vector3.RIGHT),
		origin + Vector3(8.0, 0.0, 0.0)
	)
	_expect(launched, "the probe shot must launch, or there is nothing to interpolate")

	var visual: Node3D = projectile.get("_visual")
	_expect(visual != null, "a non-hitscan bullet must have built its \"Visual\" child")
	_expect(
		not bool(projectile.get("_has_tick_history")),
		"a projectile that has never been ticked must have no tick history to blend from -- its "
			+ "first frame would otherwise blend from wherever it was constructed"
	)

	# One tick: the admission drain (slice C6b) admits it as the tick's first
	# statement, and the "sim_projectiles" walk later in the same tick flies it.
	match_instance.call("_advance_simulation_tick")
	_expect(
		bool(projectile.get("_has_tick_history")),
		"one driven tick must have given the projectile a previous position -- if this fails, the "
			+ "admission queue never admitted it and it never flew"
	)
	_expect(
		projectile.state == CombatProjectileScript.State.FLYING,
		"the probe must still be flying, or the positions below describe an impact rather than a "
			+ "tick of flight"
	)

	var previous: Vector3 = projectile.get("_previous_tick_position")
	var current: Vector3 = projectile.global_position
	_expect(
		previous.distance_to(current) > POSITION_EPSILON,
		"the projectile must have covered ground on that tick, or there is no span to blend"
	)

	var rest: Vector3 = projectile.get("_visual_rest_position")
	var fractions: Array[float] = [0.0, 0.5, 1.0]
	for fraction in fractions:
		_set_fraction(match_instance, fraction)
		projectile.call("_process", 0.0)
		var expected: Vector3 = projectile.to_global(rest) \
			+ (previous.lerp(current, fraction) - current)
		_expect(
			visual.global_position.distance_to(expected) < POSITION_EPSILON,
			(
				"at fraction %f the projectile's visual must sit at %v, got %v"
			) % [fraction, expected, visual.global_position]
		)
		_expect(
			projectile.global_position == current,
			"interpolating the visual must not move the projectile node itself -- hit resolution "
				+ "and MissileTrail.sample() both read global_position"
		)

	# A hitscan bullet resolves synchronously inside launch(), builds no
	# "Visual" at all and never reaches State.FLYING, so it must come through
	# all of this completely untouched -- including a sim_tick(), which
	# Match's "sim_projectiles" walk really does hand a finished projectile
	# for the rest of the frame it died on.
	var hitscan = CombatProjectileScript.new()
	match_instance.add_child(hitscan)
	var hitscan_launched: bool = hitscan.launch(
		_bullets.runtime_bullet(&"LMG_B"),
		Bullets.emission(origin, Vector3.RIGHT),
		origin + Vector3(4.0, 0.0, 0.0)
	)
	_expect(hitscan_launched, "the hitscan probe must launch")
	_expect(hitscan.is_finished(), "a hitscan bullet must already be finished when launch() returns")
	_expect(
		hitscan.get("_visual") == null and hitscan.get_node_or_null("Visual") == null,
		"a hitscan bullet must build no \"Visual\" child for anything to interpolate"
	)
	var hitscan_position: Vector3 = hitscan.global_position
	hitscan.call("sim_tick")
	_set_fraction(match_instance, 0.5)
	hitscan.call("_process", 0.0)
	_expect(
		hitscan.global_position == hitscan_position,
		"a hitscan bullet must still be exactly where it resolved after a tick and a frame of "
			+ "B4's own code have run over it"
	)

	projectile.free()
	hitscan.free()
	await _teardown(match_instance)


func _test_selection_halo_follows_the_interpolated_model() -> void:
	var match_instance: Node = await _boot()

	var general := HKGeneralScene.instantiate() as Unit
	general.owner_player_id = 1
	match_instance.get_node("Units").add_child(general)
	_expect(
		SelectionHaloBindingScript.anchor(general.visual_root) == null,
		"HK_General's converted model must genuinely carry no #^^0 anchor -- if it gains one, this "
			+ "case stops covering the fallback path and needs a different model"
	)
	_expect(general.entity_id != 0, "the probe unit must have registered an entity id")

	var halo = general.get("_selection_halo")
	_expect(halo != null, "the probe unit must have built a selection halo")
	var halo_rest: Vector3 = halo.get("_rest_position")

	var base := general.global_position
	general.set_simulation_position(base)
	general.set_simulation_position(base + Vector3(1.0, 0.0, 0.0))

	_set_fraction(match_instance, 0.0)
	general.call("_process", 0.0)
	halo.call("_process", 0.0)
	var rest: Vector3 = general.get("_visual_root_rest_position")
	var offset: Vector3 = general.visual_root.position - rest
	_expect(
		offset.length() > POSITION_EPSILON,
		"the probe unit's own model must be offset at fraction 0, or the halo has nothing to follow"
	)
	_expect(
		halo.position.distance_to(halo_rest + offset) < POSITION_EPSILON,
		(
			"an anchorless halo must carry the same local offset the model carries -- expected "
			+ "%v, got %v"
		) % [halo_rest + offset, halo.position]
	)

	_set_fraction(match_instance, 1.0)
	general.call("_process", 0.0)
	halo.call("_process", 0.0)
	_expect(
		halo.position.distance_to(halo_rest) < POSITION_EPSILON,
		(
			"at fraction 1 there is no offset, so an anchorless halo must be back at its authored "
			+ "resting position -- got %v against %v"
		) % [halo.position, halo_rest]
	)

	# The other path, which needed no change at all: ScoutA's model does have a
	# #^^0, and SelectionHalo._process() already re-derives its position from
	# that anchor's global transform every frame, so the offset reaches it for
	# free. This is the assertion behind "re-parenting the halo under
	# visual_root would have bought nothing".
	var scout := match_instance.get_node("Units/ScoutA") as Unit
	_expect(
		SelectionHaloBindingScript.anchor(scout.visual_root) != null,
		"ScoutA's model must have a #^^0 anchor, or this half of the case is testing the fallback "
			+ "path a second time"
	)
	var scout_halo = scout.get("_selection_halo")
	var scout_base := scout.global_position
	scout.set_simulation_position(scout_base)
	scout.set_simulation_position(scout_base + Vector3(1.0, 0.0, 0.0))
	_set_fraction(match_instance, 1.0)
	scout.call("_process", 0.0)
	scout_halo.call("_process", 0.0)
	var anchored_at_one: Vector3 = scout_halo.position
	_set_fraction(match_instance, 0.0)
	scout.call("_process", 0.0)
	scout_halo.call("_process", 0.0)
	var anchored_at_zero: Vector3 = scout_halo.position
	_expect(
		absf(anchored_at_zero.distance_to(anchored_at_one) - 1.0) < POSITION_EPSILON,
		(
			"an anchored halo must move by the model's full one-unit offset between fraction 1 "
			+ "and 0 with nothing pushing it -- got %f"
		) % anchored_at_zero.distance_to(anchored_at_one)
	)

	await _teardown(match_instance)
