# Slice plan

The queue of work, ahead of the tree. Its opposite number is
[`slices.md`](slices.md), which is history: a slice moves from this file to that
one when it lands.

**This file is owned by the architect role** of the slice pipeline
(`tools/pipeline/run.sh`, brief in `tools/pipeline/roles/architect.md`). It is
the one place the pipeline keeps a plan, and it is plain markdown on purpose —
no second rendering of the queue anywhere else, so there is nothing to keep in
sync and nothing that can quietly disagree.

## What this file is not

It is **not** the source of truth for what the project owes. That lives where it
is machine-checked, and the architect derives this queue from it each time:

1. The `exempt` lists in [`tools/architecture_rules.toml`](../../tools/architecture_rules.toml)
   — a queued group is a file list that shrinks as slices empty it. This is the
   most honest backlog in the repo, because a stale entry fails a check.
2. `## Order of work` in [`network-multiplayer.md`](network-multiplayer.md) —
   the prose argument for what comes next and why.
3. [`docs/open_questions.md`](../open_questions.md) — decisions that may have to
   become slices of their own before anything downstream can move.

A row here is a *reading* of those three, made concrete enough to hand to an
implementer. When they disagree, the row says so rather than picking a winner
silently.

## Queue

Ordered: the top row is the next slice out. A row carries only what is needed to
decide *whether it is next* — the full brief is written to `.pipeline/slice.md`
when the slice is actually handed out, and is not duplicated here.

| id | title | why now | source | status |
| --- | --- | --- | --- | --- |
| AP8 | Advance undeploy turret recentering on the simulation tick | `Unit._process(delta)` started the undeploy clip when frame-timed recentering finished; AP8 moved the decision onto admitted unit ticks and kept frame-only pose repaint. Full runner passed 105 suites; the noisy throughput gate was waived under the human's 2026-10-26 standing rule after a 5.7 µs active-call measurement | Human audit; `unit.gd` and `unit_deploy_state.gd` | landed — `0477489` |
| AO2 | Resolve projectile hits on units from tick positions | Both `CombatProjectile._collisions_between()` and `_swept_collisions_between()` query unit colliders during sim ticks. The same measured broadphase lag can change direct and piercing damage; projectile hit ordering and collision geometry need their own acceptance cases | AO1 audit of `combat_projectile.gd`; decision 7's determinism obligation | queued |
| AO3 | Resolve splash candidates on units from tick positions | `CombatImpactResolver._splash_targets()` uses `intersect_shape` against unit colliders during sim ticks. A lagging broadphase can change who takes splash damage, independently of AO1's firing-position order and AO2's projectile path | AO1 audit of `combat_impact_resolver.gd`; decision 7's determinism obligation | queued |
| AP9 | Remove navigation angle math and instance-id fallback on tick paths | `AttackArcAllocator` uses libm angles and a process-local instance-id fallback; `OrcaAvoidance` calls `Vector2.angle()` on a sim path | AN1 audit; decision 5's portable-math obligation | queued |
| AP10 | Make failed replay loads preserve the prior cursor | `tests/sim/replay_player_run.gd` claims cursor preservation but its baseline has no records; load a record, advance its cursor, then reject a malformed replay so moving `_records`/`_next_index` before validation fails the case | AP1 review of `scripts/match/replay_player.gd`; decision 7 replay reliability | queued |
| AP11 | Reject unrepresentable replay draw counts before installation | `scripts/match/match.gd::load_replay()` ignores a false `SimRng.restore_audit()` result; a format-2 header with count at or above 2^63 can return `ok=true` while leaving the old audit beside the new seed. Validate in `scripts/match/replay_file.gd` and fail without changing player or RNG state | AP1 review; replay metadata contract | queued |
| AP12 | Stop polling queued frames after a terminal halt | `scripts/match/match.gd::advance_ticks()` polls gathered START frames before its halt check; `scripts/net/turn_scheduler.gd::poll_start_frames()` stashes later horizon keepalives forever after a desync halt, about three entries per second. Halt before polling or stop stashing at terminal state | AP1 review; decision 7 terminal desync response | queued |
| AP13 | Give carried targets a tick-owned aim position | A carried Unit stays targetable as airborne while its body is reparented below the carrier's interpolated/tilted `VisualRoot`; its stored position remains at pickup and its world basis changes with the render pose. AP2 can freeze the unit's authored centre but cannot truthfully infer a flying cargo position from that stale store entry | AP2 audit of `unit.gd::transport_attach_cargo()`, `combat_aim_position()` and `combat_is_airborne()` | queued |
| AP14 | Classify Kobra targets its deployed gun cannot aim at | After AP2's full held-muzzle geometry, targets 2.3–2.8 world units from Kobra's hull are reported `IN_RANGE` although `aim_at()` cannot align below its pitch stop (`_pitch_limit_error > 0.01` at 2.5); 1.0–2.2 report `TOO_FAR`, while 2.9+ can align. Make acquisition report the pitch-limited band honestly without changing the valid firing band | AP2 coder measurement in `tests/combat/deploy_fire_run.gd`; approved code-review minor finding | queued |
| AP15 | Give building turrets tick-owned combat pose | AP3 moves the call onto a tick, but `CombatTurret.emission_points()`, `_aim_origin()` and launch still read live building markers changed by `StatePlayer`, popup and Fire clips between ticks. Capture per-state authored rest and deterministic popup hold geometry while retaining rendered muzzle effects | AP3 audit of `combat_turret.gd`, `building.gd` and AP2's live-building-muzzle limit | queued |
| AP16 | Break equal-distance acquisition ties by stable entity ID | `CombatTargetAcquisition.target_for()` is shared by units and buildings and uses `get_instance_id()` when two usable enemies are equally distant; those IDs differ by process and can select different targets despite identical tick state | AP3 audit of `combat_target_acquisition.gd:125`; entity ID contract | queued |
| AP17 | Bound idle defensive-turret tick cost as counts grow | AP3 adds about 55 us per idle defensive turret per tick; 50 cost about 2.8 ms of a 40 ms tick. Profile shared acquisition/servo work. AP4's expiry adds about 12–14 us once per 3–5-second interval: nearly all is two AP1 `SimRng.unit_fraction()` draws at about 4.9 us each versus 0.04 us for native `randf_range()`. A flatter sampler measured 3.3 us/draw (about 32% cheaper) with identical output on 1000/1000 keys. AP5 adds 45–61 us per successful fire-sequence start; about 8 us is avoidable in `scripts/units/unit_combat.gd` (`_eligible_fire_bindings()` re-sorts an already canonical list for 6.5–6.7 us and repeats path lookups for about 1.7 us). Optimize these without changing keyed results or live deploy-state eligibility | AP3/AP4/AP5 reviewer cost attribution; human performance waivers | queued |
| AP18 | Stabilize the alternating combat benchmark harness | The power-limited Intel N200 usually depresses the first run of each arm, and the absolute 0.6 ticks/s stability cutoff is tighter than normal host spread. Evaluate discarding each arm's first run, more interleaved runs, robust spread and relative tolerance like AO1's scaling gate, and optional CPU pinning. Human is not asking for this tooling change now | AP4 A5 waiver and reviewer measurement | queued |
| AP19 | Assert unit turret RNG wiring through real Match ticks | `tests/match/turret_idle_rng_run.gd` directly calls the real unit's `idle_scan()` while Match processing is disabled; the building START case does exercise real ticks. Add a unit case that boots Match and reaches `UnitCombat.advance()` without directly scanning, then mutate that call to prove the test fails | AP4 code review's A2 coverage finding | queued |
| AP20 | Harden AP5 fire-variant regression timing and global-RNG contrast | In `tests/match/unit_fire_variant_rng_run.gd`, P-pair's two arms currently end with identical global-random state (`noise_count` 12 is even), so its name checks do not catch a global-`randi()` selector although other AP5 cases and its audit do; give the arms different final global states and prove the names diverge under that mutation. W-tick's comment says the shot commits on the next tick and asserts only after tick 2, but an instrumented run shows `next_shot == 1` already on start tick 1; assert zero before the start and one immediately after it, then mutate a one-tick delay to prove the check binds | AP5 code-review minors in `tests/match/unit_fire_variant_rng_run.gd` | queued |
| AP21 | Pin independent survivor scatter extents in the Match regression | `tests/match/building_survivor_rng_run.gd` computes expected positions with production `_footprint_half_extents()`, so mutating `SPAWN_SCATTER_MARGIN` to zero leaves it and `building_death_run.gd` green. Assert the ConYard footprint half-extents from an independent literal or `collision_bounds` and prove that mutation fails. The ScoutA control has one turret but makes zero audited draws through tick 1 in both arms, so its current six-draw kill-minus-control comparison cancels nothing; retain the control for future turret draw changes | AP6 code-review minor and audit observation | queued |
| AP22 | Hash and dump world spice state | `Match.match_checksum()` folds entity state and the AP1 RNG audit, not mound countdowns, contact-entry sets, active spread/hazard jobs or spice cells; AN1's retained dump omits them too. AP7 removes the observed timing sources and compares peers directly, but a future spice-state defect could escape a checksum interval. Define a stable world-state digest and matching dump coverage without moving Node state into `scripts/sim/**` | AP7 planning audit of `match.gd`, `map_spice_layer.gd`, `match_snapshot.gd` and AN1 dump | queued |
| AP24 | Pin rejected mound contact until exit and re-entry | A unit whose fresh contact is rejected below 30% maturity is consumed until it leaves the mound for a tick. `tests/match/spice_mound_rng_run.gd` exercises rejection and later re-entry, but reviewer mutation X1 makes a parked rejected unit retry every tick and all 25 assertions stay green. Add a parked-through-30% case and prove X1 fails | AP7 code-review minor in `tests/match/spice_mound_rng_run.gd` | queued |
| AP25 | Stabilize the navigation worst-tick timing bound | `tests/navigation/run.gd:2157` rejects a single `NavigationSystem` tick over 100 ms with 16 `FakeUnit`s; a loaded Intel N200 produced 109.64 ms once, while standalone and full reruns passed. Harden or relax that wall-clock bound without hiding a real navigation slowdown | AP7 coder run and reviewer isolation of unrelated timing failure | queued |
| AP26 | Make cold mound contact independent of total unit count | AP23's warm-or-scan hybrid removes mound scans only when AO1's grid is already current; peaceful and movement-only ticks still pay AP7's linear per-mound scan. Design a persistent index that updates from units whose stored position/profile/carried state or admission changed, while retaining static units across ticks, so a cold mound can query local candidates without rebuilding all units or changing AP7 contacts | Human AP23 hybrid decision 2026-10-28; follow-up explicitly owed | queued |


**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
