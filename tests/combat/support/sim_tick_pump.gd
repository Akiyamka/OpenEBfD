extends RefCounted

## Stands in for Match's own frame loop, for suites that drive a Unit or a
## Building by hand with no Match instance in the tree.
##
## Since phase 1, Unit._process()/Building._process() no longer advance turret
## reload and burst countdowns themselves: Match._advance_simulation_tick()
## does, centrally, through each entity's sim_tick() (see its doc comment).
## A suite that calls entity._process() directly therefore advances animation
## and aim but never a countdown, and any assertion that waits for a weapon to
## come off reload waits forever -- silently, as a timeout rather than an
## error. That has already caught three suites; this exists so the fourth does
## not have to rediscover it.
##
## One pump per entity. It carries a FrameTickDriver, so its sub-tick
## remainder stays independent of whatever other entities the same test drives,
## exactly as Match's single driver would apportion ticks across a frame.
##
## Ticks run before _process() to match production ordering: Match is an
## ancestor of every Unit and Building node, and Godot processes a frame in
## scene-tree order, so _advance_simulation_tick() -- and with it every
## entity's sim_tick() -- has already run for this frame by the time a real
## _process() observes it.

const FrameTickDriverScript := preload("res://scripts/match/frame_tick_driver.gd")

var _driver := FrameTickDriverScript.new()


## Advances `entity` by one rendered frame of `delta`, running whatever whole
## simulation ticks that frame is due first.
func advance(entity, delta: float) -> void:
	for _tick in _driver.pending_ticks(delta):
		entity.sim_tick()
	entity._process(delta)
