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
| AK1 | A networked match waits for every player before its first tick | Human-directed, 2026-10-10, and it takes precedence over the exempt lists, which the queue was empty of after `AJ1`: the human runs two clients by hand against the relay and cannot launch them at the same instant, so `--net-players=N` must hold the match at tick 0 until N players are present. Today nothing synchronises a start -- each client ticks from its first frame, `WebSocketTransport.send()` drops every frame silently while still connecting, and the relay keeps no history -- so two hand-launched clients start seconds apart: whatever the first sends before the second is seated is lost, and the second's commands then arrive behind the first's clock and are dropped late, which desyncs the match. The barrier lives on the client because the relay is deliberately dumb: every waiting client re-sends a presence frame each checksum cadence, player 1 sends one START once all N are present, and **every client -- player 1 included -- starts on the relay's copy of START**, which bounds start skew by the difference of the two relay legs plus two frames instead of a full one-way latency. A gathered match starts at decision 8's two-tick floor, because `Z1`'s zero-until-measured default would late-drop commands for the first two seconds even at zero skew. Absent `--net-players` is today's behaviour byte for byte; the roster holds two players, so N is 1 or 2 | human direction 2026-10-10; `network-multiplayer.md` decisions 1, 6 and 8, and `T1`/`Z1` | landed — `pending` |


**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
