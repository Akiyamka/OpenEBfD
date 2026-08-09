extends RefCounted

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatDefinitionCatalogScript := preload("res://scripts/combat/combat_definition_catalog.gd")

var _catalog := CombatDefinitionCatalogScript.new()


func bullet_config(bullet_id: StringName) -> Resource:
	return _catalog.bullet(bullet_id)


func warhead_config(warhead_id: StringName) -> Resource:
	return _catalog.warhead(warhead_id)


func runtime_bullet(bullet_id: StringName):
	var config: Resource = bullet_config(bullet_id)
	var warhead_id: StringName = config.warhead_id if config != null else &""
	var warhead: Resource = warhead_config(warhead_id) if warhead_id != &"" else null
	return CombatBulletScript.new(config, warhead)


func bullet_with_impact_scenes(bullet_id: StringName):
	var config: Resource = bullet_config(bullet_id)
	var warhead_id: StringName = config.warhead_id if config != null else &""
	var warhead: Resource = warhead_config(warhead_id) if warhead_id != &"" else null
	var impact_scenes := {}
	for value in config.explosion_effect_ids:
		var effect_id := StringName(String(value))
		var scene: PackedScene = _catalog.scene(String(config.impact_scene_paths.get(effect_id, "")))
		if scene != null:
			impact_scenes[effect_id] = scene
	return CombatBulletScript.new(config, warhead, null, impact_scenes)


static func emission(position: Vector3, direction: Vector3) -> Dictionary:
	return {
		"position": position,
		"direction": direction.normalized(),
	}
