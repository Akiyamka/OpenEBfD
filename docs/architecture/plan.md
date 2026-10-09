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
| AH1 | A wall segment waits for a unit that can leave instead of skipping its cell | Decision 12's item 6, the last numbered item still owed, and the smaller of the two slices the human decision of 2026-10-08 requires. `AG1` supplied the wall path's check, so item 6 is now the **wait** rather than the check: the segment keeps its ready order queued, reserves its footprint no-stop, and re-asks every tick for five seconds, which is what lets the question widen from immobile-only to **any** unit -- without the wait, deferring on a unit walking past the line would cost that segment permanently, because the chain skips and moves on. An immobile unit keeps `AG1`'s immediate skip: nothing in five seconds moves a deployed unit, and the chain holds the player's whole build queue while it waits, which is the same refuse-immobile/wait-for-mobile split the human prescribed for MCV deployment on the same day. Taken before the MCV half because it is strictly smaller -- `ProductionSystem` is already on the tick and already owns the chain, the refund and the skip outcome, where the deploy has no tick of its own -- and because landing it frees `UnitPushAside`'s teleport on the wall path, leaving one caller rather than two | `network-multiplayer.md` decision 12, item 6; human decisions 2026-10-08 and 2026-10-09 | landed — `pending` |
| AI1 | An MCV deploy waits for a unit that can leave instead of aborting | The human decision of 2026-10-08 in full: the deploy adopts the same two-branch split -- `AG1`'s immediate abort for an immobile unit, and a pending state with a no-stop reservation for any other -- plus the one piece of new logic that decision names, a check at resolution that the unit's current order is still a deploy, abandoning the attempt silently when the player has ordered it elsewhere. Larger than `AH1` and deliberately second: `UnitDeploymentController` is driven by an animation signal and joins no tick, so the wait needs a place in `Match._advance_simulation_tick()`'s fixed order, and its reservation needs a second source behind the one provider `NavBlockerTracker` holds -- both of which `AH1` lands first in the smaller place | human decision 2026-10-08; `network-multiplayer.md` decision 12, item 4's "MCV deployment is a fork nobody has picked" | queued |
| AJ1 | Delete the placement teleport | What is left of decision 12's item 4 once `AH1` and `AI1` land: with both bypass callers waiting on any unit, nothing mobile reaches `_spawn_placed_building()` and `UnitPushAside.push_units_out_of_footprint()`'s `set_simulation_position()` write has nothing to do. Two facts measured while landing `AF1` belong to this slice and are recorded in decision 12 rather than here: the write cannot be deleted alone, because it is the only consumer of `excluded_unit`, which GDScript then reports as an unused parameter; and the coverage it needs is what `AH1` and `AI1` add, since before them deleting the call failed exactly one assertion in the whole suite | `network-multiplayer.md` decision 12, item 4's remaining half | queued |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
