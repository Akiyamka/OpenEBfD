extends "res://tests/support/suite.gd"

## WebSocket-specific behaviour of WebSocketTransport
## (res://scripts/net/websocket_transport.gd): connecting through a real,
## in-process RelayServer over real loopback sockets, the state mapping from
## WebSocketPeer.get_ready_state() and the relay's close codes, and the
## failure-to-connect path. Assertions that must hold for *every*
## NetTransport implementation (fan-out-to-self, poll() draining, the
## before-open/after-close no-ops, close() idempotency) live in
## tests/net/transport_conformance.gd and are run here too (see
## _test_conformance_suite below), not duplicated -- see that file's doc
## comment for why.
##
## Same bounded-pump discipline as tests/net/relay_run.gd: every wait goes
## through _pump_until() below -- a hard iteration cap *and* a wall-clock
## cap, and a named failure instead of an unbounded `while` that would just
## hang. Ports are well away from the relay's default (8910) and from every
## port tests/net/relay_run.gd already claims (18910-18913), and a bind
## failure at startup is reported by name rather than left to time out.

const RelayServerScript := preload("res://scripts/net/relay/relay_server.gd")
const WebSocketTransportScript := preload("res://scripts/net/websocket_transport.gd")
const NetTransportScript := preload("res://scripts/net/net_transport.gd")
const RelayProtocolScript := preload("res://scripts/net/relay_protocol.gd")
const TransportConformanceScript := preload("res://tests/net/transport_conformance.gd")

const TEST_PORT := 18920
## The room-capacity case needs its own server with a non-default
## max_room_size, same reasoning as relay_run.gd's CAPACITY_TEST_PORT.
const CAPACITY_TEST_PORT := 18921
## Nothing ever listens here -- this port exists only to be unreachable, for
## the "host cannot be reached at all" case.
const UNREACHABLE_PORT := 18922

const MAX_PUMP_ITERATIONS := 5000
const MAX_PUMP_SECONDS := 5.0
const PUMP_SLEEP_MSEC := 2

var _server: RelayServerScript

## Set by the three rejection-reason cases below and compared for pairwise
## distinctness in _test_rejection_reasons_are_distinct -- mirrors
## relay_run.gd's own _test_rejection_close_codes_are_distinct, one layer up
## at the transport's last_error() instead of the raw close code.
var _no_room_code_error := ""
var _invalid_room_code_error := ""
var _room_full_error := ""


func _initialize() -> void:
	_server = RelayServerScript.new()
	var err := _server.start(TEST_PORT)
	if err != OK:
		printerr(
			(
				"websocket transport tests: could not bind port %d (%s) -- another process (maybe a "
				+ "relay left running from a previous session) is already listening on it; free the "
				+ "port or change TEST_PORT in tests/net/websocket_transport_run.gd and rerun"
			)
			% [TEST_PORT, error_string(err)]
		)
		quit(1)
		return

	_run_case(
		"shared NetTransport conformance suite holds for WebSocketTransport over a real relay",
		_test_conformance_suite
	)
	_run_case(
		"two transports in one room exchange payloads, and each also receives its own",
		_test_two_transports_exchange_and_self_receive
	)
	_run_case(
		"a third transport joining a full room ends FAILED naming the room being full; the first two keep working",
		_test_room_full_ends_failed
	)
	_run_case("an invalid room code ends FAILED, distinguishable from room-full", _test_invalid_room_code_ends_failed)
	_run_case("no room code in the URL ends FAILED, distinguishable from both", _test_no_room_code_ends_failed)
	_run_case(
		"connecting to a port with nothing listening ends FAILED, bounded, with a useful last_error()",
		_test_unreachable_port_ends_failed
	)
	_run_case(
		"the three rejection reasons are distinguishable from each other by last_error() alone",
		_test_rejection_reasons_are_distinct
	)
	_run_case(
		"state() never leaves its documented progression: never CONNECTED before the handshake, never back to CONNECTING",
		_test_state_progression_invariants
	)
	_run_case(
		"a payload exactly at the protocol frame limit is still delivered",
		_test_payload_at_frame_limit_is_delivered
	)
	_run_case(
		"a payload one byte over the frame limit is refused locally, with a clear error, and never reaches the relay",
		_test_payload_one_byte_over_limit_is_refused_locally
	)
	_run_case(
		"a payload far above the local outbound buffer (65536) fails identically to one byte over the limit, not silently",
		_test_payload_far_over_local_buffer_behaves_like_one_byte_over
	)

	_server.stop()
	_finish("WebSocket transport tests")


func _test_conformance_suite() -> void:
	var room_code := "conformance-room"
	var port := TEST_PORT
	var make_transport := func(): return WebSocketTransportScript.new()
	var open_transport := func(transport): transport.open("ws://127.0.0.1:%d/%s" % [port, room_code])
	var pump := func(): _server.poll()
	TransportConformanceScript.run(Callable(self, "_expect"), make_transport, open_transport, pump, MAX_PUMP_ITERATIONS)


func _test_two_transports_exchange_and_self_receive() -> void:
	var room_code := "exchange-room"
	var a := WebSocketTransportScript.new()
	var b := WebSocketTransportScript.new()
	a.open("ws://127.0.0.1:%d/%s" % [TEST_PORT, room_code])
	b.open("ws://127.0.0.1:%d/%s" % [TEST_PORT, room_code])

	_pump_until(
		_server, "both transports reach CONNECTED",
		func() -> bool:
			return a.state() == NetTransportScript.State.CONNECTED and b.state() == NetTransportScript.State.CONNECTED,
		func() -> void:
			a.poll()
			b.poll()
	)

	a.send("hello-from-a".to_utf8_buffer())
	var a_inbox: Array[PackedByteArray] = []
	var b_inbox: Array[PackedByteArray] = []
	_pump_until(
		_server, "both a (the sender) and b receive a's payload",
		func() -> bool: return not a_inbox.is_empty() and not b_inbox.is_empty(),
		func() -> void:
			a_inbox.append_array(a.poll())
			b_inbox.append_array(b.poll())
	)

	_expect(
		a_inbox.size() >= 1 and a_inbox[0].get_string_from_utf8() == "hello-from-a",
		"the sender must receive its own frame"
	)
	_expect(
		b_inbox.size() >= 1 and b_inbox[0].get_string_from_utf8() == "hello-from-a",
		"the peer must receive the sender's frame"
	)

	a.close()
	b.close()


func _test_room_full_ends_failed() -> void:
	var server := RelayServerScript.new()
	server.max_room_size = 2
	var err := server.start(CAPACITY_TEST_PORT)
	if err != OK:
		_expect(
			false,
			"could not bind test port %d (%s) -- another process may already be listening on it"
			% [CAPACITY_TEST_PORT, error_string(err)]
		)
		return

	var room_code := "cap-room"
	var a := WebSocketTransportScript.new()
	var b := WebSocketTransportScript.new()
	a.open("ws://127.0.0.1:%d/%s" % [CAPACITY_TEST_PORT, room_code])
	b.open("ws://127.0.0.1:%d/%s" % [CAPACITY_TEST_PORT, room_code])
	_pump_until(
		server, "both a and b reach CONNECTED",
		func() -> bool:
			return a.state() == NetTransportScript.State.CONNECTED and b.state() == NetTransportScript.State.CONNECTED,
		func() -> void:
			a.poll()
			b.poll()
	)

	var c := WebSocketTransportScript.new()
	c.open("ws://127.0.0.1:%d/%s" % [CAPACITY_TEST_PORT, room_code])
	_pump_until(
		server, "the third transport to the full room ends FAILED",
		func() -> bool: return c.state() == NetTransportScript.State.FAILED,
		func() -> void: c.poll()
	)
	_room_full_error = c.last_error()
	_expect(
		_room_full_error == RelayProtocolScript.describe_close_code(RelayProtocolScript.CLOSE_ROOM_FULL),
		"a full room's last_error() must be derived from relay_protocol.gd and name the room being full: got '%s'"
		% _room_full_error
	)

	a.send("still-works".to_utf8_buffer())
	var a_inbox: Array[PackedByteArray] = []
	var b_inbox: Array[PackedByteArray] = []
	_pump_until(
		server, "the first two transports keep exchanging frames after the rejection",
		func() -> bool: return not a_inbox.is_empty() and not b_inbox.is_empty(),
		func() -> void:
			a_inbox.append_array(a.poll())
			b_inbox.append_array(b.poll())
	)
	_expect(
		a_inbox.size() >= 1 and a_inbox[0].get_string_from_utf8() == "still-works",
		"the sender must still receive its own frame after the third transport was rejected"
	)
	_expect(
		b_inbox.size() >= 1 and b_inbox[0].get_string_from_utf8() == "still-works",
		"the surviving peer must still receive frames after the third transport was rejected"
	)

	a.close()
	b.close()
	server.stop()


func _test_invalid_room_code_ends_failed() -> void:
	var t := WebSocketTransportScript.new()
	t.open("ws://127.0.0.1:%d/not-valid!" % TEST_PORT)
	_pump_until(
		_server, "an invalid room code ends FAILED",
		func() -> bool: return t.state() == NetTransportScript.State.FAILED,
		func() -> void: t.poll()
	)
	_invalid_room_code_error = t.last_error()
	_expect(
		_invalid_room_code_error == RelayProtocolScript.describe_close_code(RelayProtocolScript.CLOSE_INVALID_ROOM_CODE),
		"an invalid room code's last_error() must be derived from relay_protocol.gd: got '%s'" % _invalid_room_code_error
	)


func _test_no_room_code_ends_failed() -> void:
	var t := WebSocketTransportScript.new()
	t.open("ws://127.0.0.1:%d/" % TEST_PORT)
	_pump_until(
		_server, "a URL with no room code ends FAILED",
		func() -> bool: return t.state() == NetTransportScript.State.FAILED,
		func() -> void: t.poll()
	)
	_no_room_code_error = t.last_error()
	_expect(
		_no_room_code_error == RelayProtocolScript.describe_close_code(RelayProtocolScript.CLOSE_NO_ROOM_CODE),
		"a missing room code's last_error() must be derived from relay_protocol.gd: got '%s'" % _no_room_code_error
	)


func _test_rejection_reasons_are_distinct() -> void:
	_expect(_no_room_code_error != "", "setup: the no-room-code case must have run and recorded an error")
	_expect(_invalid_room_code_error != "", "setup: the invalid-room-code case must have run and recorded an error")
	_expect(_room_full_error != "", "setup: the room-full case must have run and recorded an error")
	_expect(
		_no_room_code_error != _invalid_room_code_error
		and _invalid_room_code_error != _room_full_error
		and _no_room_code_error != _room_full_error,
		"the three rejection reasons must be distinguishable from each other by last_error() alone"
	)


func _test_unreachable_port_ends_failed() -> void:
	var t := WebSocketTransportScript.new()
	t.open("ws://127.0.0.1:%d/whatever" % UNREACHABLE_PORT)
	_pump_until(
		_server, "a connection to a port with nothing listening ends FAILED",
		func() -> bool: return t.state() == NetTransportScript.State.FAILED,
		func() -> void: t.poll()
	)
	_expect(t.last_error() != "", "last_error() must be non-empty when the host cannot be reached at all")


## Regression guard for the state machine itself, not any one connection
## outcome: samples state() on every pumped tick of a normal, successful
## connection and asserts on what must never happen (see the class doc
## comment) rather than trying to catch CONNECTING mid-race -- (1) the very
## first observed state, before poll() has run even once, must be CONNECTING
## and never CONNECTED (the handshake cannot be reported done before it has
## even been polled), and (2) once CONNECTED has been observed, CONNECTING
## must never be observed again.
func _test_state_progression_invariants() -> void:
	var t := WebSocketTransportScript.new()
	t.open("ws://127.0.0.1:%d/state-room" % TEST_PORT)
	_expect(
		t.state() == NetTransportScript.State.CONNECTING,
		"state() must be CONNECTING immediately after open(), before poll() has ever run"
	)

	var seen_connected := false
	var reached_terminal := false
	var start_msec := Time.get_ticks_msec()
	for i in range(MAX_PUMP_ITERATIONS):
		_server.poll()
		t.poll()
		var current := t.state()
		if current == NetTransportScript.State.CONNECTED:
			seen_connected = true
		elif current == NetTransportScript.State.CONNECTING and seen_connected:
			_expect(false, "state() must never return to CONNECTING once it has reached CONNECTED")
		if seen_connected:
			reached_terminal = true
			break
		if Time.get_ticks_msec() - start_msec > MAX_PUMP_SECONDS * 1000.0:
			break
		OS.delay_msec(PUMP_SLEEP_MSEC)

	_expect(reached_terminal, "a connection to a valid room must eventually reach CONNECTED within the pump bound")
	t.close()


## Regression coverage for the frame-size defect: a real relay caps inbound
## frames at RelayProtocol.MAX_INBOUND_FRAME_BYTES (see relay_protocol.gd),
## and a payload exactly at that cap is the boundary that must still go
## through -- see websocket_transport.gd's send(), which only rejects
## payloads strictly *larger* than the limit. Sent through a real relay and
## read back via fan-out-to-self, byte for byte.
func _test_payload_at_frame_limit_is_delivered() -> void:
	var room_code := "frame-limit-room"
	var a := WebSocketTransportScript.new()
	a.open("ws://127.0.0.1:%d/%s" % [TEST_PORT, room_code])
	_pump_until(
		_server, "transport reaches CONNECTED for the at-limit payload case",
		func() -> bool: return a.state() == NetTransportScript.State.CONNECTED,
		func() -> void: a.poll()
	)

	var payload := PackedByteArray()
	payload.resize(RelayProtocolScript.MAX_INBOUND_FRAME_BYTES)
	for i in range(payload.size()):
		payload[i] = i % 256
	a.send(payload)

	var received: Array[PackedByteArray] = []
	_pump_until(
		_server, "a payload exactly at the frame limit is delivered back to the sender",
		func() -> bool: return not received.is_empty(),
		func() -> void: received.append_array(a.poll())
	)
	_expect(
		a.state() == NetTransportScript.State.CONNECTED,
		"a payload exactly at the frame limit must not fail the transport"
	)
	_expect(
		received.size() >= 1 and received[0] == payload,
		"a payload exactly at the frame limit must arrive byte-for-byte"
	)

	a.close()


## The defect this whole case-trio pins down, part 1: one byte over
## RelayProtocol.MAX_INBOUND_FRAME_BYTES must be refused by
## WebSocketTransport.send() itself, before the socket is ever touched --
## see that method's doc comment. Verified two ways: the transport ends
## FAILED with an error naming both the actual size and the limit (not
## Godot's internal buffer wording), and the relay's own view of the room
## never changes -- if the oversized frame had actually reached the wire, the
## relay would have closed the connection itself (real RFC 6455 code 1009,
## see tests/net/relay_run.gd's _test_oversized_frame_closes_sender_only),
## dropping room occupancy to 0. It staying at 1 is proof the frame never
## left this process.
func _test_payload_one_byte_over_limit_is_refused_locally() -> void:
	var room_code := "frame-over-room"
	var a := WebSocketTransportScript.new()
	a.open("ws://127.0.0.1:%d/%s" % [TEST_PORT, room_code])
	_pump_until(
		_server, "transport reaches CONNECTED for the one-byte-over-limit case",
		func() -> bool: return a.state() == NetTransportScript.State.CONNECTED,
		func() -> void: a.poll()
	)

	var over_limit := PackedByteArray()
	over_limit.resize(RelayProtocolScript.MAX_INBOUND_FRAME_BYTES + 1)
	a.send(over_limit)

	_expect(
		a.state() == NetTransportScript.State.FAILED,
		"a payload one byte over the frame limit must move the transport to FAILED immediately, synchronously"
	)
	var error := a.last_error()
	_expect(
		error.contains(str(over_limit.size())) and error.contains(str(RelayProtocolScript.MAX_INBOUND_FRAME_BYTES)),
		"last_error() must name both the actual payload size and the limit: got '%s'" % error
	)

	for i in range(30):
		_server.poll()
		OS.delay_msec(PUMP_SLEEP_MSEC)
	_expect(
		_server.room_client_count(StringName(room_code)) == 1,
		"a locally refused oversized payload must never reach the relay -- the connection must stay seated"
	)

	a.close()


## The defect this case-trio pins down, part 2: before this fix, a payload
## far above WebSocketPeer's own local outbound buffer (65536 bytes) failed
## silently -- state() stayed CONNECTED and last_error() read Godot's
## internal "send failed: Out of memory", with the frame never reaching the
## relay at all. This is the exact measurement from the defect report. After
## the fix, this payload is caught by the same up-front size check as one
## byte over the limit (65536 is already far past
## RelayProtocol.MAX_INBOUND_FRAME_BYTES, so it never gets near
## WebSocketPeer.send() to trip the local buffer at all) and must behave
## identically: FAILED, a legible error naming size and limit, and the relay
## never seeing the frame.
func _test_payload_far_over_local_buffer_behaves_like_one_byte_over() -> void:
	var room_code := "frame-huge-room"
	var a := WebSocketTransportScript.new()
	a.open("ws://127.0.0.1:%d/%s" % [TEST_PORT, room_code])
	_pump_until(
		_server, "transport reaches CONNECTED for the far-over-limit case",
		func() -> bool: return a.state() == NetTransportScript.State.CONNECTED,
		func() -> void: a.poll()
	)

	var huge := PackedByteArray()
	huge.resize(65536)
	a.send(huge)

	_expect(
		a.state() == NetTransportScript.State.FAILED,
		(
			"a payload far above the local outbound buffer must move the transport to FAILED, exactly like one byte "
			+ "over the limit -- this used to be the silent case (state stayed CONNECTED, last_error() read Godot's "
			+ "'Out of memory') where the frame vanished with no observable failure"
		)
	)
	var error := a.last_error()
	_expect(
		error.contains(str(huge.size())) and error.contains(str(RelayProtocolScript.MAX_INBOUND_FRAME_BYTES)),
		"last_error() must name both the actual payload size and the limit, not Godot's internal buffer wording: got '%s'" % error
	)
	_expect(
		not error.to_lower().contains("out of memory"),
		"Godot's internal buffer error must never be what the caller sees: got '%s'" % error
	)

	for i in range(30):
		_server.poll()
		OS.delay_msec(PUMP_SLEEP_MSEC)
	_expect(
		_server.room_client_count(StringName(room_code)) == 1,
		"a payload far over the limit must never reach the relay either -- same local rejection path as one byte over"
	)

	a.close()


## The one place every wait in this suite goes through (see the suite doc
## comment). Repeatedly polls `server` and calls `extra_poll` (which is
## responsible for polling whatever WebSocketTransport instances the case
## cares about, and for collecting any payloads it needs -- see
## websocket_transport.gd's class doc comment on why poll() must be pumped
## every tick regardless of whether the caller wants its return value), then
## checks `condition`, until it returns true, a hard iteration cap is hit, or
## a wall-clock cap is hit -- whichever comes first. On timeout this fails
## the current case naming exactly what it was waiting for, rather than
## letting the suite hang or fail with an opaque assertion somewhere later.
func _pump_until(server: RelayServerScript, description: String, condition: Callable, extra_poll: Callable) -> bool:
	var start_msec := Time.get_ticks_msec()
	for i in range(MAX_PUMP_ITERATIONS):
		server.poll()
		extra_poll.call()
		if condition.call():
			return true
		if Time.get_ticks_msec() - start_msec > MAX_PUMP_SECONDS * 1000.0:
			break
		OS.delay_msec(PUMP_SLEEP_MSEC)
	_expect(false, "timed out waiting for: %s" % description)
	return false
