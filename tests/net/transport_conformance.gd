class_name TransportConformance
extends RefCounted

## Assertions that must hold for *every* NetTransport implementation --
## contract-level, not implementation-level. Ordering, latency and loss stay
## in tests/net/loopback_run.gd; connect/reject specifics stay in
## tests/net/websocket_transport_run.gd. This suite runs once from each of
## those (and would run again unchanged for a future ENet transport -- see
## docs/architecture/network-multiplayer.md, decision 6), so the
## implementations cannot silently drift apart on the basics.
##
## Driven, not driving: this file never constructs a transport, a
## LoopbackHub or a RelayServer itself. Everything implementation-specific
## comes in through callables the caller supplies, plus the caller's own
## _expect to record results into:
##
## - `make_transport`: () -> NetTransport. Returns a fresh transport, not yet
##   opened, wired to a medium shared by every transport this callable
##   produces during one run() call (one LoopbackHub; one relay room address
##   baked into the closure) -- so a transport this callable returns can hear
##   its own sends once opened (fan-out-to-self, see _test_self_fanout).
## - `open_transport`: (NetTransport) -> void. Opens `transport` against that
##   shared medium. Kept separate from make_transport, rather than folding
##   open() into construction, because _test_send_before_open needs an
##   unopened instance and the fan-out/drain assertions need an opened one --
##   one factory cannot honestly hand back both.
## - `pump`: () -> void. Advances the world by one step -- LoopbackHub.step()
##   for the loopback, one real-time pump of the relay server for WebSocket.
##   Used to wait for a freshly opened transport to reach CONNECTED and to
##   wait for a sent payload to be delivered, both bounded by
##   max_pump_iterations so a divergent implementation fails the assertion
##   instead of hanging the suite.
## - `expect`: the calling suite's _expect(condition, message), e.g.
##   `Callable(self, "_expect")` -- bound so failures are attributed to the
##   caller's own suite output.
##
## Every wait here also calls the transport's own poll() directly, in
## addition to `pump`: poll() is the one place a real WebSocket transport is
## not a pure mirror of the loopback (see websocket_transport.gd's class doc
## comment -- it must be pumped every tick regardless of whether the caller
## wants data), and `pump` alone only advances the *server* side of a
## WebSocket run, not the client transport's own socket.

const NetTransportScript := preload("res://scripts/net/net_transport.gd")

const DEFAULT_MAX_PUMP_ITERATIONS := 2000


static func run(
	expect: Callable,
	make_transport: Callable,
	open_transport: Callable,
	pump: Callable,
	max_pump_iterations: int = DEFAULT_MAX_PUMP_ITERATIONS,
) -> void:
	_test_self_fanout(expect, make_transport, open_transport, pump, max_pump_iterations)
	_test_poll_drains(expect, make_transport, open_transport, pump, max_pump_iterations)
	_test_send_before_open_is_noop(expect, make_transport)
	_test_close_moves_to_disconnected_and_is_idempotent(expect, make_transport, open_transport, pump, max_pump_iterations)
	_test_send_after_close_is_noop(expect, make_transport, open_transport, pump, max_pump_iterations)


## 1. A payload sent while CONNECTED comes back to the sender: fan-out-to-self
## holds for both the loopback (LoopbackHub.route() walks every connected
## endpoint, including the sender) and the relay (RelayServer._broadcast()
## does the same -- see relay_server.gd's class doc comment). A single
## transport, talking only to itself, is enough to exercise it.
static func _test_self_fanout(
	expect: Callable, make_transport: Callable, open_transport: Callable, pump: Callable, max_pump_iterations: int
) -> void:
	var transport = make_transport.call()
	open_transport.call(transport)
	var connected := _await_connected(transport, pump, max_pump_iterations)
	expect.call(connected, "a freshly opened transport must reach CONNECTED within the pump bound")
	if not connected:
		return

	transport.send("self-fanout".to_utf8_buffer())
	var received := _await_payload(transport, pump, max_pump_iterations)
	expect.call(
		received.size() >= 1 and received[0].get_string_from_utf8() == "self-fanout",
		"a payload sent while CONNECTED must come back to the sender (fan-out-to-self)"
	)
	transport.close()


## 2. poll() drains: an immediate second call, with no intervening pump,
## returns empty.
static func _test_poll_drains(
	expect: Callable, make_transport: Callable, open_transport: Callable, pump: Callable, max_pump_iterations: int
) -> void:
	var transport = make_transport.call()
	open_transport.call(transport)
	if not _await_connected(transport, pump, max_pump_iterations):
		expect.call(false, "setup: transport must reach CONNECTED to test poll() draining")
		return

	transport.send("drain-me".to_utf8_buffer())
	var first := _await_payload(transport, pump, max_pump_iterations)
	expect.call(first.size() >= 1, "setup: the payload must actually arrive before testing drain")
	var second: Array[PackedByteArray] = transport.poll()
	expect.call(second.is_empty(), "poll() must drain: an immediate second call returns empty")
	transport.close()


## 3. send() before open() is a no-op: it must not change state() and must
## record last_error().
static func _test_send_before_open_is_noop(expect: Callable, make_transport: Callable) -> void:
	var transport = make_transport.call()
	var state_before: NetTransportScript.State = transport.state()
	transport.send("too-early".to_utf8_buffer())
	expect.call(transport.state() == state_before, "send() before open() must not change state()")
	expect.call(transport.last_error() != "", "send() before open() must record last_error()")


## 4. close() moves state() to DISCONNECTED and is idempotent.
static func _test_close_moves_to_disconnected_and_is_idempotent(
	expect: Callable, make_transport: Callable, open_transport: Callable, pump: Callable, max_pump_iterations: int
) -> void:
	var transport = make_transport.call()
	open_transport.call(transport)
	expect.call(
		_await_connected(transport, pump, max_pump_iterations),
		"setup: transport must reach CONNECTED before testing close()"
	)

	transport.close()
	expect.call(
		transport.state() == NetTransportScript.State.DISCONNECTED, "close() must move state() to DISCONNECTED"
	)
	transport.close()
	expect.call(
		transport.state() == NetTransportScript.State.DISCONNECTED,
		"calling close() again must leave state() at DISCONNECTED (idempotent)"
	)


## 5. send() after close() is a no-op: it must not change state() away from
## DISCONNECTED and must record last_error().
static func _test_send_after_close_is_noop(
	expect: Callable, make_transport: Callable, open_transport: Callable, pump: Callable, max_pump_iterations: int
) -> void:
	var transport = make_transport.call()
	open_transport.call(transport)
	expect.call(
		_await_connected(transport, pump, max_pump_iterations),
		"setup: transport must reach CONNECTED before testing send() after close()"
	)

	transport.close()
	transport.send("after-close".to_utf8_buffer())
	expect.call(
		transport.state() == NetTransportScript.State.DISCONNECTED, "send() after close() must not change state()"
	)
	expect.call(transport.last_error() != "", "send() after close() must record last_error()")


## Pumps both the transport's own poll() and the caller's `pump` until
## state() reports CONNECTED or `max_pump_iterations` is exhausted, whichever
## comes first.
static func _await_connected(transport, pump: Callable, max_pump_iterations: int) -> bool:
	for _i in range(max_pump_iterations):
		transport.poll()
		if transport.state() == NetTransportScript.State.CONNECTED:
			return true
		pump.call()
	transport.poll()
	return transport.state() == NetTransportScript.State.CONNECTED


## Pumps both the transport's own poll() and the caller's `pump` until
## poll() returns at least one payload or `max_pump_iterations` is exhausted,
## returning whatever was collected (possibly empty, on timeout).
static func _await_payload(transport, pump: Callable, max_pump_iterations: int) -> Array[PackedByteArray]:
	var received: Array[PackedByteArray] = []
	for _i in range(max_pump_iterations):
		received.append_array(transport.poll())
		if not received.is_empty():
			return received
		pump.call()
	return received
