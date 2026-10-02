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
| X1 | Per-peer liveness and a stall verdict naming the player, observable only | Unblocked by a human decision 2026-10-02: decision 8's stall threshold, which `K1`'s paragraph recorded as named nowhere in the document, is **10 checksum-cadence cycles** -- 80 ticks, 3.2 s at 25 Hz -- stored as a cycle count so it rescales with `CHECKSUM_INTERVAL_TICKS` instead of drifting out of sync with it. Detection only: decision 8's response is "the match pauses with an explicit UI state naming the player", and this track has no UI layer and is never getting a lobby one, so building the pause here would either invent a player-facing surface or freeze a match with nothing to explain why -- worse than not pausing. Needs the liveness widening in the same slice because decision 8 names *the player* and `TurnScheduler._last_remote_activity_tick` is a single value conflating every sender; a two-peer-only verdict would repeat exactly the scope choice `M1` had to undo in `ChecksumExchange`. The widening is semantics-preserving: the existing no-argument accessor becomes the max over senders, which is what a single overwritten value already meant, so all 13 of its existing assertions stand unchanged as the regression guard | `network-multiplayer.md`, decision 8; human decision 2026-10-02 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
