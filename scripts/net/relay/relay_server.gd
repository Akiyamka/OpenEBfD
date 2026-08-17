class_name RelayServer
extends RefCounted

## Real WebSocket relay server: the network-facing half of the "dumb relay"
## in docs/architecture/network-multiplayer.md ("Deterministic lockstep over
## a dumb relay", decision 1) and the network twin of `LoopbackHub`
## (`res://scripts/net/loopback_hub.gd`), which is the in-memory stand-in for
## exactly this component used by tests that do not need real sockets. Two
## jobs only: put each connection into a room, and forward every binary
## frame it receives verbatim to every client currently in that room --
## *including the sender*. That last detail matters: it matches LoopbackHub's
## fan-out-to-self semantics, so the turn scheduler above never needs a
## special case for local input depending on which transport is under it.
##
## Deliberately NOT part of the deterministic simulation (`scripts/sim/`):
## this runs in real time, is driven by an explicitly pumped poll() rather
## than a fixed tick, and none of the determinism rules in the design doc
## (no `await`, no wall clock, ...) apply here. `await` is avoided anyway,
## not because it is banned, but because a pumped seam is what lets a test
## drive this without a running main loop.
##
## ROOM IDENTITY comes from the connection, not from a payload: the request
## URL's path, e.g. `ws://host:port/<room-code>`. This was the one thing the
## design left unresolved -- whether Godot 4.7 exposes that URL to the
## *server* side of a WebSocketPeer upgraded from a raw TCPServer connection
## -- and it was resolved by direct experiment, not by guessing from memory:
## a throwaway script drove a real TCPServer.listen() / take_connection() /
## WebSocketPeer.accept_stream() handshake against a real client-side
## WebSocketPeer.connect_to_url("ws://127.0.0.1:<port>/room-ABC123"), pumping
## poll() on both ends until ready_state reached STATE_OPEN, and then called
## get_requested_url() on the *server*-side peer. It returned the full
## request URL including the path: "ws://127.0.0.1:38910/room-ABC123". So
## the path IS readable server-side, and no client-sent "join frame"
## fallback is needed or implemented here.
##
## The room code is normalized (leading/trailing slashes stripped, so
## `/alpha` and `/alpha/` are the same room -- a pasted URL very often
## carries a trailing slash and the alternative is two silent, disjoint
## rooms) and validated (see ROOM_CODE_ALLOWED_CHARS and
## ROOM_CODE_MAX_LENGTH) before it is ever used as a dictionary key: this is
## attacker-controlled input on a server this project intends to self-host
## publicly (decision 7), so it does not get to be arbitrary. No
## percent-decoding is attempted -- `%` is simply not in the allowed
## charset, so a percent-escaped segment (`%41` vs `A`) is rejected outright
## as an invalid room code rather than silently treated as a different room
## than the one a human typed.
##
## Raw TCPServer + WebSocketPeer, not WebSocketMultiplayerPeer: the
## high-level multiplayer peer drags in MultiplayerAPI peer ids and RPC
## routing, which is state replication -- the opposite of what a dumb relay
## and lockstep command frames want. See decision 6.
##
## Explicitly out of scope here (phase 5 in the design doc, not this
## module): peer-presence announcements, lobby, matchmaking, player slots,
## reconnect, TLS, authentication, or any knowledge of what the forwarded
## bytes mean. A text frame is treated purely as a protocol error (binary
## frames only, see decision 6/"dumb pipe"), not as the start of some other
## opcode scheme. Per-room and total connection *caps* beyond max_room_size
## are a separate hardening step, not this one -- see _admit()'s only
## capacity check.

## Max clients allowed in one room before the next joiner is rejected and
## closed rather than silently dropped. Defaults to the v0.4 player cap; see
## docs/architecture/network-multiplayer.md, decision 7 and "Starting
## parameters". Reassigning this only affects rooms evaluated by _admit()
## after the change -- it is read fresh on every join, not snapshotted.
var max_room_size := 4

## How long a connection may sit mid-handshake (accepted at the TCP level,
## not yet resolved to STATE_OPEN or STATE_CLOSED) before the relay gives up
## on it and closes it. Without this, a connection that never sends a proper
## HTTP upgrade -- a port scanner, a stray raw TCPServer client, a client
## that died mid-handshake -- sits in _handshaking forever: _advance_handshakes()
## only used to remove a peer on STATE_OPEN or STATE_CLOSED, and a peer that
## is neither never reaches either. 5 seconds is generous for a legitimate
## client on a slow link and short enough that a stalled handshake does not
## accumulate. Verified empirically that WebSocketPeer.close() on a peer
## still in STATE_CONNECTING actually tears down the underlying socket
## (observable on the other end as its raw TCP connection dropping) rather
## than leaving it dangling -- see _advance_handshakes().
var handshake_timeout_msec := 5000

## Room codes are the normalized request path (see the class doc comment)
## restricted to this charset: ASCII letters, digits, hyphen and underscore.
## Deliberately excludes `%` (see the class doc comment on why that is what
## makes percent-escapes safe to leave undecoded) and `/` (an internal slash
## would silently merge with the leading/trailing-slash stripping and make
## `a/b` ambiguous with a literal two-segment path).
const ROOM_CODE_ALLOWED_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
## Long enough for a UUIDv4 with the hyphens stripped (32 chars) plus
## generous headroom for a human-chosen slug; short enough that a hostile
## client cannot use the room code as a way to grow the relay's room
## dictionary with unbounded-length keys.
const ROOM_CODE_MAX_LENGTH := 64

## Close codes sent to a rejected client. Defined in `relay_protocol.gd`
## (preloaded below) rather than here, so a client transport can learn the
## protocol without preloading this server script -- see that file's doc
## comment for the empirical finding behind the exact numbers (Godot 4.7
## silently rewrites close codes 1012-1015 into 1002, which is why every
## rejection here uses the 4000 range instead). Re-declared as local aliases
## so existing call sites in this file, and `RelayServerScript.CLOSE_*` in
## tests/net/relay_run.gd, keep working unchanged.
const RelayProtocolScript := preload("res://scripts/net/relay_protocol.gd")
const CLOSE_NO_ROOM_CODE := RelayProtocolScript.CLOSE_NO_ROOM_CODE
const CLOSE_INVALID_ROOM_CODE := RelayProtocolScript.CLOSE_INVALID_ROOM_CODE
const CLOSE_ROOM_FULL := RelayProtocolScript.CLOSE_ROOM_FULL
const CLOSE_PROTOCOL_ERROR := RelayProtocolScript.CLOSE_PROTOCOL_ERROR

var _server: TCPServer
## Human-readable one-line descriptions of joins, leaves and rejections,
## queued in the order they happened. Several can land in a single poll()
## call (e.g. three clients all completing their handshake the same frame),
## which is why this is a queue drained by drain_events() rather than a
## single overwritten field like NetTransport.last_error() -- an overwritten
## field would silently lose all but the last event of that frame, and
## relay_main.gd's whole job is to log every one of them.
var _events: Array[String] = []
## Connections whose WebSocket upgrade handshake is not yet resolved either
## way (see accept_stream()); moved out to _rooms on success, dropped on
## failure or on timeout (see handshake_timeout_msec). Not yet associated
## with any room.
var _handshaking: Array[_Handshake] = []
## Peers rejected or protocol-faulted, kept alive only long enough for
## poll() to flush the outgoing WS close frame before they are dropped.
var _closing: Array[WebSocketPeer] = []
## StringName room code -> Array[_Client]. A room exists in this dictionary
## only while it has at least one client; see _pump_rooms().
var _rooms: Dictionary = {}


## One connected, room-assigned client. A thin pairing of the socket and the
## room it joined, not a general "player" concept -- the relay has no idea
## what a player is, see the class doc comment above.
class _Client extends RefCounted:
	var ws: WebSocketPeer
	var room: StringName


## One connection mid-handshake: the socket plus when it was accepted at the
## TCP level, so a handshake that never resolves either way can still be
## dropped once it overruns handshake_timeout_msec. See _advance_handshakes().
class _Handshake extends RefCounted:
	var ws: WebSocketPeer
	var accepted_at_msec: int


## Starts listening on `port`. Returns the `Error` from `TCPServer.listen()`
## directly (`OK` on success) so a caller -- relay_main.gd or a test -- can
## report a bind failure (e.g. the port already being in use) without this
## class inventing its own error vocabulary. Calling start() again while
## already started is itself an error; call stop() first.
func start(port: int) -> Error:
	if _server != null:
		push_error("RelayServer.start: already started; call stop() first")
		return ERR_ALREADY_IN_USE
	var server := TCPServer.new()
	var err := server.listen(port)
	if err != OK:
		return err
	_server = server
	return OK


## Closes every connection (handshaking, closing and room-assigned alike),
## forgets all room state, and stops listening. Safe to call when not
## started.
func stop() -> void:
	if _server == null:
		return
	for handshake in _handshaking:
		handshake.ws.close()
	_handshaking.clear()
	for peer in _closing:
		peer.close()
	_closing.clear()
	for room_code in _rooms:
		var clients: Array = _rooms[room_code]
		for client in clients:
			client.ws.close()
	_rooms.clear()
	_server.stop()
	_server = null


## Whether start() has been called without a matching stop().
func is_running() -> bool:
	return _server != null


## Explicitly pumped seam (see the class doc comment): drives exactly one
## round of I/O -- accept new connections, advance in-progress handshakes,
## flush closing peers, and pump every room's clients (receive, fan out,
## detect disconnects). Does nothing if not started. No `await`, no engine
## callback: a test drives this in a loop alongside real wall-clock waits or
## its own tick source, same shape as `LoopbackHub.step()` for the loopback
## stand-in.
func poll() -> void:
	if _server == null:
		return
	_accept_new_connections()
	_advance_handshakes()
	_advance_closing()
	_pump_rooms()


func _accept_new_connections() -> void:
	while _server.is_connection_available():
		var stream := _server.take_connection()
		var peer := WebSocketPeer.new()
		var err := peer.accept_stream(stream)
		if err != OK:
			_events.append("rejected connection: accept_stream failed (%s)" % err)
			continue
		var handshake := _Handshake.new()
		handshake.ws = peer
		handshake.accepted_at_msec = Time.get_ticks_msec()
		_handshaking.append(handshake)


func _advance_handshakes() -> void:
	if _handshaking.is_empty():
		return
	var still_handshaking: Array[_Handshake] = []
	var now_msec := Time.get_ticks_msec()
	for handshake in _handshaking:
		handshake.ws.poll()
		var state := handshake.ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			_admit(handshake.ws)
		elif state == WebSocketPeer.STATE_CLOSED:
			_events.append("rejected connection: WebSocket handshake failed")
		elif now_msec - handshake.accepted_at_msec >= handshake_timeout_msec:
			_events.append(
				"rejected connection: WebSocket handshake did not complete within %d ms" % handshake_timeout_msec
			)
			handshake.ws.close()
			_closing.append(handshake.ws)
		else:
			still_handshaking.append(handshake)
	_handshaking = still_handshaking


## A handshake just reached STATE_OPEN: read its room code from the request
## path, normalize and validate it, and either seat the connection in that
## room or reject it -- each of the three rejection reasons (no room code,
## an invalid room code, or a full room) gets its own close code, see
## CLOSE_NO_ROOM_CODE and friends above.
func _admit(peer: WebSocketPeer) -> void:
	var raw_path := _path_from_url(peer.get_requested_url())
	var room_code_text := _normalize_room_code(raw_path)
	if room_code_text.is_empty():
		_events.append("rejected connection: no room code in request path")
		_reject(peer, CLOSE_NO_ROOM_CODE, "no room code")
		return
	if not _is_valid_room_code(room_code_text):
		_events.append("rejected connection: invalid room code '%s'" % room_code_text)
		_reject(peer, CLOSE_INVALID_ROOM_CODE, "invalid room code")
		return
	var room_code := StringName(room_code_text)
	var clients: Array = _rooms.get(room_code, [])
	if clients.size() >= max_room_size:
		_events.append("rejected connection: room '%s' is full (%d/%d)" % [room_code, clients.size(), max_room_size])
		_reject(peer, CLOSE_ROOM_FULL, "room full")
		return
	var client := _Client.new()
	client.ws = peer
	client.room = room_code
	clients.append(client)
	_rooms[room_code] = clients
	_events.append("joined: room '%s' now has %d client(s)" % [room_code, clients.size()])


func _reject(peer: WebSocketPeer, code: int, reason: String) -> void:
	peer.close(code, reason)
	_closing.append(peer)


func _advance_closing() -> void:
	if _closing.is_empty():
		return
	var still_closing: Array[WebSocketPeer] = []
	for peer in _closing:
		peer.poll()
		if peer.get_ready_state() != WebSocketPeer.STATE_CLOSED:
			still_closing.append(peer)
	_closing = still_closing


func _pump_rooms() -> void:
	for room_code in _rooms.keys():
		var clients: Array = _rooms[room_code]
		var remaining: Array = []
		for client in clients:
			if _pump_client(client):
				remaining.append(client)
		if remaining.is_empty():
			_rooms.erase(room_code)
		else:
			_rooms[room_code] = remaining


## Polls one client's socket, forwards every binary frame it has waiting to
## the whole room (including itself), and reports whether it is still
## connected. A text frame is a protocol error: log it and close that
## connection, per decision 6 ("binary frames only") -- this is a dumb pipe,
## not a place to grow an opcode scheme; do not read meaning into the bytes
## beyond "text or binary". 1003 is a real RFC 6455 code ("received data of
## a type it cannot accept") and round-trips correctly, see CLOSE_PROTOCOL_ERROR.
func _pump_client(client: _Client) -> bool:
	var peer := client.ws
	peer.poll()
	if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_events.append("left: room '%s'" % client.room)
		return false
	while peer.get_available_packet_count() > 0:
		var payload := peer.get_packet()
		if peer.was_string_packet():
			_events.append("rejected connection: text frame in room '%s' (binary frames only)" % client.room)
			peer.close(CLOSE_PROTOCOL_ERROR, "binary frames only")
			_closing.append(peer)
			return false
		_broadcast(client.room, payload)
	return true


## Forwards `payload` verbatim to every client currently in `room_code`,
## including the sender -- see the class doc comment for why that is load
## bearing, not an oversight.
func _broadcast(room_code: StringName, payload: PackedByteArray) -> void:
	var clients: Array = _rooms.get(room_code, [])
	for client in clients:
		client.ws.send(payload, WebSocketPeer.WRITE_MODE_BINARY)


## Extracts the raw path segment from a request URL of the form
## `ws://host:port/<path>` (query string and fragment, if any, are
## stripped), with no normalization or validation applied yet -- see
## _normalize_room_code() and _is_valid_room_code(). Returns `""` for a URL
## with no scheme separator or no path segment at all.
func _path_from_url(url: String) -> String:
	var scheme_split := url.find("://")
	if scheme_split == -1:
		return ""
	var after_scheme := url.substr(scheme_split + 3)
	var path_start := after_scheme.find("/")
	if path_start == -1:
		return ""
	var path := after_scheme.substr(path_start + 1)
	var query_idx := path.find("?")
	if query_idx != -1:
		path = path.substr(0, query_idx)
	var frag_idx := path.find("#")
	if frag_idx != -1:
		path = path.substr(0, frag_idx)
	return path


## Strips every leading and trailing `/` from a raw path so `alpha`,
## `/alpha`, `alpha/` and `/alpha/` are all the same room code -- see the
## class doc comment on why a trailing slash must not silently create a
## second room. Internal slashes (`a/b`) are left alone here and rejected
## later by _is_valid_room_code(), since `/` is not in ROOM_CODE_ALLOWED_CHARS.
func _normalize_room_code(raw_path: String) -> String:
	var text := raw_path
	while text.begins_with("/"):
		text = text.substr(1)
	while text.ends_with("/"):
		text = text.substr(0, text.length() - 1)
	return text


## Whether `code` is safe to use as a room key: non-empty, within
## ROOM_CODE_MAX_LENGTH, and made up only of characters in
## ROOM_CODE_ALLOWED_CHARS. See the class doc comment for why this exists at
## all -- a room code is attacker-controlled input on a publicly self-hosted
## server.
func _is_valid_room_code(code: String) -> bool:
	if code.is_empty() or code.length() > ROOM_CODE_MAX_LENGTH:
		return false
	for i in range(code.length()):
		if not ROOM_CODE_ALLOWED_CHARS.contains(code[i]):
			return false
	return true


## Drains and returns every join/leave/rejection description queued since
## the last call, oldest first -- same "returned by exactly one call" drain
## contract as NetTransport.poll(). relay_main.gd calls this once per pump
## and logs each entry on its own line.
func drain_events() -> Array[String]:
	var drained := _events
	_events = []
	return drained


## Read-only observer: how many clients are currently seated in `room_code`.
## Zero for a room that does not exist -- a room is removed from the
## internal map the moment its last client leaves, see _pump_rooms().
func room_client_count(room_code: StringName) -> int:
	var clients: Array = _rooms.get(room_code, [])
	return clients.size()


## Read-only observer: every room that currently has at least one client.
func room_codes() -> Array[StringName]:
	var codes: Array[StringName] = []
	for room_code in _rooms:
		codes.append(room_code)
	return codes


## Read-only observer: how many connections are currently mid-handshake --
## accepted at the TCP level, not yet resolved to STATE_OPEN or
## STATE_CLOSED, and not yet past handshake_timeout_msec. Lets a test assert
## both that a stalled handshake is eventually dropped from here and that a
## normal one is not held here any longer than its handshake takes.
func handshaking_count() -> int:
	return _handshaking.size()
