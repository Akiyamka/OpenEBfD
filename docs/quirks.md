# Original Engine Quirks

This document records gaps, contradictions, and implicit behavior in the
original game's data and engine. Each entry separates facts visible in the
shipped data from compatibility decisions made by OpenEBfD.

## Production

### Construction Yard upgrades have no build-time field

**Observed data:** The `ATConYard`, `HKConYard`, and `ORConYard` sections in
`Rules.txt` define `UpgradeTechLevel = 4` and `UpgradeCost = 600`, but define
neither `BuildTime` nor `UpgradeBuildTime`. They do contain `Resource = MCV`.
The `MCV` unit has `BuildTime = 864`.

**Original-engine quirk:** Construction Yard upgrades are not instantaneous,
so their duration must be derived or hardcoded outside the visible ConYard
fields. The exact original derivation has not been verified.

**OpenEBfD compatibility decision:** When a global upgrade has no
`BuildTime`, follow its `Resource` link and use the linked entity's build time.
Construction Yard upgrades therefore use the MCV's 864 ticks. A 60-tick
fallback is reserved for malformed configs with neither a direct time nor a
usable resource link.

## Animation timing

### Infantry base movement animation is too slow

**Observed behavior:** At its configured normal movement speed, infantry's
`Move` animation plays noticeably slower than the unit travels across the
ground. Dynamic scaling still follows changes in the actual movement speed,
but the clip's base rate is too low.

**OpenEBfD compatibility status:** No per-model base-rate correction has
been established yet. The infantry `Move` clip needs a tuned baseline speed
multiplier.

### Wind-blown flag animation is too fast

**Observed behavior:** Building flags animated as if blown by wind cycle at an
anomalously high speed relative to the rest of the scene.

**OpenEBfD compatibility status:** No correction is applied yet. The
flag animation rate needs separate tuning so it is not affected by unrelated
unit movement animation scaling.

## Unit models

### Three unit rules have no convertible H0 model

**Observed data:** `ATHawkWeapon` and `ORBeamWeapon` have art-config entries
but no `xaf` model field. Their rules only reference effect resources
(`ATPalaceBeam`/`Hawk_B` and `ORPalaceLightning`/`Beserk_B`, respectively).
`GUWormCatcher` has `xaf = GU_WormCatcher`, but no matching
`GU_WormCatcher_H0.xbf` exists in `3DDATA/Units`.

**Original-engine quirk:** These unit definitions do not provide a standalone
H0 model through the shipped rules and unit-model files.

**OpenEBfD compatibility decision:** `convert_all_units.gd` reports and
skips these three definitions. It generates scenes for every unit with a
resolvable H0 source model; effect-only units remain represented by their
referenced effects rather than placeholder meshes.

### Harkonnen Trooper muzzle flash has a misspelled object name

**Observed data:** `HK_Trooper_H0.xbf` stores its embedded muzzle-flash
geometry in an object named `flah~?`. Other unit models use names containing
`bigflash`, which is the normal marker recognized by the model converter.
The `flah~?` transform remains at a tiny scale during stationary and idle
clips, then expands during `Fire_0`.

**Original-engine quirk:** The shipped Harkonnen Trooper model uses this
misspelled, model-specific name for authored muzzle-flash geometry. Treating
it as ordinary geometry leaves its mesh visible during idle animations.

**OpenEBfD compatibility decision:** `ModelBakeBuilder` recognizes
`flah~?` as embedded muzzle-flash geometry only when converting
`HK_Trooper_H0.xbf`. Its mesh is hidden by default and in non-fire clips, and
is enabled for `Fire_0`, matching the existing handling of `bigflash`
objects without broadening the typo to unrelated models.

### Harkonnen Flamer has corrupt static transforms and trailing frames

**Observed data:** `HK_Flamer_H0.xbf` declares 592 object-animation frames,
but its final named clip (`Stationary`) ends at frame 583. Several object
transforms in frames 584..591 contain `Inf`, while `!#box11` contains finite
but implausible values around `2.9e8`. No animation-table entry references
these eight trailing frames. The stored static transforms for `!#box04` through
`!#box11` (including `gunbone`) are corrupted in the same way: three contain
`Inf`, and the remaining matrices contain values as large as roughly `1e33`.
Their animation timelines all begin with valid authored transforms.

**Original-engine quirk:** The unused tail is malformed source data rather
than part of an authored action. The original engine also replaced the bad
static matrices from animation before rendering. Baking them verbatim makes
Godot's 3D editor instantiate the invalid static pose before autoplay can
apply `Stationary`, producing non-finite renderer transforms.

**OpenEBfD compatibility decision:** For the nine affected nodes,
`ModelBakeBuilder` uses the first valid animation frame as the static pose and
omits object-transform keys after frame 583. Named clips, vertex animation,
and FX timing remain unchanged. As a general safety invariant, any other
non-finite source transform holds the preceding valid pose instead of being
serialized into a converted scene.

### Six source models store non-finite static object matrices

**Observed data:** A sweep of all 1271 source XBFs finds six files whose
objects store `NaN`/`Inf` static matrices while their animation timelines are
authored normally: `IM_ADVSardaukar_H0` (`gun`, `Visorlight`, `blade` — all
828 frames finite), `HK_Flamer_H0` (see above), `HK_gunturret_h3` (twelve
objects, including every barrel), `HK_barracks_H3` (`HKBarracks11%`),
`hk_palace_h3` (`pannel 06`, `Box06`) and `hk_starport_H3` (`Box12`,
`hk_sp_footplate2`).

**Original-engine quirk:** The original engine drove these objects purely
from animation and never rendered the stored static pose, so the corrupt
matrices were invisible there. Godot does render it: a converted scene
instantiated in the editor pushes the rest pose to the renderer before any
clip plays, and every `NaN` node makes `instance_set_transform` fail with
`Condition "!v.is_finite()" is true` on each redraw. Playing the scene hides
the defect, because autoplay overwrites the pose before the first frame.

**OpenEBfD compatibility decision:** `ModelBakeBuilder` treats a non-finite
static matrix as unusable data and takes the same path as the per-file
`STATIC_TRANSFORM_ANIMATION_FALLBACKS` table: the first finite animation
frame becomes the node's static pose, sanitized into a valid basis, falling
back to identity when the object has no finite frame at all. No per-file
entry is needed for this class of defect; the table now only covers matrices
that are finite but too distorted to be a valid basis.

## Units

### Advanced Sardaukar knife is flagged as a deployed-only weapon

**Observed data:** `Rules.txt` marks `IMADVSardaukarKnife` as
`turret_disable_if_unit_undeployed = yes` and `IMADVSardaukarGun` as
`turret_disable_if_unit_deployed = yes`. Read literally, this is a deploy
pair: gun active while undeployed, knife active only while deployed — the
same shape as `ATKindjal` / `ORMortar` / `ORKobra`'s real travel/deployed
turret pairs.

**Original-engine quirk:** The Advanced Sardaukar has no deploy ability at
all. The knife is a melee weapon the original engine selects by attack
range against an adjacent target, not a mode unlocked by a deploy state.
The `turret_disable_if_unit_*` flags on this unit are stale or mis-set data
left over from copying a deployable unit's turret rows.

**OpenEBfD compatibility decision:** `tools/generate_unit_definitions.py`
applies a `TURRET_DEPLOY_GATE_OVERRIDES` table that clears both flags when
generating `IMADVSardaukarGun.tres` / `IMADVSardaukarKnife.tres`, so both
turrets are always active and the unit is excluded from the (otherwise
data-driven) combat-deploy eligibility rule — "has at least one turret
gated `disabled_when_deployed` and at least one gated
`disabled_when_undeployed`" — which would otherwise spuriously match it
alongside the three real combat-deployable units.

### OR Mortar ships a static duplicate gun barrel

**Observed data:** `OR_Mortar_H0.xbf` defines two top-level gun objects with
identical geometry (`Mortorgun` and `Mortorgun01`, same 8-vertex/12-triangle
box, same local bounding size). `Mortorgun` carries object-animation keys
across the full 971-frame timeline and matches every clip. `Mortorgun01`
carries 426 keys, but every one of them holds the exact same transform - it
never actually moves. Its children `gunleg03`/`gunleg04` duplicate
`Mortorgun`'s `gunleg1`/`gunleg2`. Clips authored past frame 425 (`Stationary`,
`Shot_1/2`, `Blow_Up_1/2`, `Deployed_Death_1/2`, `Undeploy_Gun`, `Win`,
`Gassed_1`, `Run_Over_1`) have zero keys at all on `Mortorgun01`'s track. Its
only real purpose is carrying the `::1gun#`/`>>1gun#` attachment markers,
which the FX event table uses to anchor the `Fire_1` muzzle bank
(`913E0570#497`/`#498`, frames 422-429).

**Original-engine quirk:** `Mortorgun01` is authoring scaffolding for the
`1gun` attachment point, not a second visible barrel. The original engine
apparently never rendered it; OpenEBfD's converter had no signal to
distinguish it from real geometry, so it rendered as a motionless, oversized
duplicate of the real barrel sitting near the mount point in every clip.

**OpenEBfD compatibility decision:** `ModelBakeBuilder` hides
`Mortorgun01`'s mesh (and its `gunleg03`/`gunleg04` children) via
`HIDDEN_SOURCE_MESH_COMPONENTS`, tagged `source_asset_quirk =
"unrendered_duplicate"`, the same mechanism used for the Atreides Refinery's
broken geometry. The node, its transform, and the `::1gun#`/`>>1gun#`
attachment markers are kept so the `Fire_1` muzzle FX still anchors correctly.

### Howitzer_B has no Speed — the undeployed Kobra detonated its own shell at the muzzle

**Observed data:** `[HOWITZER_B]` in `Rules.txt` is headed `//not used`, spells
out `MaxRange = 8`, `Damage = 300`, `BlastRadius = 64`,
`FriendlyDamageAmount = 50`, and carries its `Trajectory = true` line commented
out. It has no `Speed` at all. Yet the section is used: `[ORKobraUndeployedGun]`
(`//fixed weapon, can't move it`) fires it, with the explicit comment
`//this must not be a trajectory bullet`. It is the only bullet of the 72 with
no `Speed`, no `Trajectory` and a non-zero `MaxRange` — every other speedless
bullet is either conceptual (`Speed = -1`, 19 of them), a trajectory shell, or
a `MaxRange = 0` "blow up immediately" bomb.

**Original-engine quirk:** The three delivery kinds are distinguished by
`Speed`/`Trajectory`, and `Howitzer_B` matches none of them. A section marked
"not used" was never balanced against a live engine, so the missing `Speed`
went unnoticed in the source data; the shipping Kobra's travel-mode gun was
presumably never observed firing.

**OpenEBfD compatibility decision:** `CombatProjectile.launch()` reads
`speed() <= 0.0` as "arrives instantly, at the muzzle" — correct for the
`MaxRange = 0` bombs, but for `Howitzer_B` it meant the undeployed Kobra
detonated a 64-unit blast at its own barrel tip and took 50% friendly damage
from it. `tools/generate_unit_definitions.py` supplies the missing value
through `BULLET_SPEED_OVERRIDES`: `Howitzer_B` gets `28`, the direct-fire tank
shell speed of `HEAT_B`/`Rocket_B`, which share its `shell.xaf` projectile.
That keeps the turret comment's requirement (still not a trajectory bullet)
and leaves `rules.db` faithful to `Rules.txt`.

### The shell's propulsion flare is authored, then switched off by its own model

**Observed data:** `shell.xbf` — the projectile model shared by both Kobra
shells, the Minotaurus and nine other bullets — contains a helper object
`?flashl02` holding two meshes of rocket-exhaust geometry. The model's FX
timeline (one frame long) carries exactly two events: a type 3 that starts
particle bank `563844F0#23` (texture `!%FFlash`, 5 texture frames, size 0.125
world units, no gravity) on attachment `shell~~0`, and a type 1 naming
`?flashl02`. There is no type 2 for it anywhere.

**Original-engine quirk:** The FX event types encode visibility as a pair —
type 1 hides the named object, type 2 shows it. The muzzle-flash helpers prove
the direction: `AT_Kindjal`'s, `OR_Mortar`'s and `IM_Sardaukar`'s `?bigflash1`
each blink for one to five frames per shot, always from a type 2 to the
following type 1, and every sequence ends on a type 1. Across all 948 FX-bearing
XBFs the two types are paired this way (1771 type 1, 1169 type 2), and
`shell.xbf`'s `?flashl02` is the single `?`-prefixed object in the whole set
whose only event is a lone type 1 — geometry that ships with the model and is
switched off for good on frame 0. The shot the player sees is a dark casing,
plus a brief `!%FFlash` puff at the muzzle from the bank that starts on the
same frame. User-confirmed against the reference game: no continuous flare.

**OpenEBfD compatibility decision:** `CombatProjectile._hide_switched_off_fx_objects`
reads the instantiated model's own `xbf_fx_events` and hides every object that
receives a type 1 and no type 2 at all, matching by the `original_name` meta.
This replaced a `NO_PROPULSION_FLASH_BULLETS` allowlist that named
`KobraHowitzer_B` alone and therefore left the flare burning on `Howitzer_B`
and `StraightBomb`, the other two bullets that visibly fly this model. Objects
the model does blink stay untouched, under the animation's control. The
`!%FFlash` launch puff is authored data that runtime does not emit yet: bank
playback exists for turrets (`combat_turret_fx.gd`) and locomotion, not for
projectile models. See docs/open_questions.md, "Projectile models author their
own FX bank, and nothing emits it", for why its duration is not yet settled.

### Bullets have no lifetime field — MaxRange serves as both range and budget

**Observed data:** The `Bullets` section of `Rules.txt` carries `MaxRange`,
`MinRange` and `Speed`, but nothing describing how long a shot stays alive.
72 bullets, 11 of them `Homing` (`HEAT_B`, `Rocket_B`, `TrailMissile_B`,
`HomingMissile`, `DevRocket_B`, `GuildRocket_B`, `Gunship_B`, the HEAT
variants), together with `HomingDelay` and `TurnRate`, which describe steering
but not endurance.

**Original-engine quirk:** `MaxRange` does double duty — it is the distance at
which a turret may open fire *and* the distance the emitted projectile may
travel. For straight shots the two coincide. For a homing missile they do not:
steering toward a moving (especially retreating) target makes the flown path
longer than the straight line that was range-checked at launch, so the missile
runs out of budget in mid-air against a target that was comfortably in range
when it fired.

**OpenEBfD compatibility decision:** flight budget is separated from
firing range. `BulletDefinition.flight_range_scale` multiplies `MaxRange` for
the projectile's travel allowance only; turret range checks
(`CombatBullet.maximum_range_world`) are untouched. The generator
(`tools/generate_unit_definitions.py`) assigns `HOMING_FLIGHT_RANGE_SCALE`
(1.5) to every `Homing` bullet and 1.0 to the rest, with
`FLIGHT_RANGE_SCALE_OVERRIDES` for per-bullet exceptions. `CombatProjectile`
spends that budget in `_maximum_flight_distance` and still expires with
`range_exhausted` once it is gone.

## Explosions

### `chained_explosion_type_id` was speculative schema, not lost data

**Observed data:** `explosion_configs.chained_explosion_type_id` was NULL for
all 11 rows in `assets/converted/rules.db`. `tools/rules_editor/parse_rules.py`
never populated it (the file does not contain the string "chain" at all), and
`assets/raw_original_content/MODEL/*.txt` (`Rules.txt`, `ArtIni.txt`, etc.)
have no "chain" hits either, case-insensitively. Explosion sections in the
source only ever carry `FaceCamera` and `DamageToTile`, matching the table's
other two real columns (`face_camera`, `damage_to_tile`).

**Original-engine quirk:** There is no distinction here to record — unlike
the `Shot` bullet flag (fixed in `44fb405`), where the source data genuinely
had the value and the parser dropped it, `chained_explosion_type_id` was
never backed by anything in the source. It was added to the schema alongside
a foreign-key mapping entry in `converters/import_rules.gd` in anticipation of
a "chained/secondary explosion" concept that the original engine's data does
not express. Do not read "chained explosions are unimplemented" out of this;
the concept simply does not exist in the source to implement.

**OpenEBfD compatibility decision:** The column, its schema declarations
(`assets/converted/schema.sql`, `tools/rules_editor/schema.sql`), and its
`FK_TARGETS` mapping entry were removed, with a comment left in the schema
files so the column is not reintroduced. `assets/converted/rules.db` had the
column dropped in place (not reparsed, to preserve unrelated manual
convert-stage fixes such as the per-house MCV split).

Contrast with `explosion_configs.face_camera`: also unread by any runtime
code today, but it *is* real data — set for `DHBigExplosion`, `ATHawk`, and
`VetLevelFX`, all super-weapon effects that are simply not implemented yet.
That one stays; it is pending, not dead.

### `DeviateHit` authors two green-tinted banks of the same generic smoke shape; only one is built

**Observed data:** `assets/converted/impact_effects/deviatehit/deviatehit.scn`
(the `ORDeviator`/`ORGasTurret` impact effect, `Deviate_B`/`Gas_B`) is a
marker-only FX rig like `ShellHit`/`MissileHit` (see
`scripts/combat/fx/impact_debris.gd`), but it authors *two* independent FX
banks of the same generic smoke-puff shape (also seen authored into several
factory/hangar models, e.g. `AT_Factory_H0.xbf`, as plain vent steam, and into
the Chemical Trooper's poison spray as `!sm`): one on marker `?#bigbing~~0`
using texture sequence `!cexp`, bank-tinted dark green
(`int_parameters_7_11 = [0, 128, 0, ...]`), and one on `?#bigbing2` using
`!sess`, tinted a brighter green (`[0, 180, 0, ...]`) — the same
`int_parameters_7_11` field `CombatTurretFx._fx_bank_material()` already reads
for muzzle particles. Neither texture is inherently "the gas one" or "the
explosion one": rendering the raw, *untinted* `!cexp*.tga` frames shows a
bright orange/yellow puff (because it is the identical sprite sheet
`MongooseLaunchSmoke` uses untinted for its backblast), which is misleading
read in isolation — the bank's own tint is what actually decides how it
reads in-game.

**Original-engine quirk:** Both banks are genuinely present in the source XBF
event table and were presumably both drawn by the original engine — it is not
a parser gap, both are real data. Reusing one grayscale puff texture across an
explosion smoke trail, factory steam, and this weapon's gas cloud, recolored
per bank via `int_parameters_7_11`, is a deliberate original-engine art-economy
pattern: the same sprite sheet stands in for several unrelated effects instead
of authoring a dedicated texture for each.

**OpenEBfD compatibility decision:** An initial implementation missed the bank
tint entirely and rendered `!sess` in its raw (grayscale) colors, then dropped
`!cexp` because its *untinted* render read as an unrelated orange fireball —
both mistakes traced back to judging the texture instead of the authored bank
tint. With `int_parameters_7_11` now wired through as an explicit `tint` field
on `ImpactDebris`'s burst pieces (read straight from each bank, e.g.
`DEVIATE_BURST_TINT`, `DEV_IMPACT_TINT`), only the `!cexp`/`?#bigbing~~0` bank
is built for `DeviateHit`, tinted dark green: confirmed in-game as the correct
single gas-detonation piece, with `!sess`'s bank left wired in the source
scene but unused as a duplicate swirl. Revisit if further evidence (e.g.
original gameplay footage) shows both banks were meant to play together.

### Duplicate `ExplosionType` keys are overrides, not a list of effects

**Observed data:** Three `Rules.txt` sections declare `ExplosionType` twice:
`[DevPlasma_B]` (`ShellHit`, then `DevImpact` eleven lines later),
`[IXInfiltrator]` (`Explosion` at 9826, `InfiltratorDeath` at 9839) and
`[HKFactory]` (`BigExplosion` twice, identical so inert).
`tools/rules_editor/parse_rules.py::parse_explosion_types_multi` read the
repeats as an ordered *list* of effects and kept them all, which made
`DevPlasma_B` the only bullet out of 72 with two impact effects.

**Original-engine quirk:** Repeating a scalar key in this INI-style file is an
override, and the rest of `Rules.txt` is full of the same pattern — `ATAPC
Speed 8.0 -> 12.0`, `ATOutpost Health 100 -> 2500`, `GUWormhead Armour Heavy ->
Light`, `General DeviateDuration 400 -> 500` — none of which anyone reads as a
list. These look like edits where a new value was appended without deleting the
old line.

Reading them as a list was not a harmless extra: in game, `DevPlasma_B` spawned
`ShellHit` (the generic rocket/shell burst, with its shrapnel spray and orange
flash) *on top of* its real `DevImpact` cloud, and the stale effect visually
swallowed the intended one — reported from play as "the Devastator's special
impact is missing, it plays the ordinary rocket effect instead."

One wrinkle rules out a purely lexical last-wins: `IXInfiltrator`'s later value
`InfiltratorDeath` is a **bullet**, not an explosion type (there is no
`[InfiltratorDeath]` explosion section), so it resolves to nothing. Taking it
literally would strip that unit's death explosion entirely.

**OpenEBfD compatibility decision:** `parse_explosion_types_multi` now keeps a
single name — the last one that actually resolves to a known explosion type, so
an unresolvable later value leaves the previous one standing. Results:
`DevPlasma_B` -> `DevImpact` alone, `IXInfiltrator` -> `Explosion` (unchanged),
`HKFactory` -> one `BigExplosion` link instead of two. The function still
returns a list and `entity_explosion_effects` keeps its `seq` column, so a
genuine multi-effect entity stays expressible; the shipped data simply has
none. `assets/converted/rules.db` was patched in place to match rather than
reparsed, preserving the manual convert-stage fixes it carries (the per-house
`HKMCV`/`ORMCV` split, which a fresh parse drops).

Knock-on worth knowing: `DamageToTile` lives on the *explosion* section, and
there is no `[DevImpact]` section at all, so honoring the override also means
the Devastator's plasma no longer paints a ground crater (`ShellHit` authors
`DamageToTile = 30`). That follows from the source data rather than being a
separate choice.

## Audio

### ImportedSfx.txt shadows several death hooks with unconverted localized names

**Observed data:** `tools/generate_voice_feedback.py`'s `parse_sources()` keys
SFX sections by `section_name.casefold()` and lets the last source file (in
casefold-sorted filename order) that defines a given name win.
`ImportedSfx.txt` sorts after `AtreidesSFX.txt`, `GeneralSFX.txt`, and
`HarkonnenSFX.txt`, but before `ORDOSSFX.TXT`. Six death hooks are genuinely
shadowed by this: `AtreidesSFX.txt`/`HarkonnenSFX.txt` define real,
multi-sample per-house hooks — `[atnormalmandying]`/`[hknormalmandying]`
(22-sample `normal_dying_1..22`), `[atburningmandying]`/`[hkburningmandying]`
(8-sample `burn_dying_1..8`), `[atchoking]`/`[hkchoking]`
(`choke_dying_1..6`) — and `GeneralSFX.txt` defines a real `[YakDying]`
(`yak_death_1`/`yak_death_2`). `ImportedSfx.txt` redefines the same
casefolded names (`[ATNORMALMANDYING]`, `[ATBURNINGMANDYING]`,
`[ATCHOKING]`, `[HKNORMALMANDYING]`, `[HKBURNINGMANDYING]`, `[HKCHOKING]`,
`[YAKDYING]`), each pointing at a single localized sample name
(`$ATKillguy1`, `$ATburningManDying`, `$ATChoking1`, `$HKKillguy1`,
`$HKburningManDying`, `$HKChoking2`, `$YakDying`) that does not exist
anywhere in the converted WAV archive (`assets/converted/audio/sfx/`).
Ordos's equivalent hooks are unaffected: `ORDOSSFX.TXT` sorts after
`ImportedSfx.txt` and re-wins with its own real samples. A further eight
death-hook ids (`CONTAMDYING`, `ENDWORMDYING`, `FLESHVATDYING`,
`LEECHDYING`, `TLWALKERDYING`, `AT`/`HK`/`ORDICEDMANDYING`) are *not*
shadowing cases — `ImportedSfx.txt` is their only definition, and it always
pointed at an unconverted localized name — but they resolve to zero samples
for the same underlying reason.

**Original-engine quirk:** Not verified whether the original engine actually
played these hooks silently, or whether the `$`-prefixed localized names
resolved through a per-language string/audio table the shipped `SFX/*.txt`
files don't describe on their own.

**Why this is a correctness bug, not just missing polish:** `Unit`'s death
sound resolution (death-animation plan §6) walks an ordered candidate list —
per-house hook, then generic fallback — and stops at the first id *present*
in the generated `DEATH_EVENT_PATHS` manifest. Before this was fixed, the
shadowed per-house ids were still emitted as valid-looking `SoundEvent`
resources with empty `sample_paths`, so they counted as "present": the
resolution picked `atnormalmandying`/`hknormalmandying` and never reached the
real 22-sample generic `normalmandying` hook. Atreides and Harkonnen infantry
— by far the most common death in the game — would have died in total
silence, while Ordos worked only by accident of `ORDOSSFX.TXT` sorting last.

**OpenEBfD compatibility decision:** Fixed at the convert stage, per
this project's rule that wrong source data is corrected where it is
converted rather than papered over with a runtime special case.
`tools/generate_voice_feedback.py`'s `main()` now drops any death/explosion
event whose referenced samples are *all* unresolved against the WAV archive
entirely — it is not written to `resources/audio/events/`, not added to
`expected_events` (so a stale file from a previous run would be removed, not
kept), and not added to `DEATH_EVENT_PATHS`. With the shadowed ids simply
absent from the manifest, `Unit`'s existing candidate-list resolution falls
through to the generic hook on its own, with no runtime "present but empty"
check needed. The generator prints a distinct warning
("N death/explosion events dropped entirely") so this is visible in
`voice-feedback`/`voice-feedback-check` output rather than silent. Voice
(Selection/Move/Attack) events are deliberately left on the old
always-write behavior in this pass — none currently resolve to zero
samples, so there was nothing to change, and applying the same drop rule to
voice events would need `tests/audio/voice_feedback_run.gd`'s expectations
revisited first.

**Superseded for the six per-house infantry hooks.** Once the death voice
became data-driven (see "Infantry death voices are authored in the model, not
derived from the death cause" below), falling through to the generic hook
stopped being good enough: the model names `ATNormalManDying` specifically, and
that section carries an `FShift` the generic `[NormalManDying]` does not. All
six — plus `[atcrush]`/`[hkcrush]`, shadowed the same way — are now listed in
`SHADOW_PROOF_EVENT_IDS`, so the real Atreides/Harkonnen definitions win over
the localization stub and reach `DEATH_EVENT_PATHS` with their real samples.
The drop-empty-events rule above still stands for everything else, `[YAKDYING]`
and the eight never-defined-in-English ids included.

**The same shadowing hits two reload hooks.** `AtreidesSFX.txt` defines real
`[atsniperreload]` and `[frwarriorreload]` sections (both
`Sounds = kindjal_infantry_reload_1`, `Volume = 40`) and `ImportedSfx.txt`
redefines both as `[ATSNIPERRELOAD]`/`[FRWARRIORRELOAD]` pointing at
`$Atsniperreload`/`$FRwarriorreload`. Those two names are what
`AT_Sniper_H0`, `AT_Kindjal_H0` and the AT Pillbox author in their own fire
clips (see "Weapon reload sounds are authored in the fire clip" below), and
unlike the death hooks there is no generic spelling to fall through to — the
model names one section and nothing else claims it — so losing them loses the
sound outright. Both are in `SHADOW_PROOF_EVENT_IDS`.

`[HKINKVINERELOAD]` and `[HKMISSILETANKRELOAD]` look like the same case and
are not: `ImportedSfx.txt` is their *only* definition anywhere, so they belong
with the eight never-defined-in-English death ids. `HK_Inkvine_H0` authors
`HKinkvinereload` in its `Fire 0` and it is genuinely silent. Do not
"shadow-proof" them — there is nothing behind the stub to recover.

### Infantry death voices are authored in the model, not derived from the death cause

**Observed data:** every infantry `.XBF` under
`assets/raw_original_content/3DDATA/Units/` carries FX **event type 9**
records: one SFX section name pinned to one frame, and that frame falls inside
the frame range of exactly the death clip it belongs to (both halves are baked
onto the model root as `xbf_fx_events` / `xbf_animation_entries`). The scream
is therefore a per-model, per-clip authoring decision, not a function of the
death cause plus the owning house. `TL_Contaminator_H0.XBF`:

```
Shot 1     [424..453] -> GunHit1, ContaminatorDying
Burnt 1    [454..507] -> BurningSmall, HKburningManDying, ContaminatorDying
Gassed 1   [508..566] -> ContamChoking
Blow Up 1  [567..594] -> RocketDetonation2, ContaminatorDying
Run Over 1 [611..625] -> HKCrush, ContaminatorDying
```

Three authoring habits in that table are worth knowing before touching
`scripts/units/authored_death_voice.gd`, since each one needs a rule:

1. **Clip frame ranges overlap.** `HK_Flamer_H0`'s `Run Over 1` [328..338]
   sits wholly inside its `Shot 1` [332..356], so plain containment hands one
   clip's sounds to its neighbour. The tightest range around a frame owns it.
2. **The same sample pool is named twice in one clip.** TL_Contaminator's
   `Burnt 1` lists both `BurningSmall` and `HKburningManDying`, which are the
   identical eight `burn_dying_*` samples — playing both doubles the scream.
   One voice per sample family per clip, earliest frame wins.
3. **A sound is occasionally authored just outside its own clip.**
   `GU_Man_H0` puts `ATCrush` on frame 281, one frame before its own
   `Run Over 1` [282..292] begins, stranding it in `Shot 1` [270..307] where
   no range rule can dislodge it. Crush is pinned to `Run_Over_1` explicitly.

**OpenEBfD compatibility decision:** read the events rather than restate them.
The alternative — the per-cause, per-house table this replaced — could not
express `[ContaminatorDying]`, `[FemaleCivDying]`, `[SardaukarDying]` or
`[FremenDying]` without a per-unit branch, and it asserted outright that
`Blow_Up` carries no voice, which every infantry model contradicts.
`AuthoredDeathVoice` keeps only the 21 sections drawn from the six
dying-infantry sample pools (`normal_dying_*`, `burn_dying_*`,
`choke_dying_*`, `contaminator_die_*`, `female_death_*`, `crush_guy_*`) — the
weapon and explosion sounds sharing those clips (`RocketDetonation*`,
`GunHit*`, `Small`/`Medium`, ...) belong to systems that fire them from their
own call sites, and replaying them here would double them up.

**Dormant by construction:** the crush family resolves and is covered by
tests, but nothing produces a `&"Crush"` death cause yet — crushing is
declared in the rules (`UnitDefinition.crushable`/`crushes`) and not
implemented.

### Vehicle death explosions: the "personal hook" theory was falsified; size tiers are hand-picked instead

**Observed data (the now-abandoned theory):** `HarkonnenSFX.txt` contains four
death-sound sections whose names were renamed away from a per-unit label that
survives only as a commented-out line directly above each one:

| section | commented-out original label | unit |
| --- | --- | --- |
| `[hkmedium1]` | `;dko[HarkAssaultTankDie]` | `HKAssault` |
| `[hkmedium2]` | `;dko[HarkInkvineDie]` | `HKInkVine` |
| `[hksmall1]` | `;dko[HarkBuzzsawDie]` | `HKBuzzsaw` |
| `[explode]` | `;dko[HarkDevastatorDie]` | `HKDevastator` |

An earlier design (commit `105928f`) took this at face value: each of these
four units plays its "personal hook" concurrently with a generic
`GeneralSFX.txt` `[Small]`/`[Medium]`/`[Large]` size-tier boom.

**This was falsified by testing against the reference build.** `HKAssault`
empirically played `explosion_large_3.wav` + `explosion_medium_5.wav` —
*neither* of which is in `[hkmedium1]`'s own sample list
(`bigxplosion04`/`explosion_vehicle_1`/`explosion_vehicle_2`). `HKBuzzsaw`
played `explosion_large_5.wav` + `explosion_vehicle_2.wav`, and
`explosion_vehicle_2` is not even in `[hksmall1]`, its own supposed personal
hook. Further investigation (grepping every `SFX/*.txt` file and every
converted XBF model's embedded `sound_names` strings) found that essentially
every unit's model references *some* personal-hook-shaped name, but almost
all of them are dead, `$`-prefixed localized stubs in `ImportedSfx.txt` with
zero real samples behind them — these four just happen to be the only ones
that survived with real English samples, which is a fact about which stubs
got localized, not evidence that these four units are audio-special.
**Conclusion: the original engine's actual per-unit death-sample selection is
hardcoded in the shipped binary and is not recoverable from any available
source data.** `explode` is still specifically `HarkDevastatorDie`, not a
generic id (so it must never be handed to an arbitrary vehicle or to
infantry) — that grep fact stands — but "personal hook + generic tier, both
concurrent" as a *selection mechanism* does not.

**OpenEBfD compatibility decision:** abandon precision. `VehicleDeathStrategy`
drops `PERSONAL_DEATH_HOOKS` and the whole `GeneratedVoiceManifest`
indirection for this mechanism entirely, replaced by a hand-specified
three-pool system (`ExplosionTierPools`: `small`/`medium`/`large`, each a
pool of `explosion_{small,medium,large}_*.wav` referenced directly, bypassing
`SoundEvent`/the generated manifest) confirmed by ear-testing several units
against the reference build. `TIER_OVERRIDES` lists every unit the user
specified by ear; everything else defaults to `medium` — an **approximation,
not sourced data**, since the per-unit tier itself is still hardcoded in the
binary and `explosion_type_id` (the visual VFX bank) does not correlate with
it at all (`HKDevastator` and `ATMongoose` share the same generic `Explosion`
bank). Current overrides: Harkonnen vehicles are all `medium` except
`HKDevastator` (`large`); Atreides `ATTrike`/`ATAPC` are `small`,
`ATMinotaurus` is `large`; Ordos `ORDustScout` is `small`, `ORKobra` is
`large`; the shared `Harvester`/`FakeHarvester` and the Guild `GUNIABTank`
are `large`.

**Separately, an unconditional per-house layer:** every Harkonnen vehicle
additionally plays one of `explosion_vehicle_1.wav`/`explosion_vehicle_2.wav`,
and every Ordos vehicle plays one of `explosionordos01..06.wav`, both at the
start of the death animation regardless of size tier (`VehicleDeathStrategy.
death_start_sound_paths`, keyed off `house_id` rather than a per-unit list, so
it covers every vehicle in those houses automatically). Atreides and every
other faction get no such layer. This approximates the doubled-boom behavior
the original falsified theory was trying to explain, without claiming it is
the same mechanism.

`explosion_medium_1.wav` is deliberately excluded from the `medium` pool: it
was renamed to `explosion_fire.wav` at convert time
(`converters/convert_audio_bag.gd`'s `RENAMED_ENTRIES`) because that sample is
actually used in-game for the (not yet implemented) Inkvine special ability,
not for generic medium explosions.

### Infantry `Blow_Up` has no corpse sound of its own

**Observed data:** `Blow_Up_1`/`Blow_Up_2` (present on every converted infantry
model) is purely a "corpse gets launched by an explosion" animation. There is
no per-house or generic `*ManDying`-family hook for a physical blow-up at all —
the `[explode]` family it appears to want is `HarkDevastatorDie` (above), a
vehicle's personal hook.

**OpenEBfD compatibility decision:** `InfantryDeathStrategy` proposes no
sound layer for `Blow_Up`. The boom the player hears in the original belongs to
the *weapon's* detonation, a separate system (`combat_impact_resolver.gd` /
`combat_projectile.gd`) that has no SFX wiring yet; giving the corpse its own
boom would double it up once weapon-impact SFX lands. `Burn`/`Shot`/`Gassed`
keep their unrelated per-house/generic hooks unchanged.

**`HKFlamer` is the one exception:** user-confirmed, it emits a `small`-tier
boom *regardless of what killed it*, because its own fuel tank ruptures as part
of dying. Its converted model carries only the ordinary infantry clip set (no
bespoke "tank explodes" clip), so this is modelled as an extra sound layer
alongside whatever the cause resolved to — not a forced `Blow_Up` cause — and
no visual effect (`HKFlamer.explosion_type_id` is already `None`). Scoped to
this one unit: no equivalent hook or comment exists for any other infantry, so
this is a recorded observation, not an extrapolated "special payload" rule.
Same `ExplosionTierPools` direct-WAV pool the vehicle size tiers use
(`InfantryDeathStrategy.death_start_sound_paths`), not the manifest, and it
plays immediately alongside its per-cause scream — infantry has no separate
VFX-spawn call site to time against the way vehicles do, and the user
confirmed no artificial delay/sync attempt is wanted here.

### Turret fire sounds and bullet hit sounds: resolved by name match, not invented

**Observed data:** Unlike death/explosion sounds, the original SFX files have
no generic "weapon fire" or "bullet hit" event category. A turret's shot
sound is just whichever SFX section happens to share (or nearly share) its
name, and a bullet's impact sound almost never exists at all — explosive
warheads rely entirely on the explosion/death sound systems, which this
feature does not touch.

**Resolution rule (`tools/generate_unit_definitions.py`, `parse_sfx_sections()`
+ `fire_sound_paths_for()`/`hit_sound_paths_for()`):** For each turret,
look up an SFX section whose name case-insensitively equals the turret's
`config_id` (e.g. `ORDeviatorGun` → `[ORDeviatorGun]` → `DeviatorAttack.wav`,
confirmed against the user's own reference case). This resolved 38 of 70
turrets automatically, including case-only mismatches the original manual
survey missed (e.g. turret id `ATAPCGun` against section `[AtApcGun]`).

An exact name match is not always the *correct* section, though:
`[TLLeechGun]` (`leech_suck_1..4`) turned out to be the Leech's
vehicle-drain/capture sound, not its weapon fire — the real fire hook is two
sections earlier in `GeneralSFX.txt`, `[SpittingSpore]` ("the projectile
fired by TL Leech"), so `TLLeechGun` is overridden despite the tempting
name-only match. In-game user testing (not just source-comment survey) is
what caught this; a further audit of every auto-matched turret against
in-game playback is still open.

14 more turrets were resolved by hand via `TURRET_FIRE_SOUND_SECTION_OVERRIDES`,
each backed by an explicit `;dko` source comment or an unambiguous
bullet/sample-name correspondence: `ORKobraDeployedGun`/`ORKobraUndeployedGun`,
`ORLaserTankBase`, `IMADVSardaukarGun`, `IMSardaukarGun`, `ORAPCBase`,
`HKAssaultTankBase`, `HKBuzzsawLeft`/`HKBuzzsawRight`, `HKInkVineGun`,
`TLLeechGun` (above), `ATADPGun` (`[atheavymg-shortburst]`, explicitly
commented "this is the ADP fire gun sound" despite firing the oddly-named
`mongoose_rocket_1` sample), `HKADPGun` (`[hkheavymg-longburst]`,
`adp_gun_1`/`adp_gun_2` — distinct from `HKGunshipGun`'s own
`[HKGunshipGun]` → `hk_adp_gun_1`; the two "ADP"-ish names must not be
conflated, they are different weapons), and `HKFlameTankLeft`/`Right`
(no dedicated section exists; reuses `HKFlameTowerBase`'s large-flame sample
as the closest weapon-category match rather than staying silent), for 52
resolved turrets total. Of the remaining 18 empty: 7 (`ATAPCBase`,
`ATMinotaurusBase`, `ATRocketTurretBase`, `HKGunTurretBase`,
`IXProjectorTurretBase`, `ORGasTurretBase`, `SpotlightBase`) never actually
fire — they chain via `next_joint_id` into an already-resolved `...Gun`, and
only the last joint in a chain is read at runtime
(`CombatTurret._last_firing_joint`), so their own empty `fire_sound_paths` is
inert, not a gap; `SpotlightGun` is a light with no `bullet_id` at all. The
remaining 10 fire an actual weapon but have no identifiable source sound
(`ATPillboxGun`, `GUMegaTurretBase`/`GUMegaTurretGun`,
`IXMegaTurretBase`/`IXMegaTurretGun`, `GUNIAPGun`,
`TLTurretBase`/`TLTurretGun`, `SurfaceWormGun`, `WormRiderGun`) and are left
with empty `fire_sound_paths` rather than guessed.

**Continuous (stream) weapons must gate playback to once per burst.** A
stream weapon (flamethrower, gas jet) replays its short authored Fire clip
back-to-back for the whole burst window (`unit_combat.gd`'s
`_advance_engaged_turret`, `is_continuous` branch) rather than firing once —
`try_fire_at()` is therefore called many times per burst. Playing
`fire_sound_paths` on every one of those calls layered the same one-shot
sample dozens of times over a single flamer/gas burst (reported for
`ORChemicalGun`/`HKFlamerGun`). Fixed with a per-turret
`_continuous_fire_sound_pending` flag, set by `begin_continuous_burst()`
(called exactly once per fresh burst) and consumed by the first
`try_fire_at()` afterwards; non-continuous weapons are unaffected.

Bullet hit sounds use the same section-name machinery but, per the above, are
opt-in only: `BULLET_HIT_SOUND_SECTION_OVERRIDES` has exactly one entry,
`InkVine_B` → `[InkvineSplat]` (`hk_inkvine_hit_1.wav`), the one clearly
documented non-explosive impact sound (`;InkvineSplat - as HK Inkvine
projectile splats onto ground`) in the source data. No other bullet's impact
was invented a sound.

**A parsing gotcha found along the way:** `ImportedSfx.txt` redefines
`[INKVINESPLAT]` with only a `$InkvineSplat` (localized, unconverted) sample,
and sorts after `HarkonnenSFX.txt` in the casefold-sorted file order this
tool (and `generate_voice_feedback.py`) uses — the same shadowing pattern as
"ImportedSfx.txt shadows several death hooks" above. `parse_sfx_sections()`
handles this generically instead of via a per-id whitelist: a redefinition
that resolves to zero real (non-`$`) samples never overwrites an earlier
definition that had some, for every section, not just a hand-picked set.

**OpenEBfD compatibility decision:** Resolved at convert time into
`TurretDefinition.fire_sound_paths` / `BulletDefinition.hit_sound_paths`
arrays, baked into the `.tres` files like `muzzle_flash_scene_path` and
`impact_scene_paths` — not a runtime fallback. Playback reuses
`DeathSoundPlayer.play_pool()` (`scripts/combat/combat_turret.gd`'s
`try_fire_at()` for shots, `scripts/combat/combat_projectile.gd`'s
`_resolve_impact()` for hits) rather than a new player class.

**Authored `Volume` must be applied, not just the samples.** The resolved
section's `Volume=` (0-100) is also baked in
(`fire_sound_volume`/`hit_sound_volume`, default 100 when the source omitted
it) and applied by `play_pool()` as linear gain. Skipping this was a real bug,
not a nicety: `ornithopter_rocket_2.wav` (used by `ATOrnithopterGun`,
`HKGunshipGun`, `HKDevastatorMissile`, `HKMissileTankBarrage`) is a hot
recording peaking at ~99% of full scale, authored at `Volume=60` in
`[atrocketlaunch]` — playing it back unscaled at 100 was reported as "loud and
harsh" in-game. `ExplosionTierPools`/death-sound callers are unaffected: they
pass no volume and default to the previous unscaled-100 behavior.

**A section-name match is not always the correct section.** Two turrets
picked up the wrong sound despite the name-match/override logic finding
*something* plausible, caught only by in-game listening, not by the source
comments alone: `TLLeechGun`'s exact-name match (`leech_suck_*`, actually the
vehicle drain/capture sound) instead of `[SpittingSpore]` (the real weapon
fire), and `ATOrnithopterGun`'s exact-name match (`ORNITHOPTER_ROCKET_1`)
instead of the explicitly-commented `[atrocketlaunch]`
(`ornithopter_rocket_2`). Both are now `TURRET_FIRE_SOUND_SECTION_OVERRIDES`
entries. This means the full auto-matched set (see above) has not all been
individually verified in-game and may hide further cases like these two.

**Generic kinetic-impact sound (`shell_dud_1.wav`).** A broad, user-requested
rule: `[ShellDetonation]`'s `shell_dud_1.wav` — "as shell hits ground (not a
full on explosion)" — plays as the sound accompaniment for a bullet's own
explosion *visual* effect, matching the source data where `[RocketDetonation]`
resolves to the identical sample for rockets. First attempt was a hand-picked
bullet list gated on caliber (shell/rocket in, machine-gun out); user then
corrected it further (MG bullets still slipped through as "a normal bullet
shouldn't have this") and asked for the real rule: tie playback to whether an
explosion effect actually exists at the point of impact, not to a hand-sorted
weapon category.

`EXPLOSIVE_IMPACT_EFFECT_IDS = {"ShellHit", "MissileHit", "DevImpact"}`
implements that:
`assets/converted/impact_effects/{shellhit,missilehit}/*.scn` both contain a
"_bigbing_"-named mesh (a real explosion burst with "_bing1..4" debris
pieces), while `mghit.scn` (`_flashtest_0`) and `sniperhit.scn` (whose
original XBF node is literally named `_MGHit_0` — sniper impacts reuse the MG
hit visual verbatim) are flash-only, no explosion. `hit_sound_paths_for()`
plays the sound whenever any of a bullet's own `explosion_effect_ids` is in
that set, excluding only lasers (`is_laser`), continuous streams (no discrete
impact moment), and the Inkvine catapult (keeps its own `InkvineSplat`
override). This is deliberately effect-driven rather than a per-bullet list:
the two Mega Turret plasma bolts turned out to carry a real `ShellHit`
explosion effect despite reading as "energy, not kinetic" by name, and now
correctly get the sound too — the previous hand-picked list had excluded them
on a guess that the effect data contradicts.

`DevPlasma_B` (the Devastator's plasma bolt) used to be cited here as a third
example of the same thing. It was not: its `ShellHit` was the stale first half
of a duplicated `ExplosionType` key (see "Duplicate `ExplosionType` keys are
overrides" above), and the bullet's real effect is `DevImpact`. `DevImpact` is
in the set on its own merits instead — it is a marker-only rig with no burst
mesh to inspect, so the "is it a real explosion" question is answered from the
bullet it belongs to: 813 damage, `BlastRadius = 32`, `BlowUp = TRUE`. Without
that entry, fixing the duplicate-key bug would have silently muted the
Devastator's impact.

### Sound fixes belong in the generator's tables, never in the generated `.tres`

**Observed data:** `make unit-definitions` rewrites every
`resources/combat/turrets/*.tres`, `resources/units/definitions/*.tres` and
`resources/combat/generated_combat_manifest.gd` wholesale. Commit `028dc99`
tuned two weapons by editing the outputs directly — `HKGunTurretGun` pointed at
the hand-authored `assets/reworked/HKGunTurretBurst.wav`, and a new
`SMQuadGun.tres` was written by hand with `SMQuad.turret_ids` repointed onto it
— so the next regeneration silently reverted all three, and
`unit-definitions --check` reported them as "out of date" on plain `main`.

**OpenEBfD compatibility decision:** both fixes now live in
`tools/generate_unit_definitions.py`, alongside the section-override tables
that were already there for the same reason:

- `TURRET_FIRE_SOUND_PATH_OVERRIDES` — a fire sound whose sample is a
  hand-authored `assets/reworked/` asset that no SFX section can name. The
  section's authored `Volume` still applies.
- `DERIVED_TURRETS` + `UNIT_TURRET_OVERRIDES` — a turret the original data does
  not have, because a unit shared someone else's turret and has since been
  given its own weapon voice. The derived turret copies every field of its
  source turret except the fire sound, its exclusivity rule, and (explicitly,
  so it reads as a choice rather than drift) its volume. `SMQuadGun` is the
  only one: the Smuggler Quad shared `ORAPCBase`'s APC rocket sound, and now
  fires `[atsmallcannonsingleshot]` as a single non-salvo gun at the level it
  was tuned to by ear (70, where the section itself authors 80).

The rule for anything similar: if a sound needs changing, change the table and
regenerate. A `.tres` edit is not a fix, it is a pending revert.

### Movement sounds live in two places: the model's FX table and a synthesised section name

**Observed data:** There is no `MoveSound`/`EngineSound` key anywhere in
`MODEL/Rules.txt` or `MODEL/ArtIni.txt` — the `[ORAPC]` block only carries
commented-out `//SoundSelected`/`//SoundOrdered` lines. The connection is made
two different ways instead.

*Footsteps are in the model.* `3DDATA/Units/*.xbf` FX event **type 9**
(`probability` u32, `payload_type` 4, one C-string) is the "play this sound
event" record, and the string is an SFX section name: `AT_mongoose_H0.xbf`
authors `ATThumpStep` on the `Ltoe1`/`Rtoe1` bones, `AT_minotaurus_H0.xbf`
`ATHollowstep`, `Or_DustScout` `DustScoutMove`, `TL_Leech` `LeechFootsteps`.
`probability` is 100 in every unit model, so the roll never fails in shipped
data; it is still rolled. Type 9 also carries the fire and death sounds
(`ATCannonSingleLoudShot`, `ATMedBang1`), but those land in the `Fire 0` and
`Explode` frame ranges, so scoping the search to the movement clips (`Move`,
`Move_Start`, `Move_Stop`, `Turn_Left`, `Turn_Right`) separates them by data
rather than by a name blacklist. One event can belong to two clips at once:
the Mongoose's third step sits in the range `Turn Left` and `Turn Right`
share, and plays for both.

*Engine starts are synthesised.* The original engine built the section name as
`<RulesSectionName>MoveFxStart` — `[ORAPC]` → `[orapcmovefxstart]`
(`apcmovestarta/b/c`, `Control = random`, `Limit = 1`). 22 of 102 units
resolve one; `tools/generate_unit_definitions.py`'s `move_start_sound_id_for()`
bakes it into `UnitDefinition.move_start_sound_id`, so that count is a checked
artifact.

That name is the *Rules* section name, which is not always the `config_id`, so
`UNIT_MOVE_START_RULES_SECTIONS` maps the exceptions back. Rules.txt carries a
single `[MCV]`, split per house at convert time, so `ATMCVMoveFxStart` does not
exist and all three MCVs came out silent until they were mapped onto the one
`[mcvmovefxstart]` (`mcv_a_motor_1`) the source gives them. The plain
`Carryall` is the mirror image — one house-shared unit here against three
source sections — but that needs no by-house machinery either:
`[ATCarryallMoveFxStart]`, `[hkcarryallmovefxstart]` and
`[orcarryallmovefxstart]` all name the same `adv_carryall_takeoff_1` at
`Volume = 70`, `Limit = 1`, as do the three ADVCarryall sections, so the house
is simply picked. `StormUnitMoveFx` is a loop section, in the same
unimplemented family as the buildings' `*MoveFx` loops.

Note that carryalls barely exercise this in practice: `_set_movement_animation()`
hands airborne phases to `UnitFlightController` before the movement-sound module
sees them, so a carryall only sounds its start on ground locomotion. Hooking
takeoff is the open work here, not per-house resolution. Unit-level `*MoveFx` *loop* sections do not exist — only buildings
with moving parts (`ATRocketTurretBaseMoveFx`, `ORPopUpGunMoveFx`, …) and
`StormUnitMoveFx` have them, and those are not wired up yet.

**OpenEBfD compatibility decisions:** `resources/audio/generated_sfx_manifest.gd`
(from `tools/generate_voice_feedback.py`) carries every section that resolves
to at least one converted WAV — 510 of them — because a model's section names
are only known at runtime, unlike the voice/death hooks which resolve into
per-unit resources at convert time. `SfxSectionCatalog` looks them up and owns
the `Limit` accounting, which Sfx.txt defines as a *global* simultaneous-
instance cap, so `ATThumpStep`'s `Limit = 3` throttles a whole platoon of
Mongooses with no extra runtime throttle. `[GlobalDefaults]`
(`Control = random`, `Volume = 80`, `Limit = 5`) is applied in this manifest
only; the already-generated voice/death resources keep the values they were
generated with.

Deliberate silences and one deliberate deviation:

- Every infantry `*Footsteps` name (`ATengineerFootsteps`, `HKscoutFootsteps`,
  …), plus `TrackStartMove`/`TrackStopMove`, `EngineStart`, `Leech` and
  friends, has no SFX section at all. They stay silent — that is what the data
  says, and nothing is invented for them.
- `HKDevastatorFootsteps` is the same case, but the Devastator *does* have
  `[hkdevastatormovefxstart]` (`hk_devastator_walk_1`). A mech whose step
  events resolve to nothing therefore falls back to its own move-start section
  for its steps, and does not additionally play it on departure — a mech's
  movement sound is its gait. This is a gameplay decision, not something the
  source data states; it affects HKDevastator alone (the only one of the three
  `mech = true` units without resolvable step events).
- `ATadpMove` is the one movement-clip section partitioned into
  `attack`/`decay` samples: it is the ADP's spoken radio acknowledgement
  (already played as a voice bark), not a mechanical sound, so sections
  carrying those controls are skipped. Filtered on what the section data says,
  not on the name.
- `DeathHandLaunch` (in `HK_Deathhand`'s `Move`) and `HKSmall1` (in
  `HK_buzzsaw`'s `Move_Stop`) are genuinely authored inside movement clips and
  do play. That is correct; do not "fix" it.
- The four carryalls among the 19 only sound their engine start on ground
  locomotion: `Unit._set_movement_animation()` hands airborne phases to
  `UnitFlightController` before the movement-sound module sees them. Hooking
  takeoff is open work, not a regression.

### Weapon reload sounds are authored in the fire clip, not in the rules

**Observed data:** no rules key describes a reload sound. Eight authored
FX **type 9** events across the whole converted model set are one, each pinned
to a frame inside the clip it belongs to (frame numbers are the bake's, at the
fixed 20 fps XBF rate):

| model | clip | range | frame | section |
| --- | --- | --- | --- | --- |
| `AT_Sniper_H0` | `Fire 0` | 213..289 | 258 | `Atsniperreload` |
| `AT_Sniper_H0` | `Lay Down Fire` | 290..331 | 309 | `Atsniperreload` |
| `HK_Trooper_H0` | `Fire 0` | 195..248 | 237 | `HKreload` |
| `OR_AATrooper_H0` | `Fire 0` | 286..353 | 338 | `ORkobrareload` |
| `HK_Inkvine_H0` | `Fire 0` | 32..58 | 50 | `HKinkvinereload` |
| `AT_Kindjal_H0` | `Deployed Fire` | 386..436 | 429 | `FRwarriorreload` |
| `AT_Kindjal_H0` | `Deploy Gun` | 322..384 | 374 | `Atsniperreload` |
| `OR_Mortar_H0` | `Deploy Gun` | 362..420 | 416 | `ORkobrareload` |
| `ATPillbox` (`AT_MGT_H0`) | `Fire 0` | 193..275 | 257 | `Atsniperreload` |

Behind them are exactly two samples: `hk_rocket_trooper_reload_1` for the
Harkonnen bazooka and `kindjal_infantry_reload_1` for everything else.

**Why this needs an allowlist and not a name filter:** a fire clip's *other*
type-9 events are the weapon's own shot sound, and `CombatTurret` already
plays that from the turret definition's baked `fire_sound_paths` (resolved by
`config_id` name match, see "Turret fire sounds and bullet hit sounds" above).
On nine units the authored section resolves to the very WAV the turret already
fires — `AT_SonicTank`'s `SonicWail` and `HK_assault`'s `CannonSingleLoudShot`
are both exact duplicates — so playing every event in the clip would double the
gunfire. `AuthoredReloadSound.RELOAD_SECTIONS` is therefore derived from the
SFX data rather than from the model survey: it is every section in
`assets/raw_original_content/SFX/*.txt` whose `Sounds=` is one of the two
reload samples, plus the two ImportedSfx-only stubs, and nothing else.

**OpenEBfD compatibility decisions:**

- Fire clips are scheduled through `AuthoredFireController`'s own sequence
  clock (`sound_times`/`next_sound` beside `shot_times`), which is what both
  units and buildings already advance, so the AT Pillbox needed no separate
  wiring. Reload entries stay *out* of `shot_times` on purpose: three separate
  behaviours count that array (burst validation, the continuous-bullet damage
  split, and `_fire_sequence_has_multiple_shots`).
- A burst cut short stays silent. Cancellation goes through
  `cancel_sequences()` → `_stop_sequence()`, which never reaches the sound
  loop; a clip that genuinely ended does sound, including via
  `finish_animation()`'s jump to `duration` — which matters, because every
  authored reload sits near the end of its clip.
- `Deploy Gun` is driven by `UnitDeployState`, not by the fire controller, so
  the Kindjal's and the Mortar's deploy-time reloads are scheduled there on
  timers. A transition clip runs to completion by construction
  (`is_transitioning()` locks out every order that could interrupt it), so
  there is no cancellation to unwind. The delay is divided by the player's
  speed scale because nothing resets it between clips: a unit that fired
  before deploying leaves the player at `FIRE_ANIMATION_SPEED_SCALE`.
- `Lay_Down_Fire` and `CrouchFire` are authored on most infantry but bound by
  nothing in `scripts/`, so the sniper's prone reload is resolved and tested
  yet never plays today. That is missing prone/crouch stances, not a missing
  sound.
- `HK_Inkvine_H0`'s reload is silent (see the ImportedSfx shadowing entry
  above). The section stays on the allowlist so the silence reads as a data
  fact rather than an oversight.
- The AT Pillbox reload depends on the `Idle 0` range repair below: the source
  file nests `Idle 0` [200..240] inside `Fire 0` [193..275], and a nested range
  wins the tightest-range rule that decides which clip owns a frame. The bake
  rewrites `Idle_0` to the `Stationary` range and keeps the original only as
  `source_*_frame`, so the reload stays in `Fire_0`. A resolver that ever
  preferred `source_*_frame` would silently move it.

## Building models

### Atreides Refinery H0 contains two broken geometry components

**Observed data:** The shipped `at_refinery_h0.xbf` contains two disconnected
geometry components inside the merged `at_refinery` object that are not part
of the intended refinery model. After the converter deterministically splits
that object by triangle connectivity, these components are `Mesh_03` and
`Mesh_10`.

**Original-engine quirk:** The erroneous components are present in the
original model asset. They are an asset defect rather than geometry from a
valid refinery state.

**OpenEBfD compatibility decision:** Preserve both components in the
converted scene for source fidelity, but mark them with the
`source_asset_quirk = "broken_geometry"` metadata and keep them hidden. The
remaining idle geometry and the independently controlled left and right
SmallPad animations are unaffected.

### Mirrored objects are often authored inside-out

**Observed data:** Objects placed under a consistently mirrored transform
(negative basis determinant, either static or across every object-animation
frame) frequently have their geometry authored inside-out: vertex normals
point into the volume and triangle winding agrees with those inward normals.
Examples: `clonetread01`/`clonetread02` and `girderbox02/04/05` in
`AT_Conyard_HC.XBF`, `OrigTreadR03` in `OR_ConYard_HC.XBF`,
`lfrontpaw`/`lbackleg` in the `IM_Barracks` states, `wormhead` in
`GU_wormhead_H0.xbf`. A signed-volume scan of `3DDATA/Buildings` finds 67
such meshes. The data is inconsistent: 38 other mirrored meshes (for example
`girderbox06` and `Box06` in the same AT ConYard file) are authored with
outward orientation.

**Original-engine quirk:** The original renderer draws without back-face
culling (CorrinoEngine reproduces this), so an inside-out mesh under a mirror
still shows solid geometry - the mirror turns the winding right side out on
screen. Its world-space lighting normals remain inward, which the original
simply displays as slightly wrong shading. Nothing in the shipped data marks
which mirrored meshes are pre-compensated this way.

**OpenEBfD compatibility decision:** Godot flips face culling for
instances with a negative world determinant, which renders exactly the
pre-compensated meshes inside out while the correctly authored mirrored
meshes need no help. `ModelBakeBuilder` therefore tracks the net mirror
parity down the object tree and, inside mirrored subtrees only, detects
inside-out meshes by normalized signed volume (`_mesh_is_inside_out`,
threshold 0.001) and re-orients them at bake time by reversing triangle
winding and negating normals. This also corrects their lighting relative to
the original. The detection is deliberately not applied outside mirrored
subtrees: an unrestricted signed-volume sweep also flags concave debris
meshes (H3 rubble) that must keep their authored orientation.

### AT Pillbox's Idle 0 range is nested inside Fire 0

**Observed data:** Every shipped `AT_MGT` H/M/L state uses the same clip
table: `Stationary` is frames 104..133, `Idle 0` is 200..240, and `Fire 0` is
193..275. The only moving gun transforms occupy frames 194..230, while the
short-burst sound and firing events occupy frames 194..257. `Idle 0` therefore
contains the machine-gun recoil instead of an idle motion.

**Original-engine quirk:** This overlap is present verbatim in each original
XBF; it is not an animation-table parsing error. Buildings use `Stationary` as
their resting state, so the mislabeled optional idle clip did not affect the
original building state.

**OpenEBfD compatibility decision:** `ModelXbf` preserves the authored
table for lossless inspection. `ModelBakeBuilder` repairs only the converted
`AT_MGT` `Idle_0` clip by assigning it that file's `Stationary` frame range,
while retaining frames 200..240 as `source_start_frame`/`source_end_frame`
metadata. `Fire_0` and its event schedule remain unchanged.

### Two building art names differ from their H0 filenames

**Observed data:** The `INGUCyclopseHouse` art entry names its model
`IN_GU_CyclopsHouse`, while the source file is
`IN_GU_CyclopseHouse_H0.xbf`. The `PenguinRock` entry names `PenguinRock`,
but its source model is `OR_IN_Penguins_H0.xbf`.

**Original-engine quirk:** The art-table XAF names are not a one-to-one match
for these shipped building XBF filenames.

**OpenEBfD compatibility decision:** `convert_all_buildings.gd` maps
these two building IDs to their actual H0 prefixes before conversion. All 152
rules-defined buildings therefore produce scenes without placeholder models.

### Destroy (H3) debris motion is procedural, marked by a "%" name suffix

**Observed data:** Atreides H3 models (`AT_conyard_H3.XBF`,
`at_barracks_h3.xbf`, `at_Hanger_H3.xbf`, ...) contain no baked animation at
all: every object has animation flags 0, and each visible debris object's
name carries a `%` suffix (`Mesh140%`, `at_fac_flag%`, `conbelt01%`) that its
H0/H1/H2 counterpart does not. Their FX table's `Explode` entry is only a
frame window (0..50 for the ConYard, even 0..0 for Barracks and Hanger) plus
a `MASTER` bank referencing a bang effect (`ATLargeBuildingBang`). In
contrast, `HK_conyard_H3.XBF` names its pieces without `%` and bakes real
per-piece matrix animation (~30 unique matrices per debris object).

**Original-engine quirk:** The engine scattered `%`-suffixed debris pieces
procedurally during the explode window; the XBF carries only the assembled
ruin pose. Generic flying-debris projectiles (`[DebrisTypes]`,
`3DDATA/Debris*.XAF`) are a separate system layered on top.

**OpenEBfD compatibility status:** The converter preserves the `%`
marker in each node's `original_name` metadata and correctly bakes the HK
style keyframed variant. No procedural scatter is implemented yet, so
`%`-style destroy states currently show the static assembled ruin for the
clip's duration.

### Damage states may author whole sub-trees rotated

**Observed data:** In `AT_conyard_H2.XBF` the entire `foyer` object's vertex
data is authored rotated -90° around X relative to H0, with the compensating
+90° rotation stored in the `foyer` node transform. World-space geometry is
identical in placement to H0.

**Original-engine quirk:** State files are independent exports; the exporter
was free to reparent or rebake local spaces between them, and only the
composed transform is meaningful.

**OpenEBfD compatibility decision:** No special handling is needed - the
converter carries node transforms through, and baked scenes render
correctly. Be aware that the Godot editor's mesh-resource preview shows the
mesh in local space without the node transform, so such meshes look lying
down or edge-on in the Inspector while being correct in the scene.

## Textures

### Move, Attack, and Deploy cursor blue rings omit their screen marker

**Observed data:** Most cursor surfaces that require screen composition mark
their texture name with the original `!` prefix. The blue-ring surfaces in
`CU_Move_H0.xbf`, `CU_attack_H0.xbf`, and `CU_Deploy_H0.xbf` instead reference
the unmarked shared texture `whitering2.tga`, even though the rings are rendered
as screen effects in the original cursor appearance. The same texture is also
used as an ordinary surface by other cursor models, so the texture itself
cannot be classified globally as a screen texture.

**Original-engine quirk:** For these three surfaces, the shipped texture-name
marker does not fully describe the render mode. The additional state used by
the original renderer has not been identified in the converted material
data.

**OpenEBfD compatibility decision:** `convert_cursor_models.gd` records
source-specific `SCREEN_SURFACE_QUIRKS` for `cu_move_h0.xbf`,
`cu_attack_h0.xbf`, and `cu_deploy_h0.xbf`: only their `whitering2.tga`
surfaces are moved to the Screen pass. Other uses of this shared texture
retain ordinary alpha composition.

### 16-bit TGAs carry a garbage alpha bit

**Observed data:** 323 of 2462 TGA files in `3DDATA/Textures` are 16bpp
(A1R5G5B5), including damage-state wall textures (`=AT_overhangwall_D_128.tga`,
`at_eagleface_D_128.tga`) and most explosion/flash frames (`!cexp*`,
`!Debriscexp*`, `!%boom*`). Their per-pixel attribute bit is 0, which a
spec-conforming decoder reads as alpha 0 - fully transparent. Several names
exist both with and without the `=` team-colour prefix as separate files of
different bit depths (`=AT_overhangwall_D_128.tga` is 16bpp while
`AT_overhangwall_D_128.tga` is 24bpp); the XBF texture name, prefix included,
selects which file is used.

**Original-engine quirk:** The original loader ignores the 16bpp alpha bit
and treats these pixels as opaque (CorrinoEngine `LibEmperor/Tga.cs` documents
this: "It seems the alpha value is not used here"). Transparency in these
assets comes only from the magenta colour key.

**OpenEBfD compatibility decision:** Godot's TGA decoder honours the
alpha bit, which made every 16bpp texture fully transparent - materials with
alpha-scissor or discard rendered their meshes invisible (e.g. the ConYard
Damage2 wall block). `TextureImageUtils.load_image` detects 16bpp in the TGA
header and forces alpha to 255 after decoding; the magenta colour key is
applied afterwards as before.
