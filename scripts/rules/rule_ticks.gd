class_name RuleTicks
extends RefCounted

## Converts a per-tick duration out of the rules data into simulation ticks.
## This is the one place decision 4 ("One integer tick at 25 Hz",
## docs/architecture/network-multiplayer.md) puts the 60 Hz -> 25 Hz
## conversion: per-tick values stay unscaled in resources/**/*.tres, so a
## config value only becomes a simulation-domain number at the boundary where
## it turns into a queue order (BuildingQueue.start(), UpgradeQueue.start(),
## WallChain's constructor) or a countdown (SpiceMound's maturity cycle).
## Originally named for the first of those boundaries alone -- see git
## history -- until the second one arrived and the construction-only name
## started actively misleading.

const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

## The rate the *source* rules data was authored at, not a property of this
## simulation -- MatchClock.TICKS_PER_SECOND owns that. Every per-tick
## duration in resources/**/*.tres -- build times, upgrade times, spice mound
## maturity -- comes from the original game's Rules.txt, and this codebase has
## always read those values at 60 per second (see
## tools/generate_unit_definitions.py and the schema notes in
## assets/converted/schema.sql). It lives here, next to the rules, rather than
## on MatchClock, so that re-testing a different simulation tick rate (20 Hz
## is an open question -- see decision 4) never has to touch this constant.
const RULE_TICKS_PER_SECOND := 60


## Converts a duration measured in rule ticks (60/sec) into whole
## simulation ticks (MatchClock.TICKS_PER_SECOND/sec), preserving wall-clock
## duration: 300 rule ticks was 5 seconds at 60 Hz, and roundi(300 * 25 / 60)
## is 125 sim ticks -- still 5 seconds. Rounding to the nearest whole tick
## costs at most half a tick either way, well under 20 ms on a duration
## measured in seconds. A non-positive or non-finite input (no duration
## defined) returns 0, but any genuinely positive input is floored at 1: a
## build that rounded down to 0 ticks would both complete the instant it was
## adopted and be rejected outright by ProductionQueue.adopt(), which treats
## build_time_ticks <= 0 as "no order" -- one of this function's callers, not
## the only one.
static func to_sim_ticks(rule_ticks: float) -> int:
	if not is_finite(rule_ticks) or rule_ticks <= 0.0:
		return 0
	return maxi(1, roundi(rule_ticks * float(MatchClockScript.TICKS_PER_SECOND) / float(RULE_TICKS_PER_SECOND)))


## The form the order-creating call sites want: a config with no build time at
## all still yields a buildable order of one tick.
##
## This is not an edge case dressed up as one. 92 of the shipped building
## definitions and 25 of the unit definitions carry build_time_ticks = 0,
## ATConYard (cost 2000) among them, because the generated rules database
## writes 0 wherever Rules.txt had no BuildTime. Every call site therefore
## used to guard with maxf(config.build_time_ticks, 1.0) and got a buildable,
## near-instant order. to_sim_ticks() reports 0 honestly for "no build time
## defined", and ProductionQueue.adopt() rejects an order of 0 ticks outright,
## so without this floor those definitions would silently stop being
## buildable at all -- a behaviour change, in a phase whose whole point is
## that behaviour does not change.
static func order_sim_ticks(rule_ticks: float) -> int:
	return maxi(to_sim_ticks(rule_ticks), 1)
