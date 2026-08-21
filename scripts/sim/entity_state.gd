class_name SimEntityState
extends RefCounted

## Flat hot-state store for entity position -- the container decision 3
## promises in docs/architecture/network-multiplayer.md ("Simulation core
## owns state; nodes are views"): "hot state -- position, velocity, facing,
## health, owner -- lives in flat Packed*Arrays indexed by entity id." This
## slice (phase 3, C1) builds the container and stores exactly one of those
## five fields, position; nothing in the simulation writes into it yet.
## Slice C2 migrates position and facing reads/writes here (facing needs its
## own array, added the same way position's is below -- copy the pattern,
## do not generalize it into something id-and-type-agnostic; every command
## subclass in scripts/sim/commands/ repeats its own read/write pair for the
## identical reason: GDScript has no generics worth the indirection here).
## C3 does health, C4 owner. Velocity is deliberately not staged for a
## slice: the phase 3 notes in the design doc found `Unit` keeps its own
## `velocity` on the CharacterBody3D node ("the node class stays because it
## still carries velocity... changing it would touch every unit scene to
## buy clarity, not behaviour"), so there is no known consumer for a sim-side
## velocity array yet -- adding one now would be exactly the general-purpose
## store the design doc says to avoid building ahead of a reader.
##
## Storage type: `PackedVector3Array`, `float32`. This is not picked here --
## see the design doc's "Answered 2026-08-21" precision question at the
## bottom of the file. `Vector3` components are already `float32` in this
## build (decision 5's own measurement), so `PackedVector3Array` changes
## nothing about precision; `PackedFloat64Array` would be a false upgrade,
## truncated back to `float32` at every `Vector3` boundary the simulation
## already crosses constantly (`global_position`, `SimMoveCommand`, ORCA).
##
## Indexing: directly by entity id (scripts/sim/entity_registry.gd), the
## same id space commands and replays already name entities by. The
## alternative -- a packed array plus an id-to-slot map with a free list --
## was rejected on arithmetic, not taste. SimEntityRegistry ids are
## sequential from 1 and never reused, so the arrays here grow with every id
## ever allocated, not with the live count. At this project's scale that
## cost is negligible: the fastest unit in assets/converted/rules.db builds
## in 65 rules-authored ticks (ATScout/ORScout, ~1.08s at the rules' 60 Hz
## authoring rate -- see decision 4), and even an unrealistic sustained 50
## concurrent producers at that rate is under 50 entities/second, or well
## under 200,000 entities ever allocated across a 60-minute match times 4
## players. `Vector3` packed at `float32` is 12 bytes; 200,000 of them is
## 2.3 MB. A slot map would avoid that growth but cost a Dictionary entry
## per live entity instead, and GDScript's Dictionary overhead per key is
## itself well above 12 bytes -- so the "wasteful" direct-index array is
## cheaper in practice, not just simpler, and it is simpler: no second id
## space to keep in sync with the registry's, which is exactly the kind of
## hand-kept bookkeeping this project tries not to add. Reconsider only if a
## single match is ever expected to allocate on the order of 10 million
## entity ids, which nothing about this game's pacing suggests.
##
## Liveness is not duplicated here. This store takes the match's
## SimEntityRegistry by reference and asks it `is_alive()` on every access
## instead of keeping its own alive set -- the registry is already the
## single source of truth for which ids are alive, and a second copy of
## that bookkeeping is a bug waiting for the day the two fall out of sync.
##
## Double buffering lives here, not in slice B4. B4 (view-layer
## interpolation, docs/architecture/network-multiplayer.md phase 3) needs
## two consecutive ticks' values to blend between rendered frames. The
## alternative -- B4 keeping its own "last frame's value" cache -- was
## rejected because the view has no reliable way to tell "a new tick landed"
## from "the same tick's value was read again this frame" without
## reconstructing exactly the bookkeeping this store already has to do to
## grow its arrays; it would end up as a second, shadow copy of this store,
## indexed by the same ids, resized on the same schedule, and liable to
## drift from it. This store already knows the one moment that matters --
## the write that replaces one tick's value with the next -- so it shifts
## "current" into "previous" right there, in set_position(), once per write.
## That assumes exactly one write per entity per tick, which matches how
## every per-entity system already joins the tick (see
## docs/architecture/network-multiplayer.md, "The simulation tick": "Per-entity
## systems join a group... and get a sim_tick() from a loop"). Deciding this
## now instead of after B4 lands matters because the alternative would mean
## touching every reader B4 introduces to insert a second store underneath
## it; previous_position() exists from the start instead, unused until B4
## calls it, so no caller written before B4 has to change when it does.
##
## Reading or writing a dead, never-allocated, or never-written id is an
## error you can see: push_error() plus a refusal to read/write, never a
## silently returned zero. That distinction is deliberate --
## scripts/match/replay_file.gd's doc comment records the bug this project
## already shipped once, where StreamPeerBuffer.get_data() zero-pads a short
## read with no signal at all. A Vector3.ZERO returned here is always
## preceded by a push_error() naming exactly which id and why, so it cannot
## be mistaken in a log for a legitimately-zero position the way a silent
## zero-pad can.
##
## Snapshot: capture()/restore() are the "cheap copy of a handful of packed
## arrays" decision 3 promises reconnect and save/load. This class does no
## file I/O -- the sim zone forbids it (tools/architecture_rules.toml,
## zones.sim) for the identical reason scripts/match/replay_file.gd's doc
## comment gives for ReplayFile living outside the zone. capture() returns a
## plain Dictionary of JSON-safe types (Array, int, float), matching
## MatchSnapshot's own _encode_vector3()/_decode_vector3() convention
## (scripts/match/match_snapshot.gd) so a later slice can drop it straight
## into that class's `state` dictionary and let its existing
## JSON.stringify() carry it, rather than inventing a second wire format.
## Only ids that have actually been written are captured -- not the full
## sparse array, gaps included -- which keeps snapshot size proportional to
## the live entity count rather than to the id high-water mark, and answers
## part of the design doc's open "snapshot size for reconnect" question for
## the position field once this lands. previous_position() is deliberately
## not captured: restore() sets it equal to the restored current position
## for every id, because "the tick before this snapshot" is not a
## meaningful value across a save/load or reconnect boundary, and carrying
## stale data forward would produce exactly one frame of bogus interpolation
## right after every restore.

var _registry: SimEntityRegistry

## Position as of the most recent set_position() call for each id --
## "current". Index 0 is never used: ids start at 1 (SimEntityRegistry).
var _position: PackedVector3Array = PackedVector3Array()
## Position as of the set_position() call before that -- "previous". Equal
## to _position for an id that has been written exactly once, or that was
## just restored from a snapshot -- see this class's doc comment.
var _position_previous: PackedVector3Array = PackedVector3Array()
## 1 once set_position(id, ...) has been called at least once for that id, 0
## otherwise -- including for ids inside an array that has already grown
## past them because a *later* id was written first. Array bounds alone
## cannot answer "has id X been written": resize() zero-fills every new
## slot it creates, not just the one that triggered the growth, so an id
## sitting in a not-yet-written gap would silently read back as a
## plausible-looking Vector3.ZERO without this flag.
var _has_value: PackedByteArray = PackedByteArray()


func _init(registry: SimEntityRegistry) -> void:
	_registry = registry


## Writes `value` as `id`'s position for the tick this call represents,
## shifting the previous current value into previous_position() first. A
## no-op, loudly, if `id` is not currently alive -- see this class's doc
## comment on why a write to a dead id refuses rather than corrupting
## whatever the array's stale slot for that id currently holds.
func set_position(id: int, value: Vector3) -> void:
	if not _registry.is_alive(id):
		push_error(
			"SimEntityState.set_position(): id %d is not alive (dead or never allocated) -- write refused" % id
		)
		return
	_ensure_capacity(id)
	if _has_value[id] == 1:
		_position_previous[id] = _position[id]
	else:
		# First write for this id ever: previous == current, so an
		# interpolating reader never blends from a spawn-time Vector3.ZERO
		# it was never actually at.
		_position_previous[id] = value
		_has_value[id] = 1
	_position[id] = value


## `id`'s position as of its most recent set_position() call. Errors loudly
## (see this class's doc comment) and returns Vector3.ZERO for a dead,
## never-allocated, or never-written id -- check has_position() first if
## that is a normal possibility at the call site rather than a bug.
func position(id: int) -> Vector3:
	if not has_position(id):
		push_error(
			"SimEntityState.position(): id %d has no position -- dead, never allocated, or never written" % id
		)
		# Vector3.INF, not Vector3.ZERO: the origin is a legal position --
		# nav_world_bounds starts at (0, *, 0), so it is literally a corner
		# of every shipped map -- which would make "no value" and "standing
		# in the corner" the same answer. INF is this codebase's existing
		# no-value marker for a Vector3 (UnitFlightController's
		# _landing_target, Unit.move_to()'s exit_point), it is checkable with
		# is_finite(), and it poisons arithmetic loudly instead of quietly
		# placing an entity somewhere plausible.
		return Vector3.INF
	return _position[id]


## `id`'s position as of the set_position() call before its most recent one
## -- the second of the two consecutive ticks' values B4 interpolates
## between. Same error behaviour as position().
func previous_position(id: int) -> Vector3:
	if not has_position(id):
		push_error(
			"SimEntityState.previous_position(): id %d has no position -- dead, never allocated, or never written"
				% id
		)
		# Vector3.INF, not Vector3.ZERO: the origin is a legal position --
		# nav_world_bounds starts at (0, *, 0), so it is literally a corner
		# of every shipped map -- which would make "no value" and "standing
		# in the corner" the same answer. INF is this codebase's existing
		# no-value marker for a Vector3 (UnitFlightController's
		# _landing_target, Unit.move_to()'s exit_point), it is checkable with
		# is_finite(), and it poisons arithmetic loudly instead of quietly
		# placing an entity somewhere plausible.
		return Vector3.INF
	return _position_previous[id]


## True once set_position(id, ...) has been called at least once for a
## currently-alive id. The one way to ask "would position(id) succeed"
## without triggering its push_error().
func has_position(id: int) -> bool:
	return _registry.is_alive(id) and id < _has_value.size() and _has_value[id] == 1


## Array length backing every field this store holds -- the id high-water
## mark among ids that have actually been written, plus one. Test-facing:
## proves restore() replaced the arrays rather than merging into them.
func capacity() -> int:
	return _position.size()


## Captures every written id's current position into a plain, JSON-safe
## Dictionary -- see this class's doc comment for why previous_position()
## is not included and why only written ids are captured.
func capture() -> Dictionary:
	var written_ids: Array = []
	var position_rows: Array = []
	for id in _has_value.size():
		if _has_value[id] == 1:
			written_ids.append(id)
			position_rows.append(_encode_vector3(_position[id]))
	return {
		"version": 1,
		"written_ids": written_ids,
		"position": position_rows,
	}


## Replaces this store's entire contents with `data`, previously returned by
## capture(). Fails closed -- pushes an error and leaves the current
## contents untouched -- if `data` is not a well-formed capture() result,
## the way MatchSnapshot.restore() and ReplayFile.read() both fail closed on
## header-level corruption rather than partially applying it. On success,
## every id absent from `data` is gone from this store afterward, even if
## it was written here before the call: restore() replaces, it does not
## merge. Returns whether it succeeded.
func restore(data: Dictionary) -> bool:
	if int(data.get("version", 0)) != 1:
		push_error("SimEntityState.restore(): snapshot has no recognized version -- refusing to load")
		return false
	var raw_ids: Variant = data.get("written_ids")
	var raw_positions: Variant = data.get("position")
	if not raw_positions is Array:
		push_error("SimEntityState.restore(): snapshot 'position' field is missing or malformed")
		return false
	if not (raw_ids is Array or raw_ids is PackedInt32Array):
		push_error("SimEntityState.restore(): snapshot 'written_ids' field is missing or malformed")
		return false
	var ids := _coerce_id_list(raw_ids)
	var positions: Array = raw_positions
	if ids.size() != positions.size():
		push_error("SimEntityState.restore(): 'written_ids' and 'position' have different lengths")
		return false
	for i in positions.size():
		if not _is_vector3_row(positions[i]):
			push_error("SimEntityState.restore(): malformed position entry at index %d" % i)
			return false
		if ids[i] < 1:
			push_error("SimEntityState.restore(): malformed id at index %d" % i)
			return false

	var max_id := 0
	for id in ids:
		max_id = maxi(max_id, int(id))
	var new_size := max_id + 1
	var new_position := PackedVector3Array()
	new_position.resize(new_size)
	var new_has_value := PackedByteArray()
	new_has_value.resize(new_size)
	for i in ids.size():
		var id: int = ids[i]
		new_position[id] = _decode_vector3(positions[i])
		new_has_value[id] = 1

	_position = new_position
	_position_previous = new_position.duplicate()
	_has_value = new_has_value
	return true


func _ensure_capacity(id: int) -> void:
	if id < _position.size():
		return
	var new_size := id + 1
	_position.resize(new_size)
	_position_previous.resize(new_size)
	_has_value.resize(new_size)


## Normalizes written_ids, which capture() emits as a plain Array but a
## snapshot that already round-tripped through JSON could hand back as
## floats (JSON has no integer type). Returns an empty Array for anything
## that is not an Array or PackedInt32Array at all -- callers distinguish
## "genuinely empty" from "wrong type" via raw_ids directly, as restore()
## does above.
func _coerce_id_list(raw_ids: Variant) -> Array:
	var ids: Array = []
	if raw_ids is PackedInt32Array:
		for raw_id in (raw_ids as PackedInt32Array):
			ids.append(int(raw_id))
	elif raw_ids is Array:
		for raw_id in (raw_ids as Array):
			ids.append(int(raw_id))
	return ids


func _is_vector3_row(value: Variant) -> bool:
	if not value is Array:
		return false
	var row: Array = value
	if row.size() != 3:
		return false
	for component in row:
		if not (component is float or component is int):
			return false
	return true


func _decode_vector3(row: Array) -> Vector3:
	return Vector3(float(row[0]), float(row[1]), float(row[2]))


func _encode_vector3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
