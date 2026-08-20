class_name NavConstants
extends RefCounted

enum MoveMode { FREE, FORMATION }

const BLOCKER_REFRESH_SECONDS := 0.5
const ENEMY_BLOCK_SECONDS := 0.4
const FRIENDLY_YIELD_SECONDS := 0.4
const FRIENDLY_YIELD_TRIGGER_SECONDS := 0.2
const CELL_BUCKET_SIZE := 4.0
const OCCUPY_CELL_SPAN := 2
const SLOT_SEARCH_RADIUS := 32
## 0.52 s of wall-clock, rounded up from 0.5 s (10 ticks at the old 20 Hz
## navigation tick) so the anti flip-flop damping is never weakened by the
## move to 25 Hz -- see docs/architecture/network-multiplayer.md, phase 3,
## decision 4 for why this and SQUEEZE_COOLDOWN_TICKS (orca_avoidance.gd) are
## the only two navigation-tick-expressed values that needed re-deriving.
const SWAP_COOLDOWN_TICKS := 13
const PARKING_GAP_CELLS := 1
const ROUTE_LANE_COMFORT_RADIUS_FACTOR := 0.4
## A per-tick work allowance, not a duration -- unlike SWAP_COOLDOWN_TICKS
## above, this is meant to scale with the simulation tick rate (more ticks
## per second correctly buys more reroute budget per second) and must not be
## "corrected" the way the two cooldowns were.
const REROUTE_BUDGET_PER_TICK := 8
