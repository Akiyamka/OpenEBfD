class_name ReplayRecorder
extends RefCounted

## Turns "commands drained this tick" into a durable replay file, in step
## with the match rather than buffered until the end of it -- see
## docs/architecture/network-multiplayer.md, decision 10 and phase 2
## ("Replay recording and playback land here"). Not sim-zone code: it opens
## and writes a file, which tools/architecture_rules.toml's sim-no-node-api
## sibling rules exist to keep out of scripts/sim/ (see
## docs/architecture/network-multiplayer.md, "Rules for sim code"), so this
## lives under scripts/match/ beside MatchSnapshot
## (scripts/match/match_snapshot.gd), the other durable-file writer here.
##
## record_tick() is called from Match._advance_simulation_tick()
## (scripts/match/match.gd) with exactly what SimCommandBus.drain(tick)
## just returned, in that order and on that same call -- not a copy taken
## later, not requeued through anything. That is what makes "recorded
## order" and "executed order" the same fact instead of two facts a bug
## could let drift apart: this class never reorders, filters or delays
## what it is handed, it only serializes it.
##
## Appends one record at a time via ReplayFile.write_record()
## (scripts/match/replay_file.gd), which flushes on every call, rather than
## buffering the match in memory and writing it out at the end. A crash mid
## match is the case a replay is most useful for, and a recorder that only
## wrote on stop() would lose exactly that match.
##
## Recording is off by default and stays off unless something calls
## start() explicitly -- this slice adds the mechanism and its drain-point
## hook, not a way to turn it on from play. No UI exists for it yet, by
## design: see the phase 2 slice notes in
## docs/architecture/network-multiplayer.md. record_tick() is safe to call
## whether or not recording is active; it is a no-op when it is not, so
## Match's tick loop can call it unconditionally instead of guarding every
## call site on is_recording().

const ReplayFileScript := preload("res://scripts/match/replay_file.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")

var _file: FileAccess
var _recording := false


## Whether a replay is currently being written. Exposed for callers (tests,
## and eventually whatever UI or netcode flow gains the ability to toggle
## this) that need to know without reaching into this class's private state.
func is_recording() -> bool:
	return _recording


## Opens `path` for writing and immediately writes the file header, so the
## file is a valid, readable (if empty) replay from the moment start()
## returns rather than only once the match ends. `scene_path` and
## `snapshot_digest` are recorded as given -- see ReplayFile's doc comment
## for what snapshot_digest means and why an empty string is itself a
## pinned fact rather than a missing one. rng_seed and start_state are
## reserved and deliberately unused in this slice (see ReplayFile's doc
## comment): always written as 0 and an empty block.
##
## Returns a result Dictionary in the same {"ok": bool, "message": String}
## shape MatchSnapshot's own methods use (scripts/match/match_snapshot.gd),
## for the same reason: this is ordinary code called on request, not
## something anything needs to react to asynchronously.
func start(path: String, scene_path: String, snapshot_digest: String) -> Dictionary:
	if _recording:
		return {"ok": false, "message": "Already recording a replay"}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "message": "Cannot write %s (error %d)" % [path, FileAccess.get_open_error()]}
	ReplayFileScript.write_header(file, scene_path, snapshot_digest, 0, PackedByteArray())
	_file = file
	_recording = true
	return {"ok": true, "message": "Recording replay to %s" % path}


## Appends one record per command in `commands`, all scheduled at `tick`, in
## the order `commands` is given -- see this class's doc comment for why
## that order must be exactly SimCommandBus.drain(tick)'s return value and
## nothing else. A no-op when recording is not active, so Match's tick loop
## does not need to guard every call on is_recording() itself.
func record_tick(tick: int, commands: Array) -> void:
	if not _recording:
		return
	for command in commands:
		ReplayFileScript.write_record(_file, tick, SimCommandCodecScript.encode(command))


## Closes the file and turns recording off. A no-op when recording is not
## active, matching record_tick()'s tolerance so callers never need to
## check is_recording() before calling either.
func stop() -> void:
	if not _recording:
		return
	_file.close()
	_file = null
	_recording = false
