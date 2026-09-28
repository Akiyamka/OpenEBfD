extends "res://tests/support/suite.gd"

const PlayerEliminationTrackerScript := preload("res://scripts/match/player_elimination_tracker.gd")
const PlayerRosterScript := preload("res://scripts/players/player_roster.gd")
const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")


class FakeEntity extends Node:
	var entity_id := 0
	var owner_player_id := -1
	var config_id: StringName


func _initialize() -> void:
	await _run_async_case("an excluded-only player is eliminated", _test_excluded_only_player_is_eliminated)
	await _run_async_case("a counting entity prevents elimination alongside excluded entities", _test_counting_entity_prevents_elimination)
	await _run_async_case("a registry-released entity stops counting before it is freed", _test_released_entity_is_eliminated)
	_run_case("an unseen player defaults to not eliminated", _test_unseen_player_defaults_to_not_eliminated)
	_run_case("a player with no entities is eliminated", _test_player_with_no_entities_is_eliminated)
	_finish("Player elimination tracker tests")


func _test_excluded_only_player_is_eliminated() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster()
	_add_entity(fixture, registry, SimEntityRegistryScript.Kind.BUILDING, 1, &"ATSmWindtrap", "sim_buildings")
	await process_frame
	var tracker := PlayerEliminationTrackerScript.new()
	tracker.refresh(self, roster, registry)
	_expect(tracker.is_player_eliminated(1), "an excluded-only windtrap must not keep player 1 alive")
	fixture.free()


func _test_counting_entity_prevents_elimination() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster()
	_add_entity(fixture, registry, SimEntityRegistryScript.Kind.BUILDING, 1, &"ATSmWindtrap", "sim_buildings")
	_add_entity(fixture, registry, SimEntityRegistryScript.Kind.BUILDING, 1, &"ATConYard", "sim_buildings")
	_add_entity(fixture, registry, SimEntityRegistryScript.Kind.UNIT, 1, &"ATInfantry", "sim_units")
	await process_frame
	var tracker := PlayerEliminationTrackerScript.new()
	tracker.refresh(self, roster, registry)
	_expect(
		not tracker.is_player_eliminated(1),
		"a Construction Yard or infantry must keep player 1 alive alongside an excluded windtrap"
	)
	fixture.free()


func _test_released_entity_is_eliminated() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster()
	var con_yard := _add_entity(
		fixture, registry, SimEntityRegistryScript.Kind.BUILDING, 1, &"ATConYard", "sim_buildings"
	)
	await process_frame
	var tracker := PlayerEliminationTrackerScript.new()
	tracker.refresh(self, roster, registry)
	_expect(not tracker.is_player_eliminated(1), "the live Construction Yard must keep player 1 alive before release")
	registry.request_release(con_yard.entity_id)
	_expect(is_instance_valid(con_yard), "the released entity must remain instance-valid for this regression case")
	_expect(con_yard.is_in_group("sim_buildings"), "the released entity must remain in its simulation group")
	tracker.refresh(self, roster, registry)
	_expect(tracker.is_player_eliminated(1), "a registry-released Construction Yard must stop counting before it is freed")
	fixture.free()


func _test_unseen_player_defaults_to_not_eliminated() -> void:
	var registry := SimEntityRegistryScript.new()
	var tracker := PlayerEliminationTrackerScript.new()
	tracker.refresh(self, _new_roster(), registry)
	_expect(not tracker.is_player_eliminated(99), "a player refresh has never seen must default to not eliminated")


func _test_player_with_no_entities_is_eliminated() -> void:
	var registry := SimEntityRegistryScript.new()
	var tracker := PlayerEliminationTrackerScript.new()
	tracker.refresh(self, _new_roster(), registry)
	_expect(tracker.is_player_eliminated(1), "a player with no surviving entities must be eliminated")


func _new_roster() -> PlayerRoster:
	var roster := PlayerRosterScript.new()
	roster.create_player(1, "Atreides", Color.BLUE)
	roster.create_player(2, "Ordos", Color.GREEN)
	return roster


func _add_entity(
		fixture: Node, registry: SimEntityRegistry, kind: int, player_id: int,
		config_id: StringName, group: StringName
		) -> FakeEntity:
	var entity := FakeEntity.new()
	entity.entity_id = registry.allocate(kind)
	entity.owner_player_id = player_id
	entity.config_id = config_id
	entity.add_to_group(group)
	fixture.add_child(entity)
	return entity
