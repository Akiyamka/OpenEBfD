# Phase 3 slice index

Phase 3 was built as numbered slices — `A1a`, `B3d`, `C6b`, `R2b` — and that
numbering is load-bearing in the source: 230 comments across `scripts/`,
`tests/` and `tools/` justify themselves by naming a slice — 178 when this
file was written three slices ago, which is the rate the rule below has to
keep up with. This file is the
lookup those comments assume exists. A reader who hits "since slice C5" in
`scripts/units/unit.gd` comes here to find the commit that did it.

**This is history, not a plan.** Every row names work that has landed. The
backlogs live somewhere else — in the `exempt` lists of
[`tools/architecture_rules.toml`](../../tools/architecture_rules.toml), where a
queued group is a file list that shrinks as slices empty it, and where future
ids (`R5` and the slices after it) are named as work owed rather than work
done. A slice gets a row here when it lands, not when it is planned; grep the
manifest, not this file, to find out what is still owed.

**It is enforced, not maintained by discipline.** The `unindexed-slice-reference`
rule in [`tools/architecture_rules.toml`](../../tools/architecture_rules.toml)
(kind `slice-index`) scans `scripts/**/*.gd` for `slice <id>` references and
reports any id this table does not list, so a comment cannot name a slice that
has no row. `tools/test_check_architecture.py` closes the other half:
`check_slice_index_hashes()` runs `git rev-parse --verify` over every hash below
and compares every date against its commit, so a row cannot rot into a hash
that resolves to nothing.

Two limits worth knowing before trusting a green run:

- The rule only sees its zone, `scripts/**/*.gd`. References under `tests/`
  and `tools/` — including the `R4a` mention beside `allow_budget` in the
  manifest — are covered by the self-test's whole-tree pass over hashes, but
  not by the per-line rule. A reference in a test file naming a slice with no
  row will not be reported.
- An unreferenced row is not an error. History stays even when the last comment
  that mentioned it is deleted.

## Reading the table

- **commit** — the commit that made the change, first. Commits that recorded a
  slice's *scope* before it was written, corrected its account afterwards, or
  fixed a defect it turned up, follow in the same cell, tagged. The **date** is
  the implementing commit's, so the table sorts by when the work landed rather
  than by when it was decided.
- **`—`** in the commit cell means the slice deliberately never had a commit of
  its own: it is a parent that was delivered entirely through its lettered
  children.
- **`?`** would mean a slice this reconstruction could not pin to a commit.
  There are none.
- **`pending`** in the commit cell means the row landed in the same commit as
  the code that cites it, so the hash it will carry does not exist yet — a
  commit cannot contain its own hash, and the `slice-index` rule plus the
  pre-commit hook together mean the row cannot wait for the next one. The
  self-test allows exactly one, so a pending row has to be filled in before the
  slice after it can use the same escape.
- **`†`** marks a hash whose own commit message never names the slice id it is
  filed under, so the attribution is this reconstruction's inference rather than
  the commit's own claim. Eight of the twenty-six rows carry one, measured with
  `git show -s --format=%B <hash>` against each row's id: `A1a`, `A1b`'s
  implementing commit, `C5`'s implementing commit and its defect fix, `C6c`,
  `R2b`, `R3` and `R4a`. Each rests on the design note in the cell beside it
  describing the same change, and on nothing else. Nine further hashes name
  their id without the word "slice" and are not marked — the regex wants
  `slice <id>`, the commits simply write `C6a` or `R1`. The `Slice:` trailer
  above exists so this column stops growing.
- **design note** links the paragraph in
  [`network-multiplayer.md`](network-multiplayer.md) that argues the slice.
  Those paragraphs are bold or italic openers inside `## Order of work`, not
  headings, so they have no anchors of their own — the link lands on the
  enclosing section and the link text is the paragraph's exact opening phrase,
  which is greppable. An empty cell means no paragraph is devoted to that
  slice; several are mentioned only in passing inside another slice's argument.

## Keeping it current

New work carries its id in the commit message as a trailer:

```
Slice: R5
```

That is the whole convention, and it is what makes this table auditable rather
than archaeological — the reconstruction below had to be read out of prose
because nothing ever asked for the id. To list what is missing a row:

```bash
git log --format='%h %ad %s%n%b' --date=short | grep -B0 '^Slice: '
```

The ratchet that actually bites is the rule, not the trailer: the first comment
under `scripts/` that says `slice R5` fails the checker until `R5` has a row
here, so the index cannot fall behind the code that cites it.

## The slices

| slice | commit | date | what it did | design note |
| --- | --- | --- | --- | --- |
| `A1a` | `ebc7688`† | 2026-08-20 | Split the Rules.txt movement cadence away from the navigation tick rate, so folding the two clocks could not silently change how units turn | [Closed 2026-08-20, in phase 3 slices A1a and A1b](network-multiplayer.md#4-one-integer-tick-at-25-hz) |
| `A1b` | `5712714`†, `51aa267` (record) | 2026-08-20 | Folded `UnitNavigationSystem`'s own 20 Hz accumulator into the 25 Hz simulation tick and deleted `NAVIGATION_TICK_RATE`, closing the sixth tick domain | [Closed 2026-08-20, in phase 3 slices A1a and A1b](network-multiplayer.md#4-one-integer-tick-at-25-hz) |
| `B1` | `48e9e21` | 2026-08-20 | Sorted the 96 `delta: float` call sites across 37 files into simulation and view; no behaviour change, the classification was the product | [Slice B1's inventory, 2026-08-20](network-multiplayer.md#order-of-work) |
| `B2` | `b98cc3a`, `3d14e22` (correction) | 2026-08-20 | Moved ground locomotion, terrain snapping and the harvester economy onto the tick, and gave `Unit` its `_simulation_halted` gate | [Updated after slice B2](network-multiplayer.md#order-of-work) |
| `B3` | — | — | Parent of the frame-delta combat group; never a commit of its own, delivered as B3a–B3d | |
| `B3a` | `47eee7d` | 2026-08-20 | Moved projectile flight onto the simulation tick | [Updated after slice B3a, 2026-08-20](network-multiplayer.md#order-of-work) |
| `B3b` | `5d62732` | 2026-08-21 | Moved building firing onto the tick, retiring `Building._process()` and with it the dead-building hole C5 later had to close | [Updated after slice B3b, 2026-08-20](network-multiplayer.md#order-of-work) |
| `B3c` | `4e2cb7d` | 2026-08-21 | Split turret aim into a simulated angle and an applied pose | |
| `B3d` | `e85467f`, `e96185a` (rule) | 2026-08-21 | Completed Fly/Hover transitions on a tick deadline instead of `AnimationPlayer`'s `animation_finished`, severing the flight non-determinism B1 found | [Updated after slice B3d, 2026-08-21](network-multiplayer.md#order-of-work) |
| `C1` | `a438af3` | 2026-08-21 | Added the flat hot-state store `SimEntityState`, indexed by entity id, with nothing writing into it yet | |
| `C2` | `8531049`, `c9e5dc1` (scope) | 2026-08-21 | Made the store authoritative for a unit's position — writes only, readers left owing | [Slice C2's scope, decided 2026-08-21, and the debt it knowingly takes on](network-multiplayer.md#order-of-work) |
| `C3` | `da5a0b8` | 2026-08-21 | Made the store authoritative for health and shields, units and buildings both, through the existing setter chokepoint | [Slice C3, decided 2026-08-21: health and shields](network-multiplayer.md#order-of-work) |
| `C4` | `862ef06` | 2026-08-21 | Made the store authoritative for entity ownership | |
| `C5` | `f2fdf7f`†, `3756462` (scope), `ad4f271` (correction), `479cd1a`† (defect fix) | 2026-08-21 | Deferred entity despawn to a queue the tick drains, so a killed entity stops being simulated at once instead of at end of frame | [Slice C5, decided 2026-08-21: deferred despawn](network-multiplayer.md#order-of-work) |
| `C6` | `6a0be54` (scope) | 2026-08-22 | Parent of the deferred-spawn work; its own commit only recorded the scope and the shared-group problem that split it into C6a–C6c | [Slice C6, decided 2026-08-22: deferred spawn](network-multiplayer.md#order-of-work) |
| `C6a` | `0751182` | 2026-08-22 | Gave the simulation its own iteration source: `"sim_units"`/`"sim_buildings"` joined in code beside the shared view groups, no scene file touched | [C6a introduces "sim_units" and "sim_buildings"](network-multiplayer.md#order-of-work) |
| `C6b` | `8b4c430` | 2026-08-22 | Built `SimAdmissionQueue` and routed the three tick-only groups — projectiles, linger effects, spice mounds — through it | [C6b builds the queue and routes the three joins](network-multiplayer.md#order-of-work) |
| `C6c` | `21cc91c`† | 2026-08-26 | Admitted units and buildings on a tick and gated navigation's own registration on the same drain | [C6c takes "sim_units" and "sim_buildings"](network-multiplayer.md#order-of-work) |
| `B4` | `51e7cd9` | 2026-08-26 | Made the view interpolate between simulation ticks off the store's double buffer, which is what made 25 Hz motion look continuous | [Slice B4, decided 2026-08-26: the view interpolates](network-multiplayer.md#order-of-work) |
| `R1` | `d684e22` | 2026-08-26 | Gave buildings a store-backed position, closing the one hot-state field C2 left on the node | [Slice R1, decided 2026-08-26: buildings get a store-backed position](network-multiplayer.md#order-of-work) |
| `R2` | `0f299de`, `0da1419` (correction) | 2026-08-26 | Added `simulation_position()`, the `global-position-read-bypasses-store` rule, and the queued exempt group that ratchets readers off the node | [Slice R2, decided 2026-08-26: the read accessor](network-multiplayer.md#order-of-work) |
| `R2b` | `6e7a262`† | 2026-08-27 | Pushed a snapshot-restored entity's position back into the store, which `MatchSnapshot` had been assigning to the node only | [Slice R2b, decided 2026-08-27: the snapshot restore](network-multiplayer.md#order-of-work) |
| `R3` | `e7e67f5`† | 2026-08-27 | Migrated the three ground-steering modules' 53 position reads onto `simulation_position()` | [Slice R3, decided 2026-08-27: the ground-navigation group](network-multiplayer.md#order-of-work) |
| `R4` | `b932632` | 2026-08-27 | Migrated 24 of the navigation system-and-shared group's 26 reads, across six modules plus twelve of `UnitNavigationSystem`'s fourteen | [Slice R4, decided 2026-08-27: navigation's system-and-shared group](network-multiplayer.md#order-of-work) |
| `R4a` | `3bea127`† | 2026-08-27 | Hatched the two debug-overlay reads R4 left behind instead of exempting the whole 1100-line navigation facade, raising `allow_budget` 0 → 2 | |
| `R5` | `9e468d3` | 2026-08-27 | Migrated the flight group's 24 reads — `unit_flight_controller.gd` and `air_navigation.gd` — emptying the read rule's navigation queue, and bound the migration on the real path instead of a double for the first time | [Slice R5, decided 2026-08-27: the flight group](network-multiplayer.md#order-of-work) |
| `B5` | `e6becd6` | 2026-08-27 | Stopped `CombatTurret` measuring rules range from the interpolated `visual_root`, which made an in-range verdict depend on frame pacing; buildings deliberately untouched | [Slice B5, decided 2026-08-27: a firing decision](network-multiplayer.md#order-of-work) |
| `R6` | `378ffc6` | 2026-08-28 | Migrated combat's ten entity reads plus both `combat_aim_position()` accessors the rule cannot see, and moved `combat_turret.gd` and `combat_target.gd` to permanent because their reads are of markers, pivots and dead fallbacks | [Slice R6, decided 2026-08-28: the combat group](network-multiplayer.md#order-of-work) |
| `R7` | `8e0efc6` | 2026-08-28 | Migrated the last thirty entity reads across fourteen files and emptied the read rule's queued group, leaving a permanent half and seven hatched lines that have no store entry to read instead | [Slice R7, decided 2026-08-28: the tail](network-multiplayer.md#order-of-work) |
| `D1` | `dff73a7`, `03ff882` (scope) | 2026-08-28 | Moved the availability refresh off `process(delta)` into one phase in the simulation tick, after admission and before the command drain, so a production verdict stopped being a function of how many engine frames ran | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `D2` | `ab8fc5f`, `da472eb` (scope), `45aaa9e` (scope) | 2026-08-28 | Gave every player their own build queue, credits and placed-building ownership through a new `ProductionSystem`, and put the local-player ban in a zone rule over `scripts/production/` rather than an exempt list the checker cannot express | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `D2a` | `7f691dc`, `a1713ee` (scope) | 2026-08-29 | Moved wall chains, their cell evaluation, segment orders, refunds and placement into per-player production, leaving `WallLineSession` the two-click picker and nothing else | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `D3` | `9f7d2d0` | 2026-08-29 | Moved unit availability, producer selection, queues, credits, the population cap and spawned-unit ownership into a new `UnitProductionSystem` keyed by the command's player, and gave the sidebar an explicit progress signal instead of the wallet coupling the building path still relies on | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `D4` | `1316e86` | 2026-08-29 | Moved upgrade queues, credits, the granted purchase and the refinery-dock target into a new `UpgradeProductionSystem` keyed by the command's player, turned the dock target from a held `Node` into an entity id, and split the pure config helpers out to `UpgradeRules` because both the poll and the order read them | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `D5` | `c94415c` | 2026-08-29 | Moved the repair and sale services into `scripts/production/` and gave both the command's player: repairs charge each building's own owner instead of the local player every tick, a non-local sell or repair is no longer refused, and one in-flight sale per player replaces one match-wide | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `D6` | `09163c9` | 2026-08-30 | Widened the building and upgrade candidate catalogs past the local player's house so a remote verdict no longer depends on whose sidebar is drawn, gave building progress an explicit player-keyed signal instead of the wallet channel, and fixed the doubled word in six upgrade messages | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E1` | `2f73104` | 2026-08-30 | Replaced 68 hand-driven calls to Match's private simulation tick across 10 test files -- 36 of them through `call()` by string, which a rename would only have broken at runtime -- with a public `advance_ticks(count)` the frame loop reaches the tick through as well, and put the ban in a new `tests` zone instead of a convention; the injectable driver the plan named for this slice moved to phase 5, where the turn scheduler is its first reader | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E2` | `8f77aa4` | 2026-08-31 | Added a state hash that folds registry liveness first and reads the store through its own `has_*` accessors, so a released entity is absent from it the way it is absent from the simulation, and the frameless-equals-framed gate that makes track E falsifiable; the gate is green, and the two controls beside it are what stop that from being vacuous | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E2b` | `71389ac` | 2026-08-31 | Widened `animation-completes-simulation` from one exact handler name to any handler whose name ends in `animation_finished`, which surfaced six handlers in four files that were invisible to the rule and absent from its audit queue at the same time — `building_placement.gd` among them, where a building becomes functional on frame time; landed before E2a because that id already carried scope decisions | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E2a` | `1d06149` | 2026-08-31 | Moved `BuildingAvailabilityTracker`'s post-`node_added` registration off `call_deferred()` onto the node's own `ready` signal, so a building placed inside a tick dirties the availability cache within that tick instead of at the end of an engine frame; the three deferrals left in place each carry the measurement that says why a frameless run cannot observe them | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E2c` | `4db1e0e` | 2026-08-31 | Moved the clipless deploy completion, temporary invulnerability and both finished-projectile cleanups onto simulation ticks, and staged invulnerability plus its remaining count into `SimEntityState` so the parity gate can bind it — the count matters because two entities with equal booleans and different expiry hash the same today and diverge later | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E3a` | `7a58f65` | 2026-08-31 | Completed deploy transitions on a tick deadline read once from the authored clip instead of waiting on `animation_finished`, and split the rule's list in two after the audit exposed that a cleared file cannot leave a name-matching `exempt` list without turning the checker red — `exempt` stays the unaudited backlog, `cleared` records a verdict and requires a reason | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E3b` | `7287841` | 2026-08-31 | Moved construct, sell, the reversed-construct sale fallback and Construction Yard deconstruct onto `Building`-owned tick deadlines and removed `play_one_shot()`'s completion callback entirely, so the route cannot return; the fallback connected `animation_finished` directly and would have survived a rule written only against `play_one_shot` | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E3c` | `948c61f` | 2026-08-31 | Emptied the `animation-completes-simulation` backlog: `Move_Stop` gained the tick countdown it never had, while the mech start and authored fire completions turned out to be early shortcuts over integrators that already ran every tick — the defect was a differing completion tick, not a missing one, and two long-standing cases were asserting the removed contract | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E4` | `b6ffb1f` | 2026-09-11 | Added `tools/run_headless_match.gd`, the headless entry point that boots a match with no view, loads a recorded replay through new `Match.load_replay()`/`replay_exhausted()` methods validated against both the replay's `scene_path` and its `snapshot_digest`, and drives it to completion through `advance_ticks()` alone; proved two ways, by an API-level test and by running the entry point itself as a subprocess across five scenarios | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `E5` | `b9b8052` | 2026-09-22 | Added `tests/perf/headless_match_perf_run.gd` and `make godot-headless-perf`, which boot `demo_match.tscn` frameless, spawn a 6-vs-6 `ORAPC` mirror match and a 4-tank navigation patrol in code atop the existing 49-building snapshot, and measure sustained ticks-per-second with fail-closed checks on the restore, the population and both workloads; one representative run measured 30.2 ticks/s against the simulation's fixed 25 | [Tracks D and E, decided 2026-08-28](network-multiplayer.md#order-of-work) |
| `F1` | `c89d585` | 2026-09-22 | Added `tests/sim/replay_determinism_run.gd`, proving the same-process half of the Phase 4 CI test: the same replay loaded into two `MatchFixtureScene` arms run strictly one at a time — booted, driven and hashed, then torn down with `frameless_parity_run.gd`'s own `SIM_GROUPS`-empty assertion before the next boots — ends with equal `SimEntityState.state_hash()` values, with a control proving two different replays hash unequal; portable math and the RNG split were found already satisfied vacuously, and the native-vs-web comparison half was left for its own slice | [`F1` — landed, the same-process half](network-multiplayer.md#order-of-work) |
| `F2` | `bb9d932` | 2026-09-23 | Fixed two tick-domain races in `entity_id_run.gd`'s sim-group-removal case: both its unit and building admission checks asserted `sim_units`/`sim_buildings` membership right after an awaited frame with no explicit tick, so the result depended on incidental frame-to-tick timing — found and reproduced while landing `F1`, not from any of the usual three sources; verified with 22 consecutive standalone runs plus a full suite pass | |
| `F3` | `24ee930` | 2026-09-23 | Added `tools/web_replay/check_headless_boot.js` and `make godot-web-headless-check`, which export the Web preset, serve it locally with COOP/COEP headers, boot it in headless Chromium via Playwright, and wait for the native boot's own `MapLoader:` console line — proving real GDScript ran inside the WASM build. Mechanism (Playwright/headless Chromium) decided by the human after a bare WASM host was ruled out; the server tears down on every exit path, verified by a deliberate-failure run and a clean recovery after it | [`F3` — landed, the first step of the web half](network-multiplayer.md#order-of-work) |
| `F4` | `0719e9f` | 2026-09-23 | Added `scenes/dev/web_replay_check.gd` (extends `Match` directly) and two scenes/fixtures/presets proving a replay loads inside a dedicated web entry point, never `demo_match.tscn` — decided in conversation, mirroring native's `tools/run_headless_match.gd` boundary. The failure scene instances the success scene and overrides only `replay_path`, pointing at a fixture whose header names the failure scene itself with a deliberately wrong `snapshot_digest`, since `ReplayPlayer.load()` checks `scene_path` first; two Godot per-feature `run/main_scene` overrides select the right scene per export preset, each with its own `include_filter` since `.oebr` is not a Godot resource type | [`F4` — landed, a replay reaches the web build](network-multiplayer.md#order-of-work) |
| `F5` | `8c5b2c9` | 2026-09-24 | Drove a replay to completion inside the web build: `web_replay_check.gd` disables its own processing as the first statement of `_ready()` (no external caller to do it, unlike every native headless harness), settles two frames after `super()`'s unawaited `_place_on_map()` and fail-closes on `has_position()` before trusting any position, then drives `advance_ticks()` in bounded 64-tick chunks yielding three `process_frame`s between them — each checked against `Engine.get_process_frames()` to prove a real engine frame boundary was crossed, not just that an `await` sat in the source, since a browser tab cannot block on an unyielding `advance_ticks()` the way a native process can without risking Chromium treating the page as unresponsive. `web_replay_check_ticks.tscn` drives its two-record fixture to `ticks=192` across three chunks, reporting `moved=true` and a `state_hash()` reproduced identically across four independent runs | [`F5` — landed, a replay runs to completion inside the web build, and a hash comes back out](network-multiplayer.md#order-of-work) |
| `F6` | `4698c68` | 2026-09-24 | Closed Phase 4: `tools/run_native_replay_hash.gd`, a `SceneTree` wrapper, reuses `web_replay_check_ticks.tscn` unmodified and waits on `replay_exhausted()` **and** `current_tick() > 0` — `ReplayPlayer.is_exhausted()` reads `true` vacuously before any `load()`, so `exhausted()` alone would have matched the boot-settle window and hashed the wrong state — selecting a scene via a `--scene=<path>` CLI user-arg rather than an env var, since `tools/godot-container`'s `podman_base_args()` has no `--env`/`--env-host` to cross the container boundary. `tools/compare_replay_determinism.sh` extracts each side's hash with a marker-specific pattern, since the native process's own stdout also carries the child scene's own `WEB_REPLAY_CHECK_RESULT` line, and propagates a failed run distinctly from a mismatch; both hashes matched `F5`'s own `3366564294`, with two controls (`WEB_REPLAY_HASH_OVERRIDE`, `--scene=web_replay_check_failure.tscn`) each proving a different failure mode | [`F6` — landed, the comparison itself, closing Phase 4](network-multiplayer.md#order-of-work) |
| `G1` | `5e6bbf2` | 2026-09-25 | Corrected `network-multiplayer.md`'s stale claim that `UnitLocomotion`'s mech gait was "already known to be defective." Re-read `git show 948c61f -- scripts/units/unit_locomotion.gd` (slice `E3c`) in full rather than trusting the commit message alone: `STARTING` did have a real race — the pre-`E3c` tick-driven `advance_start_transition()` competed with a frame-paced `animation_finished` branch for the same `_begin_mech_move()` call, so completion tick depended on frame pacing — while `STOPPING` was the genuine no-fallback liveness defect. `E3c` fixed both (`_stop_remaining_ticks`, confirmed still live in the current file), and `animation-completes-simulation`'s `exempt` list has read `[]` ever since; the doc had never caught up | |
| `H1` | `08597b8` | 2026-09-25 | Opened Phase 5: `scripts/net/turn_scheduler.gd` bridges a `SimCommandBus` to a `NetTransport` with a fixed input delay, framing the bus's own computed target tick as a big-endian `u32` prefix ahead of `SimCommandCodec.encode(command)`'s bytes and discarding `LoopbackHub.route()`'s own echo of a client's sends back to itself, rather than resubmitting it. `tests/net/turn_scheduler_run.gd` checks the delay and the wire bytes against independently computed values, not a round trip, then proves two sequentially-run `Match` instances (concurrent liveness ruled out — `_advance_simulation_tick()` reads `SceneTree`-global groups) reach equal `SimEntityState.state_hash()` after one submits a command the other only ever receives through the transport, with a differing-target control. Decomposition (fixed delay first, deferring adaptivity/checksums/stall-drop/reconnect/lobby/live UI wiring) confirmed by human decision 2026-09-25 | [`H1` — landed, a fixed-delay turn scheduler proven over a real transport](network-multiplayer.md#order-of-work) |
| `J1` | `867cdb5` | 2026-09-26 | Added a one-byte discriminator ahead of `TurnScheduler`'s wire format (`0` = command, unchanged in substance; `1` = a new checksum report) and `scripts/net/checksum_exchange.gd`, pure per-tick hash bookkeeping fed by `TurnScheduler`'s own dispatch — kept as the transport's sole poller rather than letting a second class race it for frames. `ChecksumExchange` resolves either arrival order (a remote report before or after the matching local hash is recorded), needed because the sequential two-arm proof this reuses from `H1` delivers a whole run's reports in one batch. `tests/net/turn_scheduler_run.gd`'s `_run_pair()` keys every hash by `match.advance_ticks(1)`'s own return value rather than its loop's zero-based counter — both arms making the identical off-by-one would still have agreed with each other — and proves genuine bidirectional agreement: a final poll against client A's already-torn-down `Match` (the scheduler and exchange outlive it) resolves client B's reports too, both `agreement_count()`s reaching every tick with nothing left pending. Deliberately scoped to one remote peer; decomposition (checksums next, ordering of the rest left to the architect) confirmed by human decision 2026-09-25 | [`J1` — landed, live checksum exchange between two clients](network-multiplayer.md#order-of-work) |
| `K1` | `d4197cc` | 2026-09-26 | Gave `TurnScheduler.advance_tick()` a required `current_tick` parameter (breaking, safe — nothing outside this track's own tests called it) and a `last_remote_activity_tick()` observable, updated on any successfully-decoded, non-echo frame of either kind — including a checksum report with no `ChecksumExchange` wired to route it to, since the sender was still real even though this client had nowhere to put the report. `J1`'s own per-tick checksum cadence is what made this buildable at all: it resolved the exact conflict that made stall/drop look hard when `H1` first deferred it, giving decision 8's "when a player's frames stop arriving" a heartbeat to watch for with no new wire concept needed. No threshold or response (decision 8 names no timeout value anywhere in the doc); proving it required capturing client A's own final tick explicitly before `_teardown_arm(match_a)`, since `match_a` — the only thing that ever owned its clock — is gone by the time the cross-poll against client B's reports happens | [`K1` — landed, observable liveness tracking in `TurnScheduler`](network-multiplayer.md#order-of-work) |
| `L1` | `a137a62` | 2026-09-26 | Corrected decision 9's stale claim that 2v2 "still needs... friendly-fire rules." Found while investigating the lobby as a candidate next slice (room codes and connectivity turned out already fully built and tested at the relay level) and verified directly: `CombatTarget.are_friendly()` already calls a source's `is_allied_with()` when available, and both `Unit`/`Building.is_allied_with()` already route through `player_roster.gd`'s own `are_allied()`, predating this network track entirely (`combat_impact_resolver.gd`'s first commit, `30e3d93`, "warheads"). Lobby-side team assignment and a team-aware victory condition — confirmed genuinely missing, grepped the whole tree — stay named as owed in the corrected sentence | |
