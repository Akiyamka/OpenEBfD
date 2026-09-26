class_name TurnScheduler
extends RefCounted

## Bridges a local SimCommandBus to a NetTransport with a fixed input delay.
## The bus decides the target tick for local commands; this class preserves
## that decision in its outer network frame so remote peers use submit_at()
## rather than deriving a new tick from their local delay setting.

const NetTransportScript := preload("res://scripts/net/net_transport.gd")
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")
const SimCommandScript := preload("res://scripts/sim/commands/sim_command.gd")

const _FRAME_DISCRIMINATOR_BYTES := 1
const _TICK_PREFIX_BYTES := 4
const _CHECKSUM_REPORT_BYTES := 12
const _COMMAND_DISCRIMINATOR := 0
const _CHECKSUM_REPORT_DISCRIMINATOR := 1

var _command_bus: SimCommandBus
var _transport: NetTransport
var _local_player_id: int
var _checksum_exchange: ChecksumExchangeScript
var _discarded_echo_count := 0
var _rejected_frame_count := 0
var _last_remote_activity_tick := -1


func _init(
	command_bus: SimCommandBus,
	transport: NetTransport,
	local_player_id: int,
	checksum_exchange: ChecksumExchangeScript = null
) -> void:
	_command_bus = command_bus
	_transport = transport
	_local_player_id = local_player_id
	_checksum_exchange = checksum_exchange


## Schedules a locally-originated command, then sends the bus-selected target
## tick and encoded command as one frame. Commands naming another player are
## rejected before either local queueing or transport delivery can occur.
func submit_local(command: SimCommand, current_tick: int) -> int:
	if command.player_id != _local_player_id:
		push_error(
			"TurnScheduler.submit_local(): command player %d does not match local player %d"
			% [command.player_id, _local_player_id]
		)
		return -1
	var target_tick := _command_bus.submit(command, current_tick)
	_transport.send(_encode_frame(target_tick, command))
	return target_tick


## Polls every received frame once. A clean remote frame records activity at
## the receiving client's current tick and keeps the sender's target tick; an
## echoed local frame is deliberately discarded because the local submission
## already entered this client's command bus.
func advance_tick(current_tick: int) -> void:
	for frame in _transport.poll():
		var decoded: Variant = _decode_frame(frame)
		if decoded == null:
			continue
		if decoded["kind"] == "checksum_report":
			if int(decoded["sender_player_id"]) != _local_player_id:
				_last_remote_activity_tick = current_tick
			_handle_checksum_report(decoded)
			continue
		var command: SimCommand = decoded["command"]
		if command.player_id == _local_player_id:
			_discarded_echo_count += 1
			continue
		_last_remote_activity_tick = current_tick
		_command_bus.submit_at(command, int(decoded["target_tick"]))


## Sends a per-tick state checksum over the scheduler-owned transport. Checksum
## frames are not commands, so they deliberately never enter the command bus.
func send_checksum_report(tick: int, state_hash: int) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u8(_CHECKSUM_REPORT_DISCRIMINATOR)
	buffer.put_u32(tick)
	buffer.put_32(_local_player_id)
	buffer.put_u32(state_hash)
	_transport.send(buffer.data_array)


func discarded_echo_count() -> int:
	return _discarded_echo_count


func rejected_frame_count() -> int:
	return _rejected_frame_count


## The receiving tick of the most recent successfully decoded remote frame,
## or -1 when no frame has yet established that the other player is active.
func last_remote_activity_tick() -> int:
	return _last_remote_activity_tick


func _encode_frame(target_tick: int, command: SimCommand) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u8(_COMMAND_DISCRIMINATOR)
	buffer.put_u32(target_tick)
	buffer.put_data(SimCommandCodecScript.encode(command))
	return buffer.data_array


func _decode_frame(frame: PackedByteArray):
	if frame.size() < _FRAME_DISCRIMINATOR_BYTES:
		_rejected_frame_count += 1
		push_error(
			"TurnScheduler.advance_tick(): frame too short for the discriminator byte (%d bytes)"
			% frame.size()
		)
		return null
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.data_array = frame
	var discriminator := buffer.get_u8()
	match discriminator:
		_COMMAND_DISCRIMINATOR:
			return _decode_command_frame(frame, buffer)
		_CHECKSUM_REPORT_DISCRIMINATOR:
			return _decode_checksum_report_frame(frame, buffer)
		_:
			_rejected_frame_count += 1
			push_error(
				"TurnScheduler.advance_tick(): unknown frame discriminator (%d)" % discriminator
			)
			return null


func _decode_command_frame(frame: PackedByteArray, buffer: StreamPeerBuffer):
	if frame.size() < _FRAME_DISCRIMINATOR_BYTES + _TICK_PREFIX_BYTES:
		_rejected_frame_count += 1
		push_error(
			"TurnScheduler.advance_tick(): frame too short for the tick prefix (%d bytes)" % frame.size()
		)
		return null
	var target_tick := buffer.get_u32()
	var command := SimCommandCodecScript.decode(buffer.get_data(buffer.get_available_bytes())[1])
	if command == null:
		_rejected_frame_count += 1
		push_error("TurnScheduler.advance_tick(): SimCommandCodec.decode() rejected the frame's command payload")
		return null
	return {"kind": "command", "target_tick": target_tick, "command": command}


func _decode_checksum_report_frame(frame: PackedByteArray, buffer: StreamPeerBuffer):
	if frame.size() < _FRAME_DISCRIMINATOR_BYTES + _CHECKSUM_REPORT_BYTES:
		_rejected_frame_count += 1
		push_error(
			"TurnScheduler.advance_tick(): frame too short for the checksum report (%d bytes)" % frame.size()
		)
		return null
	return {
		"kind": "checksum_report",
		"tick": buffer.get_u32(),
		"sender_player_id": buffer.get_32(),
		"state_hash": buffer.get_u32(),
	}


func _handle_checksum_report(decoded: Dictionary) -> void:
	if int(decoded["sender_player_id"]) == _local_player_id:
		_discarded_echo_count += 1
		return
	if _checksum_exchange == null:
		_rejected_frame_count += 1
		push_error("TurnScheduler.advance_tick(): received a checksum report with no ChecksumExchange configured")
		return
	_checksum_exchange.on_report_received(int(decoded["tick"]), int(decoded["state_hash"]))
