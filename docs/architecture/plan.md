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
| AG1 | Walls and MCV deployment ask the placement authority before spawning | Human decision 2026-10-08: the two paths that bypass the placement authority are to be wired through it with real test coverage, not left as a permanently exempt pair. Both are taken in one slice because the change is the same shape in both places and asks the same question -- an **immobile** unit in the footprint refuses, reusing a refusal outcome each path already has: the wall chain's existing `CANNOT_BUILD` branch, which already refunds the order, removes the marker, emits `SKIPPED`/`FINAL_SKIPPED` and advances the chain; and the MCV flow's existing `_abort_deployment()`. So no new outcome, no new status string, no pending state and no reservation. It is also the slice that closes `AA1`'s oldest named gap -- *"walls deliberately unchanged ... a wall segment still engulfs"* -- and supplies the coverage `AF1`'s measurement proved missing, which is the stated prerequisite for ever deleting `UnitPushAside`'s teleport. Deliberately **immobile-only**, not any-unit: a wall chain skips a blocked segment permanently and a deploy aborts outright, so deferring on a unit that is merely passing through would cost a segment or a deploy where today it costs nothing. Widening walls to any-unit needs item 6's wait first, and `has_any_unit_in_footprint()` is used by neither path here | human decision 2026-10-08; `network-multiplayer.md` decision 12, item 4's remaining half, and `AF1`'s land measurement | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
