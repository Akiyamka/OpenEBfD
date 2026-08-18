extends "res://tests/support/suite.gd"

## Pins down scripts/sim/entity_registry.gd, the id allocator stable entity
## ids are built on -- see docs/architecture/network-multiplayer.md, phase 2.
## Pure unit tests: SimEntityRegistry extends RefCounted and touches no scene
## tree, so this suite instantiates it directly with nothing else running.

const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")


func _initialize() -> void:
	_run_case("ids start at 1 and increase by one per allocation", _test_ids_start_at_one_and_increase)
	_run_case("a released id is never handed out again", _test_released_id_never_reissued)
	_run_case("kind_of() still answers correctly for a released id", _test_kind_of_survives_release)
	_run_case("kind_of() returns 0 for an id that was never allocated", _test_kind_of_unknown_id)
	_run_case("live_ids() is ascending and excludes released ids", _test_live_ids_ascending_excludes_released)
	_run_case("release() of an unknown id is a no-op", _test_release_unknown_id_is_noop)
	_run_case("release() of an already-released id is a no-op", _test_release_twice_is_noop)
	_run_case("live_count() and allocated_count() diverge once something is released", _test_counts)
	_finish("SimEntityRegistry tests")


func _test_ids_start_at_one_and_increase() -> void:
	var registry := SimEntityRegistryScript.new()
	_expect(registry.allocate(SimEntityRegistryScript.Kind.UNIT) == 1, "the first allocate() must return 1")
	_expect(registry.allocate(SimEntityRegistryScript.Kind.UNIT) == 2, "the second allocate() must return 2")
	_expect(registry.allocate(SimEntityRegistryScript.Kind.BUILDING) == 3, "allocation is sequential across kinds")


func _test_released_id_never_reissued() -> void:
	var registry := SimEntityRegistryScript.new()
	var first := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	registry.release(first)
	_expect(not registry.is_alive(first), "a released id must report dead")
	for _i in 10:
		var reallocated := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
		_expect(reallocated != first, "a released id must never be handed out again, even after many more allocations")


func _test_kind_of_survives_release() -> void:
	var registry := SimEntityRegistryScript.new()
	var building_id := registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	registry.release(building_id)
	_expect(
		registry.kind_of(building_id) == SimEntityRegistryScript.Kind.BUILDING,
		"kind_of() must still answer for a released id -- kind is a fact about the id's history, not its liveness"
	)


func _test_kind_of_unknown_id() -> void:
	var registry := SimEntityRegistryScript.new()
	_expect(registry.kind_of(999) == 0, "kind_of() of an id that was never allocated must return 0")


func _test_live_ids_ascending_excludes_released() -> void:
	var registry := SimEntityRegistryScript.new()
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	var b := registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	var c := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	registry.release(b)
	var live := registry.live_ids()
	_expect(live == PackedInt32Array([a, c]), "live_ids() must be ascending and exclude the released id")


func _test_release_unknown_id_is_noop() -> void:
	var registry := SimEntityRegistryScript.new()
	registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	registry.release(12345)
	_expect(registry.live_count() == 1, "releasing an id that was never allocated must not disturb the live set")
	_expect(registry.allocated_count() == 1, "releasing an unknown id must not change the high-water mark")


func _test_release_twice_is_noop() -> void:
	var registry := SimEntityRegistryScript.new()
	var id := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	registry.release(id)
	registry.release(id)
	_expect(not registry.is_alive(id), "a double release must leave the id dead, not raise or resurrect it")
	_expect(registry.live_count() == 0, "a double release must not double-count anything in live_count()")


func _test_counts() -> void:
	var registry := SimEntityRegistryScript.new()
	var a := registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	registry.allocate(SimEntityRegistryScript.Kind.UNIT)
	registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	registry.release(a)
	_expect(registry.live_count() == 2, "live_count() must exclude released ids")
	_expect(
		registry.allocated_count() == 3,
		"allocated_count() is the id high-water mark and must include released ids"
	)
