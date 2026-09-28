class_name PlayerEliminationTracker
extends RefCounted

const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")

var _eliminated_by_player_id: Dictionary = {}


func refresh(tree: SceneTree, players: PlayerRoster, registry: SimEntityRegistry) -> void:
	if tree == null or players == null or registry == null:
		return
	for player_id in players.player_ids(false):
		_eliminated_by_player_id[player_id] = not _has_counting_entity(tree, player_id, registry)


func is_player_eliminated(player_id: int) -> bool:
	return bool(_eliminated_by_player_id.get(player_id, false))


func _has_counting_entity(tree: SceneTree, player_id: int, registry: SimEntityRegistry) -> bool:
	for building in tree.get_nodes_in_group("sim_buildings"):
		if _counts_toward_elimination(building, player_id, registry, true):
			return true
	for unit in tree.get_nodes_in_group("sim_units"):
		if _counts_toward_elimination(unit, player_id, registry, false):
			return true
	return false


func _counts_toward_elimination(node, player_id: int, registry: SimEntityRegistry, is_building: bool) -> bool:
	if not is_instance_valid(node) or not registry.is_alive(node.entity_id) \
		or not EntityQueryScript.is_owned_by(node, player_id):
		return false
	var definition := BuildingDefinitionCatalogScript.shared().definition(node.config_id) \
		if is_building else UnitSceneCatalogScript.shared().definition_for(node.config_id)
	return definition != null and not definition.exclude_from_skirmish_lose
