class_name ReplayFile
extends RefCounted

## Reads and writes the on-disk replay format: a versioned header describing
## the match, followed by the exact sequence of commands
## SimCommandBus.drain() (scripts/sim/command_bus.gd) handed to
## Match._advance_simulation_tick(), one record per command, in drain
## order. See docs/architecture/network-multiplayer.md, decision 10
## ("Replays as a command log... the primary tool for debugging desyncs")
## and phase 2 ("Replay recording and playback land here").
##
## This class only knows the byte format. ReplayRecorder
## (scripts/match/replay_recorder.gd) decides *when* to call write_header()
## and write_record() -- it lives under scripts/match/, not scripts/sim/,
## because it does file I/O, which the sim zone forbids (see
## tools/architecture_rules.toml, zones.sim). ReplayFile itself does file
## I/O too (write_header()/write_record() take an open FileAccess; read()
## opens one), which is exactly why it sits beside ReplayRecorder here
## rather than under scripts/sim/ alongside SimCommandCodec, even though its
## job -- a wire format -- rhymes with that class's.
##
## Wire format, all multi-byte fields big-endian, for the same reason
## SimCommandCodec (scripts/sim/command_codec.gd) gives: this is a format
## meant to outlive the process that wrote it -- a replay recorded today
## must still read back after an engine update, on a different platform, or
## years later -- and "whatever the platform's default endianness happens
## to be" is not something a durable format gets to inherit by accident.
## Every StreamPeerBuffer this class touches sets big_endian = true
## explicitly, never relying on the default.
##
##   magic            4 bytes, ASCII "OEBR"
##   format_version   u16
##   header_length    u32   -- byte length of the header block below, so a
##                              later format version can add fields after
##                              start_state without every reader needing to
##                              know their exact shape just to find where
##                              the header ends and the records begin
##     scene_path       u16 length + utf8
##     snapshot_digest  u16 length + utf8
##     rng_seed         s64
##     start_state      u32 length + bytes
##   then zero or more records, each:
##     tick             s32
##     payload_length   u32
##     payload          bytes, exactly SimCommandCodec.encode()'s output --
##                       this class never encodes or decodes a command
##                       itself, only stores and returns the opaque bytes.
##                       Reusing that codec verbatim, rather than a second
##                       one, is deliberate: see this class's design notes
##                       in the phase 2 replay slice -- one command encoding
##                       exists in this codebase, and this is not a second
##                       one.
##
## scene_path/snapshot_digest use a u16 length prefix, not u32 like
## SimCommand's own string fields (SimCommand._write_string_name(),
## scripts/sim/commands/sim_command.gd): both are short, bounded strings --
## a resource path or a hex digest -- never a value large enough that 65535
## bytes could matter, so the extra two header bytes u32 would cost on every
## replay are pure waste.
##
## snapshot_digest is FileAccess.get_sha256() of the bytes at
## Match._snapshot_storage_path() (scripts/match/match.gd), or the empty
## string when no such file exists at recording time. get_sha256() over
## HashingContext because it hashes a file by path in one call; the
## snapshot is a small JSON blob (see MatchSnapshot.save(),
## scripts/match/match_snapshot.gd), so there is no streaming-in-chunks case
## worth HashingContext's extra ceremony. Absence is itself a pinned fact,
## not a missing one: a replay recorded with no saved startup state must
## fail to play back against a match that has one, and comparing an empty
## string against a present digest is what makes that comparison fail
## rather than silently pass because both digests happened to be unset.
##
## rng_seed and start_state are reserved and deliberately unused in this
## slice: write_header() always receives 0 and an empty PackedByteArray from
## ReplayRecorder. There is no seed anywhere in this codebase yet -- every
## randi()/randf_range() call is global and unseeded, and making the
## simulation deterministic (a single seeded RandomNumberGenerator whose
## cursor is part of the state checksum) is phase 4's job, per "Layering" in
## docs/architecture/network-multiplayer.md. The fields are reserved now,
## ahead of that work, so phase 4 can fill them in without bumping
## format_version and stranding every replay recorded before it. Concretely
## today: a replay recorded now reproduces the command stream -- the same
## commands, on the same ticks, in the same order -- and nothing else.
## Anything downstream of unseeded RNG (impact debris timing, death voice
## line selection, and every other cosmetic draw) will *not* reproduce, and
## is not supposed to: the "Layering" section's RNG-split paragraph already
## draws that line -- the simulation owns one seeded generator whose cursor
## is part of the state checksum, while the view keeps using global
## randi()/randf() -- and this format just inherits it. (Decision 3 in the
## fork table is about the sim owning state, not about randomness; the split
## lives only in that paragraph until phase 4 implements it.)
##
## Truncated tails are tolerated, not rejected: a match that crashes mid-tick
## leaves the last record half-written, and that half-written replay is
## exactly the one someone most wants to read to see what led to the crash.
## read() stops at the first record it cannot fully parse and returns every
## record before it, with truncated = true. Bad magic, an unknown
## format_version, or a header that fails to parse are different failures --
## fail closed with a message, the way MatchSnapshot.restore()
## (scripts/match/match_snapshot.gd) does -- because those mean this is not
## a readable replay at all, not that it stopped partway through one.
##
## StreamPeerBuffer.get_data() does not error on a short read; it silently
## zero-pads the result up to the requested length (measured directly in
## this repo -- see SimCommand._read_string_name()'s comment,
## scripts/sim/commands/sim_command.gd, for the same finding). Every read in
## this class is guarded by get_available_bytes() before the get_* call that
## consumes it, exactly as SimCommandCodec and SimCommand already do, and
## for the identical reason: a missing guard would not error on a truncated
## file, it would fabricate plausible-looking bytes and hide the truncation
## instead of reporting it.

const MAGIC := "OEBR"
const FORMAT_VERSION := 1


## Appends the file header to `file`, which must already be open for
## writing at position 0. Called exactly once per replay, by
## ReplayRecorder.start() (scripts/match/replay_recorder.gd), before any
## write_record() call. Flushes before returning: the header is the part of
## the file read() depends on to make sense of anything else in it, so it
## must survive a crash that happens before the first record does.
static func write_header(
	file: FileAccess, scene_path: String, snapshot_digest: String, rng_seed: int, start_state: PackedByteArray
) -> void:
	var header_buffer := StreamPeerBuffer.new()
	header_buffer.big_endian = true
	_write_short_string(header_buffer, scene_path)
	_write_short_string(header_buffer, snapshot_digest)
	header_buffer.put_64(rng_seed)
	header_buffer.put_u32(start_state.size())
	header_buffer.put_data(start_state)
	var header_bytes := header_buffer.data_array

	var envelope := StreamPeerBuffer.new()
	envelope.big_endian = true
	envelope.put_data(MAGIC.to_utf8_buffer())
	envelope.put_u16(FORMAT_VERSION)
	envelope.put_u32(header_bytes.size())
	envelope.put_data(header_bytes)
	file.store_buffer(envelope.data_array)
	file.flush()


## Appends one record to `file`, which must already be open for writing and
## positioned at the end of whatever write_header()/write_record() calls
## came before it. `payload` is expected to be SimCommandCodec.encode()'s
## output verbatim -- this class does not look inside it. Flushes before
## returning, for the same reason write_header() does: ReplayRecorder
## appends one record per drained command as the match plays, and a crash
## between two records must still leave every record written so far intact
## and readable, not lost to a buffer this call never forced to disk.
static func write_record(file: FileAccess, tick: int, payload: PackedByteArray) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_32(tick)
	buffer.put_u32(payload.size())
	buffer.put_data(payload)
	file.store_buffer(buffer.data_array)
	file.flush()


## Reads the replay at `path` end to end and returns a result Dictionary --
## {"ok": bool, "message": String, ...} -- the same shape
## MatchSnapshot.save()/restore()/erase() use, and for the same reason: this
## is ordinary code reading a file on request, not something anything needs
## to react to asynchronously, so a signal would be the wrong tool.
##
## On success ("ok" == true) the Dictionary also carries "scene_path",
## "snapshot_digest", "rng_seed", "start_state", "records" (an Array of
## {"tick": int, "payload": PackedByteArray}, in file order) and
## "truncated" (true when the file ended mid-record and some trailing bytes
## had to be discarded -- see this class's doc comment on why that is
## tolerated rather than treated as failure).
##
## On failure ("ok" == false) only "message" is meaningful: bad magic, an
## unrecognized format_version, or a header that does not parse all fail
## this way, closed, rather than returning a partial result -- again see
## this class's doc comment for why those are a different case from a
## truncated tail.
static func read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failure("Replay file does not exist: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("Cannot open %s (error %d)" % [path, FileAccess.get_open_error()])
	var bytes := file.get_buffer(file.get_length())
	file.close()

	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.data_array = bytes

	var magic_length := MAGIC.to_utf8_buffer().size()
	if buffer.get_available_bytes() < magic_length:
		return _failure("File is too short to be a replay: %s" % path)
	var magic_bytes: PackedByteArray = buffer.get_data(magic_length)[1]
	if magic_bytes.get_string_from_ascii() != MAGIC:
		return _failure("Not a replay file (bad magic): %s" % path)

	if buffer.get_available_bytes() < 2:
		return _failure("Replay header is truncated (format_version): %s" % path)
	var format_version := buffer.get_u16()
	if format_version != FORMAT_VERSION:
		return _failure(
			"Unsupported replay format version %d (expected %d): %s" % [format_version, FORMAT_VERSION, path]
		)

	if buffer.get_available_bytes() < 4:
		return _failure("Replay header is truncated (header_length): %s" % path)
	var header_length := buffer.get_u32()
	if buffer.get_available_bytes() < header_length:
		return _failure("Replay header is truncated (header block): %s" % path)
	var header_bytes: PackedByteArray = buffer.get_data(header_length)[1]

	var header: Variant = _read_header_block(header_bytes)
	if header == null:
		return _failure("Replay header did not parse: %s" % path)

	var tail := _read_records(buffer)

	var result: Dictionary = header
	result["ok"] = true
	result["message"] = "Read %d record(s) from %s%s" % [
		(tail["records"] as Array).size(), path, " (truncated tail discarded)" if tail["truncated"] else ""
	]
	result["records"] = tail["records"]
	result["truncated"] = tail["truncated"]
	return result


## Parses the four known header fields out of `header_bytes` -- exactly the
## bytes write_header() placed between header_length and the first record --
## and returns them as a Dictionary, or null if any field fails to parse or
## bytes are left over once all four are read. Unlike _read_records()'s
## tolerance for a truncated tail, a header that does not parse cleanly
## fails read() closed entirely; see this class's doc comment for why the
## two cases are treated differently.
static func _read_header_block(header_bytes: PackedByteArray) -> Variant:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.data_array = header_bytes

	var scene_path: Variant = _read_short_string(buffer)
	if scene_path == null:
		return null
	var snapshot_digest: Variant = _read_short_string(buffer)
	if snapshot_digest == null:
		return null
	if buffer.get_available_bytes() < 8:
		return null
	var rng_seed := buffer.get_64()
	if buffer.get_available_bytes() < 4:
		return null
	var start_state_length := buffer.get_u32()
	if buffer.get_available_bytes() < start_state_length:
		return null
	var start_state: PackedByteArray = buffer.get_data(start_state_length)[1]
	if buffer.get_available_bytes() != 0:
		# format_version 1 defines the header as exactly these four fields;
		# leftover bytes here mean corruption, not a future field this
		# reader does not know about yet -- a reader that understands a
		# later format_version is the one that gets to treat header_length
		# as "skip past fields I don't recognize".
		return null

	return {
		"scene_path": scene_path,
		"snapshot_digest": snapshot_digest,
		"rng_seed": rng_seed,
		"start_state": start_state,
	}


## Reads records off `buffer` from its current position to the end,
## stopping at the first one that cannot be read in full. Returns
## {"records": Array, "truncated": bool}. Every field read is guarded by
## get_available_bytes() first -- see this class's doc comment on
## get_data()'s silent zero-padding -- so a file cut off at any byte offset
## inside the last record (before the tick, between tick and
## payload_length, or partway through the payload) is detected here rather
## than fabricating a record from zero-padded bytes.
static func _read_records(buffer: StreamPeerBuffer) -> Dictionary:
	var records: Array = []
	var truncated := false
	while true:
		if buffer.get_available_bytes() < 4:
			# Anything left at all (1-3 bytes) is a tick field cut short --
			# truncated. Exactly 0 bytes left is a clean end of file.
			truncated = buffer.get_available_bytes() > 0
			break
		var tick := buffer.get_32()
		if buffer.get_available_bytes() < 4:
			truncated = true
			break
		var payload_length := buffer.get_u32()
		if buffer.get_available_bytes() < payload_length:
			truncated = true
			break
		var payload: PackedByteArray = buffer.get_data(payload_length)[1]
		records.append({"tick": tick, "payload": payload})
	return {"records": records, "truncated": truncated}


## Shared header-field helper: writes `value` as a u16 UTF-8 byte-length
## prefix followed by its bytes -- see this class's doc comment for why u16
## rather than SimCommand's u32. The length is a byte count, not a
## character count, for the identical reason
## SimCommand._write_string_name() gives: UTF-8 is variable-width, and only
## the byte count says how many bytes the reader must actually consume.
static func _write_short_string(buffer: StreamPeerBuffer, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	buffer.put_u16(bytes.size())
	buffer.put_data(bytes)


## The inverse of _write_short_string(). Returns a String on success, or
## null -- checked by every caller -- when the buffer does not hold as many
## bytes as its own length prefix claims.
static func _read_short_string(buffer: StreamPeerBuffer) -> Variant:
	if buffer.get_available_bytes() < 2:
		return null
	var length := buffer.get_u16()
	if buffer.get_available_bytes() < length:
		return null
	var bytes: PackedByteArray = buffer.get_data(length)[1]
	return bytes.get_string_from_utf8()


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "message": message}
