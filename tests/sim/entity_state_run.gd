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
## health() / set_shields() belongs to tests/match/entity_state_run.gd, the
## same split tests/match/entity_id_run.gd draws against
## tests/sim/entity_registry_run.gd. Health and shields have no
## previous-tick buffer the way position does -- see entity_state.gd's own
## doc comment for why -- so there is no previous_health()/previous_shields()
## counterpart to _test_first_write_seeds_previous /
## _test_second_write_shifts_previous below.

const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")


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
		"a second write shifts the old current value into previous_position()",
		_test_second_write_shifts_previous
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


func _test_second_write_shifts_previous() -> void:
	var registry := SimEntityRegistryScript.new()
	var state := SimEntityStateScript.new(registry)
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	state.set_position(id, Vector3(1.0, 0.0, 0.0))
	state.set_position(id, Vector3(2.0, 0.0, 0.0))
	_expect(state.position(id) == Vector3(2.0, 0.0, 0.0), "position() must be the most recent write")
	_expect(
		state.previous_position(id) == Vector3(1.0, 0.0, 0.0),
		"previous_position() must be the write before the most recent one"
	)
	state.set_position(id, Vector3(3.0, 0.0, 0.0))
	_expect(
		state.previous_position(id) == Vector3(2.0, 0.0, 0.0),
		"a third write must shift previous_position() again, not accumulate history beyond one tick back"
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
