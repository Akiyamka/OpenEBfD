# Emperor: Battle for Dune Mechanics — 1. World Properties

The first document in a series about the original game's mechanics. It describes the **logic**
that the engine applies to the world; specific numerical parameters reside in `Rules.txt`
and are intentionally not duplicated here—the document records *what* the engine does with them.

It complements `terrain-contour-system.md` (terrain structure) and `emperor-map-file-format.md`
(baked data): those explain how the world is *stored*, while this one explains how it *behaves*.

**Labels:**
- `[Rules]` — the behavior is parameterized in `Rules.txt` (logic in the engine, numbers in the file);
- `[design]` — a note about an intentional deviation of our implementation from the original.

Status: **verified** (checked by someone with extensive knowledge of the game).

---

## 1. Surface types and their gameplay meaning

A tile's logical type (`TYPE` from `tiledef.dat`, see `terrain-contour-system.md` §2) is
a contract: the editor stores a number, and the engine attaches rules to it. Rule summary:

| TYPE | Surface | Movement | Building | Special rules |
|------|---------|----------|----------|---------------|
| 0 | `sand` | all ground units | no | worm territory; spice is found here |
| 1 | `rock` | all ground units | **yes** | the only buildable type |
| 2 | `cliff` | air only | no | blocks **visibility** (see §2) |
| 3 | `nonbuildrock` | all ground units | no | visually rock, excluded from building |
| 4 | `infantryrock` | **infantry only** | no | infantry refuge (see §1.1) |
| 5 | `dustbowl` | air, hovering units, Dust Scout | no | quicksand (see §1.2) |
| 6 | `mapedge` | nobody (an aircraft caveat—§5) | no | technical map border |
| 7 | `ramp` | all ground units | no | transition between elevation levels |

An important separation of responsibilities: surface type governs **passability and
visibility**, but **not** projectile blocking. The game is three-dimensional—whether a
projectile hits a rock is determined by the normal geometry collision calculation; tile type
is not used for that.

The world's key asymmetry is that **rock is safe but limited; sand is boundless but dangerous**
(worms)—while the resource exists only on sand. The game's entire economic loop is built around
forays from rock onto sand.

### 1.1 Infantry rock

Elevated terrain accessible only to infantry. Rules:

- vehicles (wheeled/tracked) cannot enter → infantry there **cannot be crushed**;
- **protects from worms** — worms do not attack infantry rock;
- infantry on infantry rock receive a **defense bonus** `[Rules]`;
- it can nevertheless be hit by **any weapon**—there is no attack block, projectiles reach it,
  but deal less damage because of the defense bonus.

This is a deliberate design tool for “infantry nests”: controlling such positions gives infantry
a role that vehicles would otherwise consume.

### 1.2 Dustbowl — quicksand

Quicksand depressions. Only the following can cross them:

- air units;
- **hovering** units (Ordos hover vehicles);
- the **Dust Scout** (a special Ordos unit)—which can also **submerge** into quicksand:
  below the surface it is invisible, cannot be revealed, and cannot take damage
  (details: section 5 §7.0.1).

For all other ground forces, this is impassable terrain. Thus, the dustbowl is a terrain filter
by movement method and, at the same time, a hideout for one specific scout unit.

---

## 2. Elevation, range, and visibility

Terrain is not decorative, but it works more subtly than through “line-of-fire blocking”:

- **downhill range bonus**: a unit standing above its target gains additional firing range
  against targets below; the greater the elevation difference, the greater the bonus `[Rules]`;
- **uphill**, only **indirect-fire weapons** (a ballistic arc) can fire; direct-fire weapons
  cannot hit a target on a plateau—not due to a tile-type rule, but because the projectile
  physically strikes the cliff wall (collision calculation, §1);
- **across a depression**, units on two adjacent rocks can freely fire at each other if the
  weapon's radius is sufficient—without restrictions or bonuses (there is no elevation
  difference between attacker and target);
- **visibility is asymmetric**: a unit below **does not reveal** territory atop a cliff;
  vision from above works normally. Thus, `cliff` blocks fog-of-war revelation specifically
  in the upward direction.

Data connection: the engine takes elevation from baked `test.CPF` (256×256, uint16—
see `emperor-map-file-format.md` §3).

---

## 3. Spice

The game's only resource. The world (rather than economic) part of its logic:

- **exists only on sand**; field density is uneven—visually distinct “rich” and “thin”
  areas yield different amounts when harvested `[Rules]`;
- a **spice bloom** is a point-like “geyser” object and, at the same time, the **core of the
  regeneration mechanic**: it matures and **explodes**, scattering a new spice field around
  itself. Therefore spice regenerates specifically around blooms, while a field harvested
  “to nothing” without a bloom source does not return;
- **early activation**: a bloom triggers when an admitted unit enters the geyser's
  footprint (it is not necessary to wait for it to mature or shoot it). Contact
  is checked on the 25 Hz simulation tick from stored, post-movement unit positions,
  so a unit arriving on a tick can bloom it on that tick. The horizontal test uses
  each unit's authored enclosing circle, which may include empty hull corners;
  carried units and aircraft above the mound are excluded. An entry rejected
  before the 30% repeat threshold is used up until exit and re-entry;
- **explosion damage** is differentiated: nearly lethal to infantry, small damage to vehicles,
  and **none** to a harvester `[Rules]`;
- **freshly scattered spice is toxic**: for some time after a bloom triggers, the area deals
  periodic damage `[Rules]`. “Old,” settled spice is harmless—infantry can walk over it
  without consequence.

The placement of starting fields and blooms is map data (`CHUNKSPICE` in the source;
see `terrain-contour-system.md` §5).

---

## 4. Sandworms (Shai-Hulud)

A neutral world force that acts only on sand. It can be disabled in skirmish settings.

### 4.1 Attraction and spawning

- every unit has a **“tastiness”** parameter `[Rules]`; the higher the total concentration
  of tastiness on sand in an area, the greater the chance that a worm appears;
- the trigger is **sustained movement** by a group on sand: a worm spawns some distance from
  a group that has been moving on sand for long enough. Consequently, units can move over sand
  in short bursts with pauses without attracting a worm;
- from the group, the worm selects the **“tastiest”** target.

### 4.2 Attack phases

1. **Hidden approach**: after spawning, the worm moves toward its target nearly invisibly—
   only the sound and lightning-like discharges from beneath the sand give it away;
2. **Attack**: upon approaching attack range, it partially emerges and moves toward the target
   with its mouth open. Swallowing destroys the target instantly.

### 4.3 End of an attack

The attack (and the worm's presence) ends if any of the following conditions is met:

- **(a) a damage threshold is reached** `[Rules]` — the worm is extremely durable, but can be
  driven away. Its “invulnerability” is a narrative convention: technically, each visit is a
  **new unit**;
- **(b) a vehicle is eaten** — consuming one vehicle ends the attack. The worm also eats
  infantry, but **eating infantry does not end the attack** (it may wipe out several);
- **(c) the chase takes too long** `[Rules: timer]` — fast units can “kite” the worm until
  the pursuit time expires;
- **(d) no targets remain** — the attacked group has become unreachable (moved onto rock or
  infantry rock, was airlifted by a carryall), or was destroyed by something else.

### 4.4 Fremen and worms

**There is no special immunity rule.** The low chance of an attack on Fremen is an emergent
result of three factors: their units' low “tastiness,” their lack of vehicles, and the
invisibility of all their units outside of attacks. During an attack on *another* group,
however, a nearby Fremen can be eaten like anyone else.
(The game does have a genuine flag-based immunity to worms, but not for Fremen; it belongs to
the Guild's Maker unit—section 5 §7.2.)

### 4.5 Design role

The worm is a “tax” on greedy harvesting and ground marches through open sand: it forces players
to transport armies in carryalls, split up movement, and maintain an economy with spare harvesters.

---

## 5. Map borders

- `mapedge` is an impassable technical fringe around the perimeter: ground units and buildings
  can never enter it;
- **aircraft caveat**: units circling in orbit (patrol circles) can *fly* beyond the border,
  but cannot be given a direct order to fly there;
- reinforcements/landings from off-map are mission script logic (`CHUNKGAME`), not world logic.

---

## 6. Weather: tornadoes

A dynamic weather event, present in both campaign and skirmish (in skirmish it is
**disableable** in the settings, as are worms):

- it arises at a **random location** on the map, wanders slowly and erratically, and disappears
  after a while `[Rules: timers/speed]`;
- **infantry** in its area of effect are immediately “sucked in” (destroyed);
- **vehicles and buildings** take periodic damage while within the area `[Rules]`;
- **aircraft** within the tornado's area also take damage—being airborne does not protect them
  from a tornado (verified).

> `[design]` The original had a bug: in skirmish, the tornado consistently spawned near
> **the first player's** base. In our implementation, spawning is truly random.

---

## 7. Time of day

A static map property, not a mechanic:

- it is set at the map level and affects scene colors and brightness (see `test.lit` in
  `emperor-map-file-format.md` §7);
- its only “mechanical” effect is whether lighting equipment is enabled on certain units,
  which is purely visual.

> `[design]` After recreating the original 1:1, experiment with a dynamic day/night cycle
> as an extension.

---

## 8. What the world does NOT have (negative checks)

- **no destructible/deformable terrain** — terrain is static; projectiles and explosions leave
  only crater decals;
- **no day/night cycle** (see §7—the time of day is static);
- **no functional neutral buildings in skirmish**. Story campaigns do contain capturable neutral
  buildings, but they use the same mechanism as capturing enemy buildings—an **engineer**
  (see the forthcoming units section). There are also purely decorative neutral buildings:
  they can be destroyed but provide no functionality.
