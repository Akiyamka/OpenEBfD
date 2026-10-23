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
const SimRngScript := preload("res://scripts/sim/sim_rng.gd")

const _FRAME_DISCRIMINATOR_BYTES := 1
const _TICK_PREFIX_BYTES := 4
const _CHECKSUM_REPORT_BYTES := 12
const _PING_BYTES := 8
const _PONG_BYTES := 12
const _PRESENCE_BYTES := 4
const _HORIZON_BYTES := 8
const _COMMAND_DISCRIMINATOR := 0
const _CHECKSUM_REPORT_DISCRIMINATOR := 1
const _PING_DISCRIMINATOR := 2
const _PONG_DISCRIMINATOR := 3
const _HELLO_DISCRIMINATOR := 4
const _START_DISCRIMINATOR := 5
const _HORIZON_DISCRIMINATOR := 6
const MAX_LATE_DROP_LINES := 8

var _command_bus: SimCommandBus
var _transport: NetTransport
var _local_player_id: int
var _checksum_exchange: ChecksumExchangeScript
var _rtt_tracker: RttTrackerScript
var _discarded_echo_count := 0
var _discarded_command_echo_count := 0
var _rejected_frame_count := 0
var _last_remote_activity_tick_by_sender: Dictionary = {}
var _last_remote_activity_msec_by_sender: Dictionary = {}
var _gathering := false
var _expected_player_count := 0
var _hello_interval_msec := 0
var _last_hello_msec := -1
var _present_player_ids: Dictionary = {}
var _start_sent := false
var _start_proposal := 0
var _bound_start_seed := 0
var _protocol_fault := ""
var _held_frames: Array[PackedByteArray] = []
var _stashed_frames: Array[Dictionary] = []
var _late_drop_lines := PackedStringArray()
var _late_drop_count_by_sender: Dictionary = {}
var _turn_barrier_armed := false
var _turn_barrier_player_count := 0
var _keepalive_interval_msec := 0
var _known_horizon_by_sender: Dictionary = {}
var _sent_horizon := -1
var _now_msec := -1
var _wait_started_msec := -1
var _last_keepalive_msec := -1
var _waiting_player_ids: Array[int] = []


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
	var target_tick := (
		_command_bus.submit_at(
			command,
			maxi(current_tick + _command_bus.input_delay_ticks, _sent_horizon + 1)
		)
		if _turn_barrier_armed
		else _command_bus.submit(command, current_tick)
	)
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
	_start_proposal = 0
	_bound_start_seed = 0
	_protocol_fault = ""
	_held_frames.clear()
	_stashed_frames.clear()


func set_start_proposal(seed: int) -> void:
	if SimRngScript.valid_match_seed(seed):
		_start_proposal = seed


func bound_start_seed() -> int:
	return _bound_start_seed


func protocol_fault() -> String:
	return _protocol_fault


func _accept_start(seed: int) -> void:
	if _bound_start_seed != 0 and _bound_start_seed != seed:
		_protocol_fault = "Conflicting START seed %d (bound %d)" % [seed, _bound_start_seed]
		push_error(_protocol_fault)
		return
	_bound_start_seed = seed
	if not _gathering:
		return
	_gathering = false
	for held_frame in _held_frames:
		_transport.send(held_frame)
	_held_frames.clear()
	announce_horizon(0)


func begin_turn_barrier(expected_player_count: int, keepalive_interval_msec: int) -> void:
	_turn_barrier_armed = true
	_turn_barrier_player_count = expected_player_count
	_keepalive_interval_msec = keepalive_interval_msec
	_known_horizon_by_sender.clear()
	_sent_horizon = -1
	_now_msec = -1
	_wait_started_msec = -1
	_last_keepalive_msec = -1
	_waiting_player_ids.clear()
	_last_remote_activity_msec_by_sender.clear()


func announce_horizon(executed_tick: int) -> void:
	if not _turn_barrier_armed:
		return
	_sent_horizon = maxi(_sent_horizon, executed_tick + _command_bus.input_delay_ticks)
	_send_horizon(_sent_horizon)


func sent_horizon() -> int:
	return _sent_horizon


func known_horizon_for(sender_player_id: int) -> int:
	return int(_known_horizon_by_sender.get(sender_player_id, -1))


func peers_cover_tick(tick: int) -> bool:
	return not _turn_barrier_armed or _uncovered_player_ids(tick).is_empty()


func poll_turn_barrier(next_tick: int, now_msec: int) -> void:
	if not _turn_barrier_armed or _gathering:
		return
	_now_msec = now_msec
	_drain_frames(next_tick)
	_waiting_player_ids = _uncovered_player_ids(next_tick)
	if _waiting_player_ids.is_empty():
		_wait_started_msec = -1
		return
	if _wait_started_msec < 0:
		_wait_started_msec = now_msec
		_last_keepalive_msec = now_msec
	elif (
		_sent_horizon >= 0
		and now_msec - _last_keepalive_msec >= _keepalive_interval_msec
	):
		_send_horizon(_sent_horizon)
		_last_keepalive_msec = now_msec


func waiting_player_ids() -> Array[int]:
	return _waiting_player_ids.duplicate()


func turn_wait_msec() -> int:
	if _wait_started_msec < 0:
		return 0
	return _now_msec - _wait_started_msec


func wait_silence_msec_for(player_id: int) -> int:
	if not player_id in _waiting_player_ids:
		return 0
	return _now_msec - maxi(
		_wait_started_msec, int(_last_remote_activity_msec_by_sender.get(player_id, -1))
	)


func is_gathering() -> bool:
	return _gathering


func present_player_count() -> int:
	return _present_player_ids.size()


## Runs the pre-tick client-side start barrier. Wall-clock input is supplied by
## Match so this scheduler remains deterministic and directly testable.
func poll_gathering(now_msec: int) -> void:
	if not _gathering or not _protocol_fault.is_empty():
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
		elif decoded["kind"] == "start":
			_accept_start(int(decoded["seed"]))
		else:
			_stashed_frames.append(decoded)
	if (
		_gathering
		and _local_player_id == 1
		and not _start_sent
		and _start_proposal > 0
		and _present_player_ids.size() == _expected_player_count
	):
		_transport.send(_encode_start_frame(_start_proposal))
		_start_sent = true


## Checks post-release START frames before Match enters the next tick. Other
## frames stay queued for the ordinary tick drain and retain their target tick.
func poll_start_frames() -> void:
	if _gathering:
		return
	for frame in _transport.poll():
		var decoded: Variant = _decode_frame(frame)
		if decoded == null:
			continue
		if decoded["kind"] == "start":
			_accept_start(int(decoded["seed"]))
		else:
			_stashed_frames.append(decoded)


## Polls every received frame once. A clean remote frame records activity at
## the receiving client's current tick and keeps the sender's target tick; an
## echoed local frame is deliberately discarded because the local submission
## already entered this client's command bus.
func advance_tick(current_tick: int) -> void:
	_drain_frames(current_tick)


func _drain_frames(current_tick: int) -> void:
	for decoded in _stashed_frames:
		_handle_decoded_frame(decoded, current_tick)
	_stashed_frames.clear()
	for frame in _transport.poll():
		var decoded: Variant = _decode_frame(frame)
		if decoded == null:
			continue
		_handle_decoded_frame(decoded, current_tick)


func _handle_decoded_frame(decoded: Dictionary, current_tick: int) -> void:
	if decoded["kind"] == "start":
		_accept_start(int(decoded["seed"]))
		return
	if decoded["kind"] == "hello":
		return
	if decoded["kind"] == "horizon":
		_handle_horizon(decoded, current_tick)
		return
	if decoded["kind"] == "checksum_report":
		if int(decoded["sender_player_id"]) != _local_player_id:
			_credit_activity(int(decoded["sender_player_id"]), current_tick)
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
	_credit_activity(command.player_id, current_tick)
	var target_tick := int(decoded["target_tick"])
	var dropped_late_before := _command_bus.dropped_late_count()
	_command_bus.submit_at(command, target_tick)
	if _command_bus.dropped_late_count() > dropped_late_before:
		_late_drop_count_by_sender[command.player_id] = late_drop_count_for(command.player_id) + 1
		var line := "[desync] late drop: player %d %s for tick %d, refused at local tick %d" % [
			command.player_id, describe_command(command), target_tick, current_tick,
		]
		print(line)
		_late_drop_lines.append(line)
		while _late_drop_lines.size() > MAX_LATE_DROP_LINES:
			_late_drop_lines.remove_at(0)


func _handle_horizon(decoded: Dictionary, current_tick: int) -> void:
	var sender_player_id := int(decoded["sender_player_id"])
	if sender_player_id == _local_player_id:
		_discarded_echo_count += 1
		return
	_known_horizon_by_sender[sender_player_id] = maxi(
		known_horizon_for(sender_player_id), int(decoded["horizon"])
	)
	_credit_activity(sender_player_id, current_tick)


func _credit_activity(sender_player_id: int, current_tick: int) -> void:
	_last_remote_activity_tick_by_sender[sender_player_id] = current_tick
	_last_remote_activity_msec_by_sender[sender_player_id] = _now_msec


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


func late_drop_lines() -> PackedStringArray:
	return _late_drop_lines.duplicate()


func late_drop_count_for(sender_player_id: int) -> int:
	return int(_late_drop_count_by_sender.get(sender_player_id, 0))


static func describe_command(command: SimCommand) -> String:
	return "%s %08x" % [
		command.get_script().get_global_name(), _fnv1a32(SimCommandCodecScript.encode(command)),
	]


static func _fnv1a32(bytes: PackedByteArray, state: int = 2166136261) -> int:
	var result := state
	for byte in bytes:
		result = (result ^ byte) * 16777619 & 0xffffffff
	return result


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
			return _decode_start_frame(frame, buffer)
		_HORIZON_DISCRIMINATOR:
			return _decode_horizon_frame(frame, buffer)
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


func _decode_start_frame(frame: PackedByteArray, buffer: StreamPeerBuffer):
	if frame.size() != 13:
		_rejected_frame_count += 1
		push_error("TurnScheduler: START needs exactly 13 bytes")
		return null
	var sender := buffer.get_32()
	var seed := buffer.get_64()
	if sender != 1 or not SimRngScript.valid_match_seed(seed):
		_rejected_frame_count += 1
		push_error("TurnScheduler: invalid START sender or seed")
		return null
	return {"kind": "start", "sender_player_id": sender, "seed": seed}


func _decode_horizon_frame(frame: PackedByteArray, buffer: StreamPeerBuffer):
	if frame.size() < _FRAME_DISCRIMINATOR_BYTES + _HORIZON_BYTES:
		_rejected_frame_count += 1
		push_error(
			"TurnScheduler.advance_tick(): frame too short for the horizon (%d bytes)" % frame.size()
		)
		return null
	return {
		"kind": "horizon",
		"horizon": buffer.get_u32(),
		"sender_player_id": buffer.get_32(),
	}


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
	_credit_activity(int(decoded["sender_player_id"]), current_tick)
	_transport.send(
		_encode_pong_frame(int(decoded["tick"]), int(decoded["sender_player_id"]))
	)


func _handle_pong(decoded: Dictionary, current_tick: int) -> void:
	if int(decoded["sender_player_id"]) == _local_player_id:
		_discarded_echo_count += 1
		return
	_credit_activity(int(decoded["sender_player_id"]), current_tick)
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


func _encode_start_frame(seed: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u8(_START_DISCRIMINATOR)
	buffer.put_32(_local_player_id)
	buffer.put_64(seed)
	return buffer.data_array


func _send_horizon(horizon: int) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u8(_HORIZON_DISCRIMINATOR)
	buffer.put_u32(horizon)
	buffer.put_32(_local_player_id)
	_transport.send(buffer.data_array)


func _uncovered_player_ids(tick: int) -> Array[int]:
	var uncovered: Array[int] = []
	for player_id in range(1, _turn_barrier_player_count + 1):
		if player_id != _local_player_id and known_horizon_for(player_id) < tick:
			uncovered.append(player_id)
	return uncovered


func _encode_pong_frame(tick: int, ping_sender_player_id: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u8(_PONG_DISCRIMINATOR)
	buffer.put_u32(tick)
	buffer.put_32(ping_sender_player_id)
	buffer.put_32(_local_player_id)
	return buffer.data_array
