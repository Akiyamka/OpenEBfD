class_name BuildingCatalogView
extends RefCounted

const BuildingDefinitionCatalogScript := preload(
	"res://scripts/buildings/building_definition_catalog.gd"
)
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

var _catalog := BuildingDefinitionCatalogScript.shared()
var _ids: Array[StringName] = []
var _configs: Dictionary = {}
var _availability: Dictionary = {}


func configure(building_ids: Array[StringName]) -> void:
	_ids = building_ids.duplicate()
	_configs.clear()
	_availability.clear()
	for building_id in _ids:
		var building_config: Resource = _catalog.definition(building_id)
		if building_config == null:
			push_warning("Building definition not found: %s" % String(building_id))
			continue
		_configs[building_id] = building_config


func ids() -> Array[StringName]:
	return _ids.duplicate()


func has(building_id: StringName) -> bool:
	return _ids.has(building_id)


## Resolved from the preloaded map first, then straight from the shared
## catalog. Deliberately no roster/autoload lookup on this path: a freed
## building's _exit_tree() can still reach BuildingController's option-state
## refresh through the energy/resources signal chain after that controller has
## itself left the tree, and absolute-path autoload lookups are invalid by
## then. Definition data is static, so it never needs one.
func config(building_id: StringName) -> Resource:
	# An explicit branch, not Dictionary.get(key, default): GDScript evaluates
	# the default eagerly, so the catalog fallback would run on every hit too --
	# and this is called once per configured id per option-state refresh.
	if _configs.has(building_id):
		return _configs[building_id] as Resource
	return _catalog.definition(building_id)


func config_of(building: Node) -> Resource:
	if building == null:
		return null
	var direct = building.get("building_config") as Resource
	return direct if direct != null \
		else config(StringName(String(building.get("config_id"))))


func refresh_availability(
		technology_tree,
		player,
		buildings: Array[Node],
		max_tech_level: int
) -> bool:
	var changed := false
	for building_id in _ids:
		var building_config := config(building_id)
		var available: bool = building_config != null and player != null \
			and technology_tree.is_available(
				building_config, player, buildings, max_tech_level
			)
		if available == _availability.get(building_id, false):
			continue
		_availability[building_id] = available
		changed = true
	return changed


func is_available(building_id: StringName) -> bool:
	return bool(_availability.get(building_id, false))


func scene_path(building_id: StringName) -> String:
	var prepared_path := _catalog.scene_path(building_id)
	if not prepared_path.is_empty() and ResourceLoader.exists(prepared_path):
		return prepared_path
	var id_text := String(building_id)
	var id_path := _scene_path_for_name(id_text)
	if ResourceLoader.exists(id_path):
		return id_path
	var model := model_name(building_id)
	if not model.is_empty() and model != id_text:
		var model_path := _scene_path_for_name(model)
		if ResourceLoader.exists(model_path):
			return model_path
	return id_path


func model_name(building_id: StringName) -> String:
	var definition := _catalog.definition(building_id)
	return definition.model_name if definition != null else ""


func display_name(building_id: StringName) -> String:
	match building_id:
		&"ATSmWindtrap":
			return "Windtrap"
		&"ATBarracks":
			return "Barracks"
	return String(building_id)


func tooltip(building_id: StringName) -> String:
	var building_config := config(building_id)
	if building_config == null:
		return display_name(building_id)
	# Seconds from the actual simulation ticks the order will run for, not the
	# pre-conversion rules-domain ideal -- this is the duration the player
	# really waits, rounding included (RuleTicks.to_sim_ticks()).
	var sim_ticks := RuleTicksScript.to_sim_ticks(building_config.build_time_ticks)
	var seconds := float(sim_ticks) * MatchClockScript.SECONDS_PER_TICK
	return "%s\nCost: %d\nBuild: %.1fs" % [
		display_name(building_id), int(building_config.cost), seconds,
	]


func _scene_path_for_name(scene_name: String) -> String:
	return "res://assets/converted/buildings/%s/%s.scn" % [scene_name, scene_name]
