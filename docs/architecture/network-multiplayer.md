# Networked multiplayer: high-level design

Roadmap target: **v0.4 — network stack, multiplayer up to 4 players**.

This document fixes the architectural decisions *before* implementation starts,
because almost every one of them constrains code that already exists. It is a
decision record, not a task list: each section states the choice, what it buys,
and — more importantly — what it forbids elsewhere in the project.

## Decisions at a glance

| # | Fork | Decision |
|---|---|---|
| 1 | Authority model | Deterministic lockstep over a dumb relay |
| 2 | native ↔ web crossplay | Not supported; separate lobbies |
| 3 | Simulation core | Sim layer owns state, nodes are views, hot state in flat arrays |
| 4 | Simulation tick | One integer tick at 25 Hz |
| 5 | Math | `float64` arithmetic plus our own portable math; no libm transcendentals in the sim |
| 6 | Transport | WebSocket behind a transport interface |
| 7 | Relay hosting | Self-hostable by anyone; one instance operated by the project |
| 8 | Lag policy | Adaptive input delay, pause, drop on timeout; dropped players freeze |
| 9 | Teams | Fixed teams chosen in the lobby (2v2 / FFA) |
| 10 | v0.4 scope | Replays, reconnect, save/load of a networked match. No spectators |
| 11 | Migration | Incremental, on `main`, with single-player as the test bed |

## 1. Deterministic lockstep over a dumb relay

Only *commands* travel over the wire. Every client runs its own copy of the
simulation and must reach a bit-identical result. The server relays command
frames and hosts the lobby; it does not simulate and does not arbitrate.

This is what nearly every RTS in the genre does, and the reason is bandwidth:
"these 40 selected units → move(x, y)" is a couple of dozen bytes whether the
match holds 40 units or 4000. Replays, save/load and (later) bots fall out of
the same mechanism.

The price is paid in full elsewhere: **the simulation must be deterministic**,
and that requirement drives decisions 3, 4 and 5.

Consequence we accept knowingly: with a non-simulating relay, every client holds
the full world state, so map-hacking is possible by construction. That is
acceptable for a v0.4 played among friends. The escape hatch, if it ever
matters, is promoting the relay to a headless arbiter that also runs the sim —
which the transport and command-bus layers are designed not to preclude.

## 2. No native ↔ web crossplay

A match is either all-native or all-web. This removes the hardest determinism
target (WASM vs native libm) from v0.4.

It does **not** remove cross-platform determinism: native Linux, Windows and
macOS are still three different platforms with three different `libm`
implementations. Decision 5 exists because of that.

## 3. Simulation core owns state; nodes are views

The simulation moves out of the scene tree into a plain `RefCounted` layer:

- **behaviour** lives in sim objects, one per entity kind, as today;
- **hot state** — position, velocity, facing, health, owner — lives in flat
  `Packed*Array`s indexed by entity id;
- `Node3D` and friends become **views**: they read sim state and interpolate
  between ticks, they never own gameplay state.

The flat hot state is what makes reconnect and save/load affordable: a snapshot
becomes a copy of a handful of packed arrays instead of a hand-written
serializer for 59 fields across dozens of classes. Given that both are in the
v0.4 scope (decision 10), this pays for itself immediately.

We are deliberately **not** building a full ECS. In GDScript the classic ECS
win — cache locality from structure-of-arrays — barely survives the VM, so the
cost of rewriting the bulk of 37k lines would buy a fraction of the promised
return. What we take from ECS is exactly three properties, and all three are
achievable without it:

1. state is explicit and serializable;
2. the tick is centralized and advances **system by system**, not node by node;
3. entity creation and destruction are deferred to queues, never applied
   mid-iteration.

Two things we lose by skipping ECS and accept: rollback netcode stays off the
table (lockstep does not need it), and the discipline above must be enforced by
tests and static checks rather than by structure — see "Rules for sim code".

## 4. One integer tick at 25 Hz

Today three tick domains coexist and all of them advance from frame `delta`:

- `scripts/combat/combat_rules.gd` — `TICKS_PER_SECOND := 25.0` (combat,
  turrets, linger effects);
- `scripts/buildings/production_queue.gd` — `BUILD_TICKS_PER_SECOND := 60.0`
  (production and upgrade queues);
- `scripts/buildings/building_repair_service.gd` —
  `RULE_TICKS_PER_SECOND := 25.0`;
- `scripts/combat/ballistics.gd:15` documents that it deliberately uses a rate
  of its own.

All of them collapse into a **single integer tick counter at 25 Hz**, advanced
by the turn scheduler and never by frame time. The 60-domain build times must be
re-derived from the rules data at 25 Hz.

Open fidelity question, recorded rather than resolved: two exact anchors in
`assets/raw_original_content/MODEL/Rules.txt` suggest the original game ran at
20 Hz — `TicksBetweenReinforcements = 6600 // 5.5 minutes` (6600 / 330 = 20) and
`Lifespan` with the comment `3000=2.5 minutes` (3000 / 150 = 20). A third anchor,
`StormMinWait = 7500 // around 3 minute`, disagrees, but is itself hedged. If
those anchors are right, at 25 Hz the game runs about 25% faster than the
original. We ship 25 Hz because that is what the combat code is already tuned
against. To keep the option open, **per-tick values stay unscaled in the rules
data and the tick rate remains the only knob** — changing one constant must be
enough to re-test 20 Hz later.

## 5. Portable `float64`, no libm transcendentals in the sim

IEEE-754 guarantees bit-identical results for `+ - * /` and `sqrt` on every
platform we care about, WASM included. What is *not* portable is everything that
routes through the platform's `libm`.

So the sim is written in ordinary `float` (GDScript's `float` is a double), with
a hard ban on the non-portable subset, and our own replacements where the
gameplay needs them — trigonometry over integer angle units backed by a
generated table.

Allowed in sim code: `+ - * /`, `sqrt`, `abs`, `min/max`, `floor/ceil/round`,
`Vector2/3` addition, subtraction, scalar multiply, `dot`, `cross`, `length`,
`length_squared`, `normalized`, `distance_to`, `lerp`.

Banned in sim code: `sin`, `cos`, `tan`, `atan`, `atan2`, `asin`, `acos`, `pow`,
`exp`, `log`, `fmod`, and the `Vector*` methods built on them — `rotated`,
`angle`, `angle_to`, `slerp`, `bezier_*`.

This choice keeps the code readable, keeps the ban mechanically checkable, and
as a side effect leaves the door open to native ↔ web crossplay later without a
rewrite.

## 6. WebSocket behind a transport interface

The netcode is written against a thin interface — roughly `connect`, `send(bytes)`,
`poll() -> [frames]`, `disconnect`, plus connection state — with three
implementations:

1. **WebSocket** — the only shipping transport in v0.4, one code path for both
   native and web.
2. **In-memory loopback** with configurable latency, jitter and packet loss —
   for headless tests that run four clients in one process and reproduce
   desyncs deterministically.
3. **ENet** — *not* in v0.4. Added later only if measurements justify it.

The reasoning behind not starting with ENet: in lockstep every command frame must
be reliable and ordered, because turn N+1 cannot execute before turn N. That
removes UDP's main advantage — skipping a lost packet — and head-of-line blocking
becomes a property of the problem rather than of TCP. On a clean link the two are
within a couple of milliseconds. The real difference shows up only under packet
loss, where TCP's 200 ms minimum RTO can stall a frame that ENet would re-request
in one or two RTTs. With an adaptive input delay acting as a jitter buffer, that
stall is usually absorbed rather than seen.

One thing to **measure, not assume**: whether Godot's `WebSocketPeer` disables
Nagle. An enabled Nagle adds up to 40 ms on every frame — larger than the entire
ENet-vs-TCP gap on a healthy link, and the first thing to fix if it shows up.

## 7. Relay hosting

The relay is a first-class, self-hostable artifact: a small headless server
shipped in this repository with a container image, runnable by anyone. The
project additionally operates one public instance, which the client uses as its
default endpoint, with a "custom server address" field next to it.

Browser clients require `wss://`, so any publicly reachable instance needs TLS
and a hostname; self-hosters on a LAN can stay on plain `ws://` with a native
build.

Lobby model: create a room, share a code, join by code. No matchmaking, no
ranking, no persistent accounts in v0.4.

## 8. Lag and disconnect policy

Input delay is **adaptive**: derived from the worst round-trip in the room rather
than fixed at a pessimistic constant, with a floor of two turns.

When a player's frames stop arriving, the match pauses with an explicit UI state
naming the player. After a timeout the player is dropped from the turn schedule
so the remaining players continue.

A dropped player's units and buildings **freeze**: they stay in the world,
receive no new orders, and their turrets and defensive structures keep working.
This is the behaviour that makes reconnect (decision 10) meaningful — the player
returns to the base they left.

## 9. Teams

Teams are fixed in the lobby before the match starts and never change in-game;
in-game diplomacy is out of scope. 2v2 and FFA on four players.

`scripts/players/player_roster.gd` already models this: it has `set_team`,
`relation_between` and `is_ally`, and `player_data.gd` has `Relation.ALLY`. What
2v2 still needs is lobby-side team assignment, friendly-fire rules and a
team-aware victory condition.

Shared vision is *not* work for v0.4: the project has no fog of war yet. It
becomes relevant when fog of war lands, and teams are already the right place to
hang it on.

## 10. Scope of v0.4

In scope, beyond the four-player match itself:

- **Replays** as a command log. Nearly free from lockstep, and the primary tool
  for debugging desyncs — worth having from the first line of netcode.
- **Reconnect** into a running match, served from a hot-state snapshot.
- **Save/load of a networked match**, sharing the snapshot mechanism with
  single-player saves from v0.2.

Out of scope: spectators, in-game diplomacy, ENet, matchmaking, any form of
server-side authority or anti-cheat.

Bots are v0.5, but they carry one constraint that must be respected now: a bot is
a **command producer inside the simulation**, deterministic and identical on
every client — never a separate network client.

## Layering

```
transport          WebSocket | in-memory loopback | (later) ENet
turn scheduler     command frames, adaptive input delay, checksums, stall/drop policy
command bus        serializable command structs, deterministic ordering by player id
simulation         25 Hz integer tick, flat hot state + behaviour objects, deferred spawn/despawn
view               Node3D, interpolation, cosmetic RNG, instant cosmetic feedback
```

Starting parameters, to be tuned against the loopback transport with induced
latency and loss:

- **turn** = 2 sim ticks (80 ms), which keeps the frame rate on the wire at
  12.5 per client per second;
- **input delay** = 3 turns (240 ms) by default, adaptive in the range 2–8;
- **state checksum** every 8 ticks (320 ms), covering positions, health, order
  queues and the RNG cursor.

Latency is hidden the way the genre always hides it: the acknowledgement is
cosmetic and immediate — click feedback, order marker, unit voice line — while
the order itself executes on its scheduled tick.

RNG is split in two. The simulation owns a single seeded
`RandomNumberGenerator`, advanced only from tick code, and its cursor is part of
the checksum. Everything cosmetic — impact debris, death sounds, turret FX,
which already call global `randi`/`randf` — keeps using unseeded randomness and
is structurally forbidden from touching sim state.

On desync: halt the match, dump both states, write out the replay up to the
diverging tick, and surface the tick number. A silently continuing desync is
worse than a stopped match.

## Rules for sim code

These are the invariants that replace the structure a full ECS would have
imposed. They are enforced by the `sim` zone in `tools/architecture_rules.toml`,
checked by `tools/check_architecture.py`. The zone currently matches nothing and
is marked `allow_empty = true`; it starts biting the moment the first file lands
in `scripts/sim/`:

The manifest is the source of truth for the exact bans — it carries a `why` and
an `instead` per rule and is not duplicated here. In summary, the sim layer may
not touch the scene tree, `await`, tweens or timers, signals, frame `delta`,
unseeded RNG, libm trigonometry, `Vector*` angle methods, the wall clock, or
threads.

Two of these deserve their reasoning kept in prose:

- **`await` is the most dangerous one in this codebase as it stands.** A
  coroutine parks state on the VM stack, where no snapshot, replay or checksum
  can see it, and resumes on engine frame timing.
- **Frame `delta` diverges silently rather than loudly.** The engine clamps
  physics steps per frame, so a client that drops frames skips them; nothing
  errors, the two worlds simply stop matching.

Two more invariants belong here but are **not statically checkable**, and are
therefore owned by the determinism property tests and by review:

- iteration over entities goes in sorted entity-id order — no reliance on
  dictionary insertion order, and no unstable `sort_custom` without an id
  tiebreaker;
- spawn and despawn go through deferred queues applied at tick boundaries.

That split is deliberate and worth stating plainly: the static checker fully
covers the bans it can express, partially covers frame timing, and cannot
express ordering at all. Without the property tests, ordering and deferral rest
on nothing but attention.

## Order of work

The ordering is deliberate: **nothing on this list needs a socket until phase 5**,
and by the time we get there the hard part is already tested.

- **Phase 0 — plumbing.** Transport interface, in-memory loopback, relay
  skeleton with a container image. No game logic touched.
- **Phase 1 — one tick.** Collapse the three tick domains into a single 25 Hz
  integer tick driven by a central scheduler; remove frame `delta` from
  gameplay paths. Single-player stays playable throughout.
- **Phase 2 — command bus.** Route every player intent through serializable
  command structs with a scheduled execution tick.
  `scripts/match/unit_command_controller.gd` is the natural seam. Single-player
  runs with input delay 0 over a null transport. **Replay recording and playback
  land here.**
- **Phase 3 — sim/view split.** Move state ownership out of `Node3D` into the sim
  layer and the flat hot arrays; nodes start interpolating. Headless execution
  faster than real time becomes possible, which is what makes phase 4 cheap.
- **Phase 4 — determinism gate.** Portable math, RNG split, the static rules
  above wired into `check_architecture.py`, and the CI test that replays one
  command log twice in-process and then compares state hashes across native and
  web builds.
- **Phase 5 — netcode.** Turn scheduler, adaptive input delay, checksums,
  stall/drop policy, snapshot-based reconnect, lobby with room codes and teams.
- **Phase 6 — polish.** Cosmetic prediction, parameter tuning under induced
  latency and loss, save/load of a networked match.

Migration runs incrementally on `main`, with single-player as the test bed. Every
phase leaves the game playable, and the refactor is validated by the mode we can
already play before it is trusted by the mode we cannot yet test.

## Open questions

- Does Godot's `WebSocketPeer` set `TCP_NODELAY`? Measure before designing
  around it (see decision 6).
- Original tick rate: 20 Hz per the rules-data anchors versus the 25 Hz the
  combat code is tuned to (see decision 4).
- Snapshot size for reconnect, which cannot be estimated before the hot-state
  layout exists (decision 3).
