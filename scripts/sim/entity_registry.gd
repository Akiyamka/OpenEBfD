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
## Deliberately absent: owner player id. A unit's owner is not reliably set at
## the moment it enters the tree -- building placement assigns it only after
## add_child() -- so storing ownership here would bake in a lifecycle
## assumption nobody has verified yet. The command executor reads ownership
## off the node instead, for now.

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
