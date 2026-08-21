class_name SimEntityState
extends RefCounted

## Flat hot-state store for entity position, health and shields -- the
## container decision 3 promises in docs/architecture/network-multiplayer.md
## ("Simulation core owns state; nodes are views"): "hot state -- position,
## velocity, facing, health, owner -- lives in flat Packed*Arrays indexed by
## entity id." Slice C1 (phase 3) built the container with position alone;
## nothing wrote into it. Slice C2 wired unit position writes through it.
## This slice, C3, adds health and shields and wires both units' and
## buildings' setters through them -- see Unit.health/Unit.shields
## (scripts/units/unit.gd) and Building.health/Building.shields
## (scripts/buildings/building.gd), whose own doc comments explain why the
## setter itself is the chokepoint here rather than a separate method like
## Unit.set_simulation_position(): every health/shields write in this project
## already funnels through the property setter, because GDScript routes
## every assignment to a property with `set(value)` through that setter --
## there is no second name for the backing storage a caller could assign to
## instead. C4 does owner. Facing and velocity are still not staged: facing
## has no reader yet either, and velocity stays out for the reason recorded
## below.
##
## Both kinds share this store. `SimEntityRegistry` already allocates ids for
## `Kind.BUILDING` from the identical id space `Kind.UNIT` uses (see
## entity_registry.gd), so a building's health lives at `_health[id]` exactly
## as a unit's does -- no second array, no per-kind branch anywhere in this
## file. C4 (owner) needs both kinds for the same reason and would have had
## to add that branch itself if C3 had not.
##
## Velocity is deliberately still not staged: the phase 3 notes in the design
## doc found `Unit` keeps its own `velocity` on the CharacterBody3D node ("the
## node class stays because it still carries velocity... changing it would
## touch every unit scene to buy clarity, not behaviour"), so there is no
## known consumer for a sim-side velocity array yet -- adding one now would be
## exactly the general-purpose store the design doc says to avoid building
## ahead of a reader.
##
## No previous-tick buffer for health or shields, unlike position. Position's
## `_position_previous` exists because slice B4 (view-layer interpolation)
## names a concrete, already-decided consumer for it -- see this file's
## position section below. Nothing analogous is decided for health or
## shields: a health bar is a legitimate thing to animate smoothly, but
## nothing has said that animation must read a previous *simulation tick's*
## value rather than tweening from whatever value the view last rendered,
## which is a view-side concern with no sim-state dependency. Adding
## `_health_previous`/`_shields_previous` now, with no reader, would be the
## same speculative generality velocity is kept out for above. If a future
## slice needs it, it costs exactly what adding it here already costs: one
## more packed array and one more line in set_health()/set_shields().
##
## Storage type: `PackedFloat32Array`, matching the `float` GDScript already
## declares for `Unit.health`/`Building.health` today. This is the position
## field's own argument, restated: a bare GDScript `float` is a double, but
## every number these fields already touch is nowhere near float32's ~7-digit
## precision boundary -- the largest health value in
## assets/converted/rules.db is in the low thousands -- so `PackedFloat64Array`
## would be a wider box for the same numbers at twice the footprint, not a
## precision upgrade. See decision 5's measured note on `float32` in
## docs/architecture/network-multiplayer.md for the general argument this
## project uses to decide packed-array width.
##
## No clamping happens inside this class. `clampf(value, 0.0, max_health)` is
## a simulation decision -- it changes the number that gets stored -- but
## `max_health` is a fact about one unit's or building's rules-authored
## definition, and decision 3 lists `health`, not `max_health`, as hot state:
## this store has no array to hold it and no business owning it. So
## Unit.health's and Building.health's own property setters compute the
## clamp exactly once and pass that same clamped number to both this store's
## set_health() and their own mirrored `health` field -- see those setters'
## doc comments. Passing the raw, unclamped value here instead would let the
## store and the mirror hold two different numbers for the same reason
## position's write site had to mirror in the same call rather than the same
## tick (see this file's position section): a clamp applied only on the way
## into the mirror is a clamp the store never sees.
##
## Reading a dead, never-allocated, or never-written id is an error you can
## see, exactly as position's own section documents: push_error() plus
## `INF`, this codebase's existing no-value marker for a bare float (see
## e.g. combat_turret.gd's and combat_impact_resolver.gd's own `return INF`
## for "no answer"), checkable with the global `is_finite()`. `0.0` is
## rejected as the marker for the identical reason `Vector3.ZERO` was
## rejected for position: `0.0` health is a legal, meaningful value -- it is
## what "dead" looks like -- so returning it for "no value" would make "this
## entity has no recorded health" and "this entity is dead" the same answer.
## Writing to such an id is refused and logged the same way, not corrected
## into the array's stale slot.
##
## Snapshot: capture()/restore() gain a `health`/`shields` pair of fields
## each, alongside `position`, in the same JSON-safe Dictionary shape --
## see position's own section below for why that shape exists at all.
## Absent `health`/`shields`/`*_written_ids` keys restore as empty rather
## than as a failure, so a version-1 snapshot captured before this slice
## landed still restores cleanly; present-but-malformed data still fails
## closed, exactly as position's fields already do.
##
## --- Position (slice C1/C2) ---
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
## entity ids, which nothing about this game's pacing suggests. The same
## indexing argument covers health and shields: they are one more array at
## the identical per-id cost (4 bytes each versus position's 12), not a new
## decision.
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

## Health as of the most recent set_health() call for each id. No
## "previous" buffer -- see this file's doc comment on why. Grows and is
## flagged independently of _position: a building's health is written in
## Building._ready() before Match._place_on_map() gives it its first
## position write, so the two arrays legitimately reach different sizes at
## different times, and each field's own _has_value array is what makes
## that safe.
var _health: PackedFloat32Array = PackedFloat32Array()
var _health_has_value: PackedByteArray = PackedByteArray()

## Shields as of the most recent set_shields() call for each id. Same shape
## and same independence from the other fields as _health above.
var _shields: PackedFloat32Array = PackedFloat32Array()
var _shields_has_value: PackedByteArray = PackedByteArray()


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
	_ensure_position_capacity(id)
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


## Writes `value` -- already clamped by the caller, see this class's doc
## comment on why clamping does not happen here -- as `id`'s health. A
## no-op, loudly, if `id` is not currently alive, for the identical reason
## set_position() refuses a dead write instead of corrupting a stale slot.
func set_health(id: int, value: float) -> void:
	if not _registry.is_alive(id):
		push_error(
			"SimEntityState.set_health(): id %d is not alive (dead or never allocated) -- write refused" % id
		)
		return
	_ensure_health_capacity(id)
	_health[id] = value
	_health_has_value[id] = 1


## `id`'s health as of its most recent set_health() call. Errors loudly and
## returns `INF` for a dead, never-allocated, or never-written id -- `0.0`
## would be indistinguishable from a legitimately dead entity, which is
## exactly the trap this class's doc comment records for position's
## `Vector3.ZERO`. Check has_health() first if that is a normal possibility
## at the call site rather than a bug.
func health(id: int) -> float:
	if not has_health(id):
		push_error(
			"SimEntityState.health(): id %d has no health -- dead, never allocated, or never written" % id
		)
		return INF
	return _health[id]


## True once set_health(id, ...) has been called at least once for a
## currently-alive id.
func has_health(id: int) -> bool:
	return _registry.is_alive(id) and id < _health_has_value.size() and _health_has_value[id] == 1


## Writes `value` -- already clamped by the caller -- as `id`'s shields.
## Same refusal behaviour as set_health() for a dead or unallocated id.
func set_shields(id: int, value: float) -> void:
	if not _registry.is_alive(id):
		push_error(
			"SimEntityState.set_shields(): id %d is not alive (dead or never allocated) -- write refused" % id
		)
		return
	_ensure_shields_capacity(id)
	_shields[id] = value
	_shields_has_value[id] = 1


## `id`'s shields as of its most recent set_shields() call. Same `INF`
## error-marker behaviour as health() and for the identical reason.
func shields(id: int) -> float:
	if not has_shields(id):
		push_error(
			"SimEntityState.shields(): id %d has no shields -- dead, never allocated, or never written" % id
		)
		return INF
	return _shields[id]


## True once set_shields(id, ...) has been called at least once for a
## currently-alive id.
func has_shields(id: int) -> bool:
	return _registry.is_alive(id) and id < _shields_has_value.size() and _shields_has_value[id] == 1


## Array length backing the position field this store holds -- the id
## high-water mark among ids that have actually had a position written,
## plus one. Test-facing: proves restore() replaced the arrays rather than
## merging into them. Health and shields grow independently (see _health's
## own comment) and are not reflected here; nothing outside this file reads
## their capacity yet, so no health_capacity()/shields_capacity() exists --
## add one the way this method already exists, when something needs it.
func capacity() -> int:
	return _position.size()


## Captures every written id's current position, health and shields into a
## plain, JSON-safe Dictionary -- see this class's doc comment for why
## previous_position() is not included, why no previous-health/-shields
## exist to include, and why only written ids are captured for each field.
func capture() -> Dictionary:
	var written_ids: Array = []
	var position_rows: Array = []
	for id in _has_value.size():
		if _has_value[id] == 1:
			written_ids.append(id)
			position_rows.append(_encode_vector3(_position[id]))
	var health_written_ids: Array = []
	var health_rows: Array = []
	for id in _health_has_value.size():
		if _health_has_value[id] == 1:
			health_written_ids.append(id)
			health_rows.append(_health[id])
	var shields_written_ids: Array = []
	var shields_rows: Array = []
	for id in _shields_has_value.size():
		if _shields_has_value[id] == 1:
			shields_written_ids.append(id)
			shields_rows.append(_shields[id])
	return {
		"version": 1,
		"written_ids": written_ids,
		"position": position_rows,
		"health_written_ids": health_written_ids,
		"health": health_rows,
		"shields_written_ids": shields_written_ids,
		"shields": shields_rows,
	}


## Replaces this store's entire contents with `data`, previously returned by
## capture(). Fails closed -- pushes an error and leaves the current
## contents untouched -- if `data` is not a well-formed capture() result,
## the way MatchSnapshot.restore() and ReplayFile.read() both fail closed on
## header-level corruption rather than partially applying it. On success,
## every id absent from `data` is gone from this store afterward, even if
## it was written here before the call: restore() replaces, it does not
## merge. `health_written_ids`/`health`/`shields_written_ids`/`shields` are
## optional -- a version-1 snapshot captured before this slice added them
## restores with empty health/shields, not a failure; present-but-malformed
## data in those fields still fails closed. Returns whether it succeeded.
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

	var health_ids: Array
	var health_values: Array
	var health_parsed := _parse_float_field(data, "health_written_ids", "health")
	if health_parsed.is_empty():
		return false
	health_ids = health_parsed["ids"]
	health_values = health_parsed["values"]

	var shields_ids: Array
	var shields_values: Array
	var shields_parsed := _parse_float_field(data, "shields_written_ids", "shields")
	if shields_parsed.is_empty():
		return false
	shields_ids = shields_parsed["ids"]
	shields_values = shields_parsed["values"]

	var max_id := 0
	for id in ids:
		max_id = maxi(max_id, int(id))
	var new_position := PackedVector3Array()
	new_position.resize(max_id + 1)
	var new_has_value := PackedByteArray()
	new_has_value.resize(max_id + 1)
	for i in ids.size():
		var id: int = ids[i]
		new_position[id] = _decode_vector3(positions[i])
		new_has_value[id] = 1

	var max_health_id := 0
	for id in health_ids:
		max_health_id = maxi(max_health_id, int(id))
	var new_health := PackedFloat32Array()
	new_health.resize(max_health_id + 1)
	var new_health_has_value := PackedByteArray()
	new_health_has_value.resize(max_health_id + 1)
	for i in health_ids.size():
		var id: int = health_ids[i]
		new_health[id] = float(health_values[i])
		new_health_has_value[id] = 1

	var max_shields_id := 0
	for id in shields_ids:
		max_shields_id = maxi(max_shields_id, int(id))
	var new_shields := PackedFloat32Array()
	new_shields.resize(max_shields_id + 1)
	var new_shields_has_value := PackedByteArray()
	new_shields_has_value.resize(max_shields_id + 1)
	for i in shields_ids.size():
		var id: int = shields_ids[i]
		new_shields[id] = float(shields_values[i])
		new_shields_has_value[id] = 1

	_position = new_position
	_position_previous = new_position.duplicate()
	_has_value = new_has_value
	_health = new_health
	_health_has_value = new_health_has_value
	_shields = new_shields
	_shields_has_value = new_shields_has_value
	return true


func _ensure_position_capacity(id: int) -> void:
	if id < _position.size():
		return
	var new_size := id + 1
	_position.resize(new_size)
	_position_previous.resize(new_size)
	_has_value.resize(new_size)


func _ensure_health_capacity(id: int) -> void:
	if id < _health.size():
		return
	var new_size := id + 1
	_health.resize(new_size)
	_health_has_value.resize(new_size)


func _ensure_shields_capacity(id: int) -> void:
	if id < _shields.size():
		return
	var new_size := id + 1
	_shields.resize(new_size)
	_shields_has_value.resize(new_size)


## Shared parsing for restore()'s health and shields fields, which are
## identically shaped (a plain float, no per-row struct like position's
## Vector3 triple) -- unlike position, factoring this out is not building a
## generic id-and-type-agnostic store, since it serves exactly these two
## same-typed, same-shaped fields and nothing else reaches through it.
## Returns {"ids": Array, "values": Array} on success, or an empty
## Dictionary (falsy via is_empty()) on failure, having already pushed the
## relevant error. Absent keys parse as empty, not as failure -- see
## restore()'s own doc comment on backward compatibility.
func _parse_float_field(data: Dictionary, ids_key: String, values_key: String) -> Dictionary:
	var raw_ids: Variant = data.get(ids_key, [])
	var raw_values: Variant = data.get(values_key, [])
	if not raw_values is Array:
		push_error("SimEntityState.restore(): snapshot '%s' field is malformed" % values_key)
		return {}
	if not (raw_ids is Array or raw_ids is PackedInt32Array):
		push_error("SimEntityState.restore(): snapshot '%s' field is malformed" % ids_key)
		return {}
	var ids := _coerce_id_list(raw_ids)
	var values: Array = raw_values
	if ids.size() != values.size():
		push_error("SimEntityState.restore(): '%s' and '%s' have different lengths" % [ids_key, values_key])
		return {}
	for i in values.size():
		if not (values[i] is float or values[i] is int):
			push_error("SimEntityState.restore(): malformed '%s' entry at index %d" % [values_key, i])
			return {}
		if ids[i] < 1:
			push_error("SimEntityState.restore(): malformed '%s' id at index %d" % [ids_key, i])
			return {}
	return {"ids": ids, "values": values}


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
