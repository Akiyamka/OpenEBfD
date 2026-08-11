class_name BuildingDefinition
extends Resource

@export var config_id: StringName
@export var legacy_name: StringName
@export var house_id: StringName
@export var building_group_id: StringName
@export var cost: int
@export var build_time_ticks: float
@export var health: float
@export var shield_health: float
@export var armour_type: StringName
@export var tech_level: int
@export var power_used: int
@export var power_generated: int
@export var can_be_primary: bool
@export var ai_exit: bool
@export var ai_manufacturing: bool
@export var is_construction_yard: bool
@export var upgraded_primary_required: bool
@export var primary_building_ids: Array[StringName] = []
@export var secondary_building_ids: Array[StringName] = []
@export var roles: Array[StringName] = []
@export var occupy_rows: Array[String] = []
@export var deploy_points: Array[Dictionary] = []
@export var linked_unit_ids: Array[StringName] = []
@export var survivor_count: int
@export var turret_id: StringName
@export var upgrade_tech_level: int
@export var upgrade_cost: int
@export var upgrade_build_time_ticks: float
@export var model_name: String
@export var icon_path: String
@export var icon_grey_path: String
@export var sidebar_type: StringName

@export_group("Effects and links")
@export var explosion_effect_ids: Array[StringName] = []
@export var explosion_type_id: StringName
@export var explosion_scene_paths: Dictionary = {}
