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
| AI1 | An MCV deploy waits for a unit that can leave instead of aborting | The human decision of 2026-10-08, and the last thing holding `UnitPushAside`'s teleport alive now that `AH1` has freed the wall path. The deploy adopts the same two-branch split `AH1` gave walls -- `AG1`'s immediate abort for an immobile unit, a pending state with a no-stop reservation for any other -- which is what makes `AJ1` possible: with both bypass callers deferring on any unit, nothing mobile reaches `_spawn_placed_building()`. Bigger than `AH1` in exactly two ways, and that is the whole of its risk: `UnitDeploymentController` is driven by an animation signal and joins no tick, so its wait needs a place in `Match._advance_simulation_tick()`'s fixed order and a case that proves the central loop reaches it, and its reservation is a second source behind the single provider `NavBlockerTracker` holds, which `Match` unions rather than teaching navigation about a list. The order-change check the 2026-10-08 decision named as the only new logic is **deliberately not built**, by the human decision of 2026-10-09: no input can change a deploying MCV's order today -- the move filters drop a deploying entity at both layers, a stop order is a no-op on one, and an attack or second deploy is refused -- so the check could never fire, and a pending deploy is uninterruptible exactly as the animation and `AH1`'s waiting wall segment already are. Interruptibility is a slice of its own if it is ever wanted | human decisions 2026-10-08 and 2026-10-09; `network-multiplayer.md` decision 12, item 4's remaining half | landed — `pending` |
| AJ1 | Delete the placement teleport | What is left of decision 12's item 4 once `AI1` lands. `AH1` already removed the wall path's need for the shove, so `AI1` is the last gate: with it, nothing mobile reaches `_spawn_placed_building()` and `UnitPushAside.push_units_out_of_footprint()`'s `set_simulation_position()` write has nothing to do. Two facts measured while landing `AF1` belong here and are recorded in decision 12 rather than in this row: the write cannot be deleted alone, because it is the only consumer of `excluded_unit`, which GDScript then reports as an unused parameter; and the coverage it needs is what `AH1` and `AI1` add, since before them deleting the call failed exactly one assertion in the whole suite | `network-multiplayer.md` decision 12, item 4's remaining half | queued |


**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
