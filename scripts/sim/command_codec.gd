class_name SimCommandCodec
extends RefCounted

## Serializes a SimCommand (scripts/sim/commands/sim_command.gd) to and from
## the byte format that will one day cross a real network transport -- see
## docs/architecture/network-multiplayer.md, decision 1 ("only commands
## travel over the wire"), decision 5 (float64, no libm) and decision 6 (the
## transport interface this eventually feeds). Nothing sends these bytes
## anywhere yet: phase 2 only needs them to exist and round-trip, so a later
## phase's transport code has a stable format to hand off to instead of
## inventing one under deadline.
##
## Wire format, all multi-byte fields big-endian (see below for why that is
## pinned rather than left to a default):
##   envelope: u16 type_id, s32 player_id
##   payload:  command.write_payload()'s own bytes, opaque to this class
##
## type_id is unsigned because every concrete TYPE_ID is a small positive
## constant and 0 is reserved (see SimCommand.type_id()'s doc comment).
## player_id is signed because PlayerData.NEUTRAL_PLAYER_ID
## (scripts/players/player_data.gd) is -1 and has to round-trip like any
## other value, not be special-cased at the wire boundary.
##
## Byte order is set explicitly to big-endian on every StreamPeerBuffer this
## class touches, rather than left at GDScript's little-endian default. This
## is a wire format, not an in-process implementation detail: a native
## client and a web client will eventually sit at each end of it (decision
## 2), and "whatever the platform's default happens to be" is not something
## a network protocol gets to inherit by accident.
##
## Every float this class or a command's payload puts on the wire is a
## float64 (StreamPeerBuffer.put_double()/get_double()), never a float32.
## Decision 5's determinism guarantee rests on IEEE-754 bit-identical
## float64 arithmetic; narrowing a position to 32 bits here would throw that
## away at the one point -- the wire -- where a client has no way to recover
## the bits it lost.
##
## decode() is the boundary a later phase exposes directly to the network,
## so it fails closed rather than trusts its input: an unknown type id, a
## truncated buffer, or a payload that does not match its declared type
## (including trailing bytes the payload never consumed) all return null.
## It never raises and never hands back a half-built command.
##
## The type-id-to-script table below is hand-written and exhaustive, on
## purpose. ProjectSettings.get_global_class_list() could rebuild it at
## runtime instead, by filtering scripts under scripts/sim/commands/ whose
## base is SimCommand -- tests/sim/command_codec_run.gd does exactly that,
## to prove this table stays honest -- but this class does not, because that
## API's behaviour in an exported build is unverified, and a shipped game
## that cannot decode a command is not a risk worth taking for tidiness.
## Forgetting to add a new command type here is caught by that test, not by
## trying to be clever at runtime.

const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")

## Every concrete command type, by its TYPE_ID. Add an entry here in the same
## change that adds a new SimCommand subclass under scripts/sim/commands/ --
## tests/sim/command_codec_run.gd fails loudly, naming the missing type, if
## an entry is forgotten, and just as loudly if two types collide on the
## same TYPE_ID.
const _COMMAND_SCRIPTS := {
	SimStopCommandScript.TYPE_ID: SimStopCommandScript,
	SimMoveCommandScript.TYPE_ID: SimMoveCommandScript,
}

const _ENVELOPE_SIZE := 6  ## u16 type_id (2 bytes) + s32 player_id (4 bytes)


## Encodes `command`'s envelope (type_id, player_id) followed by its own
## write_payload() bytes.
static func encode(command: SimCommand) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u16(command.type_id())
	buffer.put_32(command.player_id)
	command.write_payload(buffer)
	return buffer.data_array


## Decodes `bytes` back into the concrete SimCommand its envelope names, or
## returns null on anything malformed -- see this class's doc comment for
## the exact cases. Never crashes and never returns a half-constructed
## command.
static func decode(bytes: PackedByteArray) -> SimCommand:
	if bytes.size() < _ENVELOPE_SIZE:
		return null
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.data_array = bytes
	var type_id := buffer.get_u16()
	var player_id := buffer.get_32()
	if not _COMMAND_SCRIPTS.has(type_id):
		return null
	var script: GDScript = _COMMAND_SCRIPTS[type_id]
	var command: SimCommand = script.new()
	command.player_id = player_id
	if not command.read_payload(buffer):
		return null
	# A payload that under- or over-reads relative to what write_payload()
	# wrote is a mismatch between the declared type and the bytes -- the
	# "payload that does not match its declared type" case from this
	# class's doc comment.
	if buffer.get_available_bytes() != 0:
		return null
	return command
