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
| AE1 | A blocked placement waits for the site to clear, reserving it while it waits | Decision 12's items 1, 2 and 3 -- the pending state, the per-tick confirmation and the no-stop reservation -- taken as one slice because the decision's own corrected note says 1 through 3 are mutually dependent, and because splitting them lands a regression: with the teleport of item 4 still in place, a footprint is always clear by the time `place_without_preview()` runs, so the only verdict a pending state can wait on today is `AA1`'s immobile-unit refusal. Items 1+2 alone would therefore turn an instant "cannot be placed there" into the same message five seconds later and nothing else. What the reservation buys is narrower than it first looks and is stated exactly in the brief: it does not make a blocked placement succeed, because a mobile unit never blocks one while the teleport stands and an immobile one is the single thing `AD1`'s sweep cannot move. It buys the anti-denial rule itself -- no unit can be *ordered* to park on a site with a placement pending, which is item 3's own stated purpose and needs only the cells, since `_nearest_stoppable()` already snaps a destination out of a no-stop cell -- plus idle units walking off the site through `AD1`'s sweep, which changes no verdict yet but is what item 4 will stand on when the teleport goes. No new numbers to decide -- five seconds held as `5 * MatchClock.TICKS_PER_SECOND` at the comparison site, every-tick evaluation, and no-stop for every player are all written down in decision 12 | `network-multiplayer.md` decision 12, items 1-3, and its "Landed so far" note as corrected at `AD1`'s land; the `exempt` backlog in `architecture_rules.toml` is empty, and phase 5's own remaining items (lobby, snapshot reconnect, pause-to-drop) are each deferred or out of track scope | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
