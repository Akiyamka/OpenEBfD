class_name TurnScheduler
extends RefCounted

## Bridges a local SimCommandBus to a NetTransport with a fixed input delay.
## The bus decides the target tick for local commands; this class preserves
## that decision in its outer network frame so remote peers use submit_at()
## rather than deriving a new tick from their local delay setting.

const NetTransportScript := preload("res://scripts/net/net_transport.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")
const SimCommandScript := preload("res://scripts/sim/commands/sim_command.gd")

const _TICK_PREFIX_BYTES := 4

var _command_bus: SimCommandBus
var _transport: NetTransport
var _local_player_id: int
var _discarded_echo_count := 0
var _rejected_frame_count := 0


func _init(command_bus: SimCommandBus, transport: NetTransport, local_player_id: int) -> void:
	_command_bus = command_bus
	_transport = transport
	_local_player_id = local_player_id


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


## Polls every received frame once. A clean remote frame keeps the sender's
## target tick; an echoed local frame is deliberately discarded because the
## local submission already entered this client's command bus.
func advance_tick() -> void:
	for frame in _transport.poll():
		var decoded: Variant = _decode_frame(frame)
		if decoded == null:
			continue
		var command: SimCommand = decoded["command"]
		if command.player_id == _local_player_id:
			_discarded_echo_count += 1
			continue
		_command_bus.submit_at(command, int(decoded["target_tick"]))


func discarded_echo_count() -> int:
	return _discarded_echo_count


func rejected_frame_count() -> int:
	return _rejected_frame_count


func _encode_frame(target_tick: int, command: SimCommand) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u32(target_tick)
	buffer.put_data(SimCommandCodecScript.encode(command))
	return buffer.data_array


func _decode_frame(frame: PackedByteArray):
	if frame.size() < _TICK_PREFIX_BYTES:
		_rejected_frame_count += 1
		push_error(
			"TurnScheduler.advance_tick(): frame too short for the tick prefix (%d bytes)" % frame.size()
		)
		return null
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.data_array = frame
	var target_tick := buffer.get_u32()
	var command := SimCommandCodecScript.decode(buffer.get_data(buffer.get_available_bytes())[1])
	if command == null:
		_rejected_frame_count += 1
		push_error("TurnScheduler.advance_tick(): SimCommandCodec.decode() rejected the frame's command payload")
		return null
	return {"target_tick": target_tick, "command": command}
