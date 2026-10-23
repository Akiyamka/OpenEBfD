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
| AO1 | Decide friendly firing-line occupancy from simulation positions | The fourth two-process run stopped at tick 1160 with identical command streams and a matching checksum at 1152. Unit 25 alone has an extra combat-originated firing-position order on player 2; a headless probe confirmed that a moved `CharacterBody3D` retains its old physics-ray position until the next physics frame. The firing-line ray can therefore disagree within catch-up ticks and trigger `UnitAttackOrder.hold_firing_position()` on one client. AO1 makes this decision from post-movement stored positions and a local candidate grid; other dynamic-collider sites stay separately queued | human direction 2026-10-21 over the empty exempt backlog; decisions 7/8 and AN1 dump | landed — `pending` |
| AO2 | Resolve projectile hits on units from tick positions | Both `CombatProjectile._collisions_between()` and `_swept_collisions_between()` query unit colliders during sim ticks. The same measured broadphase lag can change direct and piercing damage; projectile hit ordering and collision geometry need their own acceptance cases | AO1 audit of `combat_projectile.gd`; decision 7's determinism obligation | queued |
| AO3 | Resolve splash candidates on units from tick positions | `CombatImpactResolver._splash_targets()` uses `intersect_shape` against unit colliders during sim ticks. A lagging broadphase can change who takes splash damage, independently of AO1's firing-position order and AO2's projectile path | AO1 audit of `combat_impact_resolver.gd`; decision 7's determinism obligation | queued |


**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
