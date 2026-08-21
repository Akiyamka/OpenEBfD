class_name SimEntityRegistry
extends RefCounted

## Allocates and accounts for stable entity ids -- the identifier a command or
## a replay file will name an entity by, in place of get_instance_id(), which
## differs between machines and between runs and therefore cannot appear in
## anything that crosses the network or a save file. See
## docs/architecture/network-multiplayer.md, decisions 3-5 and phase 2.
##
## This class holds no Node reference at all, on purpose: it only allocates
## and accounts for ids. The sim layer never dereferences a node -- binding an
## id to the live Node that currently represents it is a separate, non-sim
## class, scripts/match/entity_node_index.gd, because holding node references
## is exactly what the sim zone (tools/architecture_rules.toml) forbids.
##
## Owner player id is not here either, and was not simply left out of this
## class the way it was left out of every writer before slice C4: hot state
## -- position, health, shields, owner -- belongs to SimEntityState
## (scripts/sim/entity_state.gd), never to this class, which only allocates
## and accounts for ids. C4 wired owner_player_id through that store, for
## both units and buildings.
##
## This comment used to record the reason nobody had built that wiring yet:
## a unit's or building's owner is not reliably set at the moment it enters
## the tree, so storing it anywhere keyed on entity id would have baked in a
## lifecycle assumption nobody had verified. That was checked, not assumed,
## and it was real: every fixture and demo scene sets owner_player_id as a
## scene property, which Godot applies during PackedScene.instantiate(),
## before add_child(); MatchSnapshot._restore_entities()
## (scripts/match/match_snapshot.gd) does the same on every load, calling
## entity.set("owner_player_id", ...) before root.add_child(entity). Both
## run before Unit._register_entity_id() / Building._register_entity_id()
## ever assigns an entity id, at which point owner_player_id's own property
## setter has nothing to write into yet. C4 closes this not by reordering
## those callers -- scene deserialization order belongs to the engine, and
## restoring owner before reparenting is simply how MatchSnapshot is
## written -- but by having _register_entity_id() itself push whatever the
## mirror currently holds into the store the moment the id becomes real, so
## a write that happened first is not lost. See
## scripts/sim/entity_state.gd's "Registration-time push" section.
##
## Readers have not moved. UnitCommandController's click filtering,
## EntityQuery.owner_id_of() and combat_owner_player_id() all still read
## owner_player_id off the node, and continue to for now: C2's own debt
## paragraph in docs/architecture/network-multiplayer.md already recorded
## that write slices do not migrate readers, because a dozen-plus call
## sites across combat and UI code is the same "far past where a rule stops
## being a rule" territory position's 260 read sites are in. Moving readers
## onto the store is a real slice someone still has to schedule.

enum Kind { UNIT = 1, BUILDING = 2 }

## int id -> Kind. Entries are never removed, even after release(): kind_of()
## must keep answering for a released id.
var _kind_by_id: Dictionary = {}
## int id -> true. A released or never-allocated id is simply absent, so
## is_alive() and live_ids()/live_count() need no separate liveness flag.
var _alive: Dictionary = {}
var _next_id := 1


## Returns the next sequential id for an entity of the given Kind. Ids start
## at 1 and are never reused, including after release(): a released id
## staying dead forever is what keeps a stale command ("attack entity 42")
## from silently retargeting whatever later entity happens to land in slot 42.
func allocate(kind: int) -> int:
	var id := _next_id
	_next_id += 1
	_kind_by_id[id] = kind
	_alive[id] = true
	return id


## Marks `id` dead. A no-op for an unknown or already-released id -- callers
## never need to check is_alive() first.
func release(id: int) -> void:
	_alive.erase(id)


func is_alive(id: int) -> bool:
	return _alive.has(id)


## The Kind `id` was allocated with, or 0 (falsy, since Kind starts at 1) for
## an id that was never allocated. Still answers correctly for a released id:
## kind is a fact about the id's history, not its current liveness.
func kind_of(id: int) -> int:
	return int(_kind_by_id.get(id, 0))


## Every live id, ascending, always. This is the deterministic iteration order
## phases 3 and 4 need in place of get_nodes_in_group() -- see decision 4 in
## docs/architecture/network-multiplayer.md, where that group order is called
## out as the reason phase 1 is centralization rather than determinism.
func live_ids() -> PackedInt32Array:
	var ids: Array = _alive.keys()
	ids.sort()
	var result := PackedInt32Array()
	result.resize(ids.size())
	for i in ids.size():
		result[i] = ids[i]
	return result


func live_count() -> int:
	return _alive.size()


## The id high-water mark: how many ids have ever been allocated, released
## ones included.
func allocated_count() -> int:
	return _next_id - 1
