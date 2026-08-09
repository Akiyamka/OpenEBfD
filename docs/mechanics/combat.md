# Emperor: Battle for Dune Mechanics — 6. Combat

This section collects the combat model: how damage is calculated, how projectiles
fly, how units choose targets, and what happens to damaged units. It consolidates
notes from previous sections (listed in section 5 §8); numbers are in `Rules.txt`.

**Labels:**
- `[?]` — requires verification;
- `[Rules]` — parameterized in `Rules.txt`;
- `[← N]` — rule already verified in section N and consolidated here.

Status: **draft pending verification**.

---

## 1. Damage model: weapon × armor

- Basic scheme: a **bullet** references a **warhead** (§2), and a target has an
  **armor type**; final damage = bullet damage × the **percentage for the
  “warhead × armor” pair** from the matrix in `Rules.txt` `[Rules]`;
- the matrix expresses specializations: anti-infantry, anti-vehicle, and anti-air
  weapons are matrix rows rather than separate mechanics `[?]`;
- **zero pairs** are represented directly by zeroes in the matrix (for example,
  every normal warhead has a zero entry for `Invulnerable`) `[Rules]`; target-domain
  restrictions such as air-only fire are separate bullet flags (§7);
- buildings use the same armor-type namespace and matrix: `Armour` is present on
  building entries as well as units (`Building`, `CY`, `Heavy`, etc.) `[Rules]`.

## 2. Weapon model: turret → bullet → warhead

Weapons in `Rules.txt` are a pipeline of three entities (verified):

- **Turret** — the projectile-emission point on a unit:
  - may be **fixed** (rigidly aligned with heading — firing requires turning the
    hull) or **rotating**;
  - a rotating turret may have a limited yaw sector. If the target lies outside
    that sector, the turret turns to its authored limit while the unit turns its
    hull until the weapon can finish aiming (verified with the Minotaurus);
  - when an attack order ends, a rotated turret returns to its authored forward
    pose at the same rule-defined rotation speed; movement/idle animations do
    not snap it to rest or preserve a hidden previous aiming angle (verified);
  - **turrets on turrets** are supported — nesting for aiming along different
    axes, where different model parts rotate independently (for example, the
    mount horizontally and the barrel vertically);
- **Bullet** — the shot emitted by a turret. It owns **base damage, range, speed,
  trajectory, target-domain flags, special-effect flags, and explosion visuals**
  `[Rules]`. A physical bullet's visible model comes from its `ArtIni` `Xaf`
  mapping (for example, `KobraHowitzer_B -> shell.xaf`), independently of its
  impact effect and debris. A conceptual/hitscan shot is still a Bullet entry,
  marked by `Speed = -1`; this is used by ordinary guns and knives as well as
  lasers;
- **Warhead** — the bullet's reference to the §1 percentage matrix. Warhead
  entries contain only armor percentages; they do not own damage, effects, or
  visuals `[Rules]`.

Consequently, Deviator gas, Leech/Contaminator infection, ignition and related
effects are **bullet properties**, not warhead properties. `Leech_B` and
`Contaminator_B` intentionally have damage and effect fields but no warhead;
their `Damage` is the direct fallback for targets that cannot receive the effect
`[Rules]`.

Other weapon properties on a unit:

- a unit carries **one or more weapons** `[← 5: Sardaukar, Devastator]` `[Rules]`;
  selection logic when several are present: by **target type** `[?]`; can two
  weapons operate **simultaneously against different targets** `[?]`;
- reload/rate of fire is per weapon `[Rules]`. `ReloadCount` and source Fire
  clip frames use a 25 Hz combat domain. Converted XBF timelines are baked at
  20 Hz, so runtime Fire playback uses a `25 / 20` speed scale to preserve the
  source cadence. Vehicle and walker turrets advance ReloadCount in parallel with
  their complete authored `Fire N` XBF clip; the next firing action starts
  only after both restrictions have completed. Infantry instead executes its
  full-body Fire clip as a locked action and starts the post-action
  `ReloadCount` when that clip ends. The distinction is rules-backed by the
  unit's `Infantry` flag rather than a list of unit names. Projectile events
  inside the clip follow the animated barrel
  recoils: the Minotaurus emits four sequential shells from its four muzzles
  during one 31-frame `Fire 0` clip while its reload timer is already advancing.
  A type-10 launch event's `value` payload names which physical `>>N` muzzle
  fires it — the barrel order the animation visibly opens, which is not
  guaranteed to match the muzzles' own ascending numeric names. ATRocketTurret
  is the clearest case: its Fire_0 clip visibly recoils a left pair of barrels,
  then a right pair, while the `>>N` markers are numbered top-then-bottom.
  `AuthoredFireController` reads `value` and threads the named muzzle through
  `FireRequest.muzzle_index` so `CombatTurret.try_fire`/`try_fire_at` fire (and
  flash) that exact muzzle instead of the plain round-robin
  `next_emission()` would otherwise pick; the override only applies to
  single-bullet shots (`bullet_count == 1`), and any turret whose `value`
  payload falls outside its own `muzzle_count()` range is treated as
  untrustworthy and left on the round-robin, since the field is undocumented
  and is reused for unrelated data by other XBF event categories (e.g.
  locomotion footstep events).
  A `Continuous` bullet uses its single type-10 launch as the first damage
  pulse, then repeats at the source-frame cadence until the matching authored
  muzzle-stream banks stop. Thus the Harkonnen Flamer and Flame Tank deliver a
  real pulse sequence for the whole visible jet instead of one projectile at
  its beginning. A continuous weapon's muzzle-stream banks — the flamethrowers'
  `!%01fire` fuel, the Chemical Trooper's `!sm` spray — are identified by
  having a positive authored launch speed, which excludes the same models'
  zero-speed pilot-light banks and stationary drum smoke without depending on
  texture names. Those banks were sized for the source engine's own particle
  reach, roughly half of a converted weapon's `MaxRange` in world units, and
  emit sparse pulses of identically sized, identically aged sprites down one
  straight line at constant speed. Runtime rebuilds each such particle's whole
  life from the bullet's real `maximum_range_world()`: a sub-frame launch time
  so one pulse becomes a continuous column rather than a march of puffs,
  randomised lifetime and reach so the tip dissolves gradually instead of every
  sprite vanishing at one radius, eased-out travel plus buoyancy and a lateral
  flare that both grow with elapsed² so the stream stays a tight rod at the
  nozzle and only opens into a plume where it burns out, growth from a fraction
  of the authored size to a broad tip, a per-particle mirrored sprite sheet,
  and a hot-to-ember tint with a real fade-out (the authored frame opacity ramp
  bottoms out around a third, which alone would pop particles out mid-flame).
  The Flame Tank's own authored `Fire 0`/`Fire 1` clips are each only 5-6
  frames (one short burst per side turret), far shorter than their 60-tick
  (2.4s) `ReloadCount`; unlike a discrete-shot weapon, a `Continuous` turret's
  next authored clip is allowed to restart as soon as the previous one ends,
  without waiting for `ReloadCount` to finish counting down first
  (`CombatTurret.is_continuous_bullet()`), so the short burst replays
  back-to-back into one sustained stream for as long as the target stays
  engaged, matching the original's continuous flame instead of one puff
  followed by a multi-second silent gap. The infantry Flamer's single `Fire_0`
  clip already contains enough authored burst frames to look continuous on
  its own and is unaffected by this change.
  `TurretBulletCount` remains a
  separate rule for several projectiles emitted by one event. Once the firing
  clip has started, its authored salvo events are committed; the next barrel
  does not have to pass a fresh one-frame aim-tolerance check;
- suppression slows attacks `[← 5 §1]`.

## 3. Projectiles and trajectories

Projectiles (“bullets” from §2) are **physical 3D objects** with speed and
trajectory parameters `[← 1 §1: collisions]` `[Rules]`. Trajectory behavior
(verified):

- trajectory bullets use the global `BulletGravity` together with their
  `MaxRange` and the firing joint's elevation limits. There is no separate
  per-bullet `ArcHeight` field in `Rules.txt`: `Trajectory=true` enables the
  ballistic delivery, while a weapon that permits both solutions uses the
  flatter low arc and a minimum-elevation weapon (such as the deployed mortar)
  selects the high arc. The barrel follows the same solution as the projectile;
- **conceptual bullets** (`Speed = -1`) hit instantly; there are 19 such entries
  in the normalized rules, including ordinary firearms, knives, heavy guns, and
  both lasers. `IsLaser` is a separate bullet flag rather than the definition of
  hitscan `[Rules]`; lasers never miss (verified);
- **piercing** (Sonic Tank): a slow wave passing through units/buildings/walls
  `[← 5 §7.1]`;
- **homing (missiles)**: pursue a target **until they hit or bullet lifetime
  expires**; if the target dies while a missile is in flight, the missile
  **self-destructs** (missiles do not overdamage “a corpse” or hit bystanders
  beyond the target).

Additional bullet properties (verified):

- a **bullet can spawn warheads as it travels** — rather than only one at the
  impact point. This implements the Sonic Tank wave: the “damage for intersection
  time” from section 5 §7.1 is a chain of warheads spawned by the bullet along
  its path (a large target catches more warheads from the chain);
- **range limit / lifetime**: a bullet has a maximum existence limit `[Rules]` —
  for homing bullets, it also serves as a stop to infinite pursuit;
- **homing** is a bullet property `[Rules]` with a **turn-rate limit** (verified):
  a bullet adjusts its trajectory toward the target, but no faster than its
  angular speed — a fast/maneuverable target can “dodge” a missile;
- **there is no lead targeting** (verified): units fire at the target's **current
  position**, not a calculated intercept point — a target moving sideways escapes
  non-homing bullets. Compensation is left to the player as a micro-management
  element: the **attack ground** order (§4) allows manual leading;
- **indirect-fire spread** for side-by-side artillery barrels is geometric,
  not random (verified with the Minotaurus): the rigid turret aims as one group
  and every shell preserves its muzzle's horizontal forward direction. The
  trajectories remain parallel, so the authored barrel spacing becomes the
  lateral impact pattern without a separate spread/accuracy rule;

Projectile presentation is also rules-backed: `MissileTrail`,
`MissileTrailSize`, `MissileTrailLength`, and `MissileTrailDelta` produce the
fading wake behind a physical bullet. For example, the Minotaurus uses the dark
`shell.xaf` projectile with a long pale trail; the source model's helper flash
is not persistent rocket exhaust. A separate `TurretMuzzleFlash` field selects
the short effect spawned at the active muzzle when a shot is emitted. The
Minotaurus maps `Muzzle3` through ArtIni to the original
`3DDATA/Explosion/Muzzle3.xbf` visual. The oversized primary `Mesh_00` element
is rendered at half scale for every turret that selects `Muzzle3`; its authored
animation continues to drive the surrounding transform. The muzzle-flash XBF
also carries its own particle timeline: both `Muzzle1` and `Muzzle3` emit the
21-frame `!%Bru` fire/smoke sequence twice between their type-3/type-4 control
frames. `Muzzle1` authors size 8 (0.5 world units) and signed gravity -0.3
(-7.5 world units/s²); `Muzzle3` authors size 10 (0.625 world units) and -0.2
(-5 world units/s²). Positive bank gravity makes casings and sand fall, so the
negative values are the source of the smoke's upward buoyancy. Runtime reads
the bank selected through `TurretMuzzleFlash`, emits at its authored attachment,
applies the bank colour/fade, and lets each billboard continue rising after the
short flash model disappears. Consequently Trike/APC receive this smoke from
`Muzzle1`, while Mongoose/Minotaurus receive it from `Muzzle3`, without a unit
allowlist. The Minotaurus model also pairs every front
`>>...#muzzle01–04` marker with a sibling rear `#muzzle05–08` marker. The XBF
FX bank assigns the original `!cexp` rear cannon flash and a `!%shel` tumbling
casing particle to that rear point; they are emitted by the same per-barrel
firing event as the projectile. Every emitted projectile also creates a short
warm point-light pulse just behind the active barrel (using the rear marker
when present), so a multi-shot salvo illuminates the unit once per shot rather
than once for the complete firing animation.

Converted model roots retain the source FX bank records in `xbf_fx_banks`,
their timeline records in `xbf_fx_events`, and the absolute source clip ranges
in `xbf_animation_entries`. Those range entries use the final baked animation
name, after model-specific conversion repairs, while `source_name` preserves
the original XBF label. Consequently every authored bank follows a repaired
clip name without a corresponding runtime workaround. Undecoded words and the
raw event block remain available as metadata as well. Alongside the type-3/4
bank start/stop pair, event types 1 and 2 carry object visibility: type 1 hides
the object named in its single string, type 2 shows it. The `?bigflash1` muzzle
helpers of `AT_Kindjal`, `OR_Mortar` and `IM_Sardaukar` establish the direction
— each blinks for one to five frames per shot, from a type 2 to the following
type 1, and every sequence ends hidden. `CombatProjectile` uses this to switch
off helper geometry that a projectile model never shows (see docs/quirks.md,
"The shell's propulsion flare is authored, then switched off by its own model"). Bank parameter 05 is
signed gravity per source update squared, while parameter 06 is particle size
in source-model coordinates. Thus the `!%shel` values 10 (Minotaurus), 6
(Trike), 4 (APC), and 3 (light infantry and Sniper) become 0.625, 0.375, 0.25,
and 0.1875 world units at the normal 1/16 model scale. Casing count is encoded
by the frames strictly between the bank's type-3 start and type-4 stop events,
with a one-frame pulse still yielding one particle: Minotaurus gets one per
barrel, Trike two per `Fire 0`, light infantry seven across its three burst
intervals, and Sniper one. The APC also authors three small casings in one
`!%shel` interval attached to `::1turret#`; the Mongoose has no casing bank
and only authors its `!cexp`
backblast. Runtime aligns these absolute events with the sliced `Fire_0` clip,
emits each ten-frame tumbling casing at the named attachment, and applies its
bank size and positive downward gravity. This replaces the former one-casing,
size-0.56, gravity-5.5 rear-muzzle fallback and also lets infantry with an
embedded muzzle flash retain their separate authored casing bank.

The Mongoose also selects `Muzzle3`, placing that front flash at its combined
`>>0#flame` projectile marker. Its launcher has a separate sibling `#smoke`
marker behind the tube: the firing event emits the original sixteen-frame
`!cexp` additive backblast there. The same short warm light pulse is centred on
that rear marker, so the launch illuminates both the missile mouth and the
exhaust side of the turret.

Every launcher authors that backblast the same way, so the pairing follows the
data rather than the `#smoke` name: a tube takes the nearest `#` attachment
marker parented alongside it that holds a baked still billboard, and replays
that marker's own bank. The Devastator's `#flare01..03` sit behind
`>>0..2missile_salvo#` and carry the twenty-frame `!exp0` rocket flare; the
Missile Tank's `#M0..#M5` are excluded because their banks emit particle
streams that its own `Fire_0` clip already drives. The authored start/stop pair
spans a single frame, which is why the baked billboard cannot show the sequence
and the runtime replays it. Embedded `?bigflash`/`?bflash` geometry suppresses
the rules-supplied flash only for the weapon that owns it — it is authored as a
sibling of that weapon's `::` pivot, so the Devastator's `::0plas` barrel
flashes no longer silence the `::1` salvo launcher, which authors none.

On a resolved impact, the bullet's ordered `ExplosionType` entries select the
short-lived world-space visuals mapped by `ArtIni`; the effect survives the
projectile node long enough to play its source animation once. The Minotaurus'
`KobraHowitzer_B` selects `ShellHit`, rendered from the original
`3DDATA/Explosion/shellhit.xbf`. That file's blue `#bing` cubes are hidden
animated emitter anchors, not visible blast geometry. XBF event types 3/4
start and stop (rather than timestamp) the FX banks: one central `!%Bru` burst,
followed by a loose radial spray of small warm-white particles. Every particle
receives an independent random horizontal direction and speed; the hidden
`#bing1–4` motion must not appear as four fixed rays. The burst's first two fire
frames stay opaque, while its following smoke frames render translucent. A
two-frame orange point-light flash then leaves roughly ten source frames of
weaker local illumination. Range exhaustion and target loss are expiry events
rather than impacts and therefore do not request this effect.

The Mongoose's `HEAT_B` selects `MissileHit`. Like `ShellHit`, its source XBF is
an emitter rig rather than visible cube geometry: `#bigbing` drives the central
`!%Bru` fire/smoke burst and `!@sm` produces the loose randomized shrapnel
spray. A second group of the same small particles expands at one radial speed
to preserve a ring, with independently randomized positions around its
circumference. The four animated `#bing1–4` helpers stay hidden rather than
appearing as four large diverging objects. For both `ShellHit` and `MissileHit`,
shrapnel keeps its final sprite frame after the texture sequence, follows its
ballistic arc to the ground, and then fades instead of disappearing in mid-air.
The detonation receives the same brief warm point-light flash.

Summary of how different bullets miss (follows from the verified behavior above):

- **non-homing arc bullets**: no lead means the bullet reaches the plane through
  the target's sampled former position. It does not correct sideways after
  leaving the muzzle, so a side-mounted barrel keeps its lateral offset and the
  warhead's splash resolves at that offset impact point;
- **missiles**: a miss means the target dodged beyond the turn-rate limit or the
  bullet outlived its lifetime; target death in flight → self-destruction;
- **laser**: never misses.

## 4. Range, elevation, visibility

- `MinRange`/`MaxRange` are measured from the stable gameplay origin of the
  firing entity. The animated muzzle is the projectile spawn point, but moving,
  elevating, or entering a `Fire` pose cannot move the weapon itself into or out
  of gameplay range (verified);
- **downhill range bonus**, increasing with height difference `[← 1 §2]`;
- firing uphill is possible only with indirect fire `[← 1 §2]`;
- a flat-flying shot also needs an **unobstructed line of fire**: bullets collide
  with terrain and buildings while travelling, so a target inside range but
  behind a cliff shoulder or a building cannot be hit from that spot. Nothing
  fires without that line (implemented):
  - a **unit** treats the blocked line like an out-of-range target and keeps
    repositioning until the shot lands on the target instead of the obstacle; if
    no reachable position inside weapon range can see the target, it holds;
  - a **defensive building** cannot reposition, so it drops the shielded target
    and automatically engages a reachable enemy instead. An explicit order stays
    attached and takes the weapon back once the obstacle falls or a mobile target
    leaves cover;
  - trajectory bullets lob over obstacles and ignore this entirely;
  - units never obstruct each other's line of fire (implementation decision: a
    vehicle driving through the line must not abandon a valid engagement);
- the **target must be visible** (by the player's scouting/vision) to issue an
  attack order `[?]`; the **attack ground** order exists (verified, §3) — firing
  at a coordinate without a target, a tool for manual leading and area fire;
- a unit's **vision** radius and **weapon** radius are independent parameters
  `[Rules]`; can a weapon outrange vision (requiring a spotter) `[?]`.

## 5. Automatic target acquisition

- In the defensive stance, a unit **opens fire itself** on enemies in range; in
  the passive stance, it only responds `[← 5 §2]`;
- auto-acquisition priorities: nearest target or weighted selection
  (threat/type) `[?]`;
- a unit **pursues** a target that leaves range when auto-acquiring `[?]` (and
  how far — leash from the guard point `[?]`);
- guard order: reaction radius and return to post `[?]`.

## 6. Damage states

- **Vehicles — “burning” threshold** `[← 5 §7.0.1]`: below an HP threshold, a
  vehicle burns (visible smoke/fire), and a burning vehicle cannot use stealth.
  Clarify `[?]`:
  - whether it burns with gradual HP loss (burns to death) or is merely a state marker;
  - whether the threshold is shared by all vehicles or per unit `[Rules]`;
- **infantry**: are there state stages (wounds) `[?]` — presumably not;
- **buildings**: visual damage stages (smoke/fire) `[?]`; do they affect
  functionality (such as slower production at low HP) `[?]`.

## 7. Anti-air capability

- The ability to hit air is the Bullet `AntiAircraft` flag `[Rules]`;
- air is unreachable by non-AA weapons `[← 5 §3]`, except for a landed plane
  (a ground unit `[← 5 §3]`);
- air-only weapons exist: `ATHEATADP_B` combines `AntiAircraft = true` with
  `AntiGround = false` `[Rules]`.

## 8. Residual-effect areas

Shared “area on the ground” mechanism, extensible by type `[← 1, 5]`:

| Area | Source | Effect | Verified in |
|------|--------|--------|-------------|
| chemical | Inkvine | DoT to infantry only; ignitable by any AoE | section 5 §7.1 |
| fire | chemical ignition | damages all; infantry burns instantly; burns out quickly | section 5 §7.1 |
| radiation | Devastator self-destruction | residual area damage `[Rules]` | section 5 §7.1 |
| fresh spice | bloom explosion | periodic damage for a time | section 1 §3 |

Questions `[?]`: is this a single engine mechanism; do areas stack; do they affect
buildings; does Harkonnen flame weaponry create an ignition area by itself.

## 9. Splash and friendly fire

- AoE damage from explosions affects everyone in the radius, including allies `[?]` —
  which weapons have friendly fire (Sonic Tank is confirmed `[← 5]`);
- the splash from the shot that finishes a building does not kill survivors
  (1 second of invulnerability) `[← 3 §7.3]`;
- splash falloff from center to edge `[Rules]` `[?]`.

## 10. Open questions pending verification

Consolidated by section: §1 (whether specialization is entirely matrix-driven),
§2 (weapon selection, simultaneity, runtime turret aiming), §3 (misses/overshoots/
overdamage), §4 (attack ground, weapons beyond vision), §5 (priorities, pursuit,
guard), §6 (burning: does it burn to death; building stages), §8 (whether area
mechanisms are shared), §9 (friendly fire, falloff).
