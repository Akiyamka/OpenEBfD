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
| AA1 | An immobile unit inside a building's footprint refuses the placement instead of being engulfed by it | The `open_questions.md` entry that asked phase 5 for "one rule for the class" of local view state racing a submitted command has a stale premise: the right-click cancel its example describes no longer reaches a committed placement, because `BuildingController._committed_placement_cell` locks the mode from submission until execution. Human decisions 2026-10-04 and 2026-10-05 replaced the question with a concrete mechanic instead -- placement becomes a pending simulation state with a per-tick confirmation and a five-second deadline, the reserved cells become no-stop for every player so a parked scout cannot deny a site for free, idle units inside walk out instead of being teleported, and the ready-building icon gains a third non-interactive state. This is the one piece of that mechanic with no dependency on the pending state, it is required under every variant discussed, and it closes a hole `unit_push_aside.gd` admits in its own comment: a deployed unit is skipped by the shove and ends up inside the building. It also shrinks what follows, because once an immobile unit can never stand in a completed footprint the later eviction rule has only mobile units to move. Id is `AA1` because A-Z at digit 1 are now spent and `A2` already reads as "the second slice of track A" in phase 3's scheme | `docs/open_questions.md` ("What happens to local view state that races a command already submitted", premise now stale); human decisions 2026-10-04 and 2026-10-05 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
