# Emperor: Battle for Dune Mechanics — 4. Production

This section combines the entire production loop: building construction, map
placement, unit production, upgrades, and the tech tree. The monetary side
(gradual deduction, pausing when funds are insufficient, and a full refund on
cancellation) is already recorded in section 3 §6 and is not repeated here.

**Labels:**
- `[?]` — requires verification;
- `[Rules]` — parameterized in `Rules.txt`;
- `[→ N]` — details in section N of the series.

Status: **verified**.

---

## 1. Building construction

- Buildings are constructed by the **Construction Yard** — the root of the
  entire tech tree (see section 2 §1.3);
- construction proceeds “virtually” in the side panel: the player selects a
  building, it is built with progress and gradual money deduction; on completion
  it enters the **“ready for placement”** state and waits for the player to place
  it on the map (verified);
- **order management** (verified):
  - construction can be **paused** and resumed;
  - an order can be **cancelled** at any stage — including a building already
    ready for placement (money is refunded — section 3 §6);
  - **auto-cancellation**: if the building's availability conditions cease to be
    met during construction (a prerequisite is lost), the order is cancelled
    automatically. However, if the order has **already reached “ready for
    placement”** status, it remains and is not cancelled. The rule also applies
    to **upgrades under construction** (verified) — an upgrade becomes
    irreversible (§5) only after its purchase completes;
- the **construction queue is one per player** (verified), not one per
  Construction Yard: multiple Construction Yards provide neither parallel queues
  nor acceleration. Double-clicking a Construction Yard designates it as the
  **primary** one, and it becomes the **main base** (verified). The general rule:
  the main base is a **fallback return point** for units that “need to return
  somewhere” when no normal return target remains:
  - **harvesters**: their bunker is full and all refineries are destroyed → they
    go to the main base;
  - **aircraft**: ammunition is depleted and no landing pads remain → they return
    to the main base;
  - **reinforcements** (campaign): appear on the map already ordered to travel
    to the main base;
  - the list is open — extend it when new cases are found;
- **MCV** (verified):
  - built at the factory as a unit; **deploys** into a Construction Yard;
  - a Construction Yard can be **packed back up** into an MCV; it cannot construct
    while in unit form. In runtime this is initiated by giving the selected,
    completed Construction Yard an ordinary move order; the resulting concrete
    House MCV inherits that same destination and movement mode;
  - this is the **only building that appears not from a panel order but from a
    unit deployment**. Consequently, the deployment eligibility check **does not
    consider proximity to other buildings** (the build radius, §2) — an MCV can
    *start* a base, including a new base at any point on the map;
- losing all Construction Yards means losing the ability to construct buildings
  (but not units); recovery is possible by building an MCV at a factory, if the
  factory is still alive.

---

## 2. Building placement

Rules for placing a ready building on the map:

- **only on `rock`** (`TYPE 1`) — see section 1 §1: `nonbuildrock` is visually
  indistinguishable but excluded; this is the only “type for appearance / type
  for rules” pair in the logical grid;
- **footprint** (verified): the footprint shape of each building is specified as
  a **matrix** in `Rules.txt`. The matrix is **coarse-grained**: one cell covers
  **4 cells of the logical surface grid** (a 2×2 block). The entire footprint
  must lie on buildable cells and be free of buildings;
- **units at the construction site do not block placement — they are pushed
  aside** (verified): when a building is placed, units are displaced from its
  footprint. That is the original's behaviour and this entry does not change.
  **OpenEBfD diverges, and as of slice `AF1` the divergence covers every unit
  rather than only immobile ones** — on the path the player places buildings
  through, a unit standing in the footprint makes the placement *wait* for up
  to five seconds while the site clears, and the order is abandoned if it has
  not. An immobile (deployed/deploying) unit therefore usually outlasts the
  deadline, since nothing can move it. Since slice `AH1` the same is true of a
  wall segment, through the chain's own skip rather than through an abandoned
  order (see the walls entry below), so the two routes a player actually builds
  through both wait. See [`quirks.md`](../quirks.md), "A
  deployed unit on a building site was engulfed rather than blocking", and
  decision 12 in
  [`network-multiplayer.md`](../architecture/network-multiplayer.md).
  Since slice `AI1` the same is true of MCV deployment, which waits for the
  footprint of the Construction Yard it is about to become, so **no path
  displaces a mobile unit** any more: every route to a building spawn asks the
  execution-time check first. Since slice `AJ1` the shove itself is deleted, so
  **a building spawn moves no unit** at all: the check is the only thing that
  keeps a unit out of a new building, and a unit it does not see stays where it
  stands;
- **build radius** (verified): a new building can be placed only near the
  player's existing buildings `[Rules: radius]`. **All buildings except walls**
  provide this radius; walls extend the radius **only for constructing other
  walls** (an ordinary building cannot “reach” through a chain of walls). The
  sole exception to this check is MCV deployment (§1);
- **height changes are not buildable** (verified): ramps (`TYPE ramp`) are
  excluded from construction, as are sloped sand areas (dunes). Thus, the
  “flatness” check is a separate rule and cannot be reduced to surface type;
- **walls** (verified) are a special form of construction:
  - ordered as a **line from point A to point B**, built **one cell at a time**:
    each cell is a separate order in the construction queue, automatically
    placed after the preceding buildable cell completes successfully;
  - cells where construction is not allowed are shown as blocked during line
    selection and **skipped without stopping the remaining wall chain**. Since
    slice `AG1` an OpenEBfD wall segment also skips a cell held by an immobile
    (deployed/deploying) unit, through that same skip rather than by engulfing
    it. Since slice `AH1` a cell held by a unit that *can* move is not skipped
    at once either: the segment waits up to five seconds for the unit to leave,
    with its cell reserved against parking so no unit may be ordered to stop
    there, and it is built the moment the cell clears. Only when the deadline
    passes is the segment refunded and skipped, through that same outcome. The
    icon reads `BUILDING` and accepts no clicks while a segment waits, so the
    wait cannot be cancelled — the deadline is its only exit. The blocked-cell
    *preview* is still terrain-only, deliberately, and `AH1` strengthens the
    reason rather than weakening it: segments are ordered one at a time over
    many seconds, and a unit's position during line selection now says even
    less about the outcome, since a unit that is there when the segment is
    ordered may simply be waited out;
  - after the line is confirmed, its buildable cells retain `build_wall`
    markers until the corresponding segment is built or the order is canceled;
  - **cancelling one cell's order also cancels all later ones** (the next cell is
    auto-ordered only when the previous buildable one succeeds);
  - block **passability and visibility**; projectiles with **indirect trajectories
    (artillery) pass over walls**, while direct-fire projectiles are blocked
    (3D collision, section 1 §1);
- after placement, there is a **short construction animation** during which the
  building is **invulnerable** (verified).

### 2.1 Building destruction (included here as part of the life cycle)

- When a building is destroyed, **surviving units** appear with **1 second of
  invulnerability** against the splash that finished the building (the rule is
  recorded in section 3 §7.3 together with the `[design]` deviation about selling);
- the survivor composition is always the same (verified): the basic infantryman
  of the House that owned the building; the **quantity** is `[Rules]` — the
  per-building `NumInfantryWhenGone` field in `Rules.txt` (e.g. `ATConYard`/
  `ATBarracks` = 3, `ATSmWindtrap` = 1);
- survivors spawn with **70% HP** (verified);
- no debris or ruins remain; footprint cells are freed immediately (verified).

---

## 3. Unit production

Runtime unit creation resolves the completed unit's `config_id` through
`UnitSceneCatalog` and instantiates the same prepared scene that designers can
place in a Godot mission. Scenes and definitions load lazily and are cached. A
missing prepared scene falls back to the generic `unit.tscn` plus its converted
model; the dedicated Harvester scene and lifecycle remain intact. See
[`docs/architecture/unit-data-migration.md`](../architecture/unit-data-migration.md).

- Production buildings: **barracks** (infantry), **factory** (vehicles, including
  harvesters and MCVs), **hangar** (aircraft and carryalls), **Sub-House building**
  (Sub-House units — section 2 §1.2), and **starport** (batch orders — section 3 §4);
- the production queue is **one per building type** (verified): multiple buildings
  of one type do **not** provide parallel queues or accelerate production. **Queue
  capacity is 100 units** (verified); **shift+click adds 10** per click;
- **primary building**: when there is more than one building of a type, a
  **double-click** designates the primary one — completed units emerge from it.
  Design consequence: bases in different parts of the map + switching the
  production exit point between them (verified);
- a completed unit **emerges from the primary building** into the world; a
  **rally point** is assigned to the building (verified);
- Sub-House units emerge from the Sub-House building (verified, section 2);
- **population limit**: no hard cap has been found in the original — it was not
  reached in practice, and no parameter was found in `Rules.txt`.
  > `[design]` Our implementation introduces a safety cap of **1,000 units per
  > player** — protection against degenerate scenarios, unreachable in normal play.

---

## 4. Upgrades

- An upgrade is a credit purchase through the **upgrade panel** (encountered
  earlier: refinery docks, section 3 §3);
- **binding** (verified): refinery docks advance one refinery instance through
  three states (no upgrades → right dock → right and left docks). The target is
  selected automatically from owned refineries that can still upgrade; no map
  selection is required. All other upgrades are **global per type** (purchased
  once, effective for all buildings of that type);
- **roster expansion** (verified): every production building **and the
  Construction Yard** has an upgrade that unlocks next-tech-level entries; the
  “upgrade → unlocks” links are described in `Rules.txt` `[Rules]`;
- upgrades **are built over time**, like buildings, and have their **own queue —
  one per player** (verified). Thus, there are three queue types: buildings (one
  per player), upgrades (one per player), and units (one per building type).
  Construction Yard upgrade timing is an original-data exception documented in
  [`docs/quirks.md`](../quirks.md#construction-yard-upgrades-have-no-build-time-field).

---

## 5. Tech tree

- Form: a **prerequisite graph** — every building/unit/upgrade has a list of
  conditions `[Rules: prerequisites]`; the root is the Construction Yard
  (section 2 §1.3);
- **prerequisite composition** (verified): buildings and/or upgrades — for units,
  these are production-building upgrades; for buildings, other buildings and
  **Construction Yard** upgrades;
- **loss of a prerequisite building** (verified): what has already been
  constructed/produced remains; new entries disappear from menus until the
  prerequisite is restored;
- **upgrades are irreversible** (verified): a purchased upgrade is not lost when
  buildings are lost — the “upgrade purchased” state belongs to the player, not
  the building. The sole exception is refinery docks: they are instance-bound (§4)
  and are destroyed with it;
- **map tech level**: campaign maps impose an upper limit on accessible tree depth
  (section 2 §1.3 — the “map settings” filter) `[Rules/map]`;
- the palace is the top of the tree and unlocks a superweapon `[→ 8]`.

---

## 6. Open questions

None — all section questions have been resolved through verification.
