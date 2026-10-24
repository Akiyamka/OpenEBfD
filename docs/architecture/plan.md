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
| AP3 | Move building target acquisition and engagement decisions onto ticks | `Building._process(delta)` still chooses targets, aims and starts fire sequences with render-frame timing; seed agreement cannot fix that path | Human audit; `BuildingCombat.advance()` and `Building.sim_tick()` | landed — `pending` |
| AP4 | Key turret idle-scan draws by seed and stable turret identity | `CombatTurret.configure()` randomizes a process-local generator; unit tick scans and building scans (after AP3) can shift fire ticks | Human audit; `combat_turret.gd` idle scans | queued |
| AP5 | Key authored unit fire-clip selection | `UnitCombat.fire_animation_binding()` uses global `randi()` and different variants can carry different shot times; overlay setup also calls this selector | Human audit; `unit_combat.gd` and `unit_fire_overlay.gd` | queued |
| AP6 | Key building-survivor placement | Two global `randf_range()` draws put survivors at different hashed positions after a qualifying building dies | Human audit; `building_survivors.gd` | queued |
| AP7 | Key spice-mound maturity and tick its contact activation | `SpiceMound.configure()` and `_ready()` draw before gathered START, while `body_entered` activates from physics frames; both can change bloom/spice ticks | Human audit; `spice_mound.gd` and `map_spice_layer.gd` | queued |
| AP8 | Advance undeploy turret recentering on the simulation tick | `Unit._process(delta)` starts the undeploy clip when frame-timed recentering finishes, changing when the unit may move again | Human audit; `unit.gd` and `unit_deploy_state.gd` | queued |
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
| AP17 | Bound idle defensive-turret tick cost as counts grow | AP3 adds about 55 us per idle defensive turret per tick; 50 cost about 2.8 ms of a 40 ms tick. Profile and reduce shared acquisition/servo work without losing tick timing or view behavior | AP3 reviewer cost attribution; human A8/A9 waiver on 2026-10-24 | queued |


**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
