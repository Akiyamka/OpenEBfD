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
| Y1 | Send pings on the decided cadence and wire `RttTracker` into a live `Match`, observable only | Unblocked by a human decision 2026-10-02: the ping cadence is **6 checksum-cadence cycles** -- 48 ticks, 1.92 s at 25 Hz -- stored as a cycle count like `X1`'s stall threshold so it rescales with `CHECKSUM_INTERVAL_TICKS`. `N1` built `RttTracker` and `O1` the formula, but `Match` has passed `null` for the tracker since `P1`, so nothing has ever measured a round trip in a live match; this is the last piece of `H1`-`O1`'s stack never wired into one. Deliberately **not** also applying `O1`'s `recommended_input_delay_ticks()` to the live bus: too small a delay means a command arrives after the receiver has passed its target tick, `submit_at()` drops it late and silently, and the two clients diverge -- a desync `V1` would then halt on. That is a real correctness stake needing its own controls, plus policy this round has no decision for (when to re-apply, and what happens to commands already scheduled under the old delay). Same observable-first split `O1` itself drew and `U1`/`V1` and `K1`/`X1` each followed | `network-multiplayer.md`, decision 8; human decision 2026-10-02 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
