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
- `scripts/production/building_repair_service.gd` —
  `RULE_TICKS_PER_SECOND := 25.0`;
- `scripts/combat/ballistics.gd:15` documents that it deliberately uses a rate
  of its own.

All of them collapse into a **single integer tick counter at 25 Hz**, advanced
by the turn scheduler and never by frame time. The 60-domain build times must be
re-derived from the rules data at 25 Hz.

**Done in phase 1, 2026-08-18.** `scripts/sim/match_clock.gd` holds the counter
and nothing else; `scripts/match/frame_tick_driver.gd` turns frame time into
whole ticks and is the piece phase 5 replaces with the turn scheduler.
`Match._advance_simulation_tick()` is the only caller of `MatchClock.advance()`
and drives every system in a fixed, documented order.

The count of domains was five, not three. Beyond the three named above,
`map_spice_spread.gd` and `spice_mound.gd` each held their own 60 Hz constant,
and `map_spice_hazard.gd` ran at 4 Hz — and spice turned out not to be a rate
problem at all but a `Timer` problem, which is worse: a Timer advances on
engine frame time where no snapshot or checksum can see it. All of them are
gone. `ballistics.gd`'s 20 Hz stays, correctly: it converts Rules.txt units,
it is not a clock.

**Found 2026-08-20, and it corrects "all of them are gone" above: the count
was six.** `scripts/units/navigation/shared/nav_constants.gd` declares
`NAVIGATION_TICK_RATE := 20.0`, and `UnitNavigationSystem._physics_process()`
runs its own accumulator against it — a sixth domain, advancing on frame time,
driving the part of the game that decides where every unit ends up. The sweep
missed it because `own-tick-rate`'s pattern matches `TICKS_PER_SECOND` and this
constant is named something else, which is precisely the failure mode that rule
exists to prevent.

**Closed 2026-08-20, in phase 3 slices A1a and A1b.** `NAVIGATION_TICK_RATE` is
deleted, not re-pointed: there is no navigation tick rate any more, only the
simulation's, and `UnitNavigationSystem.sim_tick()` is called once per tick from
`Match._advance_simulation_tick()`. The `own-tick-rate` pattern now matches the
`_TICK_RATE` spelling as well, so re-adding the constant is rejected outright --
which is what actually keeps the domain closed, the deletion being merely the
first half. A1a came first and changed no behaviour at all: it separated the
Rules.txt movement cadence, which is also 20 and is not a clock, from the tick
rate that was about to change, after finding one place that had already confused
the two.

Two conversions were not one-to-one and are recorded here because they changed
the game, slightly and deliberately:

- Rules build times are authored at 60 Hz and converted at the one boundary
  where a config becomes a queue order (`scripts/rules/rule_ticks.gd`), which
  costs at most half a tick of rounding. The conversion is **not** a drop-in
  for the `maxf(build_time_ticks, 1.0)` guard it replaced: 92 building and 25
  unit definitions ship with `build_time_ticks = 0`, `ATConYard` among them,
  and converting that honestly to 0 ticks would have made
  `ProductionQueue.adopt()` reject them outright.
- The spice hazard pulsed 4 times a second, which is 6.25 ticks — not
  expressible. It now pulses 5 times a second, which is exactly 5 ticks and
  divides the 250-tick lifetime evenly. Total damage and total duration are
  unchanged; only the granularity moved, and it moved finer.

What phase 1 deliberately did **not** do: continuous motion — locomotion,
navigation, flight, projectile flight and turret aim — still advances on frame
`delta`. Moving it to 25 Hz without interpolation would make the game visibly
steppy, and the view layer that interpolates between ticks is phase 3, which is
where that motion moves with it.

**That prediction was wrong, and phase 3 measured it.** Ground locomotion was
never on frame `delta` to begin with: `Unit.navigation_step()` has integrated
position explicitly as `global_position += velocity * delta` since the repo's
first commit, on the navigation tick, which was 20 Hz. So a moving unit already
stepped 20 times a second, and slice A1b made those steps 25% *finer*, not
coarser. The `move_and_slide()` that did run on the 60 Hz physics frame was
reached only by units the navigation system does not manage — which in a real
match means units standing still with zero velocity, and in tests means
fixtures with no navigation system at all. Running the demo match after slice
B2 shows no steppiness, because there was none to introduce: at 25 Hz and
ordinary unit speeds the per-step displacement is small, and 60 fps model
animation covers it. This is how the genre has always shipped.

What that costs B4 is its stated justification, not its place. Interpolation is
not needed to undo damage this phase did. It is needed because phase 5 delivers
ticks irregularly — the turn scheduler, adaptive input delay and stall policy
mean a client can go several frames with no tick and then catch up — and
because once decision 3's hot state lands in flat arrays, the view needs a read
path across the boundary regardless.

What it bought and what it did not: the tick order is now a handful of lines in
one function instead of whatever order the scene tree handed out, so it is
observable and changeable in one place. It is **not** yet cross-machine
deterministic — there are no stable entity ids, so `get_nodes_in_group()`
ordering is not guaranteed to match across clients. That is centralization, not
determinism; the gate is phase 4.

`tools/architecture_rules.toml` gained `own-tick-rate`, which forbids a module
from declaring a tick rate of its own. Collapsing five domains was expensive
enough that a sixth should not be able to appear without someone deciding to
add one.

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

**Measured, 2026-08-19, and it corrects the sentence above.** A bare GDScript
`float` is indeed a double, but `Vector2`/`Vector3` components are **not**: this
project runs a standard single-precision Godot build, so every component is a
`float32`. Verified directly — `16777217.0` survives in a plain `float` and
comes back as `16777216.0` from `Vector3.x`, and `0.1234567890123456789` loses
precision at the eighth digit. Every position the game holds in a `Vector3`,
including the click target inside `SimMoveCommand`, is therefore already
narrowed to `float32` before anything else touches it.

This does **not** break the guarantee, and the distinction matters: IEEE-754
pins `+ - * /` and `sqrt` in binary32 exactly as it does in binary64, and every
allowed `Vector*` operation below reduces to those. What it breaks is the
*reasoning* — the determinism above rests on IEEE-754, not on the width, and
the width is not what this section said it was.

Where it becomes a real decision is phase 3. Decision 3 puts hot state in flat
`Packed*Array`s, and `PackedVector3Array` is `float32` while `PackedFloat64Array`
is not. That is a choice about precision on large map coordinates with real
consequences, and it must be made deliberately rather than inherited from
whichever packed type looks like it matches.

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

**Measured, 2026-08-18 — Nagle is off on both links.** `make measure-nagle`
(`tools/measure_nagle.py`, with `tests/net/nagle_probe_client.gd`) reruns it.
Both the client's `WebSocketPeer` and the stream the relay accepts from
`TCPServer` matched a `TCP_NODELAY` control exactly — 0 stalled rounds out of
15, median excess delay 0.37 ms and 0.00 ms respectively — while a control
peer with Nagle deliberately enabled stalled in 15 rounds of 15 at ~30 ms.
Nothing needs to be set in this project's code, and on the relay's accepted
stream nothing *can* be: `set_no_delay(false)` was tried both before and after
`accept_stream()` and changed neither run, so Godot's WebSocket layer owns
that socket option. The measurement runs over loopback, where Nagle's cost is
bounded by the receiver's delayed-ACK timer rather than by the round trip, so
it answers "is `TCP_NODELAY` set" and not "how many milliseconds would Nagle
cost in a real match".

Two things that measurement turned up, which matter more than the answer:

- **The relay's own poll cadence was the real latency, not Nagle.** It pumps
  once per main-loop iteration, and it was inheriting the game's
  `run/max_fps=60` from `project.godot` — up to 16.6 ms added to every
  forwarded frame, over a third of a 40 ms tick. Clearing that exposes a
  second floor, Godot's 6.9 ms `low_processor_usage_mode_sleep_usec`, applied
  in headless runs even though `OS.low_processor_usage_mode` reads back
  `false`. `relay_main.gd` now sets both (see its `POLL_SLEEP_USEC`); measured
  end to end, the relay's added delay went from 6.66 ms median to 0.02 ms for
  about one extra percent of one core.
- **Clients pay the same tax and have not been fixed.** A client polls its
  transport once per rendered frame, so at 60 fps it adds up to 16.6 ms on
  send and again on receive. Unlike the relay, that cadence is the game's and
  cannot simply be raised, so the turn scheduler in phase 5 has to account for
  it rather than assume a frame costs nothing.

A note for whoever reruns this: a receiver that only ever reads makes Nagle
undetectable, because Linux leaves such a socket in quick-ack and it
acknowledges instantly. The harness has its receiver send exactly one frame
first, which is both what makes the effect visible (0 of 12 rounds detected
before that change, 12 of 12 after) and what a real client does anyway, since
every player sends a command frame every turn.

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
checked by `tools/check_architecture.py`. The zone went live in phase 1 with
`scripts/sim/match_clock.gd`, the simulation's tick counter; `allow_empty` came
off with it, so a zone that matches nothing is an error again rather than a
glob that enforces nothing while looking healthy:

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

Phase 3's work is numbered in slices, and the paragraphs below argue them
rather than list them: 11 of the ids mentioned here get a paragraph of their
own and the rest appear only inside someone else's. [`slices.md`](slices.md) is
the lookup — every slice id, the commit that made the change, and a link back
to the paragraph here where there is one. Start there when a comment in the
source cites a number you cannot place.

- **Phase 0 — plumbing. Done 2026-08-18.** Transport interface, in-memory
  loopback, relay skeleton with a container image. No game logic touched.
  Shipped as `scripts/net/`: `net_transport.gd` (the contract),
  `loopback_hub.gd`/`loopback_transport.gd` (deterministic, tick-driven, with
  latency, jitter and per-recipient loss), `websocket_transport.gd`,
  `relay/relay_server.gd` and `relay/relay_main.gd`, with
  `tests/net/transport_conformance.gd` holding the assertions both transports
  must satisfy identically so they stay interchangeable. No separate container
  image was built: `tools/godot-container` gained a `relay` subcommand that
  publishes the port, which is all a second image would have given us. The
  Nagle question this phase was supposed to answer is answered above.
- **Phase 1 — one tick. Done 2026-08-18.** Five tick domains, not the three
  this list originally named, collapsed into one 25 Hz integer tick driven by
  `Match._advance_simulation_tick()`; every Godot `Timer` driving simulation
  state retired. Discrete gameplay — production and upgrade queues, building
  repair, turret reload and burst, linger damage, spice blooms and their
  hazard — advances on the tick. Continuous motion stays on frame `delta` by
  design until the view layer interpolates in phase 3; see decision 4 for what
  that leaves owed. Single-player stayed playable throughout, and every system
  attached to the tick has a test that boots the real match and touches
  nothing, because a system silently dropped from the central loop is the
  failure mode central iteration trades for.
- **Phase 2 — command bus. Done 2026-08-20.** Every player intent now reaches
  the world as a serializable command with a scheduled execution tick: twelve
  types under `scripts/sim/commands/`, ordered by `SimCommandBus`
  (`scripts/sim/command_bus.gd`), encoded by `SimCommandCodec`, and carried out
  by `CommandExecutor` (`scripts/match/command_executor.gd`) — which is the
  single place that answers "which command is this" and the only place that
  turns an entity id back into a Node. Single-player runs with input delay 0
  over a null transport. Replays landed as planned:
  `scripts/match/replay_file.gd` holds the format, with recording hooked to the
  drain so recorded order and executed order are one fact, and playback feeding
  the same bus through `submit_at()`.

  Two things this phase actually turned on, neither of which was on the list.
  Entities needed stable ids first (`scripts/sim/entity_registry.gd`): a
  command may not hold a Node, ids are never reused after release, and
  `live_ids()` is the deterministic iteration order phases 3 and 4 need. And
  the split that matters is not "input versus simulation" but **input versus
  verdict**: a click keeps only what cannot be recomputed later — where the
  player pointed, which entities were selected, which mouse button — while
  every judgement about what that means is recomputed on the execution tick,
  against the world as it stands then.

  The reason is not that two clients would otherwise disagree, tempting as that
  reading is: a verdict carried inside a command is read identically by
  everyone, so shipping one costs nothing in determinism. It is recomputed
  because it can simply be **wrong** by the time it runs: the target died, the
  cell was taken, the credits were spent. At a real input delay two players
  can confirm the same cell inside the same window, and only an execution-time
  check decides which of them loses. And a rule derived from shared state is a rule
  no client can assert — a modified client can then lie about its own input,
  but not about what the input means.

  Which leaves room for something the first pass of this phase got wrong by
  being too strict: **a local check may refuse to send, it just may not
  authorize.** A click on a cell the placement already knows is unbuildable is
  not a game action and should never reach the wire, exactly like a click that
  lands on no cell at all — and before the command bus it never did. Suppressing
  a doomed click locally is free, because the execution-time check still
  decides for every click that does get sent. The filter and the authority are
  the same implementation called from two places for two different jobs, and
  neither is redundant with the other.

  The corollary cost real work: **the preview is not an authority.** The wall
  line used to hand the chain the set of cells its preview had judged
  buildable. Segments are ordered one at a time over many seconds, so that
  snapshot is stale by construction; the buildable set is now recomputed at
  execution. Making that affordable meant splitting `BuildingPlacement`'s
  verdict away from its drawing, which had been answering "can a building
  stand here" only as a side effect of instantiating preview meshes — on the
  simulation tick, on every client, including the ones with no cursor near it.
- **Phase 3 — sim/view split.** Move state ownership out of `Node3D` into the sim
  layer and the flat hot arrays; nodes start interpolating. Headless execution
  faster than real time becomes possible, which is what makes phase 4 cheap.
  Production comes with it: the build and unit queues, the credits they spend
  and the option state they drive are per-player simulation state that today
  lives in one controller bound to the local player — see the open question
  below. Until that lands, a command's `player_id` cannot choose a queue,
  because there is only one. Both of those — production per player and the
  headless loop — are what remains of this phase after tracks A, B, C and R
  closed; they are sliced as tracks `D` and `E` in the entry of that name
  below.

  Two forks decided 2026-08-20, before any of it was written:

  **Navigation runs on the sim tick, every tick, at 25 Hz** — not on an
  accumulator of its own (see phase 1's correction above), and not decimated to
  every second tick. 20 Hz does not divide out of 25 Hz any more than the spice
  hazard's 4 Hz did, so this is the same conversion phase 1 already made and
  for the same reason: a rate that cannot be expressed in whole ticks is a
  second clock wearing a disguise. It costs about 25% more ORCA work per second,
  plus a re-derivation of whatever the navigation layer expresses in its own
  ticks. That inventory turned out small, and it is recorded here because it is
  what makes the conversion checkable rather than hopeful. Exactly two
  constants need re-deriving to keep their wall-clock meaning:
  `SWAP_COOLDOWN_TICKS` (0.5 s) and ORCA's `SQUEEZE_COOLDOWN_TICKS` (0.3 s),
  both anti-oscillation cooldowns, both rounded up so the damping is never
  weakened. `REROUTE_BUDGET_PER_TICK` is a per-tick work allowance rather than
  a duration, and correctly scales with the rate. `MAX_CATCH_UP_TICKS`
  disappears: `FrameTickDriver.MAX_TICKS_PER_FRAME` already bounds exactly
  this, and unlike the navigation budget it counts what it discards
  (`dropped_ticks()`) — which a lockstep match needs, because ticks dropped on
  one client and not another are themselves a divergence. Everything else
  re-derives itself, being expressed in seconds: the enemy-block and
  friendly-yield timers, ORCA's `TAU` horizons, and the waypoint capture radius
  (`speed / NAVIGATION_TICK_RATE`). The one genuine trap was
  `ground_path_follower.gd`'s angular speed, which read the navigation tick
  rate where it meant the rules movement cadence — slice A1a fixed that
  separately, precisely so this rate change could not silently alter how units
  turn.
  Decimating to 12.5 Hz would divide evenly and cost less, and was rejected
  because it is coarser than what ships today: obstacle response and waypoint
  capture are the most visible part of unit control.

  **`Unit` stays a `CharacterBody3D`; only the `move_and_slide()` call goes.**
  Inspection found that call is doing far less than its name suggests:
  `unit.gd` sets `collision_mask = 0` (deliberately — terrain height is sampled
  explicitly, and letting the body collide with the terrain mesh made every
  triangle edge behave like a small wall), and nothing in the project reads
  `is_on_floor()`, `get_slide_collision()`, `up_direction` or `motion_mode`. So
  it resolves no collision and returns nothing anyone consults; it integrates
  `position += velocity * physics_delta` and that is all. Separation between
  units is `OrcaAvoidance`'s job, on the navigation tick. Replacing it with an
  explicit integration on the sim tick is therefore a small change rather than
  a physics rewrite. The node class stays because it still carries `velocity`
  and the `collision_layer` mouse picking selects units through; changing it
  would touch every unit scene to buy clarity, not behaviour.

  **Found while measuring slice A1a, 2026-08-20: flight is already
  non-deterministic, and the test suite has been showing it all along.**
  `tests/units/flight_run.gd` reports 253 or 254 assertions on repeated runs of
  identical code. The count varies because several of its loops assert once per
  step and exit when the aircraft reaches a state, so the count *is* how many
  steps that took — and that number is not reproducible. The cause is that
  flight state transitions are driven by `AnimationPlayer`'s
  `animation_finished` signal
  (`UnitFlightController.notify_animation_finished()`), which fires on engine
  frame time: how many `_physics_process()` steps elapse before a transition
  lands depends on how fast the machine happened to run. This is simulation
  state advanced by the view layer's clock — the exact thing decision 3
  forbids, and what `sim-no-signals` and `sim-no-frame-delta` would catch if
  this file sat in the sim zone. Slice B3 has to sever it: the transition
  completes on a tick deadline the simulation owns, with the clip playing
  alongside as presentation. Until then no replay of a match containing
  aircraft can reproduce, and phase 4's replay-twice check would fail on this
  alone.

  *Updated after slice B2:* the **symptom** is gone from the suite — flight now
  reports a stable 381 assertions across runs, because B2 moved the flight
  branches onto the fixed tick and the fixture drives those ticks explicitly
  instead of letting real frame timing decide how many steps a transition
  takes. The **cause** is untouched: `Unit._on_animation_finished()` still
  calls `UnitFlightController.notify_animation_finished()`, and transitions
  still complete on that signal. A green, stable suite is now evidence about
  the fixture rather than about the code, which makes this defect harder to
  see, not easier. B3 still owns severing it.

  *Updated after slice B3d, 2026-08-21:* the **cause** is severed.
  `UnitFlightController.notify_animation_finished()` is gone, and so is its
  call site in `Unit._on_animation_finished()`. `set_cruise_moving()` now
  reads the Fly/Hover transition clip's authored length once, when the
  transition starts — the same `flight_clip_length()` one-time-lookup idiom
  `flight_landing_approach_radius()` and the takeoff/land transitions already
  used — and stores it as a tick deadline; `advance()`, called once per
  simulation tick, ticks it down and completes the transition itself.
  `AnimationPlayer` keeps playing the clip on its own player for the look, but
  nothing simulation-relevant reads it back. `tests/units/flight_run.gd`
  proves the severing directly, not just by staying green: a new case,
  `_test_flight_transition_completes_on_tick_not_signal`, starts a transition,
  lets the real `AnimationPlayer` actually finish playing the clip and fire
  its own `animation_finished` (still wired straight into
  `Unit._on_animation_finished()` by `_prepare_idle_animations()`, so this is
  the real old trigger, not a stand-in for it) with zero simulation ticks
  run, and asserts the transition is still pending — the middle-step canary,
  without which a later "ticks alone complete it" assertion would be
  vacuous. It then drives only `UnitFlightController.advance()`, with the
  `AnimationPlayer`'s own playback never touched again, and confirms the
  transition completes exactly on the computed tick deadline.
  `_test_flyer_cruise_animation` was converted the same way, from emitting
  `animation_finished` by hand to driving `advance()` by tick count.

  Two things this slice did **not** touch, so a future reader does not read
  "flight" as fully clean:

  - `UnitDeployState`'s deploy/undeploy transitions
    (`scripts/units/unit_deploy_state.gd`) and the authored fire-sequence
    lifecycle both still complete on `Unit._on_animation_finished()`'s other
    branches, exactly as before — B3's own file list never named
    `unit_deploy_state.gd` as this slice's target, and `_on_animation_finished()`
    still has to serve them after the flight branch is gone; this slice only
    confirmed removing the flight branch does not change what reaches them
    (checked directly: none of `UnitCombat`'s fire-sequence matching,
    `UnitDeployState`'s player/animation-name matching, `UnitLocomotion`'s
    mech-gait matching, or `UnitIdleAnimations`'s prefix matching can match a
    `Fly`/`Hover`/`FlyToHover`/`HoverToFly` clip name, so the fall-through is a
    no-op for all of them).
  - **Found during the B3d sweep, not fixed by it:** `UnitLocomotion`'s mech
    gait state machine (`scripts/units/unit_locomotion.gd`) has the identical
    shape. `on_animation_finished()`'s `State.STARTING` branch completes a
    mech's start-of-movement transition on `MOVE_START_ANIMATION`'s finished
    signal — racing the tick-driven `advance_start_transition()`, whose own
    comment already admits the tension ("Physics owns the transition deadline
    *as well as* AnimationPlayer"). `is_starting()` gates whether `Unit`
    zeroes `velocity`, so which of the two paths wins first decides, on real
    hardware, which tick a mech actually starts moving on — the same class of
    non-determinism this slice just removed from flight. Its `State.STOPPING`
    branch is a plainer case of the same thing: `on_animation_finished()` is
    the *only* path back to `State.IDLE`, with no tick-driven fallback at all.
    This was already named, once, in the B1 inventory above ("already worked
    around once rather than fixed") but is not in B3's file list and is not
    fixed here — left for whichever slice claims `unit_locomotion.gd`,
    flagged so it is not mistaken for something this slice ruled out.

  **Slice B1's inventory, 2026-08-20.** 96 `delta: float` signatures across 37
  files. The dividing question is not "does this run every frame" but "does the
  value this advances survive into the next tick as something a command or a
  checksum can see". Sorting them is the slice's whole product; B2–B4 consume
  this list and it stops existing when they are done, which is why it is a work
  list here rather than a registry anyone has to keep current.

  *Stays on frame `delta`, and should* — camera (`rts_camera.gd`), cursor,
  `panel_tab.gd`, `selection_halo.gd`, `navigation_grid_debug.gd`,
  `unit_shader_fx.gd`, `unit_movement_sounds.gd`, `combat_impact_effect.gd`,
  `UnitLocomotion.advance_gait()` (animation playback speed), and the visual
  slope tilt (`Unit._advance_visual_slope_alignment()`,
  `UnitTerrainAlignment.advance_slope_alignment()`). None of these are readable
  by a command or a checksum, and interpolating them is the point of B4.

  *Already resolved* — `FrameTickDriver.pending_ticks()` and `Match._process()`
  are the conversion boundary itself; the three controllers' `process(_delta)`
  no longer use the parameter; the navigation `tick(delta)` chain now receives
  `MatchClock.SECONDS_PER_TICK` (slice A1b).

  *Moves to the tick* — ground locomotion and terrain snapping (B2:
  `Unit._physics_process()`, `navigation_step()`, `_snap_to_terrain()`,
  `_slope_speed_multiplier()`, `turn_toward()`); flight, projectiles, turret
  aim and target acquisition (B3: `unit_flight_controller.gd`,
  `combat_projectile.gd`, `combat_turret.gd`, `combat_target_acquisition.gd`,
  `unit_combat.gd`, `building_combat.gd`, `advanced_carryall_transport.gd`,
  `unit_deploy_state.gd`, `building_refinery_docks.gd`).

  *Updated after slice B3a, 2026-08-20:* `combat_projectile.gd` is off that
  list. `CombatProjectile` no longer defines `_physics_process()`; flight,
  hit resolution and impact now run from `CombatProjectile.sim_tick()`,
  joined to `Match._advance_simulation_tick()`'s new `"sim_projectiles"` group
  loop the same way linger effects and spice mounds already join theirs (see
  that function's doc comment for the loop and why it sits right after linger
  effects). `advance()` itself is unchanged — it already sub-stepped against
  `MAX_SIMULATION_STEP` (the rules' 20 Hz), which is coarser than one 25 Hz
  tick (0.05s > 0.04s), so handing it a fixed tick-length delta was a
  same-behavior wiring change, not a rewrite of flight itself. The rest of the
  B3 list is untouched and stays on frame `delta`: firing still launches a
  projectile from `unit_combat.gd`/`building_combat.gd`'s `_process()`
  (B3b/B3c), and turret aim/target acquisition and flight-controller
  transitions are unmoved. That leaves the placement question B3b inherits:
  once firing itself joins the tick, whichever branch does it has to recheck
  where `try_fire_at()`'s call site lands relative to the `"sim_projectiles"`
  loop, because "a shot fired this tick must not also travel this tick" holds
  today only by accident of scene-tree ordering (`Match._process()` runs
  before any `Unit`/`Building`'s own `_process()` every frame — see
  `tests/combat/support/sim_tick_pump.gd`), not because this loop's position
  enforces it.

  *Updated after slice B3b, 2026-08-20:* `building_refinery_docks.gd` is off
  that list; `building_combat.gd` is only partly off it. `Building._process()`
  used to run four statements: `_building_combat.advance(delta)`,
  `_authored_fire_controller.advance(delta)`,
  `_building_combat.after_authored_advance()`, and
  `_refinery_docks.advance(delta)`. `Building.sim_tick()` now runs three
  things: `CombatTurret.advance_tick()` (already there), the authored fire
  controller's `advance()` (shot committal), and the refinery dock departure
  cooldown. `AuthoredFireController.advance_sequences()` was checked, not
  assumed, the same way B3a checked `MAX_SIMULATION_STEP`: it keeps its own
  `elapsed` accumulator and compares it against precomputed `shot_times`; it
  never reads the `AnimationPlayer`'s playback position, and the clip itself
  keeps playing via Godot's own per-frame processing at whatever
  `speed_scale` was set regardless of which clock calls `advance()`. Moving it
  onto the tick is therefore a change of delta source and nothing more — there
  was no animation coupling to sever here, unlike the flight-controller
  finding above.

  `BuildingCombat._advance_popup_transition()` moved too, into a new
  `BuildingCombat.sim_tick()`: its own `_transition_elapsed` accumulator has
  the identical shape (never reads the transition player's position, only
  compares against a duration cached once at transition start), and it gates
  whether `_advance_engagement()` lets a popup turret fire — a simulation
  decision wearing a visible motion, decided in favor of simulation because
  the decision, not the motion, is what a replay or checksum needs to agree
  on. `BuildingCombat.advance()` — turret aim, target acquisition, and the
  engagement decision that calls the fire controller's `try_start()` — stays
  on `_process()`, unmoved: this is the same "turret aim and target
  acquisition" work the B3 inventory above already named as unmoved after
  B3a, and it still is. `restore_popup_hold_pose()` stays in `_process()` too,
  on both call sites (inside `advance()` and in `after_authored_advance()`):
  it repairs a rendered pose the authored clip may have overwritten and
  changes no state a replay or checksum can see, so it belongs on the frame's
  clock regardless of what clock the fire controller itself runs on. Its
  adjacency to the fire controller's `advance()` call is no longer
  load-bearing now that that call has moved to `sim_tick()` — `Match` already
  runs every due tick before any `Building`'s own `_process()` this same
  frame (the ordering B3a's doc comment relies on), so `after_authored_advance()`
  observes a tick's pose write regardless of exactly where in `_process()` it
  sits — but the two-call structure was left as is rather than collapsed,
  since collapsing it is a behavior change this slice was not asked to make.

  `_advance_engagement()` also has a second, direct firing path
  (`turret.try_fire_at()`, taken only when `has_fire_animation()` is false)
  that stayed on `_process()` with the rest of that function. Checked, not
  assumed: every one of `BuildingCombat.DEFENSIVE_TURRET_IDS`'s seven entries
  has an authored `Fire_0` (and, for two-weapon turrets, `Fire_1`) animation
  in its converted scene, so that fallback is unreachable by any building
  configured today — there is nothing live to migrate, and it is left where
  it is pending whichever slice gives `combat_turret.gd`'s aim/target
  acquisition its own tick half to join, the same open item B3a recorded.

  Building firing joining the tick reopened the trap B3a left explicitly for
  this slice: "a projectile fired this tick must not also travel this tick"
  held only because firing ran from `_process()`, not because of
  `"sim_projectiles"`'s position in `Match._advance_simulation_tick()`. Once
  `AuthoredFireController.advance()` runs from `Building.sim_tick()`, inside
  that same function, a shot fired there parents a new `CombatProjectile`
  synchronously (`turret.try_fire_at()` → `add_child()` → `_ready()` joins
  `"sim_projectiles"` before the call returns), so the invariant now depends
  entirely on loop order. The `"buildings"` loop moved from directly after
  `"units"` (its position since before B3a) to directly after
  `"sim_projectiles"` instead, so a projectile a building fires this tick
  joins the group too late for this tick's already-completed projectile walk.
  Units are unaffected — `unit_combat.gd` still fires from `Unit._process()`
  (B3c), so scene-tree ordering alone still protects that path, exactly as
  before. See `Match._advance_simulation_tick()`'s doc comment for the full
  ordering argument, including why linger effects' and projectiles' own
  positions did not need to move.

  One fixture needed the B2 treatment twice.
  `tests/combat/defensive_building_run.gd` drove five cases by hand with no
  `Match` in the tree and expected a manual `building._process(1.0 / 60.0)`
  loop (or, for two cases, `await physics_frame`/`await process_frame` with no
  ticking at all) to both aim *and* fire; converted to pump `sim_tick()`
  first, the same idiom `SimTickPumpScript` already names for this exact
  failure. `tests/buildings/upgrade_run.gd`'s refinery dock reservation test
  drove the departure cooldown with `refinery._process(2.9)` /
  `refinery._process(0.1)`; converted to whole ticks (74 then 1, since
  3.0 seconds is exactly 75 ticks at 25 Hz and 2.9/0.1 do not divide evenly
  into `SECONDS_PER_TICK`).

  Two of them are worth naming individually, because their classification is
  not what the file they live in suggests:

  `UnitLocomotion.advance_start_transition()` looks cosmetic and is not: while
  `is_starting()` holds, `Unit` forces `velocity = Vector3.ZERO`, so this
  countdown decides whether a unit moves at all. Its own comment already
  records the tension — it says physics owns the deadline "as well as
  AnimationPlayer" so that manual simulations keep moving when no render frame
  advances the player. That is the same animation-drives-simulation coupling
  the flight finding above describes, already worked around once rather than
  fixed.

  `HarvesterController._transfer_unload_credits()` advances the **economy** on
  the render frame: `Unit._process()` calls it, and it ends in
  `player.add_money()`. Total income per wall-clock second is frame-rate
  independent, so this is not a "faster machine earns more" bug — but the tick
  on which each credit lands is decided by frame timing, and credits gate
  production. Two clients running at different frame rates would fund the same
  build order on different ticks. It belongs with B2's economy-adjacent work
  rather than being left for B3.

  **Slice C2's scope, decided 2026-08-21, and the debt it knowingly takes on.**
  `global_position` is touched 260 times across 55 files, 49 of them writes.
  Migrating reads and writes together would be one unreviewable diff, which is
  the opposite of how this phase has been built, so C2 takes the half that
  carries the meaning: **`SimEntityState` owns the write; the node's
  `global_position` becomes a mirror updated from it.** Roughly fifteen write
  sites change; every read keeps working unchanged, because the mirror still
  holds the same value it always did. That is enough to make the store
  authoritative, to make a snapshot a copy of packed arrays, and to give B4 the
  two consecutive ticks it interpolates between.

  **The debt, stated plainly rather than implied: decision 3's "nodes are views"
  is only half true after C2.** Writes go through the simulation, but readers
  still ask the node, and a reader cannot tell the difference — which means the
  design's own promise is being kept by convention at 260 call sites rather than
  by structure. Two concrete consequences follow, and neither should be
  discovered later as a surprise:

  - Any code that writes `global_position` directly instead of through the
    store diverges from it silently, and the mirror makes that divergence look
    correct until a snapshot or a checksum disagrees. C2 must add a checker rule
    for direct writes, with its `exempt` list as the audit queue — the same
    ratchet `animation-completes-simulation` uses, for the same reason.
  - Reads are not enforceable that way; 260 sites is far past where a rule stops
    being a rule and becomes noise. They come back honestly only when a later
    slice moves readers onto the store, which is a real slice someone has to
    schedule, not something that happens as a side effect of C3 or C4.

  This is a deliberate trade, not an oversight: the incremental path keeps every
  slice reviewable and the game playable, which decision 11 requires. It is
  recorded here so that "the sim owns state" is not read as finished when it is
  half finished.

  **Slice C3, decided 2026-08-21: health and shields, for units and buildings
  both, and why it needed no checker rule.** C2's chokepoint problem does not
  repeat here. `Unit.health`/`Unit.shields` and `Building.health`/
  `Building.shields` were already GDScript properties with `set(value)`
  before this slice touched them, so every write in the project — about
  fifteen call sites across five files (`unit.gd`, `building.gd`,
  `building_survivors.gd`, and one reflection-based `.set("health", ...)` in
  `building_repair_service.gd`), swept and confirmed, none bypassing —
  already funneled through one setter per field per class. There was no
  scattered `global_position`-style write surface to migrate and no second
  name for the backing storage a caller could assign to instead of the
  setter, so C3 makes the setter itself write the store: `SimEntityState.set_health()`/`set_shields()` first, the node's
  field second, the same store-then-mirror order `set_simulation_position()`
  established. `clampf(value, 0.0, max_health)` is computed once, in the
  setter — the only place that knows `max_health` — and that same clamped
  number is what both the store and the mirror receive, so a write above the
  ceiling cannot land unclamped in one and clamped in the other. View work
  that used to run after the clamp (`health_changed.emit()`, the two
  `Building._refresh_*()` calls, `Unit._refresh_shield_visibility()`) still
  runs last, after both the store and the mirror hold the same value it
  reads.
  `global-position-bypasses-store`'s pattern cannot be repeated for this
  field: a regex has no way to tell the setter's own sanctioned
  `health = clamped` from an external bypass, because outside the setter no
  such bypass exists to distinguish it from — GDScript enforces the setter on
  every assignment, full stop. A rule that cannot fire is not a rule, so none
  was added.
  Buildings rode along at effectively no extra cost: `SimEntityRegistry`
  already allocates ids for `Kind.BUILDING` from the same id space
  `Kind.UNIT` uses, so `SimEntityState`'s arrays already index them, and a
  building's `_register_entity_id()`/`_ready()` ordering already matches a
  unit's. C4 (owner) inherits both kinds covered for the identical reason.
  Missing-id reads return `INF`, `0.0`'s replacement for a bare float the way
  `Vector3.INF` replaced `Vector3.ZERO` for position in C1 — `0.0` health is
  what a dead entity legitimately has, so it cannot also mean "no value."
  `PackedFloat32Array` was kept, matching the `float` GDScript already
  declares for these fields today and the identical reasoning position's
  `PackedVector3Array` already rests on (decision 5). No previous-tick buffer
  was added for either field: nothing has named a consumer for a previous
  simulation tick's health or shields the way B4 names one for position, so
  adding one now would be exactly the speculative generality this store's own
  doc comment already declines for velocity.

  **Slice C5, decided 2026-08-21: deferred despawn, and the defect that
  changed its shape.** Decision 3's third borrowed-from-ECS property is
  "entity creation and destruction are deferred to queues, never applied
  mid-iteration." C5 takes destruction only; creation is C6. The split is not
  a matter of diff size alone: creation's current safety rests on the loop
  ordering `Match._advance_simulation_tick()`'s doc comment argues at length
  and a wiring test pins, so it is fragile but *correct*, while destruction
  was found to be neither.

  What was checked rather than assumed. `FrameTickDriver.MAX_TICKS_PER_FRAME`
  is 5, so one engine frame can run up to five simulation ticks, and
  `queue_free()` neither drops group membership nor invalidates the instance
  until that frame ends. A killed entity is therefore still listed by
  `get_nodes_in_group()`, still passes `is_instance_valid()`, and still gets
  ticked for every remaining tick of its own frame. `Unit` survives this only
  because slice B2 gave it `_simulation_halted`, checked by both
  `sim_tick()` and `sim_tick_combat()`. **`Building.sim_tick()` checks
  nothing**, which means a dead building's turrets reload, its refinery dock
  cooldown runs, and `AuthoredFireController.advance()` can commit a shot --
  a dead building can fire. `Building.prepare_model_for_corpse()`'s own
  comment claims `set_process(false)` prevents exactly this; that claim was
  true when written and stopped being true at slice B3b, which moved those
  ticks onto `sim_tick()`, where no engine flag reaches them. And both
  classes' death sequences have a second hole on the branch where no death
  clip matched (`unit_death_sequence.gd`, `building_death_sequence.gd`):
  that branch calls `queue_free()` without going through
  `prepare_model_for_corpse()` at all, so neither `_simulation_halted` nor
  `set_process(false)` is ever set.

  Five mechanisms currently encode one concept -- `_simulation_halted`,
  `set_process(false)`, `set_physics_process(false)`, `remove_from_group()`
  in projectiles and linger effects, and the six `is_instance_valid()` guards
  in `Match`. C5 replaces the entity-id-carrying part of that with one:
  `Unit.request_despawn()` / `Building.request_despawn()`, which halts the
  entity's simulation immediately and hands its id to a queue.

  **Fork 1, when a killed entity stops simulating: immediately, through one
  shared notion, not at the end of the tick.** Deferring the *logical* death
  to the tick boundary is the semantically cleaner simulation -- everything
  on tick N would see the world as of the start of tick N, and simultaneous
  mutual kills would become symmetric -- but it is a different simulation: a
  unit killed by this tick's linger damage would newly get to shoot back in
  the same tick's combat pass. Phase 3's standing rule is that behaviour does
  not change, so the timing stays exactly what `_simulation_halted` already
  gave units, and the queue owns only the structural half. Making death
  resolve on the tick boundary is a real gameplay decision available to a
  later phase; it is recorded here so nobody mistakes it for something C5
  quietly settled.

  The shared notion is `SimEntityRegistry`'s own liveness, not a new flag
  alongside it: `request_release(id)` erases the id from `_alive` at once and
  appends it to a pending queue. That has a consequence worth naming, because
  it is a feature and not a side effect -- `SimEntityState`'s accessors all
  guard on `is_alive()`, so a dead entity's hot state freezes the instant it
  dies, with no per-field work. C3's `is_finite(stored)` read-back guard in
  the health setter, added because a refused store write must not poison the
  mirror, is what makes this safe without touching a single setter.
  `EntityNodeIndex.node_for()` likewise stops resolving the id at once, which
  `command_executor.gd` already expects: its comment has said since phase 2
  that "an id that no longer resolves is skipped."

  **Fork 2, where `queue_free()` goes: into the queue drain.** The drain runs
  at the **end** of `_advance_simulation_tick()`, and that placement rather
  than "the start of the next tick" is load-bearing for a reason specific to
  Godot: `queue_free()` deletes at the end of the *engine frame* regardless
  of which tick called it, so deferring from mid-tick to end-of-the-same-tick
  costs exactly zero wall-clock and cannot be observed. Draining at the start
  of the next tick would push a death that happened on a frame's last tick a
  whole frame later, which would be visible. The node's actual deletion
  moment is therefore unchanged by this slice; what changes is that the
  entity is halted from the kill site onward, and that the unbinding happens
  at one point instead of wherever the killing blow landed.

  Every despawn of an id-carrying entity routes through this, not just the
  two death sequences: `BuildingSaleService._finish()` (in
  `scripts/production/building_sale_service.gd`) and the two
  `UnitDeploymentController` conversions (MCV to construction yard and back)
  free a `Unit` or a `Building` too, and leaving them on the old path would
  recreate the "one concept, several mechanisms" problem this slice exists to
  end. A sold building stops firing immediately for the first time as a
  result.

  What C5 does not cover, stated so it is not read as finished.
  Projectiles, linger effects, spice mounds and corpses carry no entity id at
  all -- `SimEntityRegistry.Kind` has only `UNIT` and `BUILDING` -- so their
  own `remove_from_group()` handling stays exactly as it is, and so do all
  six `is_instance_valid()` guards in `Match`, which still protect against
  nodes freed by routes no queue owns. An entity leaving the tree for a
  reason that is not a despawn (scene teardown, a suite ending) still
  unbinds through `_exit_tree()`; that path is idempotent against the queue
  by construction, since the drain erases the same bindings. And an entity
  with no `Match` in the tree -- which is most unit and combat suites -- has
  no queue to drain it, so `request_despawn()` falls back to freeing the node
  directly. That fallback is a second path, honestly, and it is the one
  narrow case where there is no alternative: without it a killed unit in
  those suites would never be freed at all.

  **A finding this slice reported wrongly, and the measurement that corrected
  it.** A full suite run emits about 1700 `SimEntityState` refused-write
  errors, essentially all of them from `tests/match/demo_boot_run.gd`. The
  first explanation written here -- and reported as traced -- was that C5
  caused them: erasing liveness at the kill site would make every write
  against a not-yet-drained entity loud, and `UnitNavigationSystem` does keep
  stepping a unit whose node is still valid. Both halves of that are true
  statements about the code, and together they are still the wrong answer.

  Running `demo_boot_run.gd` at the commit *before* C5 settles it: **1737
  errors there against 1698 after**, with the same call sites in the same
  proportions (~800 from `Unit._terrain_snap_body()`, ~800 from
  `navigation_step()`, ~60 from `Match._place_on_map()`). The flood predates
  the slice and C5 slightly reduced it. A plausible mechanism that really
  exists in the code is not evidence that it is the mechanism producing the
  symptom in front of you -- the same mistake, in the same phase, that
  `flight_run.gd`'s stabilised assertion count already taught once from the
  opposite direction.

  The actual cause, confirmed by experiment rather than by reading:
  `MatchLookup` (scripts/match/match_lookup.gd) resolves the running match
  with `get_first_node_in_group()` and does not check whether that node is
  already `is_queued_for_deletion()`. A `Unit` or `Building` entering the tree
  while a dying `Match` still holds group membership therefore takes its
  entity id from a registry that is about to disappear, and every later write
  resolves `entity_state()` to a different match's store -- where that id was
  never allocated. Once a unit is mis-registered, every position write it
  makes for the rest of its life reports. The fix that suggested itself was
  to skip a queued-for-deletion match in both lookups: an entity that can
  only find a dying match would then get no id at all, exactly the "no Match
  in the tree" case those lookups were already written to tolerate.

  That fix was measured, not just reasoned about, and the measurement
  disproved it: `demo_boot_run.gd` produced **1696** refused writes with the
  skip in place, against 1698 without it -- statistically unchanged, not a
  fix. The reasoning above was incomplete rather than wrong: it addressed
  only one of two mirror-image populations that group-position resolution
  gets wrong. A *new* entity entering the tree beside a dying match does
  skip it and take an id from the live one, once the skip exists. But an
  entity *already registered* before a second match ever showed up keeps
  being ticked every frame through the global `"units"`/`"buildings"`
  groups, and its writes go through `entity_state()`, which was still
  resolving the running match by `get_first_node_in_group()` -- so once two
  matches were briefly both group members, an already-registered entity's
  writes could resolve to whichever one the lookup preferred, not
  necessarily its own, regardless of which candidate was dying. Skipping a
  dying candidate cannot fix a resolver that is answering the wrong
  question in the first place.

  The right question is "which Match owns this node", not "which Match is
  first in the group" -- group position only ever coincidentally agreed with
  ownership, for as long as this repo's suites mostly kept exactly one Match
  in the group at a time. Ownership is what the scene tree's ancestor chain
  actually encodes: a node's Match ancestor is unambiguous no matter how
  many other Matches the group holds at that instant. `_live_match()`
  (`scripts/match/match_lookup.gd`) now walks the node's ancestors first and
  returns the first one in `GROUP` that answers the requested method,
  falling back to the old group-wide walk only when the node has no Match
  ancestor at all -- `tests/match/support/command_pump.gd` installs a stub
  Match into the group that is never an ancestor of the entities under test,
  so that fallback is load-bearing, not caution. Measured after ancestor
  resolution: `demo_boot_run.gd` produces **0** refused writes with its 364
  assertions still passing, and the full suite -- **63 passed, 0 failed** --
  drops refused writes across the whole run from 1707 to **9**, of which 7
  are `tests/sim/entity_state_run.gd`'s own deliberate error-path cases and
  2 are `tests/match/despawn_run.gd` hitting the known between-ticks
  navigation gap the next paragraph describes.

  What survives of the original reading, recorded so it is not rediscovered as
  new: navigation prunes its agents on `EntityQuery.is_live()`, which tests
  node validity and `is_queued_for_deletion()`, never simulation liveness. For
  a kill that lands *on* a tick this is harmless, because `_navigation_tick()`
  runs at the top of `_advance_simulation_tick()` and the drain at its bottom,
  so the node is already queued for deletion before navigation next looks at
  it. For a kill that lands *between* ticks -- a signal, a `_process()` path --
  the unit is halted and its id released while the node is not yet queued, and
  the next tick's navigation will step it once. One tick, no behaviour change,
  and now a measured size rather than a guessed one: exactly 2 refused writes
  across a full suite run, both of them `despawn_run.gd`'s own corpse-branch
  case, which kills between ticks on purpose. It is a real gap and a small one; it is
  not what the errors above were.

  One near-miss worth keeping, because the code comments that now prevent it
  read as obvious only in hindsight: `request_despawn()` is idempotent on
  `_simulation_halted`, and `Unit.prepare_model_for_corpse()` used to set that
  same flag a few statements before `UnitDeathSequence.begin()` called
  `request_despawn()`. The guard therefore swallowed the despawn on the ordinary
  corpse branch -- the death path every unit with a matched death clip takes --
  so the node was halted but never freed and its id never released. The flag now
  has exactly one writer per class, `request_despawn()` itself, and
  `tests/match/despawn_run.gd` names the hazard directly rather than leaving it
  to be rediscovered through five unexplained `is_queued_for_deletion()`
  failures in a suite about corpses and animation clips.

  **Slice C6, decided 2026-08-22: deferred spawn, and the group that had to
  be split first.** Decision 3's third ECS property, creation half. C5 took
  destruction; this takes the other side, and the forks were answered the
  same way: the queue defers **entry into the simulation**, not the creation
  of the node, and it covers everything the tick walks rather than only the
  two kinds that carry an entity id.

  Deferring entry rather than creation is what keeps every call site's shape.
  `CombatTurret.try_fire_at()` constructs a `CombatProjectile`, parents it,
  configures it, and calls `launch()` -- which can *fail*, on an out-of-range
  shot or a target that died between muzzle selection and the call, after
  which the caller frees the node it still holds. A queue that owned creation
  would have to model that failure path; a queue that owns only the moment
  something becomes simulated does not have to know the path exists. This is
  the exact mirror of C5's answer, where death also takes effect immediately
  and the queue owns only the structural half.

  The defect that grounds it, found by reading the tick order rather than by
  a failing test: `BuildingSurvivors.spawn_for_destroyed_building()` spawns
  infantry from a building's death, and that death arrives from inside the
  projectile loop or the linger loop. `Unit.sim_tick()`'s pass over `"units"`
  has already run by then; `Unit.sim_tick_combat()`'s has not. So a survivor
  **misses the locomotion pass but catches the combat pass on its own birth
  tick** -- it can acquire a target and commit a shot in the tick it was
  created, while not yet being able to move. Nothing chose that; it is where
  two loop positions happened to land relative to a third.

  **What made this bigger than it looks, and the split it forced.** The
  obvious implementation -- defer the `add_to_group()` that makes an entity
  live -- cannot be applied to units and buildings as they stand.
  `"units"` is declared statically in 99 scene files under `scenes/units/`,
  and neither it nor `"buildings"` belongs to the tick: selection, the side
  panel, availability tracking, blocker refresh and `UnitNavigationSystem`
  all read them too. Deferring membership in a group that shared would make a
  newly spawned unit unselectable and invisible to the UI for a tick, which
  is a view regression bought to fix a simulation ordering question.

  The pattern that resolves it is already in the codebase rather than
  invented for this slice: `SpiceMound._ready()` joins **two** groups, the
  shared `"spice_mounds"` everything else reads and the tick-only
  `"sim_spice_mounds"`, and `CombatProjectile`/`CombatLingerEffect` have
  tick-only groups by construction because nothing else ever wanted to list
  them. Three of the five kinds the tick walks already have their iteration
  source separated from the view layer's; units and buildings are the two
  that do not. So C6 splits in two:

  - **C6a** introduces `"sim_units"` and `"sim_buildings"`, joined in code
    beside the existing scene-declared membership, and moves the tick's three
    loops -- and `UnitNavigationSystem`'s own reads of `"units"` -- onto
    them. Membership is identical at every instant, so this changes no
    behaviour; what it changes is that the simulation stops sharing its
    iteration source with the view layer, which is decision 3's own sentence
    made structural instead of aspirational. No scene file is touched: the
    static `"units"` declaration stays exactly where it is and keeps meaning
    what it has always meant.
  - **C6b** builds the queue and routes the three joins nothing but the tick
    reads -- `"sim_projectiles"`, `"sim_linger_effects"`, `"sim_spice_mounds"`
    -- through it, drained at the **start** of `_advance_simulation_tick()`:
    admit, simulate, retire, with C5's despawn drain already at the other
    end. An entity with no `Match` in the tree joins immediately, the same
    fallback and the same reason `request_despawn()` carries, routed through
    one shared `MatchLookup.request_sim_entry()` so three callers do not
    each keep that null-check correct separately.
  - **C6c** takes `"sim_units"` and `"sim_buildings"`, together with
    `UnitNavigationSystem`'s own registration. Split out of C6b rather than
    sequenced arbitrarily: deferring a unit's admission while navigation
    still picks it up off `"units"` would leave navigation driving a unit
    the tick does not simulate, which is precisely the inconsistency this
    property exists to remove. The `call_deferred` finding below is C6c's
    other half, and what C6c actually cost is recorded after it.

  **What C6b proved, and one thing it could not.** The load-bearing case is a
  real shot from a real building inside a real match: the projectile is not in
  `"sim_projectiles"` for the remainder of the tick that fired it, and travels
  on the next -- with a positive control, so it cannot pass for a projectile
  that never moves at all. What the suite deliberately does **not** assert is
  admission *order*. The first attempt did, by copying the despawn queue's own
  ordering case, and it failed: `take_pending_releases()` returns a
  `PackedInt32Array`, whose order is observable and worth pinning, while
  `apply_pending_entries()`'s only effect is `add_to_group()` -- group
  membership, a set. The queue does walk its requests in order, but that order
  is unobservable through `get_nodes_in_group()`, whose own iteration order is
  Godot's to decide and is already this document's known phase 4 gap. A test
  asserting it would have been asserting the engine, not this code.

  **The tick order stays exactly as it is.** Once entry is deferred, the
  ordering arguments in `Match._advance_simulation_tick()`'s doc comment stop
  being load-bearing: a projectile fired this tick cannot travel this tick
  because it is not in the group yet, not because the buildings loop was
  moved past the projectile loop in B3b. Moving anything back would be a
  different, silently-chosen simulation, which phase 3 does not do. C6b
  rewrites the *argument* -- from "this order is required" to "this order is
  now free, and here is what used to require it" -- and leaves the order
  untouched.

  **Two things C6a's own sweep turned up, both handed to C6b rather than
  guessed at.** The sweep that decides, per call site, whether a group read
  is simulation or view is the substance of this slice, and it is the part a
  wrong answer hides until C6b defers membership. Two sites resisted a clean
  verdict, and both matter more than the reclassification that found them.

  `UnitNavigationSystem._on_tree_node_added()` stays on `"units"`/
  `"buildings"`, and must: `SceneTree`'s `node_added` fires while
  `_enter_tree()` propagates, before `_ready()` runs anywhere in the subtree,
  and the tick-only groups are joined *in* `_ready()`. A unit scene's static
  `"units"` declaration is already present at that moment; `"sim_units"` is
  not and cannot be. Switching this check would have made it permanently
  false and silently killed live navigation registration -- the exact class
  of change C6a promises not to make.

  Reading that handler turned up the sharper problem, which is not about
  groups at all: it registers through `register_unit.call_deferred(node)`.
  Deferred calls flush at the end of the engine **frame**, while ticks run
  inside it -- up to `FrameTickDriver.MAX_TICKS_PER_FRAME`'s five. A unit
  spawned during the first tick of a frame is therefore not navigable for the
  second and third ticks of that same frame, while on a machine whose frame
  carries one tick it is navigable by the very next one. **How many ticks a
  unit waits before navigation can see it is decided by frame rate**, which
  is a divergence of exactly the kind lockstep exists to prevent, and it was
  not on any list here before this sweep. C6c inherits it: the admission
  queue's drain is the tick-domain moment this registration belongs to, and
  moving it there is what makes the wait a fixed number of ticks on every
  machine.

  **What C6c built, and the three things that were not on any list.**
  `Unit._ready()` and `Building._ready()` now *request* entry into
  `"sim_units"`/`"sim_buildings"` through `MatchLookup.request_sim_entry()`
  instead of joining them, and nothing else in either function moves. The
  shared `"units"`/`"buildings"` joins stay immediate, so a newly spawned
  unit is still selectable and visible to the UI on its birth frame, and
  `_register_entity_id()` stays immediate too: an entity needs its id the
  instant it exists, because every write it makes from that point resolves
  through that id. Only the tick's iteration source is deferred.

  `UnitNavigationSystem` gets an ordered pending list drained at the top of
  `sim_tick()`, replacing the `register_unit.call_deferred()` above, and
  `NavAgentRegistry.register_unit()` gets a gate: a node outside
  `"sim_units"` is refused with a `0`, exactly the way the
  `navigation_is_suspended()` check beside it already refuses a unit whose
  transform a transport anchor owns. The gate lives in the registry rather
  than in the facade because the facade's `register_unit()` is the registry
  method's only caller, so both placements cover the same population, and
  because that is where refusals of this class already live. What it buys is
  that `command_move()`, `command_dock()`, `assign_attack_arcs()` and
  `resume_unit()` all call `register_unit()` unconditionally and obey the
  rule without knowing it exists -- "navigation never drives a unit the tick
  does not simulate" as a structural fact rather than four call sites
  remembering.

  The pending list's order is load-bearing, and this is the one place C6b's
  reasoning about queue order does *not* carry over. `SimAdmissionQueue`'s
  own order is unobservable because its only effect is `add_to_group()`, a
  set. This list's is not: `NavAgentRegistry.register_unit()` hands out `id`
  from `_next_agent_id` in call order, and `command_move()` sorts the units
  of one order by their `navigation_agent_id` meta -- so the order agents are
  created in reaches the simulation. Taking the drain's order from
  `get_nodes_in_group("sim_units")` instead would have put Godot's group
  iteration order, the known and still-open phase 4 gap, straight into that
  sort.

  An entry the tick has not admitted stays queued for the next drain rather
  than being dropped, and that is required rather than defensive. A building
  placed by a command is created during the command loop, step 2 of
  `Match._advance_simulation_tick()`, while navigation's drain runs from step
  3 -- so at that drain it is in `"buildings"` but not yet in
  `"sim_buildings"`, because the admission queue admits it at the start of
  the *next* tick. Discarding it there would leave its cells open until the
  periodic `BLOCKER_REFRESH_SECONDS` sweep came round: 0.5 s, or twelve ticks
  at `MatchClock`'s 25 Hz, against the one tick waiting costs. The only
  entries that can linger indefinitely are nodes that join
  `"units"`/`"buildings"` by hand and are never admitted at all, which today
  exist only in tests.

  The first thing the sweep turned up is that the branch this rule was
  written for had never once run. `_on_tree_node_added()`'s building half
  tested `node.is_in_group("buildings")`, and `"buildings"` -- unlike
  `"units"`, which 99 `.tscn` files declare statically -- is joined by
  `Building._ready()`'s own `add_to_group()` call. `node_added` fires while
  `_enter_tree()` propagates, before any `_ready()` in the subtree, so a real
  building is in *no* group at that instant. Measured against a live match: a
  freshly instanced `ATRocketTurret` reports `buildings=false`,
  `sim_buildings=false` at `node_added`, and `true` for `"buildings"` the
  moment `add_child()` returns. The branch's intent -- refresh blockers when a
  building appears -- was only ever satisfied by the periodic sweep. This is
  the same argument that keeps the unit half off `"sim_units"`, applied one
  group further: the test now asks for the footprint property
  `NavBlockerTracker.refresh_building_blockers()` itself reads, which is
  present from instantiation and keeps the module duck-typed the way the rest
  of navigation deliberately is. It is not a determinism fix -- the periodic
  sweep counts down in tick domain and was already frame-independent -- it is
  a latency fix that makes the building half of the pending list mean
  anything at all.

  The second is that deferring the join breaks navigation's initial
  population, and no test would have said so. `UnitNavigationSystem.setup()`
  runs from `Match._ready()`, after every node of a freshly instanced match
  scene has already entered the tree and therefore after `_on_tree_node_added()`
  could ever have seen them -- so for an authored match its group walk *is*
  the starting units. It walked `"sim_units"`, which C6c leaves empty at that
  moment. Measured on `tests/fixtures/match_fixture.tscn`: the navigation
  system held 0 agents for its whole life against 3 before C6c, and no later
  frame recovered them -- the starting units simply stopped participating in
  avoidance until something commanded them. The walk now reads `"units"` and
  branches: a unit the tick has already admitted registers immediately (every
  suite that builds a navigation system with no `Match` in the tree, where
  `request_sim_entry()` joins the group at once), and one that has not is
  queued for the first drain. That leaves a one-tick delay before a match's
  starting units are navigable, which the gate makes unavoidable rather than
  chosen: `setup()` could not register them early even if it wanted to,
  because they are not yet in `"sim_units"`. Three `demo_boot_run.gd` cases
  and `entity_id_run.gd`'s group-mirror case now drive one explicit
  `_advance_simulation_tick()` for that reason, rather than an awaited frame
  -- an awaited frame advances the clock by however much wall time it
  happened to take and is not guaranteed to produce a tick at all.

  The third is a claim this document made that is no longer true as written.
  C6a's sentence was that `"units"` and `"sim_units"` are identical *at every
  instant*; C6c narrows it, deliberately and by exactly one drain, to
  identical once the tick has run. Between an entity's creation and the next
  `apply_pending_entries()` the two memberships differ by that entity -- which
  is the entire point of C6b and C6c, and is what
  `tests/match/admission_run.gd` asserts directly. `entity_id_run.gd`'s
  mirror case now states the narrower claim rather than the old one.

  Two smaller things the test sweep found, both worth naming because the
  first contradicts what the slice was expected to cost. The gate's price was
  supposed to be one line in `tests/navigation/run.gd`'s `FakeUnit._init()`,
  covering all 84 registration sites at once, and it mostly was. But
  `tests/units/harvester_run.gd`'s `TestHarvester` overrides `Unit._ready()`
  with `pass` -- it skips the authored visual tree that suite does not build
  -- so it never joined any group at all, and the immediate-join fallback the
  gate was expected to rely on never ran for it. It joins `"sim_units"`
  explicitly now. And putting every `FakeUnit` in `"sim_units"` made one
  navigation case visible to another: `can_place_transport_cargo()` scans
  that group across the whole tree with no ownership filter, and
  `_test_disconnected_island_orders()` parks a unit at exactly the
  destination the transport-drop case probes, `queue_free()`d but not yet
  freed. That case now waits a frame for the frees to land.

  **Slice B4, decided 2026-08-26: the view interpolates, and the store it
  interpolates from turned out to be measuring the wrong thing.** The
  justification is the one recorded at the top of this section rather than the
  obvious one: interpolation is not repairing steppiness phase 3 introduced,
  because ground locomotion was never on frame `delta`. It is here because
  phase 5 delivers ticks irregularly — the turn scheduler, adaptive input delay
  and stall policy all mean a client can go several frames with no tick and
  then catch up — and because the view now needs a read path across the
  sim/view boundary at all.

  **Only the visual subtree moves; `global_position` is not touched.** It stays
  the exact tick-authoritative mirror C2 made it. That is not caution: C2
  recorded a debt of roughly 260 `global_position` *read* sites that still ask
  the node rather than the store, and simulation code is among them, so a
  blended `global_position` would feed a frame-rate-dependent number straight
  into the tick — precisely the divergence lockstep exists to prevent. Paying
  that debt is its own slice, and B4 is deliberately built so that it does not
  wait for it and does not add to it. What moves instead is `visual_root`, by
  an offset written from `Unit._process()` beside `restore_combat_turret_poses()`,
  which was already there making the same argument for a turret angle.

  The blend is between `previous_position(id)` and `position(id)`, never past
  the latter, so the model renders up to one tick — 40 ms — behind the
  simulation. That is the cheaper of the two errors available. Extrapolating
  forward removes the lag but overshoots whenever a unit stops, turns or dies,
  and then snaps back; at 25 Hz the snap is visible and the lag is not. It also
  costs nothing anyone can act on: selection, orders and hit resolution all
  read `global_position`, which is exactly on the tick.

  **The selection halo was not re-parented under `visual_root`, and the request
  to do so rested on an incomplete description of how it already works.**
  `SelectionHalo._process()` re-derives its position every frame as
  `_entity.to_local(_position_anchor.to_global(Vector3.ZERO))`, where
  `_position_anchor` is the authored `#^^0` attachment *inside* the model —
  which is to say inside `visual_root`. Wherever that anchor exists the
  interpolation offset reaches the halo for free, with no change at all.
  Re-parenting would also have been actively wrong twice over: `visual_root`
  carries the slope-alignment tilt, which would tip a ground decal off the
  ground, and the halo's own `rotation.y = -_entity.rotation.y` horizontality
  rule is written against `Unit` being its parent. What did need handling is
  the fallback, and it is not hypothetical: **9 of this project's 99 unit
  scenes** use a model whose source XBF carries no `#^^0` at all — the two
  worms, the storm unit, the Death Hand, and the five story/hero characters —
  and those halos hold a fixed local position that would not have followed. The
  offset is pushed to them explicitly, and the anchored path is left untouched.

  **`visual_root`'s authored rest position is captured once in `_ready()`, and
  that is required rather than tidy.** `Unit._set_transport_anchor_offset()`
  computes `unit_local_offset - visual_root.position` and treats what it reads
  as the authored offset of the model inside the unit. The moment
  `visual_root.position` becomes a per-frame interpolation value that
  arithmetic silently picks up whatever the current frame happened to hold, and
  a docked passenger's anchor drifts by up to one tick of the carrier's travel.
  The capture mirrors `UnitTerrainAlignment._visual_root_rest_basis`, which
  takes the rest *basis* once for the same reason. Every shipped unit scene
  authors `(0, 0, 0)` there today — all 99 checked — so the value changes
  nothing; what changes is that the arithmetic stops reading a moving target.

  A relocation is snapped rather than blended, above
  `Unit.MAX_INTERPOLATION_DISTANCE` = 4.0 world units. The threshold is set
  against the data: the fastest unit in `assets/converted/rules.db` has speed
  40.0, which is 1.6 world units per 25 Hz tick, and flight transitions move at
  the same `navigation_move_speed()` plus a vertical component of the same
  order. Getting it wrong in the tight direction costs one tick of smoothing on
  whatever it excludes — that unit renders exactly as it did before B4 — while
  getting it wrong in the loose direction slides a model across the map over
  40 ms after a transport drop or a factory exit, so the margin sits where it
  does deliberately.

  Projectiles are in scope and keep their own previous position, because they
  have no entity id at all: `_register_entity_id()` exists only on `Unit` and
  `Building`, so `SimEntityState` holds nothing for them. `CombatProjectile`
  records `global_position` at the top of `sim_tick()`, before the trajectory
  advance, and interpolates the `"Visual"` child both branches of
  `_create_visual()` build. Nothing blends before the first `sim_tick()` has
  run, which matters because C6b's admission queue means a shot does not travel
  on the tick that fired it and `launch()` moves the node from wherever it was
  constructed to the muzzle in between. A hitscan bullet builds no `"Visual"`
  at all and never reaches `State.FLYING`, so it is untouched, and
  `MissileTrail.sample()` keeps reading the authoritative `global_position`.

  **What the sweep found, and it is the reason this slice is bigger than it
  looks: `previous_position()` was not returning the previous tick.** B4 is the
  first code ever to read it, and the first thing it measured was that a moving
  ScoutA had a blend span of 0.005 world units while covering 0.24 per tick,
  with the X axis — where all of the movement was — identical between the two
  values. The cause is stated as an assumption in `entity_state.gd`'s own doc
  comment, where C1 wrote that shifting current into previous inside
  `set_position()` "assumes exactly one write per entity per tick, which matches
  how every per-entity system already joins the tick". It does not match, and
  did not when it was written: every managed ground unit is written twice per
  tick from one call stack — `Unit.navigation_step()` writes the horizontal
  step and then `_snap_to_terrain()` reaches
  `UnitTerrainAlignment.snap_body_to_terrain()`, which writes the vertical
  correction. `previous_position()` therefore held a mid-tick intermediate, and
  an interpolating view would have smoothed the terrain snap and nothing else.

  The fix moves the shift to where "previous tick" is actually defined:
  `SimEntityState.begin_tick()`, called once by
  `Match._advance_simulation_tick()` immediately after the clock advances and
  before any system can write. The first write for an id in a tick shifts; every
  later one does not. It is O(1), not a copy of the position array — a per-id
  `PackedInt32Array` records which tick sequence number last shifted that id and
  `begin_tick()` increments the counter it is compared against — which matters
  because that array grows with every id ever allocated, so a per-tick
  `duplicate()` would be up to 2.3 MB copied 25 times a second late in a long
  match. The alternative, making every writer write exactly once, is a real
  option and a larger one: it means folding the terrain snap into
  `navigation_step()`'s own arithmetic across every path that reaches it, which
  is locomotion's shape rather than the store's, and it would still leave the
  store trusting a convention no test can see. Two cases in
  `tests/sim/entity_state_run.gd` now state the corrected contract, one of them
  driving exactly the two-writes-in-one-tick shape that was broken.

  The ordering B4 depends on was measured rather than assumed. A view reading
  the interpolation fraction must read it after `Match._process()` has advanced
  the accumulator for that frame, and Godot is documented to process ancestors
  before descendants — but that is a claim about the engine, not about this
  scene tree. Instrumenting both callbacks and printing the fraction on either
  side of `pending_ticks()` showed, on every frame sampled: Match enters at the
  previous frame's remainder, `pending_ticks()` leaves 0.528333, and all three
  fixture units then read 0.528333 — including on the frame where a tick came
  due, where Match entered at 0.943833 and every unit read the post-tick
  0.360333. The pull direction is therefore sound and no push from `Match` was
  needed.

  **One exposure this slice widens rather than creates, recorded because
  slice B1's inventory clears it and should not.** That inventory lists the
  visual slope tilt under "stays on frame `delta`, and should", on the grounds
  that "none of these are readable by a command or a checksum". That is not
  true of `visual_root`, and was not true before B4: `CombatTurret.bind_model()`
  is handed `_owner.visual_root` and collects its muzzles from inside it, so
  `emission_points()` reads `muzzle.global_transform` — a world position derived
  from a subtree whose orientation is already advanced on frame `delta`, and
  which is a simulation input, since it becomes a projectile's
  `_launch_position`. B4 adds a translation term to that existing rotation term.
  The magnitude is bounded by one tick of the shooter's travel — 1.6 world
  units for the fastest unit in the rules — and how much of that bound a tick
  actually sees depends entirely on how frames and ticks happen to interleave.
  **Corrected by slice B5**, which measured the same subtree from the other
  side. B4 recorded "median 0.0, maximum 0.0044 world units" for a ScoutA at 6
  units per second and reasoned that the frame immediately before a tick
  boundary has the largest fraction and therefore the smallest offset. B5's
  probe on a moving NIABTank, sampling inside `sim_tick_combat()`, found median
  0.083 and maximum 0.164 — the whole of that unit's per-tick travel. Neither
  number is wrong about its own run and neither is a client measurement:
  headless pacing is not 60 fps pacing, and the fraction distribution is
  whatever the run happened to produce. The durable statement is the bound and
  the dependence, not either figure. It is not fixed here because the fix is not B4's
  shape: either the muzzle read subtracts the offset, or the model's
  presentation transform stops being the thing the simulation measures from.
  Whichever slice claims it should also correct B1's inventory line.

  **Slice B5, decided 2026-08-27: a firing decision stops being measured from
  an interpolated node.** Found while sweeping the combat group for R6, and
  taken first because it is a defect rather than a migration.
  `CombatTurret._range_origin()` decides whether a target is in rules range,
  and therefore whether a shot happens at all. It read
  `_model_root.global_position`, and for a unit `_model_root` is `visual_root`
  — the node B4 offsets every frame. The function's own comment has always said
  the opposite of what it did: "Rules ranges belong to the gameplay entity, not
  to an animated muzzle." Until B4 that was true anyway, because `visual_root`
  sat at the unit's origin and only its basis was animated; B4 made the comment
  false without touching the file.

  `Unit` now answers `combat_range_origin()` with its store position and the
  turret asks for it, resolving the entity by walking up from the model root at
  `bind_model()` time rather than taking it as a parameter — that call has
  nineteen sites in `tests/combat` binding bare models with no entity above
  them, and an ancestor walk cannot be forgotten the way a second bind call
  could.

  **`Building` deliberately does not answer, and the asymmetry is the whole
  scope decision.** A building does not move and nothing interpolates its
  model, so it has no frame dependence to fix — but its state root sits at an
  authored offset from the building origin, measured at 0.583 world units on
  `HKGunTurret`. Making the entity authoritative there would have shifted every
  building turret's effective range by that much, which is a balance change
  this slice has no business making. The first attempt did exactly that, and
  the measurement is the only reason it did not ship: the code read correctly
  and the suites stayed green.

  The muzzle half of the same finding stays open, and its entry above is now
  corrected rather than merely inherited. It is a harder question than this
  one: a range origin has an obvious right answer in the entity, while a launch
  position genuinely belongs at the muzzle, so fixing it means deciding what a
  muzzle position *is* in the simulation rather than moving a read.

  **Slice R1, decided 2026-08-26: buildings get a store-backed position, and
  the read debt becomes a scheduled program instead of a paragraph.** C2's debt
  above says the honest thing — reads "come back honestly only when a later
  slice moves readers onto the store, which is a real slice someone has to
  schedule". This is that schedule. R1 gives buildings the write path units got
  in C2. R2 adds a `simulation_position()` accessor on the node and a checker
  rule forbidding `global_position` *reads* in simulation code, with its exempt
  list as the work queue, the same ratchet
  `global-position-bypasses-store` and `animation-completes-simulation` already
  use. R3 and whatever follows it empty that list one subsystem at a time. The
  debt is real and current: measured on the tree R1 started from,
  `global_position` appears 266 times across 55 files, and the
  `global-position-bypasses-store` pattern matches 33 of those lines — 29
  whole-vector writes plus four component writes on the RTS camera. C2's own
  count of "260 times, 49 of them writes" was taken before its migration
  landed, so the write half has since shrunk by a third while the read half
  has not moved at all, which is the shape of the debt R2 and R3 exist to
  clear.

  R1 itself is small, which is the point of splitting it out. `Building` gains
  `set_simulation_position()`, the same shape and the same store-then-mirror
  order as `Unit`'s: `SimEntityState.set_position()` first, `global_position`
  second. Buildings already carried an entity id from C3 and already had
  health, shields and owner in the store; position was the one field missing,
  and it was missing only because C2 scoped itself to units. There were exactly
  two direct writes to a building's `global_position` in `scripts/` —
  `Match._place_on_map()`'s snap-to-ground loop and
  `BuildingPlacement.try_place_at_hover_cell()` — and both now route through
  the method, so `scripts/match/match.gd` leaves the rule's exempt list
  entirely and `scripts/buildings/building_placement.gd` stays on it for its
  preview meshes alone. `scripts/buildings/building.gd` joins the list as the
  sanctioned chokepoint, exactly as `scripts/units/unit.gd` is on it.

  Both write sites run after `add_child()`, so `_ready()` and therefore
  `_register_entity_id()` have already run and the id is nonzero — the same
  argument `match.gd` already spells out for the unit loop directly below the
  building loop. `BuildingPlacement`'s other branch, for a node that is not in
  the tree, keeps writing local `position`: outside the tree a node has never
  reached `_ready()`, so it has no id to write a store entry under, and
  `Node3D.global_position` is not even readable there, which is why that branch
  exists at all.

  A building is written once, at placement, and then does not move, so
  `previous_position()` equals `position()` for its whole life and no
  previous-tick concern was added. The sweep looked for a moving building —
  walls, upgrades, refinery docks, the sale and refund paths, survivors — and
  found none: every other position write near a building moves a *child* marker
  in local space (the rally-point line, the repair effect, the wall and
  footprint previews), never the building itself.

  **Projectiles and linger effects deliberately do not get entity ids, in this
  program or any later part of it, and this is a decision rather than a
  backlog entry.** C2's exempt-list comment used to call it "real, scheduled
  work"; that wording was wrong and is now corrected in
  `tools/architecture_rules.toml`. `SimEntityRegistry` allocates ids
  sequentially from 1 and never reuses one — that is a promise, tested by
  `_test_freed_entity_releases_and_never_reissues_its_id` — and every
  `SimEntityState` array is indexed directly by id, so the arrays grow with
  every id ever allocated rather than with the live count. That trade was
  costed for units and buildings and it is cheap there: the store now holds 44
  bytes per id across its ten arrays, and a long match allocates on the order
  of a hundred thousand of them. Projectiles break the arithmetic that makes it
  cheap, not by a little: a match produces tens of thousands of them, each
  alive for a fraction of a second, so an id-indexed store would spend those 44
  bytes forever on entities that existed for a few ticks. An id-indexed array is simply the wrong shape for a
  high-churn, short-lived entity. Nothing is lost in the meantime, because a
  projectile's position is already written only from the simulation tick —
  `sim_tick()`, plus the `launch()` the tick's own fire committal calls
  synchronously — so it is deterministic today without a store entry. What a snapshot does with them is
  phase 5's design question, and it is a different question: it wants a
  compact serialization of a transient population, not a permanent slot per
  shot.

  **What the sweep turned up that was on nobody's list:
  `MatchSnapshot._restore_entities()` restores position by writing
  `entity.global_transform`, for units as well as buildings, and the store
  never learns about it.** It is not a rule violation because the rule's
  pattern matches `global_position`, and `global_transform` is a different
  spelling of the same write — which is exactly why it survived C2's
  migration unnoticed. The consequence is concrete: after a snapshot load, a
  restored entity's node is at the saved position while `SimEntityState` has
  no position for it at all until something writes one, so
  `has_position()` answers false for a live entity and the registration-time
  push added in C4 does not help, because it pushes owner only. It is left
  unfixed here on purpose — R1 is the building write path and a snapshot
  restore is not it — but it belongs to whichever slice next touches
  `MatchSnapshot`, and R2's read rule should widen its pattern to cover
  `global_transform` rather than repeat this.

  **Slice R2, decided 2026-08-26: the read accessor, the rule that makes the
  read debt a queue, and one subsystem moved to prove the accessor works.**
  `Unit.simulation_position()` and `Building.simulation_position()` return the
  store's position for this entity's id, and a new `all`-zone rule,
  `global-position-read-bypasses-store`, forbids reading `global_position` or
  `global_transform` off another entity's node. The rule's exempt list is the
  work queue R3 and its successors empty, which is the same object serving as
  the enforcement — the ratchet `global-position-bypasses-store` and
  `animation-completes-simulation` already are.

  The rule matches **qualified** reads only — `X.global_position`, one system
  asking where another entity is — and that is a measurement rather than a
  concession. Re-measured on the tree R2 started from — 270 `global_position`
  occurrences over 262 lines in 55 files, not the 266 R1's paragraph above
  records, because R1 measured the tree it *started* from and its own migration
  has landed since — the reads split into at least 195 qualified occurrences across 49
  files and 47 bare ones in only 7 (`unit.gd`, `building.gd`, `rts_camera.gd`,
  and four combat effect files). Qualified `global_transform` reads add 24 more
  across 15 files.

  Those counts are worth stating with the command that produced them, because
  three separate numbers in this program's own paragraphs disagreed before this
  one was pinned down: the totals here are
  `grep -ro '\bglobal_position\b' --include='*.gd' scripts/ | wc -l` for
  occurrences and `grep -rn` piped the same way for lines, both including
  matches inside comments. "At least 195 qualified" is a floor rather than a
  count: the sweep matched `X.global_position` with a word-shaped receiver, so a
  read through a parenthesised expression — `(candidate as Node3D).global_position`,
  which the harvester migration below turned up — is invisible to it. The rule
  itself does not share that blind spot, which is why the queue is sized by the
  rule's own matches at the bottom of this paragraph rather than by the sweep.

  A bare read is a node reading its own mirror, and that node is
  the one
  thing already guaranteed to have written the store it is mirroring, so the
  question it raises is both different and much smaller than "who told this
  system where that unit is". Sorting 195 qualified reads into a queue is worth
  the rule; chasing 47 self-reads would make the rule noise before it made
  anything correct. After the harvester migration below, the rule matches 190
  lines in 52 files, every one of them exempted, which is the size of the queue
  R3 inherits. The same measurement decided where the accessor lives: the
  qualified reads cluster in collaborator modules that are cleanly simulation or
  cleanly view — `unit.gd` itself has exactly one and `building.gd` has none —
  so the migration is per-module, not a rewrite of the two big entity files.

  A reader calls `simulation_position()` **on the node** rather than holding the
  store and an id. That is deliberate and it costs something: the accessor is a
  second way to reach state that a reader could already reach directly, which is
  usually how a facade rots. It buys two things worth more. Navigation's modules
  take a `Node3D` and never a `Unit` — duck typing that predates this program and
  that keeps the navigation suites able to drive a bare `Node3D` — so handing
  them a store and an id would mean giving them an entity model they were
  written not to need. And "call this method instead" is checkable by a regex
  where "hold the store" is not, which is what turns the remaining debt into a
  list that shrinks visibly instead of a paragraph that ages.

  **The accessor's fallback to `global_position` is required, and it is also the
  one dangerous thing in this slice.** It is required twice over: `entity_id`
  stays 0 for the whole life of an entity built with no `Match` in the tree,
  which is most of `tests/units/*` and `tests/combat/*`, and even inside a real
  match there is a window between `_ready()` and the first
  `set_simulation_position()` where the id exists and the store has no entry
  yet — wider for a building, which is written once at placement, than for a
  unit. It is dangerous because a silent fallback answers from the node, which is
  precisely the behaviour this program is removing: a bug that loses the store
  entry degrades into "reads the mirror" rather than failing. What makes it
  acceptable is that the store is authoritative only inside a match — outside one
  there is nothing for it to be authoritative over — and both fallback conditions
  are exactly "no store, or no entry yet". The alternative, returning the store's
  `Vector3.INF` no-value marker, would push an unusable number into a footprint
  or a dock offset in the one window where the node's value is the only value
  anyone has. The tests pin the distinction rather than the agreement:
  `tests/match/entity_state_run.gd` pokes `global_position` behind the accessor's
  back and asserts it still answers the store's value *and* that the two
  genuinely differ, because an accessor that simply returned `global_position`
  passes every test that only checks the two agree.

  **The write rule was blind to `global_transform`, and that blindness was
  hiding a defect.** `global-position-bypasses-store` said `global_position`
  only, so a whole-transform write — the same write under a second spelling —
  was invisible to it. R2 widens the pattern, which was not speculative:
  `MatchSnapshot._restore_entities()` restores a unit's or a building's position
  by writing `entity.global_transform` after `add_child()`, and the store never
  learns about it. `_register_entity_id()` pushes owner only, so after a
  snapshot load `has_position()` answers false for a live entity, `position()`
  push_errors, and the node is at the saved place while the store believes it has
  no place at all. That is a defect in C2's own scope that survived C2's
  migration because of the spelling, and it is on the write rule's exempt list
  labelled as one — the way `animation-completes-simulation` labels
  `UnitLocomotion` "proven defective" — not fixed here, because a snapshot
  restore is not R2's scope. Its read-side mirror image, `_capture_entity()`
  saving `entity.global_transform` instead of the store's position, is on the
  read rule's queued list. (Slice R2b below took the restore side and settled
  the read side the other way; both entries now say so.) Widening the pattern cost
  eight further exemptions, all of them view nodes that were never entities: a
  ground decal, a laser beam, a corpse, two debug overlays, a unit's authored
  collision shape and the map's sun.

  **The exempt list is sorted into two labelled groups, because a list that
  mixes them stops being a queue.** Permanent — 19 files, 33 reads — is code that
  should keep asking the node forever, for one of three reasons: the reader is
  view code (camera, FX, positional audio, UI halo, debug overlay, death
  sequence, a wall's mesh-variant choice), or the thing being read deliberately
  has no store entry (projectiles, linger effects and spice mounds never get
  entity ids, which R1 settled), or the read is of a rotation, which
  `SimEntityState` does not hold at all. Queued — 33 files, 157 reads — is
  simulation code R3 and after will migrate, grouped by subsystem with counts so
  the list doubles as the plan: navigation 103 across 12 files, combat 19 across
  6, buildings 11 across 5, units 16 across 5, match and world 8 across 5.
  Navigation is two thirds of the remaining debt and is the only group that
  needs splitting again before it can be a slice. The exemptions are per file,
  which is coarser than those reasons: three simulation files
  (`authored_fire_controller.gd`, `unit_deploy_state.gd`,
  `unit_movement_sounds.gd`) are on the permanent list because their only
  qualified read is an audio emitter placement, and their entry buys silence for
  a future simulation read too. That is the same imprecision the write rule
  already accepts for `unit.gd` and `building.gd`, for the same reason: a
  file-level rule cannot tell a sanctioned read from a future accidental one.

  **One subsystem was migrated in this slice rather than left to R3, and the
  reason is a specific mistake this project has already paid for.**
  `SimEntityState.previous_position()` was added in C1, sat unused until B4 read
  it, and was found to have been wrong the whole time — with a passing test the
  entire way, because nothing consumed it. An accessor with no caller is the same
  shape of claim. `HarvesterController` was the migration: seven lines, all
  simulation, covered by `tests/units/harvester_run.gd`, and now gone from the
  queued list, because an emptying list is the progress report. Two of those
  seven turned out not to be `_unit.global_position` as recorded but reads of
  *another* entity — `(candidate as Node3D).global_position` in the nearest-owned-
  refinery search and `main_base.global_position` in the return-to-base fallback.
  They are simulation reads of a `Building` and were migrated with the rest, but
  they cost something the six self-reads did not: the suite's `FakeRefinery` and
  `FakeMainBase` doubles extend `Node3D` and had to grow a `simulation_position()`
  of their own. That is the honest price of an accessor reached by duck typing,
  and it is worth stating because R3's navigation work will pay it at a much
  larger scale — every navigation fixture that drives a bare `Node3D` becomes a
  double that has to implement this method.

  **Slice R2b, decided 2026-08-27: the snapshot restore, and a defect that
  turned out to be one-sided.** R2 recorded `MatchSnapshot` as broken on both
  sides. It is not. `_capture_entity()` reads `entity.global_transform`, and
  inside a match that transform's translation *is* the store's own mirror, so
  the value it saves is correct — the read violates the rule without producing a
  wrong answer. Only the restore was a defect, and only in one line: the
  `global_transform` assignment restores rotation, which nothing else can (the
  store holds a position and nothing more), and then stopped, leaving
  `has_position()` false for a live entity. The fix pushes the landed position
  straight back through `set_simulation_position()`. The write rule's exemption
  stays, because the rotation assignment itself is still a direct write and
  still necessary; what changed is that it is labelled sanctioned rather than
  defective.

  The read side is deliberately *not* migrated, and that is a decision rather
  than a deferral. F7/Shift+F7 snapshots are a throwaway debug convenience whose
  files are expected to be lost, and a real save/load system supersedes the
  whole file later, so a migrated read there buys nothing that outlives it. Its
  entry moved from the read rule's queued group to the permanent one with that
  reason attached, which is what keeps the queue meaning "work someone will do".

  Two things worth keeping from how this was found. The test could not live in
  `tests/match/snapshot_run.gd`, whose fixture is a bare `Node3D` with no
  `Match` in it: `MatchLookup` finds nothing there, `entity_id` stays 0 and the
  store is never involved, so the defect is invisible in the suite that owns the
  feature — which is exactly why it survived C2. It lives in
  `tests/match/entity_state_run.gd` instead, driven inside a real match, with
  the restored node's own transform as the control, since that lands correctly
  with the defect present as well as absent. And the defect's whole lifetime was
  spent under a rule that could not see it: `global-position-bypasses-store`
  said `global_position` while the line said `global_transform`. A rule is only
  as wide as its spelling, and the cost of finding that out was two slices.

  **Slice R3, decided 2026-08-27: the ground-navigation group, and a fixture
  that can finally disagree with itself.** Three files —
  `ground_slot_allocator.gd` (23 reads), `ground_navigation.gd` (20) and
  `steering_stabilizer.gd` (10) — now ask `simulation_position()` instead of
  the node. All 53 moved and none stayed: the sweep looked for the two things
  that would have kept an entry on the list, a read that only feeds the view
  and a read of something that never had a store entry, and found neither. Every
  one of these reads is a slot assignment, a destination, a swept-disc check or
  a steering decision taken inside the tick, so every one of them owes the store
  an answer. The three files are gone from the read rule's queued group, which
  leaves it at 29 files and 103 reads; navigation, which was two thirds of the
  debt at 12 files and 103 reads, is now 9 files and 50 and is no longer one
  indivisible lump — `unit_flight_controller.gd` (21) and
  `unit_navigation_system.gd` (14) are each a slice of their own.

  The duck typing survived intact and that was the point of the accessor living
  on the node. Nothing in these three files learned what a `Unit` is: every unit
  still comes out of `agent["unit"]` annotated `Node3D`, there is no `is Unit`
  check and no preload of `unit.gd` anywhere in them, and the call is resolved
  at runtime exactly as `has_method("navigation_step")` already was. What that
  costs is spelled out in the diff rather than hidden: `simulation_position()`
  is not a field read, it resolves the owning `Match` by walking the node's
  ancestors (`MatchLookup._live_match`) on every call, and these loops run for
  every agent every tick. Where a function read the same unit's position several
  times it now reads it once into a local and reuses that, which is only safe
  because nothing between the reads moves the unit — stated at each hoist,
  because the one place where it is *not* true, `tick()`'s achieved-velocity
  calculation, has to read again after `navigation_step` has landed the unit and
  says so.

  **The hard part of this slice was that no existing suite could have caught a
  mistake in it, and that is structural rather than an oversight.** Inside a
  match the store and the node hold the same number, so `unit.global_position`
  and `unit.simulation_position()` return the same value and every assertion in
  `demo_boot_run.gd` or `harvester_run.gd` passes with either read. R2's
  harvester migration ran into exactly this and measured 103 assertions before
  and 103 after. `tests/navigation/run.gd` is worse still: it has no `Match` in
  the tree at all, so a `simulation_position()` added to its `FakeUnit` would
  just return `global_position` and agree with itself forever. Fifty-three reads
  inside the tick protected by nothing but a regex is not good enough, so the
  fake was given the ability to disagree: `FakeUnit._simulation_position` holds
  a store-side position that `simulation_position()` returns, defaulting to
  `Vector3.INF` meaning "no separate store value, answer from the node" — which
  is both what a real `Unit` outside a match does and what leaves all 388
  pre-existing assertions untouched. Three cases then set the two apart and
  assert the store wins: a unit parked exactly on its destination whose store
  still has it six metres short must keep driving rather than report arrival
  (`ground_navigation.gd`), two units whose nodes are swapped across the travel
  axis must get the route lanes their stored positions earn
  (`ground_slot_allocator.gd`), and a chassis whose node sits on its steering
  target while the store keeps it ten metres away must drive the arc instead of
  stopping to turn in place (`steering_stabilizer.gd`).

  What makes that fake honest rather than convenient is the second half of it:
  `FakeUnit.navigation_step()` re-syncs the stored position to the node after
  it moves, because `Unit.navigation_step()` ends in `set_simulation_position()`
  and therefore closes any divergence on the very next step. A double that could
  hold a disagreement open for a hundred ticks would be modelling a state the
  simulation cannot reach, and assertions built on it would be proving something
  about the fixture. The three cases are all single, direct calls into the
  module under test for the same reason. Their honesty was checked by mutation
  rather than assumed: making `FakeUnit.simulation_position()` return
  `global_position` unconditionally fails exactly those three cases and nothing
  else, 7 assertions of 398, which is what tells them apart from cases that
  merely assert the two agree.

  **The mutation worth recording is the one that failed to fail.** Making the
  *real* `Unit.simulation_position()` answer from the node instead of the store
  breaks two assertions in the whole repository, both of them in R2's own
  deliberate poke case in `tests/match/entity_state_run.gd`; the navigation
  suite still reports 398 passing assertions and `demo_boot_run.gd` still
  reports 364. That is not a gap to be closed by adding integration coverage —
  it is the same fact that made this slice hard, seen from the other side. Inside
  a match the mirror is correct, so no integration test can distinguish a reader
  that asks the store from one that asks the node, and the binding has to live
  where a disagreement can be manufactured: at the double, and at that one poke
  case. Every future slice off this queue inherits that and should expect to pay
  the same price.

  Three things the sweep turned up that were not on anyone's list. First, the
  queue's own arithmetic was wrong: the rule matched 191 lines across 52 files
  at the commit R3 started from, not the 190 R2's paragraph above records, and
  both group headers still carried pre-R2b figures — permanent was 20 files and
  35 reads rather than the 19 and 33 it claimed, queued 32 and 156 rather than
  33 and 157, because R2b moved `match_snapshot.gd`'s two reads across without
  updating either total. All four numbers are corrected in the rule, measured
  with the rule's own pattern. Second, `nav_spatial_hash.gd`'s single remaining
  read is not independent of the ones R3 just moved: it keys the neighbour
  buckets by node position while `ground_navigation.tick()` now queries those
  buckets with a store position, and the two must agree. Inside a match they do,
  so nothing is broken, but the pair should migrate together rather than the
  hash being left for last. Third, the duck-typing bill R2's paragraph predicted
  came due immediately and in a place no one would have looked: two `Node3D`
  doubles that drive the real navigation system had to grow the accessor —
  `tests/match/admission_run.gd`'s `UnregisteredProbeUnit`, whose suite kept
  passing while printing a "Nonexistent function" error every tick, and
  `tests/navigation/jitter_probe.gd`'s `ProbeUnit`, which is not in the suite
  list at all and would simply have been found broken later, exactly as slice
  C6c's group gate found it.
  **Slice R4, decided 2026-08-27: navigation's system-and-shared group, and the
  first reads this program has deliberately decided to leave alone.** Six modules
  — `shared/nav_agent_registry.gd` (3 reads), `shared/nav_blocker_tracker.gd`
  (2), `ground/orca_avoidance.gd` (2), `ground/ground_path_follower.gd` (2),
  `ground/attack_arc_allocator.gd` (2) and `shared/nav_spatial_hash.gd` (1) —
  now ask `simulation_position()` instead of the node, and so do 12 of
  `unit_navigation_system.gd`'s 14: the transport drop probe's occupancy scan,
  the destination seeds in `stop()` and `set_hold_position()`, all three
  `_route_agent()` starts (`command_move`, `command_depart`, `command_dock`),
  `destination_reached()`'s arrival measurement, both reads in
  `_firing_anchor_blockers()`, the parking-claim ordering inside `sim_tick()`,
  and `_ground_target_is_reachable()`'s component test. Twenty-four of the
  group's twenty-six reads moved, through nineteen accessor calls: where a
  function read the same unit twice with nothing between the reads to move it,
  R3's hoist is repeated and said out loud at the site, and
  `assign_arcs()` now caches one position per unit for its two loops instead of
  reading each unit twice.

  **The two reads that stayed are what the sweep was for, not an exception to
  it.** R3 found 53 of 53 reads were simulation, and this slice checked rather
  than inherited that ratio; both survivors sit in
  `UnitNavigationSystem._refresh_navigation_debug()`,
  which builds the line strip `UnitNavigationDebug` draws for a selected unit and
  produces nothing else. Nothing there is read back by a tick, and both numbers —
  a height offset and the route's first point — are measured against the very
  node the overlay is drawn on top of, so asking the store would buy nothing and
  would make the overlay describe a body it is not drawing. That is reason 1 of
  the three the read rule's permanent group already lists. It has a real price,
  and hiding it would be worse than paying it: the rule exempts by file, so
  moving `unit_navigation_system.gd` across to the permanent group instead of
  deleting it means the checker no longer guards this file at all. Reverting any
  one of the twelve migrated reads there leaves `check_architecture.py` green —
  measured, not assumed, by doing exactly that — while the same revert in each of
  the other six files is rejected. Those twelve are held by
  `tests/navigation/store_reads_run.gd` alone. The alternative was to migrate the
  two debug reads as well so the file could leave the exempt list, and that was
  rejected on the merits rather than on effort: the overlay is the one thing in
  this file that has a legitimate reason to be refreshed on frame time one day,
  and a store read there is precisely the "view lags the mirror it is drawing"
  failure the permanent group exists to name.

  **`nav_spatial_hash.gd` had to travel with this group rather than after it.**
  Its single read keys the neighbour buckets, and `GroundNavigation.tick()` —
  migrated by R3 — has queried those buckets with a store position ever since.
  Keying from the node while looking up from the store files an agent in one
  bucket and searches for it in another the moment the two disagree. Inside a
  match they never disagree, so nothing was broken at any point; leaving the hash
  for a later slice would have parked a genuine inconsistency in the tree between
  the two, which is a different thing from leaving work undone.

  **`register_unit()`'s seeds read the store, and that is where the accessor's
  fallback stops being a tolerated wart and becomes the mechanism.** The three
  fields seeded from a unit's position at registration — `destination`,
  `steering_target` and `claim_center` — are all simulation state the tick reads
  back afterwards: arrival is measured against `destination` every tick and the
  parking claim search centres on `claim_center`, so a mirror value entering
  here is inherited by every store-side read downstream of it. The awkward fact
  is that a unit genuinely can register before anything has written its position
  to `SimEntityState`: `Unit._register_entity_id()` pushes `owner_player_id` and
  not position, so `has_position()` answers false until that unit's first
  `set_simulation_position()`. `simulation_position()` answers from the node in
  exactly that window, which is what makes reading the store here safe rather
  than merely harmless — the seeds get the store's value when there is one and
  the node's when there is not, and seeding from the node directly would be
  indistinguishable today and wrong the moment registration follows a store
  write, which is already the ordinary case for anything built after match start.

  **The accessor's cost, measured rather than asserted.** `simulation_position()`
  is not a field read: it resolves the owning `Match` through
  `MatchLookup._live_match`, which walks the node's ancestors testing
  `is_in_group` and `has_method` at each level and then `call()`s the match, on
  every invocation. Instrumenting it with a counter, booting
  `tests/fixtures/match_fixture.tscn` and driving 100 simulation ticks gives
  2800 calls, 28.0 per tick across the fixture's 3 navigation agents — 9.3 per
  agent per tick — with every unit idle, and 4796 calls, 48.0 per tick and 16.0
  per agent per tick, with the whole roster under one move order. That counter
  is on `Unit.simulation_position()` itself and so covers every caller, but
  every caller is navigation or `harvester_controller.gd` today, which is what
  the migration has moved so far. What that does *not* imply is that anything
  needs redesigning: the fixture is small, the numbers are per tick rather than
  per frame, and no profile in this program has yet shown `_live_match` on a hot
  path. What it does imply is a shape — the cost is proportional to agents times
  reads-per-agent, and the two navigation files still on the queue
  (`unit_flight_controller.gd` at 21 reads and `air_navigation.gd` at 3) will add
  to the same product. The
  point of measuring now is that the next slice inherits a number instead of a
  worry, and a decision about caching the match reference belongs in whatever
  slice can show the number matters.

  **What the sweep turned up that was on nobody's list.** One test double broke
  and was fixed here: `tests/units/advanced_carryall_run.gd`'s `FakeCarrier`, a
  bare `Node3D` handed straight to the real navigation system, has no
  `simulation_position()` and `destination_reached()` now calls it — the suite
  failed one assertion and printed two "Nonexistent function" errors, which is
  one better than R3's two doubles managed, both of which kept passing while
  printing the same error every tick. The wider grep for unit stand-ins found no
  others: the `sim_units` members in `tests/combat/*` and
  `tests/units/deployment_run.gd` never reach a navigation system, and R3 had
  already fixed the two that do. The read rule's arithmetic reproduced exactly
  this time — 138 lines across 49 files at the commit R4 started from, both group
  headers correct — which is the first slice in this program where it has, and
  worth recording only because the previous three did not.

  The queue is now 22 files and 77 reads, down from 29 and 103. Navigation is 2
  files and 24 reads, down from 12 files and 103 when R3 started, and everything
  left of it is flight. The binding went into a new suite,
  `tests/navigation/store_reads_run.gd` (570 lines, 50 assertions in 13 cases),
  rather than into `tests/navigation/run.gd`: that file is 3028 lines and already
  one of the two standing `max-file-lines` offenders, and R3's argument that a
  separate suite would duplicate ~60 lines of scaffolding for no net reduction
  inverts at this volume. The new suite reuses `run.gd`'s own `FakeUnit` through
  a preload rather than defining a second one, and that is load-bearing rather
  than tidy: the mutation that proves these cases are real — making
  `FakeUnit.simulation_position()` ignore the override and answer from the node —
  has to fail all of them, and a second copy of the double would have left half
  of them passing. It fails 25 assertions across all 13 cases, and R3's own three
  cases in `run.gd` at the same time, 7 of 398. The other mutation is the one
  that still fails to fail: making the real `Unit.simulation_position()` answer
  from the node breaks the same two assertions in
  `tests/match/entity_state_run.gd` R3 recorded and nothing else — 65 of the 66
  suites still pass, `tests/navigation/run.gd` still reports 398,
  `store_reads_run.gd` still reports 50, `demo_boot_run.gd` still 364. Inside a match the mirror is
  correct, so no integration test can tell a store reader from a node reader, and
  every slice off this queue will keep paying for its binding at a manufactured
  disagreement instead.

  **Slice R5, decided 2026-08-27: the flight group, and the first binding this
  program has been able to put on the real path.** Two files —
  `unit_flight_controller.gd` (21 reads) and `air/air_navigation.gd` (3) — now
  ask `simulation_position()` instead of the node. All 24 moved and none stayed:
  the sweep looked for the two things that keep a read on the permanent list, a
  read that only feeds the view and a read of something with no store entry, and
  found neither. Every one of them is an altitude the next line writes back
  through `set_simulation_position()`, a bearing an aircraft flies on for a whole
  tick, an arrival verdict that completes an order, or a terrain probe whose
  answer becomes the altitude. Deleting the two entries empties the navigation
  subgroup of the read rule's queued group entirely, which was 12 files and 103
  reads when R3 started: R3 took ground steering, R4 the system-and-shared group,
  R5 flight. The queue is 20 files and 53 reads, down from 22 and 77, and what is
  left of it is combat, buildings and a scattering of unit and match code.

  Four of the controller's functions read the same unit twice with nothing
  between the reads that moves it, so R3's hoist is repeated and said out loud at
  each site: 21 reads became 17 accessor calls. Two functions deliberately do
  *not* hoist and say why — `_advance_vertical_transition()` and
  `_advance_pickup_landing()` both call `Unit.flight_advance_transition_motion()`
  first, which moves the unit horizontally through `set_simulation_position()`, so
  their read has to be taken after it rather than at the top of the function.
  `advance_circles_flight()` keeps its two reads separate for a weaker reason
  that is worth being honest about: only `turn_toward()` sits between them and it
  only rotates, so a hoist would be correct today and would be asserting that
  forever, which the second accessor call is cheap enough not to be worth.

  **One line deserves calling out because a reader skimming will misread it.**
  `_advance_hangar_exit()` ends in
  `_unit.set_simulation_position(_unit.global_position + exit_offset / distance * step)`
  — the *read* inside that argument is a read like any other and became
  `simulation_position()`, while the write around it stays what it was. They are
  not the same call and the write half was never in question. Integrating from
  the node while writing the store would have copied the mirror into the store
  one step per tick, which is the failure this whole migration exists to remove,
  and it would have looked completely correct.

  **Three of the reads are `.y` only, and whether the store's `y` is *right*
  rather than merely equal is a different question from the rest.** They are the
  cruise altitude `configure()` starts from, the altitude a pickup descent lerps
  down from, and the altitude the post-pickup climb lerps up from. The worry
  worth having is that an aircraft's rendered height might not be its simulated
  one, which would make the node's `y` the correct read at some of these sites.
  It is not: `UnitTerrainAlignment.snap_body_to_terrain()` — the only thing that
  writes a flying unit's `y` outside the controller — routes through
  `set_simulation_position()` like everything else, and B4's interpolation offsets
  `visual_root`, a child node, never the body. So the node's `y` is a mirror of
  the store's `y` at every instant, all three feed lerp endpoints that are written
  straight back into the store, and there is no rendered height anywhere in this
  file for a read to have meant.

  **This is the first group whose binding could go on the real path, and it
  did.** R3 and R4 both reported the same fact from the other side: making the
  real `Unit.simulation_position()` answer from the node broke two assertions in
  the whole repository, both in R2's own poke case in
  `tests/match/entity_state_run.gd`, and nothing on a navigation path. Their
  bindings had to live at a double because the modules they migrated are
  duck-typed on a `Node3D` and their suites have no `Match` in the tree at all.
  `UnitFlightController` is not like that: `Unit` constructs it, holds it, and
  drives it, so the disagreement can be manufactured on the real object.
  `tests/units/flight_store_reads_run.gd` boots the real match fixture, adds a
  real ATADVCarryall and a real Carryall under it, waits for each to earn an
  entity id and a store position from the tick, and then splits the two apart the
  only way a real unit can be split — `store.set_position(id, …)` behind the
  node's back, the identical bypass the poke cases perform — before driving one
  real flight step and asserting the controller followed the store. Fifteen cases,
  78 assertions, no double anywhere in the file. **Mutation 3 moves for the first
  time in this program: making the real accessor answer from the node now breaks
  41 assertions across two suites — 39 of the new suite's 77 in all fifteen
  cases, plus the same 2 in `entity_state_run.gd` R3 and R4 recorded — where for
  those two slices it broke 2 and nothing else.**

  What made that suite possible is also what bounds it, and the bound is the
  interesting part. A real unit's store/node disagreement survives exactly until
  its next simulation tick, because `Unit.navigation_step()` and
  `snap_body_to_terrain()` both end in `set_simulation_position()` written from
  the node's own `global_position` — a bare self-read, deliberately outside the
  read rule's scope, and the thing that makes the mirror true. So every case runs
  synchronously against one fixture with no `await` between the poke and the
  step: the measurement is taken inside the window the simulation actually leaves
  open, rather than by pretending the window is wider. The same fact costs one
  read its binding. `air_navigation.tick()`'s
  `agent["destination"] = unit.simulation_position()`, which runs when a Circles
  order completes, sits immediately after `navigation_step()` has closed the
  divergence, so no manufactured disagreement can survive to reach it. A double
  that held the split open across its own step would be modelling a state the
  simulation cannot reach — the same reason `FakeUnit.navigation_step()` re-syncs
  — so that read is held by the architecture rule alone, and saying so is worth
  more than a case that would pass either way. A second read is unobservable for
  an unrelated reason: `_circles_steering_target()`'s idle branch returns
  `simulation_position() + facing_direction()`, and its only consumer subtracts
  the position again, so the two reads cancel unless exactly one of them is
  reverted — which is precisely what the rule catches.

  `air_navigation.gd`'s other two reads are bound at the established double,
  in `tests/navigation/store_reads_run.gd` (now 15 cases, 58 assertions, 678
  lines) rather than in a suite of their own, because that module is duck-typed
  on `FakeUnit` exactly as the ground modules are and `FakeLandedFlyer` already
  inherits the override. Its neighbour-search read is the air twin of the pairing
  R4 had to make for `nav_spatial_hash.gd`: `NavSpatialHash.build()` has keyed
  those buckets from `simulation_position()` since R4, so looking them up from
  the node would file an agent in one bucket and search for it in another the
  moment the two disagreed. Inside a match they never do, so nothing was broken;
  the case proves the lookup follows the store by putting the neighbour 141 m
  from the mover's node and half a metre from its stored position and asserting
  that lateral separation still deflects the step.

  **What the sweep turned up.** One test double broke, and loudly this time:
  `tests/units/flight_run.gd`'s `FakeFlyingUnit`, a bare `Node3D` handed straight
  to `AirNavigation.desired_velocity()` and `.tick()`, has no
  `simulation_position()` — removing the one this slice added costs that suite 2
  failed assertions and 2 "Nonexistent function" errors, which is the same
  outcome R4's `FakeCarrier` had and better than R3's two doubles, both of which
  kept passing while printing the error every tick. The wider grep over `tests/`
  found no others: `jitter_probe.gd`'s `ProbeUnit` is not a flyer and already
  answers, and nothing else reaches an air agent. The read rule's arithmetic did
  *not* reproduce this time, and in the half nobody had looked at: the permanent
  group's header still claimed 21 files and 37 reads, which was R4's own correct
  count and went stale the same day, because R4a pulled `unit_navigation_system.gd`
  back out of that group in favour of two line-scoped hatches without lowering the
  total it had just been added to. The queued half was exact. Both headers are
  corrected and the arithmetic now closes: the rule matches 90 lines across 41
  files, 20 permanent, 20 queued, and `unit_navigation_system.gd` alone with its
  two hatches, `allow_budget` unchanged at 2 — this slice needed none.


  **Slice R6, decided 2026-08-28: the combat group, most of which turned out
  not to be a migration at all.** Ten reads across four files moved onto
  `simulation_position()` — target acquisition's distance and hull-aim origins,
  the attack order's turn/pursue/fire offsets, the unit's and the building's
  aim vectors. Two more files left the queue in the other direction, and that
  is the substance of the slice rather than a footnote. `combat_turret.gd`'s
  eight reads are muzzle and pivot transforms, the launch-smoke marker, the
  model root, a projectile — which by R1's decision has no entity id at all —
  and one dead fallback. `combat_target.gd`'s single read is that fallback's
  twin. Both fallbacks reach a `Node3D`'s position only when the object offers
  neither `combat_aim_position_from()` nor `combat_aim_position()`, and every
  `Unit` and `Building` offers both, so for a real entity the line never runs.
  Neither file was migrated because neither has anything to migrate *to*.

  **The two `combat_aim_position()` accessors were migrated although the rule
  cannot see them**, and that is the point of including them. An entity reading
  its own `global_position` is a bare read, which R2 deliberately excluded from
  the rule on the argument that a node reading its own mirror is a smaller
  question than a system reading someone else's. That argument does not survive
  a *public accessor whose answer other entities consume*: this is the point
  every shot in the game is aimed at, laundered through a method the rule is
  blind to. `Building`'s returned `global_position` and now returns
  `simulation_position()`; `Unit`'s built its answer from `to_global(...)` and
  now composes the store position with the same authored centre.

  Both migrations are unguarded, and that is worth stating rather than
  discovering: reverting `Building.combat_aim_position()` to `global_position`
  leaves the checker silent, because a bare self-read is exactly what the rule
  declines to match. The four ordinary migrations in this slice are each caught
  — verified one file at a time — but these two rest on review alone. Widening
  the rule to bare reads was measured and rejected at R2, 47 sites in 7 files
  against 195 qualified ones, and nothing here changes that arithmetic. What
  changes is knowing the exclusion has a shape, and that public accessors are
  it.

  **What R6 tried to fix and could not, with the measurement that stopped it.**
  `Unit.combat_aim_position()` takes `_selection_bounds().get_center()`, the
  model's authored centre expressed in the unit's own frame — a constant, in
  principle. On a moving NIABTank it varied by 0.284 world units across 92
  ticks, and slice B5 had just fixed the same class of leak on the shooter's
  side. The obvious cause was B4's interpolation offset, which
  `_selection_bounds()` picks up because it measures the model relative to the
  unit. Subtracting that offset made the spread *worse*, so the components were
  measured separately: raw centre 0.210, centre with the offset removed 0.136,
  the offset itself 0.170, and the terrain tilt 0.00136 radians — negligible.
  Most of what is left is the model's own animation. Tracks and turret idle
  move the meshes the bounds are taken from, and the function's original
  comment says that is the intent: "the converted selection volume follows the
  visible body". **The aim point has been animation-driven since long before B4
  added a term to it.** Making it deterministic means deciding what an aim
  point *is* in the simulation rather than moving a read, which is the same
  question the muzzle finding above asks and belongs with it in phase 4. The
  attempt is recorded rather than the fix, because the code read perfectly
  sensibly and only the number said otherwise.

  After R6 the read rule matches 80 lines in 37 files: 22 permanent files
  holding 44 reads, and a queue of 14 files holding 34 — units 16, buildings
  11, match and world 7. Navigation and combat are both gone from it.

  **Slice R7, decided 2026-08-28: the tail, and the end of the program.** Thirty
  reads across fourteen files — a building's footprint centre and rally point
  and refinery docks and survivor origin, the push-aside displacement, the
  carryall ability's nearest-candidate search and the transport's approach and
  docking checks, the deployment and roster spawn points, the terrain snap, the
  spice hazard's victim list, the command executor's target resolution and
  `Match._place_on_map()`'s two seeding reads. None of them is interesting on
  its own, which is what a tail is; three deserve a note.

  `CommandExecutor` resolves a target that may be any `Node3D` a command names,
  so it asks `simulation_position()` only when the node answers and keeps the
  node otherwise — the fallback carries a hatch, because a marker or an effect
  has no store entry to prefer. `Match._place_on_map()`'s two reads are the
  sites R2's own paragraph singled out as the only ones that *depend* on the
  accessor's fallback rather than merely tolerating it: they run before the
  first store write of the match, and now they say so. And
  `unit_terrain_alignment.gd` migrated four of its five, the fifth being a
  basis read, which the store has nothing to answer with.

  **The queued group is empty, and the rule's header now says a new entry there
  is a regression rather than a plan.** The program ran R1 through R7 and took
  the queue from 33 files and 157 reads to none: harvester, ground steering,
  navigation's system-and-shared group, flight, combat, tail. What is left is
  the permanent half — 22 files whose reads are of view code, of rotations, or
  of things that deliberately have no entity id — plus seven `# arch-allow:`
  hatches, up from two. The five new ones are the honest residue: an authored
  exit marker, a building's inverse transform, the `Node3D` fallback above, a
  rotation, and a spice mound. Each sits on a line that has no store entry to
  read instead, and each carries its reason inline where the next reader will
  meet it rather than in a list they would have to find.

  **The migration also caught a suite lying to the store, which is the first
  time reading the store has exposed a divergence rather than merely being
  tidier.** `unit_terrain_alignment.gd`'s snap reads the position, corrects its
  `y` against the terrain and writes the result back. Moving that read onto the
  store broke eleven assertions in `demo_boot_run.gd`, and bisecting to the
  single line and then instrumenting it gave the reason: **39.1 world units of
  divergence on OrdosAPC**, and 5.0 on two other frames. The suite sets up its
  combat scenarios by assigning `global_position` directly, so the node moved
  and the store did not; the snap then read the store and put the unit back
  where the store still believed it was. `tests/` is deliberately outside the
  checker's zone, so nothing had ever objected. The suite now moves entities
  through `set_simulation_position()`, the way production does. Reading the node
  had been hiding this for as long as the writes existed.

  **Five test doubles needed the accessor across the program, and the count is
  the point.** R3 fixed two, R4 one, R6 one, R7 five more — `FakeCargo`,
  `FakeAbilityCarrier` and three separate `FakeBuilding` classes. Every one of
  them printed `Nonexistent function` on every tick while its suite kept
  passing, which is why the verification for these slices counts that string
  separately from failures. A green run does not mean a quiet one.

  **Tracks D and E, decided 2026-08-28: what phase 3 still owes, and the
  defect that joins the two halves.** The reader migration closed `R`, and two
  items from this phase's own opening paragraph are still owed — production
  that belongs to a player rather than to whoever is local, and headless
  execution faster than real time. They are sliced below as tracks `D` and
  `E`. They share their first slice, and the reason is a measured defect
  rather than a tidy factoring.

  **Availability is a frame-time cache that the simulation tick reads, and it
  is computed for the local player only.** Both halves show on one path each.
  `BuildingController._process_building_order()` runs from `advance_tick()`
  and asks `_is_building_available()` whether the order it is advancing is
  still legal (`scripts/buildings/building_controller.gd:1072`); that function
  returns `_catalog_view.is_available()`, a dictionary lookup
  (`scripts/buildings/building_catalog_view.gd:79`); and the dictionary is
  filled by `_refresh_availability_if_dirty()`, which the controller calls
  from `process(delta)`. `UnitRosterController` has the same shape on the
  execution side: `execute_unit_order_command()` reaches
  `_on_unit_slot_left_pressed()`, which reads `_unit_availability`, filled
  from its own `process(delta)`.

  So a verdict the simulation depends on is refreshed on engine frames and
  consumed on ticks. This is a structural finding, not a reproduced bug:
  frames and ticks are interleaved today, the availability tracker only
  dirties on real events, and the queue's own progress signal drives a refresh
  on most ticks anyway, so the staleness window is at most a frame and nothing
  has been observed to go wrong. It becomes two different failures the moment
  either track lands. Under lockstep a `SimBuildOrderCommand` carrying
  `player_id: 2` is validated against the technology the *local* player owns,
  which is divergence by construction. Under a frameless headless loop
  `process()` never runs at all, and the cache answers with whatever the last
  frame left. One cause, two symptoms, so it is slice `D1` and both tracks
  stand on it.

  **The queue, measured, with the method beside it.** `_local_player()`,
  `local_player_id`, `_local_player_id()` and `_local_player_resource` appear
  at **47 non-comment sites** across the three production controllers: 31 in
  `building_controller.gd`, 9 in `building_upgrade_controller.gd`, 7 in
  `unit_roster_controller.gd`. A plain `grep | wc -l` says 48 — the extra
  match is inside a doc comment, which is why the number here comes from a
  script that attributes every site to its enclosing `func` rather than from a
  line count. Classified by that attribution, where a site counts as
  simulation if it is reachable from `advance_tick()` or from an `execute_*`
  method, **17 of the 47 are simulation**: six in `building_controller.gd`
  (`_process_building_order`, `_process_repairs`, `_cancel_building_order`,
  `execute_place_building_command`, `execute_sell_building_command`,
  `_refresh_availability_if_dirty`), six in `building_upgrade_controller.gd`
  (`_process_upgrade_order`, `_cancel_upgrade_order`,
  `_complete_global_upgrade`, `_refund_and_fail`, `_is_upgrade_available`,
  `_refinery_for_dock_upgrade`), five in `unit_roster_controller.gd`
  (`_process_unit_orders`, `_spawn_completed_unit`,
  `_refresh_availability_if_dirty`, `_remove_queued_units`,
  `_production_building_id`). The remaining 30 are input handling, resource
  binding and sidebar rendering, which stay local by design and go into the
  rule's permanent group. `_refresh_availability_if_dirty` is counted as
  simulation in both controllers on purpose: it is a view-side call the tick
  reads out of, which is exactly `D1`.

  Four forks were decided before any of it was written.

  **Enforcement is a rule with a queue, the way `R` was.** A new `all`-zone
  rule, `local-player-in-simulation`, forbids the local-player lookups on
  simulation paths, with the 17 sites above as its queued exempt group and the
  30 input-and-view sites as its permanent one. The alternative was slices and
  tests alone, which is one slice cheaper and leaves "is the track closed" a
  judgement rather than a measurement — the same trade the read rule already
  settled once.

  **Reshaped 2026-08-28, before `D2` was written: the queue above cannot be
  expressed, and a rule that cannot express its queue is worse than no rule.**
  `Rule.exempt` is a tuple of path patterns and `Rule.applies_to()` decides per
  *file* (`tools/check_architecture.py:144`); the line-by-line scan only runs on
  files that decision let through. The read rule survived that limit because its
  permanent files and its queued files were mostly different files. Here they
  are the same three: every one of `building_controller.gd`,
  `building_upgrade_controller.gd` and `unit_roster_controller.gd` holds both
  simulation sites that must move and input-and-sidebar sites that are local by
  design and always will be. Exempting those paths would switch the rule off
  over exactly the code it exists to watch, and the track would end with three
  permanently-exempt files and a green checker proving nothing.

  So the rule gets a zone instead of an exempt list. The per-player simulation
  modules go in a directory of their own, `scripts/production/`, and
  `local-player-in-simulation` covers that directory with **no `exempt` entries
  at all** — a new file there is watched the day it is written, which is the
  code most likely to get this wrong, and there is no list for anyone to keep
  correct. The 17 sites stay the measurement of what has to move; they are the
  slice inventory rather than a manifest entry. What replaces "the queue is
  empty" as the track's closing condition is that the controllers retain no
  simulation path at all — which is `D5`'s product, and is checkable by the same
  attribution script that produced the 17.

  **Availability for a non-local player is recomputed at execution, not cached
  per player.** The local player keeps its cache, because the sidebar renders
  from it every frame and the `TechnologyTree` scan behind it was the single
  largest cost in the frame before it was cached. Every other player's
  availability is recomputed at the moment their order executes. That is not a
  shortcut, it is phase 2's own rule: a verdict is recomputed on the execution
  tick against the world as it stands then, precisely because it can be wrong
  by the time it runs. Caching availability for every player would pay an
  N-times scan to keep answers nobody renders.

  **Reversed 2026-08-28, before `D2` was written, because `D1` removed the
  premise.** The cost argument above was about a scan running *every frame*;
  `D1` moved the refresh onto the tick behind the availability tracker's dirty
  flag, so it now runs when buildings are actually added, lost, captured,
  completed or upgraded — not on a cadence at all. An N-player scan on those
  events is not the cost the paragraph above was avoiding. The second reason is
  correctness and it was missed the first time round:
  `BuildingController._process_building_order()` re-checks availability on
  **every tick**, not only at order start, so that an order whose prerequisite
  is lost gets cancelled. "Recomputed at execution" gives a non-local player no
  such check, which would make an order behave differently depending on whose
  it is — the exact class of difference lockstep cannot have. So every player
  gets a cache, all of them refreshed by `D1`'s tick phase, and only the local
  player's is rendered.

  **Production state lives in a new `ProductionSystem`, not on `PlayerData`.**
  The roster already holds a `PlayerData` per player with its own credits,
  energy and upgrades, so hanging the queues there is one lookup instead of
  two. It is the wrong home anyway: `PlayerData` is a `Resource` that the UI
  reads and that a save system will one day serialize, while a production
  queue is state that advances on a tick and therefore needs an owner Match
  ticks in a fixed order beside the other controllers. `ProductionSystem` is
  that owner; `PlayerData` stays about resources.

  **The six animation-completed transitions come into phase 3 as `E3`.** They
  were carried into phase 4 deliberately (see that phase's entry below), and
  `E` takes them back for a mechanical reason: a loop that runs ticks without
  frames never fires `AnimationPlayer`'s `animation_finished`, so a unit that
  finishes deploying on that signal never finishes at all. Leaving them would
  make the headless harness able to run only the paths that avoid them, which
  is not the harness phase 4 was promised. Doing them here also gives the work
  a real reader — a headless match that completes — instead of six severings
  verified in isolation.

  The slices, in order:

  - **`D1`** — availability answers on the tick, not on the frame. One refresh
    phase in `Match._advance_simulation_tick()`, placed immediately after
    `_admission_queue.apply_pending_entries()` and before the command drain,
    replacing the two controllers' `process(delta)` refreshes. The position is
    the point and was corrected twice under review before any of it was
    written: putting it at the top of each controller's `advance_tick()` would
    have missed the command-execution readers entirely, because
    `_advance_simulation_tick()` drains and executes commands *before* it
    reaches the controllers; and putting it at each `execute_*` entry point
    instead would have made a verdict depend on command order within one tick,
    letting a building created by an earlier command count while the
    simulation had not admitted it — against C6c's own rule. After admission
    and before the drain, every reader in the tick sees one settled snapshot.
    No per-player work; the sidebar's update can shift by up to one tick,
    which is the only behaviour this slice changes.

    What `D1` does **not** deliver, measured rather than assumed: a
    *newly added* building still needs an engine frame before it affects
    availability at all. `Building` joins `"buildings"` in `_ready()`, while
    `SceneTree.node_added` fires during `_enter_tree()`, so
    `BuildingAvailabilityTracker._on_node_added()` defers its `_track()` — and
    `_track()` is the only place that marks the cache dirty and connects the
    building's own change signals. Removals and changes to already-tracked
    buildings dirty synchronously, so those are frame-independent after `D1`;
    additions are not. That deferral is `E2a`'s, not `D1`'s.
  - **`D2`** — `ProductionSystem`, the rule, and the build queue made
    per-player in one move. A `PlayerProduction` per player keyed by player id,
    ticked by Match in the fixed order the sibling controllers already run in;
    `local-player-in-simulation` over the new `scripts/production/` directory;
    and `execute_build_order_command()` selecting the queue by `command.player_id`
    rather than taking the only one there is. **Merged from what were two
    slices, and the merge is the point.** Introducing the container with the
    local player as its sole inhabitant would have created a per-player map
    with one entry and no second reader for a whole slice, which is the shape
    that makes state look tested when it is not. The slice is done when a test
    drives player 2 end to end — order, tick to completion, place — and asserts
    player 1's credits were untouched. It is R2's proven shape: the mechanism,
    the rule that queues the debt, and one real migration to prove the
    mechanism works.

    It also has to separate placement's verdict from placement's preview, and
    that requirement was found by review rather than by design. `execute_place_building_command()`
    runs through the controller's single `BuildingPlacement`, whose `begin()`
    opens with `_clear()` (`building_placement.gd:129`) and which owns the
    active building id, anchor cell, preview cells and arrow. Today that is
    harmless because the method is only ever reached for the local player.
    The moment `D2` lets a `player_id: 2` command reach it, that command wipes
    an unfinished local preview, clears the local committed-click guard and
    publishes player 2's status in player 1's sidebar. **That defect would be
    created by `D2` rather than merely left by it**, which is the line between
    absorbing work and deferring it — `D2a` is deferred because the wall path
    is already wrong today, and this is absorbed because it would not be. So
    execution places through a view-less path for every player, local included,
    and the preview stays what it always was: local UI, dismissed by the
    controller on its own player's outcome.
  - **`D2a`** — wall chains follow `player_id` too. `SimWallLineCommand` is a
    third command path over the same build queue, and `D2` leaves it selecting
    whichever player the receiving client considers local:
    `execute_wall_line_command()` forwards only the cells and the building id
    (`building_controller.gd:1377`) while `_submit_wall_line_command()` stamps
    `player_id` that nothing then reads. Under lockstep the same wall command
    would spend player 1's credits on one client and player 2's on another.
    It is a slice of its own because the fix is a module split rather than a
    parameter: `WallLineSession` is 378 lines with 68 touches of its queue and
    chain, and the seam runs through the middle of it — `begin`, `click`,
    `process_preview`, `lock_markers` and `clear_markers` are the local
    two-click picker, while `start_chain`, `advance_chain`,
    `place_ready_segment`, `refund_order` and `cancel_chain` are simulation
    that has to exist per player, including the single `_chain` field that
    cannot represent two players building at once. `D2` recorded the debt in a
    comment at the method itself rather than only here, the way the phase-5
    ownership comment it deletes did; **landed 2026-08-29**, and both comments
    are gone with it. Reconnaissance widened the slice once: the preview was
    mutated by every *cell evaluation*, not only by placement, because
    `_evaluate_cell_availability()` bracketed its verdict in
    `_placement.begin()` / `.cancel()` — so a remote wall line wiped a local
    preview without placing anything at all.

    Worth noting for what it says about the rule: `D2`'s
    `local-player-in-simulation` cannot catch this. The rule watches
    `scripts/production/`, and this defect lives in `building_controller.gd` —
    a zone rule protects the code that has moved, not the code that has not.
  - **`D3`** — unit production per player, in a `UnitProductionSystem` that is
    a `Node` rather than a `RefCounted`: unit spawning is world-facing, and a
    node in the Match tree reaches `get_tree()`, the `sim_buildings` and
    `sim_units` groups and the units parent directly instead of through the
    provider callables `ProductionSystem` already carries five of. Queues key on
    player *and* production building; a completed unit emerges from that
    player's primary building and the population cap counts that player's units.
    Availability became a per-player cache in the roster, mirroring what `D2`
    did to `BuildingCatalogView`, because the verdict is read on the command
    execution path. **Landed 2026-08-29.**

    Two findings the slice turned up, both about readers rather than writers.
    First, moving `_process_unit_orders()` out of the controller would have
    frozen the sidebar's progress bar: the coupling `if _process_unit_orders():
    _refresh_unit_option_states()` was its only per-tick refresh, and *nothing*
    in `tests/` observes `unit_option_state_changed`. `D3` replaced it with an
    explicit `unit_queue_progressed(player_id)` signal. Second, and worth
    recording against `D2`: the building path lost the same coupling then and
    did not break, because paying for an order moves `PlayerData.money`, which
    emits `resources_changed`, which `BuildingController` turns back into an
    option-state refresh. That side channel is undeclared, untested, and silent
    for a `cost <= 0` order. It is named in a comment at
    `ProductionSystem.advance_tick()` and is `D6`'s to remove.

    Also worth recording: the running local-player inventory stops being
    comparable here. `_local_player()` in the roster became `_sidebar_player()`,
    which is honest — every one of its five callers is view code — but the
    tracking regex no longer sees it, so `48` is not `54` minus six.
  - **`D4`** — upgrades per player, in a `UpgradeProductionSystem` `Node`
    alongside `D3`'s. Queue, credits, the granted purchase and the buildings it
    is applied to all take the command's player. `UpgradeOrder.target_refinery`
    stopped being a `Node` held across ticks and became an `EntityNodeIndex`
    id. **Landed 2026-08-29.**

    Three things this slice settled that the one-line plan above did not
    anticipate. First, five helpers were neither simulation nor view — a
    catalog lookup, a display name and build-time arithmetic — and had readers
    on both sides of the split; they went to a shared `UpgradeRules` rather
    than to either owner. Second, `UpgradeOrder.display_name` already holds
    `"ATConYard upgrade"` and five sites format it again, so the shipping text
    reads "ATConYard upgrade upgrade paused"; `D4` preserved it verbatim rather
    than mixing a text fix into a move and turning the string audit from "must
    match" into a list of intended differences. Third, the per-tick progress
    reader came up for the third time in the track and was carried across
    explicitly, as `D3` did for units.

    Availability did **not** move, and that is the split's whole point: unlike
    the unit path, the upgrade execution verdict is computed live rather than
    read from a cache, so threading the player through it is enough for
    lockstep while the cache stays local view state.
  - **`D4a`** — **abandoned 2026-08-29, before any of it landed.** The plan was
    to gate `BuildingUpgradeController`'s per-frame availability poll on a
    `BuildingAvailabilityTracker` dirty flag, and to make refinery dock state
    observable so the gate could not go stale on it. Reviewing and then
    prototyping it turned up two failure modes the gate itself introduces, and
    together they cost more than the gate saves.

    First, the freshness signal and the verdict read **different groups, one
    tick apart**. `Building._ready()` joins `"buildings"` immediately, while
    entry into `sim_buildings` goes through the admission queue and lands on the
    next simulation tick — the reasoning is written out at `building.gd:279-291`.
    The tracker watches `"buildings"`; `D4` made the upgrade verdict read
    `sim_buildings`. A frame poll that consumes the dirty flag inside that
    window never retries, so a newly placed building's upgrade slot never
    appears. The unconditional poll hides this by trying again every frame.

    Second, `tests/match/demo_boot_run.gd:1836` calls `PlayerData.grant_upgrade()`
    directly and requires the purchased slot to vanish. That transition emits
    nothing — not a building signal, not a production event. It is a test
    shortcut rather than a shipping path (`grant_upgrade()` has exactly one
    caller in `scripts/`, `upgrade_production_system.gd:208`), but the gate
    turns it from harmless into a stale sidebar.

    Against that: the poll is ~10-15 upgrade ids per house against the base's
    buildings each frame, with a field compare inside — roughly an order of
    magnitude lighter than the technology-tree scan `D1` removed, and never
    measured as a problem. The estimate was mine, and `make godot-perf`, which
    the tracker's own comment cites, measured the unit grid rather than this
    one.

    Without the gate the dock signal has no reader, so the slice collapses
    rather than shrinks. `D6` revisits this area with the per-player option-state
    design in hand and can decide then; the group mismatch above is the fact it
    will need.
  - **`D5`** — repairs and sales per player, the last live divergence in the
    track. `D2`'s report listed repairs, sales, unit production and upgrades as
    deferred; `D3` and `D4` took the last two and these were never assigned a
    slice. Measured 2026-08-29: `_process_repairs()` charges `_local_player()`
    **every tick**, so each client repairs a different player's buildings;
    `execute_sell_building_command()` and `execute_repair_building_command()`
    refuse a non-local player outright through `_is_local_player_building()`;
    and `CommandExecutor._execute_sell_building()` / `_execute_repair_building()`
    resolve the entity and drop `command.player_id` on the floor, which is why
    the controller entry points have no player parameter at all.
    `BuildingSaleService` is additionally a single match-wide state machine, so
    one player selling blocks every other. Ordered ahead of option state because
    this diverges the tick and option state cannot.
  - **`D6`** — option state becomes per-player data rendered for the local
    player only, closing the three local id lists `Match` fills from
    `_local_player_*` (`match.gd:186-190`) and the two debts recorded earlier
    against this work while it still carried the id `D5`: the building progress
    bar's wallet coupling, and the doubled "upgrade upgrade" text in five
    messages.
  - **`E1`** — a tick-driver seam. Match takes a driver rather than owning
    `FrameTickDriver`; a burst driver returns a fixed budget with no wall
    clock and no `MAX_TICKS_PER_FRAME` clamp to apply. This seam is already
    wanted and already improvised: **70 direct calls to
    `_advance_simulation_tick()` across 11 test files** exist because an
    awaited frame "only advances the clock by however much wall time it
    happened to take and is not guaranteed to produce a tick at all"
    (`tests/match/demo_boot_run.gd:131`). `MatchClock`'s own class comment
    already names the second driver phase 5 will bring, so the seam is owed
    twice over.
  - **`E2a`** — the frameless sweep. Nine `call_deferred` / `set_deferred`
    sites in `scripts/` each hold work that only runs at end of engine frame,
    which in a loop that runs ticks without frames is never.
    `BuildingAvailabilityTracker`'s deferred `_track()` is the one `D1` turned
    up and left; the slice's job is to find what the other eight do to a
    frameless run and give each one a tick-time answer or a documented reason
    it does not need one. It sits before `E2` because `E2`'s test is what
    proves the sweep worked, and a slice whose product is a fix wants its
    reader waiting for it rather than the other way round.
  - **`E2`** — a state hash on `SimEntityState`, and the test that makes the
    track falsifiable: N ticks with no frames must hash identically to N ticks
    interleaved with frames. This is the acceptance test for `E` and phase 4's
    replay-hash primitive in embryo, which is why it comes before the runner
    rather than after it.
  - **`E3`** — sever the six `animation_finished` completions the way `B3d`
    severed flight's: read the clip's authored length once, complete on a tick
    deadline. The rule's exempt list is the file list, and it shrinks to zero.
  - **`E4`** — the headless entry point: boot a match with no view, feed a
    recorded command log, run to the end of it, exit. Production code is
    almost ready for it — `await` appears at exactly 2 sites in all of
    `scripts/`, both in `match.gd`.
  - **`E5`** — measure it and record the number. Ticks per second headless
    against the 25 a second real time gives, on the same machine, with the
    command beside it. Until that number exists, "faster than real time" is a
    claim rather than a result, and phase 4's cost is still unknown.

- **Phase 4 — determinism gate.** Portable math, RNG split, the static rules
  above wired into `check_architecture.py`, and the CI test that replays one
  command log twice in-process and then compares state hashes across native and
  web builds.

  **Carried in from phase 3, then taken back by it: simulation state that
  completes on an animation signal.** `AnimationPlayer`'s
  `animation_finished` fires on engine frame time, so anything that completes on
  it takes however many simulation ticks the machine's frame rate happened to
  allow. Slice B3d removed one instance of this from `UnitFlightController` and
  proved the severing directly; the rest were found by its sweep and left,
  because they were not in B3's file list and widening a slice after the fact is
  how a slice stops being reviewable. **Reassigned 2026-08-28 to phase 3's slice
  `E3`** — see tracks D and E above. Not because the argument for deferring them
  changed, but because a headless loop that runs ticks without frames never
  fires the signal at all, so the six of them block `E` rather than merely
  waiting for phase 4.

  The backlog is not kept here, on purpose — a list in prose is a second place
  to keep correct, and it would be wrong the first time someone fixed one
  without coming back. It lives in `tools/architecture_rules.toml` as the
  `exempt` list of the `animation-completes-simulation` rule, which is the audit
  queue and the enforcement in one object: a **new** handler trips the rule
  immediately, and deleting an entry is the visible event that records progress.
  Read that list; it is current by construction. `tools/test_check_architecture.py`
  proves both halves — that the shape is caught, and that an exemption really
  does silence it, so removing one means something.

  What each entry needs before this gate closes is one question, the same one
  B3b answered "no" for authored building fire and B3d answered "yes" for
  flight: **does it read live animation state to decide when, or whether,
  something happens?** Reading a clip's authored length once is a lookup of
  data and is fine — `flight_clip_length()` and `AuthoredFireController`'s
  precomputed `shot_times` both do it. Waiting on a finished signal is not.
  Expect some entries to clear without a fix, as building fire did.

  One is already known to be defective rather than merely suspect:
  `UnitLocomotion`'s mech gait. Its `STARTING` branch **races** the tick-driven
  `advance_start_transition()`, whose own comment already admits the tension,
  and `is_starting()` gates whether `Unit` zeroes `velocity` — so which path
  wins decides which tick a mech starts moving on. Its `STOPPING` branch is
  worse: the signal is the only path back to idle, with no tick-driven
  fallback at all.

  The trap this class sets, worth stating because phase 3 walked into it: moving
  a system onto the tick can **hide** the symptom while leaving the cause.
  `tests/units/flight_run.gd` reported 253 or 254 assertions across identical
  runs until slice B2 made its fixture drive ticks explicitly, after which it
  read a stable 381 with the coupling entirely intact. A green, stable suite
  became evidence about the fixture rather than about the code. Prove a fix the
  way B3d's test does: fire the real signal, assert nothing happened, then drive
  ticks alone.
- **Phase 5 — netcode.** Turn scheduler, adaptive input delay, checksums,
  stall/drop policy, snapshot-based reconnect, lobby with room codes and teams.
- **Phase 6 — polish.** Cosmetic prediction, parameter tuning under induced
  latency and loss, save/load of a networked match.

Migration runs incrementally on `main`, with single-player as the test bed. Every
phase leaves the game playable, and the refactor is validated by the mode we can
already play before it is trusted by the mode we cannot yet test.

## Open questions

- ~~Does Godot's `WebSocketPeer` set `TCP_NODELAY`?~~ **Answered 2026-08-18:
  yes, on both links, and the relay's poll cadence turned out to cost far more
  than Nagle would have. See decision 6.**
- How much of a turn the client's own frame rate eats, now that the relay no
  longer eats any: a 60 fps client adds up to 16.6 ms on send and the same on
  receive, which the phase 5 turn scheduler has to budget for (decision 6).
- Original tick rate: 20 Hz per the rules-data anchors versus the 25 Hz the
  combat code is tuned to (see decision 4). Phase 1 made this cheap to test:
  `MatchClock.TICKS_PER_SECOND` is the only declaration of the rate, and
  `own-tick-rate` in the checker keeps it that way.
- Snapshot size for reconnect, which cannot be estimated before the hot-state
  layout exists (decision 3).
- What happens to local view state that races a command already submitted.
  The concrete case is building placement. The confirming click submits a
  command and deliberately leaves the preview up, because whether the cell was
  buildable is not known until the command executes — and if it was not, the
  preview has to still be there for the player to click somewhere else, which
  is how it behaved before the command bus. That leaves a window between the
  click and its execution in which the placement is still active, so a right
  click lands in `BuildingController`'s placement branch (it is offered input
  before the unit controller) and cancels a placement that is already
  committed. The player sees the preview vanish; on the execution tick the
  building is placed at the clicked cell anyway and `take_ready()` consumes the
  order.

  At input delay 0 that window is one tick and no human reaches it. It widens
  with the delay, and the same shape covers every mode a player can leave
  between their own click and its execution. Phase 5 needs one rule for the
  class — treat the local dismissal as prediction and reconcile, or make the
  dismissal itself a command and accept the latency — not a patch per action.
  Cancelling the *order* is already safe by a different route: the queue is
  empty by execution time, so the placement command finds no matching ready
  order and does nothing.
- Production is still single-player-shaped. Under lockstep every client
  simulates every player, so a `SimBuildOrderCommand` carrying `player_id: 2`
  has to open an order in *that* player's queue, tick it against *that*
  player's credits, and hand the finished building to *that* player. Today it
  would take the one queue there is, spend the local player's money, write into
  the local player's sidebar, and place a building owned by
  `local_player_id`.

  The roster is already ready for this: `PlayerRoster` holds a `PlayerData` per
  player, each with its own credits, energy and purchased upgrades. The queues
  are not. `BuildingController` owns a single `_building_queue`, and
  `UnitRosterController` keys its queues by production-building id rather than
  by player; both read costs through `_local_player()`. Every player needs its
  own queues, its own resources — those exist — and its own option/availability
  state, which today is computed once, for whoever is local.

  So the fix is not to look the queue up by `player_id`. It is to separate the
  three roles `BuildingController` currently shares: the queue and its
  economics (simulation, per player), the sidebar's option state (per player as
  data, rendered only for the local one), and input handling (local only). That
  separation is phase 3's work — the same move that takes state out of the view
  objects — and `player_id` selecting a queue falls out of it afterwards.
  **Sliced 2026-08-28 as track `D`** (`D1` through `D6`, in the tracks D and E
  entry under phase 3): the three roles separate in that order, `D1` first
  because the availability verdict this argument depends on turned out to be
  refreshed on frame time and read on the tick, which is a second defect living
  in the same code.
  `SimBuildOrderCommand` already carries and orders `player_id` for that day, so
  neither the wire format nor replays recorded before it have to change.
- Suppressing local input while a replay plays back. Nothing can start playback
  from the UI today, so live controllers cannot collide with it. The day that
  changes, they submit to the same bus and would merge into the replay's stream
  — see `ReplayPlayer`'s doc comment, which names the hazard where whoever adds
  that UI will find it.
- ~~Whether phase 3's hot state stores positions as `float32` or `float64`.~~
  **Answered 2026-08-21: `float32`, `PackedVector3Array`.** Measured against the
  shipped maps rather than argued: `#M70 Claw Rock` is 256x256 world units and
  `#M25 GM Aprit Chard S 2` is 288x288 (`nav_world_bounds` in each map's
  `map_data.tres`). Dune maps are small by RTS standards, and that settles most
  of it.

  There is no navigation coarsening to worry about. A `float32` step at the far
  edge of the larger map is 3.05e-5 world units against a navigation cell of
  1.125 — one part in 36,864 of a cell, on a grid whose own indices are integers
  (`NAV_SIZE` 256), with a unit radius of about 3.7 units for scale. Float
  precision only positions an entity *within* a cell, four and a half orders
  finer than the cell itself.

  Accumulated integration error does not decide it either. `position += velocity
  * SECONDS_PER_TICK` at 25 Hz over a 60-minute match is 90,000 additions:
  1.37 units if every rounding happens to fall the same way, which is an
  adversarial bound rather than a physical one, and 0.005 units on the random
  walk that actually occurs. And for lockstep it is not a correctness question
  at all — IEEE-754 pins binary32 addition exactly as it pins binary64, so the
  drift is bit-identical on every client. It asks whether a unit ends up where
  the player expected, not whether two clients agree.

  What actually decides it: **`float32` is the status quo, not a choice.**
  Decision 5's own measurement already established that `Vector3` components are
  `float32` in this build, so every position the game holds is narrowed to
  `float32` today. `PackedVector3Array` changes nothing; `PackedFloat64Array`
  would be an upgrade — and a false one. The simulation routes positions through
  `Vector3` constantly (`global_position`, `SimMoveCommand`, ORCA's own
  geometry), so `float64` storage would be truncated back at every one of those
  boundaries, every tick. Real `float64` positions require the simulation to
  stop using `Vector3` at all, which is a far larger change than picking a
  packed type, and nothing measured here argues for paying for it.
