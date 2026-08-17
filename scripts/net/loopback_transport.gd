class_name LoopbackTransport
extends NetTransport

## One endpoint of a `LoopbackHub`. Construct these only through
## `LoopbackHub.add_endpoint()` — a transport with no hub can never deliver
## anything, and the hub is what assigns the registration index the loss
## draw order depends on.
##
## open()/close() only flip local state; the actual fan-out, latency, jitter
## and loss mechanics live on the hub, because delivery to this endpoint
## depends on every other registered endpoint too, not just this one. See
## `loopback_hub.gd`.
##
## `_hub_ref` is a `WeakRef`, not a direct reference, for two reasons: typing
## it `LoopbackHub` would make this file `preload` `loopback_hub.gd`, while
## `loopback_hub.gd` already `preload`s this file to construct endpoints —
## GDScript does not resolve that cycle — and a strong reference back to the
## hub that registered this endpoint, held while the hub's own `_endpoints`
## dictionary holds this endpoint, is a reference cycle that plain
## `RefCounted` refcounting can never collect. The hub is only ever reached
## through its public `route()`/`discard_pending_for()` methods below, never
## through its underscore members.
##
## send() enforces RelayProtocol.MAX_INBOUND_FRAME_BYTES even though this
## in-memory hub could technically carry a payload of any size: the frame
## limit is a protocol invariant (see relay_protocol.gd), not a
## WebSocketTransport implementation detail, and this transport exists to be
## interchangeable with that one (docs/architecture/network-multiplayer.md,
## decision 6; tests/net/transport_conformance.gd runs the identical suite
## against both). A payload the loopback silently accepted but a real relay
## refused would pass in CI and fail against a real socket — exactly the gap
## the shared conformance suite exists to close.

const RelayProtocolScript := preload("res://scripts/net/relay_protocol.gd")

var _id: StringName
var _hub_ref: WeakRef
var _state := State.DISCONNECTED
var _last_error := ""
var _inbox: Array[PackedByteArray] = []


func _init(hub, id: StringName) -> void:
	_hub_ref = weakref(hub)
	_id = id


## Ignores `address`: a loopback endpoint has nothing to dial, it only needs
## to be marked reachable. There is no CONNECTING phase because the "dial"
## is instantaneous — state() jumps straight to CONNECTED.
func open(_address: String) -> void:
	_state = State.CONNECTED


## Discards messages already scheduled for delivery to this endpoint (see
## `LoopbackHub.discard_pending_for()`); payloads already delivered but not
## yet polled are untouched and stay pollable. Idempotent, per the base
## contract.
func close() -> void:
	if _state == State.DISCONNECTED:
		return
	_state = State.DISCONNECTED
	var hub = _hub_ref.get_ref()
	if hub != null:
		hub.discard_pending_for(_id)


## No-op once not CONNECTED (either never opened or already closed): records
## why in last_error() instead of queuing anything with the hub. While
## CONNECTED, a payload over RelayProtocol.MAX_INBOUND_FRAME_BYTES is
## rejected up front, before the hub ever sees it (see the class doc comment
## on why this loopback enforces the same limit a real relay would), and
## moves this endpoint to FAILED rather than staying silently CONNECTED: a
## frame that cannot actually be delivered on a live connection is exactly
## the kind of drop lockstep cannot paper over (see
## docs/architecture/network-multiplayer.md, decision 1).
func send(payload: PackedByteArray) -> void:
	if _state != State.CONNECTED:
		_last_error = "cannot send: endpoint %s is not connected" % _id
		return
	if payload.size() > RelayProtocolScript.MAX_INBOUND_FRAME_BYTES:
		_last_error = (
			"cannot send: payload of %d bytes exceeds the %d-byte protocol frame limit"
			% [payload.size(), RelayProtocolScript.MAX_INBOUND_FRAME_BYTES]
		)
		_state = State.FAILED
		return
	var hub = _hub_ref.get_ref()
	if hub == null:
		_last_error = "cannot send: endpoint %s has outlived its hub" % _id
		return
	hub.route(payload)


func poll() -> Array[PackedByteArray]:
	var drained := _inbox
	_inbox = []
	return drained


func state() -> State:
	return _state


func last_error() -> String:
	return _last_error


## Hub-only: appends a delivered payload to this endpoint's inbox. Not part
## of the NetTransport contract — called from `LoopbackHub.step()` and
## nowhere else.
func receive(payload: PackedByteArray) -> void:
	_inbox.append(payload)
