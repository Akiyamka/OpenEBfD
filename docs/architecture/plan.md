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
| Q1 | Add `PlayerEliminationTracker`: per-player elimination as an observable, from the rules-authored `exclude_from_skirmish_lose` flag | Decision 9 names "a team-aware victory condition" as still owed, confirmed missing by grep during `L1`'s investigation and still missing today -- nothing computes elimination at all. This is the ground floor a team-aware check must fold through team topology (`players.are_allied()`/`team_id`) later, the same incremental shape `K1` built directly on `J1`'s cadence -- team-folding and any UI/pause/response stay out of scope here. Unlike every other remaining Phase 5 item, this is **not** blocked by the live-match transport-bootstrap question this track keeps deferring: it is pure per-tick simulation-adjacent logic, needs no peer, no transport, no lobby. The rules-db column itself needed no new plumbing, but the brief's own planned read path did: `assets/converted/rules/{buildings,units}/*.tres`/`RuleEntityConfig` turned out to be the *deprecated* legacy rules representation (`docs/architecture/unit-data-migration.md`), not what `BuildingDefinitionCatalog`/`UnitSceneCatalog` actually return -- escalated to a human mid-implementation, who chose extending the real, active `BuildingDefinition`/`UnitDefinition` generator pipeline instead, the same pattern every other converted column already uses | `network-multiplayer.md`, decision 9 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
