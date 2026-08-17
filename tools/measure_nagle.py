#!/usr/bin/env python3
"""Measure whether Nagle's algorithm is enabled on the two TCP links the
lockstep netcode runs over: client -> relay (Godot's WebSocketPeer as a
client, res://scripts/net/websocket_transport.gd) and relay -> client (the
stream RelayServer accepts from TCPServer, res://scripts/net/relay/relay_server.gd).

Why measure rather than assume: in lockstep every turn sends one small frame
and cannot advance until the other players' frames for that turn arrive.
Nagle withholds a small write while earlier small data is still
unacknowledged, so paired with the receiver's delayed ACK it can hold a frame
for tens of milliseconds, per turn, on top of the real network. That is
larger than the entire ENet-versus-TCP gap this project decided not to chase
(docs/architecture/network-multiplayer.md, decision 6), which is why that
decision records this as an open question to settle before designing around
it.

## What the measurement does

Nagle is invisible when a sender writes once and waits: with nothing
unacknowledged outstanding, a small write goes out immediately either way. It
becomes observable only when small writes follow each other faster than they
can be acknowledged. So each round opens a connection, sends a short burst of
small frames -- one frame per write, spaced well under the delayed-ACK timer
-- and the receiver timestamps their arrival:

  Nagle off: arrivals track the sends, one every `interval` ms.
  Nagle on:  the first frame goes out, the rest are withheld until the ACK
             for it comes back, then flush together. Sends stay evenly
             spaced; arrivals bunch behind one long gap.

The receiver stays silent for the whole burst. That is deliberate: any
response would carry a piggybacked ACK, releasing Nagle immediately and
hiding the effect being measured. It does send exactly one frame before the
timing starts, which is equally deliberate and for the opposite reason -- see
poke_to_enter_pingpong().

## Why one connection per round

Measured while building this: over a single connection the delay fires
exactly once, near the start, however many frames are sent -- Linux adapts
its delayed-ACK timer to a steady stream within a few round trips and then
stops delaying. A single long connection therefore yields one sample per run
(and a 1-in-300 event is indistinguishable from a scheduling hiccup), while a
fresh connection per round yields one sample per round. With 15 rounds the
positive and negative controls separated 15-to-0.

## Why the controls are the important part

"No delay observed" means "Nagle is off" only if this harness could have
observed a delay at all -- on a kernel or machine where the effect does not
reproduce, a broken harness and a healthy transport print the same thing. So
every direction is measured three ways: a Python peer with Nagle deliberately
left on, a Python peer with TCP_NODELAY deliberately set, and the real thing.
The first two are the positive and negative controls. If they fail to
separate, the direction is reported INCONCLUSIVE and no claim is made about
Godot, rather than the reassuring answer being printed by default.

The subject's own send trace is checked too. Bunched arrivals are ambiguous
between "Nagle held these frames" and "they were never written separately",
and a peer that flushed a whole burst in one write would look exactly like a
healthy one. A round whose arrivals are markedly tighter than its sends is
counted as batched, and enough of those also make the direction
INCONCLUSIVE.

## What it cannot tell you

Everything here runs over loopback, where the round trip is microseconds and
the delay Nagle imposes is therefore bounded by the receiver's delayed-ACK
timer (~40 ms on Linux). On a real link the bound is the round trip instead.
So the numbers below answer "is TCP_NODELAY set on this socket" -- a yes/no
-- and must not be read as "Nagle would cost this many milliseconds in a real
match".

## Running it

Runs inside the Godot container, the one place `godot` and `python3` share a
loopback interface:

    make measure-nagle

This is a measurement, not a test: it reports numbers rather than asserting
them, and tools/run_godot_tests.sh does not list it.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
from collections import deque

WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OPCODE_BINARY = 0x2
OPCODE_CLOSE = 0x8

# How much longer than the sender's own spacing a gap has to be before it
# counts as Nagle rather than noise. The delay being looked for is a
# delayed-ACK wait, ~40 ms on Linux; loopback jitter and a headless Godot's
# poll loop are millisecond-scale. 10 ms sits well clear of both.
STALL_EXCESS_MSEC = 10.0

# Rounds that must stall for a run to count as showing Nagle. The controls
# separated 15-to-0 when this was written, so anything in between is a
# malfunctioning harness rather than a close call -- which is why the two
# controls are checked against this same number from both sides.
MIN_STALL_ROUNDS = 3


# --------------------------------------------------------------------------
# WebSocket, hand-rolled
#
# Only what a probe needs: binary frames, no extensions, no fragmentation, no
# continuation frames. Godot's WebSocketPeer sends each send() as one
# unfragmented frame, so nothing here has to reassemble.
# --------------------------------------------------------------------------


class TimedReader:
    """Buffered socket reader that remembers *when* each byte arrived.

    The point of the class: a frame's arrival time is the time of the recv()
    that completed it, not the time parsing finished. Reading one frame takes
    several read_exact() calls (header, maybe extended length, maybe mask,
    payload), and only the last of them marks when the frame was actually on
    the wire -- so each read returns the timestamp of the recv() that
    delivered its final byte.
    """

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self._buf = bytearray()
        self._consumed = 0  # absolute offset of _buf[0] in the byte stream
        self._marks: deque[tuple[int, float]] = deque()  # (end offset, time)
        self._last_ts = time.perf_counter()

    def _fill(self) -> None:
        data = self._sock.recv(65536)
        if not data:
            raise ConnectionError("peer closed the connection")
        now = time.perf_counter()
        self._buf += data
        self._marks.append((self._consumed + len(self._buf), now))
        self._last_ts = now

    def read_exact(self, count: int) -> tuple[bytes, float]:
        if count == 0:
            return b"", self._last_ts
        while len(self._buf) < count:
            self._fill()
        out = bytes(self._buf[:count])
        del self._buf[:count]
        self._consumed += count
        arrival = self._last_ts
        for end_offset, timestamp in self._marks:
            if end_offset >= self._consumed:
                arrival = timestamp
                break
        while self._marks and self._marks[0][0] < self._consumed:
            self._marks.popleft()
        return out, arrival

    def read_http_head(self) -> bytes:
        while b"\r\n\r\n" not in self._buf:
            self._fill()
        end = self._buf.index(b"\r\n\r\n") + 4
        head = bytes(self._buf[:end])
        del self._buf[:end]
        self._consumed += end
        return head


def read_frame(reader: TimedReader) -> tuple[int, bytes, float]:
    header, _ = reader.read_exact(2)
    opcode = header[0] & 0x0F
    masked = bool(header[1] & 0x80)
    length = header[1] & 0x7F
    if length == 126:
        extended, _ = reader.read_exact(2)
        length = int.from_bytes(extended, "big")
    elif length == 127:
        extended, _ = reader.read_exact(8)
        length = int.from_bytes(extended, "big")
    mask = b""
    if masked:
        mask, _ = reader.read_exact(4)
    payload, arrival = reader.read_exact(length)
    if masked:
        payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    return opcode, payload, arrival


def encode_client_frame(payload: bytes, opcode: int = OPCODE_BINARY) -> bytes:
    """Client-to-server frame: always masked, per RFC 6455."""
    mask = os.urandom(4)
    out = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        out.append(0x80 | length)
    elif length < 65536:
        out.append(0x80 | 126)
        out += length.to_bytes(2, "big")
    else:
        out.append(0x80 | 127)
        out += length.to_bytes(8, "big")
    out += mask
    out += bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    return bytes(out)


def encode_server_frame(payload: bytes, opcode: int = OPCODE_BINARY) -> bytes:
    """Server-to-client frame: never masked. Payloads here are always small
    enough for the one-byte length form."""
    return bytes(bytearray([0x80 | opcode, len(payload)])) + payload


def server_handshake(sock: socket.socket, reader: TimedReader) -> None:
    head = reader.read_http_head().decode("latin-1")
    key = ""
    for line in head.split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
    accept = base64.b64encode(hashlib.sha1(key.encode("ascii") + WS_GUID).digest()).decode("ascii")
    sock.sendall(
        (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        ).encode("ascii")
    )


def client_handshake(sock: socket.socket, reader: TimedReader, port: int, room: str) -> None:
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    sock.sendall(
        (
            f"GET /{room} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        ).encode("ascii")
    )
    head = reader.read_http_head().decode("latin-1")
    status = head.split("\r\n")[0]
    if "101" not in status:
        raise ConnectionError(f"handshake refused: {status}")


def connect_ws(port: int, room: str, no_delay: bool) -> tuple[socket.socket, TimedReader]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1 if no_delay else 0)
    sock.settimeout(30.0)
    sock.connect(("127.0.0.1", port))
    reader = TimedReader(sock)
    client_handshake(sock, reader, port, room)
    return sock, reader


def read_burst(reader: TimedReader, burst: int) -> list[float]:
    """Arrival times of the next `burst` binary frames; stops early on close
    or on a dead socket, so a short round shows up as short rather than
    hanging."""
    arrivals: list[float] = []
    try:
        while len(arrivals) < burst:
            opcode, _payload, arrival = read_frame(reader)
            if opcode == OPCODE_CLOSE:
                break
            if opcode == OPCODE_BINARY:
                arrivals.append(arrival)
    except (OSError, ConnectionError):
        pass
    return arrivals


def burst_payload(index: int, payload_bytes: int) -> bytes:
    return index.to_bytes(4, "little") + b"\x00" * max(0, payload_bytes - 4)


def quiet_after_handshake(warmup_msec: float) -> None:
    """Waits for the connection to fall silent before the burst starts.

    The handshake is itself unacknowledged small data -- the client's GET,
    the server's 101 -- so a burst beginning immediately risks having its
    *first* frame withheld behind the handshake rather than behind another
    frame. Every gap is measured from that first arrival, so such a delay
    would land outside the measurement window and a Nagle-enabled peer could
    score clean.

    That is the reasoning; the evidence is weaker than the reasoning, and the
    comment says so rather than implying this wait earned its place. Measured
    both ways, with and without, it changed no verdict in either direction --
    what actually decided the outbound direction was
    poke_to_enter_pingpong() below. Kept because 60 ms of quiet costs nothing
    and removes a way the first frame could be mismeasured.
    """
    time.sleep(warmup_msec / 1000.0)


def poke_to_enter_pingpong(sock: socket.socket, payload_bytes: int) -> None:
    """Makes the *receiving* end delay its ACKs, by having it send one frame
    after it has received something.

    Nagle can only withhold a write while an earlier one is unacknowledged,
    so a receiver that acknowledges instantly hides it completely. Linux
    picks between the two with a heuristic: a socket that sends data shortly
    after receiving some is treated as interactive ("pingpong") and starts
    delaying its ACKs, while one that has only ever received stays in
    quick-ack and replies immediately.

    This is the single change that made the outbound direction measurable,
    and it is not the harness stacking the deck. Measured directly: against a
    receiver that only ever reads, the positive control -- Nagle deliberately
    enabled -- stalled in 0 of 12 rounds, so a peer known to have Nagle on
    looked perfectly healthy. With one frame sent first, the same control
    stalled in 12 of 12 while the TCP_NODELAY control still stalled in 0.

    The read-only receiver is also the artificial case, not this one. Every
    client in a lockstep match sends its own command frame every turn, so a
    real client sits permanently in the interactive mode reproduced here; a
    harness built on a silent receiver would have quietly measured a
    situation the game never gets into.
    """
    sock.sendall(encode_client_frame(burst_payload(0, payload_bytes)))


# --------------------------------------------------------------------------
# Per-round bookkeeping
# --------------------------------------------------------------------------


class Round:
    """One connection's worth of trace: when frames were sent, when they
    arrived."""

    def __init__(self, sends: list[float], arrivals: list[float], interval_msec: float) -> None:
        self.sends = sends
        self.arrivals = arrivals
        self.interval_msec = interval_msec

    @property
    def usable(self) -> bool:
        return len(self.arrivals) >= 2

    @property
    def max_arrival_gap(self) -> float:
        return max(_gaps_msec(self.arrivals), default=0.0)

    @property
    def excess_msec(self) -> float:
        """How much longer the worst gap was than the sender's own spacing --
        the quantity Nagle actually adds. Comparing raw gaps instead would
        make the sender's `interval` look like a stall as soon as it exceeded
        the threshold."""
        return self.max_arrival_gap - self.interval_msec

    @property
    def stalled(self) -> bool:
        return self.usable and self.excess_msec >= STALL_EXCESS_MSEC

    @property
    def batched(self) -> bool:
        """Arrivals markedly tighter than the sends that produced them: the
        frames were not written separately, so Nagle had nothing to withhold
        and this round proves nothing either way."""
        if not self.usable or len(self.sends) < 2:
            return False
        send_spread = (self.sends[-1] - self.sends[0]) * 1000.0
        arrival_spread = (self.arrivals[-1] - self.arrivals[0]) * 1000.0
        return send_spread > 1.0 and arrival_spread < send_spread * 0.5


class Trace:
    def __init__(self, label: str, rounds: list[Round]) -> None:
        self.label = label
        self.rounds = [r for r in rounds if r.usable]
        self.attempted = len(rounds)

    @property
    def stalls(self) -> int:
        return sum(1 for r in self.rounds if r.stalled)

    @property
    def batched(self) -> int:
        return sum(1 for r in self.rounds if r.batched)

    def row(self) -> str:
        if not self.rounds:
            return f"  {self.label:<32} no usable rounds (attempted {self.attempted})"
        excesses = [r.excess_msec for r in self.rounds]
        return (
            f"  {self.label:<32} rounds={len(self.rounds):<3} "
            f"median excess={statistics.median(excesses):7.2f} ms  "
            f"max={max(excesses):7.2f} ms  "
            f"stalled={self.stalls}/{len(self.rounds)}  batched={self.batched}"
        )


def _gaps_msec(times: list[float]) -> list[float]:
    return [(b - a) * 1000.0 for a, b in zip(times, times[1:])]


def verdict(control_on: Trace, control_off: Trace, subject: Trace) -> tuple[str, str]:
    if control_on.stalls < MIN_STALL_ROUNDS:
        return "INCONCLUSIVE", (
            f"positive control (Nagle deliberately on) stalled in only {control_on.stalls} rounds, so this "
            "harness cannot detect Nagle here and proves nothing about the subject"
        )
    if control_off.stalls >= MIN_STALL_ROUNDS:
        return "INCONCLUSIVE", (
            f"negative control (TCP_NODELAY deliberately set) stalled in {control_off.stalls} rounds, so the "
            "stalls are not Nagle and this harness is measuring something else"
        )
    if not subject.rounds:
        return "INCONCLUSIVE", "the subject produced no usable rounds"
    if subject.batched > len(subject.rounds) // 2:
        return "INCONCLUSIVE", (
            f"the subject batched {subject.batched} of {len(subject.rounds)} rounds into single writes, so "
            "Nagle had nothing to withhold and absence of delay is not evidence"
        )
    if subject.stalls >= MIN_STALL_ROUNDS:
        return "NAGLE ON", f"the subject stalled in {subject.stalls} rounds, matching the positive control"
    return "NAGLE OFF", f"the subject stalled in {subject.stalls} rounds, matching the negative control"


# --------------------------------------------------------------------------
# Direction A: client -> relay. Subject is Godot's WebSocketPeer as a client.
# --------------------------------------------------------------------------


class BurstServer(threading.Thread):
    """Accepts `rounds` connections one after another and times the burst on
    each. Sends nothing after the handshake -- see the module doc comment on
    why a silent receiver is what makes the effect visible."""

    def __init__(self, port: int, rounds: int, burst: int) -> None:
        super().__init__(daemon=True)
        self.arrivals: list[list[float]] = []
        self.error: str | None = None
        self._rounds = rounds
        self._burst = burst
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", port))
        self._listener.listen(8)
        self._listener.settimeout(30.0)
        self.port = self._listener.getsockname()[1]

    def run(self) -> None:
        try:
            for _ in range(self._rounds):
                conn, _addr = self._listener.accept()
                conn.settimeout(30.0)
                with conn:
                    reader = TimedReader(conn)
                    server_handshake(conn, reader)
                    self.arrivals.append(read_burst(reader, self._burst))
        except (OSError, ConnectionError) as exc:
            self.error = str(exc)
        finally:
            self._listener.close()


def python_client_rounds(port: int, args: argparse.Namespace, no_delay: bool) -> list[list[float]]:
    """Control sender: the same per-round pattern as the Godot probe, with
    Nagle explicitly on or off."""
    per_round: list[list[float]] = []
    for _ in range(args.rounds):
        sock, _reader = connect_ws(port, args.room, no_delay)
        sends: list[float] = []
        try:
            quiet_after_handshake(args.warmup)
            for index in range(args.burst):
                sock.sendall(encode_client_frame(burst_payload(index, args.payload)))
                sends.append(time.perf_counter())
                time.sleep(args.interval / 1000.0)
            time.sleep(args.settle / 1000.0)
        finally:
            sock.close()
        per_round.append(sends)
    return per_round


def godot_client_rounds(port: int, args: argparse.Namespace) -> tuple[list[list[float]], str]:
    """Runs tests/net/nagle_probe_client.gd and parses its SEND trace.

    Its timestamps come from another process's Time.get_ticks_usec() and share
    no origin with this process's perf_counter(); only the gaps between them
    are used, which is all they are comparable for.
    """
    proc = subprocess.run(
        [
            "godot", "--headless", "--path", "/workspace",
            "--script", "res://tests/net/nagle_probe_client.gd", "--",
            "--port", str(port), "--room", args.room, "--rounds", str(args.rounds),
            "--burst", str(args.burst), "--interval-msec", str(int(args.interval)),
            "--payload-bytes", str(args.payload), "--warmup-msec", str(int(args.warmup)),
        ],
        capture_output=True, text=True, timeout=300,
    )
    per_round: list[list[float]] = [[] for _ in range(args.rounds)]
    for line in proc.stdout.splitlines():
        if not line.startswith("SEND "):
            continue
        _tag, round_index, _index, usec = line.split()
        per_round[int(round_index)].append(int(usec) / 1_000_000.0)
    if not any(per_round):
        return [], (proc.stdout + proc.stderr).strip()[-800:] or "probe produced no SEND lines"
    return per_round, ""


def measure_client_to_relay(args: argparse.Namespace) -> tuple[str, str, list[Trace]]:
    traces: list[Trace] = []
    for label, subject in (
        ("control: python, Nagle on", False),
        ("control: python, TCP_NODELAY", True),
        ("subject: Godot WebSocketPeer", None),
    ):
        server = BurstServer(args.port, args.rounds, args.burst)
        server.start()
        time.sleep(0.1)
        if subject is None:
            sends, failure = godot_client_rounds(server.port, args)
            if failure:
                print(f"  Godot probe failed: {failure}", file=sys.stderr)
        else:
            sends = python_client_rounds(server.port, args, no_delay=subject)
        server.join(timeout=180.0)
        if server.error and not server.arrivals:
            print(f"  probe server error for {label}: {server.error}", file=sys.stderr)
        traces.append(_build_trace(label, sends, server.arrivals, args))
        time.sleep(0.2)
    return (*verdict(traces[0], traces[1], traces[2]), traces)


# --------------------------------------------------------------------------
# Direction B: relay -> client. Subject is the outbound half of the real
# RelayServer, i.e. the stream it took from TCPServer and handed to
# WebSocketPeer.accept_stream().
# --------------------------------------------------------------------------


def measure_relay_to_client(args: argparse.Namespace) -> tuple[str, str, list[Trace]]:
    port = args.port + 1
    relay = subprocess.Popen(
        [
            "godot", "--headless", "--path", "/workspace",
            "--script", "res://scripts/net/relay/relay_main.gd", "--",
            "--port", str(port),
        ],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        if not _wait_for_listener(port, timeout=60.0):
            return "INCONCLUSIVE", f"the relay never started listening on port {port}", []
        traces: list[Trace] = []
        for label, subject in (
            ("control: python, Nagle on", False),
            ("control: python, TCP_NODELAY", True),
            ("subject: RelayServer outbound", None),
        ):
            if subject is None:
                sends, arrivals = _relay_fanout_rounds(port, args)
            else:
                sends, arrivals = _direct_pair_rounds(args, no_delay=subject)
            traces.append(_build_trace(label, sends, arrivals, args))
            time.sleep(0.2)
        return (*verdict(traces[0], traces[1], traces[2]), traces)
    finally:
        relay.terminate()
        try:
            relay.wait(timeout=10.0)
        except subprocess.TimeoutExpired:
            relay.kill()
            relay.wait(timeout=10.0)


def _relay_fanout_rounds(port: int, args: argparse.Namespace) -> tuple[list[list[float]], list[list[float]]]:
    """Two clients in one room per round. The sender writes a spaced burst,
    the relay fans it out, and the *receiver* is where arrival is timed, so
    the link under test is relay -> receiver. The sender's own Nagle is
    disabled so its link cannot contaminate the trace, and it drains its own
    fan-out copy so a full receive window never stalls the relay for reasons
    unrelated to Nagle. The receiver sends exactly one frame of its own, up
    front and before any timing starts -- see poke_to_enter_pingpong().

    The relay writes what it forwards on its own poll cycle, so the *relay's*
    write times, not the sender's, are what the receiver's arrivals should be
    compared against. The sender's spacing is used as the stand-in: at this
    interval each forwarded frame lands in its own relay poll, which the
    batched check below would catch if it stopped being true.
    """
    per_round_sends: list[list[float]] = []
    per_round_arrivals: list[list[float]] = []
    for round_index in range(args.rounds):
        room = f"{args.room}{round_index}"
        receiver, receiver_reader = connect_ws(port, room, no_delay=True)
        sender, sender_reader = connect_ws(port, room, no_delay=True)
        drain_stop = threading.Event()
        drainer = threading.Thread(target=_drain_until, args=(sender_reader, drain_stop), daemon=True)
        drainer.start()

        # The relay fans out to every endpoint in the room including the
        # sender (that is its contract, not an accident), so the receiver's
        # poke comes straight back to the receiver as well and has to be
        # consumed here -- otherwise it would be counted as the first frame
        # of the burst and shift every gap by one.
        poke_to_enter_pingpong(receiver, args.payload)
        read_burst(receiver_reader, 1)

        arrivals: list[float] = []
        collector = threading.Thread(
            target=lambda: arrivals.extend(read_burst(receiver_reader, args.burst)), daemon=True
        )
        collector.start()

        sends: list[float] = []
        try:
            quiet_after_handshake(args.warmup)
            for index in range(args.burst):
                sender.sendall(encode_client_frame(burst_payload(index, args.payload)))
                sends.append(time.perf_counter())
                time.sleep(args.interval / 1000.0)
            collector.join(timeout=args.settle / 1000.0 + 2.0)
        finally:
            drain_stop.set()
            sender.close()
            receiver.close()
        per_round_sends.append(sends)
        per_round_arrivals.append(arrivals)
    return per_round_sends, per_round_arrivals


def _direct_pair_rounds(args: argparse.Namespace, no_delay: bool) -> tuple[list[list[float]], list[list[float]]]:
    """Control for the outbound direction: this script's own server sends the
    spaced burst, with Nagle explicitly on or off. Same link shape as the
    relay's outbound half -- one write per frame, and a receiver that pokes
    once and then only reads, exactly as in the relay run -- with the single
    variable under test set deliberately."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    listener.settimeout(30.0)
    port = listener.getsockname()[1]

    per_round_sends: list[list[float]] = [[] for _ in range(args.rounds)]
    per_round_arrivals: list[list[float]] = []
    error: list[str] = []

    def serve() -> None:
        try:
            for round_index in range(args.rounds):
                conn, _addr = listener.accept()
                conn.settimeout(30.0)
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1 if no_delay else 0)
                with conn:
                    reader = TimedReader(conn)
                    server_handshake(conn, reader)
                    # Consumes the client's poke (see poke_to_enter_pingpong),
                    # which must be read for the framing to stay in sync.
                    read_frame(reader)
                    quiet_after_handshake(args.warmup)
                    for index in range(args.burst):
                        conn.sendall(encode_server_frame(burst_payload(index, args.payload)))
                        per_round_sends[round_index].append(time.perf_counter())
                        time.sleep(args.interval / 1000.0)
                    time.sleep(args.settle / 1000.0)
        except (OSError, ConnectionError) as exc:
            error.append(str(exc))
        finally:
            listener.close()

    server = threading.Thread(target=serve, daemon=True)
    server.start()
    for _ in range(args.rounds):
        client, reader = connect_ws(port, args.room, no_delay=True)
        poke_to_enter_pingpong(client, args.payload)
        try:
            per_round_arrivals.append(read_burst(reader, args.burst))
        finally:
            client.close()
    server.join(timeout=180.0)
    if error and not any(per_round_arrivals):
        print(f"  direct-pair control error: {error[0]}", file=sys.stderr)
    return per_round_sends, per_round_arrivals


def _drain_until(reader: TimedReader, stop: threading.Event) -> None:
    try:
        while not stop.is_set():
            read_frame(reader)
    except (OSError, ConnectionError):
        pass


# --------------------------------------------------------------------------


def _build_trace(
    label: str, sends: list[list[float]], arrivals: list[list[float]], args: argparse.Namespace
) -> Trace:
    rounds = [
        Round(send_times, arrival_times, args.interval)
        for send_times, arrival_times in zip(sends, arrivals)
    ]
    return Trace(label, rounds)


def _wait_for_listener(port: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1.0):
                return True
        except OSError:
            time.sleep(0.2)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--port", type=int, default=19310, help="base port; the relay direction uses port+1")
    parser.add_argument("--room", default="nagle")
    parser.add_argument("--rounds", type=int, default=15, help="connections per run; one sample each")
    parser.add_argument("--burst", type=int, default=3, help="frames per connection")
    parser.add_argument(
        "--interval", type=float, default=10.0,
        help="milliseconds between sends; must stay well under the delayed-ACK timer (~40 ms)",
    )
    parser.add_argument("--payload", type=int, default=16, help="payload bytes per frame")
    parser.add_argument(
        "--warmup", type=float, default=60.0,
        help="milliseconds of quiet after the handshake, before the burst; see quiet_after_handshake()",
    )
    parser.add_argument("--settle", type=float, default=120.0, help="milliseconds to wait before closing")
    parser.add_argument("--only", choices=["client", "relay"], help="measure one direction only")
    args = parser.parse_args()

    directions = []
    if args.only in (None, "client"):
        directions.append(("client -> relay  (Godot WebSocketPeer as client)", measure_client_to_relay))
    if args.only in (None, "relay"):
        directions.append(("relay -> client  (RelayServer's accepted stream)", measure_relay_to_client))

    failed = False
    for title, measure in directions:
        print(f"\n=== {title} ===")
        state, reason, traces = measure(args)
        for trace in traces:
            print(trace.row())
        print(f"  -> {state}: {reason}")
        if state != "NAGLE OFF":
            failed = True
    print()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
