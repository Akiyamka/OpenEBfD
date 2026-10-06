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
| AC1 | A sell or repair click echoes immediately, claiming nothing about its outcome | The surviving half of the open question decision 12 replaced, and the only queued item that needs no part of that decision's pending state. `_try_sell_building()` and `_try_toggle_building_repair()` emit a status only when the click resolves to no building; a click that lands submits in silence, and the sell path emits nothing at execution either, so a successful sale never reaches the status channel at all. At a real input delay the natural response to silence is to click again, and the second click is swallowed by `_sale_service.is_active()` while the first building sells, or toggles repair back off because `execute_repair_building_command()` reads the direction at execution and is right to. `AB1` just established the pattern for the placement surface, where the fix was an icon state; sell and repair have no icon, so the echo is a status string and must claim only that an order was sent -- the repair direction is genuinely unknown at click time. Items 1 through 4 of decision 12 are mutually dependent and item 6 needs the deadline, so none of them can go next alone; item 4's idle-unit relocation is the one that could, and it carries a question for the human rather than a documented number, so it is flagged in this brief rather than picked | `network-multiplayer.md`, `## Open questions`, the entry reframed at `AA1`'s land, which names this as what survives and prescribes "an echo that claims nothing" | landed — `pending` |

**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
