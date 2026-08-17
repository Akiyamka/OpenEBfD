extends "res://tests/support/suite.gd"

## Pins down the loopback transport contract from
## docs/architecture/network-multiplayer.md ("WebSocket behind a transport
## interface"): delivery timing, per-recipient loss, per-recipient jitter,
## per-link FIFO ordering, deterministic ordering, close() semantics and the
## NetTransport base class's loud-failure guard. Time here is simulation
## ticks, advanced only by LoopbackHub.step() — nothing in this suite waits
## on engine time.

const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const NetTransportScript := preload("res://scripts/net/net_transport.gd")
const TransportConformanceScript := preload("res://tests/net/transport_conformance.gd")


func _initialize() -> void:
	_run_case(
		"shared NetTransport conformance suite holds for LoopbackTransport", _test_conformance_suite
	)
	_run_case("zero latency: sender and peer both receive after one step", _test_zero_latency)
	_run_case("latency_ticks=3 delays delivery by exactly three steps", _test_fixed_latency)
	_run_case(
		"same seed reproduces the delivery log; a different seed diverges it", _test_determinism
	)
	_run_case(
		"the declared rng_seed default is the effective default, with no seed ever assigned",
		_test_default_seed_is_deterministic
	)
	_run_case("loss_permille extremes: 1000 drops everything, 0 drops nothing", _test_loss_extremes)
	_run_case("loss is drawn independently per recipient", _test_partial_loss)
	_run_case(
		"jitter is drawn independently per recipient, not shared by the whole message",
		_test_jitter_differs_per_recipient
	)
	_run_case(
		"each relay link is FIFO and never delivers at or before the send tick",
		_test_fifo_link_and_send_tick_bound
	)
	_run_case("same-tick delivery order follows the sequence counter", _test_same_tick_order)
	_run_case(
		"close() disconnects, discards in-flight delivery, keeps received payloads pollable",
		_test_close_semantics
	)
	_run_case("poll() drains: a second immediate poll returns nothing", _test_poll_drains)
	_run_case(
		"the base class fails loudly when a method is not overridden",
		_test_base_class_reports_errors
	)
	_finish("Loopback transport tests")


## Runs tests/net/transport_conformance.gd against LoopbackTransport -- see
## that file's doc comment for what it checks and why it is shared with
## tests/net/websocket_transport_run.gd. Each call to `make_transport` needs
## its own unique endpoint id (LoopbackHub.add_endpoint() errors on a
## duplicate), hence the counter; it is wrapped in a one-element array so the
## closure mutates the same cell regardless of GDScript's lambda-capture
## semantics for plain local variables.
func _test_conformance_suite() -> void:
	var hub := LoopbackHubScript.new()
	var next_id := [0]
	var make_transport := func():
		next_id[0] += 1
		return hub.add_endpoint(StringName("conformance-%d" % next_id[0]))
	var open_transport := func(transport): transport.open("")
	var pump := func(): hub.step()
	TransportConformanceScript.run(Callable(self, "_expect"), make_transport, open_transport, pump)


func _test_zero_latency() -> void:
	var hub := LoopbackHubScript.new()
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	a.open("")
	b.open("")

	a.send("hello".to_utf8_buffer())
	hub.step()

	var a_inbox := a.poll()
	var b_inbox := b.poll()
	_expect(
		a_inbox.size() == 1 and a_inbox[0].get_string_from_utf8() == "hello",
		"the sender must receive its own zero-latency payload after one step"
	)
	_expect(
		b_inbox.size() == 1 and b_inbox[0].get_string_from_utf8() == "hello",
		"the peer must receive the zero-latency payload after one step"
	)


func _test_fixed_latency() -> void:
	var hub := LoopbackHubScript.new()
	hub.latency_ticks = 3
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	a.open("")
	b.open("")

	a.send("delayed".to_utf8_buffer())

	hub.step()
	_expect(b.poll().is_empty(), "nothing may arrive after 1 of 3 latency ticks")
	hub.step()
	_expect(b.poll().is_empty(), "nothing may arrive after 2 of 3 latency ticks")
	hub.step()
	var inbox := b.poll()
	_expect(
		inbox.size() == 1 and inbox[0].get_string_from_utf8() == "delayed",
		"the payload must arrive exactly on the 3rd step"
	)


func _test_determinism() -> void:
	var log_a := _run_determinism_script(42)
	var log_b := _run_determinism_script(42)
	_expect(
		log_a == log_b,
		"two hubs given the same seed and the same send script must produce identical delivery logs"
	)

	var log_c := _run_determinism_script(999)
	_expect(
		log_a != log_c,
		"a different seed must actually be consulted, and change the delivery log"
	)


func _run_determinism_script(seed_value: int) -> Array[String]:
	var hub := LoopbackHubScript.new()
	hub.latency_ticks = 2
	hub.jitter_ticks = 1
	hub.loss_permille = 200
	hub.rng_seed = seed_value
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	var c := hub.add_endpoint(&"C")
	a.open("")
	b.open("")
	c.open("")

	var log: Array[String] = []
	for i in range(10):
		a.send(("msg-%d" % i).to_utf8_buffer())
		hub.step()
		for entry in [["A", a], ["B", b], ["C", c]]:
			for payload in entry[1].poll():
				log.append("%d:%s:%s" % [hub.current_tick(), entry[0], payload.get_string_from_utf8()])
	return log


## Regression for a real bug: `var rng_seed := 0: set(value): ...` does not
## run its own `set` callback while GDScript evaluates that initializer, so a
## hub that never assigns rng_seed used to keep whatever seed
## RandomNumberGenerator.new() drew from OS entropy instead of the declared
## default (0) — two such hubs would silently diverge. LoopbackHub._init()
## now seeds `_rng` explicitly from `rng_seed`, closing the gap. Two
## independently constructed hubs here never touch rng_seed at all.
func _test_default_seed_is_deterministic() -> void:
	var log_a := _run_default_seed_script()
	var log_b := _run_default_seed_script()
	_expect(
		log_a == log_b,
		"two hubs that never assign rng_seed must still produce identical delivery logs"
	)


func _run_default_seed_script() -> Array[String]:
	var hub := LoopbackHubScript.new()
	hub.jitter_ticks = 3
	hub.loss_permille = 300
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	var c := hub.add_endpoint(&"C")
	a.open("")
	b.open("")
	c.open("")

	var log: Array[String] = []
	for i in range(10):
		a.send(("msg-%d" % i).to_utf8_buffer())
		hub.step()
		for entry in [["A", a], ["B", b], ["C", c]]:
			for payload in entry[1].poll():
				log.append("%d:%s:%s" % [hub.current_tick(), entry[0], payload.get_string_from_utf8()])
	return log


func _test_loss_extremes() -> void:
	var hub_all_lost := LoopbackHubScript.new()
	hub_all_lost.loss_permille = 1000
	var a1 := hub_all_lost.add_endpoint(&"A")
	var b1 := hub_all_lost.add_endpoint(&"B")
	a1.open("")
	b1.open("")
	for i in range(20):
		a1.send(("x%d" % i).to_utf8_buffer())
	hub_all_lost.step()
	_expect(
		a1.poll().is_empty() and b1.poll().is_empty(),
		"loss_permille=1000 must deliver nothing, including to the sender"
	)

	var hub_none_lost := LoopbackHubScript.new()
	hub_none_lost.loss_permille = 0
	var a2 := hub_none_lost.add_endpoint(&"A")
	var b2 := hub_none_lost.add_endpoint(&"B")
	a2.open("")
	b2.open("")
	for i in range(20):
		a2.send(("y%d" % i).to_utf8_buffer())
	hub_none_lost.step()
	_expect(
		a2.poll().size() == 20 and b2.poll().size() == 20,
		"loss_permille=0 must deliver every message to every recipient"
	)


## Exact expected log for rng_seed=7, loss_permille=500, three endpoints and
## eight sends, pinned down by construction rather than a probabilistic
## bound: it was captured by running this scenario once, and re-running it
## proves both the per-recipient independence (B and C diverge) and that the
## same seed reproduces the same log (already covered on its own by
## _test_determinism above). jitter_ticks is left at its default (0) here on
## purpose: RandomNumberGenerator.randi_range(0, 0) is a documented no-op
## that does not advance the generator's state, so this log is unaffected by
## jitter having moved from one draw per message to one draw per recipient.
func _test_partial_loss() -> void:
	var hub := LoopbackHubScript.new()
	hub.loss_permille = 500
	hub.rng_seed = 7
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	var c := hub.add_endpoint(&"C")
	a.open("")
	b.open("")
	c.open("")

	var received: Dictionary = {"A": [], "B": [], "C": []}
	for i in range(8):
		a.send(("m%d" % i).to_utf8_buffer())
		hub.step()
		for entry in [["A", a], ["B", b], ["C", c]]:
			for payload in entry[1].poll():
				received[entry[0]].append(payload.get_string_from_utf8())

	_expect(
		received["A"] == ["m0", "m1", "m2", "m4", "m6", "m7"],
		"A's exact per-recipient delivery log must match the fixed seed"
	)
	_expect(
		received["B"] == ["m0", "m2", "m7"],
		"B's exact per-recipient delivery log must match the fixed seed"
	)
	_expect(
		received["C"] == ["m4"],
		"C's exact per-recipient delivery log must match the fixed seed"
	)
	_expect(
		received["B"] != received["C"],
		"one message must reach some peers and not others in the same run"
	)


## Pinned to rng_seed=5: with a shared, per-message jitter draw (the original,
## wrong spec) every recipient always lands on the same delivery tick — this
## is the exact scenario the coordinator's review used to demonstrate the
## bug (jitter_ticks=4, one send, three recipients, all landing on tick 2).
## With jitter drawn independently per recipient, this seed's three draws
## put C on a different tick than A and B.
func _test_jitter_differs_per_recipient() -> void:
	var hub := LoopbackHubScript.new()
	hub.jitter_ticks = 4
	hub.rng_seed = 5
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	var c := hub.add_endpoint(&"C")
	a.open("")
	b.open("")
	c.open("")

	a.send("frame".to_utf8_buffer())

	var arrival_tick: Dictionary = {}
	for i in range(10):
		hub.step()
		for entry in [["A", a], ["B", b], ["C", c]]:
			if not entry[1].poll().is_empty():
				arrival_tick[entry[0]] = hub.current_tick()

	_expect(
		arrival_tick.size() == 3,
		"the single send must eventually reach all three connected endpoints"
	)
	_expect(arrival_tick["A"] == 1, "A's exact arrival tick must match the fixed seed")
	_expect(arrival_tick["B"] == 1, "B's exact arrival tick must match the fixed seed")
	_expect(arrival_tick["C"] == 3, "C's exact arrival tick must match the fixed seed")
	_expect(
		arrival_tick["A"] != arrival_tick["C"],
		"jitter must be drawn independently per recipient, not once for the whole message"
	)


## A relay->recipient link stands in for one real, reliable, ordered
## connection (WebSocket/TCP, ENet reliable-ordered), and no transport in
## that set can reorder its own stream — so this loopback must not invent
## reorderings either. Heavy jitter (well past latency_ticks=0, so raw
## per-recipient draws would frequently cross each other) over a long run:
## each endpoint's own received order must exactly match ascending send
## order. Verified by deliberately removing the FIFO clamp in route() and
## confirming this case fails.
##
## _collect_origin_ticks() below also checks that no payload is ever
## observed on or before its own send tick — this holds today, but, like the
## `maxi(send_tick + 1, ...)` floor it exercises, it cannot actually be made
## to fail through this public interface: step() always advances exactly one
## tick per call and checks pending messages with `<=`, so the earliest any
## message can first be found due is send_tick + 1 regardless of how far
## below that its raw (jitter/latency, or even FIFO-clamped) delivery_tick
## was computed — removing the floor and rerunning this suite still passes.
## The assertion stays as cheap defense-in-depth (it does catch, for
## instance, a sign error that pushed delivery_tick below send_tick by more
## than the FIFO floor could hide), not as a claim that this case exercises
## the floor.
func _test_fifo_link_and_send_tick_bound() -> void:
	var hub := LoopbackHubScript.new()
	hub.jitter_ticks = 6
	hub.rng_seed = 11
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	var c := hub.add_endpoint(&"C")
	a.open("")
	b.open("")
	c.open("")

	var sent := 0
	var received_b: Array[int] = []
	var received_c: Array[int] = []
	for i in range(40):
		var send_tick := hub.current_tick()
		a.send(("%d" % send_tick).to_utf8_buffer())
		sent += 1
		hub.step()
		_collect_origin_ticks(hub, b, received_b)
		_collect_origin_ticks(hub, c, received_c)
	for i in range(15):
		hub.step()
		_collect_origin_ticks(hub, b, received_b)
		_collect_origin_ticks(hub, c, received_c)

	_expect(
		received_b.size() == sent and received_c.size() == sent,
		"every send must eventually reach every recipient so the ordering check is not vacuous"
	)
	_expect(
		_is_strictly_ascending(received_b),
		"B must observe every payload in strictly ascending send order (its link is FIFO)"
	)
	_expect(
		_is_strictly_ascending(received_c),
		"C must observe every payload in strictly ascending send order (its link is FIFO)"
	)


## Appends the embedded origin send tick of every payload endpoint just
## received to `origins`, and asserts each one arrived strictly after it was
## sent — the clamp this exercises (delivery tick >= send_tick + 1) has no
## other test naming it directly.
func _collect_origin_ticks(hub, endpoint, origins: Array[int]) -> void:
	for payload in endpoint.poll():
		var origin_tick := int(payload.get_string_from_utf8())
		_expect(
			hub.current_tick() > origin_tick,
			"delivery tick %d must be strictly after send tick %d" % [hub.current_tick(), origin_tick]
		)
		origins.append(origin_tick)


func _is_strictly_ascending(values: Array[int]) -> bool:
	for i in range(1, values.size()):
		if values[i] <= values[i - 1]:
			return false
	return true


func _test_same_tick_order() -> void:
	var hub := LoopbackHubScript.new()
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	var c := hub.add_endpoint(&"C")
	a.open("")
	b.open("")
	c.open("")

	a.send("first".to_utf8_buffer())
	b.send("second".to_utf8_buffer())
	c.send("third".to_utf8_buffer())
	hub.step()

	var expected: Array[String] = ["first", "second", "third"]
	for entry in [["A", a], ["B", b], ["C", c]]:
		var texts: Array[String] = []
		for payload in entry[1].poll():
			texts.append(payload.get_string_from_utf8())
		_expect(
			texts == expected,
			"%s must observe the three same-tick sends ordered by the sequence counter" % entry[0]
		)


func _test_close_semantics() -> void:
	var hub := LoopbackHubScript.new()
	hub.latency_ticks = 1
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	a.open("")
	b.open("")

	a.send("delivered-before-close".to_utf8_buffer())
	hub.step()

	hub.latency_ticks = 10
	a.send("in-flight-at-close".to_utf8_buffer())
	b.close()

	_expect(
		b.state() == NetTransportScript.State.DISCONNECTED,
		"close() must move state() to DISCONNECTED"
	)

	b.send("after-close".to_utf8_buffer())
	_expect(b.last_error() != "", "a send after close() must record last_error()")

	var first_poll := b.poll()
	_expect(
		first_poll.size() == 1 and first_poll[0].get_string_from_utf8() == "delivered-before-close",
		"a payload already received before close() must stay pollable"
	)
	_expect(b.poll().is_empty(), "poll() must drain: the already-received payload is returned only once")

	for i in range(15):
		hub.step()
	_expect(
		b.poll().is_empty(),
		"a message still in flight toward the closed endpoint at close() time must be discarded"
	)

	var found_in_flight := false
	for payload in a.poll():
		if payload.get_string_from_utf8() == "in-flight-at-close":
			found_in_flight = true
	_expect(
		found_in_flight,
		"closing one endpoint must not cancel the same broadcast toward other, still-open recipients"
	)


func _test_poll_drains() -> void:
	var hub := LoopbackHubScript.new()
	var a := hub.add_endpoint(&"A")
	var b := hub.add_endpoint(&"B")
	a.open("")
	b.open("")

	a.send("once".to_utf8_buffer())
	hub.step()

	var first := b.poll()
	_expect(first.size() == 1, "the first poll() after delivery must return the payload")
	var second := b.poll()
	_expect(second.is_empty(), "an immediate second poll() must return nothing: poll() drains")


func _test_base_class_reports_errors() -> void:
	var base := NetTransportScript.new()
	# Each call below is expected to push_error() naming the method (visible
	# in this run's stderr as "NetTransport.<method>() was not
	# overridden..."); GDScript gives tests no hook to intercept push_error's
	# text, so this case instead pins down the other half of the contract: a
	# subclass that forgets to override still cannot crash its caller or read
	# as success.
	base.open("irrelevant")
	base.close()
	base.send(PackedByteArray())
	_expect(base.poll().is_empty(), "an un-overridden poll() must still return a safe empty array")
	_expect(
		base.state() == NetTransportScript.State.DISCONNECTED,
		"an un-overridden state() must still return a safe default"
	)
	_expect(base.last_error() == "", "an un-overridden last_error() must still return a safe empty string")
