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
| AJ1 | Delete the placement teleport | The last of decision 12. With `AI1` landed, all four production call sites that reach `_spawn_placed_building()` ask `has_any_unit_in_footprint()` first and defer, wait or refuse, so the teleport has nothing left to move -- measured 2026-10-10: disabling it fails exactly one assertion in the whole suite, the bypass case built to observe it, which this slice inverts into the control for the deletion. It also takes `unit_push_aside.gd` off `global-position-bypasses-store`'s exempt list outright, since the shove's fallback was that file's only direct position write. Decision 12's **Still owed** line under-states the cascade: with `unused_parameter=2` the deletion takes two parameters and an argument, not one parameter, so the brief follows the code and the land corrects the doc. The shove walked `units` where the gates walk `sim_units`, so a unit not yet admitted is the one thing it could still have reached; traced unreachable, and recorded rather than built for | `network-multiplayer.md` decision 12, item 4; `tools/architecture_rules.toml`, `global-position-bypasses-store` exempt list | landed — `pending` |


**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
