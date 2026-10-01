# Open Questions

This document tracks source-model markers whose original runtime behavior is
not established yet. They are deliberately not assigned compatibility
behavior merely because their names begin with `#`.

## Building `#` markers not fully resolved

**Resolved boundary:** Building markers referenced by a decoded XBF FX
`start`/`stop` event and a valid FX bank are converted as attachment effects.
This includes lights as well as authored smoke, fire, flame, dry-ice, blood,
plasma, red-flash, garage, movie, and parts banks. Marker lookup is
case-insensitive to tolerate inconsistent source capitalization.

The following real object names occur in building `H*` models but either have
no decoded FX event that establishes how Emperor's runtime treats them, or
reference a missing asset. Compare them against the original game before
implementing them:

| Marker(s) | Source model examples | Question to verify |
| --- | --- | --- |
| `#lightning` | `OR_Palace_H0/H1/H2` | Animated geometry, a procedural beam, or an attachment effect? |
| `#blueflame` | `HK_Palace_H0/H1/H2/H3/HC` | Always-visible animated mesh or bank-driven flame? |
| `#boom` | `HK_Windtrap_H3`, `HK_UpgrdWindtrap_H3` | Destruction flash marker or visible debris geometry? |
| `#fountain` | `TL_IN_Greenhouse_H0` | Water particle emitter or an animated mesh? |
| `#dribble`, `#dribble01` | `TL_Fleshvat_H0` | Liquid emitter behavior and timing? |
| `#bigchimney` | `HL_IN_OxygenGen_H0`, `HL_IN_Oxygen_H0/H1/H2` | Smoke emitter, anchor, or visible chimney component? |
| `#movie` | `AT_Hanger_H0` | Parent/control node for the numbered `#movieNN` FX attachments? |
| `#Parts2`, `#Parts2X` | Repair-pad models | Gameplay repair particles or ordinary animated parts? |
| `#pivot` | `AK_IN_RepairPad_H0` | Transform-only animation pivot or gameplay attachment? |
| `#akira00`–`#akira03` | `IN_GU_MegaCannon_H0/H1/H2` | Weapon/control anchors or visible effect geometry? |
| `#Seagul01/03/04` | `CN_IN_Seaguls_H0` | Procedural ambient birds or model animation? |
| `#vulture`, `#vulture01`–`03` | `AK_IN_Vultures_H0` | Procedural ambient birds or model animation? |
| `#smoke1`–`#smoke3`, `#smokey5`, `#smokey6`, `#_smoke` | Various building and ambient models | Additional emitters, or meshes controlled by an undecoded event form? |
| `#ExplosionParent` | `HK_Barracks_H3` | Parent used by procedural destruction or ordinary hierarchy? |
| `#Vent` | `CN_IN_Whale_H0` | Its decoded bank requests `@Wake.tga`, which is absent from the shipped texture directory. Is the wake supplied procedurally or under another name? |
| `#::0`, `#::1` | `HK_GunTurret_H0` | Weapon hardpoints encoded with a prefixed legacy marker? |
| `#>>0` | `IN_GU_MegaCannon_H0/H1/H2`, `IN_IX_MegaCannon_H0/H1/H2` | Weapon target/muzzle anchor encoded with a prefixed legacy marker? |
| `#'~~0`, `#~~0boxes`, `#~~1`, `#_aircrash_parent~~0` | `OR_IN_Indi`, `G_Crates`, `air_crash` | Collision hierarchy variant or procedural object grouping? |

### Already understood special markers

- `#~~0` is authored collision geometry. An FX event may still target that
  transform (for example campfire/smoke assets), but its mesh stays hidden.
- `#^^0` supplies halo-anchor bounds and is already consumed by the runtime.
- Ordinary `#light…` variants and markers backed by decoded FX events with
  available textures are no longer open questions.

When checking the original game, record whether each marker is visible at
idle, only during an animation/damage state, camera-facing, particle-emitting,
or controlled by gameplay. Those distinctions determine whether it belongs
in model baking, animation tracks, or runtime simulation.

## FX bank emitter parameters partially inferred

Attachment banks whose parameter block authors motion (initial speed or
gravity) bake as `GPUParticles3D` streams; the rest stay single billboards.
The parameter words used for that are decoded with differing confidence:

| Word | Reading | Confidence |
| --- | --- | --- |
| 02 | Particle lifetime in 20 Hz updates | High — matches every fire/smoke bank against its texture sequence length |
| 04 | Speed in source units per update, along the marker's up axis | High for the magnitude; the **sign is not a direction** — AT Refinery authors its stacks positive and OR Refinery authors the same rising plume negative, on identity-basis markers, so only the magnitude is used |
| 07-09 | Particle tint RGB | High — OR Refinery's `@!%Engine` banks author (200, 255, 64), the dirty green its exhaust has in the original |
| 05 | Gravity per squared update, positive down | High — already corroborated; smoke and fire author it negative |
| 06 | Particle size in source units | High — corroborated by ShellHit |
| 01 | Particles per burst | Medium — always 1 for the damage banks, larger only for construction sparks and sand |
| 03 | Emission cone half-angle in degrees | Medium — 0 for straight columns, 10–50 for spraying banks |
| 10 | Source updates between bursts | Low — only the resulting particle density depends on it |

Compare a damaged building and a Construction Yard against the original game
to confirm the burst density; the plume shape does not depend on words 01/10.

The bank `start`/`stop` events gate emission, not the node's visibility: idle
stacks are authored as intermittent puffs (`AT_REFINERY_H1`'s `#smoke02` runs
source frames 5-70 and 90-100 of a 201-frame loop), while damage fire is a bare
`start@0`. The emitter stays drawn for one particle lifetime past its last stop
so the tail drifts away instead of popping, and is baked not emitting, so the
damage-state banks of every packed state cost nothing until their state runs.

Two further emitter behaviours were taken from the original game rather than
decoded, and are worth re-checking against it:

- **Alpha ramp.** Particles thin out towards the end of their life (a stack's
  plume is dense at the mouth and dissipated by the top). No bank authors this:
  every building smoke bank has zero per-update colour deltas, so the converter
  bakes a linear ramp on the assumption that the fade is engine behaviour.
- **Lateral drift.** A rising plume wanders instead of climbing as a rigid
  column, each particle taking its own share of a noise field. Also not
  authored: the strength is set so a fully-influenced particle drifts sideways
  by a fraction of the distance it travels along the plume
  (`ATTACHMENT_FX_DRIFT_FRACTION`). Measuring against the travel and not the
  particle's own size is deliberate — damage fire is authored as 4-unit sprites
  that barely move, so a size-relative drift would fling it across the building.
- **Blend mode.** The `@` texture marker selects alpha blending; `!` alone stays
  additive. `@!%Engine` and `!@sm` carry it, `!fire`, `!%Flash` and `!Dlight` do
  not, which matches which effects glow in the original. Those sprites are
  24-bit light-on-black, so their brightness is re-keyed into alpha and their
  hue normalized, leaving the bank tint to decide the colour.

Parameters 12 and 13 remain undecoded. They are not the acceleration a bank
uses in place of gravity: across the original content they appear both with and
without a gravity, so nothing about their meaning is established.

## Projectile models author their own FX bank, and nothing emits it

`shell.xbf` — the projectile model shared by both Kobra shells, the Minotaurus
and nine other bullets — carries a one-bank, one-frame FX timeline of its own:

| Field | Value |
| --- | --- |
| Bank id / texture | `563844F0#23` / `!%FFlash`, 5 texture frames |
| Attachment | `shell~~0`, the shell body itself |
| Events | type 3 (start) on frame 0. **No type 4 stop anywhere** |
| Word 01 particles per burst | 2 |
| Word 02 lifetime | 10 updates (0.5 s at 20 Hz) |
| Word 03 cone half-angle | 20° |
| Word 04 speed | 0.11 source units per update |
| Word 05 gravity | 0 |
| Word 06 size | 2 source units (0.125 world) |
| Word 10 updates between bursts | 1 |

Bank playback exists for turrets (`combat_turret_fx.gd`) and locomotion, both
of which read `xbf_fx_banks` off a model root. `CombatProjectile` reads the
model's `xbf_fx_events` only to hide switched-off helper geometry (see
docs/quirks.md, "The shell's propulsion flare is authored, then switched off by
its own model"); it never emits a bank. So this puff does not exist in game
today.

This is the likely source of the brief flare a player remembers at the muzzle
as the shell leaves the barrel — user-recalled from the reference game, where
the flare is *not* continuous. What is not established is how long it emits.
Every characterized turret bank brackets its emission between a type-3 start
and a type-4 stop, and the casing counts in docs/mechanics/combat.md are
derived from the frames strictly between them. This bank has no stop and its
whole timeline is one frame long, so the burst count has no authored bound.
Word 10 (updates between bursts) is the low-confidence parameter in the table
above, which is exactly the one that would decide the answer.

Two readings to weigh before implementing: a single burst on launch (the
one-frame timeline taken literally), or continuous emission for the shell's
whole flight (the missing stop taken literally), which would read as a smoke
trail and collide with the separate rules-driven `MissileTrail` that
`KobraHowitzer_B` already authors. Compare against the original game before
choosing; deliberately left unimplemented.

## Animated FX texture rate

FX event record type 6 (`object`, `texture.tga`) is the authored flipbook: the
converter drives each animated-texture mesh from those frames directly. Objects
with no record of their own borrow the timeline of a sibling sharing the same
sequence; only models with no type-6 records at all fall back to a fixed step,
which is 2 source frames — the interval used by 1071 of the 1494 authored steps
in the original content.

## Snapshot format: netcode reconnect versus singleplayer save/load

`V1` made a checksum mismatch halt the match terminally, and names
snapshot-based reconnect as the eventual answer — a halted or dropped client
needs some way back in, and lockstep offers nothing to reconcile to. That
makes a snapshot format the next thing reconnect would need, and it is not
obvious it should be a netcode-only one.

Phase 6 of [`network-multiplayer.md`](architecture/network-multiplayer.md)
lists "save/load of a networked match" as its own separate item, and
singleplayer save/load wants the same thing: the whole simulation's state,
restorable into a fresh process, keyed to a scene and a tick. A format built
only to get a dropped peer back into a live room would likely be the wrong
shape for that and have to be redone — so the question to answer before any
reconnect slice is written is whether one format serves both, and what each
needs that the other does not.

What already exists to build on: `MatchSnapshot`
(`scripts/match/match_snapshot.gd`), `SimEntityState`'s flat arrays and their
`state_hash()`, and `ReplayFile`'s header, which already reserves a
`rng_seed` and a `start_state` payload. What is missing is the decision about
whether reconnect and save/load share a format, plus — per the same header —
a seeded simulation RNG at all, which `sim-no-global-rng`'s own `instead`
already names but `scripts/sim/` does not yet contain.

Deliberately not queued as a slice until that is settled.
