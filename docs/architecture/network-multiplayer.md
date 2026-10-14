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
| 12 | Placement timing | Pending placement: a five-second deadline, a no-stop reservation, and no refusal that is not provable |

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
`poll() -> [frames]`, `disconnect`, plus connection state — with four
implementations:

1. **WebSocket** — the only shipping transport in v0.4, one code path for both
   native and web.
2. **In-memory loopback** with configurable latency, jitter and packet loss —
   for headless tests that run four clients in one process and reproduce
   desyncs deterministically.
3. **ENet** — *not* in v0.4. Added later only if measurements justify it.
4. **NullTransport** — the sink every single-player Match runs over. It
   deliberately delivers nothing, so it is exempt from the shared
   self-fanout and oversized-payload-moves-to-FAILED conformance assertions.

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
than fixed at a pessimistic constant, with a floor of two **ticks**. (Earlier
wording here and in `rtt_tracker.gd` said "two turns", which is 4 ticks — twice
the implemented floor. The number `2` is the one the human decision of
2026-09-28 confirmed for `O1`'s formula, so the value is settled and the unit
was the error. Corrected at `Z1`.)

All of it is live as of `Z1`. The measurement is real: a
live `Match` pings every **six checksum-cadence cycles** — decided 2026-10-02,
48 ticks or 1.92 s at `U1`'s eight-tick cadence, and stored as
`Match.PING_INTERVAL_CADENCE_CYCLES` in cycles for the same reason the stall
threshold is — and each returning pong lands a per-peer round trip in the
`RttTracker` that `Match` owns. `O1` already settled the conversion
(`maxi(2, worst_known_rtt_ticks())`), and `Z1` applies it: `Match` writes
`SimCommandBus.input_delay_ticks` from that recommendation once a round trip has
actually been measured.

Three properties of that application are decisions rather than details, all
confirmed by human decision 2026-10-02. It is **event-driven** — the value is
written only when the recommendation changes, so the transition is a counted
event (`Match.input_delay_change_count()`) rather than a silent per-tick
recompute. It is **undamped** — the measured value is applied directly, because
a smoothing rate is a parameter nothing here has a basis to pick. And it has a
floor but **no ceiling**: capping the delay below the measured round trip would
schedule every command earlier than the network can deliver it, so it would
arrive after the receiver drained its target tick, be dropped silently by
`submit_at()`, and desync the match — the cap would guarantee the failure it
looks like it prevents. A match that has measured nothing changes nothing:
without that gate the floor of 2 would be written into every single-player
match, which boots at 0. The one exception is a match the start barrier has
gathered (`AK1`, `--net-players`). It has peers by construction, so **a gathered
match starts at the floor** before anything is measured, and `Z1`'s first
measurement then counts as a change only if it actually moves the delay. That
gate's argument was about a peer that does not exist, and a gathered match has
one. A plain `--net-room` boot is unchanged and still starts at 0.

What remains genuinely open is the direction of travel. A *falling*
recommendation shortens the delay, and if the network is in fact slower than the
last measurement said, the next command can still be dropped late and desync the
match. `O1`'s formula uses the full measured round trip deliberately rather than
a tighter one-way estimate, so this is an accepted tradeoff; tuning it belongs to
a later pass against real measurements.

When a player's frames stop arriving, the match pauses with an explicit UI state
naming the player. Removing that player is then a decision the *remaining
players* make, not a timeout this layer runs out: the model is Warcraft III's —
the match waits a few minutes, and then a vote-kick button appears for the
others. Once they do remove a player, that player leaves the turn schedule and
the rest continue.

**The silence threshold is ten checksum-cadence cycles**, decided 2026-10-02
after `K1`'s paragraph recorded that this document named no timeout anywhere.
At `U1`'s eight-tick cadence that is 80 ticks, 3.2 s at 25 Hz. It is stored as
a *cycle count* — `Match.STALL_THRESHOLD_CADENCE_CYCLES`, multiplied by
`CHECKSUM_INTERVAL_TICKS` where it is compared — so it stays ten heartbeats if
the cadence is ever retuned instead of silently drifting out of sync with the
heartbeat it is counting.

The ten cycles measure silence since a player's last frame, and are what `X1`
implemented as a detection verdict. **That is the only timeout in this
section**, and no slice owes a second one: confirmed 2026-10-02, the removal
above is a player action and player-facing game logic rather than a threshold
this track picks, so it is deferred alongside the lobby UI this track has never
built and will not build. `X1`'s `Match.is_player_stalled()` /
`stalled_player_ids()` is what such a mechanism would read from, and nothing
about the detection needs to change for it.

A dropped player's units and buildings **freeze**: they stay in the world,
receive no new orders, and their turrets and defensive structures keep working.
This is the behaviour that makes reconnect (decision 10) meaningful — the player
returns to the base they left.

## 9. Teams

Teams are fixed in the lobby before the match starts and never change in-game;
in-game diplomacy is out of scope. 2v2 and FFA on four players.

`scripts/players/player_roster.gd` already models this: it has `set_team`,
`relation_between` and `is_ally`, and `player_data.gd` has `Relation.ALLY`.
Friendly fire is already handled team-aware through
`CombatTarget.are_friendly()`'s `is_allied_with()` path.
`PlayerEliminationTracker` (`scripts/match/player_elimination_tracker.gd`,
slice `Q1`) tracks, per tick, whether a player has any building or unit
left that counts toward not losing, per the rules-authored
`exclude_from_skirmish_lose` flag. `MatchVictoryTracker`
(`scripts/match/match_victory_tracker.gd`, slice `S1`) folds that through
team topology: `remaining_player_ids()` and `is_match_decided()`, checking
every distinct pair of survivors against `PlayerRoster.are_allied()`
rather than bucketing by `team_id` directly, so an explicit relation
override (`Match._configure_demo_players()` already sets one) cannot
silently disagree with the authoritative answer. Both remain purely
observable — nothing declares a winner in any UI sense, pauses the match,
or responds to a decided verdict at all. What 2v2 still needs is
lobby-side team assignment and that eventual response.

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

## 12. Pending placement, with a deadline and a no-stop reservation

Decided 2026-10-04 and 2026-10-05, replacing the "one rule for the class"
question under "Open questions" that asked what local view state should do when
it races a submitted command. The answer turned out not to be a rule about view
state at all: **placement becomes a state of the simulation with its own
outcome**, and the input-delay window stops being a special case because it is
only the first few ticks of a state that lasts five seconds.

This is a netcode decision and not merely a gameplay one. Before the command bus
a place click took effect immediately and the question could not arise; `Z1`
then made the input delay adaptive with a floor of two ticks and **no ceiling**,
so the window between a click and its execution is now the full measured round
trip and grows with the network. Every piece of the mechanic is nonetheless
provable in single-player at delay 0, which is decision 11's own discipline.

The mechanic:

1. A confirmed placement enters a **pending** state lasting at most five
   seconds, held as `5 * MatchClock.TICKS_PER_SECOND` at the comparison site
   rather than as a bare `125` — the way `X1`'s stall threshold and `Y1`'s ping
   cadence are held as cycle counts, because decision 4 promises that
   re-testing another rate is a one-constant change.
2. Confirmation is evaluated **every tick**; the deadline is only where the
   attempt is given up. A unit crossing the site therefore costs a tick or two
   rather than the placement.

   **Items 1 and 2 landed together in `AE1`**, because they are one mechanism
   seen from two ends. `PendingPlacement` holds one entry per player and
   `BuildingController.advance_tick()` re-runs the entire placement verdict
   ladder against it every tick. Exactly one verdict defers: an immobile unit
   in the footprint. Terrain, build radius, a cell another building has taken,
   a missing scene and a stale order all stay immediate, because none of them
   becomes valid by waiting and a pending state that waits for terrain to move
   would be a bug dressed as a feature. The retry shares **one** copy of that
   ladder with the command path, which the command bus's "one dispatch" rule
   exists to force — the ladder is nine branches long, and a second copy is a
   verdict the next slice updates in only one of them. The per-player entries
   are iterated in insertion order on purpose, and that order is the priority
   rule: two overlapping reservations that clear on the same tick are retried
   in the order the bus executed their commands, so the loser's retry finds a
   building rather than a unit and takes the immediate `CANNOT_BUILD` exit on
   that same tick. Sorting by `player_id` instead would hand priority to the
   lower-numbered player, which is arbitrary where "whose command ran first"
   is not.
3. The reserved footprint becomes **no-stop for every player** — not a new
   per-player capability, which the map could not express anyway: there is one
   blocked overlay per match, shared by every player. Any unit may cross a
   reservation; none may be ordered to park on it. That is what prices out the
   denial the original game permits, where one parked scout stops a build site
   for as long as it stands there.

   **Landed in `AE1`, and it needed a third cell set rather than the `_no_stop`
   one this paragraph used to name.** The claim here was that
   `UnitNavigationPlanner._nearest_stoppable()` "already snaps a destination out
   of a no-stop cell", so a reservation needed no navigation behaviour of its
   own. That is false for precisely the case the mechanic exists to stop. A
   no-stop cell the player *explicitly aims at* is a legal parking destination
   **on purpose**: `UnitNavigationSystem` derives `allow_no_stop` from
   `runtime_map.is_no_stop(target_cell)`, and `GroundNavigation` then adds that
   destination to `_nearest_stoppable()`'s `stoppable_no_stop_cells` exception
   set — which is how a harvester is sent onto a refinery apron at all. Folding
   reservations into `_no_stop` alone would have left the scout denial fully
   available to anybody who clicked *on* the build site, which is the only way
   anyone would do it.

   So `UnitNavigationMap` now carries `_reserved_no_stop` beside `_blocked` and
   `_no_stop`: no-stop like an apron, but never eligible as a stop even when
   explicitly named. Five places ask it, and the list is the interesting part
   because it is what "an apron you may be sent to, a reservation you may not"
   costs — the order path (`command_move()`), the read-only legality answer
   (`can_move_to()`, which feeds the cursor), both slot-assignment entry points,
   the passable-anchor claim, and the reroute of an agent whose existing
   no-stop destination *becomes* reserved under it. The reservation stays
   traversable throughout; only stopping is refused.
4. Units standing in the footprint **walk out** instead of being teleported,
   replacing `UnitPushAside`'s `set_simulation_position()` write.
   `NavBlockerTracker.process_reroute_queue()` already relocates a *commanded*
   agent whose destination stops being stoppable, with a reroute budget; the
   missing piece is the idle unit, since that function skips an agent whose
   `command_id` is not positive — and an idle unit is exactly the parked scout.
   **The idle half landed in `AD1`:** `sweep_idle_no_stop_agents()` runs on the
   same blocker-refresh cadence, immediately after the refresh that may have
   just created the apron, and asks every never-commanded ground agent standing
   on a no-stop cell to yield toward the nearest stoppable one. It needed none
   of items 1 through 3, which is what corrected the sequencing claim at the end
   of this decision: aprons and skirts already exist without any reservation, so
   there was already a population of stranded idle units to clear. Three things
   it deliberately is not. It creates no order and no route — `request_yield()`
   is internal steering by its own doc comment, and the yield's *expiry* is what
   supplies the legal parking destination, through the `command_id == 0` branch
   that was already there. It is bounded to exactly that zero, not to `<= 0`,
   because `stop()` does not clear `command_id`: the expiry branch walks a
   positive-id agent back to `agent["destination"]`, which `stop()` left on the
   stranded cell, so a wider boundary would oscillate rather than relocate. And
   it does not touch `UnitPushAside`, whose teleport was then still what cleared
   a footprint at placement (until `AJ1` deleted it). The other half — walking units out of a *reserved*
   footprint — waited on item **3**, the reservation. (This sentence named item
   2 until `AE1` landed; the reservation is item 3, and the cross-reference was
   simply wrong.)

   **The walk-out half then landed in two steps, and only the first is done.**
   `AF1` widened the execution-time authority from "an immobile unit" to **any**
   unit, which is what turned `AE1`'s wait into something that clears: a mobile
   unit in the footprint now defers the placement instead of being teleported
   out from under the building, and the site is cleared by the two relocation
   paths that already existed — `AD1`'s sweep for a never-commanded agent, and
   `replan_after_map_change()` plus `process_reroute_queue()` for one with a
   positive `command_id`, which is the half the sweep deliberately skips.
   Between them they cover every agent *standing* on the site; one merely
   crossing it leaves on its own, which is item 2's "a unit crossing the site
   costs a tick or two rather than the placement".

   **`AG1` then gave both bypass callers the check**, by human decision
   2026-10-08, which is what turns the teleport from permanently load-bearing
   into something with a deletion path. `ProductionSystem._place_ready_wall_segment()`
   asks the immobile question before spawning and converges on its own existing
   `CANNOT_BUILD` outcome — refund, skip, advance — so a wall segment skips a
   cell held by an immobile unit instead of engulfing it, which is what `AA1`
   deferred and has said it deferred since 2026-10-05. MCV deployment asks the
   same question at animation completion, excluding the deploying unit, and
   takes its existing abort path. Both ask **immobile-only**, deliberately:
   neither has a wait, a wall chain skips a blocked segment permanently and a
   deploy aborts outright, so deferring on a unit merely passing through would
   cost a segment or a deploy where today it costs nothing. Widening walls to
   the any-unit question belongs to item 6, once the skip waits.

   The exclusion needed no redesign, which the `AF1` land note had claimed:
   `has_immobile_unit_in_footprint()`'s own doc comment had anticipated it since
   `AA1` — *"an MCV deployment flow must supply its own exclusion when it
   eventually uses this query"* — and the shape was already in the file, since
   `try_place_at_hover_cell()` threads an identical `excluded_unit` into
   `_push_units_out_of_footprint()`. It is one optional parameter on both
   queries, skipped by identity in the walker they share. The footprint the
   query checks is provably the one the spawn will use: the rows are the array
   `begin()` was given, threaded through the deployment record, and the rotation
   is read from the public `rotation_quarter_turns()` rather than stored, so
   there is no second copy to drift.

   **`AI1` then gave the deploy the same wait**, which is what finally empties
   the teleport's caller list. An MCV whose footprint holds a unit that can
   leave reserves the footprint and waits up to five seconds, built the moment
   the site clears and given up at the deadline through the abort the flow
   already had; an immobile unit still aborts at once, for the same reason
   item 6 gives for a wall segment. Three things that slice settled are worth
   keeping. The wait lives in the `_deployments` record that already existed, so
   unlike `AH1`'s it needs **no clear at all** — a deployment record is erased on
   every terminal outcome, so a stale wait has nowhere to survive. The
   reservation made navigation's single provider a **union**, held by `Match`
   rather than by either controller, because the two sources now live in sibling
   nodes; navigation still sees one callable, and its consumer writes every cell
   into a Dictionary, so order and duplicates stay immaterial. And the controller
   had to **join the tick** — it was driven by an animation signal and nothing
   else — which is why `Match._advance_simulation_tick()` now calls it, directly
   after the building controller so that a deploy whose cell a placement takes
   this tick sees the building on its own retry.

   **The teleport's deletion landed in `AJ1`.** After `AI1`, **no caller
   reaches the shove** with a unit it would have to move. All four production
   call sites into `_spawn_placed_building()` ask `has_any_unit_in_footprint()`
   first and do not spawn while it answers true: the two in
   `BuildingController._attempt_pending_placement()`, the wall segment's in
   `ProductionSystem._place_ready_wall_segment()` and the deploy's in
   `UnitDeploymentController._resolve_deployment()`. Each covers its first
   attempt and every retry, because both arrive through the same function. So
   `UnitPushAside.push_units_out_of_footprint()` and
   `BuildingPlacement._push_units_out_of_footprint()` are gone, and **a building
   spawn moves no unit**. `UnitPushAside` keeps only the two predicates the
   queries share.

   Two facts measured while landing `AF1` decided how the deletion was done.
   First, the behaviour had been **wholly untested** on the bypass paths:
   deleting the call failed exactly one assertion in the whole suite, the
   deliberately retargeted bypass case in `placement_immobile_unit_run.gd`.
   Re-measured while planning `AJ1` on 2026-10-10, with `AH1` and `AI1` in
   place, disabling the shove still failed that one assertion and nothing else,
   because the two paths it could not vouch for had since gained gates and tests
   of their own. `AJ1` inverted that case into the control for the deletion: it
   now asserts that a direct call places the building without moving the unit,
   and restoring the shove fails exactly that assertion.

   Second, the call could not be deleted on its own, and the sentence that said
   so here understated the cascade: it took **two parameters and an argument**,
   not one parameter. With `unused_parameter=2`, removing
   `_spawn_placed_building()`'s `excluded_unit` left
   `try_place_at_hover_cell()`'s own `excluded_unit` with no use either. The
   deploy's call site passed the fourth argument that fed it, and because that
   call is dynamic there, leaving the argument would have failed only at
   runtime. The MCV's exclusion was not lost with them: `AG1` had already
   re-expressed it on the two footprint queries, which are now the only place it
   lives. The deletion also took `unit_push_aside.gd` off
   `global-position-bypasses-store`'s exempt list, since the shove's fallback for
   a non-`Unit` node was that file's only direct position write.

   **One gap is recorded rather than owed.** The gates walk `sim_units` and skip
   anything `EntityQuery.is_live()` rejects, but the shove walked `units`. So the
   only units it could still have reached were ones the gates cannot see. One
   kind is a unit already queued for deletion, which is freed at the end of its
   tick regardless. The other is a unit **not yet admitted**: created during the
   same tick and waiting for slice `C6c`'s admission queue, which drains at the
   top of the next. Such a unit inside a footprint now stays where it stands,
   inside the new building. No route to it is known, though this is traced
   rather than measured. Every placement resolves before `UnitProductionSystem`
   in `Match._advance_simulation_tick()`, except an MCV deploy's first attempt,
   which arrives through `Unit.sim_tick()` afterwards. And a produced unit
   appears at `BuildingRallyPoint.spawn_position()`, the factory's authored exit
   marker or the nearest skirt cell of its own footprint, which no new footprint
   can overlap. If a route is ever found, the fix belongs on the admission side,
   not in a teleport.

   How far the sweep has to reach is a measurement, recorded here
   because the plan brief that got it wrong is not kept: across the 152 building
   definitions in `assets/converted/rules/buildings/`, 54 author at least one
   `s`/`d`/`p` marker, and expanding each footprint at `OCCUPY_CELL_SPAN` puts
   the deepest no-stop nav cell **8 nav cells** from the nearest cell that is
   neither no-stop nor solid body — `ATStarport`, `HKStarport` and
   `SMStarport`, whose rows 5 to 10 are entirely `d`/`s` under two rows of solid
   `b` — with four of the five refineries at 7, `ORStarport` at 6, and **21 of
   the 54 deeper than 4**. The sweep's bound is therefore not
   derived from apron geometry at all but from
   `GroundSlotAllocator.claim_anchor()`'s `SLOT_SEARCH_RADIUS`, since that is
   what assigns the destination when the yield expires: a shorter reach would
   decline to move a unit for which parking would have found a slot, and because
   there is one `_blocked`/`_no_stop` overlay per match, two adjacent production
   buildings' aprons merge into a field deeper than either alone.
5. The ready-building icon gains a **third, non-interactive state**: it reads
   as building rather than placeable, cannot cancel the order and cannot order
   another. The rest of the construction tab is already `BLOCKED` while any
   order is in flight, so only that one icon changes. **Landed in `AB1`** as
   `BuildingOptionState.State.PLACING` with the caption `BUILDING`, against the
   window that existed then — the one `input_delay_ticks` long. **`AE1` made
   that window the pending state's**, exactly as `AB1` anticipated: the icon now
   holds `PLACING` until the placement *resolves*, up to five seconds plus the
   input delay, and `AB1`'s own case asserting that an authority refusal
   restores the ready icon was inverted to assert it does not — the refusal is
   no longer an outcome, it is the start of the wait. Two things
   that slice settled are worth keeping here, because both are invisible from
   the outside. `QueueSlot` does not use `BaseButton.pressed` for slot intent;
   it overrides `_gui_input()` and emits its own `intent_pressed`, so
   `disabled` does not make the widget refuse clicks — the guard tests the
   state, and it has to, because `BLOCKED` is already `disabled` and its clicks
   must still reach the controller to produce the "busy"/"waiting for credits"
   feedback. And the refusal lives at **both** layers on purpose: the widget
   stops a click becoming an intent, while the controller refuses an intent
   that arrives anyway, since the panel is refreshed by a signal and `Match`
   wires `building_intent_pressed` straight through without consulting the
   slot.

   **Decided 2026-10-09, asked by `AH1`: `PLACING` is non-interactive for every
   caller, with no exception for walls.** `AH1` gives a waiting wall segment
   this same icon state, and the obvious-looking concession — let the right
   click cancel the wall line, since a chain is a long-running thing a player
   may want to abandon — was refused, because the only way to grant it is to
   make `PLACING` accept a button, and that reopens cancellation for *every*
   pending placement. A waiting wall segment therefore has no cancel at all:
   **the deadline is its only exit**, and expiring there already refunds the
   segment and skips it. The plan review caught the contradiction before any
   code was written, and it caught it in the widget rather than in the prose:
   `QueueSlot._gui_input()` returns before emitting either button while the
   state is `PLACING`, so the cancel the brief had described could never have
   reached the controller anyway. One structural consequence is recorded under
   item 6, because the next slice depends on it.
6. A wall segment that cannot be placed is still **skipped** rather than
   cancelling the chain — `ProductionSystem.WallChainOutcome.SKIPPED` already
   exists with its own status strings — except that the skip now waits for the
   deadline instead of being decided instantly. Only the next segment is
   reserved, so a long wall's worst case is linear in its segments, while a
   unit crossing just before a segment is built now costs a pause instead of
   the segment.

   **`AG1` supplied the check and `AH1` landed the wait, so this item is
   done.** `AG1` had already made a wall segment refuse an immobile unit and
   skip, through the chain's own `CANNOT_BUILD` outcome; what `AH1` added is the
   deadline, and with it the widening of the wall question from immobile-only to
   **any** unit — the two had to land together, because without a wait,
   deferring on a unit walking past the line would cost that segment
   permanently, while without the widening the wait could only ever wait for
   units that will never move, which is `AE1`'s pre-`AF1` state.

   Four things `AH1` settled are worth keeping here.

   **An immobile unit still skips immediately; only a unit that can leave buys
   the deadline.** This item's text does not say what happens to the immobile
   answer, and ordinary placement's reading is the opposite one — `AE1` defers
   on an immobile unit and gives up at the deadline. The wall path diverges
   because a chain holds the player's *entire* build queue for its whole length
   (`execute_wall_line()` refuses to start while `queue.has_order()`), so five
   seconds spent on a blocker that nothing in those five seconds can move is
   five seconds of the player's only queue, per blocked segment, on a line that
   may be twenty segments long. For a mobile unit the expected cost is a tick or
   two, which is item 2's own promise. That is also the split the human decision
   of 2026-10-08 prescribed for MCV deployment, so both bypass callers end up
   the same shape.

   **The waiting segment keeps its ready order in the queue.** The alternative —
   taking the order and holding it beside the wait — empties the queue for five
   seconds, and `has_order()` is what makes the rest of the construction tab
   `BLOCKED`, what refuses a second wall line as busy, and what the chain's
   exclusive hold on the queue is expressed as. Keeping it there means every one
   of those readers sees, while a segment waits, exactly what it sees while one
   is building. The cost is that `order.ready` becomes observable for five
   seconds where it previously lasted zero ticks, which is what item 5's
   2026-10-09 decision answers.

   **There is exactly one place the wait is cleared, and a second would be
   unreachable.** The clear sits immediately before `take_ready()`, so pending,
   refused and placed outcomes cannot drift apart. A clear in
   `_end_wall_chain()` was specified and then removed, because once the cancel
   is refused no route ends a chain while its segment waits: `cancel_wall_chain()`
   has one caller and it is the refused one, the availability cancel tests
   `not order.ready` and a waiting segment's order is ready, `advance_wall_chain()`
   is called only at chain start and after a resolution, and
   `_place_ready_wall_segment()`'s own terminal branches all sit below the clear.
   **That is a reachability argument, so it has an owner:** a later slice that
   gives a waiting segment any cancel route, or that lets the availability
   branch see a ready order, must add the clear and a case that reaches it. A
   leaked wait is not cosmetic — the countdown decrements whenever the wait is
   non-null, so it would run past zero forever and then deny the next chain's
   first blocked segment its deadline.

   **The countdown runs after `queue.advance_tick()`, and the position is
   behaviour.** On the ordinary path a segment's successor is started from
   inside `queue.advance_tick()`, so it gets its first tick of progress on the
   following tick; a retry that resolves — by placing *or* by expiring into the
   skip — also starts the successor, and above that call it would hand it a tick
   of progress the ordinary path never gives. With a one-tick build time that is
   two segments resolved in one tick, and it was the plan's most-corrected
   prediction: the review had to fix the stated reach of that mutation twice,
   once for the success path and once for the expiry.

   Landing this also frees `UnitPushAside`'s teleport on the wall path: nothing
   mobile reaches the spawn there any more.

What this forbids elsewhere: **refusing a click on anything that is not
provably hopeless.** The local filter may suppress only what the clicking
player can see cannot change — an immobile unit of their own — because an enemy
unit may leave before the deadline, and a refusal keyed on enemy positions
would make the verdict depend on what one client happens to know. Everything
else goes to the wire and is judged by the deadline. That is the command bus's
own "a local check may refuse to send; it may not authorize", applied to a
verdict that now has a duration.

What it costs, recorded because it was weighed rather than overlooked: a
building placed onto an enemy army makes those units walk a few cells instead of
scattering them, and a *deployed* enemy unit can still hold a site for five
seconds at a time — immobile, and inside the placing player's build radius,
which is a far worse trade for its owner than a scout was. The abuse is priced,
not removed.

**Landed so far: `AA1`, `AB1`, `AD1`, `AE1`, `AF1`, `AG1`, `AH1`, `AI1` and `AJ1`** — an immobile unit inside the
footprint refuses the placement, friend-filtered at the click and owner-blind at
execution (`AA1`); the ready icon shows a third, non-interactive state while its
placement command is in flight (`AB1`); an idle unit parked on a no-stop cell is
asked to step off it (`AD1`, the idle half of item 4); and a blocked placement
now waits up to five seconds for its site to clear, reserving the footprint
against being parked on while it waits (`AE1`, items 1, 2 and 3); and that wait
now applies to **any** unit rather than only one that cannot move, so the site
actually clears (`AF1`, the first half of item 4); and the two callers that
reached the spawn without ever asking — a wall segment and an MCV deployment —
now ask it too, so neither engulfs an immobile unit (`AG1`); and a wall segment
blocked by a unit that *can* leave now waits five seconds for its cell with that
cell reserved, instead of skipping it, which completes item 6 (`AH1`); and an
MCV deploy does the same for the Construction Yard footprint it is about to
become, which was the last caller that still displaced anything (`AI1`); and
`UnitPushAside`'s teleport, left with nothing to move, is deleted, so a
building spawn moves no unit (`AJ1`, the last of item 4).

**Still owed: nothing.** Every numbered item has landed. Item 4 records one
gap, a unit not yet admitted to the simulation, and it is not owed because no
route to it is known. If one is found, it is a slice of its own on the admission
side. Making a pending deploy interruptible, below, is likewise a slice that
would need wanting first, not debt.

**One piece of the 2026-10-08 decision was deliberately not built, and the
reason belongs here so nobody re-derives it.** That decision asked for a check,
at the deploy's resolution, that the unit is still ordered to deploy — on the
premise that a player can give a pending deploy a superseding order. **No input
can interrupt a deploy**, measured while planning `AI1`:
`CommandExecutor._execute_move()` drops every entity for which
`SelectionClassifier.is_immobilized_by_deployment()` is true, which it is for
the whole `DEPLOYING` span, and `UnitCommandController` applies the same filter
at click time, so `command_move()` — whose `agent["hold"] = false` would have
released the deploy's navigation hold — is never reached; `_execute_stop()` has
no deployment filter but `Unit.cancel_all_orders()` never touches
`UnitDeployState`, and a deploying MCV has no attack or navigation order left to
cancel, so it is a no-op; an attack order is refused by the same `is_deploying()`
primitive; and a second deploy command is refused by `_deployment_candidate()`.
A check for "is the order still deploy" could therefore never answer no, so
building it would have been the contradictory-fixture trap `AD1` already paid
for. A pending deploy is uninterruptible exactly as the animation before it
already was, and as item 5's 2026-10-09 decision made a waiting wall segment.
**Making one interruptible is a slice of its own** if it is ever wanted: both
move filters would need a verdict that separates "animating" from "waiting for
its site", accepting such an order would have to unwind the deploy through
`finish_deployment(false)` and clear the reservation, and none of it is needed
by the teleport's deletion.

**Correction, 2026-10-07:** this paragraph used to say that items 1 through 4
are mutually dependent and that only the wall deferral could go next on its own.
`AD1` is the counter-example, and a human decision of 2026-10-06 is what took
it — not an argument found here, which had the sequencing wrong. Item 4's idle
half needed no reservation, because the `_no_stop` set is already populated
today by every building apron and skirt `refresh_building_blockers()` writes
from an `s`, `d` or `p` marker. What survives of the claim is narrower: items 1,
2 and 3 are mutually dependent, because a reservation needs something to reserve
and a deadline with nothing to make a footprint clear itself would either
regress placement or never fire; item 6 needs item 1; and only item 4's
*reserved-footprint* half needs item 2.

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
- **input delay** = 3 turns (240 ms) by default, then adaptive with a floor of
  2 ticks and **no upper bound**. An earlier version of this line gave the range
  as "2–8" turns; the upper half was never implemented and must not be — see
  decision 8 on why a ceiling below the measured round trip is a desync, not a
  safety margin. One consequence, recorded at `Z1`:
  `ChecksumExchange.RETAINED_TICKS` had been justified as "4 × the widest delay
  this range admits, 16 ticks", and that basis is gone with the bound. 64 ticks
  still covers any ordinary round trip comfortably, so nothing is broken, but it
  now stands as a standalone bookkeeping limit rather than a multiple of a
  documented maximum — and whether it remains right for a very high round trip
  is a question for its own slice;
- **state checksum** every 8 ticks (320 ms), intended to cover positions,
  health, order queues and the RNG cursor. Live since `U1` as
  `Match.CHECKSUM_INTERVAL_TICKS`, which is the only declaration of the
  cadence. What the digest actually folds today is narrower than this line
  promises: `SimEntityState.state_hash()` covers entity id, position,
  health, shields, owner and invulnerability — **not** order queues and
  **not** the RNG cursor. Both ends hash the identical fields, so a
  divergence in anything covered is caught; a divergence in an order queue
  or the RNG cursor is not yet. Widening the digest is its own slice.
  Bounded since `W1`: the per-tick bookkeeping behind the comparison retains a
  64-tick window rather than the whole match, and counts the peer reports it
  discards as too late to compare (`dropped_stale_report_count()`).

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

Two of those four are live since `V1`, and two are not. `Match` halts on the
first checksum mismatch — terminally, since lockstep has nothing to
reconcile to — and surfaces the diverging tick through `halt_diagnostic()`
and a `push_error()`. Note *diverging*, not *halting*: a report can arrive a
tick or two after the tick it describes, so the number worth reporting is
`ChecksumExchange.last_mismatch()["tick"]`, not the tick the halt was
noticed on. Still owed: dumping state, which has no second state to dump
(only the peer's hash crosses the wire) and no path decided, and writing the
replay, which cannot work while nothing calls `ReplayRecorder.start()`.
Surfacing the tick to a *player* is also still owed; there is no UI for it.
Since `AL1`, a halt prints a short `[desync]` block on each client's terminal,
after `V1`'s unchanged headline. It holds the clock and frame counters, the
late drops, a per-player fingerprint of every command executed in the whole
match, and the commands executed in the last 80 ticks. Diffing the two blocks
points to a category of cause; the Phase 5 entry for `AL1` gives the table. It
does not dump state. The entity-state dump and the replay remain owed, and they
are what would localise a genuine nondeterminism, or name a culprit older than
the window.

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

  **The animation-completion audit queue across ten files comes into phase 3 as
  `E3`.** It
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
    track. **Landed 2026-08-29.** `D2`'s report listed repairs, sales, unit production and upgrades as
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
    Landing note: the move broke a manifest exemption nobody would have noticed
    until the checker went red — `animation-completes-simulation` exempts the
    sale service **by path**, and F2 keeps its `animation_finished` callback for
    `E3`, so the exemption had to move with the file. Worth recording because
    the checker validates that a rule has a violating fixture, but nothing
    validates that an exempt path still names a file that exists; a stale
    exemption would sit there silently protecting nothing.
  - **`D6`** — **landed 2026-08-30, and not what this bullet said.** The plan
    called for option state to become per-player data. That was wrong: option
    state is what the sidebar draws, so computing it for every player would be
    state whose only reader renders one of them — the defect `D3` was sent back
    for and the reason `D4a` was cancelled. What was actually broken sat one
    level below: the per-player availability caches looped the **local**
    player's id list, so a remote verdict was bounded by whose sidebar happened
    to be drawn.

    Measured before writing the brief, only two of the four lists were ever
    house-bound. `producible_unit_ids()` walks the whole manifest with no house
    filter and says why in its own comment — every producible unit stays a
    candidate and `TechnologyTree` hides the rest, so a captured Great-House
    building can expose its roster. The unit roster therefore had no
    divergence at all, and the comment `D3` left claiming otherwise described a
    hole that did not exist; `D6` corrected it. Buildings and upgrades adopted
    the same rule through `production_candidate_ids()`.

    The slice also closed the two debts recorded against it: building progress
    moved onto an explicit `build_queue_progressed(player_id)` signal and the
    resources handler stopped refreshing option state, and the doubled word in
    six upgrade messages was fixed — `D4` had preserved it so its own status
    audit could stay verbatim.

    Superseded plan text, for the record: option state per-player, closing the
    three local id lists `Match` fills from
    `_local_player_*` (`match.gd:186-190`) and the two debts recorded earlier
    against this work while it still carried the id `D5`: the building progress
    bar's wallet coupling, and the doubled "upgrade upgrade" text in five
    messages.
  - **`E1`** — a public tick pump on `Match`:
    `advance_ticks(count: int) -> int`. Measured before the migration, **68
    direct calls to `_advance_simulation_tick()` across 10 test files** — 36
    through `call()` by string and 32 direct — existed because an awaited
    frame "only advances the clock by however much wall time it happened to
    take and is not guaranteed to produce a tick at all"
    (`tests/match/demo_boot_run.gd:167`). The pump replaces those hand-driven
    copies, returns the clock boundary it reaches, and is the entry point a
    headless runner can loop without frame time. `_process()` calls it only
    after `FrameTickDriver` has applied `MAX_TICKS_PER_FRAME`; the clamp is
    frame pacing, not a simulation limit. The injectable-driver plan moves to
    phase 5, where the turn scheduler is its actual second reader, rather than
    introducing an unused seam here.

    Superseded plan text, for the record: a tick-driver seam where Match takes
    a driver rather than owning `FrameTickDriver`; a burst driver returns a
    fixed budget with no wall clock and no `MAX_TICKS_PER_FRAME` clamp to
    apply. `MatchClock`'s own class comment already names the second driver
    phase 5 will bring.
  - **`E2`** — a state hash on `SimEntityState`, and the test that makes the
    track falsifiable: N ticks with no frames must hash identically to N ticks
    interleaved with frames. It moved ahead of E2a because the hash is phase
    4's primitive regardless of the sweep, and it binds every deferred effect
    that reaches the state it observes; it does not select E2a's scope. The
    boundary is explicit: ascending live entity ids, then each live id's
    position, health, shields and owner player id, in raw packed-array bytes.
    `previous_position` is derived interpolation state and is outside it.
    State that still lives on nodes is outside it too: `Unit.invulnerable` is
    the known example, owed to E2a rather than staged here. `capture()` still
    walks stale presence bytes after a registry release while `has_position()`
    rejects that id; the hash follows the reader and excludes it. That
    snapshot disagreement is recorded, not changed, because snapshot restore
    behaviour needs its own slice. The parity arms run sequentially: Match
    walks six tree-wide group lists per tick (units twice, linger effects,
    projectiles, buildings and spice mounds), so two live matches would tick
    one another's entities.

    The gate is green as landed: over a 40-tick window that places a building,
    produces a unit, runs an attack and despawns an entity, the frameless and
    the framed arm end on the same hash. That is a result rather than a clean
    bill of health, and it is what E2a is owed less by — the deferred
    availability registration and the default rally point each fired once in
    the framed arm and not at all in the frameless one, and neither moved
    observable state inside the window. What makes the green mean anything is
    the pair of controls beside it: a deliberately deferred store write does
    make the two hashes differ, and invulnerability does diverge across the
    arms while the hash stays equal. Measured, not assumed — with `state_hash()`
    stubbed to a constant the parity case still passes and only the first
    control catches it, so the parity case on its own proves nothing.
  - **`E2b`** — **landed before `E2a`, despite the letter.** The older
    `animation-completes-simulation` pattern matched only the exact
    `on_animation_finished` handler name. Once a class had more than one such
    handler, descriptive names made six handlers in four files invisible both
    to enforcement and to its audit queue; the widened suffix pattern finds
    twelve handlers across ten queued files. `building_placement.gd` is the
    command-observable case: its frame-time construct callback clears the
    placed building's invulnerability and calls `finish_construction()`.
    E2b records those four files as unaudited rather than fixing them; that
    severing remains E3. It lands first because E2a already had two scope
    decisions made against that id, and renaming E2a would invalidate them.
  - **`E2c`** — the entity-lifecycle half of the frameless sweep. A clipless
    deploy no longer completes through a frame-deferred call: it records a
    pending completion which `Unit.sim_tick()` consumes on the next tick. The
    extra tick is a subscriber-ordering constraint, not latency for its own
    sake: the MCV controller connects before `deploy()`, while
    `CombatDeployStrategy` connects afterwards, so immediate emission would
    strand combat units in transition.

    Temporary invulnerability and its remaining tick count moved from the
    node-owned blind spot into `SimEntityState`; `-1` is indefinite placement
    protection and positive values count down at 25 Hz. Both values are pushed
    at registration, hashed, captured and restored, so equal protection with
    different expiry cannot hide a future divergence. E2's old invulnerability
    boundary control is therefore replaced by local selection, which can still
    diverge after a deferred frame callback without changing the simulation
    hash.

    Projectile cleanup has two lifecycle phases: a hitscan can finish inside
    `launch()` before queued admission, while a flight projectile finishes
    after admission. Finished projectiles now remain tick-admitted for a
    deterministic cleanup countdown (four ticks for the 0.16-second laser
    visual, one for ordinary cleanup), so the former cannot rejoin after being
    removed and the latter is not abandoned after removal. This is bounded-node
    cleanup rather than a hash fix: finished projectile ticks only preserve
    previous position and `advance()` no-ops, and no shipping reader observes
    their finish state.
  - **`E2a`** — the placement-side frameless sweep. Its one fix replaces
    `BuildingAvailabilityTracker`'s post-`node_added` `call_deferred()` with
    the added node's `ready` signal: `node_added` comes before
    `Building._ready()` joins `"buildings"`, while `ready` runs later in that
    same tick. The old call needed a rendered frame, leaving the dirty-gated
    availability caches clean when a next-tick unit order read them. The
    admission regression creates and completes a real Barracks inside tick N,
    drives tick N+1 without a frame, and observes its Infantry order accepted.

    Three audited calls remain deferred for measured reasons. Rally readers
    reach `BuildingRallyPoint.point()`, which materializes the default
    synchronously; no shipping reader bypasses it, so the deferred call merely
    changes an unobservable eager-versus-lazy moment. `rally_point_changed` is
    declared and emitted but has no `connect()` site in `scripts/` or `tests/`;
    that reader-less signal is recorded, not removed. The placement wall
    refresh and its neighbour refresh have no shipping topology reader outside
    `BuildingWallVisual`, and navigation never reads wall connectivity, so a
    frameless run can draw stale wall stubs while simulating identically.
    There are six runtime `call_deferred`/`set_deferred` calls after this
    change. **`E2c`** owns the separate entity-lifecycle half: deployment
    completion, projectile free, invulnerability, and the remaining handlers
    whose frame-time completion changes simulation state.
  - **`E3`** — audit the ten-file queue, split three ways by subsystem, and
    sever the handlers that complete simulation state, the way `B3d` severed
    flight's: read the clip's authored length once and complete on a tick
    deadline. `E3a` takes deployment: `UnitDeployState` now reads its selected
    clip's authored length once, divides it by the transition player's retained
    `speed_scale`, and queues that many simulation ticks; the old
    `Unit._on_animation_finished()` route and deploy predicate are gone. A
    frameless real-Match regression proves both a completely unadvanced player
    and one advanced through its whole clip reach the same deadline.

    `E3b` applies that same deadline to buildings. `Building` owns one pending
    authored-completion countdown because its `sim_tick()` is already reached
    through `sim_buildings`: construction, both sale variants, and Construction
    Yard deconstruction all act on that entity, while neither
    `BuildingSaleService` nor `UnitDeploymentController` has a Match tick site.
    The deadline reads the clip length once and divides it by the selected
    player's `abs(speed_scale)`, clamped to `0.01`, matching the visual and the
    construction-sound schedule. Reversing `construct` for a sale changes its
    direction but not its authored duration, so the fallback uses that same
    calculation. `building_placement.gd`, `building_sale_service.gd`, and
    `unit_deployment_controller.gd` no longer let either `play_one_shot()` or a
    direct `animation_finished` connection complete simulation state; the
    clipless sale branch remains deliberately synchronous because it has no
    frame-time completion to sever. This relies on the C6c lifecycle invariant:
    a placed building is admitted to `sim_buildings` on its next tick, and a
    selling or deconstructing building remains there until its deadline calls
    `request_despawn()`.

    The audit also corrected the queue's ownership: the
    `unit_deployment_controller.gd:356` callback is bound by
    `AuthoredModel.play_one_shot()` to the Construction Yard's `deconstruct`
    clip and spawns the packed MCV, so it belongs to building work in `E3b`,
    not deployment's project-signal subscription. `CombatDeployStrategy`'s two
    similarly named methods really do subscribe to
    `Unit.deployment_animation_finished`; their names are correct and are not
    renamed merely to satisfy a suffix regex. The widened `E2b` pattern also
    found scheduling-side `queue_deployment_animation_finished`; excluding
    `queue_`, like its existing `emit_` exclusion, keeps scheduling from being
    miscounted as a handler.

    That distinction required the rule to split its lists. `exempt` is the
    unaudited work queue and shrinks as defects are fixed; `cleared` is a
    structured, reason-required record of audited matching files that are not
    defects. The checker suppresses either list but rejects an overlap, so a
    file cannot silently move from the work queue into an undocumented waiver.

    **E3 is closed.** E3a moved deploy transitions to their authored
    tick-deadlines; E3b did the same for building construction and sale; E3c
    closed locomotion and unit fire. E3c found that `Move_Start` and authored
    fire were not missing tick completion at all: both already had integrators,
    while their animation-finished handlers were early shortcuts that made
    completion frame-paced. It removed those shortcuts and gave the genuinely
    frameless `Move_Stop` transition an authored, gait-speed-scaled tick
    deadline. The next audit work is the measured eleven non-locomotion
    `is_playing()`/`current_animation` sites: one fire-controller binding, one
    animation-director playback choice, five cosmetic idle decisions, and four
    movement-sound decisions. They are classified before a later dedicated
    rule/probe slice, not folded into E3.

    E3c also changed the contract of the two long-standing mech-transition
    regressions in `demo_boot_run.gd`: their old direct
    `animation_finished.emit()` assertions described the removed early path,
    not a visual requirement. They now drive fixed simulation ticks through
    the authored deadline and still require the same visible outcomes: the
    looping Move clip (including its zero-speed gait phase) and Stationary
    after Move_Stop. This preserves the visual chain while making its moment
    independent of render-frame signal pacing.
  - **`E4`** — the headless entry point: boot a match with no view, feed a
    recorded command log, loop `Match.advance_ticks()`, run to the end of it,
    exit. Production code is almost ready for it — `await` appears at exactly
    2 sites in all of `scripts/`, both in `match.gd`.

    *Landed.* `Match.load_replay(path)` and `Match.replay_exhausted()`
    (`scripts/match/match.gd`) are thin delegators to the `_replay_player`
    field `_ready()` already constructed but nothing had ever called `.load()`
    on. `ReplayPlayer.load()` (`scripts/match/replay_player.gd`) grew a second
    required check, against `scene_path`, ahead of the existing
    `snapshot_digest` one — plan review for this slice found that an
    empty-snapshot replay recorded for one scene could otherwise load
    successfully against a different empty-snapshot scene and resolve stable
    entity ids against the wrong nodes with no error at all. Both checks now
    fail closed with a message naming the mismatched field.

    `tools/run_headless_match.gd` is the entry point itself: `--replay`
    (required), `--scene` (default `demo_match.tscn`, what actually boots —
    the replay's header is validated against it, never used to select it) and
    `--max-ticks` (a safety bound, so a replay that never reports itself
    exhausted cannot hang the process the way AGENTS.md's "a headless run
    that hangs" section warns a stuck `SceneTree` script otherwise would).
    Its `--replay` existence check runs strictly before `--scene` is
    instantiated, in its own phase, precisely because a bogus scene path must
    never mask a missing replay file behind an unrelated error. Its boot
    settle calls `set_process(false)` on the match instance before the first
    awaited frame, the same way `tests/match/frameless_parity_run.gd`'s
    `_boot_arm()` already did for a different reason — without it,
    `Match._process()` advances the clock through `FrameTickDriver` during
    the settle itself, and an early-scheduled command goes stale before
    `load_replay()` is even called, making playback frame-dependent despite
    the whole point of this slice.

    Verified two ways, because a `tests/**/*.gd` suite driving `Match`'s
    public API cannot prove the standalone script's own argument parsing,
    check ordering or exit codes: `tests/match/headless_replay_run.gd` boots
    a real `Match` frameless, asserts `current_tick() == 0` before
    `load_replay()` runs, and asserts a replayed move command's simulated
    effect actually happened, not just that `replay_exhausted()` went true.
    `tools/smoke_test_headless_match.sh` runs the actual script as a
    subprocess five times against a committed fixture
    (`tests/fixtures/headless_match_smoke.oebr`) and checks both exit codes
    and, for the ordering and scene-identity scenarios, that the output names
    the field that failed — now a `make godot-test` step in its own right.

    `E5` is next and unblocked: the entry point it needs to measure now
    exists.
  - **`E5`** — measure it and record the number. Ticks per second headless
    against the 25 a second real time gives, on the same machine, with the
    command beside it. Until that number exists, "faster than real time" is a
    claim rather than a result, and phase 4's cost is still unknown.

    *Landed.* `make godot-headless-perf`
    (`tests/perf/headless_match_perf_run.gd`) boots `demo_match.tscn`
    frameless, restores the same 49-building snapshot
    `tests/perf/demo_match_perf_run.gd` uses, then spawns — in code, not the
    snapshot, which stays buildings-only — a 6-vs-6 `ORAPC` mirror match and
    a 4-`GUNIABTank` navigation patrol, so the measured batch is doing real
    combat and real pathing rather than idling. The number:
    **30.2 ticks/s against the simulation's fixed 25**, one representative
    `--ticks=5000 --warmup-ticks=200` run on the container host this landed
    on. Run-to-run variance was wide (26–159 ticks/s was observed across
    repeated runs on this same machine), which is the report-only nature the
    tool's own `--budget-ticks-per-second` gate exists to be honest about —
    treat the number as a floor and a baseline for comparing future runs on
    the same hardware, not a portable constant. Headless is faster than real
    time, but by a modest margin here, not the dramatic one "faster than real
    time" invites assuming; that itself is the fact this slice exists to
    pin down, and interpreting what margin phase 5's catch-up budget needs is
    explicitly left to whichever later slice needs that decision.

    Two findings surfaced building the workload, neither previously written
    down anywhere in this document: an idle `UnitCombat` does not auto-fire —
    `CombatTargetAcquisition` picks a target but `_scan_turret_if_idle()` only
    tracks it until a real `SimAttackCommand` arrives — so the harness submits
    mirrored attack orders through the same deferred command-bus path the
    navigation patrol uses. And a static 6v6 resolves in a few hundred ticks,
    so keeping the default 5,000-tick run's combat workload real for its
    whole span meant replacing defeated participants between measurement
    chunks rather than spawning the group once; every complete 100-tick
    window is checked for its own real damage, not just the batch total, so a
    battle that quietly went idle after an early kill would fail the run
    instead of being averaged away.

- **Phase 4 — determinism gate. Done 2026-09-24.** Portable math, RNG split,
  the static rules above wired into `check_architecture.py`, and the CI test
  that replays one command log twice in-process and then compares state
  hashes across native and web builds.

  **`F1` — landed, the same-process half.** Portable math and the RNG split
  turned out to already be satisfied: nothing under `scripts/sim/**` calls
  libm math, a `Vector*` angle method, or global RNG today, so both bans
  hold with nothing built, and `SimMath`/a seeded sim RNG stay unwritten
  until a real caller needs one. `tests/sim/replay_determinism_run.gd` is
  the "replays one command log twice in-process" half of the CI test:
  two `MatchFixtureScene` arms, run strictly one at a time — booted,
  loaded, driven, hashed and torn down with `frameless_parity_run.gd`'s own
  `SIM_GROUPS`-empty teardown assertion before the next arm ever boots,
  never two `Match` instances alive together, since
  `Match._advance_simulation_tick()` walks `get_tree().get_nodes_in_group(...)`
  and would cross-drive two live instances into agreement for the wrong
  reason. One case proves the same replay file, loaded into two
  independently-booted arms, ends with equal `SimEntityState.state_hash()`
  values; a second, control case proves two genuinely different replays end
  with *unequal* hashes, so the comparison is shown able to fail before it
  is trusted to pass. The "across native and web builds" half of the CI
  test remains open — it needs `godot-export-web` actually exercised
  end-to-end, which this slice deliberately left for its own turn.

  **`F3` — landed, the first step of the web half.** Deciding how to drive
  a Godot web export outside a browser was a real fork — new dependencies,
  new CI footprint — so it went back to the human rather than being guessed
  at. Their answer: Playwright driving headless Chromium (a bare WASM host
  was ruled out; Godot's web export is an emscripten build that expects a
  DOM and WebGL2), rescoped so this slice proves only that the mechanism
  works at all. `tools/web_replay/` (plain Node, not containerized, tracked
  the same way `tools/rules_editor/` already is) adds
  `check_headless_boot.js`, which serves `exports/web` over a local HTTP
  server with the `Cross-Origin-Opener-Policy`/`Cross-Origin-Embedder-Policy`
  headers a threaded WASM build would need for `SharedArrayBuffer` (this
  export reports itself single-threaded, so they are precautionary rather
  than load-bearing today), launches headless Chromium, and waits for the
  same `MapLoader:` console line the native boot already emits — proof that
  real simulation-adjacent GDScript ran inside the WASM build, not merely
  that a blank canvas rendered. `make godot-web-headless-check` chains the
  export, the server and the check, tearing the server down on every exit
  path including a deliberately-failing run (`WEB_HEADLESS_CHECK_EXPECTED_LINE`/`WEB_HEADLESS_CHECK_TIMEOUT_MS`
  override the check for exactly this). No replay, no `state_hash()`, no
  comparison against a native run yet — those are later slices in the same
  track, on purpose. This cannot run in CI: the same `.gitignore` exclusion
  of `assets/` that already keeps `make godot-test` local-only means a
  fresh checkout has no game files to export from either.

  **`F4` — landed, a replay reaches the web build.** Getting a replay into
  the running export raised a second fork — teach `demo_match.tscn`/`Match`
  itself to respond to a replay-loading trigger, or keep that capability in
  a dedicated entry point the way native's `tools/run_headless_match.gd`
  already does — decided in conversation for the dedicated entry point,
  matching the boundary this project holds elsewhere (`ReplayPlayer`'s own
  doc comment names live playback during real play as an unsolved hazard
  for exactly this reason). `scenes/dev/web_replay_check.gd` extends
  `Match` directly and overrides only `_restore_saved_startup_state()`
  (a no-op, so no local snapshot file is ever consulted) and `_ready()`
  (calls the real boot via `super()`, then `load_replay()` on an
  `@export var replay_path`), printing `WEB_REPLAY_CHECK_RESULT ok=<bool>
  message=<...>` unconditionally so success and failure are equally
  observable — never a bare timeout standing in for either.
  `scenes/dev/web_replay_check.tscn` boots it against a committed,
  header-only, zero-record replay whose header names that very scene and an
  empty digest; `scenes/dev/web_replay_check_failure.tscn` *instances* that
  same scene (Godot scene inheritance, not a duplicate node tree) and
  overrides only `replay_path`, pointing at a second fixture whose header
  names the *failure* scene with a deliberately wrong `snapshot_digest` —
  `ReplayPlayer.load()` checks `scene_path` before `snapshot_digest`, so
  getting the header's scene name wrong would have made the failure preset
  fail on the wrong check and never reach the one this slice exists to
  prove. Two new export presets (`custom_features="web_replay_check"` /
  `"web_replay_check_failure"`) each carry their own
  `include_filter="scenes/dev/*.oebr"` — a `.oebr` is not a Godot resource
  type and is not bundled by default — and a `project.godot`
  `run/main_scene.<feature>` override each, confirming Godot 4's per-feature
  project-setting overrides are exactly the mechanism this needed; the
  default preset and `demo_match.tscn` are untouched, proven by re-running
  `F3`'s own check unchanged. `make godot-web-replay-load-check` and
  `make godot-web-replay-load-failure-check` reuse `check_headless_boot.js`
  (now parameterized by `WEB_HEADLESS_CHECK_EXPORT_DIR` and
  `WEB_HEADLESS_CHECK_EXPECTED_FAILURE`) rather than a second script. Ticks
  still are not driven and no hash is extracted or compared — the next
  slices in this track.

  **`F5` — landed, a replay runs to completion inside the web build, and a
  hash comes back out.** `Match.advance_ticks()` has no internal yield, and
  a browser tab cannot block on it the way a native headless process can
  without risking Chromium treating the page as unresponsive — the one
  genuinely new, browser-specific risk this track had left, not a
  product/dependency fork needing a human decision the way `F3`/`F4` were.
  `scenes/dev/web_replay_check.gd` now calls `set_process(false)` as the
  first statement of `_ready()`, before `super()` — its only external
  caller is the web export's own boot, so nothing else was ever going to
  disable `Match._process()` the way every native headless harness's own
  caller already does. `super()` fires `Match._place_on_map()` without
  awaiting it, so the script settles two frames afterward and then
  fail-closes on `entity_state().has_position(scout.entity_id)` before
  trusting any position — sampling `ScoutA`'s baseline earlier risked
  attributing boot-time placement to the replay's own move command.
  `@export var drive_to_completion` gates a bounded loop —
  `max_ticks_when_driving` defaults to `2000`, the same
  hang-prevention discipline `E4`'s own `--max-ticks` already established —
  advancing ticks in `64`-tick chunks and yielding three `process_frame`s
  between them; each yield checks `Engine.get_process_frames()` actually
  advanced, printing `WEB_REPLAY_CHECK_YIELD_FAILED` and stopping rather
  than trusting the `await` silently. `scenes/dev/web_replay_check_ticks.tscn`
  (instancing the same success scene, overriding only two exported
  properties) drives a two-record fixture to `ticks=192` across `chunks=3`,
  reporting `moved=true` (`ScoutA`'s position actually changed, not merely
  that a record was visited), `clock_ticks` cross-checked against
  `Match.current_tick()` independently of the script's own counter, and the
  resulting `SimEntityState.state_hash()` — reproduced identically across
  repeated runs, with no browser unresponsiveness warning. Comparing that
  hash against a native run of the same replay is the next slice.

  **`F6` — landed, the comparison itself, closing Phase 4.**
  `tools/run_native_replay_hash.gd` reuses `scenes/dev/web_replay_check_ticks.tscn`
  unmodified — booting it directly as a native main scene hangs, since its
  `_ready()` never calls `get_tree().quit()`, correctly, because nothing
  about the web page it was built for needed it to. The wrapper instead
  `add_child()`s the scene and polls for both `replay_exhausted()` **and**
  `current_tick() > 0` before reading `entity_state().state_hash()` off the
  public API directly: `ReplayPlayer.is_exhausted()`
  (`scripts/match/replay_player.gd`) returns `true` vacuously before any
  `load()`, so `exhausted()` alone would have matched the boot-settle
  window itself and hashed the wrong state; `current_tick()` only leaves
  `0` once `advance_ticks()` has actually run, which cannot happen before a
  real load succeeds, since `web_replay_check.gd` disables its own
  processing as the first statement of its own `_ready()`. Selecting a
  scene by `--scene=<path>` — an `OS.get_cmdline_user_args()` flag,
  matching `tools/run_headless_match.gd`'s own convention — rather than an
  env var was itself a review finding: `tools/godot-container`'s
  `podman_base_args()` sets no `--env`/`--env-host`, so a host-side env var
  set before the container command never reaches Godot running inside it.
  `tools/compare_replay_determinism.sh` runs the wrapper, then
  `make godot-web-replay-ticks-check` (or an injected
  `WEB_REPLAY_HASH_OVERRIDE`), extracting each side's hash with a
  marker-specific pattern rather than a bare `hash=` grep — the native
  process's own stdout also carries the child scene's own
  `WEB_REPLAY_CHECK_RESULT` line, so an unqualified pattern returns two
  values for one run — requiring exactly one match per side and
  propagating a failed run as distinct from a hash mismatch. Both hashes:
  `3366564294`, matching `F5`'s own reported value. Two controls prove the
  comparison can fail for two different reasons:
  `WEB_REPLAY_HASH_OVERRIDE=0` for an unequal-but-well-formed pair, and
  `--scene=web_replay_check_failure.tscn` (`F4`'s own fixture) for a source
  that never produces a marker at all. Portable math, the RNG split and the
  static rules wired into `check_architecture.py` were already satisfied by
  the time `F1` checked them; this slice closes the one piece of this
  phase's opening sentence still open after it — "compares state hashes
  across native and web builds" — so nothing this phase names is still
  owed.

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
  fires the signal at all, so the whole queue blocks `E` rather than merely
  waiting for phase 4.

  The backlog is not kept here, on purpose — a list in prose is a second place
  to keep correct, and it would be wrong the first time someone fixed one
  without coming back. It lives in `tools/architecture_rules.toml` as the
  `exempt` list of the `animation-completes-simulation` rule, which is the
  unaudited queue and the enforcement in one object: a **new** handler trips
  the rule immediately, and deleting an exempt entry is the visible event that
  records fixed work. Its companion `cleared` list holds structured audited
  non-defects, because a name-matching file cannot leave the rule altogether
  merely because the audit found it safe. Read both lists; they are current by
  construction. `tools/test_check_architecture.py` proves the pattern, both
  suppression lists, and that the two cannot overlap.

  What each entry needs before this gate closes is one question, the same one
  B3b answered "no" for authored building fire and B3d answered "yes" for
  flight: **does it read live animation state to decide when, or whether,
  something happens?** Reading a clip's authored length once is a lookup of
  data and is fine — `flight_clip_length()` and `AuthoredFireController`'s
  precomputed `shot_times` both do it. Waiting on a finished signal is not.
  Expect some entries to clear without a fix, as building fire did.

  **Closed by phase 3's slice E3c** (`948c61f`, 2026-08-31):
  `UnitLocomotion`'s mech gait was the known defect, but its two branches
  needed different remedies. `STARTING` did have a real race: the pre-E3c
  `advance_start_transition()` already counted `_start_remaining` down every
  tick, while `on_animation_finished()` had a second, frame-paced path to the
  same `_begin_mech_move()` call; as the old comment admitted, ordinary scene
  playback could switch to Move first. Whichever path won therefore chose the
  completion tick, making it depend on client frame pacing. E3c removed that
  signal branch and left the countdown, now in `advance_transitions()`, as the
  only completion path. `STOPPING` was the actual no-fallback liveness defect:
  before E3c nothing counted down, so it held forever without frames. E3c
  added `_stop_remaining_ticks`, computed from the authored clip length scaled
  by gait cadence and decremented on ticks. The
  `animation-completes-simulation` rule's `exempt` list has been `[]` since
  that slice, so this backlog has nothing still owed.

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

  **`H1` — landed, a fixed-delay turn scheduler proven over a real
  transport.** `scripts/net/turn_scheduler.gd` bridges a local
  `SimCommandBus` to a `NetTransport`: `submit_local()` calls the bus's own
  `submit(command, current_tick)` to get the target tick `input_delay_ticks`
  already computes, then frames it — a big-endian `u32` tick prefix ahead
  of `SimCommandCodec.encode(command)`'s own bytes, deliberately outside
  that codec's envelope, whose own doc comment is explicit the target tick
  is a scheduling fact the bus decides, not the command's to carry — and
  sends it. `advance_tick()` polls once a tick and, for a decoded frame
  naming a different player, calls `submit_at(command, target_tick)`,
  preserving the sender's own tick exactly the way `ReplayPlayer.play_tick()`
  already does for a recorded one; a frame naming the *same* player is
  discarded, not resubmitted — `LoopbackHub.route()` fans every send back
  to its own sender too, and the first version of this design would have
  double-submitted on that echo before a fixed field-by-field byte check
  and a hand-computed expected tick, run independently of the round trip,
  is what makes each of those a class of bug this design guards against
  rather than a hoped-for outcome. `tests/net/turn_scheduler_run.gd` proves
  it: two `Match` instances, each with their own scheduler and one shared
  `LoopbackHub`, run sequentially rather than concurrently — verified while
  planning this slice, `Match._advance_simulation_tick()` reads
  `SceneTree`-global groups, so two live at once would each iterate both
  matches' entities — one submits a real command, the other only receives
  it through the transport, and both finish with equal
  `SimEntityState.state_hash()`; a differing-target control confirms the
  two clients still agree with each other while producing a different
  result from the baseline. `input_delay_ticks` stays a hand-set constant
  here — RTT-derived adaptivity, live checksum exchange, the stall/drop
  state machine, snapshot reconnect and the lobby are each their own later
  slice, and wiring live UI input through the scheduler instead of straight
  to the local bus remains untouched.

  **`J1` — landed, live checksum exchange between two clients.**
  `scripts/net/turn_scheduler.gd`'s wire format gained a one-byte
  discriminator ahead of everything `H1` already encoded (`0` = command,
  unchanged in substance, one byte later; `1` = a new checksum report) —
  a breaking change with nothing to migrate, since nothing outside this
  track's own tests has ever spoken the protocol. `TurnScheduler` stays
  the only thing that ever calls `NetTransport.poll()`, dispatching a
  checksum report to a new `scripts/net/checksum_exchange.gd` rather than
  letting it poll the same transport independently — two pollers on one
  transport would race each other for frames, one always starving the
  other. `ChecksumExchange` is pure bookkeeping with no transport of its
  own: `record_local_hash(tick, hash)` and `on_report_received(sender_player_id,
  tick, hash)` each resolve the comparison immediately if the other side of
  the same tick is already known, or buffer it if not — both orders had to
  work, because the sequential two-arm proof this reuses from `H1`
  delivers a whole run's reports in one batch, before the receiving
  client has recorded a single tick of its own hash. `_run_pair()`'s own
  per-tick loop keys every hash by `match.advance_ticks(1)`'s own return
  value, not the loop's zero-based counter — both arms making the
  identical off-by-one would still have agreed with each other, caught
  only by checking against an independently computed tick, not a
  round trip. The proof is genuinely bidirectional: after both arms run
  and a final flush, a last `TurnScheduler.advance_tick()` call against
  client A's already-torn-down `Match` (the scheduler and exchange are
  plain `RefCounted` objects that outlive it) resolves client B's reports
  against hashes A recorded during its own, earlier run, and both
  `agreement_count()`s reach every tick with zero mismatches and nothing
  left pending. `M1` widened pending remote reports to `(sender_player_id,
  tick)` for more than two clients with only a wider test harness, not the
  lobby. What a mismatch does beyond being observable and countable,
  adaptive delay, stall/drop, reconnect, the lobby, and
  wiring live UI input through the scheduler all remain untouched.

  **`K1` — landed, observable liveness tracking in `TurnScheduler`.**
  `J1`'s own per-tick checksum cadence resolved the exact conflict that
  made stall/drop look hard when `H1` first deferred it — a heartbeat
  already exists, so decision 8's "when a player's frames stop arriving"
  now has something to watch. `advance_tick()` took a required
  `current_tick` parameter (breaking, safe — nothing outside this track's
  own tests calls it), and records `_last_remote_activity_tick` on any
  successfully-decoded, non-echo frame of either kind, including a
  checksum report that arrives with nowhere to route (no
  `ChecksumExchange` wired) — the sender was still real, only this
  client's own wiring had nowhere to put it. An echo, or anything that
  fails to decode at all, updates nothing: there is no real sender to
  credit, and treating unreadable bytes as proof of liveness would let
  corrupted traffic masquerade as a live peer. `last_remote_activity_tick()`
  is the one new observable this slice adds; no threshold, no "stalled"
  verdict, and no response (pause, freeze, drop) — decision 8 names no
  timeout value anywhere in this document, and the response half needs
  the same live-match wiring this whole track keeps deferring. Proving
  this across the sequential two-arm harness needed one more thing pinned
  precisely: client A's final, post-teardown poll happens after `match_a`
  — the only thing that ever owned A's own clock — is already freed, so
  the tick passed into that call is a value captured from A's own last
  `advance_ticks()` return *before* teardown, not re-derived or assumed
  afterward.

  **`M1` — landed, widened checksum exchange for more than two peers.**
  `J1`'s own two-peer scope for `ChecksumExchange` turned out to be a
  choice, not a limit of anything underneath it: `LoopbackHub.add_endpoint()`
  already takes any number of registered endpoints, and `SimCommandBus`'s
  own `drain()` already sorts by `player_id`, built for more than two
  players from the start. Only the checksum side had stayed two-peer.
  Pending remote reports widened from a plain `tick -> hash` map to
  `tick -> (sender_player_id -> hash)`, so more than one peer can have a
  report buffered for the same tick at once, each resolved independently
  once the matching local hash is recorded — recording one no longer
  resolves only the first pending sender found, but every one of them.
  `last_mismatch()` now names `sender_player_id` alongside its tick and
  both hashes, since decision 4's own desync protocol wants to "surface
  the tick number," and surfacing *which peer* diverged is the same kind
  of fact once more than one peer exists to tell apart.
  `TurnScheduler._handle_checksum_report()` forwards the decoded sender id
  it already had, after its unchanged echo check — a one-line pass-through
  once the receiving end could use it. Proven with a three-endpoint
  `LoopbackHub` (never a real lobby, never more than the existing two
  sequential `Match` arms): one peer agreeing and a *different* peer
  disagreeing on the same tick, checked against the specific disagreeing
  sender's id — two agreeing peers would have passed identically against
  a broken pass-through that silently replaced every sender with one
  constant id, so the control needed a mix of verdicts to mean anything.

  **`N1` — landed, round-trip measurement to each peer, observable only.**
  Two new discriminators — `2` (ping) and `3` (pong) — reuse `M1`'s own
  field shapes. `send_ping()` embeds the sending tick and this client's
  id; a genuine, non-echo ping gets an immediate, unconditional pong back
  regardless of whether an `RttTracker` is wired, since answering is a
  courtesy to whoever asked, not something this client's own
  configuration should gate. `RttTracker` mirrors `ChecksumExchange`'s
  shape exactly: the *latest* measurement per sender, not a running
  maximum — proven with a control where a smaller second measurement
  replaces a larger first one, since a naive "worst I've ever seen from
  this peer" implementation would pass every other case and fail only
  that.

  Two real defects surfaced in review, not in this brief's own design,
  and both are why a pong's wire body grew from the originally-specified
  8 bytes to 12: `LoopbackHub.route()` fans a pong out to *every*
  connected endpoint, not just the client whose ping it answers, so a
  three-or-more-peer room lets a pong meant for one client arrive at
  every other client's own inbox too. The pong now carries the original
  ping's own sender alongside its own — `[3][tick][ping_sender][pong_sender]`
  — so a receiver can tell "is this addressed to me" from "is this
  someone else's exchange" before touching an `RttTracker` at all; a
  third-party pong is measured by nobody but its intended recipient. The
  second round fixed the same distinction cutting too far: a third-party
  pong is still proof its *responder* is alive, even though it carries no
  RTT this client should keep, so `last_remote_activity_tick()` updates on
  every genuine, non-echo pong regardless of whether it was addressed
  here — only the `RttTracker` hand-off is gated on that. Proven with a
  three-endpoint `LoopbackHub`: the ping's own sender measures both
  responders independently, while each responder's own tracker stays
  empty and neither rejects the other's reply to a ping it never sent,
  yet both still record it as activity. Setting
  `SimCommandBus.input_delay_ticks` from any measurement remains untouched
  (applied since `Z1`)
  — decision 8 names a floor (two ticks) but no conversion formula, the
  same "no exact number specified" gap `K1` already found for stall/drop's
  own timeout.

  **`O1` — landed, the RTT-to-delay formula itself.** `N1`'s own gap
  needed a human decision, unlike every prior one this track found:
  "adaptive input delay" *is* the conversion decision 8 names, with no
  smaller observable-only piece left to build first, and a wrong number
  has real gameplay cost once ever wired live — too small risks executing
  a command before every client has received it, too large adds felt lag
  for no reason. Confirmed: `maxi(2, worst_known_rtt_ticks())` — the floor
  decision 8 already names, otherwise the full measured round-trip
  directly, no halving, no added margin, chosen deliberately conservative
  over a tighter one-way estimate; tuning that tradeoff against real
  playtesting is a later pass, not a number to guess tighter now.
  `RttTracker.recommended_input_delay_ticks()` is the one new method this
  needed — `worst_known_rtt_ticks()`'s own `-1` "no peer yet" sentinel
  already floors to `2` through the same `maxi()` every other input uses,
  no special case required. Proven against the one case that would catch
  a wrong formula directly: an above-floor measurement must come back
  *exactly* unchanged, not halved, not padded — the smallest slice in the
  whole track, because the formula itself was already settled before this
  brief was written. Applying the recommendation to any live
  `SimCommandBus` remains untouched *as of this slice* — `Z1` is what
  applied it — the same live-match bootstrap question that had kept
  wiring live UI input through the scheduler deferred throughout.

  **`P1` — landed, `Match` owns a real `TurnScheduler` over a null
  transport.** Phase 2's own prose ("Single-player runs with input delay
  0 over a null transport") had never become a landed class; this closes
  that gap and, with it, the single most-repeated "remains untouched"
  line in every one of `H1`, `J1`, `N1` and `O1`'s own paragraphs above —
  "wiring live UI input through the scheduler." All 13 direct
  `SimCommandBus.submit()` call sites across the four command-issuing
  controllers (`BuildingController`, `BuildingUpgradeController`,
  `UnitCommandController`, `UnitRosterController`) now go through
  `TurnScheduler.submit_local()` instead, a behaviour-preserving
  substitution verified by reading every site: each already set
  `command.player_id = players.local_player_id` before submitting, so
  `submit_local()`'s own player-id check never trips. `NullTransport`
  (`scripts/net/null_transport.gd`) implements the real `NetTransport`
  lifecycle — `DISCONNECTED`/`CONNECTED`, explicit `open()`/`close()` —
  rather than faking a permanent connection, with two deliberate,
  documented exceptions to `tests/net/transport_conformance.gd`'s shared
  suite: a connected send is always discarded, never fanned back to the
  sender, and never fails on size, because losing every frame is this
  transport's whole contract rather than a size-triggered edge case of
  one. Proven with a real-`Match` wiring suite that captures a controller-
  issued Stop order's actual wire bytes through an injected recording
  transport, parses the discriminator and the big-endian target tick
  before decoding the command payload, and would fail if the
  `submit_local()` substitution were reverted at even one call site while
  every behavioural suite stayed green — the same "test the wiring, not
  just the part" proof this whole track has repeated since `H1`. Does
  *not* by itself unblock applying `O1`'s recommendation or `K1`'s
  liveness tracking to live play: both still need a real transport
  carrying real peer traffic, which needs the relay/lobby connection, a
  larger and more product-shaped question left for its own slice.

  **`T1` — landed, a real `WebSocketTransport` in a live `Match`,
  dev-only.** The slice `P1`'s own last sentence asks for, and the one
  every "remains untouched" line from `H1` onward had been waiting on.
  Which half to build first — the transport or the lobby — was the fork
  this track could not settle on its own, and it needed a human decision
  (2026-09-30): transport first, finish the technical foundation and prove
  the whole `H1`–`P1` stack over a real socket before investing in
  player-facing UI. So there is still no lobby: the room address and which
  player a process is arrive as two command-line arguments,
  `--net-room=ws://host:port/<room-code>` and `--local-player-id=<1|2>`,
  each parsed by a `static` function taking an explicit
  `PackedStringArray` and wrapped by a one-line resolver reading
  `OS.get_cmdline_user_args()`. That split is the whole reason the argument
  syntax is directly testable — `tests/match/match_net_args_run.gd` calls
  the parsers with hand-built arrays, covering both flags together, each
  skipping the other's, and every malformed id falling back to player 1.
  Validation goes through `is_valid_int()` before `int()`, because Godot's
  `int()` parses a leading numeric prefix rather than proving the whole
  string is a number, so `int("1oops")` returns `1` and would otherwise
  pass a `{1, 2}` range check. Both values resolve exactly once, in
  `_enter_tree()`, before `_configure_demo_players()` can read them.
  `_create_net_transport()` then returns a real `WebSocketTransport` when a
  room URL is present and `P1`'s `NullTransport` when it is not, so a boot
  with no arguments is byte-for-byte the single-player behaviour that
  shipped with `P1`. Exactly four `LOCAL_PLAYER_ID` reads became the
  resolved `_local_player_id` — the `TurnScheduler`'s own construction,
  `players.local_player_id`, `_local_player()` and the sidebar's
  ownership filter. The two `create_player()` calls and the
  `set_relation()` call deliberately did **not**: both processes must
  create the same two players with the same relation between them, and
  only *whose perspective is local* may differ, or the two ends would
  disagree about who player 1 even is — a far stranger failure than not
  connecting at all. Proven end to end against a real in-process
  `RelayServer` on a real loopback port with two real `WebSocketTransport`
  instances: two live `Match` instances still cannot coexist (the
  SceneTree-global sim groups collide), so the arms run sequentially the
  way `H1`'s own pair does, but two raw transports can, which is what
  makes the proof possible. Order is forced by the relay itself —
  `_broadcast()` fans a frame to every endpoint *currently* seated and
  keeps no history, unlike the `LoopbackHub` every prior suite in this
  track used, so player 2's transport is connected and seated *before*
  player 1 sends anything or the frame is gone for good. Delivery is
  confirmed by a concrete signal rather than a guessed tick count: because
  that same `_broadcast()` echoes to the sender, the sender's own
  `discarded_echo_count()` rising proves the relay already read and
  re-forwarded the frame, and therefore that it reached the other seat
  too. Both arms install the same pending-order precondition at the same
  simulation tick, reached through the public `advance_ticks()` path, and
  the receiver asserts `dropped_late_count() == 0` — `submit_at()` drops a
  late command silently, so without that check a delivery failure and a
  timing failure look identical. Reverting the transport switch to always
  return `NullTransport` fails the delivery assertions while the state
  hash alone still matches, which is exactly why the Stop order's concrete
  effect is asserted next to the hash: `state_hash()` folds in no
  pending-order state, so hash equality cannot by itself catch a delivery
  that never happened. Still untouched, and still each its own slice: any
  lobby UI, applying `O1`'s recommendation or `K1`'s liveness tracking to
  this now-real connection (`ChecksumExchange` and `RttTracker` are still
  constructed `null`, as `P1` left them), stall/drop's response, and
  snapshot reconnect.

  **`U1` — landed, state checksums exchanged over the live connection.**
  `T1` left every remaining Phase 5 item unblocked at once, and this one
  went first for a reason that had nothing to do with size: **its number
  was the only one already written down.** The "Starting parameters" above
  fix the checksum cadence at every 8 ticks, whereas `K1`'s paragraph
  records that decision 8 names no stall timeout anywhere in this document,
  and no ping cadence for `N1`'s `RttTracker` appears either — so either of
  those would have opened with a human decision this did not need.
  `ChecksumExchange` had been built (`J1`) and widened past two peers
  (`M1`) but never had a live sender: `Match` passed `null` for it, so a
  real match compared nothing. Now `Match` owns one, injects it as
  `TurnScheduler`'s long-optional fourth argument, and at every eighth tick
  computes `state_hash()` **once** and hands the same value to both
  `record_local_hash()` and `send_checksum_report()`. Two placement
  decisions carry the weight. It runs as the last statement of
  `_advance_simulation_tick()`, after `apply_pending_releases()` — not
  because that point is uniquely right, since any consistent point would
  detect divergence, but because it is the only one that yields the same
  number every existing reader of `entity_state().state_hash()` already
  sees after `advance_ticks()` returns, and two definitions of "the tick's
  hash" is the thing worth refusing. And `tick % CHECKSUM_INTERVAL_TICKS`
  is computed from the shared tick number, so every client reports on
  exactly the same ticks with no negotiation — a report for a tick the
  receiver will never record locally would wait in
  `_pending_remote_hash_by_tick` forever and never become an agreement,
  which is why `pending_remote_count() == 0` is asserted rather than just
  counting agreements. It records and sends unconditionally, including over
  `NullTransport` in single-player where the frame is discarded, following
  decision 11 and `P1` directly: the path is validated by the mode we can
  already play. The slice's sharpest problem was not the wiring but what a
  *second frame kind* does to tests that had counted frames. Two places
  assumed the only thing a scheduler ever sent was the command under test:
  `turn_scheduler_live_wiring_run.gd`'s raw `sent_frames` assertions, and
  `T1`'s own echo-based delivery wait, which would have accepted a checksum
  echo as proof that a Stop had been relayed. Both broke only *when frame
  timing crossed tick 8*, so a green run proved nothing — the precise trap
  phase 4's B3d note describes. The first now filters by the command
  discriminator it already asserted on; the second reads a new
  `discarded_command_echo_count()`, added beside the existing total rather
  than narrowing it, so no other assertion changed meaning. Proven by two
  sequential `Match` arms over a real relay reaching exactly two agreements
  at exactly the two cadence boundaries in a sixteen-tick window, with zero
  mismatches and nothing pending; the sender additionally asserts **zero**
  agreements against its own echoed reports, which is what would catch
  `_handle_checksum_report()` ever routing an echo instead of discarding it
  and manufacturing agreement out of one client. Observable only: no halt,
  no dump, no player-facing report. `last_mismatch()` already carries what
  that response will need. Still owed, and each its own slice: decision 7's
  halt-and-dump response, bounding `ChecksumExchange`'s per-tick
  dictionaries (they grow at about 3.1 entries per second and are never
  pruned), widening the digest past the fields listed above, `RttTracker`
  and `O1`'s recommendation, a stall threshold — which must now exceed 8
  ticks, since that is how far apart the heartbeats are — and the lobby.

  **`V1` — landed, a desync stops the match instead of compounding.** `U1`
  made divergence countable in a live match and nothing acted on it, which
  left the tree in the one state decision 7 names outright as the worst
  available: *"a silently continuing desync is worse than a stopped
  match."* It went next for the same reason `U1` did — its policy was
  already written down, while `K1`'s stall timeout and `N1`/`O1`'s ping
  cadence are named nowhere in this document and so each open with a human
  decision. `Match` now keeps one `_halted_at_tick` sentinel (`-1` for
  "running", the shape `TurnScheduler._last_remote_activity_tick` already
  uses, so no boolean can disagree with it), sets it on the first tick where
  `mismatch_count()` is nonzero, and `advance_ticks()` — the sole caller of
  the private tick method, and the entry point
  `hand-driven-simulation-tick`'s own `instead` already directs tests to —
  stops advancing. The guard lives there rather than inside
  `_advance_simulation_tick()` because `var tick := _clock.advance()` is that
  function's first statement: an early return inside it would leave a halted
  match still counting ticks it never simulated. Three decisions in the halt
  block each have a test that fails without them. It sits **outside** `U1`'s
  cadence block, because a mismatch can first exist on any tick at all —
  `advance_tick()` routes arriving reports near the top of every tick — so
  nesting it would let a diverged match run up to seven more ticks; the suite
  pins this by halting at tick 9, deliberately not a multiple of eight. It
  sits **after** the cadence block, so a mismatch resolved at the bottom of a
  tick by `record_local_hash()` is caught in that tick rather than the next.
  And it reports `last_mismatch()["tick"]`, never the halt tick — the
  substitution that would have passed every structural assertion while
  sending whoever reads the diagnostic to the wrong tick of a replay, which
  is why the message is frozen into `halt_diagnostic()` and asserted by exact
  equality against a string the test builds from values it already knows.
  Both ends halt independently with no new frame on the wire: each compares
  the other's hash against its own, so a divergence at tick `T` is a mismatch
  on both sides, and a "you-should-halt-too" message would only re-derive a
  fact both already have. They may notice on different ticks and both report
  the same diverging one. Proven by four isolated `Match` arms — halt timing
  and diagnostic, a halted clock that ignores `advance_ticks(50)`, an
  *agreeing* report that must not halt, and an untouched match ticking
  through three cadence boundaries — and held in place by three mutations,
  each failing a different case: dropping the clock guard fails only the
  permanence case, firing on `agreement_count()` instead of
  `mismatch_count()` fails the healthy-traffic case, and interpolating the
  halt tick fails only the diagnostic assertion. The halt is terminal on
  purpose: decision 1's lockstep offers nothing to resume to, and snapshot
  reconnect is the eventual answer. Still owed from decision 7's own
  sentence: dumping state and writing the replay, neither of which has the
  machinery yet (see "On desync" above), plus a player-facing surface.

  **`W1` — landed, the checksum bookkeeping is bounded.** `U1` gave
  `ChecksumExchange` a live sender and recorded the debt in the same breath:
  neither of its per-tick dictionaries was ever cleared, so a match grew them
  at about 3.1 entries per second for as long as it ran, and `V1`'s halt only
  stopped that in the desync case — a *healthy* match grew forever, which is
  the common case rather than the exceptional one. It went before the two
  other items `V1` left owed for one reason: its number was derivable and
  theirs are not. `RETAINED_TICKS` is 64 because the "Starting parameters"
  above admit a widest input delay of 8 turns × 2 ticks = 16, and four times
  that spans eight cadence intervals — arithmetic rather than judgement,
  whereas widening the digest needs a seeded simulation RNG that
  `scripts/sim/` does not contain plus a seed both clients agree on, and
  decision 7's dump-and-replay response needs a path for
  `ReplayRecorder.start()` that nothing has chosen. Entirely inside one
  `RefCounted`: no change to `Match`, `TurnScheduler`, or the cadence, since
  the exchange is already handed the current tick on every record. One
  `_is_stale()` predicate defines the retention edge for both the eviction and
  the arrival guard, so the two cannot drift. Three things here were only
  settled because review caught them. The edge is **strictly** older-than, so
  a tick exactly 64 ticks back is retained and the capacity at an eight-tick
  cadence is `64 / 8 + 1` = **nine** entries, not eight — eight *intervals*,
  nine *boundaries*, and the first draft of the brief asserted the wrong one.
  Eviction counts the *reports* it discards, not the ticks: the pending
  dictionary nests one entry per sender inside each tick, so a three-player
  room would otherwise undercount by two every time. And proving the primary
  leak was closed needed a `retained_local_hash_count()` observable, because
  the arrival guard answers from the newest recorded tick alone and therefore
  masks every behavioural probe of whether the local dictionary was actually
  trimmed — without it, deleting local-hash eviction left a green suite, which
  the mutation that removes it now demonstrates. It is the same accessor shape
  `pending_remote_count()` has always been for the other dictionary. A
  discarded report is counted, never silently dropped: a nonzero
  `dropped_stale_report_count()` means a comparison was received too late to
  make, which is a peer on a different cadence or a connection far outside the
  delay window — and deliberately **not** a desync, since the hashes were
  never compared, so `V1`'s halt condition stays exactly
  `mismatch_count() > 0`. Held in place by five mutations, each failing a
  different case, including one that targets a test written long before this
  slice: a zero-width high-water mark instead of a window breaks
  `_test_independent_ticks`, which records ticks out of order on purpose.

  **`X1` — landed, per-peer liveness and a stall verdict naming the player.**
  `K1` built `last_remote_activity_tick()` and recorded the blocker in plain
  terms: "decision 8 names no timeout value anywhere in this document". A human
  decision on 2026-10-02 supplied it — ten checksum-cadence cycles, stored as a
  cycle count so it stays ten heartbeats if the cadence is retuned (see
  decision 8). What landed is **detection only**, and stopping there was the
  judgement this slice turned on rather than a scope trim: decision 8's response
  is "the match pauses with an explicit UI state naming the player", and this
  track has no UI layer and is never getting the lobby one, so building the
  pause here would mean either inventing a player-facing surface nobody asked
  for or freezing a live match with nothing on screen to explain it — a hang,
  from the player's side. Detection is the half that is unambiguously ours and
  is what both the pause and the drop will read. Decision 8's prose also turns
  out to hold *two* timeouts: the silence threshold now decided, and a separate
  pause-to-drop interval measured from the pause, still unspecified and
  explicitly not allowed to borrow this number. The verdict needed `K1`'s
  observable widened first, because `_last_remote_activity_tick` was a single
  `int` overwritten by whichever sender's frame arrived last, so a verdict built
  on it could only have worked in a two-player room — exactly the scope choice
  `M1`'s paragraph records having had to undo in `ChecksumExchange`, and
  repeating it one slice after the number arrived would have been the same
  mistake with the precedent already written down. The widening is
  semantics-preserving rather than breaking: a single value overwritten by the
  newest frame *is* the maximum over senders of their last activity, so
  `last_remote_activity_tick()` keeps its signature and meaning as that maximum
  and all 13 of its existing assertions stand unedited — which is what makes the
  refactor provable rather than merely plausible. The verdict itself is computed
  on demand from `current_tick()`, so it holds no state, needs no place in the
  tick order, and clears by itself when a peer is heard from again — correct for
  a condition decision 8 describes as recoverable, unlike `V1`'s terminal desync
  halt. Two exclusions carry real weight. The local player is never stalled,
  because our own frames never arrive over the transport. And a player never
  heard from is *absent*, not stalled: `-1` is not silence, and treating it as
  silence would have reported the demo enemy of **every single-player match this
  project can currently play** as stalled from tick 81 onward, since nothing
  ever arrives for it over `NullTransport` — the defect most likely to have
  shipped, and the one the first mutation control targets. Proven over a real
  `LoopbackHub` with two send-only peer schedulers, carrying liveness by *ping*
  specifically: a checksum report would have entered `ChecksumExchange`, and a
  hash that did not match would have tripped `V1`'s halt and frozen the clock
  mid-case, a failure that would have read as a stall-detection bug. Held by
  five mutations, including one that answers for every player at once and must
  fail only the two-peer case while every single-peer case and all 13 existing
  no-argument assertions still pass. One acceptance demand of the brief proved
  unmeetable and was withdrawn at land rather than faked: GDScript returns the
  same empty `Array[int]` whether or not `stalled_player_ids()` guards a null
  roster, logging a `Nil` error instead of returning anything different, so no
  behavioural test can distinguish that guard. It is kept for consistency with
  every other `_players()` call site, and the suite says in a comment why it
  cannot be pinned — in place of an assertion on `match.gd`'s source text, which
  would couple a test to production formatting and report a reformat as a
  missing guard.

  **`Y1` — landed, a live match measures the round trip to each peer.** The
  last piece of the `H1`–`O1` stack never wired into a real `Match`. `N1` built
  `RttTracker`, `O1` settled the formula, and `TurnScheduler` has had
  `send_ping()` and an optional tracker argument since `H1` — but `Match` passed
  `null` for it from `P1` onward and nothing ever sent a ping, so no round trip
  had ever been measured in a game. A human decision on 2026-10-02 supplied the
  cadence: six checksum-cadence cycles, stored in cycles like `X1`'s threshold
  so it stays six heartbeats if the cadence is retuned. `Match` now owns one
  `RttTracker`, hands it to the scheduler as the fifth collaborator, and sends
  `send_ping(tick)` on that cadence — the *tick* being the measurement, since
  `_handle_pong()` subtracts it from the arrival tick, which is only comparable
  across clients because both ends count the same integers. The ping block sits
  after `U1`'s checksum emission and before `V1`'s halt check, deliberately:
  `V1` placed that check last so a mismatch resolved at the bottom of a tick is
  caught in the same tick, and appending after it would have changed nothing
  observable today while quietly undoing that ordering. **Measurement only**
  (applied since `Z1`).
  `O1`'s recommendation is still not applied to any live `SimCommandBus`, and
  the reason is not scope tidiness: too small a delay means a command arrives
  after the receiver has drained its target tick, `submit_at()` drops it late
  and silently, and the two simulations diverge — which `V1` then halts. A
  dedicated case asserts `input_delay_ticks` is untouched after a real
  measurement, so a later slice applying the recommendation has to change that
  assertion deliberately rather than find the boundary already gone. Two
  findings came out of review rather than implementation, and both are the kind
  that pass silently. First, self-measurement is blocked by **two** independent
  guards — `_handle_ping()` refuses to answer a ping from the local id, and
  `_handle_pong()` refuses to route a pong from it — so either alone suffices
  and no single-guard mutation can demonstrate the invariant; the suite's
  self-echo case therefore asserts two separate facts, and the control that
  actually produces a self-RTT has to remove both. That case also has to run
  **two** hub delivery cycles, because the hub moves one hop per `step()` and a
  self-addressed pong is only *queued* when the echoed ping is handled — stopping
  a cycle early leaves the mutation unobservable rather than failing, which is
  how an earlier revision of the brief would have shipped. Second, because six
  cycles is a multiple of eight ticks, every ping tick is also a checksum tick,
  and a test peer built without its own `ChecksumExchange` rejects the report
  and logs an error before it ever answers the ping — so each answering peer
  gets one, and every measuring case asserts `rejected_frame_count() == 0`,
  which is what turns "co-cadenced traffic is harmless" from an assumption into
  a checked fact.

  **`Z1` — landed, the adaptive input delay is actually adaptive.** `O1` settled
  the formula and every slice since has carried a line saying applying it
  "remains untouched"; `Y1` made the measurement real and stopped deliberately
  short. `Match` now writes `SimCommandBus.input_delay_ticks` from
  `recommended_input_delay_ticks()`, immediately after the scheduler poll that
  is the one point in a tick where a pong can have landed — so a command
  submitted later in the same tick already uses the new delay. Three human
  decisions (2026-10-02) shaped it and each has a test that fails without it.
  **Event-driven**: the write happens only when the recommendation changes, and
  `input_delay_change_count()` exists because of a subtlety the decision itself
  pointed out — between measurements the recommendation cannot change, so an
  event-driven application and an unconditional per-tick reassignment leave
  *identical* values behind. The count is the only thing that distinguishes
  them, which makes it the observable rather than a convenience, the same
  reasoning that forced `X1`'s `retained_local_hash_count()`. **Undamped**: the
  measured value is applied directly, since a smoothing rate is a parameter
  nothing here can justify picking. **And no handling for already-scheduled
  commands**, because none is possible: `submit()` is
  `submit_at(current_tick + input_delay_ticks)`, so a target tick is computed
  once and stored, and a later change cannot reach it. That is proven rather
  than defended — a case submits a Stop, changes the delay, and asserts the
  command still executes on its original tick with nothing dropped late, and
  the mutation that makes `drain()` recompute the target tick is what shows why
  no code was needed. The gate matters more than it looks: the floor is 2 and
  the bus boots at 0, so without "has anything actually been measured" every
  single-player match would silently gain 80 ms of input lag for a peer that
  does not exist — the same shape as `X1`'s "never heard from is absent, not
  stalled". Review also caught that a **ceiling** was both invited and
  unverified: "Starting parameters" documented the delay as adaptive in 2–8
  turns, so a `mini(recommended, 16)` clamp looked like following the spec,
  while every acceptance case measured inside that range and would have passed
  with one. A clamp is in fact a correctness bug — a delay capped below the
  measured round trip schedules every command earlier than the network can
  deliver it, which is precisely the silent late drop and desync this slice
  exists to avoid — so a case now plants a 25-tick round trip and asserts the
  full value is applied. The same audit found the floor had been mislabelled
  "two turns" (4 ticks) next to its own `INPUT_DELAY_FLOOR_TICKS := 2` since
  `O1`, in two source comments and in decision 8; the value was the
  human-confirmed one and the unit was the error, so the labels were corrected
  and the constant left alone. Nine written statements were falsified by this
  slice and not one of them would have failed a test.
  **`AK1` — landed, a networked match waits for every player before its first
  tick.** This was directed by the human on 2026-10-10. They run two clients by
  hand against the relay and cannot launch them at the same instant, and until
  now nothing synchronised a start. Each client ticked from its first frame.
  `WebSocketTransport.send()` drops a frame silently while the socket is still
  connecting, and the relay keeps no history. So two hand-launched clients
  started seconds apart. Whatever the first sent before the second was seated
  was lost, and the second's commands then arrived behind the first's clock and
  were dropped late by `submit_at()`. A third argument now asks for the wait,
  `--net-players=<N>`, alongside `T1`'s two:

  ```
  make relay
  godot --path . -- --net-room=ws://127.0.0.1:8910/dev --local-player-id=1 --net-players=2
  godot --path . -- --net-room=ws://127.0.0.1:8910/dev --local-player-id=2 --net-players=2
  ```

  **The barrier lives on the client**, because decision 1's relay is dumb on
  purpose. While waiting, the match does not tick: `_process()` polls the
  barrier instead of the tick driver, and `advance_ticks()` refuses, extending
  `V1`'s guard to a second condition. Every client re-sends a presence frame
  (`HELLO`, discriminator `4`) once per checksum cadence, 320 ms, because a
  frame sent before a peer is seated is gone for good. A client counts itself
  present only when its own hello comes back from the relay, which proves it is
  seated rather than merely connected. Player 1, the lowest id, so nobody
  negotiates, sends one `START` (discriminator `5`) once all N are present.
  **Every client, player 1 included, starts on the relay's copy of START**, not
  on sending it. The relay fans a frame to every seated endpoint, its sender
  included, at once. So start skew is the difference of the two relay legs,
  `|r_A − r_B|`, plus under two frames of polling quantization. A
  "ready → go" handshake would instead leave the full one-way latency.

  What skew is tolerable follows from the late-drop rule. A command clicked at
  the sender's tick `x` targets `x + 1 + d`. The receiver accepts it if it has
  not yet drained that tick when the frame arrives. With `S` the receiver's lead
  in ticks, `ow` the one-way latency in ticks and `d` the sender's input delay,
  that condition is `S + ow < d`. `Z1`'s zero-until-measured delay fails it for
  the first two seconds of any networked match, even at zero skew. So a
  gathered match starts at the floor of two ticks (decision 8). On one machine
  or a LAN, `S` is at most two frames, about 33 ms at 60 fps, and `S + ow` sits
  well under the 80 ms the floor allows.

  **Commands issued while waiting are held, not refused.** `submit_local()`
  still queues them in the local bus but keeps the frame until release. None of
  its thirteen call sites, which all discard the return value, is left holding
  view state that nothing will resolve. **Presence frames are scheduler frames**,
  like checksums and pings, not `SimCommand`s. After release they are ignored
  without counting as activity, so a client that missed START cannot mask the
  silence `X1` looks for.

  **Without `--net-players` every boot is byte for byte what it was**, including
  a plain `--net-room` boot's zero-until-measured delay. `N = 1` means nothing
  to wait for and behaves the same, and `N` is capped at 2 because the roster
  holds two players.

  **How it is proven.** Two raw schedulers run on a `LoopbackHub`, which, like
  the relay, delivers only to endpoints seated at send time. After a hello lost
  to an unseated peer is re-sent, both release on the same delivery of START.
  One live `Match` waits and then starts on its own frame loop, without the test
  ever calling `advance_ticks()`, since two live matches cannot coexist. All
  eighteen mutation controls were measured. One prediction in the brief was
  wrong: dropping the re-send also fails the case added in revision 2 to time
  the first hello, because that case observes the second hello too.

  Two things are owed and deliberately not built.

  - **A WAN client is exposed before its first round trip is measured.** At 50
    ms one way and a 20 ms leg difference, `S + ow` is about 100 ms against the
    floor's 80, for the two seconds until the first pong. The fix is to seed the
    delay from a round trip measured during the barrier, in wall-clock time,
    since ticks are frozen there.
  - **The barrier bounds only the initial skew: clocks are never resynchronised
    after start.** `FrameTickDriver` discards ticks past five per frame on a
    hitch, so a client that stalls for more than 200 ms falls permanently behind,
    and nothing re-aligns two clients afterwards. Below about 30 fps, the
    two-frame quantization term alone approaches the floor.
  **`AL1` — landed, a desync halt says which client dropped what.** This was
  directed by the human on 2026-10-14. The first real two-process run over
  `AK1`'s barrier halted once at tick 400 and could not be explained afterwards.
  Both terminals printed only `V1`'s one line, while every fact that would have
  told the causes apart was counted or known and never surfaced:
  `SimCommandBus.dropped_late_count()`, `FrameTickDriver.dropped_ticks()`, and
  which commands each client executed on which tick.

  It is diagnostics for a human reading two terminals, not a proof system.
  `scripts/sim/` is untouched, and `V1`'s halt is unchanged. Two output sites
  are added, and both are unreachable in single-player and in replay
  playback:

  - **A late drop is printed when it happens**, by `TurnScheduler`, the one
    place a remote command enters the bus:
    `[desync] late drop: player 2 SimMoveCommand 1a2b3c4d for tick 395, refused at local tick 397`.
  - **At the halt**, after `V1`'s `push_error()`, each client prints:
    - `[desync] player 1 halted at tick 400: input_delay_ticks=2 dropped_late_count=0 dropped_ticks=0 rejected_frames=0`;
    - up to the 8 newest late-drop lines;
    - one line per roster player, `[desync] player 2 stream: executed 14,
      dropped late 0, content 5e1f0a7c, timed 9a03b2d4`;
    - `[desync] commands executed in the last 80 ticks: N`, followed by
      `[desync] tick T player P <description>` for each.

  A command's description is its class name and a 32-bit FNV-1a of its codec
  bytes. FNV-1a is used rather than engine `hash()`, because nothing pins
  `hash()` to be stable across processes. Extract each terminal's block with
  `grep '\[desync\]'` and diff the two.

  **The per-player lines rest on one verified fact: the issuing client always
  executes its own commands.** A local submission targets past every drained
  tick, so it can never be refused late. So within one player's line, a
  receiver can only fall short of the issuer, and losses cannot cancel. Losses
  on different players show up as separate shortfalls, where one combined count
  would have hidden them.

  **The digests are a fingerprint, not a proof.** The plan review constructed
  two different `SimMoveCommand` targets for the same unit that share a 32-bit
  description digest, and on the same tick they would leave both dumps
  identical. The table below therefore reads **evidence categories**, and it
  assumes **a single discrepancy**. Several faults at once can combine into a
  pattern that reads as another, and where even one fault leaves two readings,
  the row says so.

  For each player P, compare P's stream line on P's own client (the issuer)
  with P's line on the other client (the receiver):

  | pattern in P's two lines | points to |
  | --- | --- |
  | Receiver executed k fewer; its `dropped late` for P is k. | (a) dropped late. Its `late drop` lines name the commands. |
  | Receiver executed k fewer; `dropped late` for P is 0. | (e) **loss, undecodable frame or echo-collision**. This is ambiguous: the dump does not separate them. A nonzero `rejected_frames` makes "undecodable" likelier, but cannot attribute the frame to a player. |
  | Receiver executed k fewer; `dropped late` is j, with 0 < j < k. | (a) for j; the rest fall under (e)'s ambiguity. |
  | Receiver executed **more** than the issuer. | A spurious or duplicated command. Record it. |
  | Counts equal; content digests differ. | (f) **content or order differed**. This is ambiguous: the digest folds order, and a loss plus a spurious extra reads the same. The recent lists separate them if the culprit is recent. |
  | Counts and content equal; timed digests differ. | (c) a command ran on different ticks. The code says this cannot happen today, and the dump shows it anyway. |
  | Every line matches, and there are no late drops. | Consistent with (d), a genuine nondeterminism, **by elimination** of the command-stream causes. This includes state outside `state_hash()` that already differed. A fingerprint collision would look identical. |

  **(b), a clock that fell behind**, is the scalar line's `dropped_ticks` > 0.
  It causes nothing alone: it appears beside row (a) on the *other* client,
  whose `late drop` line's target tick against its refusal tick measures by how
  much.

  **Why the summary covers the whole match.** `state_hash()` misses order
  queues, production queues, money and the RNG cursor, so a lost build order
  surfaces only when its building spawns, possibly minutes later. No bounded
  list can be guaranteed to hold the culprit.

  **Why the recent list is 80 ticks.** Its job is only to *name* a culprit the
  very next checksum caught. A report for checksum tick T is accepted until
  the newest recorded hash passes T + `RETAINED_TICKS`. Because a tick records
  after it polls, `V1` can halt as late as T + 72, and that culprit ran no
  earlier than T − 7. So the window is `RETAINED_TICKS + 2 ×
  CHECKSUM_INTERVAL_TICKS` = 80, as `Match.DESYNC_LOG_WINDOW_TICKS`. The first
  brief used 64, and the review showed that retention bounds bookkeeping, not
  a causal command's age.

  **How it is proven.** Three plan-review rounds shaped it, each narrowing a
  claim the dump could not keep. The 64-tick window. A whole-match line first
  promised as exact, then per-player once the review found two cross-player
  losses that cancel. And two "unambiguous" rows that a decode failure, an echo
  collision or a reordering also explain. One halt case plants every scalar
  with a distinct value. Another plants exactly the T + 72 worst case. Unit
  cases prove the per-player summary outlives the window and that losses on
  two players do not cancel. Twenty mutation controls, five re-measured at
  land.

  **Owed**, as decision 7 records: the entity-state dump and the replay, for
  localising row (d), naming an old culprit, or settling a fingerprint
  collision.
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
- ~~What happens to local view state that races a command already submitted.~~
  **Reframed 2026-10-05: the worked example this entry argued from is falsified
  by the code, both options it offered are impossible, and the class was
  replaced by a mechanic — decision 12. A narrower question survives and is
  stated at the end of this entry.**

  The example was: the player right-clicks inside the window, the preview
  vanishes, and on the execution tick the building is placed at the clicked cell
  anyway. That cannot happen. `BuildingController._committed_placement_cell`
  locks the placement from the instant the command is submitted until it
  executes — `process()` pins the preview to the clicked cell instead of
  following the pointer, `handle_unhandled_input()`'s placement branch consumes
  nothing, and `_on_building_slot_right_pressed()` will not cancel.

  **Correction, 2026-10-05:** `AA1`'s land step wrote here that three of the
  four input paths carried that guard and that `AA1` closed the fourth. The
  first half is true; the second is not — `AA1` added an immobile-unit filter
  and never touched `_begin_ready_building_placement()`, which still has no
  `_committed_placement_cell` guard. Clicking the ready icon during the window
  therefore re-begins the preview, emits a false "placement ready", and resets
  the rotation to zero while the committed command carries the old one, so the
  pinned preview shows the wrong orientation until execution. `AB1` closed it,
  together with item 5's icon state, since both lived in that same window.

  Neither option this entry proposed for the class survives either, and the
  reason is the same for both: **they both still place the building.** "Treat
  the local dismissal as prediction and reconcile" has nothing to reconcile to,
  because decision 1 is lockstep with no rollback — the building is really
  built, so reconciling can only mean showing the player a building that appears
  unbidden. "Make the dismissal itself a command" cannot retract a command
  already ahead of it in the bus, and `SimCommandBus` has no un-submit. The two
  differ only in whether the view lies early or freezes, which is not the
  difference the entry was asking about.

  What survives is the *other* half of the original observation, which decision
  12 deliberately does not cover: sell and repair gave the player no local echo
  at all. `_try_sell_building()` and `_try_toggle_building_repair()` emitted a
  status only when the click resolved to no building, so a click that landed
  submitted in silence — and on the sell side the silence ran all the way
  through, since execution emits nothing on success either.

  **`AC1` closed the echo half, 2026-10-06.** Both handlers now emit
  `"%s sale ordered"` / `"%s repair ordered"` the moment the command is
  submitted. Each claims only that an order was sent, which for repair is
  forced rather than chosen: `execute_repair_building_command()` reads the
  toggle direction at execution and is right to, so no click-time message can
  honestly say "started" or "canceled". A case asserts the echo is present and
  that **neither** execution string is, because an implementation that read
  `is_repairing` at click time would emit whichever matched and would pass a
  one-sided assertion.

  **What is still owed is the harm, not the silence.** At a real input delay the
  response to silence was to click again, and the echo makes that less likely
  without preventing it. A second sell click inside the window is still
  swallowed by `_sale_service.is_active()` while the first building sells — so
  the player can still sell the building they thought they had missed. A second
  repair click still toggles repair back off. Preventing either means refusing
  to send a duplicate while one is in flight, which the command bus's own
  *"a local check may refuse to send; it may not authorize"* already sanctions
  and which `_committed_placement_cell` already demonstrates for placement.

  That is deliberately not queued, because it carries a fork nobody has
  settled: **suppressing a second repair click also removes the player's
  ability to cancel a repair they just ordered, until it executes.** At a
  two-tick delay that costs nothing; at a second it is a real loss of control.
  Whoever picks this up has to choose between a duplicate-proof click and a
  cancellable one, and that is a product call rather than a netcode one.

  **Deferred to phase 6 by human decision, 2026-10-06, and the fork is not to
  be picked before then.** This is the same class of problem as the one
  `UnitCommandController.on_command_executed()` already names in its own doc
  comment — that once phase 5 raises the delay for real play an
  acknowledgement *"necessarily arrives noticeably late relative to the click
  that caused it, and hiding that gap behind an optimistic guess of the outcome
  is phase 6's job, not this method's"*. A move order has the identical hole
  and is not getting an early answer either. Phase 6 owns **cosmetic
  prediction**, and once that exists the window this fork argues about may
  shrink or disappear for the same reason it would for movement: a predicted
  acknowledgement makes the second click unnecessary rather than harmless, so
  neither suppression nor cancellability has to be chosen in the abstract
  first. Resolving it now would be picking between two answers to a question
  phase 6 may dissolve. The behaviour stays exactly as `AC1` left it.
- ~~Production is still single-player-shaped.~~ **Resolved by track `D`;
  re-checked 2026-10-07 while landing `AE1`.** The entry stood in the present
  tense long after the work it described had landed, which is the failure mode
  a resolved question left in an open-questions list always has: it said "today
  it would take the one queue there is, spend the local player's money, write
  into the local player's sidebar, and place a building owned by
  `local_player_id`", and all four clauses are now false.

  It was sliced as `D1` through `D6`, every one of which has a row in
  [`slices.md`](slices.md), and the separation it called for is the separation
  that exists: the queue and its economics are per player
  (`ProductionSystem.build_queue_for_player()`, with
  `queue.advance_tick(player.money, Callable(player, &"spend_money"))` charging
  *that* player), availability is asked per player
  (`_is_building_available_for_player(player_id, building_id)`), and the sidebar
  is the one thing rendered for the local player only — which was the intended
  end state, not a gap. `SimPlaceBuildingCommand` carries `player_id` and every
  branch of `execute_place_building_command()` keys off it, including `AE1`'s
  per-player pending entries.

  What the entry predicted about the wire held: `SimBuildOrderCommand` already
  carried and ordered `player_id`, so neither the format nor replays recorded
  before the change had to migrate.

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
