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
| L1 | Correct decision 9's stale "friendly-fire rules" claim | Investigating "the lobby" as a candidate next slice (ordering among `H1`'s deferred items still delegated to the architect) turned up a real doc defect, the same shape as `G1`'s own finding: decision 9 says 2v2 "still needs... friendly-fire rules," but `scripts/combat/combat_target.gd`'s `are_friendly()` already calls a source's `is_allied_with()` when available, and both `Unit.is_allied_with()` and `Building.is_allied_with()` already route through `player_roster.gd`'s own `are_allied()` (via `EntityQueryScript.is_allied_with()`) -- genuinely team-aware, not player-aware only. `combat_impact_resolver.gd`'s `_friendly_multiplier()` already reduces ally damage by `bullet.friendly_damage_amount()`, predating this network track entirely (that file's own first commit, `30e3d93`, "warheads"). Confirmed still genuinely missing, by contrast: any victory/defeat condition at all -- grepped the whole tree, found nothing -- which is real, substantial, new-feature work belonging to its own later slice with its own investigation, not folded into this one-paragraph correction | `network-multiplayer.md`, decision 9 | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
