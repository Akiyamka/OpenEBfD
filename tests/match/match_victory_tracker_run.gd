extends "res://tests/support/suite.gd"

const MatchVictoryTrackerScript := preload("res://scripts/match/match_victory_tracker.gd")
const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const PlayerEliminationTrackerScript := preload("res://scripts/match/player_elimination_tracker.gd")
const PlayerRosterScript := preload("res://scripts/players/player_roster.gd")
const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")


class FakeEntity extends Node:
	var entity_id := 0
	var owner_player_id := -1
	var config_id: StringName


func _initialize() -> void:
	await _run_async_case("two surviving enemies leave the match undecided", _test_two_enemies_are_not_decided)
	await _run_async_case("one surviving enemy decides the match", _test_one_surviving_enemy_decides_match)
	await _run_async_case("one surviving team decides the match", _test_one_surviving_team_decides_match)
	await _run_async_case("one survivor from each team leaves the match undecided", _test_one_survivor_per_team_is_not_decided)
	await _run_async_case("mutual elimination is a decided draw", _test_mutual_elimination_is_decided)
	await _run_async_case("an explicit enemy override breaks an otherwise allied side", _test_non_transitive_alliance_is_not_decided)
	await _run_async_case("remaining player ids are a defensive copy", _test_remaining_player_ids_are_a_defensive_copy)
	_finish("Match victory tracker tests")


func _test_two_enemies_are_not_decided() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster([1, 2])
	_add_counting_entity(fixture, registry, 1)
	_add_counting_entity(fixture, registry, 2)
	var tracker: MatchVictoryTracker = await _refresh_tracker(roster, registry)
	_expect(not tracker.is_match_decided(), "two surviving enemy players must leave the match undecided")
	_expect(tracker.remaining_player_ids() == [1, 2], "both surviving enemy ids must remain visible")
	fixture.free()


func _test_one_surviving_enemy_decides_match() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster([1, 2])
	_add_counting_entity(fixture, registry, 2)
	var tracker: MatchVictoryTracker = await _refresh_tracker(roster, registry)
	_expect(tracker.is_match_decided(), "one surviving player must decide the match")
	_expect(tracker.remaining_player_ids() == [2], "only the surviving player id must remain")
	fixture.free()


func _test_one_surviving_team_decides_match() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster([1, 1, 2, 2])
	_add_counting_entity(fixture, registry, 3)
	_add_counting_entity(fixture, registry, 4)
	var tracker: MatchVictoryTracker = await _refresh_tracker(roster, registry)
	_expect(tracker.is_match_decided(), "two surviving teammates must decide the match")
	_expect(tracker.remaining_player_ids() == [3, 4], "both members of the surviving team must remain")
	fixture.free()


func _test_one_survivor_per_team_is_not_decided() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster([1, 1, 2, 2])
	_add_counting_entity(fixture, registry, 2)
	_add_counting_entity(fixture, registry, 4)
	var tracker: MatchVictoryTracker = await _refresh_tracker(roster, registry)
	_expect(not tracker.is_match_decided(), "survivors from opposing teams must leave the match undecided")
	_expect(tracker.remaining_player_ids() == [2, 4], "one survivor from each team must remain visible")
	fixture.free()


func _test_mutual_elimination_is_decided() -> void:
	var registry := SimEntityRegistryScript.new()
	var tracker: MatchVictoryTracker = await _refresh_tracker(_new_roster([1, 2]), registry)
	_expect(tracker.is_match_decided(), "mutual elimination must be a decided draw")
	_expect(tracker.remaining_player_ids().is_empty(), "a decided draw must have no remaining players")


func _test_non_transitive_alliance_is_not_decided() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster([1, 1, 1])
	roster.set_relation(2, 3, PlayerDataScript.Relation.ENEMY)
	_add_counting_entity(fixture, registry, 1)
	_add_counting_entity(fixture, registry, 2)
	_add_counting_entity(fixture, registry, 3)
	var tracker: MatchVictoryTracker = await _refresh_tracker(roster, registry)
	_expect(
		not tracker.is_match_decided(),
		"an explicit enemy relation between two survivors must make the match undecided"
	)
	fixture.free()


func _test_remaining_player_ids_are_a_defensive_copy() -> void:
	var fixture := Node.new()
	root.add_child(fixture)
	var registry := SimEntityRegistryScript.new()
	var roster := _new_roster([1, 2])
	_add_counting_entity(fixture, registry, 1)
	_add_counting_entity(fixture, registry, 2)
	var tracker: MatchVictoryTracker = await _refresh_tracker(roster, registry)
	var returned_ids := tracker.remaining_player_ids()
	returned_ids.clear()
	_expect(
		tracker.remaining_player_ids() == [1, 2],
		"mutating a returned array must not change the cached remaining ids without refresh"
	)
	fixture.free()


func _new_roster(team_ids: Array[int]) -> PlayerRoster:
	var roster := PlayerRosterScript.new()
	for index in team_ids.size():
		var player_id := index + 1
		roster.create_player(player_id, "Player %d" % player_id, Color.WHITE, &"", [], team_ids[index])
	return roster


func _refresh_tracker(roster: PlayerRoster, registry: SimEntityRegistry) -> MatchVictoryTracker:
	await process_frame
	var elimination := PlayerEliminationTrackerScript.new()
	elimination.refresh(self, roster, registry)
	var tracker := MatchVictoryTrackerScript.new()
	tracker.refresh(roster, elimination)
	return tracker


func _add_counting_entity(fixture: Node, registry: SimEntityRegistry, player_id: int) -> FakeEntity:
	var entity := FakeEntity.new()
	entity.entity_id = registry.allocate(SimEntityRegistryScript.Kind.BUILDING)
	entity.owner_player_id = player_id
	entity.config_id = &"ATConYard"
	entity.add_to_group("sim_buildings")
	fixture.add_child(entity)
	return entity
