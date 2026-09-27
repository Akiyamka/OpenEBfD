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
| N1 | Measure round-trip time to each peer, observable only | Reconsidered while ordering `H1`'s deferred items (still the architect's own call): adaptive input delay was previously set aside because decision 8's own "worst round-trip in the room" is multi-peer language and this track had stayed two-peer -- `M1` closed exactly that gap, so the per-sender infrastructure a real RTT measurement needs (tracking one value per remote peer, independently) already exists to reuse. A ping/pong pair of new discriminator values (`2`/`3`) lets a client measure elapsed ticks to each peer that answers; `RttTracker` records the latest measurement per sender and the worst known value, mirroring `ChecksumExchange`'s own shape. Actually setting `bus.input_delay_ticks` from a measured RTT is a policy this slice does not build -- decision 8 gives a floor (two turns) but no conversion formula, the same "no exact number specified" gap `K1` already found for stall/drop's own timeout -- so this stays observable-only, exactly the split `J1`/`K1` each already drew for a mismatch and a stalled peer. Proven at the unit level only (bare `TurnScheduler`/`LoopbackHub`), not extending the sequential two-`Match` proof, since a genuinely round-trip-timed measurement inside that harness would need a scheduler answering pings before its own `Match` even boots -- achievable, but not needed to prove the wire mechanism itself | `network-multiplayer.md`, decision 8, continuing the pattern `H1`-`M1` established | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
