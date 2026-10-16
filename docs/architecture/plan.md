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
| AM1 | A turn barrier keeps gathered clients in step | Human-directed, 2026-10-16, taking precedence over the exempt lists (the queue was empty after `AL1`); the human chose a real turn barrier over clock-slewing and a larger input delay. The second two-process run halted with `AL1`'s dump reading `late drop: player 1 SimMoveCommand ... for tick 727, refused at local tick 969` and `dropped_ticks=0` on both sides: Godot clamps `_process` delta after a long stall, so `FrameTickDriver` never sees the lost time, and clocks free-run with nothing tying them together but a two-tick input delay. Each client of a `--net-players` match now announces a **horizon** (discriminator 6), the newest tick its commands are final for, and runs tick T only once every peer's horizon covers T -- so the faster client waits and, with ordered delivery, a remote command can no longer arrive after its tick. Skew is bounded by each sender's *effective* delay -- its announced horizon minus its clock -- which equals the input delay except while it decays one tick per tick after `Z1` lowers it, since a promised horizon cannot be withdrawn. The wait polls and re-announces in wall-clock time, is printed and labelled once it lasts a checksum cadence, and feeds `X1`'s verdict in wall-clock time, since a waiting client's ticks stop; at the threshold the match keeps waiting with the player named, because decision 8's removal is the deferred vote-kick. Closes `AK1`'s owed resync and, as a consequence, the second symptom: a client can no longer run 64 ticks past a halted peer, so the peer's report is compared and both halt. Plain `--net-room` and single-player boots are byte for byte unchanged. Owed from the land: `Match.is_player_stalled()`'s doc comment still says a never-heard player is absent, which a turn-barrier wait no longer honours; the brief asked for it to be updated and the code review missed it | human direction 2026-10-16; `network-multiplayer.md` decision 8 and `AK1`'s owed list | landed — `pending` |


**status** is one of `queued`, `in-flight`, `landed`, `abandoned`. A landed row
stays for one further slice with its commit hash, then moves to `slices.md` and
is deleted from here — the overlap exists so a reader who arrives mid-run can
still see what just happened.

An `abandoned` row keeps its reason. `slices.md` has precedent for this being
worth recording: "Abandon D4a: the gate costs more than the poll it saves" is
more useful to the next reader than a row that silently vanished.
