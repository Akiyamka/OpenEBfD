# Combat test suite split

`tests/combat/run.gd` is 5228 lines and holds 74 cases. It has crossed
`max-file-lines: 5000` in `.gdlintrc`, which makes `make lint` fail — currently
the only lint error in the project. The file grew as the default dumping ground:
three sibling suites (`death_category_run.gd`, `multi_turret_run.gd`,
`authored_reload_sound_run.gd`) already budded off it, but everything else —
bullet rules, ballistics, FX, turret topology, unit attack orders, defensive
buildings, deploy modes — stayed in one file.

This document plans the split into 12 thematic suites, each comfortably below the
eventual ratchet target (`max-file-lines: 800`, see the comment at the bottom of
`.gdlintrc`), and the extraction of the shared harness — by inheritance where a
suite genuinely *is* what it extends, and by composition everywhere else.

## What makes the move dangerous

Today's `_run_case` prints `PASS` whenever `_failures` did not increase. A GDScript
runtime error **aborts the case body where it stands** and never touches
`_failures`, so the suite exits 0. A mechanical move of 4500 lines is exactly the
operation that produces bodies which abort on their first line — a forgotten
`LegacyRulesFixture.install`, a `preload` left behind.

`tests/combat/multi_turret_run.gd:125` already carries a guard for this, which was
never backported. But **it closes only part of the hole**: it catches a case that
added no assertions, while a case that managed one `_expect` and then crashed
still prints `PASS`. Safety therefore comes from four invariants together, not
from the guard alone — see "Move invariants".

## Target structure

Inheritance only where the relationship is genuinely is-a. Everything else is
composition through `preload` constants, modelled on
`tests/support/legacy_rules_fixture.gd`.

### Inheritance: `tests/support/suite.gd` (~60 lines)

`extends SceneTree`. A suite **is** the main loop: `--script` requires the script's
root to be a `MainLoop`, and `root`, `quit()` and `await process_frame` are methods
and state of that very object. The counters and the epilogue live there by
definition.

- `var _assertions`, `_failures`, `_current_case`
- `_run_case(name, test)` and `_run_async_case(name, test)`, both with the
  zero-assert guard
- `_expect(condition, message)` — the 522 call sites in `run.gd` stay untouched
- `_finish(label)` — reproduces today's epilogue: `printerr(...); quit(1)` /
  `print(...); quit(0)`

And **nothing else**: this base is intended as the future foundation for the other
30 suites, so no combat- or 3D-specific code belongs in it. The base does not
declare `_initialize` — each suite defines its own, so there is no `super()`
discipline to remember. `extends "res://..."` is a path reference rather than a
global `class_name` lookup, which satisfies the AGENTS.md rule; the same idiom is
already used by `tests/fixtures/match_fixture.gd` and every
`scripts/rules/*_config.gd`.

### Composition: `tests/combat/support/`

`combat_doubles.gd` — `extends RefCounted`, no `class_name`, inner classes only:

```
class FakeCombatTarget extends RefCounted
class PhysicsCombatTarget extends StaticBody3D
class PhysicsBuildingBlocker extends PhysicsCombatTarget   # cannot be separated
class CombatSource extends RefCounted
```

Consumed as `const Doubles := preload("res://tests/combat/support/combat_doubles.gd")`
followed by `Doubles.FakeCombatTarget.new(&"Heavy")`. The two-step form is
mandatory — the one-line alias `preload(...).FakeCombatTarget` is unreliable in
GDScript 4.

`combat_fx_probe.gd` — `extends RefCounted`, `static func` only, parameterised by
the tree root (like `LegacyRulesFixture.install(root)`):

```
static muzzle_effects(root, kind, emission_index := -1) -> Array[Node3D]
static free_muzzle_effects(root) -> void
static impact_effects(root, effect_id) -> Array[Node3D]
static free_impact_effects(root) -> void
static ground_decals(root) -> Array[Node3D]
static free_ground_decals(root) -> void
static free_all(root) -> void          # new: one-call cleanup for setup/teardown
```

`combat_bullets.gd` — `extends RefCounted`, instantiated (it owns the catalog):

```
var _catalog := CombatDefinitionCatalogScript.new()
bullet_config(id) / warhead_config(id)     # for the 3 cases that read the catalog directly
runtime_bullet(id)                         # without today's dead `_rules` argument
bullet_with_impact_scenes(id)
static emission(position, direction) -> Dictionary   # pure function, needs no catalog
```

`emission()` becomes static: it assembles a two-key dictionary and has no use for
the catalog. One caveat so the gain is not overstated — this does not remove the
instance from any suite. S12, the only candidate, still reads the catalog directly
(`_test_undeployed_kobra_shell_leaves_the_muzzle`, `run.gd:1020`).

`combat_assertions.gd` — `extends RefCounted`, statics:

```
static horizontal_angle_between(a, b) -> float
```

A separate module rather than `suite.gd`: this is a 3D/combat-specific helper and
has no business in a base shared by all 30 suites.

### Actual per-suite dependencies

Verified mechanically: for each of the 74 cases, the function's line range was
scanned for the symbols it uses. Each file imports **only** what is marked here —
otherwise the thematic boundaries stop being visible.

| Suite | Doubles | Fx | `_bullets` | Assertions | local classes |
|---|:-:|:-:|:-:|:-:|---|
| S1 | ✔ | | ✔ | | |
| S2 | ✔ | | ✔ | | `PhysicsGround` |
| S3 | | ✔ | ✔ | | |
| S4 | | ✔ | ✔ | | |
| S5 | | ✔ | | | |
| S6 | ✔ | ✔ | | | |
| S7 | | | | | |
| S8 | ✔ | | | ✔ | |
| S9 | ✔ | | | ✔ | `PhysicsCliff`, `RejectingAttackNavigation` |
| S10 | ✔ | | ✔ | | |
| S11 | ✔ | | | ✔ | |
| S12 | ✔ | | ✔ | | |
| `multi_turret_run.gd` | ✔ | ✔ | | ✔ | |

Two non-obvious cells: **S6 does touch FX** (`_muzzle_effects`, `_impact_effects`
and their `free_*` in `fixed_turret` / `single_axis_turret` /
`parallel_trajectory_salvo`) **and uses `FakeCombatTarget`**. **S7 is the only
suite that needs no support module at all.**

### Doubles and helpers: shared vs. co-located

| Symbol | Consumers | Destination |
|---|---|---|
| `FakeCombatTarget` | S1, S2, S6, S8, S9, S12 + `multi_turret_run.gd` | `combat_doubles.gd` |
| `PhysicsCombatTarget` | S1, S2, S8, S9, S11 + `multi_turret_run.gd` | `combat_doubles.gd` |
| `PhysicsBuildingBlocker` | S9, S11 (and it extends the previous one) | `combat_doubles.gd` |
| `CombatSource` | S1, S10 | `combat_doubles.gd` |
| `PhysicsGround` | `_test_trajectory_moving_target_miss` only | **stays in `run.gd` until S2 moves**, then an inner class of S2 |
| `PhysicsCliff` | `_test_obstructed_attack_order` only | **stays in `run.gd` until S9 moves**, then an inner class of S9 |
| `RejectingAttackNavigation` | `_test_rejected_attack_perch` only | **stays in `run.gd` until S9 moves**, then an inner class of S9 |
| `_authored_flash_nodes` / `_flash_departed_from_rest` | `_test_defensive_turret_stop_clears_muzzle_flash` only | stay in `run.gd` until S11 moves |

Extract **by syntactic block name, never by line range**: `PhysicsCliff`,
`PhysicsBuildingBlocker` and `PhysicsGround` interleave across lines 179–215, two
of them carry a doc comment above the `class` line, and any range either bites off
a neighbour's comment or carries away `PhysicsGround`, which the monolith still
needs — leaving a file that no longer compiles.

### The 12 suites, all `extends "res://tests/support/suite.gd"`

| # | File | Cases | Body lines | Est. file |
|---|---|---|---|---|
| S1 | `tests/combat/bullet_rules_run.gd` | 9 | 375 | ~430 |
| S2 | `tests/combat/projectile_flight_run.gd` | 11 | 392 | ~450 |
| S3 | `tests/combat/muzzle_fx_run.gd` | 5 | 443 | ~505 |
| S4 | `tests/combat/impact_fx_run.gd` | 3 | 268 | ~300 |
| S5 | `tests/combat/shot_fx_composition_run.gd` | 3 | 479 | ~515 |
| S6 | `tests/combat/turret_mount_run.gd` | 9 | 370 | ~430 |
| S7 | `tests/combat/fire_sequence_run.gd` | 3 | 166 | ~205 |
| S8 | `tests/combat/unit_fire_movement_run.gd` | 5 | 441 | ~485 |
| S9 | `tests/combat/unit_attack_order_run.gd` | 5 | 510 | ~555 |
| S10 | `tests/combat/building_geometry_run.gd` | 3 | 287 | ~325 |
| S11 | `tests/combat/defensive_building_run.gd` | 9 | 554 | ~605 |
| S12 | `tests/combat/deploy_fire_run.gd` | 9 | 426 | ~485 |

Contents below. The number is the case's **position in today's `_initialize`**
(extracted from `tests/combat/run.gd:245–452`); within each file, cases are
registered in strictly ascending order of that number. Each of the 74 appears
exactly once — verified.

- **S1** (1) armour_matrix · (2) target_domains · (3) bullet_delivery_rules ·
  (4) impact_effect_contract · (5) lingering_gas_damage ·
  (20) projectile_damage_scale_isolation · (21) impact_resolution ·
  (66) combat_targets · (67) shield_absorption
- **S2** (6) hitscan_projectile · (8) linear_projectile_no_lead ·
  (10) attack_ground_missile · (11) homing_projectile · (12) homing_flight_budget ·
  (13) trajectory_projectile · (14) elevated_trajectory_mounts ·
  (16) trajectory_moving_target_miss (+`PhysicsGround`) · (17) projectile_world_collision ·
  (18) continuous_stream_piercing · (19) continuous_stream_damage_split
- **S3** (7) laser_hitscan_visual · (25) muzzle_fx_bank_smoke · (26) model_fx_bank_casings ·
  (27) discrete_fire_skips_particle_streams · (28) model_fx_bank_streams
- **S4** (29) ground_decal_overlap_budget · (32) deviate_hit_impact_fx · (33) dev_impact_fx
- **S5** (30) turret_projectile_launch · (31) mongoose_launch_and_impact_fx ·
  (34) devastator_missile_launch_blast
- **S6** (22) turret_reload · (23) turret_fx_ownership · (24) continuous_turret_burst_reload ·
  (35) compound_turret · (36) single_axis_turret · (37) fixed_turret ·
  (38) multi_barrel_turret · (39) parallel_trajectory_salvo · (40) limited_turret_hull_turn
- **S7** (52) xbf_fire_event_timing · (53) launcher_fire_sequences ·
  (54) continuous_flame_sequences
- **S8** (41) fire_while_moving_capability · (42) blocking_fire_move_cancel ·
  (43) independent_side_turrets · (44) turret_recenter_after_move · (45) unit_turret_rebind
- **S9** (49) unit_attack_order · (50) ink_vine_refire ·
  (51) rejected_attack_perch (+`RejectingAttackNavigation`) · (55) far_attack_pursuit ·
  (56) obstructed_attack_order (+`PhysicsCliff`)
- **S10** (46) building_edge_range · (47) hktrooper_building_damage ·
  (48) hkstarport_courtyard_collision
- **S11** (57) building_turret_rebind · (58) defensive_building_auto_fire ·
  (59) defensive_building_visible_aim · (60) atrocket_turret_muzzle ·
  (61) defensive_turret_stop_clears_muzzle_flash (+2 helpers) ·
  (62) ordos_popup_turret_animations · (63) building_attack_order ·
  (64) building_obstructed_targets · (65) building_damage_visual_states
- **S12** (9) undeployed_kobra_shell_leaves_the_muzzle · (15) deployed_mortar_high_arc ·
  (68) kindjal_deployed_fire · (69) deployed_fire_completion_preserves_hidden_flash ·
  (70) kobra_deployed_hull_frozen · (71) kobra_deployed_range_acquisition ·
  (72) sardaukar_not_combat_deployable · (73) kobra_travel_fire_variants ·
  (74) kobra_travel_fire_pose_boundaries

Cases (9) and (15) look like ballistics but assert deploy-mode behaviour, hence S12.

`tests/combat/run.gd` and `run.gd.uid` are **deleted** at the end.

### Cleanup by wrapper, not by editing bodies

Preserving the relative order inside each file is necessary but not sufficient: the
single global sequence of 74 cases becomes 12 independent ones. Today only 6 cases
clear FX on entry; the rest rely on their predecessor having tidied up.

Cleanup is therefore expressed as **suite-local wrappers** around `_run_case` /
`_run_async_case`, not as edits to the bodies. Editing bodies for cleanup would
break the "moved verbatim" rule and devalue the assertion-count invariant. With
wrappers the bodies stay byte-for-byte, and `ImpactDebris` in S4 remains the single
exception to verbatim movement.

Two different wrappers are needed, because they clean different things:

- **S3, S4, S5** — `Fx.free_all(root)` before and after each case. This removes FX
  nodes tagged with the `combat_muzzle_fx` / `combat_impact_fx` /
  `combat_ground_decal` metas.
- **S10** — `Fx.free_all()` is useless here: what can leak are physics bodies
  (`HKStarport`, `HKGunTurret`, targets) that carry none of those metas. It needs
  its own wrapper: snapshot `root.get_children()` before the case and free whatever
  appeared afterwards. That is more reliable than auditing the trailing `free()`
  calls inside the bodies — on a runtime error such a `free()` simply never runs,
  whereas the wrapper always does, and the bodies stay verbatim.

A leaked static body does not fail; it silently changes raycast results for every
later case. That is the nastiest class of breakage in this refactor, and only
cleanup catches it — ordering does not.

## Move invariants

The guard from `multi_turret_run.gd:125` is one of four layers, and on its own it
does **not** close silent runtime failures (a case with one `_expect` before the
crash still reports `PASS`). All four are required:

1. **zero-assert guard** in `_run_case` and `_run_async_case` — catches a body that
   died before its first assertion, the typical symptom of a missing preamble or
   `preload`;
2. **`timeout --foreground`** on every run — catches a parse/compile error, which
   in headless mode does not terminate the process but drops it into an idle loop
   forever (AGENTS.md documents this symptom separately);
3. **an unchanged total assertion count across the cohort** — catches a case that
   died midway: it yields fewer assertions than it did in the monolith;
4. **case census**: 74 registrations **with no duplicates**, 74 `_test_*`
   definitions, and an **empty symmetric difference** between the two sets — not
   merely equal counts. The duplicate check is a mandatory separate step: `sort -u`
   on its own still reports 74 when a case is registered twice (the assertion sum
   would probably catch that, but the invariant should catch it by itself).

**The cohort is the shrinking `run.gd` plus the 12 new files, and nothing else.**
Its invariant is 74. The three sibling suites (`death_category_run.gd` 10,
`multi_turret_run.gd` 3, `authored_reload_sound_run.gd` 9) are outside it: counting
all of `tests/combat/` gives a baseline of 96, and swapping one number for the
other would mask a lost case.

The commands below were verified against the current `run.gd` and report
`74 / none / 74 / none / none`. `awk` takes the `_initialize` body up to the next
top-level `func`; a `_run_case` delimiter would not work, because after the move to
`suite.gd` no such function exists in these files and `sed` would read to EOF,
counting definitions as registrations:

```bash
cd tests/combat
# Cohort = run.gd + the 12 new files, but ONLY those that already exist:
# early on the new paths do not exist yet, and after stage 17 run.gd is gone.
ALL=(run.gd bullet_rules_run.gd projectile_flight_run.gd muzzle_fx_run.gd \
     impact_fx_run.gd shot_fx_composition_run.gd turret_mount_run.gd \
     fire_sequence_run.gd unit_fire_movement_run.gd unit_attack_order_run.gd \
     building_geometry_run.gd defensive_building_run.gd deploy_fire_run.gd)
COHORT=(); for f in "${ALL[@]}"; do [[ -f $f ]] && COHORT+=("$f"); done

reg_raw() { awk '/^func _initialize/{f=1;next} /^func /{f=0} f' "$@" \
            | grep -o '_test_[a-z_0-9]*'; }
def_raw() { grep -ho '^func _test_[a-z_0-9]*' "$@" | sed 's/^func //'; }

reg_raw "${COHORT[@]}" | wc -l                    # 74
reg_raw "${COHORT[@]}" | sort | uniq -d           # empty: no case registered twice
def_raw "${COHORT[@]}" | wc -l                    # 74
def_raw "${COHORT[@]}" | sort | uniq -d           # empty: no duplicated definition
comm -3 <(reg_raw "${COHORT[@]}" | sort) <(def_raw "${COHORT[@]}" | sort)   # empty
```

## Stages

The property preserved throughout: `run.gd` stays a working, monotonically
shrinking suite, and every stage can be reverted independently. The mechanical
call-site rewrite is a **separate commit before** the moves, so each move commit
contains nothing but whole functions that travelled verbatim.

**Stage 0 — baseline.** Before touching anything, record: the assertion total for
`run.gd` and separately for the three sibling suites, the wall time of each run,
and the case-census numbers for the cohort (74 / no duplicates / empty difference).

Also measure boot cost, since it decides whether all 12 files are worth it:

```bash
time timeout --foreground 180 ./tools/godot-container \
  godot --headless --path /workspace --script res://tests/combat/death_category_run.gd
```

104 lines with no scene loading is close to a pure Godot boot-cost probe. Under
~10 s: take all 12. Over ~15 s: consider merging S7 into S6 and S4 into S3. Check
the merged size **with an actual `gdlint` run, not arithmetic** — 536 and 711 are
body-line sums without preambles and registrations, while the full-file estimates
in the table above give 430+205 and 505+300.

**Stage 1 — guard the existing suites.** Add the zero-assert guard to `_run_case`
**and** `_run_async_case` of the monolith (`tests/combat/run.gd:453` and `:461`)
and to the three sibling suites. Run, and fix whatever it exposes. Keep it a
separate commit so any fallout is attributable to pre-existing tests rather than
to the split. If the assertion total changes, that must be explained by a specific
case, not waved through.

**Stage 2 — create `suite.gd`, prove it on the cheapest file.** Create
`tests/support/suite.gd` and convert **only** `tests/combat/death_category_run.gd`
(104 lines, no scenes). This smoke test confirms in one shot that a path-extended
`SceneTree` script boots under `--script`, that `_initialize` overrides, that
`quit()` from the base's `_finish` sets the exit code, and that gdlint accepts it —
for the price of one file instead of fifteen.

**Stage 3 — move the remaining three suites onto `suite.gd`.** For `run.gd`,
`multi_turret_run.gd` and `authored_reload_sound_run.gd`, delete **only** the
scaffolding: the counters, `_run_case`, `_run_async_case`, `_expect`; replace the
`_initialize` epilogue with `_finish(<label>)`. All combat-specific helpers,
including `multi_turret_run.gd`'s forks of `_free_muzzle_effects` and
`_horizontal_angle_between` and its doubles, **stay put at this stage**: the
support modules do not exist yet, and removing them now would leave three calls to
a function that is gone. Test bodies are untouched.

**Stage 4 — combat support modules, plus the mechanical call-site rewrite in
`run.gd` and `multi_turret_run.gd` together.** Create
`tests/combat/support/{combat_doubles,combat_fx_probe,combat_bullets,combat_assertions}.gd`.
Delete **by block name**: from `run.gd` — `FakeCombatTarget`, `PhysicsCombatTarget`,
`PhysicsBuildingBlocker`, `CombatSource`, the six FX probes, `_runtime_bullet`,
`_bullet_with_impact_scenes`, `_emission`, `_horizontal_angle_between`,
`var _combat_catalog`; from `multi_turret_run.gd` — its forks of
`_free_muzzle_effects` and `_horizontal_angle_between` and its reduced
`FakeCombatTarget` / `PhysicsCombatTarget`. **`PhysicsCliff`, `PhysicsGround` and
`RejectingAttackNavigation` stay in `run.gd`** — their consumers are still there.

Before deleting the forks, confirm one divergence: `multi_turret_run.gd`'s
`PhysicsCombatTarget.combat_hit_radius()` returns a hardcoded `0.5`, whereas the
shared one returns the constructor radius. All of its call sites use the default
`0.5`, so the substitution is behaviour-identical. Its `FakeCombatTarget` is a
strict subset of the shared one.

Rewrite scope, both files together:

| From | To | Sites |
|---|---|---|
| `_runtime_bullet(rules, id)` | `_bullets.runtime_bullet(id)` | 33 |
| `_emission(p, d)` | `Bullets.emission(p, d)` (static) | 17 |
| `_combat_catalog.bullet/warhead(...)` | `_bullets.bullet_config/warhead_config(...)` | 8 |
| `_bullet_with_impact_scenes(id)` | `_bullets.bullet_with_impact_scenes(id)` | 3 |
| the six FX probes | `Fx.<same>(root, ...)` | **54** (51 + 3) |
| the 4 shared doubles | `Doubles.<same>` | **~55** (19+25+2+4 in `run.gd`, +5 in `multi_turret_run.gd`) |
| `_horizontal_angle_between(a, b)` | `Assertions.horizontal_angle_between(a, b)` | **7** (6 + 1) |

No logic changes; `_expect` (522 sites) is untouched because it is inherited. The
dead first argument `_rules` of `_runtime_bullet` is dropped along the way.

**Stages 5–16 — one file per commit.** Each commit: move the `_test_*` bodies
**verbatim** (in ascending registration order), move their registrations, add the
file's `preload` block and **only** the support modules listed in the dependency
matrix, add the path to `SUITES`, generate the `.uid`, run **both the new suite and
the shrinking `run.gd`**, and check all four invariants.

Order — least-coupled first, FX-coupled last, so the risky ones happen when the
mechanics are already boring:

`S1` → `S6` → `S7` → `S12` → `S2` → `S10` → `S8` → `S9` → `S11` → `S3` → `S4` → `S5`

S1/S7/S12 do not depend on accumulated FX state in `root` (their firing may well
create FX — no assertion of theirs inspects it); S3/S4/S5 read `root`'s children
and go last, when `run.gd` is nearly empty and the source of any contamination is
obvious. `PhysicsGround` / `PhysicsCliff` / `RejectingAttackNavigation` travel with
S2 and S9; `_authored_flash_nodes` / `_flash_departed_from_rest` travel with S11.

**When S4 is created (not deferred to stage 17)**, add
`const ImpactDebrisScript := preload("res://scripts/combat/fx/impact_debris.gd")`
and replace the references to `ImpactDebris`: there are **20**, all of the form
`ImpactDebris.X`, across 18 lines in the ranges 5139–5169 and 5174–5210 (two further
mentions, in doc comments at 5023 and 5025, need no change). This is the one place
where "moved verbatim" is deliberately broken: a bare `class_name` reference is
exactly the failure AGENTS.md records as having already bitten this repository once.

**Stage 17 — retire and ratchet.**

- delete `tests/combat/run.gd` and `run.gd.uid`, and drop its `SUITES` entry;
- repoint the 11 prose references to `tests/combat/run.gd` — they are load-bearing,
  explaining why a given public method exists:
  `scripts/units/unit_combat.gd:148,765,774`, `scripts/units/unit.gd:53,58,159,811`,
  `scripts/combat/combat_turret.gd:106` (→ S5), `:1463`,
  `scripts/combat/fx/impact_debris.gd:406` (→ S4),
  `tests/units/death_animation_run.gd:188` (→ S8);
- lower `max-file-lines` **5000 → 2600** and update the ratchet comment. 800 is
  still blocked: `tests/navigation/run.gd` (2587),
  `converters/model_bake_builder.gd` (2469) and `tests/characterization/run.gd`
  (2064) are all above it.

## Check expectations per stage

| Stage | `check_architecture.sh` | `gdlint` |
|---|---|---|
| 0–3 | green | exactly **one** error: `max-file-lines` on `tests/combat/run.gd` |
| 4 | green | **zero or one**, and the only permissible one is that same `max-file-lines` |
| 5 (S1 moved) onward | green | zero |

The fork at stage 4 is not sloppiness: removing the scaffolding and the modules
takes roughly 240 lines out of the monolith, landing at ~4990–5010 — on both sides
of the limit, with the exact value depending on how many lines the moves collapse.
Demanding exactly one error there would be wrong, and so would celebrating zero.
`make lint` should only be considered fixed after S1, when a further 375 lines of
bodies leave. Until then the red line is expected and is not a regression — it is
already there today.

## Risks

- **Silent runtime failures during the move** — addressed by all four invariants
  together, not by the guard alone.
- **The `_initialize` preamble** — every new suite needs
  `LegacyRulesFixture.install(root)` and `await process_frame`; ~40 cases call
  `root.get_node("Rules")` and hard-fail without it. The zero-assert guard turns
  that into a loud FAIL rather than a green run.
- **Coupling through `root`** — addressed by the suite-local wrappers:
  `Fx.free_all(root)` in S3/S4/S5 and the snapshot wrapper in S10 that frees the
  children which appeared, rather than by relying on neighbouring cases.
- **Process count** — 4 combat suites become 15, run serially (AGENTS.md forbids
  parallel container runs). The suites contain only ~4.5 s of real `create_timer`
  waiting, so the cost is 11 extra Godot boots; the 10-suite fallback means 13
  processes and 9 extra boots. Decide from the stage-0 measurement. Time the
  current `run.gd` as well: with 60 `await`s it may be approaching the 180 s
  `timeout`, in which case the split also removes a real timeout cliff.
- **`.uid` sidecars** — 17 new scripts (15 in the 10-suite fallback), plus the
  deletion of `run.gd.uid`. Godot regenerates them on a headless import: run
  `make godot-check`, then `git status --porcelain tests/ | grep '\.uid$'`, and
  stage them **in the same commit as the script**. The repository already carries a
  patch-up commit for exactly this omission.
- **`SUITES` stays an explicit list.** Do not switch to a glob:
  `tests/perf/demo_match_perf_run.gd` matches `*_run.gd` but is deliberately
  excluded from `make godot-test`, and `tests/navigation/jitter_probe.gd` and
  `tests/buildings/collision_probe.gd` are not suites at all.
- **Branch conflicts.** At the time of writing the state is clean: no working-tree
  changes, and `tools/run_godot_tests.sh` is identical in both worktrees. But a
  second worktree exists — `/tmp/openebfd-construction-sfx-events`, branch
  `codex/construction-sfx-events` — and a 5228-line file is being rewritten, so any
  parallel work on `tests/combat/run.gd` produces an unmergeable conflict. Re-check
  `git worktree list` and `git status` before starting, agree to freeze the file,
  keep the whole sequence on one branch, and land it quickly.

## Deliberately out of scope

- **A `spawn_unit(model_scene, config_id)` fixture.** Roughly 30 cases repeat the
  `UnitScene.instantiate()` → `config_id` → `add_child` → `replace_visual_scene` →
  pump-N-frames preamble, and extracting it would save another ~300 lines — but it
  rewrites test bodies. The size target is met without it; do it later, per file.
- **Splitting `_test_unit_attack_order`** — 276 lines for a single case, 6% of the
  whole suite behind one `PASS` line. It should become 4–5 cases, but in a
  **separate commit after** S9 exists, never during the move.
- **Migrating the other 30 suites onto `suite.gd`.** The base is built for that,
  but the migration is separate work and must not be mixed into the combat split.

## Verification

After **every** stage:

```bash
./tools/check_architecture.sh              # silence + exit 0, always
./tools/godot-container lint               # see the expectations table above
```

Run the affected suites individually, always under `timeout` and without buffering
the output (a headless "hang" is a compile error — see AGENTS.md; `| tail` hides
`SCRIPT ERROR` until a process exit that never comes):

```bash
timeout --foreground 180 ./tools/godot-container \
  godot --headless --path /workspace --script res://tests/combat/<new>_run.gd
timeout --foreground 180 ./tools/godot-container \
  godot --headless --path /workspace --script res://tests/combat/run.gd
```

A move counts as successful only when all four invariants from "Move invariants"
hold — in particular when the sum of `N assertions passed` **across the cohort**
(`run.gd` plus the new files, excluding the three sibling suites) matches the
stage-0 baseline.

Final check (container runs strictly sequential):

```bash
make godot-test        # unit-definitions-check + lint + every suite
```
