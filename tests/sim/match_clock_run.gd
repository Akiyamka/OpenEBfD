extends "res://tests/support/suite.gd"

## Pins down scripts/sim/match_clock.gd (the simulation's only clock) and
## scripts/match/frame_tick_driver.gd (the frame-time -> whole-tick
## converter that lives outside the sim zone -- see that file's doc comment
## for why). Nothing here waits on engine time: MatchClock only moves when
## advance() is called, and FrameTickDriver only moves when pending_ticks()
## is called with an explicit delta.

const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const FrameTickDriverScript := preload("res://scripts/match/frame_tick_driver.gd")


func _initialize() -> void:
	_run_case("a fresh clock reads tick 0, and advance() counts up from there", _test_clock_counts_up)
	_run_case(
		"deltas shorter than one tick period yield 0 until the remainder crosses a whole tick",
		_test_sub_tick_deltas_accumulate
	)
	_run_case(
		"repeated exact one-tick-period deltas each yield exactly 1, proving nothing is banked",
		_test_exact_tick_period_yields_one
	)
	_run_case(
		"2.5 tick periods yields 2, and a following 0.5 period yields 1: the remainder is kept, not truncated",
		_test_fractional_remainder_carries
	)
	_run_case(
		"a delta far past MAX_TICKS_PER_FRAME clamps to the max and drops the excess instead of banking it",
		_test_clamp_drops_excess_rather_than_banking
	)
	_run_case(
		"zero, negative and non-finite deltas yield 0 and never corrupt the accumulator",
		_test_non_positive_and_non_finite_deltas_are_inert
	)
	_finish("MatchClock / FrameTickDriver tests")


func _test_clock_counts_up() -> void:
	var clock := MatchClockScript.new()
	_expect(clock.current_tick() == 0, "a fresh clock must read tick 0 before advance() is ever called")
	_expect(clock.advance() == 1, "the first advance() must return 1")
	_expect(clock.advance() == 2, "the second advance() must return 2")
	_expect(clock.current_tick() == 2, "current_tick() must agree with the last value advance() returned")


func _test_sub_tick_deltas_accumulate() -> void:
	var driver := FrameTickDriverScript.new()
	var third := MatchClockScript.SECONDS_PER_TICK / 3.0
	var due_per_call: Array[int] = []
	for _i in 3:
		due_per_call.append(driver.pending_ticks(third))
	_expect(
		due_per_call == [0, 0, 1],
		"three frames of a third of a tick period each must yield 0, 0, 1 -- the remainder carries across frames"
	)


func _test_exact_tick_period_yields_one() -> void:
	var driver := FrameTickDriverScript.new()
	for i in 20:
		_expect(
			driver.pending_ticks(MatchClockScript.SECONDS_PER_TICK) == 1,
			"frame %d of a run of exact one-tick-period deltas must yield exactly 1 tick" % i
		)


func _test_fractional_remainder_carries() -> void:
	var driver := FrameTickDriverScript.new()
	var first := driver.pending_ticks(2.5 * MatchClockScript.SECONDS_PER_TICK)
	_expect(first == 2, "2.5 tick periods in one frame must yield 2 whole ticks")
	var second := driver.pending_ticks(0.5 * MatchClockScript.SECONDS_PER_TICK)
	_expect(
		second == 1,
		"the leftover half tick period from the previous frame plus another half must yield 1 more tick"
	)


func _test_clamp_drops_excess_rather_than_banking() -> void:
	var driver := FrameTickDriverScript.new()
	_expect(driver.dropped_ticks() == 0, "a fresh driver must start with nothing dropped")

	# 12.5 tick periods in one frame: well past MAX_TICKS_PER_FRAME (5), with a
	# half-tick sub-tick remainder left over once every whole period is removed.
	var due := driver.pending_ticks(12.5 * MatchClockScript.SECONDS_PER_TICK)
	_expect(due == FrameTickDriverScript.MAX_TICKS_PER_FRAME, "an oversized frame must clamp to MAX_TICKS_PER_FRAME")
	_expect(
		driver.dropped_ticks() == 12 - FrameTickDriverScript.MAX_TICKS_PER_FRAME,
		"the ticks due beyond the clamp (12 whole periods due, 5 returned) must be recorded as dropped"
	)

	var zero_delta_due := driver.pending_ticks(0.0)
	_expect(zero_delta_due == 0, "a zero-delta frame right after the clamp must not surface any held-back ticks")

	# If the excess had been banked instead of dropped, roughly seven whole
	# tick periods would still be sitting in the accumulator and one more half
	# tick period would push due well past 1. Getting exactly 1 here is the
	# actual proof that the clamp discarded the excess rather than banking it.
	var half_tick_due := driver.pending_ticks(0.5 * MatchClockScript.SECONDS_PER_TICK)
	_expect(
		half_tick_due == 1,
		"only the half-tick sub-tick remainder may have survived the clamp, not the seven dropped whole periods"
	)


func _test_non_positive_and_non_finite_deltas_are_inert() -> void:
	var driver := FrameTickDriverScript.new()
	for bad_delta in [0.0, -1.0, -MatchClockScript.SECONDS_PER_TICK, NAN, INF, -INF]:
		_expect(
			driver.pending_ticks(bad_delta) == 0,
			"a non-positive or non-finite delta (%s) must yield 0 ticks" % bad_delta
		)
	_expect(driver.dropped_ticks() == 0, "none of the non-positive or non-finite deltas may register as dropped ticks")

	# The garbage deltas above must leave no residue: a normal frame right
	# after them has to behave exactly like it would on a freshly constructed
	# driver, not like one carrying corrupted accumulator state.
	_expect(
		driver.pending_ticks(MatchClockScript.SECONDS_PER_TICK) == 1,
		"a normal one-tick-period frame after a run of bad deltas must still yield exactly 1 tick"
	)
