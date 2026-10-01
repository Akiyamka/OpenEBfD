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
| U1 | Exchange state checksums over the live connection, observable only (`ChecksumExchange` wired into `Match`'s `TurnScheduler` at decision 7's documented 8-tick cadence) | `T1` removed the blocker every remaining Phase 5 item shared, so the question is now which one goes first — and this is the only one whose number is already written down. Decision 7's own "starting parameters" fixes the cadence at every 8 ticks; `K1`'s stall threshold and `N1`/`O1`'s ping cadence are both named nowhere in the document, so wiring either of those first would need a human decision this does not. `ChecksumExchange` has been built, tested and widened to many peers since `J1`/`M1` but has never had a live sender: `Match` still passes `null` for it, exactly as `P1` left it. Wiring it also gives `K1`'s `last_remote_activity_tick()` its first real heartbeat to watch, so it is the common prerequisite for the stall/drop response as well as for desync detection. Observable only — decision 7's "halt the match, dump both states" response stays out, the same split `J1` drew between a countable mismatch and what a mismatch *does* | `network-multiplayer.md`, decision 7 and its "Starting parameters", Phase 5 (netcode) | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
