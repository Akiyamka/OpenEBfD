extends "res://tests/support/suite.gd"

## Pins down scripts/sim/entity_state.gd, the flat hot-state store slice C1 of
## phase 3 builds and slice C3 extends with health and shields -- see
## docs/architecture/network-multiplayer.md, decision 3 ("Simulation core
## owns state; nodes are views") and the answered precision question at the
## bottom of that doc. Pure unit tests: SimEntityState extends RefCounted and
## touches no scene tree, so this suite instantiates it directly with a real
## SimEntityRegistry and nothing else running -- the same shape as
## tests/sim/entity_registry_run.gd.
##
## This suite drives the store directly rather than through a booted match; a
## wiring test that proves something actually calls set_position() / set_
## health() / set_shields() / set_owner_player_id() belongs to
## tests/match/entity_state_run.gd, the same split tests/match/entity_id_run.gd
## draws against tests/sim/entity_registry_run.gd -- and that file, not this
## one, is where slice C4's actual reason for existing (a pre-registration
## owner_player_id assignment must still reach the store) gets proven, because
## it is a _register_entity_id()/_ready() ordering question a store driven
## directly with no Unit/Building involved cannot pose. Health and shields
## have no previous-tick buffer the way position does -- see entity_state.gd's
## own doc comment for why -- so there is no previous_health()/
## previous_shields() counterpart to _test_first_write_seeds_previous /
## _test_second_write_shifts_previous below. owner_player_id has none either,
## for the identical reason.

const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const PlayerDataScript := preload("res://scripts/players/player_data.gd")


func _initialize() -> void:
	_run_case("write then read round-trips the exact value", _test_write_read_round_trip)
	_run_case("has_position() is false before the first write, true after", _test_has_position)
	_run_case(
		"reading a never-allocated id errors and returns a non-finite marker", _test_read_unallocated_id_errors
	)
	_run_case("reading a released id errors and returns a non-finite marker", _test_read_released_id_errors)
	_run_case(
		"reading a live but never-written id errors -- array growth from a later id must not fake it",
		_test_read_live_but_unwritten_id_errors
	)
	_run_case("writing to a never-allocated id is refused, not corrupted", _test_write_unallocated_id_refused)
	_run_case("writing to a released id is refused", _test_write_released_id_refused)
	_run_case(
		"the first write for an id sets previous_position() equal to the write, not to zero",
		_test_first_write_seeds_previous
	)
	_run_case(
		"the first write of each tick shifts the old current value into previous_position()",
		_test_first_write_of_a_tick_shifts_previous
	)
	_run_case(
		"a second write inside the same tick leaves previous_position() on the tick's start value",
		_test_second_write_in_one_tick_does_not_shift
	)
	_run_case("capacity() grows to cover the highest id written", _test_capacity_grows)
	_run_case("capture() then restore() round-trips every written id's position", _test_snapshot_round_trip)
	_run_case(
		"restore() replaces prior contents rather than merging into them", _test_restore_replaces_not_merges
	)
	_run_case(
		"restore() fails closed and leaves prior contents untouched on malformed data",
		_test_restore_fails_closed_on_malformed_data
	)
	_run_case("health: write then read round-trips the exact value", _test_health_write_read_round_trip)
	_run_case("health: has_health() is false before the first write, true after", _test_has_health)
	_run_case(
		"health: reading a never-allocated id errors and returns a non-finite marker",
		_test_read_unallocated_id_health_errors
	)
	_run_case(
		"health: reading a released id errors and returns a non-finite marker",
		_test_read_released_id_health_errors
	)
	_run_case(
		"health: writing to a never-allocated id is refused, not corrupted",
		_test_write_unallocated_id_health_refused
	)
	_run_case("health: writing to a released id is refused", _test_write_released_id_health_refused)
	_run_case("shields: write then read round-trips the exact value", _test_shields_write_read_round_trip)
	_run_case("shields: has_shields() is false before the first write, true after", _test_has_shields)
	_run_case(
		"shields: reading a never-allocated id errors and returns a non-finite marker",
		_test_read_unallocated_id_shields_errors
	)
	_run_case("shields: writing to a released id is refused", _test_write_released_id_shields_refused)
	_run_case(
		"health and shields grow independently of position and of each other",
		_test_health_and_shields_grow_independently
	)
	_run_case(
		"capture() then restore() round-trips every written id's health and shields alongside position",
		_test_snapshot_round_trip_health_and_shields
	)
	_run_case(
		"restore() accepts a version-1 snapshot with no health/shields keys at all, as empty",
		_test_restore_without_health_or_shields_keys_is_backward_compatible
	)
	_run_case(
		"restore() fails closed on malformed health data and leaves prior contents untouched",
		_test_restore_fails_closed_on_malformed_health_data
	)
	_run_case(
		"owner_player_id: write then read round-trips the exact value",
		_test_owner_player_id_write_read_round_trip
	)
	_run_case(
		"owner_player_id: has_owner_player_id() is false before the first write, true after",
		_test_has_owner_player_id
	)
	_run_case(
		"owner_player_id: reading a never-allocated id errors and returns the no-value marker",
		_test_read_unallocated_id_owner_player_id_errors
	)
	_run_case(
		"owner_player_id: reading a released id errors and returns the no-value marker",
		_test_read_released_id_owner_player_id_errors
	)
	_run_case(
		"owner_player_id: writing to a never-allocated id is refused, not corrupted",
		_test_write_unallocated_id_owner_player_id_refused
	)
	_run_case(
		"owner_player_id: writing to a released id is refused", _test_write_released_id_owner_player_id_refused
	)
	_run_case(
		"owner_player_id: NEUTRAL_PLAYER_ID and Player 0 both round-trip as legitimate owners, distinct from"
			+ " the no-value marker",
		_test_owner_player_id_boundary_values_round_trip
	)
	_run_case(
		"owner_player_id grows independently of position, health and shields",
		_test_owner_player_id_grows_independently
	)
	_run_case(
		"capture() then restore() round-trips every written id's owner_player_id alongside the other fields",
		_test_snapshot_round_trip_owner_player_id
	)
	_run_case(
		"restore() accepts a version-1 snapshot with no owner_player_id keys at all, as empty",
		_test_restore_without_owner_player_id_keys_is_backward_compatible
	)
	_run_case(
		"restore() fails closed on malformed owner_player_id data and leaves prior contents untouched",
		_test_restore_fails_closed_on_malformed_owner_player_id_data
	)
	_run_case("state_hash() changes for every stored observation", _test_state_hash_observed_fields)
	_run_case("state_hash() includes live ids, including unwritten ones", _test_state_hash_liveness)
	_run_case("state_hash() excludes released rows", _test_state_hash_excludes_released_rows)
	_run_case("state_hash() is stable and independent of write order", _test_state_hash_stability)
	_finish("SimEntityState tests")


func _test_write_read_round_trip() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(id, Vector3(1.5, 2.5, -3.5))
	_expect(state.position(id) == Vector3(1.5, 2.5, -3.5), "position() must return exactly what set_position() wrote")


func _test_has_position() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	_expect(not state.has_position(id), "a freshly allocated id must have no position until set_position() is called")
	state.set_position(id, Vector3.ONE)
	_expect(state.has_position(id), "has_position() must be true right after set_position()")


func _test_read_unallocated_id_errors() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	_expect(not state.has_position(999), "an id that was never allocated must report no position")
	_expect(
		not state.position(999).is_finite(),
		"position() of an unallocated id must answer with a non-finite marker, not a legal position: Vector3.ZERO is the corner of every shipped map (nav_world_bounds starts at 0), so returning it would make \"no value\" indistinguishable from \"standing at the origin\""
	)


func _test_read_released_id_errors() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(id, Vector3(4.0, 5.0, 6.0))
	registry.release(id)
	_expect(not state.has_position(id), "a released id must report no position even though it was written before release")
	_expect(not state.position(id).is_finite(), "position() of a released id must answer with a non-finite marker, not a legal position")


func _test_read_live_but_unwritten_id_errors() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var early := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var later := registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	# Writing the later id first forces the arrays to grow past `early`'s
	# index. Array-bounds-only tracking would make `early` look written
	# because resize() zero-fills every new slot, not just `later`'s -- the
	# exact bug this store's _has_value flag exists to prevent.
	state.set_position(later, Vector3(7.0, 8.0, 9.0))
	_expect(
		not state.has_position(early),
		"an id whose array slot merely exists because a later id grew the array must still report no position"
	)
	_expect(not state.position(early).is_finite(), "position() of that unwritten gap id must answer with a non-finite marker, not a legal position")
	_expect(state.position(later) == Vector3(7.0, 8.0, 9.0), "the id that was actually written must read back correctly")


func _test_write_unallocated_id_refused() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	state.set_position(42, Vector3.ONE)
	_expect(not state.has_position(42), "a write to a never-allocated id must be refused, not silently accepted")


func _test_write_released_id_refused() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(id, Vector3(1.0, 1.0, 1.0))
	registry.release(id)
	state.set_position(id, Vector3(2.0, 2.0, 2.0))
	_expect(not state.has_position(id), "a write to a released id must be refused -- the stale pre-release value must not be reachable through has_position()")


func _test_first_write_seeds_previous() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(id, Vector3(10.0, 0.0, 0.0))
	_expect(
		state.previous_position(id) == Vector3(10.0, 0.0, 0.0),
		"the first write for an id must seed previous_position() with the same value, not Vector3.ZERO -- otherwise an interpolating reader blends from a spawn point the entity was never at"
	)


## Slice B4 corrected what "previous" is measured from -- see this store's own
## doc comment. It used to be "the write before the most recent one", which is
## only the previous tick for an entity written exactly once per tick, and no
## managed ground unit is. It is now the tick boundary begin_tick() marks, so
## these cases drive begin_tick() explicitly where they used to rely on the
## write count alone.
func _test_first_write_of_a_tick_shifts_previous() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.begin_tick()
	state.set_position(id, Vector3(1.0, 0.0, 0.0))
	state.begin_tick()
	state.set_position(id, Vector3(2.0, 0.0, 0.0))
	_expect(state.position(id) == Vector3(2.0, 0.0, 0.0), "position() must be the most recent write")
	_expect(
		state.previous_position(id) == Vector3(1.0, 0.0, 0.0),
		"previous_position() must be the value this id had when the current tick started"
	)
	state.begin_tick()
	state.set_position(id, Vector3(3.0, 0.0, 0.0))
	_expect(
		state.previous_position(id) == Vector3(2.0, 0.0, 0.0),
		"a third tick must shift previous_position() again, not accumulate history beyond one tick back"
	)


## The case the correction exists for. Two writes inside one tick is not a
## hypothetical shape: Unit.navigation_step() writes the horizontal step and
## then UnitTerrainAlignment.snap_body_to_terrain() writes the vertical
## correction, both from the same call stack, on every tick, for every managed
## ground unit. Under the old shift-per-write rule previous_position() came
## back holding the horizontal step -- a mid-tick intermediate -- so a view
## blending between the two got only the terrain snap.
func _test_second_write_in_one_tick_does_not_shift() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.begin_tick()
	state.set_position(id, Vector3(1.0, 0.0, 0.0))
	state.begin_tick()
	# The horizontal step, then the vertical correction, exactly as one tick of
	# managed locomotion writes them.
	state.set_position(id, Vector3(2.0, 0.0, 0.0))
	state.set_position(id, Vector3(2.0, 0.5, 0.0))
	_expect(
		state.position(id) == Vector3(2.0, 0.5, 0.0),
		"position() must be the last write of the tick, corrections included"
	)
	_expect(
		state.previous_position(id) == Vector3(1.0, 0.0, 0.0),
		"previous_position() must still be where the tick started, not the intermediate value the "
			+ "first write of this same tick left behind"
	)
	# A third write in the same tick must not shift it either.
	state.set_position(id, Vector3(2.0, 0.5, 0.25))
	_expect(
		state.previous_position(id) == Vector3(1.0, 0.0, 0.0),
		"a third write inside the same tick must leave previous_position() alone as well"
	)


func _test_capacity_grows() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	_expect(state.capacity() == 0, "a fresh store must have zero capacity")
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var b := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(a, Vector3.ZERO)
	_expect(state.capacity() == a + 1, "capacity() must grow to cover the highest id ever written")
	state.set_position(b, Vector3.ZERO)
	_expect(state.capacity() == b + 1, "capacity() must grow again for a higher id")


func _test_snapshot_round_trip() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var b := registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	state.set_position(a, Vector3(1.0, 2.0, 3.0))
	state.set_position(b, Vector3(-4.0, 5.0, -6.0))
	var snapshot := state.capture()

	var restored := SimEntityStateScript.new(registry)
	var ok := restored.restore(snapshot)
	_expect(ok, "restore() of a snapshot capture() just produced must succeed")
	_expect(restored.position(a) == Vector3(1.0, 2.0, 3.0), "restore() must reproduce the first entity's position exactly")
	_expect(restored.position(b) == Vector3(-4.0, 5.0, -6.0), "restore() must reproduce the second entity's position exactly")
	_expect(
		restored.previous_position(a) == restored.position(a),
		"previous_position() must equal position() right after a restore -- there is no meaningful pre-snapshot tick to report, and carrying stale data forward would fake one frame of motion"
	)


func _test_restore_replaces_not_merges() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(a, Vector3(1.0, 1.0, 1.0))
	var snapshot := state.capture()

	# Mutate the existing id and add a new one after the snapshot was taken.
	state.set_position(a, Vector3(9.0, 9.0, 9.0))
	var b := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(b, Vector3(2.0, 2.0, 2.0))
	_expect(state.capacity() == b + 1, "sanity check: the store grew to include b before restore()")

	var ok := state.restore(snapshot)
	_expect(ok, "restore() of the earlier snapshot must succeed")
	_expect(
		state.position(a) == Vector3(1.0, 1.0, 1.0),
		"restore() must roll a's position back to the snapshot's value, discarding the later write"
	)
	_expect(
		not state.has_position(b),
		"restore() must remove b entirely -- it did not exist in the snapshot, so a merge would wrongly keep it alive"
	)


func _test_restore_fails_closed_on_malformed_data() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(a, Vector3(3.0, 3.0, 3.0))

	_expect(
		not state.restore({"version": 2, "written_ids": [], "position": []}),
		"restore() must reject an unrecognized version"
	)
	_expect(
		not state.restore({"version": 1, "written_ids": [a], "position": []}),
		"restore() must reject mismatched written_ids/position lengths"
	)
	_expect(
		not state.restore({"version": 1, "written_ids": [a], "position": [[1.0, 2.0]]}),
		"restore() must reject a malformed position row"
	)
	_expect(
		state.position(a) == Vector3(3.0, 3.0, 3.0),
		"a failed restore() must leave the store's prior contents completely untouched"
	)


func _test_health_write_read_round_trip() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_health(id, 42.5)
	_expect(state.health(id) == 42.5, "health() must return exactly what set_health() wrote")


func _test_has_health() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	_expect(not state.has_health(id), "a freshly allocated id must have no health until set_health() is called")
	state.set_health(id, 10.0)
	_expect(state.has_health(id), "has_health() must be true right after set_health()")


func _test_read_unallocated_id_health_errors() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	_expect(not state.has_health(999), "an id that was never allocated must report no health")
	_expect(
		not is_finite(state.health(999)),
		"health() of an unallocated id must answer with a non-finite marker, not a legal health value: 0.0 is what a dead entity's health legitimately holds, so returning it for \"no value\" would make the two indistinguishable"
	)


func _test_read_released_id_health_errors() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_health(id, 55.0)
	registry.release(id)
	_expect(not state.has_health(id), "a released id must report no health even though it was written before release")
	_expect(not is_finite(state.health(id)), "health() of a released id must answer with a non-finite marker, not a legal health value")


func _test_write_unallocated_id_health_refused() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	state.set_health(42, 100.0)
	_expect(not state.has_health(42), "a write to a never-allocated id must be refused, not silently accepted")


func _test_write_released_id_health_refused() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_health(id, 10.0)
	registry.release(id)
	state.set_health(id, 20.0)
	_expect(not state.has_health(id), "a write to a released id must be refused -- the stale pre-release value must not be reachable through has_health()")


func _test_shields_write_read_round_trip() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_shields(id, 12.0)
	_expect(state.shields(id) == 12.0, "shields() must return exactly what set_shields() wrote")


func _test_has_shields() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	_expect(not state.has_shields(id), "a freshly allocated id must have no shields until set_shields() is called")
	state.set_shields(id, 5.0)
	_expect(state.has_shields(id), "has_shields() must be true right after set_shields()")


func _test_read_unallocated_id_shields_errors() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	_expect(not state.has_shields(999), "an id that was never allocated must report no shields")
	_expect(
		not is_finite(state.shields(999)),
		"shields() of an unallocated id must answer with a non-finite marker, not a legal shields value: 0.0 is what depleted shields legitimately hold"
	)


func _test_write_released_id_shields_refused() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_shields(id, 10.0)
	registry.release(id)
	state.set_shields(id, 20.0)
	_expect(not state.has_shields(id), "a write to a released id must be refused, exactly as set_health() and set_position() refuse one")


## Building kind is used here deliberately, not because kind matters to the
## store (it does not -- see entity_state.gd's own doc comment on why one
## shared array covers both), but to make that claim concrete: a BUILDING id
## writes health/shields through the identical arrays a UNIT id does.
func _test_health_and_shields_grow_independently() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var b := registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	# Write b's health only, and a's position only -- if capacity were
	# shared across fields the way _test_capacity_grows checks it is not,
	# growing one field for the higher id would silently make the lower id
	# look written in the other field.
	state.set_health(b, 200.0)
	state.set_position(a, Vector3.ONE)
	_expect(not state.has_health(a), "a must have no health: only b's health was ever written")
	_expect(not state.has_position(b), "b must have no position: only a's position was ever written")
	_expect(state.health(b) == 200.0, "b's health must read back correctly regardless of a's unrelated position write")
	_expect(not state.has_shields(a) and not state.has_shields(b), "neither id has had shields written at all")


func _test_snapshot_round_trip_health_and_shields() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var b := registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	state.set_position(a, Vector3(1.0, 2.0, 3.0))
	state.set_health(a, 80.0)
	state.set_shields(a, 15.0)
	state.set_health(b, 500.0)
	state.set_shields(b, 0.0)
	var snapshot := state.capture()

	var restored := SimEntityStateScript.new(registry)
	var ok := restored.restore(snapshot)
	_expect(ok, "restore() of a snapshot capture() just produced must succeed")
	_expect(restored.health(a) == 80.0, "restore() must reproduce a's health exactly")
	_expect(restored.shields(a) == 15.0, "restore() must reproduce a's shields exactly")
	_expect(restored.health(b) == 500.0, "restore() must reproduce b's health exactly")
	_expect(restored.shields(b) == 0.0, "restore() must reproduce b's shields exactly, including a legitimately-zero value")
	_expect(restored.has_shields(b), "b's shields must be recorded as written, not confused with \"never written\" merely because the value is 0.0")


func _test_restore_without_health_or_shields_keys_is_backward_compatible() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var ok := state.restore({"version": 1, "written_ids": [], "position": []})
	_expect(ok, "restore() must accept a version-1 snapshot with no health/shields keys at all, as an older capture would produce")
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	_expect(not state.has_health(id), "a store restored from a snapshot with no health data must report no health for any id")
	_expect(not state.has_shields(id), "a store restored from a snapshot with no shields data must report no shields for any id")


func _test_restore_fails_closed_on_malformed_health_data() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_health(a, 33.0)

	_expect(
		not state.restore(
			{
				"version": 1,
				"written_ids": [],
				"position": [],
				"health_written_ids": [a],
				"health": [],
			}
		),
		"restore() must reject mismatched health_written_ids/health lengths"
	)
	_expect(
		not state.restore(
			{
				"version": 1,
				"written_ids": [],
				"position": [],
				"health_written_ids": [a],
				"health": ["not a number"],
			}
		),
		"restore() must reject a malformed health entry"
	)
	_expect(
		state.health(a) == 33.0,
		"a failed restore() must leave the store's prior health contents completely untouched"
	)


func _test_owner_player_id_write_read_round_trip() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_owner_player_id(id, 2)
	_expect(
		state.owner_player_id(id) == 2, "owner_player_id() must return exactly what set_owner_player_id() wrote"
	)


func _test_has_owner_player_id() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	_expect(
		not state.has_owner_player_id(id),
		"a freshly allocated id must have no owner_player_id until set_owner_player_id() is called"
	)
	state.set_owner_player_id(id, 1)
	_expect(state.has_owner_player_id(id), "has_owner_player_id() must be true right after set_owner_player_id()")


func _test_read_unallocated_id_owner_player_id_errors() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	_expect(not state.has_owner_player_id(999), "an id that was never allocated must report no owner_player_id")
	_expect(
		state.owner_player_id(999) == SimEntityStateScript.NO_OWNER_PLAYER_ID,
		(
			"owner_player_id() of an unallocated id must answer with the no-value marker, not a legal player"
			+ " id: 0 is Player 0 and -1 is PlayerDataScript.NEUTRAL_PLAYER_ID, both legal owners, so neither"
			+ " can also mean \"no value\""
		)
	)


func _test_read_released_id_owner_player_id_errors() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_owner_player_id(id, 3)
	registry.release(id)
	_expect(
		not state.has_owner_player_id(id),
		"a released id must report no owner_player_id even though it was written before release"
	)
	_expect(
		state.owner_player_id(id) == SimEntityStateScript.NO_OWNER_PLAYER_ID,
		"owner_player_id() of a released id must answer with the no-value marker, not a legal player id"
	)


func _test_write_unallocated_id_owner_player_id_refused() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	state.set_owner_player_id(42, 1)
	_expect(
		not state.has_owner_player_id(42), "a write to a never-allocated id must be refused, not silently accepted"
	)


func _test_write_released_id_owner_player_id_refused() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_owner_player_id(id, 1)
	registry.release(id)
	state.set_owner_player_id(id, 2)
	_expect(
		not state.has_owner_player_id(id),
		(
			"a write to a released id must be refused -- the stale pre-release value must not be reachable"
			+ " through has_owner_player_id()"
		)
	)


## Binds the no-value marker directly: NEUTRAL_PLAYER_ID (-1) and Player 0
## are the two values entity_state.gd's "Owner player id" section explains
## NO_OWNER_PLAYER_ID must never be mistaken for. If NO_OWNER_PLAYER_ID were
## ever changed to 0 or -1, this test starts failing the moment it does.
func _test_owner_player_id_boundary_values_round_trip() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var neutral_id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var player_zero_id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_owner_player_id(neutral_id, PlayerDataScript.NEUTRAL_PLAYER_ID)
	state.set_owner_player_id(player_zero_id, 0)
	_expect(
		state.has_owner_player_id(neutral_id)
			and state.owner_player_id(neutral_id) == PlayerDataScript.NEUTRAL_PLAYER_ID,
		"NEUTRAL_PLAYER_ID (-1) must round-trip as a legitimate, recorded owner -- it is a legal value, not"
			+ " \"no value\""
	)
	_expect(
		state.has_owner_player_id(player_zero_id) and state.owner_player_id(player_zero_id) == 0,
		"Player 0 must round-trip as a legitimate, recorded owner -- 0 is a legal player id, not \"no value\""
	)
	_expect(
		PlayerDataScript.NEUTRAL_PLAYER_ID != SimEntityStateScript.NO_OWNER_PLAYER_ID and 0 != SimEntityStateScript.NO_OWNER_PLAYER_ID,
		"sanity check: the no-value marker must not collide with either legal boundary value"
	)


## Building kind is used here deliberately, for the identical reason
## _test_health_and_shields_grow_independently uses it.
func _test_owner_player_id_grows_independently() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var b := registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	state.set_owner_player_id(b, 3)
	state.set_health(a, 10.0)
	_expect(not state.has_owner_player_id(a), "a must have no owner_player_id: only b's was ever written")
	_expect(not state.has_health(b), "b must have no health: only a's health was ever written")
	_expect(
		state.owner_player_id(b) == 3,
		"b's owner_player_id must read back correctly regardless of a's unrelated health write"
	)


func _test_snapshot_round_trip_owner_player_id() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var b := registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	state.set_position(a, Vector3(1.0, 2.0, 3.0))
	state.set_owner_player_id(a, 1)
	state.set_owner_player_id(b, PlayerDataScript.NEUTRAL_PLAYER_ID)
	var snapshot := state.capture()

	var restored := SimEntityStateScript.new(registry)
	var ok := restored.restore(snapshot)
	_expect(ok, "restore() of a snapshot capture() just produced must succeed")
	_expect(restored.owner_player_id(a) == 1, "restore() must reproduce a's owner_player_id exactly")
	_expect(
		restored.owner_player_id(b) == PlayerDataScript.NEUTRAL_PLAYER_ID,
		"restore() must reproduce b's owner_player_id exactly, including a legitimately-neutral value"
	)
	_expect(
		restored.has_owner_player_id(b),
		(
			"b's owner_player_id must be recorded as written, not confused with \"never written\" merely"
			+ " because the value is NEUTRAL_PLAYER_ID"
		)
	)


func _test_restore_without_owner_player_id_keys_is_backward_compatible() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var ok := state.restore({"version": 1, "written_ids": [], "position": []})
	_expect(
		ok,
		"restore() must accept a version-1 snapshot with no owner_player_id keys at all, as a pre-C4 capture"
			+ " would produce"
	)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	_expect(
		not state.has_owner_player_id(id),
		"a store restored from a snapshot with no owner_player_id data must report no owner_player_id for any id"
	)


func _test_restore_fails_closed_on_malformed_owner_player_id_data() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_owner_player_id(a, 2)

	_expect(
		not state.restore(
			{
				"version": 1,
				"written_ids": [],
				"position": [],
				"owner_player_id_written_ids": [a],
				"owner_player_id": [],
			}
		),
		"restore() must reject mismatched owner_player_id_written_ids/owner_player_id lengths"
	)
	_expect(
		not state.restore(
			{
				"version": 1,
				"written_ids": [],
				"position": [],
				"owner_player_id_written_ids": [a],
				"owner_player_id": ["not a number"],
			}
		),
		"restore() must reject a malformed owner_player_id entry"
	)
	_expect(
		state.owner_player_id(a) == 2,
		"a failed restore() must leave the store's prior owner_player_id contents completely untouched"
	)


func _test_state_hash_observed_fields() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(id, Vector3(1.0, 2.0, 3.0))
	state.set_health(id, 10.0)
	state.set_shields(id, 20.0)
	state.set_owner_player_id(id, 1)
	var before := state.state_hash()
	state.set_position(id, Vector3(4.0, 2.0, 3.0))
	_expect(state.state_hash() != before, "a position mutation must change state_hash()")
	before = state.state_hash()
	state.set_health(id, 11.0)
	_expect(state.state_hash() != before, "a health mutation must change state_hash()")
	before = state.state_hash()
	state.set_shields(id, 21.0)
	_expect(state.state_hash() != before, "a shields mutation must change state_hash()")
	before = state.state_hash()
	state.set_owner_player_id(id, 2)
	_expect(state.state_hash() != before, "an owner_player_id mutation must change state_hash()")


func _test_state_hash_liveness() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var before := state.state_hash()
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	_expect(
		state.state_hash() != before,
		"allocating a live id with no writes must change state_hash(): entity existence is observable state"
	)
	before = state.state_hash()
	registry.release(id)
	_expect(state.state_hash() != before, "releasing a live id must change state_hash()")


func _test_state_hash_excludes_released_rows() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var before := state.state_hash()
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(id, Vector3(8.0, 9.0, 10.0))
	state.set_health(id, 12.0)
	state.set_shields(id, 13.0)
	state.set_owner_player_id(id, 3)
	registry.release(id)
	_expect(
		state.state_hash() == before,
		"a written row released before hashing must be excluded: capture() presence bytes are not the hash traversal"
	)


func _test_state_hash_stability() -> void:
	var first_registry := SimEntityRegistryScript.new()
	var first := SimEntityStateScript.new(first_registry)
	var first_a := first_registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var first_b := first_registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	first.set_position(first_a, Vector3(1.0, 2.0, 3.0))
	first.set_health(first_b, 50.0)
	first.set_shields(first_a, 4.0)
	first.set_owner_player_id(first_b, 2)
	var first_hash := first.state_hash()
	_expect(first.state_hash() == first_hash, "hashing the same store twice must be stable")

	var second_registry := SimEntityRegistryScript.new()
	var second := SimEntityStateScript.new(second_registry)
	var second_a := second_registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var second_b := second_registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	second.set_owner_player_id(second_b, 2)
	second.set_shields(second_a, 4.0)
	second.set_health(second_b, 50.0)
	second.set_position(second_a, Vector3(1.0, 2.0, 3.0))
	_expect(
		second.state_hash() == first_hash,
		"equivalent stores written in a different order must have the same hash"
	)
