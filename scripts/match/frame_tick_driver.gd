class_name FrameTickDriver
extends RefCounted

## Converts frame `delta` into whole simulation ticks. This lives outside
## scripts/sim/ on purpose: turning wall/frame time into ticks is exactly the
## operation the sim zone's `sim-no-frame-delta` rule (see
## tools/architecture_rules.toml and docs/architecture/network-multiplayer.md,
## "Rules for sim code") forbids sim code from doing itself, so the
## conversion has to happen in a driver the sim layer never sees, one call to
## MatchClock.advance() per whole tick due.

const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

## A single frame that stalls for, say, one real second must not make the
## *next* frame try to simulate a whole second of gameplay in one go: that
## next frame would itself take far longer than 1/60s to run 25 ticks worth
## of game logic, stalling the frame after it, and so on -- the spiral of
## death every fixed-timestep loop has to guard against. Clamping how many
## ticks a single frame may advance breaks that feedback loop at the cost of
## the simulation temporarily running behind real time instead of never
## catching up at all.
const MAX_TICKS_PER_FRAME := 5

var _accumulator := 0.0
var _dropped_ticks := 0


## Adds `delta` to the internal accumulator and returns how many whole
## MatchClock.SECONDS_PER_TICK periods are now due, consuming exactly that
## much from the accumulator so a sub-tick remainder carries into the next
## frame instead of being truncated away.
##
## A non-positive or non-finite delta (a paused engine, a hitch that reports
## NAN/INF, or simply frame 0) contributes nothing and leaves the
## accumulator untouched, rather than being clamped into 0.0 and silently
## eating whatever remainder was already banked.
func pending_ticks(delta: float) -> int:
	if delta <= 0.0 or not is_finite(delta):
		return 0
	_accumulator += delta
	var due := int(_accumulator / MatchClockScript.SECONDS_PER_TICK)
	if due <= MAX_TICKS_PER_FRAME:
		_accumulator -= due * MatchClockScript.SECONDS_PER_TICK
		return due
	# More ticks are due than one frame may ever advance. The excess is
	# discarded rather than banked for a later frame: banking it would just
	# delay the same catch-up spiral instead of preventing it, since a later
	# frame would still have to run more ticks than it has time for. Dropping
	# keeps the sub-tick remainder (not the whole accumulator) so a clamped
	# frame does not also lose fractional progress it never asked to lose.
	_dropped_ticks += due - MAX_TICKS_PER_FRAME
	_accumulator -= due * MatchClockScript.SECONDS_PER_TICK
	return MAX_TICKS_PER_FRAME


## Total ticks discarded by the clamp in pending_ticks() since this driver
## was constructed. Dropped ticks are simulated time that never happened --
## in a lockstep match, every client must run the same number of ticks, so a
## clamp that fires differently on different machines (a slower client
## stalling more often) is itself a source of divergence. Nothing reads this
## counter yet; it exists as the seam a later phase (the turn scheduler, or
## its stall/drop policy) can read instead of discovering the loss only when
## a desync check already failed.
func dropped_ticks() -> int:
	return _dropped_ticks
