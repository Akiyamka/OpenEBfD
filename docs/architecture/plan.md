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
| AF1 | A unit of any kind in the footprint defers the placement instead of being shoved aside | The first half of decision 12's item 4, and the slice that finally pays off `AD1` and `AE1`. Today the authority defers only on an **immobile** unit (`AA1`), so a mobile one is teleported by `UnitPushAside.push_units_out_of_footprint()` before any verdict can defer -- which is why `AE1`'s pending state can only ever wait on a unit that will not move, and why its reservation changes no placement outcome. Widening the authority's question to *any* unit makes the wait productive, and both relocation paths it depends on already exist and were verified for this brief: a never-commanded agent is walked off by `AD1`'s `sweep_idle_no_stop_agents()`, and a commanded one whose destination block intersects the newly reserved cells is queued by `replan_after_map_change()` -- which skips `command_id <= 0`, precisely the hole `AD1` filled -- and relocated by `process_reroute_queue()`, which `AE1` taught to treat a reserved destination as unstoppable. The teleport itself is deliberately **not** deleted here: walls and the MCV deployment flow reach `_spawn_placed_building()` without passing the authority at all, so removing it now would make them engulf units where today they shove them. This slice instead makes it provably dead on the command path, and the measurement it was asked for came back empty: no suite outside the two it extends covers the shove at all, so the deletion slice must add wall and MCV-deployment coverage rather than fix existing cases | `network-multiplayer.md` decision 12, item 4, and the "Still owed" note as rewritten at `AE1`'s land | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
