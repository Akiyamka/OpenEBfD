class_name UnitDeploymentController
extends Node

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")

## Dispatches "deploy" to one of two strategies over the same {handled,
## started, message} façade. The MCV strategy (this file's original body,
## unchanged) owns both sides of the MCV/Construction Yard transformation.
## Unit deployment resolves the Construction Yard linked from the concrete
## ATMCV/HKMCV/ORMCV rules entry and hands off to normal building
## construction. A move command on a completed Construction Yard plays its
## authored Deconstruct transition, resolves the concrete MCV from the
## building's reciprocal rules link, then gives the spawned unit the original
## move order. The combat strategy (CombatDeployStrategy) instead switches a
## unit into a stationary combat mode in place, with no building involved; see
## that script for its (data-driven, no hardcoded id list) eligibility rule.

signal construction_yard_deployed(building: Node3D)
signal mcv_undeployed(unit: Node3D)

const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const PlacementContextScript := preload("res://scripts/buildings/placement_context.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const CombatDeployStrategyScript := preload("res://scripts/units/combat_deploy_strategy.gd")

const MCV_IDS: Array[StringName] = [&"ATMCV", &"HKMCV", &"ORMCV"]
const QUARTER_TURN_RADIANS := PI * 0.5
const DEFAULT_BUILDING_FORWARD_OFFSET_CELLS := 1
const DEFAULT_UNIT_FORWARD_OFFSET_WORLD := -0.8
const BUILDING_SCENE_ROOT := "res://assets/converted/buildings"

var _navigation_grid
var _buildings_root: Node3D
var _units_root: Node
var _navigation
var _deployments: Dictionary = {}
var _undeployments: Dictionary = {}
var _building_scene_cache: Dictionary = {}
static var _unit_scene_catalog := UnitSceneCatalogScript.shared()
static var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()
var _combat_deploy_strategy := CombatDeployStrategyScript.new()


func setup(
		navigation_grid,
		buildings_root: Node3D,
		units_root: Node = null,
		navigation = null
	) -> void:
	_navigation_grid = navigation_grid
	_buildings_root = buildings_root
	_units_root = units_root
	_navigation = navigation


## Result keys: handled (this command applies to this unit, by either
## strategy), started, and message.
func try_deploy(unit: Node3D) -> Dictionary:
	if _combat_deploy_strategy.can_handle(unit):
		return _combat_deploy_strategy.try_deploy(unit)
	var candidate := _deployment_candidate(unit)
	if not bool(candidate.get("handled", false)):
		return {"handled": false, "started": false, "message": ""}
	if not bool(candidate.get("available", false)):
		return _result(false, String(candidate.get("message", "")))

	var placement := candidate.get("placement") as BuildingPlacement
	var building_id: StringName = candidate.get("building_id", &"")
	var building_scene := candidate.get("building_scene") as PackedScene
	var hover_cell: Vector2i = candidate.get("hover_cell", Vector2i.ZERO)

	var deployment_id := unit.get_instance_id()
	_deployments[deployment_id] = {
		"unit": unit,
		"placement": placement,
		"hover_cell": hover_cell,
		"building_id": building_id,
		"building_scene": building_scene,
		"owner_player_id": EntityQueryScript.owner_id_of(unit),
	}
	placement.building_placed.connect(_on_building_placed.bind(deployment_id))
	unit.deployment_animation_finished.connect(
		_on_deployment_animation_finished.bind(deployment_id), CONNECT_ONE_SHOT
	)
	unit.tree_exiting.connect(_on_deploying_unit_exiting.bind(deployment_id), CONNECT_ONE_SHOT)
	if not bool(unit.call("deploy", _deployment_facing_direction(unit))):
		_abort_deployment(deployment_id, true)
		return _result(false, "MCV could not start its deployment animation")
	return _result(true, "%s deployment started" % String(building_id))


func can_handle(unit: Node3D) -> bool:
	if _combat_deploy_strategy.can_handle(unit):
		return true
	return (
		unit != null
		and StringName(String(unit.get("config_id"))) in MCV_IDS
		and unit.has_method("deploy")
		and unit.has_method("is_deploying")
		and unit.has_method("finish_deployment")
	)


## Exposed so UnitCommandController's cursor probe can skip the throttle it
## only needs for the MCV's expensive BuildingPlacement footprint check; the
## combat strategy's check is a handful of state-flag reads.
func is_combat_deploy_candidate(unit: Node3D) -> bool:
	return _combat_deploy_strategy.can_handle(unit)


func can_issue_deploy(unit: Node3D) -> bool:
	if _combat_deploy_strategy.can_handle(unit):
		return _combat_deploy_strategy.can_issue_deploy(unit)
	var candidate := _deployment_candidate(unit)
	var available := bool(candidate.get("available", false))
	var placement := candidate.get("placement") as BuildingPlacement
	if placement != null and is_instance_valid(placement):
		placement.free()
	return available


## Builds the exact placement candidate used by both cursor validation and the
## real command. A successful caller owns the returned placement node.
func _deployment_candidate(unit: Node3D) -> Dictionary:
	if not can_handle(unit):
		return {"handled": false, "available": false, "message": ""}
	if bool(unit.call("is_deploying")):
		return _reject("MCV is already deploying")
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return _reject("MCV cannot deploy: navigation grid is unavailable")
	if _buildings_root == null:
		return _reject("MCV cannot deploy: buildings root is unavailable")

	var con_yard := _construction_yard_for(unit)
	var building_id: StringName = con_yard.get("id", &"")
	var config: Resource = con_yard.get("config")
	if building_id == &"" or config == null:
		return _reject("MCV cannot deploy: its rules have no Construction Yard")

	var building_scene := _cached_building_scene(building_id)
	if building_scene == null:
		return _reject("MCV cannot deploy: %s scene is unavailable" % String(building_id))

	var placement: BuildingPlacement = BuildingPlacementScript.new()
	add_child(placement)
	var placement_context := PlacementContextScript.new()
	placement_context.navigation_grid = _navigation_grid
	placement_context.buildings_root = _buildings_root
	placement_context.existing_building_occupy_rows = Callable(
		self, "_occupy_rows_for_existing_building"
	)
	placement.setup(placement_context)
	var occupy_rows: Array[String] = []
	occupy_rows.assign(config.occupy_rows)
	if not placement.begin(building_id, String(building_id), occupy_rows, false, true):
		placement.free()
		return _reject("MCV cannot deploy: %s has no valid footprint" % String(building_id))

	placement.set_rotation_quarter_turns(_deployment_quarter_turns(unit))
	var hover_cell := _deployment_hover_cell(unit)
	var evaluation: int = placement.evaluate_at_hover_cell(hover_cell)
	if evaluation != BuildingPlacement.PlaceResult.AVAILABLE:
		placement.free()
		return _reject("MCV cannot deploy at this location")

	return {
		"handled": true,
		"available": true,
		"message": "",
		"placement": placement,
		"hover_cell": hover_cell,
		"building_id": building_id,
		"building_scene": building_scene,
	}


## Every rejection past the can_handle() gate has the same shape and differs
## only in its message. `handled` stays true there: the unit *is* an MCV, it
## just cannot deploy right now, and the caller must not fall through to the
## ordinary move order.
static func _reject(message: String) -> Dictionary:
	return {"handled": true, "available": false, "message": message}


## Whether a move order on this building should be routed to try_undeploy
## instead of the ordinary rally-point path. Construction Yards never carry
## Rules.txt's AiManufacturing flag (only real production buildings do), so
## this is checked independently of building_definition.ai_manufacturing /
## can_set_rally_point.
func can_undeploy(building: Node3D) -> bool:
	var building_config := _building_config_for(building)
	return building_config != null and building_config.is_construction_yard


## A Construction Yard receives this through the ordinary terrain move-command
## path. Result keys mirror try_deploy: handled, started, and message.
func try_undeploy(building: Node3D, move_target: Vector3, move_mode := 0) -> Dictionary:
	var building_config := _building_config_for(building)
	if building_config == null or not building_config.is_construction_yard:
		return {"handled": false, "started": false, "message": ""}
	if _undeployments.has(building.get_instance_id()):
		return _result(false, "Construction Yard is already packing")
	if not EntityQueryScript.is_operational(building):
		return _result(false, "Construction Yard cannot pack while under construction")

	var mcv := _mcv_for(building, building_config)
	var unit_id: StringName = mcv.get("id", &"")
	if unit_id == &"":
		return _result(false, "Construction Yard cannot pack: its rules have no concrete MCV")
	var unit_scene := _unit_scene_catalog.scene_for(unit_id, UnitScene)
	if unit_scene == null:
		return _result(false, "Construction Yard cannot pack: %s scene is unavailable" % String(unit_id))
	if not _unit_scene_catalog.has_scene(unit_id) \
	and _unit_scene_catalog.model_scene_for(unit_id) == null:
		return _result(false, "Construction Yard cannot pack: %s model is unavailable" % String(unit_id))
	var units_parent := _units_parent(building)
	if units_parent == null:
		return _result(false, "Construction Yard cannot pack: units root is unavailable")

	var undeployment_id := building.get_instance_id()
	_undeployments[undeployment_id] = {
		"building": building,
		"unit_id": unit_id,
		"unit_definition": mcv.get("config"),
		"unit_scene": unit_scene,
		"units_parent": units_parent,
		"owner_player_id": EntityQueryScript.owner_id_of(building),
		"spawn_position": _building_spawn_position(building),
		"exit_position": _building_exit_position(building),
		"facing": _building_exit_direction(building),
		"move_target": move_target,
		"move_mode": move_mode,
	}
	building.tree_exiting.connect(
		_on_undeploying_building_exiting.bind(undeployment_id), CONNECT_ONE_SHOT
	)

	if AuthoredModelScript.play_one_shot(
		building,
		&"deconstruct",
		_on_undeployment_animation_finished.bind(undeployment_id)
	):
		return _result(true, "%s packing into %s" % [String(building.get("config_id")), String(unit_id)])

	# Lightweight/test buildings without an authored deconstruct clip still obey
	# the same transformation contract; their handoff is simply immediate.
	_finish_undeployment(undeployment_id)
	return _result(true, "%s packing into %s" % [String(building.get("config_id")), String(unit_id)])


## Units face local -Z while converted buildings expose their front/exit on
## local +Z. Convert the MCV's semantic world direction instead of copying its
## raw yaw, then snap that building direction to the nearest 90 degrees.
func _deployment_quarter_turns(unit: Node3D) -> int:
	var facing := SpatialOrientationScript.world_forward(unit)
	if facing.length_squared() <= SpatialOrientationScript.DIRECTION_EPSILON:
		return 0
	var building_yaw := atan2(facing.x, facing.z)
	return posmod(int(roundf(building_yaw / QUARTER_TURN_RADIANS)), 4)


func _deployment_facing_direction(unit: Node3D) -> Vector3:
	match _deployment_quarter_turns(unit):
		0:
			return Vector3.BACK
		1:
			return Vector3.RIGHT
		2:
			return Vector3.FORWARD
		3:
			return Vector3.LEFT
	return Vector3.BACK


func _deployment_hover_cell(unit: Node3D) -> Vector2i:
	var unit_cell: Vector2i = _navigation_grid.world_to_grid(unit.global_position)
	var facing := SpatialOrientationScript.world_forward(unit)
	if facing.length_squared() <= SpatialOrientationScript.DIRECTION_EPSILON:
		return unit_cell

	# Placement anchors are aligned to two navigation cells per authored
	# footprint cell. Moving by that full step keeps the forward offset stable
	# on either side of an anchor boundary.
	var forward_cell := Vector2i.ZERO
	match _deployment_quarter_turns(unit):
		0:
			forward_cell = Vector2i.DOWN
		1:
			forward_cell = Vector2i.RIGHT
		2:
			forward_cell = Vector2i.UP
		3:
			forward_cell = Vector2i.LEFT
	return (
		unit_cell
		+ forward_cell
			* DEFAULT_BUILDING_FORWARD_OFFSET_CELLS
			* BuildingPlacementScript.NAV_CELLS_PER_OCCUPY_CELL
	)


func _on_deployment_animation_finished(deployment_id: int) -> void:
	var deployment: Dictionary = _deployments.get(deployment_id, {})
	if deployment.is_empty():
		return
	var unit := deployment["unit"] as Node3D
	var placement: BuildingPlacement = deployment["placement"]
	if unit == null or not is_instance_valid(unit) or placement == null:
		_abort_deployment(deployment_id, unit != null and is_instance_valid(unit))
		return

	var result: int = placement.try_place_at_hover_cell(
		deployment["hover_cell"],
		deployment["building_scene"],
		deployment["owner_player_id"],
		unit
	)
	if result != BuildingPlacement.PlaceResult.PLACED:
		_abort_deployment(deployment_id, true)
		return

	unit.call("finish_deployment", true)
	_deployments.erase(deployment_id)
	unit.queue_free()


func _on_building_placed(building: Node3D, deployment_id: int) -> void:
	var deployment: Dictionary = _deployments.get(deployment_id, {})
	if deployment.is_empty() or building == null:
		return
	if building.has_signal("construction_completed"):
		building.construction_completed.connect(
			_on_construction_yard_completed.bind(building), CONNECT_ONE_SHOT
		)
	else:
		_on_construction_yard_completed(building)


func _on_construction_yard_completed(building: Node3D) -> void:
	if building == null or not is_instance_valid(building):
		return
	var players := AutoloadLookupScript.roster(self)
	if players != null:
		players.set_main_base(EntityQueryScript.owner_id_of(building), building)
	construction_yard_deployed.emit(building)


func _on_undeployment_animation_finished(
		animation_name: StringName, undeployment_id: int
	) -> void:
	if animation_name != &"deconstruct":
		_abort_undeployment(undeployment_id, true)
		return
	_finish_undeployment(undeployment_id)


func _finish_undeployment(undeployment_id: int) -> void:
	var undeployment: Dictionary = _undeployments.get(undeployment_id, {})
	if undeployment.is_empty():
		return
	var building := undeployment.get("building") as Node3D
	var units_parent := undeployment.get("units_parent") as Node
	var unit_scene := undeployment.get("unit_scene") as PackedScene
	if building == null or not is_instance_valid(building) \
	or units_parent == null or not is_instance_valid(units_parent) \
	or unit_scene == null:
		_abort_undeployment(
			undeployment_id, building != null and is_instance_valid(building)
		)
		return

	var unit_id: StringName = undeployment["unit_id"]
	var unit := _unit_scene_catalog.instantiate(unit_id, UnitScene) as Unit
	if unit == null:
		_abort_undeployment(undeployment_id, true)
		return
	unit.name = String(unit_id)
	unit.config_id = unit_id
	unit.unit_definition = undeployment.get("unit_definition") as Resource
	units_parent.add_child(unit)
	unit.set_simulation_position(undeployment["spawn_position"])
	unit.face_direction(undeployment["facing"])
	unit.set_owner_player_id(int(undeployment["owner_player_id"]))

	_undeployments.erase(undeployment_id)
	building.queue_free()
	var move_target: Vector3 = undeployment["move_target"]
	var exit_position: Vector3 = undeployment["exit_position"]
	if _navigation != null and _navigation.has_method("command_move"):
		_navigation.call(
			"command_move", [unit], move_target, int(undeployment["move_mode"]), exit_position
		)
	else:
		unit.move_to(move_target, exit_position)
	mcv_undeployed.emit(unit)


func _on_undeploying_building_exiting(undeployment_id: int) -> void:
	_abort_undeployment(undeployment_id, false)


func _abort_undeployment(undeployment_id: int, restore_building: bool) -> void:
	var undeployment: Dictionary = _undeployments.get(undeployment_id, {})
	if undeployment.is_empty():
		return
	_undeployments.erase(undeployment_id)
	var building := undeployment.get("building") as Node3D
	if restore_building and building != null and is_instance_valid(building):
		if building.has_method("play_state"):
			building.call("play_state", &"idle")


func _on_deploying_unit_exiting(deployment_id: int) -> void:
	_abort_deployment(deployment_id, false)


func _abort_deployment(deployment_id: int, release_unit: bool) -> void:
	var deployment: Dictionary = _deployments.get(deployment_id, {})
	if deployment.is_empty():
		return
	_deployments.erase(deployment_id)
	var placement = deployment.get("placement")
	if placement != null and is_instance_valid(placement):
		placement.queue_free()
	var unit = deployment.get("unit")
	if release_unit and unit != null and is_instance_valid(unit):
		unit.call("finish_deployment", false)


func _construction_yard_for(unit: Node3D) -> Dictionary:
	var unit_definition = unit.get("unit_definition") as Resource
	if unit_definition == null:
		unit_definition = _unit_scene_catalog.definition_for(StringName(String(unit.get("config_id"))))
	if unit_definition == null:
		return {}
	# The concrete MCV rules entry carries exactly one deployment target. Player
	# ownership and the player's default/cosmetic house are intentionally absent
	# from this decision.
	for value in unit_definition.resource_ids:
		var building_id := StringName(String(value))
		var config := _building_definition_catalog.definition(building_id)
		if config == null or not config.is_construction_yard:
			continue
		return {"id": building_id, "config": config}
	return {}


func _mcv_for(building: Node3D, building_config: Resource = null) -> Dictionary:
	var config := building_config
	if config == null:
		config = _building_config_for(building)
	if config == null:
		return {}
	for value in config.linked_unit_ids:
		var unit_id := StringName(String(value))
		if unit_id not in MCV_IDS:
			continue
		var unit_definition := _unit_scene_catalog.definition_for(unit_id)
		if unit_definition != null:
			return {"id": unit_id, "config": unit_definition}
	return {}


func _building_config_for(building: Node3D) -> Resource:
	if building == null:
		return null
	return _building_definition_catalog.definition(
		StringName(String(building.get("config_id")))
	)


func _units_parent(building: Node3D) -> Node:
	if _units_root != null and is_instance_valid(_units_root):
		return _units_root
	return EntityQueryScript.units_parent(
		get_tree() if is_inside_tree() else null,
		building.get_parent() if building != null else null
	)


func _building_spawn_position(building: Node3D) -> Vector3:
	# Deconstruct ends with the folded MCV at the Construction Yard's own
	# gameplay pivot. The tuned offset moves it only along the shared
	# building/MCV forward axis; production_spawn_position() remains
	# the separate front-apron contract used by ordinary factory output.
	return (
		building.global_position
		+ _building_exit_direction(building) * DEFAULT_UNIT_FORWARD_OFFSET_WORLD
	)


func _building_exit_position(building: Node3D) -> Vector3:
	if building.has_method("production_exit_position"):
		return building.call("production_exit_position") as Vector3
	return _building_spawn_position(building) + _building_exit_direction(building) * 2.0


func _building_exit_direction(building: Node3D) -> Vector3:
	return EntityQueryScript.exit_direction(building)


func _occupy_rows_for_existing_building(building: Node3D) -> Array[String]:
	var config = _building_definition_catalog.definition(
		StringName(String(building.get("config_id")))
	)
	var rows: Array[String] = []
	if config != null:
		rows.assign(config.occupy_rows)
	return rows


func _building_scene_path(building_id: StringName) -> String:
	var prepared_path := _building_definition_catalog.scene_path(building_id)
	if not prepared_path.is_empty() and ResourceLoader.exists(prepared_path):
		return prepared_path
	var id_text := String(building_id)
	return BUILDING_SCENE_ROOT.path_join(id_text).path_join("%s.scn" % id_text)


## The deploy-cursor check re-resolves this every second while an MCV stays
## selected and hovered; building_id only ever spans MCV_IDS's three concrete
## Construction Yards, so caching sidesteps a repeated ResourceLoader hit for
## a scene path that cannot change at runtime.
func _cached_building_scene(building_id: StringName) -> PackedScene:
	if _building_scene_cache.has(building_id):
		return _building_scene_cache[building_id]
	var scene_path := _building_scene_path(building_id)
	if not ResourceLoader.exists(scene_path):
		return null
	var scene := load(scene_path) as PackedScene
	if scene != null:
		_building_scene_cache[building_id] = scene
	return scene


func _result(started: bool, message: String) -> Dictionary:
	return {"handled": true, "started": started, "message": message}
