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
| M1 | Widen checksum exchange to track multiple remote peers | Reconsidered while ordering `H1`'s deferred items (still the architect's own call): `LoopbackHub` already supports any number of endpoints -- `ChecksumExchange`'s two-peer limit was a deliberate scope choice in `J1`, not a limitation of the transport it sits on -- so proving multi-peer support needs only a wider harness (three-plus `LoopbackHub` endpoints), the same pattern `H1`-`K1` already used, not the lobby's own room-join flow this had previously been assumed to need. `SimCommandBus` already sorts by `player_id` and needs no change; only `ChecksumExchange`'s tick-only keys and `TurnScheduler`'s discard-after-echo-check of `sender_player_id` do. Adaptive delay, stall/drop's response half, snapshot reconnect, wiring live UI input, the lobby's own team-assignment UI, and the newly-confirmed-missing victory condition all remain deferred, ordering still delegated | `network-multiplayer.md`, `## Order of work`, Phase 5's `J1` paragraph | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
