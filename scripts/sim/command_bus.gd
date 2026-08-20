class_name SimCommandBus
extends RefCounted

## Queues SimCommands (scripts/sim/commands/sim_command.gd) until their
## scheduled execution tick, in the total order lockstep needs. This is
## sim-zone code -- see docs/architecture/network-multiplayer.md, "Rules for
## sim code", and tools/architecture_rules.toml -- so it may not touch the
## scene tree, frame `delta` or the wall clock, and it never emits a signal:
## drain() hands its result back as a return value, and Match is the one
## that turns that into anything a player sees (see
## Match._advance_simulation_tick() and
## UnitCommandController.on_command_executed()).

## One command waiting for its scheduled tick, paired with the bus-assigned
## sequence number that breaks same-player, same-tick ties in drain() (see
## _drain_order()). Modeled on LoopbackHub.PendingMessage
## (scripts/net/loopback_hub.gd), which solves the identical "assign an
## order at submission time, sort by it at delivery time" problem for
## network frames. The sequence lives here, not on SimCommand, for the same
## reason the execution tick does not (see that class's doc comment): it is
## a fact about when the bus received the command, not about the command
## itself.
class _QueuedCommand extends RefCounted:
	var command: SimCommand
	var tick: int
	var sequence: int


## Phase 2 runs single-player, over no transport, with nothing to hide --
## a command takes effect on the very next tick. Phase 5's turn scheduler
## raises this once real round-trips need to be absorbed (decision 8,
## "Layering", in docs/architecture/network-multiplayer.md). A `var`, not a
## constant: the adaptive policy changes this at runtime as measured latency
## changes, unlike MatchClock.TICKS_PER_SECOND, which is fixed for a whole
## match. It is also deliberately not a second tick *rate* -- own-tick-rate
## in tools/architecture_rules.toml forbids a module declaring one of those,
## and this isn't one: it is an offset measured in the one tick rate the
## match already has.
var input_delay_ticks := 0

var _pending: Array[_QueuedCommand] = []
## Every submit() call, accepted or dropped, draws from this counter --
## see _drain_order() for why acceptance order alone is not enough.
var _next_sequence := 0
var _last_tick_drained := -1
var _dropped_late_count := 0


## Schedules `command` for the absolute tick `target_tick` and returns it
## unchanged, applying the same late-drop rule submit() does (see the
## paragraphs below). This is the one implementation "queue a command for
## tick T" has; submit() is written in terms of it rather than duplicating
## the body, so there is exactly one place this logic can drift.
##
## The reason a separate absolute-tick entry point exists at all: a replay
## records the tick drain() actually executed a command on
## (scripts/match/replay_file.gd), and playback must land the command on
## that exact recorded tick, not on whatever tick a fresh computation would
## produce. input_delay_ticks is a `var` phase 5's adaptive policy changes
## at runtime (see that field's doc comment) -- if playback reconstructed
## the target tick via submit(command, recorded_tick - input_delay_ticks) or
## any other derivation, the same replay would land on a different tick
## depending on whatever input_delay_ticks happens to be set to at playback
## time, silently diverging from the tick it actually ran on when recorded.
## submit_at() sidesteps that reconstruction entirely: it is handed the
## already-decided answer and trusts it.
##
## A command whose target tick is at or before the last tick this bus has
## already drained missed its slot. This mirrors FrameTickDriver.dropped_ticks()
## (scripts/match/frame_tick_driver.gd) exactly, and for the same reason:
## the target tick is simulated time that already happened, and in lockstep
## "simulate it anyway, late" is not an option -- every client must run the
## same commands on the same ticks, and a client that quietly slipped this
## command onto whatever tick it next got around to would diverge from one
## that dropped it, or from one that was merely a frame faster. So a late
## command is not executed and not silently rescheduled onto some other
## tick either: it is counted in dropped_late_count() and nothing else,
## which is the seam a later phase (the turn scheduler's stall/drop policy,
## or a desync check) reads instead of discovering the loss only after a
## match has already diverged. Replay playback inherits this rule for free
## by going through this method rather than around it: a recorded command
## that targets a tick playback has already passed (say, because playback
## started partway through the file) is dropped the same way a live late
## command is, instead of needing its own second copy of this reasoning.
func submit_at(command: SimCommand, target_tick: int) -> int:
	if target_tick <= _last_tick_drained:
		_dropped_late_count += 1
		return target_tick
	var queued := _QueuedCommand.new()
	queued.command = command
	queued.tick = target_tick
	queued.sequence = _next_sequence
	_next_sequence += 1
	_pending.append(queued)
	return target_tick


## Schedules `command` for current_tick + input_delay_ticks and returns that
## tick. A thin wrapper over submit_at() -- see that method for the
## late-drop rule and for why an absolute-tick entry point exists at all
## (replay playback).
func submit(command: SimCommand, current_tick: int) -> int:
	return submit_at(command, current_tick + input_delay_ticks)


## Every command due at exactly `tick`, removed from the bus, in the bus's
## total order: by player_id, then by submission sequence (see
## _drain_order()). Also marks `tick` as drained, whether or not anything
## was due -- see submit()'s late-detection, which depends on this having
## happened even for an empty tick.
func drain(tick: int) -> Array:
	_last_tick_drained = maxi(_last_tick_drained, tick)
	var due: Array[_QueuedCommand] = []
	var remaining: Array[_QueuedCommand] = []
	for queued in _pending:
		if queued.tick == tick:
			due.append(queued)
		else:
			remaining.append(queued)
	_pending = remaining
	due.sort_custom(_drain_order)
	var commands: Array = []
	for queued in due:
		commands.append(queued.command)
	return commands


## By player_id, then by submission sequence. The sequence tie-break is not
## optional: two commands from the same player submitted on the same tick
## have no other property that orders them, and "no defined order" is
## exactly what lockstep cannot afford here -- every client must resolve the
## tie identically, and only the order the bus itself assigned at submit
## time is guaranteed to agree across clients (arrival order over a real
## transport is not; see decision 6). Sorting by player_id first, not just
## sequence, is what makes the order depend only on facts every client
## already agrees on -- who issued a command and when the local bus queued
## it -- never on which client's copy of this function happens to run.
func _drain_order(a: _QueuedCommand, b: _QueuedCommand) -> bool:
	if a.command.player_id != b.command.player_id:
		return a.command.player_id < b.command.player_id
	return a.sequence < b.sequence


## Commands currently queued, across every tick -- drained and dropped ones
## excluded either way.
func pending_count() -> int:
	return _pending.size()


## Total commands submit() refused to queue because their target tick was
## already at or before the last tick this bus had drained. See submit()
## for why a late command is counted here rather than executed or
## rescheduled.
func dropped_late_count() -> int:
	return _dropped_late_count
