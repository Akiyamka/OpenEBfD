# Phase 3 slice index

Phase 3 was built as numbered slices — `A1a`, `B3d`, `C6b`, `R2b` — and that
numbering is load-bearing in the source: 178 comments across `scripts/`,
`tests/` and `tools/` justify themselves by naming a slice. This file is the
lookup those comments assume exists. A reader who hits "since slice C5" in
`scripts/units/unit.gd` comes here to find the commit that did it.

**This is history, not a plan.** Every row names work that has landed. The
backlogs live somewhere else — in the `exempt` lists of
[`tools/architecture_rules.toml`](../../tools/architecture_rules.toml), where a
queued group is a file list that shrinks as slices empty it, and where future
ids (`R5` and the slices after it) are named as work owed rather than work
done. A slice gets a row here when it lands, not when it is planned; grep the
manifest, not this file, to find out what is still owed.

**It is enforced, not maintained by discipline.** The `unindexed-slice-reference`
rule in [`tools/architecture_rules.toml`](../../tools/architecture_rules.toml)
(kind `slice-index`) scans `scripts/**/*.gd` for `slice <id>` references and
reports any id this table does not list, so a comment cannot name a slice that
has no row. `tools/test_check_architecture.py` closes the other half:
`check_slice_index_hashes()` runs `git rev-parse --verify` over every hash below
and compares every date against its commit, so a row cannot rot into a hash
that resolves to nothing.

Two limits worth knowing before trusting a green run:

- The rule only sees its zone, `scripts/**/*.gd`. References under `tests/`
  and `tools/` — including the `R4a` mention beside `allow_budget` in the
  manifest — are covered by the self-test's whole-tree pass over hashes, but
  not by the per-line rule. A reference in a test file naming a slice with no
  row will not be reported.
- An unreferenced row is not an error. History stays even when the last comment
  that mentioned it is deleted.

## Reading the table

- **commit** — the commit that made the change, first. Commits that recorded a
  slice's *scope* before it was written, corrected its account afterwards, or
  fixed a defect it turned up, follow in the same cell, tagged. The **date** is
  the implementing commit's, so the table sorts by when the work landed rather
  than by when it was decided.
- **`—`** in the commit cell means the slice deliberately never had a commit of
  its own: it is a parent that was delivered entirely through its lettered
  children.
- **`?`** would mean a slice this reconstruction could not pin to a commit.
  There are none.
- **`pending`** in the commit cell means the row landed in the same commit as
  the code that cites it, so the hash it will carry does not exist yet — a
  commit cannot contain its own hash, and the `slice-index` rule plus the
  pre-commit hook together mean the row cannot wait for the next one. The
  self-test allows exactly one, so a pending row has to be filled in before the
  slice after it can use the same escape.
- **`†`** marks a hash whose own commit message never names the slice id it is
  filed under, so the attribution is this reconstruction's inference rather than
  the commit's own claim. Eight of the twenty-six rows carry one, measured with
  `git show -s --format=%B <hash>` against each row's id: `A1a`, `A1b`'s
  implementing commit, `C5`'s implementing commit and its defect fix, `C6c`,
  `R2b`, `R3` and `R4a`. Each rests on the design note in the cell beside it
  describing the same change, and on nothing else. Nine further hashes name
  their id without the word "slice" and are not marked — the regex wants
  `slice <id>`, the commits simply write `C6a` or `R1`. The `Slice:` trailer
  above exists so this column stops growing.
- **design note** links the paragraph in
  [`network-multiplayer.md`](network-multiplayer.md) that argues the slice.
  Those paragraphs are bold or italic openers inside `## Order of work`, not
  headings, so they have no anchors of their own — the link lands on the
  enclosing section and the link text is the paragraph's exact opening phrase,
  which is greppable. An empty cell means no paragraph is devoted to that
  slice; several are mentioned only in passing inside another slice's argument.

## Keeping it current

New work carries its id in the commit message as a trailer:

```
Slice: R5
```

That is the whole convention, and it is what makes this table auditable rather
than archaeological — the reconstruction below had to be read out of prose
because nothing ever asked for the id. To list what is missing a row:

```bash
git log --format='%h %ad %s%n%b' --date=short | grep -B0 '^Slice: '
```

The ratchet that actually bites is the rule, not the trailer: the first comment
under `scripts/` that says `slice R5` fails the checker until `R5` has a row
here, so the index cannot fall behind the code that cites it.

## The slices

| slice | commit | date | what it did | design note |
| --- | --- | --- | --- | --- |
| `A1a` | `ebc7688`† | 2026-08-20 | Split the Rules.txt movement cadence away from the navigation tick rate, so folding the two clocks could not silently change how units turn | [Closed 2026-08-20, in phase 3 slices A1a and A1b](network-multiplayer.md#4-one-integer-tick-at-25-hz) |
| `A1b` | `5712714`†, `51aa267` (record) | 2026-08-20 | Folded `UnitNavigationSystem`'s own 20 Hz accumulator into the 25 Hz simulation tick and deleted `NAVIGATION_TICK_RATE`, closing the sixth tick domain | [Closed 2026-08-20, in phase 3 slices A1a and A1b](network-multiplayer.md#4-one-integer-tick-at-25-hz) |
| `B1` | `48e9e21` | 2026-08-20 | Sorted the 96 `delta: float` call sites across 37 files into simulation and view; no behaviour change, the classification was the product | [Slice B1's inventory, 2026-08-20](network-multiplayer.md#order-of-work) |
| `B2` | `b98cc3a`, `3d14e22` (correction) | 2026-08-20 | Moved ground locomotion, terrain snapping and the harvester economy onto the tick, and gave `Unit` its `_simulation_halted` gate | [Updated after slice B2](network-multiplayer.md#order-of-work) |
| `B3` | — | — | Parent of the frame-delta combat group; never a commit of its own, delivered as B3a–B3d | |
| `B3a` | `47eee7d` | 2026-08-20 | Moved projectile flight onto the simulation tick | [Updated after slice B3a, 2026-08-20](network-multiplayer.md#order-of-work) |
| `B3b` | `5d62732` | 2026-08-21 | Moved building firing onto the tick, retiring `Building._process()` and with it the dead-building hole C5 later had to close | [Updated after slice B3b, 2026-08-20](network-multiplayer.md#order-of-work) |
| `B3c` | `4e2cb7d` | 2026-08-21 | Split turret aim into a simulated angle and an applied pose | |
| `B3d` | `e85467f`, `e96185a` (rule) | 2026-08-21 | Completed Fly/Hover transitions on a tick deadline instead of `AnimationPlayer`'s `animation_finished`, severing the flight non-determinism B1 found | [Updated after slice B3d, 2026-08-21](network-multiplayer.md#order-of-work) |
| `C1` | `a438af3` | 2026-08-21 | Added the flat hot-state store `SimEntityState`, indexed by entity id, with nothing writing into it yet | |
| `C2` | `8531049`, `c9e5dc1` (scope) | 2026-08-21 | Made the store authoritative for a unit's position — writes only, readers left owing | [Slice C2's scope, decided 2026-08-21, and the debt it knowingly takes on](network-multiplayer.md#order-of-work) |
| `C3` | `da5a0b8` | 2026-08-21 | Made the store authoritative for health and shields, units and buildings both, through the existing setter chokepoint | [Slice C3, decided 2026-08-21: health and shields](network-multiplayer.md#order-of-work) |
| `C4` | `862ef06` | 2026-08-21 | Made the store authoritative for entity ownership | |
| `C5` | `f2fdf7f`†, `3756462` (scope), `ad4f271` (correction), `479cd1a`† (defect fix) | 2026-08-21 | Deferred entity despawn to a queue the tick drains, so a killed entity stops being simulated at once instead of at end of frame | [Slice C5, decided 2026-08-21: deferred despawn](network-multiplayer.md#order-of-work) |
| `C6` | `6a0be54` (scope) | 2026-08-22 | Parent of the deferred-spawn work; its own commit only recorded the scope and the shared-group problem that split it into C6a–C6c | [Slice C6, decided 2026-08-22: deferred spawn](network-multiplayer.md#order-of-work) |
| `C6a` | `0751182` | 2026-08-22 | Gave the simulation its own iteration source: `"sim_units"`/`"sim_buildings"` joined in code beside the shared view groups, no scene file touched | [C6a introduces "sim_units" and "sim_buildings"](network-multiplayer.md#order-of-work) |
| `C6b` | `8b4c430` | 2026-08-22 | Built `SimAdmissionQueue` and routed the three tick-only groups — projectiles, linger effects, spice mounds — through it | [C6b builds the queue and routes the three joins](network-multiplayer.md#order-of-work) |
| `C6c` | `21cc91c`† | 2026-08-26 | Admitted units and buildings on a tick and gated navigation's own registration on the same drain | [C6c takes "sim_units" and "sim_buildings"](network-multiplayer.md#order-of-work) |
| `B4` | `51e7cd9` | 2026-08-26 | Made the view interpolate between simulation ticks off the store's double buffer, which is what made 25 Hz motion look continuous | [Slice B4, decided 2026-08-26: the view interpolates](network-multiplayer.md#order-of-work) |
| `R1` | `d684e22` | 2026-08-26 | Gave buildings a store-backed position, closing the one hot-state field C2 left on the node | [Slice R1, decided 2026-08-26: buildings get a store-backed position](network-multiplayer.md#order-of-work) |
| `R2` | `0f299de`, `0da1419` (correction) | 2026-08-26 | Added `simulation_position()`, the `global-position-read-bypasses-store` rule, and the queued exempt group that ratchets readers off the node | [Slice R2, decided 2026-08-26: the read accessor](network-multiplayer.md#order-of-work) |
| `R2b` | `6e7a262`† | 2026-08-27 | Pushed a snapshot-restored entity's position back into the store, which `MatchSnapshot` had been assigning to the node only | [Slice R2b, decided 2026-08-27: the snapshot restore](network-multiplayer.md#order-of-work) |
| `R3` | `e7e67f5`† | 2026-08-27 | Migrated the three ground-steering modules' 53 position reads onto `simulation_position()` | [Slice R3, decided 2026-08-27: the ground-navigation group](network-multiplayer.md#order-of-work) |
| `R4` | `b932632` | 2026-08-27 | Migrated 24 of the navigation system-and-shared group's 26 reads, across six modules plus twelve of `UnitNavigationSystem`'s fourteen | [Slice R4, decided 2026-08-27: navigation's system-and-shared group](network-multiplayer.md#order-of-work) |
| `R4a` | `3bea127`† | 2026-08-27 | Hatched the two debug-overlay reads R4 left behind instead of exempting the whole 1100-line navigation facade, raising `allow_budget` 0 → 2 | |
| `R5` | `9e468d3` | 2026-08-27 | Migrated the flight group's 24 reads — `unit_flight_controller.gd` and `air_navigation.gd` — emptying the read rule's navigation queue, and bound the migration on the real path instead of a double for the first time | [Slice R5, decided 2026-08-27: the flight group](network-multiplayer.md#order-of-work) |
| `B5` | `e6becd6` | 2026-08-27 | Stopped `CombatTurret` measuring rules range from the interpolated `visual_root`, which made an in-range verdict depend on frame pacing; buildings deliberately untouched | [Slice B5, decided 2026-08-27: a firing decision](network-multiplayer.md#order-of-work) |
| `R6` | `378ffc6` | 2026-08-28 | Migrated combat's ten entity reads plus both `combat_aim_position()` accessors the rule cannot see, and moved `combat_turret.gd` and `combat_target.gd` to permanent because their reads are of markers, pivots and dead fallbacks | [Slice R6, decided 2026-08-28: the combat group](network-multiplayer.md#order-of-work) |
