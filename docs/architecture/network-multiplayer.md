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
  because there is only one.

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
  two death sequences: `BuildingSaleService._finish()` and the two
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

  **What C5 made visible, measured 2026-08-21 and deliberately left open: dead
  units are still being moved.** Erasing liveness at the kill site turned every
  hot-state write against a not-yet-drained entity into a loud refusal, and the
  volume named the gap: 1707 `push_error`s across a full suite run, 1698 of them
  from `tests/match/demo_boot_run.gd` alone (1662 position, 23 health, 17
  shields, 5 owner; 7 of the 1707 are `tests/sim/entity_state_run.gd`'s own
  deliberate error-path cases and 2 are `despawn_run.gd`'s).

  The path, traced rather than guessed: `UnitNavigationSystem.sim_tick()` walks
  its own agent registry and calls `Unit.navigation_step()`, which writes the
  unit's position -- and it prunes agents on node validity alone, while
  `queue_free()` keeps a node valid until the engine frame ends. So a dead unit
  keeps being navigated for every remaining tick of the frame that killed it.
  `Unit.sim_tick()`'s own `_simulation_halted` guard does not cover this,
  because navigation drives the unit from outside that call.

  Behaviour did not change: the node still moves and the store still refuses,
  exactly as before. What changed is that the store now says so. This is the
  same trap phase 3 already walked into once from the other direction -- there,
  moving a system onto the tick hid a defect's symptom while leaving its cause;
  here, a slice that touched neither made a silent pre-existing defect start
  reporting itself. Neither the silence nor the noise is evidence about the
  code that produced it.

  Two ways out, neither chosen here because choosing is a decision rather than a
  detail. Either the store learns to tell a released id from a never-allocated
  one -- `SimEntityRegistry.kind_of()` already outlives `release()` precisely so
  that distinction stays available, and a write to an id that died this frame is
  expected under C5 in a way a write to an id that never existed is not -- or
  navigation stops stepping a halted unit at all, which is the behaviour fix and
  a wider slice than quieting a report. Recorded here rather than in a checker
  rule because it is one known site, not a class someone could reintroduce
  without noticing.

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

- **Phase 4 — determinism gate.** Portable math, RNG split, the static rules
  above wired into `check_architecture.py`, and the CI test that replays one
  command log twice in-process and then compares state hashes across native and
  web builds.

  **Carried in from phase 3, and deliberately not fixed there: simulation state
  that completes on an animation signal.** `AnimationPlayer`'s
  `animation_finished` fires on engine frame time, so anything that completes on
  it takes however many simulation ticks the machine's frame rate happened to
  allow. Slice B3d removed one instance of this from `UnitFlightController` and
  proved the severing directly; the rest were found by its sweep and left,
  because they were not in B3's file list and widening a slice after the fact is
  how a slice stops being reviewable.

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
