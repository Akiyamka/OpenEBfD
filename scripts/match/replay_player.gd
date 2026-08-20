class_name ReplayPlayer
extends RefCounted

## Feeds a recorded replay (scripts/match/replay_file.gd) back into a
## SimCommandBus (scripts/sim/command_bus.gd), on the ticks
## ReplayRecorder (scripts/match/replay_recorder.gd) recorded them for -- the
## playback half of the phase 2 replay slice; see
## docs/architecture/network-multiplayer.md, decision 10 and phase 2
## ("Replay recording and playback land here"). Lives beside ReplayRecorder,
## for the identical reason: ReplayFile.read() opens a file, which
## tools/architecture_rules.toml's zones.sim rules forbid inside
## scripts/sim/ -- see ReplayRecorder's doc comment for the exact rule this
## class would otherwise break.
##
## Playback goes through the bus, not around it: a replay is just another
## submitter, exactly like UnitCommandController or BuildingController, and
## the bus is the merge point every submitter shares -- see the module doc
## comment on scripts/sim/command_bus.gd. play_tick() is called from
## Match._advance_simulation_tick() (scripts/match/match.gd) *between*
## `_clock.advance()` and `_command_bus.drain(tick)`, not after, unlike
## record_tick()'s call site: a command targeting tick T has to be queued
## before drain(T) runs, or SimCommandBus.submit_at()
## (scripts/sim/command_bus.gd) would count it as late -- _last_tick_drained
## already at T -- purely because playback called in one statement too late,
## not because the replay is actually corrupt.
##
## Every record submits through submit_at(command, recorded_tick) -- never
## submit(), and never a target tick reconstructed from input_delay_ticks --
## see submit_at()'s own doc comment for why that method exists at all: this
## class is the reason. And every tick's records submit in the order they
## appear in the file, which is already SimCommandBus.drain()'s own total
## order (by player_id, then submission sequence -- see _drain_order() in
## scripts/sim/command_bus.gd). Submitting in that order hands each command a
## fresh sequence in the same relative order, so drain() returns the
## identical order again; this class never sorts, filters or dedupes what it
## reads, only replays it. See ReplayRecorder's doc comment for the matching
## half of this invariant on the recording side -- "recorded order" and
## "executed order" being the same fact is what both classes exist to
## preserve, from opposite ends.
##
## Not suppressed here: a live player's local controllers submitting to the
## same bus while a replay plays back. There is currently no UI that can
## start playback -- it is driven only from tests and headless entry points,
## the same as recording -- so nothing today can be clicking while a replay
## runs, and building suppression for a scenario that cannot occur yet would
## be speculative. The day playback gains a UI, this stops being free:
## UnitCommandController, BuildingController and the rest would still submit
## straight to the one bus a match owns, merging live input into the
## replay's stream on ticks the replay never scheduled anything for, and
## desyncing every tick after the first collision from what was recorded.
## Whoever builds that UI must make local controllers stop submitting before
## playback starts -- a "replay mode" flag, a scratch bus, or detaching the
## controllers entirely -- and none of those exist yet. Naming the hazard is
## this slice's job; solving it is the next one's.
##
## Loading is off by default, matching ReplayRecorder.start(): nothing in
## Match calls load() outside tests and headless entry points.

const ReplayFileScript := preload("res://scripts/match/replay_file.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")

var _records: Array = []
var _next_index := 0
var _loaded := false


## Whether a replay is currently loaded. Mirrors ReplayRecorder.is_recording()
## -- exposed for callers that need to know without reaching into this
## class's private state.
func is_loaded() -> bool:
	return _loaded


## Reads `path` via ReplayFile.read() (scripts/match/replay_file.gd) and, if
## it parses, checks its snapshot_digest against `expected_snapshot_digest`
## -- the digest of the match's *current* MatchSnapshot file
## (FileAccess.get_sha256() of Match._snapshot_storage_path(),
## scripts/match/match.gd, or "" when no such file exists yet). A mismatch
## fails to load, loudly, naming both digests, rather than silently playing
## a replay's commands back against a starting position it was never
## recorded from -- see ReplayFile's doc comment on snapshot_digest for why
## that comparison is the entire reason the field is in the header at all. A
## replay recorded with no snapshot carries an empty digest and fails this
## check the same way against a match that has one: "" is a pinned fact
## there, not a missing one, so it never coincidentally matches a real
## digest.
##
## A failed check (bad file, or a digest mismatch) leaves this player
## exactly as it was before the call -- is_loaded() and is_exhausted() keep
## reporting whatever a prior successful load() left them at, if any --
## since nothing here is mutated until the digest check has already passed.
##
## Returns a result Dictionary in the same {"ok": bool, "message": String}
## shape ReplayFile.read() and ReplayRecorder.start() use, for the same
## reason: loading a file on request is ordinary code, not something a
## signal is the right tool for.
func load(path: String, expected_snapshot_digest: String) -> Dictionary:
	var result := ReplayFileScript.read(path)
	if not bool(result.get("ok", false)):
		return result
	var recorded_digest := String(result.get("snapshot_digest", ""))
	if recorded_digest != expected_snapshot_digest:
		return {
			"ok": false,
			"message": (
				"Replay snapshot_digest %s does not match the match's current snapshot digest %s: %s"
				% [_describe_digest(recorded_digest), _describe_digest(expected_snapshot_digest), path]
			),
		}
	_records = result.get("records", [])
	_next_index = 0
	_loaded = true
	return {"ok": true, "message": String(result.get("message", ""))}


## Submits every not-yet-submitted record whose recorded tick is at or
## before `tick`, onto `command_bus`, in file order, via
## submit_at(command, recorded_tick) -- see this class's doc comment for why
## submit_at() and file order, never submit() or a re-derived target. A
## no-op when no replay is loaded, exactly as ReplayRecorder.record_tick()
## is a no-op when not recording, so Match's tick loop can call this
## unconditionally instead of guarding every call site on is_loaded().
##
## Must be called for tick T before `command_bus`'s own drain(T) -- see this
## class's doc comment for why. "At or before `tick`", not "equal to
## `tick`", is what lets this method also be the answer for a record whose
## own tick has already been passed by the time this is first called (say,
## because playback resumed partway through a match): such a record is
## still submitted, via submit_at(command, its own recorded tick), and
## SimCommandBus's late-drop rule takes it from there exactly as it would
## for any other late command -- counted in dropped_late_count(), never
## executed, never silently rescheduled onto `tick` instead. In the ordinary
## case, where this is called once for every tick in increasing order
## starting from the first, "at or before" and "equal to" pick out exactly
## the same records, since a record's tick becomes `<= tick` for the first
## time exactly when `tick` reaches it.
##
## A record whose payload fails to decode (SimCommandCodec.decode()
## returning null -- corruption ReplayFile.read() itself cannot see, since
## it never looks inside a payload) has nothing to submit, so it is skipped
## -- but loudly, via push_error(), never silently. A skipped record means
## this playback has already stopped reproducing the recording, and every
## tick after it is suspect; the same reasoning CommandExecutor.execute()
## (scripts/match/command_executor.gd) gives in its own default branch for
## refusing to drop an unknown command type without a trace.
func play_tick(command_bus: SimCommandBus, tick: int) -> void:
	if not _loaded:
		return
	while _next_index < _records.size() and int(_records[_next_index]["tick"]) <= tick:
		var record: Dictionary = _records[_next_index]
		var command := SimCommandCodecScript.decode(record["payload"])
		if command == null:
			push_error(
				"ReplayPlayer.play_tick(): record %d (tick %d) failed to decode -- "
					% [_next_index, int(record["tick"])]
				+ "this replay no longer reproduces what was recorded, and every tick "
				+ "after this one is suspect. Skipping it silently would leave a "
				+ "playback that merely looks faithful."
			)
		else:
			command_bus.submit_at(command, int(record["tick"]))
		_next_index += 1


## True once every recorded command has been submitted (via play_tick(),
## dropped-late ones included -- see that method) -- the only end marker
## this format has, per ReplayFile's doc comment: it stores no duration or
## explicit stop tick, so "every record has been consumed" is the one fact
## this class can report in its place. True before load() is ever called
## and again once a loaded replay runs out, matching
## ReplayRecorder.record_tick()'s tolerance for being called whether or not
## anything is active: there is nothing left to play, vacuously, in both
## cases.
func is_exhausted() -> bool:
	return not _loaded or _next_index >= _records.size()


func _describe_digest(digest: String) -> String:
	return ("\"%s\"" % digest) if not digest.is_empty() else "<empty, no snapshot>"
