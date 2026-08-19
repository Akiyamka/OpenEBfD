class_name SimCommand
extends RefCounted

## Base for every serializable player intent that travels through the
## command bus (scripts/sim/command_bus.gd). See
## docs/architecture/network-multiplayer.md, decision 1 and the "Layering"
## section: only commands cross the wire, so every command type is a plain
## data struct living in the sim zone, with no Node reference and no
## behaviour of its own beyond carrying its fields -- resolving a command
## against the live world is CommandExecutor's job
## (scripts/match/command_executor.gd), deliberately outside this zone.
##
## Deliberately absent: the tick this command executes on. When a command
## runs is a scheduling fact the bus decides at submit time
## (current_tick + input_delay_ticks -- see SimCommandBus.submit()), not a
## property of the intent itself. Folding the tick into the command would let
## a bug -- or, once commands cross a real transport, a forged frame --
## carry a tick number that never passed through the bus's ordering and late
## detection at all; keeping it out is what keeps the bus the one place that
## decision is made.

## Which player issued this command. Every concrete command carries this
## regardless of what else it carries: SimCommandBus.drain() sorts its total
## order by player_id first (see that method for why the order must be
## total, not merely stable).
var player_id: int = 0


## Identifies the concrete command type for dispatch. CommandExecutor.execute()
## matches on this today; SimCommandCodec (scripts/sim/command_codec.gd)
## decodes a command's remaining fields by matching on the same number.
## Returns 0 in the base, which no concrete command ever returns -- every
## subclass overrides this to return its own TYPE_ID constant instead.
func type_id() -> int:
	return 0


## Writes this command's own fields -- everything beyond player_id, which
## SimCommandCodec's envelope carries directly -- onto `buffer` in whatever
## order read_payload() below expects them back. Every concrete command
## overrides both this and read_payload(); the two must stay exact inverses
## of each other, since SimCommandCodec.decode() calls this pair with no
## other way to know it got the order wrong. The base implementation writes
## nothing, matching type_id() == 0: no concrete command is ever this class
## directly, so this body never actually runs through the codec.
func write_payload(_buffer: StreamPeerBuffer) -> void:
	pass


## Reads this command's own fields from `buffer`, in the exact order
## write_payload() wrote them, and returns true on success. Returns false --
## never raises and never leaves this command half-populated -- on anything
## that does not look like this command's own payload, a truncated buffer
## being the case that matters most: decode() is the boundary a later phase
## exposes directly to a real network transport, and hostile or corrupt
## bytes have to fail closed here rather than produce a command with some
## fields written and others left at their defaults.
func read_payload(_buffer: StreamPeerBuffer) -> bool:
	return true


## Shared payload helper: writes a PackedInt32Array as a u32 count followed
## by that many signed 32-bit values. Every concrete command that carries a
## list of entity ids (SimStopCommand.entity_ids, SimMoveCommand.entity_ids,
## and, per docs/architecture/network-multiplayer.md phase 2, most of the
## dozen still to come) uses this identical layout, so it lives here once
## instead of being re-typed by hand in every override.
func _write_entity_ids(buffer: StreamPeerBuffer, ids: PackedInt32Array) -> void:
	buffer.put_u32(ids.size())
	for id in ids:
		buffer.put_32(id)


## The inverse of _write_entity_ids(). Returns a PackedInt32Array on success.
## Returns null -- checked for by every read_payload() override that calls
## this -- when the buffer does not hold as many ids as its own count prefix
## claims, which is the truncated/corrupt case this exists to fail closed on
## rather than let a runaway count prefix drive reads past the end of the
## buffer.
func _read_entity_ids(buffer: StreamPeerBuffer) -> Variant:
	if buffer.get_available_bytes() < 4:
		return null
	var count := buffer.get_u32()
	if buffer.get_available_bytes() < count * 4:
		return null
	var ids := PackedInt32Array()
	ids.resize(count)
	for i in count:
		ids[i] = buffer.get_32()
	return ids


## Shared payload helper: writes `value` as a u32 byte-length prefix followed
## by its UTF-8 bytes -- the same "count prefix, then that many payload
## bytes" shape _write_entity_ids() above uses, applied to the one field
## shape this project's commands have needed a string for so far
## (SimTargetAbilityCommand.ability_id, scripts/sim/commands/target_ability_command.gd).
## Deliberately hand-rolled rather than StreamPeerBuffer's own
## put_utf8_string()/get_utf8_string(): those exist, but read_payload()'s
## contract (see SimCommand's own doc comment) is to fail closed on a
## truncated buffer, which means validating the byte count against
## get_available_bytes() *before* consuming it, the same discipline
## _read_string_name() below applies and _read_entity_ids() above already
## does -- not trusting a built-in whose behaviour on a short buffer this
## class has not verified. The length is a byte count, not a character
## count: UTF-8 is variable-width, so a non-ASCII StringName's byte length
## and character length differ, and only the byte length says how many bytes
## read_payload() must actually consume.
func _write_string_name(buffer: StreamPeerBuffer, value: StringName) -> void:
	var bytes := String(value).to_utf8_buffer()
	buffer.put_u32(bytes.size())
	buffer.put_data(bytes)


## The inverse of _write_string_name(). Returns a StringName on success.
## Returns null -- checked for by every read_payload() override that calls
## this, exactly as _read_entity_ids() callers do -- when the buffer does not
## hold as many bytes as its own length prefix claims: StreamPeerBuffer.get_data()
## does not fail on a short read by itself (measured directly: asked for more
## bytes than were available and it silently zero-padded the result up to the
## requested length rather than erroring or truncating), so the length must
## be checked against get_available_bytes() before get_data() is ever called,
## not after.
func _read_string_name(buffer: StreamPeerBuffer) -> Variant:
	if buffer.get_available_bytes() < 4:
		return null
	var length := buffer.get_u32()
	if buffer.get_available_bytes() < length:
		return null
	var bytes: PackedByteArray = buffer.get_data(length)[1]
	return StringName(bytes.get_string_from_utf8())


## Shared payload helper: writes a Vector2i as two signed 32-bit values, x
## then y. Grid cells (SimPlaceBuildingCommand.nav_cell,
## scripts/sim/commands/place_building_command.gd, and the wall-line command
## the next slice adds) are integer nav-grid coordinates, not world positions
## -- SimMoveCommand.target is a Vector3 resolved by the local raycast at
## issue time (see that field's doc comment for why a view-resolved position
## still travels as plain data), while a nav cell is already the integer grid
## coordinate that raycast resolves down to, so it round-trips exactly with
## no float precision to lose and needs none of put_double()'s 8-byte cost
## per component.
func _write_cell(buffer: StreamPeerBuffer, value: Vector2i) -> void:
	buffer.put_32(value.x)
	buffer.put_32(value.y)


## The inverse of _write_cell(). Returns a Vector2i on success. Returns null
## -- checked for by every read_payload() override that calls this, exactly
## as _read_entity_ids() and _read_string_name() callers do -- when the
## buffer does not hold both 32-bit components.
func _read_cell(buffer: StreamPeerBuffer) -> Variant:
	if buffer.get_available_bytes() < 8:
		return null
	return Vector2i(buffer.get_32(), buffer.get_32())
