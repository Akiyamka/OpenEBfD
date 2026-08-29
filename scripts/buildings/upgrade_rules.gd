class_name UpgradeRules
extends RefCounted

const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")

## Rules-shaped defaults, in rule ticks (60/sec) like every other build time
## in the rules data.
const DEFAULT_GLOBAL_UPGRADE_BUILD_TIME_TICKS := 60.0
## Rules.txt defines this separately for all three refinery docks, but the
## current generated rules database predates that column.
const DEFAULT_DOCK_UPGRADE_BUILD_TIME_TICKS := 720.0

static var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()
static var _unit_definition_catalog := UnitSceneCatalogScript.shared()


static func is_refinery_dock_id(building_id: StringName) -> bool:
	var config: Resource = _building_definition_catalog.definition(building_id)
	return config != null and config.building_group_id == &"RefineryDock"


static func display_name(building_id: StringName) -> String:
	return "%s upgrade" % String(building_id)


## Converts the rules-domain build time to the Match simulation tick domain.
static func build_time_sim_ticks(config: Resource, refinery_dock: bool) -> int:
	return RuleTicksScript.to_sim_ticks(_build_time_rule_ticks(config, refinery_dock))


static func _build_time_rule_ticks(config: Resource, refinery_dock: bool) -> float:
	if config == null:
		return DEFAULT_GLOBAL_UPGRADE_BUILD_TIME_TICKS
	if refinery_dock:
		return config.upgrade_build_time_ticks if config.upgrade_build_time_ticks > 0.0 else DEFAULT_DOCK_UPGRADE_BUILD_TIME_TICKS
	var build_time: float = float(config.build_time_ticks)
	if build_time > 0.0:
		return build_time
	var resource_build_time := _linked_resource_build_time(config)
	return resource_build_time if resource_build_time > 0.0 else DEFAULT_GLOBAL_UPGRADE_BUILD_TIME_TICKS


static func _linked_resource_build_time(config: Resource) -> float:
	for target_id in config.linked_unit_ids:
		var building_definition := _building_definition_catalog.definition(target_id)
		if building_definition != null and building_definition.build_time_ticks > 0.0:
			return building_definition.build_time_ticks
		var unit_definition := _unit_definition_catalog.definition_for(target_id)
		if unit_definition != null and unit_definition.build_time_ticks > 0.0:
			return unit_definition.build_time_ticks
	return 0.0
