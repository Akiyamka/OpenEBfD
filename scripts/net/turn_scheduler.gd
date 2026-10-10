class_name TurnScheduler
extends RefCounted

## Bridges a local SimCommandBus to a NetTransport, whatever input delay that
## bus is currently running. The bus decides the target tick for local
## commands; this class preserves that decision in its outer network frame so
## remote peers use submit_at() rather than deriving a new tick from their own
## delay setting. That is load-bearing rather than tidy since Z1 made the delay
## adaptive per client: two clients legitimately run different delays, and
## honouring the sender's absolute tick is what keeps that from desyncing them.

const NetTransportScript := preload("res://scripts/net/net_transport.gd")
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const RttTrackerScript := preload("res://scripts/net/rtt_tracker.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")
const SimCommandScript := preload("res://scripts/sim/commands/sim_command.gd")

const _FRAME_DISCRIMINATOR_BYTES := 1
const _TICK_PREFIX_BYTES := 4
const _CHECKSUM_REPORT_BYTES := 12
const _PING_BYTES := 8
const _PONG_BYTES := 12
const _PRESENCE_BYTES := 4
const _COMMAND_DISCRIMINATOR := 0
const _CHECKSUM_REPORT_DISCRIMINATOR := 1
const _PING_DISCRIMINATOR := 2
const _PONG_DISCRIMINATOR := 3
const _HELLO_DISCRIMINATOR := 4
const _START_DISCRIMINATOR := 5

var _command_bus: SimCommandBus
var _transport: NetTransport
var _local_player_id: int
var _checksum_exchange: ChecksumExchangeScript
var _rtt_tracker: RttTrackerScript
var _discarded_echo_count := 0
var _discarded_command_echo_count := 0
var _rejected_frame_count := 0
var _last_remote_activity_tick_by_sender: Dictionary = {}
var _gathering := false
var _expected_player_count := 0
var _hello_interval_msec := 0
var _last_hello_msec := -1
var _present_player_ids: Dictionary = {}
var _start_sent := false
var _held_frames: Array[PackedByteArray] = []
var _stashed_frames: Array[Dictionary] = []


func _init(
	command_bus: SimCommandBus,
	transport: NetTransport,
	local_player_id: int,
	checksum_exchange: ChecksumExchangeScript = null,
	rtt_tracker: RttTrackerScript = null
) -> void:
	_command_bus = command_bus
	_transport = transport
	_local_player_id = local_player_id
	_checksum_exchange = checksum_exchange
	_rtt_tracker = rtt_tracker


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
	var frame := _encode_frame(target_tick, command)
	if _gathering:
		_held_frames.append(frame)
	else:
		_transport.send(frame)
	return target_tick


func begin_gathering(expected_player_count: int, hello_interval_msec: int) -> void:
	_gathering = true
	_expected_player_count = expected_player_count
	_hello_interval_msec = hello_interval_msec
	_last_hello_msec = -1
	_present_player_ids.clear()
	_start_sent = false
	_held_frames.clear()
	_stashed_frames.clear()


func is_gathering() -> bool:
	return _gathering


func present_player_count() -> int:
	return _present_player_ids.size()


## Runs the pre-tick client-side start barrier. Wall-clock input is supplied by
## Match so this scheduler remains deterministic and directly testable.
func poll_gathering(now_msec: int) -> void:
	if not _gathering:
		return
	if (
		_transport.state() == NetTransportScript.State.CONNECTED
		and (_last_hello_msec < 0 or now_msec - _last_hello_msec >= _hello_interval_msec)
	):
		_transport.send(_encode_presence_frame(_HELLO_DISCRIMINATOR))
		_last_hello_msec = now_msec
	for frame in _transport.poll():
		var decoded: Variant = _decode_frame(frame)
		if decoded == null:
			continue
		if _gathering and decoded["kind"] == "hello":
			var hello_player_id := int(decoded["sender_player_id"])
			if hello_player_id >= 1 and hello_player_id <= _expected_player_count:
				_present_player_ids[hello_player_id] = true
		elif _gathering and decoded["kind"] == "start":
			_gathering = false
			for held_frame in _held_frames:
				_transport.send(held_frame)
			_held_frames.clear()
		else:
			_stashed_frames.append(decoded)
	if (
		_gathering
		and _local_player_id == 1
		and not _start_sent
		and _present_player_ids.size() == _expected_player_count
	):
		_transport.send(_encode_presence_frame(_START_DISCRIMINATOR))
		_start_sent = true


## Polls every received frame once. A clean remote frame records activity at
## the receiving client's current tick and keeps the sender's target tick; an
## echoed local frame is deliberately discarded because the local submission
## already entered this client's command bus.
func advance_tick(current_tick: int) -> void:
	for decoded in _stashed_frames:
		_handle_decoded_frame(decoded, current_tick)
	_stashed_frames.clear()
	for frame in _transport.poll():
		var decoded: Variant = _decode_frame(frame)
		if decoded == null:
			continue
		_handle_decoded_frame(decoded, current_tick)


func _handle_decoded_frame(decoded: Dictionary, current_tick: int) -> void:
	if decoded["kind"] == "hello" or decoded["kind"] == "start":
		return
	if decoded["kind"] == "checksum_report":
		if int(decoded["sender_player_id"]) != _local_player_id:
			_last_remote_activity_tick_by_sender[int(decoded["sender_player_id"])] = current_tick
		_handle_checksum_report(decoded)
		return
	if decoded["kind"] == "ping":
		_handle_ping(decoded, current_tick)
		return
	if decoded["kind"] == "pong":
		_handle_pong(decoded, current_tick)
		return
	var command: SimCommand = decoded["command"]
	if command.player_id == _local_player_id:
		_discarded_echo_count += 1
		_discarded_command_echo_count += 1
		return
	_last_remote_activity_tick_by_sender[command.player_id] = current_tick
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


## Sends a ping that lets a remote peer return the sending tick unchanged.
func send_ping(current_tick: int) -> void:
	_transport.send(_encode_ping_pong_frame(_PING_DISCRIMINATOR, current_tick))


func discarded_echo_count() -> int:
	return _discarded_echo_count


func discarded_command_echo_count() -> int:
	return _discarded_command_echo_count


func rejected_frame_count() -> int:
	return _rejected_frame_count


## The receiving tick of the newest successfully decoded remote frame across
## all senders, or -1 when no remote player has established activity. Use
## last_remote_activity_tick_for() when attribution to one sender matters.
func last_remote_activity_tick() -> int:
	var newest_tick := -1
	for activity_tick in _last_remote_activity_tick_by_sender.values():
		newest_tick = max(newest_tick, int(activity_tick))
	return newest_tick


## The receiving tick of sender_player_id's most recent successfully decoded
## remote frame, or -1 when that sender has never established activity.
func last_remote_activity_tick_for(sender_player_id: int) -> int:
	return int(_last_remote_activity_tick_by_sender.get(sender_player_id, -1))


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
		_PING_DISCRIMINATOR:
			return _decode_ping_frame(frame, buffer)
		_PONG_DISCRIMINATOR:
			return _decode_pong_frame(frame, buffer)
		_HELLO_DISCRIMINATOR:
			return _decode_presence_frame(frame, buffer, "hello")
		_START_DISCRIMINATOR:
			return _decode_presence_frame(frame, buffer, "start")
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


func _decode_ping_frame(frame: PackedByteArray, buffer: StreamPeerBuffer):
	if frame.size() < _FRAME_DISCRIMINATOR_BYTES + _PING_BYTES:
		_rejected_frame_count += 1
		push_error(
			"TurnScheduler.advance_tick(): frame too short for the ping (%d bytes)" % frame.size()
		)
		return null
	return {
		"kind": "ping",
		"tick": buffer.get_u32(),
		"sender_player_id": buffer.get_32(),
	}


func _decode_pong_frame(frame: PackedByteArray, buffer: StreamPeerBuffer):
	if frame.size() < _FRAME_DISCRIMINATOR_BYTES + _PONG_BYTES:
		_rejected_frame_count += 1
		push_error(
			"TurnScheduler.advance_tick(): frame too short for the pong (%d bytes)" % frame.size()
		)
		return null
	return {
		"kind": "pong",
		"tick": buffer.get_u32(),
		"ping_sender_player_id": buffer.get_32(),
		"sender_player_id": buffer.get_32(),
	}


func _decode_presence_frame(frame: PackedByteArray, buffer: StreamPeerBuffer, kind: String):
	if frame.size() < _FRAME_DISCRIMINATOR_BYTES + _PRESENCE_BYTES:
		_rejected_frame_count += 1
		push_error(
			"TurnScheduler.advance_tick(): frame too short for the %s (%d bytes)" % [kind, frame.size()]
		)
		return null
	return {"kind": kind, "sender_player_id": buffer.get_32()}


func _handle_checksum_report(decoded: Dictionary) -> void:
	if int(decoded["sender_player_id"]) == _local_player_id:
		_discarded_echo_count += 1
		return
	if _checksum_exchange == null:
		_rejected_frame_count += 1
		push_error("TurnScheduler.advance_tick(): received a checksum report with no ChecksumExchange configured")
		return
	_checksum_exchange.on_report_received(
		int(decoded["sender_player_id"]), int(decoded["tick"]), int(decoded["state_hash"])
	)


func _handle_ping(decoded: Dictionary, current_tick: int) -> void:
	if int(decoded["sender_player_id"]) == _local_player_id:
		_discarded_echo_count += 1
		return
	_last_remote_activity_tick_by_sender[int(decoded["sender_player_id"])] = current_tick
	_transport.send(
		_encode_pong_frame(int(decoded["tick"]), int(decoded["sender_player_id"]))
	)


func _handle_pong(decoded: Dictionary, current_tick: int) -> void:
	if int(decoded["sender_player_id"]) == _local_player_id:
		_discarded_echo_count += 1
		return
	_last_remote_activity_tick_by_sender[int(decoded["sender_player_id"])] = current_tick
	if int(decoded["ping_sender_player_id"]) != _local_player_id:
		return
	if _rtt_tracker == null:
		_rejected_frame_count += 1
		push_error("TurnScheduler.advance_tick(): received a pong with no RttTracker configured")
		return
	_rtt_tracker.on_pong_received(
		int(decoded["sender_player_id"]), current_tick - int(decoded["tick"])
	)


func _encode_ping_pong_frame(discriminator: int, tick: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u8(discriminator)
	buffer.put_u32(tick)
	buffer.put_32(_local_player_id)
	return buffer.data_array


func _encode_presence_frame(discriminator: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u8(discriminator)
	buffer.put_32(_local_player_id)
	return buffer.data_array


func _encode_pong_frame(tick: int, ping_sender_player_id: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u8(_PONG_DISCRIMINATOR)
	buffer.put_u32(tick)
	buffer.put_32(ping_sender_player_id)
	buffer.put_32(_local_player_id)
	return buffer.data_array
