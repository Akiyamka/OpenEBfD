extends SceneTree

## Godot-side half of the Nagle measurement driven by tools/measure_nagle.py
## -- see that script's module doc comment for what is being measured, why,
## and why the controls it runs alongside this one are the part that makes
## the result mean anything. Not a test suite: nothing here asserts, and
## tools/run_godot_tests.sh deliberately does not list it. It produces one
## side of a timing trace; the verdict is computed in Python.
##
## Shape: `rounds` independent connections, each opening a fresh
## WebSocketTransport, sending `burst` small frames `interval-msec` apart --
## one frame per poll(), so one frame per socket write -- then closing. One
## connection per round rather than one long connection is not incidental:
## Nagle's delay is only observable while the receiver is still delaying its
## ACKs, and Linux stops doing that within the first few round trips of a
## steady stream. Measured directly while building this probe: over a single
## connection the effect fires exactly once no matter how many frames are
## sent, so a long connection yields one sample per run, while a fresh
## connection per round yields one per round.
##
## It prints its own send timestamps (SEND lines), and that is not redundant
## with the receiver's arrival trace. Without them, frames arriving bunched
## is ambiguous between "Nagle held them" and "they were never written
## separately in the first place" -- a peer that flushed several frames in
## one write would look identical at the receiver. The two traces together
## separate those, and tools/measure_nagle.py refuses to draw a conclusion
## when they disagree.
##
## Deliberately blocking: OS.delay_msec() rather than a timer or await. This
## is a standalone script with no scene and no frame loop, the spacing is the
## experiment's independent variable and has to be as exact as this process
## can make it, and precise blocking spacing is far easier to reason about
## here than a frame-driven approximation of it.

const WebSocketTransportScript := preload("res://scripts/net/websocket_transport.gd")
const NetTransportScript := preload("res://scripts/net/net_transport.gd")

const CONNECT_TIMEOUT_MSEC := 5000
const CONNECT_POLL_SLEEP_MSEC := 1
const WARMUP_POLL_SLEEP_MSEC := 1
## Frames are handed to WebSocketPeer, not to the socket: after the last
## send() the peer still has to be pumped for its outbound buffer to drain,
## and closing before it has drained would truncate the round. Long enough to
## cover a fully Nagle-delayed flush (~40 ms on Linux) with margin.
const SETTLE_MSEC := 120
const SETTLE_POLL_SLEEP_MSEC := 1


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var port := int(args.get("port", 0))
	if port <= 0:
		printerr("nagle probe: --port is required")
		quit(2)
		return
	var room := String(args.get("room", "nagle"))
	var rounds := int(args.get("rounds", 15))
	var burst := int(args.get("burst", 3))
	var interval_msec := int(args.get("interval-msec", 10))
	var payload_bytes := int(args.get("payload-bytes", 16))
	var warmup_msec := int(args.get("warmup-msec", 60))

	for round_index in rounds:
		if not _run_round(port, room, round_index, burst, interval_msec, payload_bytes, warmup_msec):
			quit(1)
			return
	print("DONE %d" % rounds)
	quit(0)


## One connection: open, send `burst` frames one poll() apart, let the peer
## drain, close. Returns false once anything has gone wrong, so a partial
## trace is never mistaken for a complete one.
func _run_round(
	port: int,
	room: String,
	round_index: int,
	burst: int,
	interval_msec: int,
	payload_bytes: int,
	warmup_msec: int
) -> bool:
	var transport := WebSocketTransportScript.new()
	transport.connect_timeout_msec = CONNECT_TIMEOUT_MSEC
	transport.open("ws://127.0.0.1:%d/%s" % [port, room])
	if not _await_connected(transport, round_index):
		return false

	# Let the connection fall silent before the burst starts -- see
	# quiet_after_handshake() in tools/measure_nagle.py for why this is load
	# bearing rather than tidiness. Still polling, because the peer has to be
	# pumped for the handshake's own bytes to finish moving.
	var warmup_deadline := Time.get_ticks_msec() + warmup_msec
	while Time.get_ticks_msec() < warmup_deadline:
		transport.poll()
		OS.delay_msec(WARMUP_POLL_SLEEP_MSEC)

	for index in burst:
		transport.send(_frame_payload(index, payload_bytes))
		transport.poll()
		# Recorded after poll(), so it is the moment the frame reached the
		# socket rather than the moment it was queued -- only the former is
		# comparable with the receiver's arrival timestamps.
		print("SEND %d %d %d" % [round_index, index, Time.get_ticks_usec()])
		if transport.state() != NetTransportScript.State.CONNECTED:
			printerr(
				(
					"nagle probe: transport left CONNECTED in round %d at frame %d: %s"
					% [round_index, index, transport.last_error()]
				)
			)
			return false
		if interval_msec > 0:
			OS.delay_msec(interval_msec)

	var settle_deadline := Time.get_ticks_msec() + SETTLE_MSEC
	while Time.get_ticks_msec() < settle_deadline:
		transport.poll()
		OS.delay_msec(SETTLE_POLL_SLEEP_MSEC)
	transport.close()
	transport.poll()
	return true


## Pumps until the transport resolves out of CONNECTING, reporting the
## failure by name rather than letting a bad endpoint look like an empty
## round. Bounded by the transport's own connect_timeout_msec plus a margin,
## so it cannot outlive the timeout it is waiting on.
func _await_connected(transport: WebSocketTransportScript, round_index: int) -> bool:
	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MSEC * 2
	while Time.get_ticks_msec() < deadline:
		transport.poll()
		match transport.state():
			NetTransportScript.State.CONNECTED:
				return true
			NetTransportScript.State.FAILED:
				printerr(
					"nagle probe: connect failed in round %d: %s" % [round_index, transport.last_error()]
				)
				return false
			_:
				OS.delay_msec(CONNECT_POLL_SLEEP_MSEC)
	printerr(
		"nagle probe: connect did not resolve within %d ms in round %d" % [CONNECT_TIMEOUT_MSEC * 2, round_index]
	)
	return false


## `index` in the first four bytes so the receiver can name a frame it never
## got; the rest is padding to the requested size. Small and fixed-size on
## purpose: Nagle only ever withholds a segment smaller than the MSS, so a
## payload that grew past it would silently stop testing anything.
func _frame_payload(index: int, payload_bytes: int) -> PackedByteArray:
	var payload := PackedByteArray()
	payload.resize(maxi(4, payload_bytes))
	payload.encode_u32(0, index)
	return payload


## Accepts only `--key value` pairs; anything else is a typo in the caller
## and is reported rather than ignored, because a silently dropped --rounds
## would still produce a plausible-looking trace at the wrong length.
func _parse_args(argv: PackedStringArray) -> Dictionary:
	var parsed: Dictionary = {}
	var index := 0
	while index < argv.size():
		var key := argv[index]
		if not key.begins_with("--") or index + 1 >= argv.size():
			printerr("nagle probe: unexpected argument %s" % key)
			index += 1
			continue
		parsed[key.substr(2)] = argv[index + 1]
		index += 2
	return parsed
