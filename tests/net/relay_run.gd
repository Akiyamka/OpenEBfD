extends "res://tests/support/suite.gd"

## Drives `RelayServer` (res://scripts/net/relay/relay_server.gd) in-process
## with real `WebSocketPeer` clients over real loopback sockets -- no
## container-in-container, no external relay process. Pins down the same
## "dumb pipe" contract `tests/net/loopback_run.gd` pins down for the
## in-memory stand-in: fan-out including the sender, room isolation, room
## capacity, disconnect handling, multiple rooms, and binary-frames-only.
## See docs/architecture/network-multiplayer.md, decision 1 ("dumb relay")
## and decision 6 ("WebSocket behind a transport interface").
##
## Real sockets and real time make this suite structurally flakier than the
## loopback one, so every wait goes through the single _pump_until() helper
## below: a hard iteration cap *and* a wall-clock cap, and a named failure
## instead of an unbounded `while` that would just hang. TEST_PORT is well
## away from the relay's default 8910 so a relay a developer left running on
## the default port cannot make this suite fail confusingly, and a bind
## failure at startup is reported by name rather than left to time out.

const RelayServerScript := preload("res://scripts/net/relay/relay_server.gd")

const TEST_PORT := 18910
## The room-capacity case needs its own server with a non-default
## max_room_size, so it gets its own port too rather than juggling that
## setting on the shared server mid-suite.
const CAPACITY_TEST_PORT := 18911
## The "room full" leg of the close-code case needs its own tiny-capacity
## room, same reasoning as CAPACITY_TEST_PORT.
const FULL_ROOM_TEST_PORT := 18912
## The stalled-handshake case needs its own server with a short
## handshake_timeout_msec, so the case does not have to wait out the real
## 5-second default.
const STALLED_HANDSHAKE_TEST_PORT := 18913

const MAX_PUMP_ITERATIONS := 5000
const MAX_PUMP_SECONDS := 5.0
const PUMP_SLEEP_MSEC := 2

var _server: RelayServerScript


func _initialize() -> void:
	_server = RelayServerScript.new()
	var err := _server.start(TEST_PORT)
	if err != OK:
		printerr(
			(
				"relay tests: could not bind port %d (%s) -- another process (maybe a relay "
				+ "left running from a previous session) is already listening on it; free the "
				+ "port or change TEST_PORT in tests/net/relay_run.gd and rerun"
			)
			% [TEST_PORT, error_string(err)]
		)
		quit(1)
		return

	_run_case("fan-out includes the sender: three clients, one sends, all three receive it", _test_fanout_including_sender)
	_run_case("room isolation: a room B client never receives a frame sent in room A", _test_room_isolation)
	_run_case(
		"room capacity: the third client to a max_room_size=2 room is rejected and closed",
		_test_room_capacity
	)
	_run_case(
		"disconnect: a closed client stops receiving, survivors keep working, count drops",
		_test_disconnect
	)
	_run_case("two rooms coexist and both independently work", _test_two_rooms_coexist)
	_run_case("a text frame is a protocol error: that connection is closed, others are undisturbed", _test_text_frame_rejected)
	_run_case(
		"a trailing slash does not create a second room: '/alpha' and '/alpha/' are the same room",
		_test_trailing_slash_same_room
	)
	_run_case(
		"an invalid room code (bad charset, or past the length cap) is rejected, not seated",
		_test_invalid_room_code_rejected
	)
	_run_case(
		"no-room-code, invalid-room-code and room-full each observe their own distinct close code",
		_test_rejection_close_codes_are_distinct
	)
	_run_case(
		"a stalled handshake is dropped after its deadline; a healthy one is not disturbed",
		_test_stalled_handshake_dropped
	)

	_server.stop()
	_finish("Relay server tests")


func _test_fanout_including_sender() -> void:
	var room := &"fanout-room"
	var a := _connect_client(TEST_PORT, "fanout-room")
	var b := _connect_client(TEST_PORT, "fanout-room")
	var c := _connect_client(TEST_PORT, "fanout-room")
	var clients: Array[WebSocketPeer] = [a, b, c]

	_pump_until(
		_server, clients, "all three clients seated in room 'fanout-room'",
		func() -> bool: return _server.room_client_count(room) == 3
	)

	a.send("hello-from-a".to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)

	_pump_until(
		_server, clients, "all three clients, including the sender, receive the frame",
		func() -> bool:
			return (
				a.get_available_packet_count() > 0
				and b.get_available_packet_count() > 0
				and c.get_available_packet_count() > 0
			)
	)

	for entry in [["A", a], ["B", b], ["C", c]]:
		var pkt: PackedByteArray = entry[1].get_packet()
		_expect(
			pkt.get_string_from_utf8() == "hello-from-a",
			"%s must receive the exact bytes the sender sent -- the sender is not a special case" % entry[0]
		)

	a.close()
	b.close()
	c.close()
	_pump_until(
		_server, _empty_clients(), "room 'fanout-room' empties out after all clients close",
		func() -> bool: return _server.room_client_count(room) == 0
	)


func _test_room_isolation() -> void:
	var room_a := &"iso-room-a"
	var room_b := &"iso-room-b"
	var a1 := _connect_client(TEST_PORT, "iso-room-a")
	var a2 := _connect_client(TEST_PORT, "iso-room-a")
	var b1 := _connect_client(TEST_PORT, "iso-room-b")
	var all_clients: Array[WebSocketPeer] = [a1, a2, b1]

	_pump_until(
		_server, all_clients, "room A has 2 clients and room B has 1",
		func() -> bool: return _server.room_client_count(room_a) == 2 and _server.room_client_count(room_b) == 1
	)

	a1.send("only-for-a".to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)

	_pump_until(
		_server, all_clients, "both room A clients receive the frame sent inside room A",
		func() -> bool: return a1.get_available_packet_count() > 0 and a2.get_available_packet_count() > 0
	)

	# Keep pumping for a bounded stretch so room B has every chance to
	# (wrongly) receive the frame too, before asserting it did not.
	for i in range(30):
		_server.poll()
		b1.poll()
		OS.delay_msec(PUMP_SLEEP_MSEC)

	_expect(a1.get_packet().get_string_from_utf8() == "only-for-a", "room A's sender must receive its own frame")
	_expect(a2.get_packet().get_string_from_utf8() == "only-for-a", "room A's other client must receive the frame")
	_expect(b1.get_available_packet_count() == 0, "room B must never receive a frame sent inside room A")

	a1.close()
	a2.close()
	b1.close()
	_pump_until(
		_server, _empty_clients(), "rooms A and B both empty out",
		func() -> bool: return _server.room_client_count(room_a) == 0 and _server.room_client_count(room_b) == 0
	)


func _test_room_capacity() -> void:
	var server := _start_server(CAPACITY_TEST_PORT, 2)
	if server == null:
		return

	var room := &"cap-room"
	var a := _connect_client(CAPACITY_TEST_PORT, "cap-room")
	var b := _connect_client(CAPACITY_TEST_PORT, "cap-room")
	var clients: Array[WebSocketPeer] = [a, b]

	_pump_until(server, clients, "both of the first two clients are seated", func() -> bool: return server.room_client_count(room) == 2)

	var c := _connect_client(CAPACITY_TEST_PORT, "cap-room")
	clients.append(c)
	_pump_until(
		server, clients, "the third client to the full room is rejected and closed",
		func() -> bool: return c.get_ready_state() == WebSocketPeer.STATE_CLOSED
	)

	_expect(server.room_client_count(room) == 2, "room occupancy must stay at 2 after the third client is rejected")

	a.send("still-works".to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)
	_pump_until(
		server, clients, "the first two clients keep exchanging frames after the rejection",
		func() -> bool: return a.get_available_packet_count() > 0 and b.get_available_packet_count() > 0
	)

	_expect(a.get_packet().get_string_from_utf8() == "still-works", "the sender must still receive its own frame")
	_expect(b.get_packet().get_string_from_utf8() == "still-works", "the surviving peer must still receive the frame")

	a.close()
	b.close()
	server.stop()


func _test_disconnect() -> void:
	var room := &"disconnect-room"
	var a := _connect_client(TEST_PORT, "disconnect-room")
	var b := _connect_client(TEST_PORT, "disconnect-room")
	var c := _connect_client(TEST_PORT, "disconnect-room")
	var clients: Array[WebSocketPeer] = [a, b, c]

	_pump_until(
		_server, clients, "all three clients seated in 'disconnect-room'",
		func() -> bool: return _server.room_client_count(room) == 3
	)

	c.close()
	_pump_until(
		_server, clients, "the server's observed client count for the room drops after the close",
		func() -> bool: return _server.room_client_count(room) == 2
	)

	a.send("after-disconnect".to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)
	_pump_until(
		_server, clients, "the two remaining clients still exchange frames",
		func() -> bool: return a.get_available_packet_count() > 0 and b.get_available_packet_count() > 0
	)

	_expect(
		a.get_packet().get_string_from_utf8() == "after-disconnect",
		"the sender must still receive its own frame after a third client disconnected"
	)
	_expect(
		b.get_packet().get_string_from_utf8() == "after-disconnect",
		"the surviving peer must still receive frames after a third client disconnected"
	)

	# Give the closed client c every chance, within a bounded window, to
	# wrongly receive the post-disconnect frame before asserting it did not.
	for i in range(30):
		_server.poll()
		c.poll()
		OS.delay_msec(PUMP_SLEEP_MSEC)
	_expect(c.get_available_packet_count() == 0, "a client that closed must stop receiving frames sent afterward")

	a.close()
	b.close()
	_pump_until(
		_server, _empty_clients(), "the room empties out after the remaining clients close",
		func() -> bool: return _server.room_client_count(room) == 0
	)


func _test_two_rooms_coexist() -> void:
	var room_x := &"coexist-x"
	var room_y := &"coexist-y"
	var x1 := _connect_client(TEST_PORT, "coexist-x")
	var x2 := _connect_client(TEST_PORT, "coexist-x")
	var y1 := _connect_client(TEST_PORT, "coexist-y")
	var y2 := _connect_client(TEST_PORT, "coexist-y")
	var clients: Array[WebSocketPeer] = [x1, x2, y1, y2]

	_pump_until(
		_server, clients, "both rooms are fully seated (2 clients each)",
		func() -> bool: return _server.room_client_count(room_x) == 2 and _server.room_client_count(room_y) == 2
	)

	x1.send("x-frame".to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)
	y1.send("y-frame".to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)

	_pump_until(
		_server, clients, "each room's own frame reaches both of that room's own clients",
		func() -> bool:
			return (
				x1.get_available_packet_count() > 0 and x2.get_available_packet_count() > 0
				and y1.get_available_packet_count() > 0 and y2.get_available_packet_count() > 0
			)
	)

	_expect(x1.get_packet().get_string_from_utf8() == "x-frame", "room X's sender must receive room X's frame")
	_expect(x2.get_packet().get_string_from_utf8() == "x-frame", "room X's other client must receive room X's frame")
	_expect(y1.get_packet().get_string_from_utf8() == "y-frame", "room Y's sender must receive room Y's frame")
	_expect(y2.get_packet().get_string_from_utf8() == "y-frame", "room Y's other client must receive room Y's frame")

	x1.close()
	x2.close()
	y1.close()
	y2.close()
	_pump_until(
		_server, _empty_clients(), "both rooms empty out",
		func() -> bool: return _server.room_client_count(room_x) == 0 and _server.room_client_count(room_y) == 0
	)


func _test_text_frame_rejected() -> void:
	var room := &"text-frame-room"
	var a := _connect_client(TEST_PORT, "text-frame-room")
	var b := _connect_client(TEST_PORT, "text-frame-room")
	var clients: Array[WebSocketPeer] = [a, b]

	_pump_until(
		_server, clients, "both clients seated in 'text-frame-room'",
		func() -> bool: return _server.room_client_count(room) == 2
	)

	a.send_text("this is a text frame, not binary")
	_pump_until(
		_server, clients, "the client that sent a text frame is closed by the server",
		func() -> bool: return a.get_ready_state() == WebSocketPeer.STATE_CLOSED
	)

	_expect(_server.room_client_count(room) == 1, "the room must drop to 1 client after the protocol violator is closed")

	b.send("still-fine".to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)
	_pump_until(
		_server, clients, "the other client is undisturbed and keeps exchanging frames",
		func() -> bool: return b.get_available_packet_count() > 0
	)

	_expect(
		b.get_packet().get_string_from_utf8() == "still-fine",
		"the surviving client must still receive its own frame after the other was closed for a protocol error"
	)

	b.close()
	_pump_until(
		_server, _empty_clients(), "the room empties out after the surviving client closes",
		func() -> bool: return _server.room_client_count(room) == 0
	)


## Regression for a real bug found by review: `ws://host:port/alpha` and
## `ws://host:port/alpha/` used to produce two different rooms (the raw path
## was used verbatim as the room key), so two players sharing a pasted room
## code -- which very often carries a trailing slash -- would silently sit
## in separate rooms, each waiting for someone who never arrives. Verifies
## RelayServer._normalize_room_code() (called from _admit()).
func _test_trailing_slash_same_room() -> void:
	var room := &"slash-room"
	var a := _connect_client(TEST_PORT, "slash-room")
	var b := _connect_client(TEST_PORT, "slash-room/")
	var clients: Array[WebSocketPeer] = [a, b]

	_pump_until(
		_server, clients, "both clients (one with a trailing slash) land in the same room",
		func() -> bool: return _server.room_client_count(room) == 2
	)
	_expect(
		not _server.room_codes().has(&"slash-room/"),
		"a trailing slash must not create a second, distinct room"
	)

	a.send("shared-room".to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)
	_pump_until(
		_server, clients, "both clients receive the frame -- proof they are truly in one room, not two",
		func() -> bool: return a.get_available_packet_count() > 0 and b.get_available_packet_count() > 0
	)
	_expect(a.get_packet().get_string_from_utf8() == "shared-room", "the plain-path sender must receive its own frame")
	_expect(
		b.get_packet().get_string_from_utf8() == "shared-room",
		"the trailing-slash client must receive the same frame -- they are in one room"
	)

	a.close()
	b.close()
	_pump_until(
		_server, _empty_clients(), "the shared room empties out",
		func() -> bool: return _server.room_client_count(room) == 0
	)


## A room code is attacker-controlled input on a server this project intends
## to self-host publicly (design doc, decision 7), so it must be validated,
## not seated verbatim. Exercises both dimensions RelayServer checks: an
## explicitly disallowed character (`!`, confirmed by direct experiment to
## survive the WebSocket handshake unencoded, so this is not exercising some
## unrelated HTTP-parsing failure -- see the doc comment on
## RelayServer.ROOM_CODE_ALLOWED_CHARS) and a code past ROOM_CODE_MAX_LENGTH.
func _test_invalid_room_code_rejected() -> void:
	var bad_char_client := _connect_client(TEST_PORT, "not-valid!")
	_pump_until(
		_server, [bad_char_client], "a room code with a disallowed character is rejected and closed",
		func() -> bool: return bad_char_client.get_ready_state() == WebSocketPeer.STATE_CLOSED
	)
	_expect(
		bad_char_client.get_close_code() == RelayServerScript.CLOSE_INVALID_ROOM_CODE,
		"an invalid-charset room code must be rejected with its own distinct close code, not folded into 'room full'"
	)

	var too_long := ""
	for i in range(RelayServerScript.ROOM_CODE_MAX_LENGTH + 1):
		too_long += "x"
	var too_long_client := _connect_client(TEST_PORT, too_long)
	_pump_until(
		_server, [too_long_client], "a room code past the length cap is rejected and closed",
		func() -> bool: return too_long_client.get_ready_state() == WebSocketPeer.STATE_CLOSED
	)
	_expect(
		too_long_client.get_close_code() == RelayServerScript.CLOSE_INVALID_ROOM_CODE,
		"a too-long room code must be rejected with the same distinct 'invalid room code' close code"
	)

	_expect(_server.room_codes().is_empty(), "neither invalid attempt may have created a room on the shared server")


## Two problems from review, pinned down together: (1) _reject() used to
## close every rejection reason with the same code (1013, "room full"),
## losing the distinction the event log already had; (2) even after giving
## each reason its own code, 1013 specifically turned out to never arrive at
## all -- verified by direct experiment (a throwaway probe round-tripped
## every close code 1000-1015 and 2999-4999 through a real
## accept_stream()/close()/poll() cycle): codes 1000-1003, 1007-1011 and the
## whole 3000-4999 range arrive exactly as sent, but 1012-1015 (and anything
## else in the 1004-2999 gap RFC 6455 reserves) are silently rewritten by
## Godot 4.7's WebSocketPeer into 1002 "Protocol error" -- which is
## indistinguishable from an actual protocol violation. This case connects
## through all three rejection paths and pins down the exact codes a real
## client observes, so a future regression to a code from that dead range
## fails loudly here instead of silently reintroducing the bug.
func _test_rejection_close_codes_are_distinct() -> void:
	var no_code_client := WebSocketPeer.new()
	var no_code_err := no_code_client.connect_to_url("ws://127.0.0.1:%d/" % TEST_PORT)
	_expect(no_code_err == OK, "connect_to_url must accept ws://host:port/ (empty room code) as well-formed")
	_pump_until(
		_server, [no_code_client], "a connection with no room code at all is closed by the server",
		func() -> bool: return no_code_client.get_ready_state() == WebSocketPeer.STATE_CLOSED
	)

	var invalid_client := _connect_client(TEST_PORT, "not-valid-at-all!!")
	_pump_until(
		_server, [invalid_client], "a connection with an invalid room code is closed by the server",
		func() -> bool: return invalid_client.get_ready_state() == WebSocketPeer.STATE_CLOSED
	)

	var full_server := _start_server(FULL_ROOM_TEST_PORT, 1)
	if full_server == null:
		return
	var occupant := _connect_client(FULL_ROOM_TEST_PORT, "full-room")
	_pump_until(
		full_server, [occupant], "the sole seat in the tiny room is filled",
		func() -> bool: return full_server.room_client_count(&"full-room") == 1
	)
	var overflow_client := WebSocketPeer.new()
	overflow_client.connect_to_url("ws://127.0.0.1:%d/full-room" % FULL_ROOM_TEST_PORT)
	_pump_until(
		full_server, [occupant, overflow_client], "the overflow client to the full room is closed by the server",
		func() -> bool: return overflow_client.get_ready_state() == WebSocketPeer.STATE_CLOSED
	)

	_expect(
		no_code_client.get_close_code() == RelayServerScript.CLOSE_NO_ROOM_CODE,
		"a missing room code must observe RelayServer.CLOSE_NO_ROOM_CODE (4000), not a generic protocol-error code"
	)
	_expect(
		no_code_client.get_close_reason() == "no room code",
		"a missing room code's close reason must arrive verbatim"
	)
	_expect(
		invalid_client.get_close_code() == RelayServerScript.CLOSE_INVALID_ROOM_CODE,
		"an invalid room code must observe RelayServer.CLOSE_INVALID_ROOM_CODE (4001)"
	)
	_expect(
		invalid_client.get_close_reason() == "invalid room code",
		"an invalid room code's close reason must arrive verbatim"
	)
	_expect(
		overflow_client.get_close_code() == RelayServerScript.CLOSE_ROOM_FULL,
		"a full room must observe RelayServer.CLOSE_ROOM_FULL (4002)"
	)
	_expect(
		overflow_client.get_close_reason() == "room full",
		"a full room's close reason must arrive verbatim"
	)

	var observed_codes := [
		no_code_client.get_close_code(), invalid_client.get_close_code(), overflow_client.get_close_code()
	]
	_expect(
		observed_codes[0] != observed_codes[1]
		and observed_codes[1] != observed_codes[2]
		and observed_codes[0] != observed_codes[2],
		"the three rejection kinds must be distinguishable from each other by close code alone"
	)
	_expect(
		not observed_codes.has(1002),
		(
			"none of these may fall back to Godot's generic 1002 'Protocol error' -- that collision is exactly "
			+ "the bug this case pins down (the old 'room full' code, 1013, silently arrived as 1002)"
		)
	)

	full_server.stop()


## A connection that is accepted at the TCP level but never sends a proper
## HTTP upgrade (a port scanner, a stray raw TCPServer client, a client that
## died mid-handshake) used to sit in RelayServer's internal handshake list
## forever: _advance_handshakes() only ever removed a peer once its state
## reached STATE_OPEN or STATE_CLOSED, and a connection that is neither never
## reaches either on its own. Verifies both halves of the fix: the stalled
## connection is eventually dropped (observable both as handshaking_count()
## returning to 0 and as its own raw socket actually disconnecting -- see
## the doc comment on RelayServer.handshake_timeout_msec for why that second
## check is not redundant), and a second, healthy connection made around the
## same time is not held up by the stalled one.
func _test_stalled_handshake_dropped() -> void:
	var server := RelayServerScript.new()
	server.handshake_timeout_msec = 300
	var err := server.start(STALLED_HANDSHAKE_TEST_PORT)
	if err != OK:
		_expect(
			false,
			(
				"could not bind test port %d (%s) -- another process may already be listening on it"
				% [STALLED_HANDSHAKE_TEST_PORT, error_string(err)]
			)
		)
		return

	# A stalled connection: raw TCP only, never speaks WebSocket at all.
	var stalled := StreamPeerTCP.new()
	stalled.connect_to_host("127.0.0.1", STALLED_HANDSHAKE_TEST_PORT)
	var poll_stalled := func() -> void: stalled.poll()

	_pump_until(
		server, _empty_clients(), "the stalled connection is accepted and counted as mid-handshake",
		func() -> bool: return server.handshaking_count() == 1,
		poll_stalled
	)

	# A healthy client, connecting while the stalled one is still pending,
	# must complete its handshake normally and not be held hostage by it.
	var healthy := _connect_client(STALLED_HANDSHAKE_TEST_PORT, "healthy-room")
	_pump_until(
		server, [healthy], "the healthy client completes its handshake and is seated in its room",
		func() -> bool: return server.room_client_count(&"healthy-room") == 1,
		poll_stalled
	)
	_expect(
		healthy.get_ready_state() == WebSocketPeer.STATE_OPEN,
		"a healthy handshake must not be delayed or disturbed by an unrelated stalled one"
	)

	_pump_until(
		server, [healthy], "the stalled handshake is dropped once its deadline passes",
		func() -> bool: return server.handshaking_count() == 0,
		poll_stalled
	)
	_expect(
		stalled.get_status() != StreamPeerTCP.STATUS_CONNECTED,
		"the stalled connection's underlying socket must actually be closed, not just forgotten server-side"
	)
	_expect(
		healthy.get_ready_state() == WebSocketPeer.STATE_OPEN,
		"dropping the stalled handshake must not disturb the healthy, already-open connection"
	)

	healthy.close()
	server.stop()


## Starts a fresh RelayServer on `port` with `room_size` as its max room
## size. On a bind failure this records the case failure by name (see the
## suite doc comment on why real-socket tests must never just time out) and
## returns null; callers must check for that before using the result.
func _start_server(port: int, room_size: int) -> RelayServerScript:
	var server := RelayServerScript.new()
	server.max_room_size = room_size
	var err := server.start(port)
	if err != OK:
		_expect(
			false,
			(
				"could not bind test port %d (%s) -- another process may already be listening on it"
				% [port, error_string(err)]
			)
		)
		return null
	return server


func _connect_client(port: int, room_code: String) -> WebSocketPeer:
	var ws := WebSocketPeer.new()
	var err := ws.connect_to_url("ws://127.0.0.1:%d/%s" % [port, room_code])
	_expect(err == OK, "connect_to_url must accept a well-formed ws:// URL for room '%s'" % room_code)
	return ws


## Typed empty array literal, factored out because `Array[WebSocketPeer]()`
## used directly as a call argument parses fine as a statement but not
## inline in some call positions in this Godot version -- easier to give it
## a name once than to fight the parser at every call site.
func _empty_clients() -> Array[WebSocketPeer]:
	return []


## The one place every wait in this suite goes through (see the suite doc
## comment). Repeatedly polls `server` and every client in `clients` (plus
## `extra_poll`, if given -- for a raw non-WebSocketPeer connection such as
## the stalled-handshake case's bare StreamPeerTCP, which does not fit the
## `Array[WebSocketPeer]` shape of `clients`), then checks `condition`, until
## it returns true, a hard iteration cap is hit, or a wall-clock cap is hit
## -- whichever comes first. On timeout this fails the current case naming
## exactly what it was waiting for, rather than letting the suite hang or
## fail with an opaque assertion somewhere later.
func _pump_until(
	server: RelayServerScript,
	clients: Array[WebSocketPeer],
	description: String,
	condition: Callable,
	extra_poll: Callable = Callable()
) -> bool:
	var start_msec := Time.get_ticks_msec()
	for i in range(MAX_PUMP_ITERATIONS):
		server.poll()
		for client in clients:
			client.poll()
		if extra_poll.is_valid():
			extra_poll.call()
		if condition.call():
			return true
		if Time.get_ticks_msec() - start_msec > MAX_PUMP_SECONDS * 1000.0:
			break
		OS.delay_msec(PUMP_SLEEP_MSEC)
	_expect(false, "timed out waiting for: %s" % description)
	return false
