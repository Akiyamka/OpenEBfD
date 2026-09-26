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
| K1 | Detect a stalled peer: observable liveness tracking in TurnScheduler | `J1` (`867cdb5`) landed checksum reports sent every tick, which resolves the exact conflict that made stall/drop look hard when `H1`'s own deferral was written: decision 8's "when a player's frames stop arriving" now has a per-tick heartbeat to watch for, with no new wire concept needed. Its own pause/timeout/drop/freeze response still needs live-match wiring this track has deliberately avoided (the same gap that keeps "wiring live UI input" itself premature) -- but observing the gap, the same observable-only split `J1` already drew for a hash mismatch, is buildable now, reusing everything already landed. No exact timeout value is specified anywhere in the doc (checked: only "after a timeout" appears), so this slice exposes the raw fact and invents no policy. Ordering among `H1`/`J1`'s deferred items was explicitly left to the architect by human decision 2026-09-25; adaptive delay was also considered and set aside for now, since decision 8's own "worst round-trip in the room" phrasing is multi-peer-flavored where this track has stayed deliberately two-peer, and it would need an entirely new ping/pong wire concept where this needs none | `network-multiplayer.md`, `## Order of work`, Phase 5, decision 8 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
