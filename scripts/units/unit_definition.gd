class_name UnitDefinition
extends Resource

## Godot-native unit data introduced during the staged Rules migration.
##
## These properties are the runtime source for unit identity, production,
## movement, durability, behavior, effects, art, and combat references.

@export_group("Identity")
@export var config_id: StringName
@export var legacy_name: StringName
@export var house_id: StringName
@export var unit_group_id: StringName

@export_group("Assets")
@export_file("*.tscn") var scene_path: String
@export_file("*.scn", "*.tscn") var model_scene_path: String
@export var icon_path: String
@export var icon_grey_path: String
@export var sidebar_type: StringName
@export_file("*.tres") var voice_profile_path: String
@export var voice_profile_paths_by_house: Dictionary = {}
## Section of the original SFX data the engine synthesised as
## `<RulesSectionName>MoveFxStart` -- the engine/undercarriage sound a vehicle
## makes when it starts moving. Empty for the units whose section does not
## exist or resolves to no converted sample; only 19 of them carry one. Looked
## up through SfxSectionCatalog, which owns the authored Volume/Limit/Control.
@export var move_start_sound_id: StringName

@export_group("Production")
@export var cost: int
@export var build_time_ticks: int
@export var tech_level: int
@export var upgraded_primary_required: bool
@export var primary_building_ids: Array[StringName] = []
@export var secondary_building_ids: Array[StringName] = []

@export_group("Body")
@export var size: int
@export var health: int
@export var shield_health: float
@export var armour_type: StringName
@export var speed: float
@export var mech_speed: float
@export var mech: bool
@export var turn_rate: float
@export var infantry: bool
@export var can_fly: bool
## While hovering, this aircraft follows a slow circular patrol instead of
## remaining at its arrival point. Mirrors Rules.txt `Circles`.
@export var circles: bool
@export var ornithoptor: bool
@export var carryall: bool
@export var advanced_carryall: bool
@export var can_move_any_direction: bool
@export var terrain_ids: Array[StringName] = []

@export_group("Behavior")
@export var can_be_deviated: bool
@export var can_self_repair: bool
@export var can_be_repaired: bool
@export var crushable: bool
@export var crushes: bool
@export var starportable: bool
@export var tasty_to_worms: bool
@export var worm_attraction: int
@export var can_be_suppressed: bool
@export var can_die: bool
@export var cant_be_leeched: bool
@export var selectable: bool
@export var stealthed_when_still: bool
@export var height_offset: float
@export var roof_height: int
@export var spice_capacity: float
@export var unload_rate: float

@export_group("Effects and links")
@export var resource_ids: Array[StringName] = []
@export var explosion_effect_ids: Array[StringName] = []
@export var chaos_effect_id: StringName
@export var hawk_effect_id: StringName
@export var damage_effect_id: StringName
@export var explosion_type_id: StringName
@export var explosion_scene_paths: Dictionary = {}
@export_file("*.tres") var veterancy_level_paths: Array[String] = []

@export_group("Combat references")
@export var turret_ids: Array[StringName] = []
