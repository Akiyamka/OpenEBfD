class_name MatchClock
extends RefCounted

## The simulation's only clock. See docs/architecture/network-multiplayer.md,
## decision 4 ("One integer tick at 25 Hz") and "Rules for sim code": the tick
## counter this class holds is simulation state, not a view-layer convenience
## -- it will be part of snapshots and checksums once those exist, the same
## way position, health and order queues are. Because it is state, this class
## itself is deliberately just a counter with no opinion on *when* it moves:
## who calls advance() is not this class's business. Today that caller is
## scripts/match/frame_tick_driver.gd, converting frame time into whole
## ticks; from phase 5 it is the turn scheduler, converting arrived command
## frames into ticks instead. Both drivers advance the same counter through
## the same method, which is the point.

## The single knob decision 4 fixes: the whole simulation runs off one
## integer tick rate, and every per-tick rule value in the rules data stays
## unscaled against it rather than being pre-multiplied for 25 Hz. That is
## what keeps re-testing at a different rate (20 Hz is an open question --
## see decision 4) a one-constant change instead of a rules-data rewrite.
const TICKS_PER_SECOND := 25
const SECONDS_PER_TICK := 1.0 / float(TICKS_PER_SECOND)

var _current_tick := 0


## Number of ticks simulated so far; 0 on a fresh clock, before advance() has
## ever been called.
func current_tick() -> int:
	return _current_tick


## Advances the simulation by exactly one tick and returns the new tick
## number. Callers decide how many times to call this per frame or per
## command batch; this class only ever moves by one.
func advance() -> int:
	_current_tick += 1
	return _current_tick
