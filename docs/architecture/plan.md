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
| G1 | Correct the stale mech-gait defect claim in network-multiplayer.md | `F6` (`4698c68`) closed Phase 4; re-reading `## Order of work` for what comes after it turned up a factual error sitting right where Phase 5 begins: the "Carried in from phase 3" paragraph still calls `UnitLocomotion`'s mech gait "already known to be defective," describing a `STARTING` race and a `STOPPING` liveness bug with "no tick-driven fallback at all." Slice `E3c` (`948c61f`, 2026-08-31) fixed both, and `tools/architecture_rules.toml`'s `animation-completes-simulation` rule has carried `exempt = []` ever since — confirmed against the current `scripts/units/unit_locomotion.gd`, which has `_start_remaining` and `_stop_remaining_ticks` countdowns for exactly these branches. All three canonical sources are otherwise quiet: every `exempt` list in the manifest is empty, `open_questions.md` holds only unrelated XBF/FX content, and Phase 5 (netcode) is large enough that its first slice deserves its own considered cut rather than a rushed guess here. A doc that misrepresents a three-week-old fix as a live desync risk is smaller and more defensible to close first | `network-multiplayer.md`, `## Order of work`, Phase 4's trailing "Carried in from phase 3" block | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
