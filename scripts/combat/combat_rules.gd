class_name CombatRules
extends RefCounted

const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

## The combat rule tick IS the simulation tick -- Rules.txt's per-tick combat
## values (ReloadCount, LingerDuration and friends) are counted in exactly the
## ticks MatchClock advances. Derived rather than declared so decision 4's
## single-knob promise holds literally: re-testing 20 Hz means editing
## MatchClock.TICKS_PER_SECOND and nothing else. It stays a float only because
## the remaining callers convert rule ticks to seconds for animation and
## docking maths, which is view-side arithmetic, not a tick domain of its own.
const TICKS_PER_SECOND := float(MatchClockScript.TICKS_PER_SECOND)
const COLLISION_MASK := 3
const DEFAULT_TARGET_HIT_RADIUS := 0.25
