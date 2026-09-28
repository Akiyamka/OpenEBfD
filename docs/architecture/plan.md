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
| P1 | Give `Match` a real `TurnScheduler` over a null transport, and route local input through it | Turns Phase 2's own prose ("single-player runs with input delay 0 over a null transport") into a landed, tested fact, and is Phase 5's own explicitly named remaining item -- "wiring live UI input through the scheduler" -- named as untouched in `H1`, `J1`, `N1` and `O1`'s own paragraphs. Deliberately the same incremental shape as the rest of this track: prove the mechanism over a trivial substrate (a real, landed `NullTransport`) before a later slice swaps in a real one. Does **not** by itself unblock applying `O1`'s RTT recommendation or `K1`'s liveness tracking to live play -- both need a real transport carrying real peer traffic, which needs the relay/lobby connection, a larger and more product-shaped undertaking left for its own slice(s). All four command-issuing controllers (`BuildingController`, `BuildingUpgradeController`, `UnitCommandController`, `UnitRosterController`) already submit only for `players.local_player_id` today (verified by reading every call site), so retargeting their submission through `TurnScheduler.submit_local()` is a behaviour-preserving substitution, not a new policy | `network-multiplayer.md`, Phase 5 (netcode) and Phase 2's own "null transport" line | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
