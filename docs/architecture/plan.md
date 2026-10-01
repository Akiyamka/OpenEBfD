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
| W1 | Bound `ChecksumExchange`'s per-tick retention, counting what it discards | The last Phase 5 item that needs no new human decision, which is why it goes now. `U1` gave the exchange a live sender and recorded the debt: `_local_hash_by_tick` and `_pending_remote_hash_by_tick` are never cleared, so a live match grows them at about 3.1 entries per second for as long as it runs, and `V1`'s halt only stops that in the desync case -- a healthy match grows forever. The retention window is derivable from the document rather than chosen: "Starting parameters" fix input delay at 2-8 turns of 2 ticks (4-16) and the checksum cadence at 8, so a window several times the widest skew is arithmetic, not a judgement call. The other two owed items both open with a fork and are deliberately not picked: widening the digest to decision 7's promised order queues and RNG cursor needs a seeded simulation RNG that `scripts/sim/` does not contain and a seed both clients agree on, and decision 7's dump/replay response needs `ReplayRecorder.start()` to be given a path nothing has chosen. Self-contained in one `RefCounted`: no change to `Match`, `TurnScheduler` or the cadence | `network-multiplayer.md`, decision 7 and its "Starting parameters"; the debt `U1` recorded and `V1` left standing | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
