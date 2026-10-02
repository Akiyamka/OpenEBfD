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
| Z1 | Apply `O1`'s recommended input delay to the live `SimCommandBus`, event-driven | `Y1` made the measurement real but deliberately left the application for its own slice, because a careless one risks a command arriving after the receiver drained its target tick, a silent `submit_at()` late drop, and the desync `V1` halts on. The three policy questions it left open were all answered by human decision 2026-10-02: apply **event-driven** (only when the recommendation actually changes, so the transition is a counted event rather than a silent per-tick recompute, matching how halt, stall and mismatch are each explicit transitions); **no damping**, since a smoothing rate is a parameter this track has no basis to pick and `O1`'s own philosophy defers tuning to real measurements; and **no special handling for already-scheduled commands**, which is a fact to prove rather than code to write -- `submit()` computes a target tick once from the delay then in effect and never recomputes it. Completes `O1`, whose paragraph has recorded the application as untouched since it landed, and closes the one half of decision 8's "input delay is adaptive" that `Y1` left aspirational | `network-multiplayer.md`, decision 8 and `O1`; human decisions 2026-10-02 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
