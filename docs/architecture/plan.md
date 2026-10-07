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
| AD1 | An idle unit standing on a no-stop cell steps off it | Decision 12's item 4, the half that is implementable today: no-stop cells already exist as building aprons and skirts (the `s`/`d`/`p` markers `NavBlockerTracker.refresh_building_blockers()` writes), and `process_reroute_queue()` already relocates a *commanded* agent whose destination stops being stoppable, with a reroute budget -- it `continue`s on an agent whose `command_id` is not positive, and that idle agent is exactly the parked unit decision 12 wants moved. Taken now rather than held until items 1-3 build the reservation, by human decision 2026-10-06. The mechanism it needs already exists and says so: `GroundNavigation.request_yield()`'s own doc comment is *"Yield is internal steering, not an order ... The request mainly displaces idle friendlies that occupy a choke point"*, it already refuses a `hold` agent and an en-route one, and `_drain_pending_entries()` gives every unit admitted to `sim_units` an agent entry, so the deterministic `registry.ordered_agents()` list already contains the units to sweep | `network-multiplayer.md` decision 12, item 4; human decision 2026-10-06 taking it as its own slice | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
