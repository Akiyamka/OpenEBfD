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
| J1 | Phase 5's second slice: which deferred piece next (tentative — see `.pipeline/slice.json`'s `blocked_on`) | `H1` (`08597b8`) proved the turn scheduler in isolation and named five deferred pieces plus live UI wiring, with no ordering among them the way `F5`→`F6` or `G1`'s own finding had. Investigating each surfaced real interdependencies before a brief could be written: live checksum exchange would need a message-type discriminator added to `TurnScheduler`'s already-landed, already-tested wire format; the stall/drop state machine likely needs a per-turn heartbeat frame, which conflicts with `H1`'s own deliberate choice to skip sending on ticks with no local command; wiring live UI input needs a decision about how a match acquires a transport at all, which the lobby piece hasn't settled yet. Sent back for a human decision the way the original Phase 5 decomposition was, rather than picked silently | `network-multiplayer.md`, `## Order of work`, Phase 5's `H1` paragraph, plus decisions 6, 8, 9 and 10 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
