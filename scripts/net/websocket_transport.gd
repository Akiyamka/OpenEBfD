class_name WebSocketTransport
extends NetTransport

## WebSocket client transport: the network-facing half of the pair the relay
## (res://scripts/net/relay/relay_server.gd) anticipates, and the real-socket
## counterpart to the in-memory loopback
## (res://scripts/net/loopback_transport.gd) -- see
## docs/architecture/network-multiplayer.md, decision 6, and
## tests/net/transport_conformance.gd for the contract every NetTransport,
## this one included, must satisfy identically. One instance is one
## connection to one room: open("ws://host:port/<room-code>") both dials the
## socket and selects the room -- see relay_server.gd's class doc comment on
## how the room code travels in the request path. This transport does not
## parse or validate the room code itself; it stays dumb and lets the relay
## reject a bad one and say why, via the close-code mapping below.
##
## *** poll() MUST be called every tick, whether or not the caller wants
## payloads. *** This is the one place this transport is not a pure mirror of
## LoopbackTransport: a real socket has to be pumped for its handshake to
## progress and its close to be observed, regardless of whether anything is
## waiting to be received. Skipping poll() stalls the connection -- it will
## sit in CONNECTING (or hold a stale CONNECTED belief past an actual
## disconnect) forever, because nothing else drives the underlying
## WebSocketPeer.
##
## State mapping from WebSocketPeer.get_ready_state():
##  STATE_CONNECTING -> CONNECTING
##  STATE_OPEN       -> CONNECTED
##  STATE_CLOSING    -> left unchanged; the transition is only reported once
##                      STATE_CLOSED resolves
##  STATE_CLOSED     -> DISCONNECTED if this side already asked to close (see
##                      close(), which sets state() synchronously and makes
##                      this branch a no-op for that case) or the peer sent
##                      RFC 6455's normal close code 1000; otherwise FAILED,
##                      with last_error() naming the reason via
##                      relay_protocol.gd. In particular every code in the
##                      relay's 4000-4999 rejection range lands here --
##                      telling "room full" from "invalid room code" is the
##                      entire reason those codes are distinct numbers, so
##                      they are never collapsed into one generic failure --
##                      and so does an abrupt drop or a refused TCP
##                      connection, which Godot reports as close code -1
##                      ("not cleanly closed").
##
## Binary only, per decision 6 ("dumb pipe"): send() always writes
## WRITE_MODE_BINARY. An inbound *text* frame is a protocol error -- the relay
## never sends one (see relay_server.gd's own text-frame handling) -- so
## receiving one means something upstream is wrong: it is recorded in
## last_error(), this transport moves to FAILED, and the socket is closed
## rather than the frame being silently ignored.
##
## connect_timeout_msec is this transport's own belt-and-suspenders answer to
## "failure to reach the host at all must not hang in CONNECTING forever":
## empirically, when nothing listens on the target port, Godot's
## WebSocketPeer does resolve to STATE_CLOSED (close code -1) rather than
## hanging -- but this transport does not want to depend on that platform
## behavior to satisfy the contract, so it also tracks how long it has been
## waiting on its own and forces FAILED once connect_timeout_msec is
## exceeded, the same belt-and-suspenders shape as
## RelayServer.handshake_timeout_msec on the server side.

const RelayProtocolScript := preload("res://scripts/net/relay_protocol.gd")

## How long open() may sit in CONNECTING before this transport gives up on
## its own, independent of whatever the underlying socket eventually
## reports. See the class doc comment.
var connect_timeout_msec := 5000

var _socket: WebSocketPeer
var _state := State.DISCONNECTED
var _last_error := ""
var _connect_started_at_msec := 0


## Begins connecting to `address` (a full `ws://host:port/<room-code>` URL --
## see the class doc comment; this transport does not parse or validate it,
## the relay does). Never blocks: state() reports CONNECTING immediately and
## only resolves to CONNECTED or FAILED once poll() is called enough times to
## observe it.
func open(address: String) -> void:
	_socket = WebSocketPeer.new()
	_last_error = ""
	_connect_started_at_msec = Time.get_ticks_msec()
	var err := _socket.connect_to_url(address)
	if err != OK:
		_socket = null
		_state = State.FAILED
		_last_error = "could not begin connecting to %s: %s" % [address, error_string(err)]
		return
	_state = State.CONNECTING


## Closes the connection immediately from this side's point of view: state()
## moves to DISCONNECTED synchronously, matching LoopbackTransport.close()
## rather than waiting out the real WebSocket close handshake -- that
## handshake is still driven to completion by subsequent poll() calls, but is
## no longer observable through state(), since a caller that already asked to
## close does not need to see an intermediate state on the way out.
## Idempotent per the base contract.
func close() -> void:
	if _state == State.DISCONNECTED:
		return
	_state = State.DISCONNECTED
	if _socket != null:
		_socket.close()


## Writes `payload` as a binary frame (see the class doc comment -- this
## transport never sends text). A no-op outside CONNECTED, recording why in
## last_error() rather than raising, per the base contract.
func send(payload: PackedByteArray) -> void:
	if _state != State.CONNECTED or _socket == null:
		_last_error = "cannot send: transport is not connected (state=%s)" % State.keys()[_state]
		return
	var err := _socket.send(payload, WebSocketPeer.WRITE_MODE_BINARY)
	if err != OK:
		_last_error = "send failed: %s" % error_string(err)


## Pumps the underlying socket and returns every binary payload received
## since the last call, draining them -- see the base contract on poll().
## *** Must be called every tick regardless of whether the caller wants
## data ***: see the class doc comment.
func poll() -> Array[PackedByteArray]:
	var drained: Array[PackedByteArray] = []
	if _socket == null:
		return drained
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			_check_connect_timeout()
		WebSocketPeer.STATE_OPEN:
			if _state == State.CONNECTING:
				_state = State.CONNECTED
			_drain_frames(drained)
		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CLOSED:
			_handle_closed()
	return drained


func state() -> State:
	return _state


func last_error() -> String:
	return _last_error


func _check_connect_timeout() -> void:
	if Time.get_ticks_msec() - _connect_started_at_msec < connect_timeout_msec:
		return
	_state = State.FAILED
	_last_error = "connection attempt timed out after %d ms" % connect_timeout_msec
	_socket.close()


## Reads every binary frame currently buffered on the socket into `drained`.
## A text frame ends the loop immediately (see the class doc comment): the
## relay never sends one, so seeing one means the connection is no longer
## trustworthy, and this transport fails and closes rather than keep reading.
func _drain_frames(drained: Array[PackedByteArray]) -> void:
	while _socket.get_available_packet_count() > 0:
		var payload := _socket.get_packet()
		if _socket.was_string_packet():
			_last_error = "received a text frame; this transport is binary-only (protocol error)"
			_state = State.FAILED
			_socket.close()
			return
		drained.append(payload)


## The socket has fully closed. If this side already called close(), _state
## is already DISCONNECTED (set synchronously there) and this is a no-op --
## the branches below only ever run for a close this side did not ask for.
func _handle_closed() -> void:
	if _state == State.DISCONNECTED or _state == State.FAILED:
		return
	var code := _socket.get_close_code()
	if code == RelayProtocolScript.CLOSE_NORMAL:
		_state = State.DISCONNECTED
		return
	if code >= 4000 and code <= 4999:
		_state = State.FAILED
		_last_error = RelayProtocolScript.describe_close_code(code)
		return
	_state = State.FAILED
	_last_error = _describe_unexpected_close(code)


## `code` is whatever WebSocketPeer.get_close_code() reports for a close this
## transport did not itself request and that was neither a normal 1000 nor
## one of the relay's own 4000-4999 rejection codes -- most commonly -1
## ("not cleanly closed": a refused or dropped TCP connection, most notably
## nothing listening on the target host/port at all) or 1002 ("protocol
## error", which is also what Godot 4.7 substitutes for any close code it
## does not round-trip -- see relay_protocol.gd's doc comment).
func _describe_unexpected_close(code: int) -> String:
	if code == -1:
		return "connection closed without completing the WebSocket handshake (host unreachable, refused, or dropped the connection)"
	return "connection closed unexpectedly with code %d" % code
