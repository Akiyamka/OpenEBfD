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
| V1 | Halt the match on a checksum mismatch, and surface the diverging tick | `U1` made a desync detectable in a live match and nothing responds to one, which is the exact state decision 7 singles out as the worst: "a silently continuing desync is worse than a stopped match". It is also the only remaining Phase 5 item whose policy the document already states outright -- `K1`'s stall timeout and `N1`/`O1`'s ping cadence are both named nowhere, so either would open with a human decision this does not. Completes the split `J1` drew and `U1` finished the first half of: a countable mismatch, then what a mismatch *does*. Deliberately only the halt and the tick number, not decision 7's whole sentence -- "dump both states" has no state-dump path decided and only the peer's *hash* is ever available, and "write out the replay" cannot work while nothing calls `ReplayRecorder.start()`; both are named out of scope rather than guessed at. Both ends detect the same mismatch independently and halt without coordinating, so no peer-notification protocol is needed | `network-multiplayer.md`, decision 7 ("On desync") and decision 8 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
