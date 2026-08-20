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
##
## Also holds the plain rate constants behind those conversions -- not every
## number the original data was authored against turns into a simulation
## tick; TurnRate below is consumed directly as radians per second. This
## module is the category's one home either way: a rate or duration measured
## in the source data's own units, as distinct from anything this simulation
## or its navigation layer ticks at.

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

## Another rate the *source* rules data was authored at, and a different one
## from RULE_TICKS_PER_SECOND above: Rules.txt stores TurnRate in radians per
## original-game movement update, and the original engine ran twenty of those
## per second. Independent of both MatchClock.TICKS_PER_SECOND (this
## simulation's tick rate) and NavConstants.NAVIGATION_TICK_RATE
## (UnitNavigationSystem's own tick domain, folded into the simulation tick by
## a later slice) -- this constant stays 20.0 whatever either of those become.
## Several modules alias it locally so the math in each stays readable
## unqualified, and so a test can keep reading it by that class's name. Those
## aliases are deliberately not listed here: a list of them is a second place
## to keep correct, and it would be wrong the first time one is added or
## removed without anyone thinking to come back. Grep the constant's name to
## find them -- every alias assigns from this declaration, so the grep is
## exhaustive by construction in a way a hand-kept list never is.
const RULE_MOVEMENT_UPDATES_PER_SECOND := 20.0


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
