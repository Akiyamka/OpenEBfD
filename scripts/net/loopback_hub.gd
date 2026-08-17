class_name LoopbackHub
extends RefCounted

## In-memory relay for tests: several `LoopbackTransport` endpoints attached
## to one hub, fanning every `send()` out to every currently-connected
## endpoint — including the sender — with configurable per-recipient
## latency, jitter and packet loss, and fully deterministic delivery
## ordering. See `docs/architecture/network-multiplayer.md`, "WebSocket
## behind a transport interface", and `tests/net/loopback_run.gd` for the
## exact contract this implements.
##
## Time here is *simulation ticks* (25 Hz): the clock only advances when
## step() is called, never from engine time — no `_process`, no `Time.*`, no
## `await`, so a test can run a thousand ticks instantly.

const NetTransportScript := preload("res://scripts/net/net_transport.gd")
const LoopbackTransportScript := preload("res://scripts/net/loopback_transport.gd")

## A single fan-out copy of one send(), addressed to one recipient. Several
## of these can share a (send_tick, sequence) pair — one per recipient that
## did not lose its draw — which is exactly why sequence, not identity,
## breaks same-tick delivery ties (see _less_than()).
class PendingMessage extends RefCounted:
	var recipient_id: StringName
	var payload: PackedByteArray
	var send_tick: int
	var sequence: int
	var delivery_tick: int


## Ticks of fixed delay added to every delivery, before jitter.
var latency_ticks := 0

## Maximum absolute jitter, in ticks, added on top of latency_ticks. Drawn
## uniformly from [-jitter_ticks, +jitter_ticks], independently for every
## recipient of a given send() — see route(). A shared, per-message draw
## would mean every client always observed a given relay frame on the same
## tick, which erases the one thing this harness exists to reproduce: two
## clients receiving the same frame on different ticks, which the turn
## scheduler and stall policy have to survive.
var jitter_ticks := 0

## Per-mille (0..1000) chance that an individual recipient's copy of a given
## message is dropped, independently of every other recipient's copy of the
## same message. Out-of-range assignments are clamped.
var loss_permille := 0:
	set(value):
		loss_permille = clampi(value, 0, 1000)

## Reseeds the hub's RNG immediately on assignment, so setting it before the
## first send (or between steps, to branch a run) is enough to get a
## reproducible delivery log. Two hubs given the same seed and fed the same
## sends at the same ticks produce byte-identical logs.
##
## The declared default (0) is also the *effective* default: GDScript does
## not run a property's `set` callback for its own initializer, so without
## the explicit `_rng.seed = rng_seed` in _init() below, a hub that never
## assigns rng_seed would keep whatever seed RandomNumberGenerator.new()
## draws from OS entropy — silent, undetectable non-determinism, which is
## exactly the failure this module exists to rule out.
var rng_seed := 0:
	set(value):
		rng_seed = value
		_rng.seed = value

var _rng := RandomNumberGenerator.new()
var _current_tick := 0
var _next_sequence := 0
var _endpoints: Dictionary = {}  # StringName -> LoopbackTransportScript
var _endpoint_order: Array[StringName] = []
var _pending: Array[PendingMessage] = []
var _link_next_free_tick: Dictionary = {}  # StringName -> int, see route()


func _init() -> void:
	_rng.seed = rng_seed


## Registers a new endpoint. Registration order is significant: it fixes the
## ascending index the per-recipient draws are made in (see route()).
## Registering the same id twice is an error; it returns null rather than
## the existing endpoint so the mistake cannot silently succeed.
func add_endpoint(id: StringName) -> LoopbackTransportScript:
	if _endpoints.has(id):
		push_error("LoopbackHub.add_endpoint: %s is already registered" % id)
		return null
	var endpoint := LoopbackTransportScript.new(self, id)
	_endpoints[id] = endpoint
	_endpoint_order.append(id)
	return endpoint


## Advances the clock exactly one tick and delivers every message whose
## delivery tick is now due, in (send_tick, sequence) order.
func step() -> void:
	_current_tick += 1
	var due: Array[PendingMessage] = []
	var remaining: Array[PendingMessage] = []
	for message in _pending:
		if message.delivery_tick <= _current_tick:
			due.append(message)
		else:
			remaining.append(message)
	_pending = remaining
	due.sort_custom(_less_than)
	for message in due:
		var endpoint: LoopbackTransportScript = _endpoints.get(message.recipient_id)
		if endpoint != null:
			endpoint.receive(message.payload)


func current_tick() -> int:
	return _current_tick


## Hub-only: called by a CONNECTED LoopbackTransport's send(). Walks every
## currently-connected endpoint in registration order and, for each,
## independently draws jitter then rolls loss — this fixed per-recipient
## order (jitter, then loss; recipients ascending by registration index) is
## what two hubs with the same seed and the same send script reproduce
## byte-for-byte. A disconnected endpoint is not a recipient at all: it is
## skipped before any draw, so it consumes no randomness and cannot receive
## this message.
##
## Every relay->recipient link is also kept FIFO: a link models a single
## reliable, ordered connection (WebSocket/TCP, ENet reliable-ordered — see
## docs/architecture/network-multiplayer.md, decision 6), and no real
## transport in that set can reorder its own stream, so this loopback must
## not invent reorderings a real transport cannot produce. _link_next_free_tick
## tracks, per recipient, the delivery tick already committed to that link;
## a new message's tick is clamped up to that floor and the floor then
## advances to match. A lost message never claims a floor, since it never
## actually occupies the link.
func route(payload: PackedByteArray) -> void:
	var send_tick := _current_tick
	var sequence := _next_sequence
	_next_sequence += 1
	for id in _endpoint_order:
		var endpoint: LoopbackTransportScript = _endpoints[id]
		if endpoint.state() != NetTransportScript.State.CONNECTED:
			continue
		var jitter := _rng.randi_range(-jitter_ticks, jitter_ticks)
		var target := maxi(send_tick + 1, send_tick + latency_ticks + jitter)
		var link_floor: int = _link_next_free_tick.get(id, 0)
		var delivery_tick := maxi(target, link_floor)
		var roll := _rng.randi_range(1, 1000)
		if roll <= loss_permille:
			continue
		_link_next_free_tick[id] = delivery_tick
		var message := PendingMessage.new()
		message.recipient_id = id
		message.payload = payload
		message.send_tick = send_tick
		message.sequence = sequence
		message.delivery_tick = delivery_tick
		_pending.append(message)


## Hub-only: called by a LoopbackTransport's close(). Removes every message
## still scheduled for delivery to `id`; messages already delivered into its
## inbox (and not yet polled) are untouched, and messages `id` itself sent
## before closing keep going to their other, still-open recipients.
func discard_pending_for(id: StringName) -> void:
	var kept: Array[PendingMessage] = []
	for message in _pending:
		if message.recipient_id != id:
			kept.append(message)
	_pending = kept


func _less_than(a: PendingMessage, b: PendingMessage) -> bool:
	if a.send_tick != b.send_tick:
		return a.send_tick < b.send_tick
	return a.sequence < b.sequence
