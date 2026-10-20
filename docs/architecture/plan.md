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
| AN1 | A desync halt dumps entity state at the diverging tick | Human-directed, 2026-10-20, taking precedence over the exempt lists (the queue was empty after `AM1`). The third two-process run halted both clients at tick 1008 with identical `AL1` dumps -- player 1 executed 9 commands, player 2 none, nothing late, nothing in the last 80 ticks, checksum 1000 agreed -- which is `AL1`'s row (d): the simulation itself diverged with no new input, the genuine nondeterminism only a state dump can localise. So decision 7's owed **entity-state dump** lands, terminal only: at a halt each client prints a `[desync-state]` block holding every live entity's hashed fields as the exact bytes `state_hash()` folds, plus each unit's navigation state and each turret's aim, which are not hashed but are exactly what explains a position or health that differs. It prints the state **as of the mismatched checksum tick**, from a ten-entry ring captured at each checksum tick, because under `AM1` two clients can halt up to an effective delay apart and a dump of two different ticks would differ everywhere. Captured only when a room is set; single-player is byte for byte unchanged, and `scripts/sim/` is untouched. The planning audit found nothing in the navigation layer that differs between two processes on one machine, and found per-process randomness in turret idle scans and building survivors; those fixes wait until the dump has located this divergence | human direction 2026-10-20; `network-multiplayer.md` decision 7 ("On desync") and `AL1`'s owed list | landed — `pending` |


**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
