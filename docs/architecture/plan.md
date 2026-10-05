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
| AB1 | The ready-building icon shows a third, non-interactive state while its placement command is in flight | Decision 12's item 5, and the only piece of it that needs no pending state: the window it describes already exists today and is `input_delay_ticks` long, which `Z1` made adaptive with no ceiling. Between submission and execution the icon is unchanged -- still `READY` at 100 percent with the caption `PLACE` -- because `_try_place_ready_building()` never refreshes the option states after submitting, so the player gets no local echo at the one place they are looking. Worse, `_begin_ready_building_placement()` is the one input path with no `_committed_placement_cell` guard, so clicking the icon again during the window re-begins the preview, emits a false "placement ready", and resets the rotation to zero while the committed command carries the old one -- the pinned preview then shows the wrong orientation until execution. `AA1`'s land step recorded that `AA1` closed this fourth path; it did not, and decision 12 is corrected in this round's refresh. Lands the icon half of the mechanic against today's short window so that when the pending state arrives the same state simply lasts longer | `network-multiplayer.md` decision 12, item 5; human decision 2026-10-05 confirming a separate enum value rather than a reused `PROGRESS` | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
