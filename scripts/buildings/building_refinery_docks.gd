class_name BuildingRefineryDocks
extends RefCounted

const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")
const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")
const OccupyGridScript := preload("res://scripts/buildings/occupy_grid.gd")
const BuildingRallyPointScript := preload("res://scripts/buildings/building_rally_point.gd")

const REFINERY_ROLE := "Refinery"
const RELEASE_DELAY_SECONDS := 3.0
const INVALID_DOCK := -1
const MAX_UPGRADES := 2
const OCCUPY_CELL_WORLD_SPAN := OccupyGridScript.CELL_WORLD_SPAN
const RALLY_POINT_CLEARANCE := BuildingRallyPointScript.CLEARANCE
const ANIMATIONS: Array[StringName] = [&"Refinery_Pad_1", &"Refinery_Pad_2"]
const POINT_ORDER := [0, 2, 1]

var _owner: Node3D
var _users: Dictionary = {}
var _cooldowns: Dictionary = {}


func configure(owner: Node3D) -> void:
	_owner = owner


func advance(delta: float) -> void:
	_prune_users()
	for dock_index in _cooldowns.keys():
		var remaining := maxf(float(_cooldowns[dock_index]) - maxf(delta, 0.0), 0.0)
		if remaining <= 0.0001:
			_cooldowns.erase(dock_index)
		else:
			_cooldowns[dock_index] = remaining


func dock_count() -> int:
	return _owner.refinery_upgrade_state


func capacity() -> int:
	if not is_refinery():
		return 0
	return mini(1 + _owner.refinery_upgrade_state, _dock_points().size())


func is_refinery() -> bool:
	return _owner.building_definition != null \
		and _owner.building_definition.roles.has(REFINERY_ROLE)


func try_reserve(harvester: Node) -> int:
	if harvester == null or not is_instance_valid(harvester):
		return INVALID_DOCK
	_prune_users()
	for dock_index in capacity():
		if float(_cooldowns.get(dock_index, 0.0)) > 0.0 or _users.has(dock_index):
			continue
		_users[dock_index] = harvester
		return dock_index
	return INVALID_DOCK


func reserved_by(dock_index: int, harvester: Node) -> bool:
	_prune_users()
	return _users.get(dock_index) == harvester


func release(harvester: Node, cooldown_seconds := RELEASE_DELAY_SECONDS) -> void:
	for dock_index in _users.keys():
		if _users[dock_index] != harvester:
			continue
		_users.erase(dock_index)
		_cooldowns[dock_index] = maxf(cooldown_seconds, 0.0)


func front_position() -> Vector3:
	return _owner.simulation_position() + _owner.exit_direction() * (
		_front_footprint_extent() + RALLY_POINT_CLEARANCE
	)


func world_position(dock_index: int) -> Vector3:
	var points := _dock_points()
	var rows := _occupy_rows()
	if dock_index < 0 or dock_index >= capacity() or rows.is_empty():
		return Vector3.INF
	var point: Dictionary = points[dock_index]
	var width := OccupyGridScript.width(rows)
	if width <= 0:
		return Vector3.INF
	var mirrored_y := rows.size() - 1 - int(point.get("tile_y", 0))
	var local_x := (float(point.get("tile_x", 0)) + 0.5 - float(width) * 0.5) \
		* OCCUPY_CELL_WORLD_SPAN
	var local_z := (float(mirrored_y) + 0.5 - float(rows.size()) * 0.5) \
		* OCCUPY_CELL_WORLD_SPAN
	return _owner.simulation_position() \
		+ SpatialOrientationScript.world_right(_owner) * local_x \
		+ _owner.exit_direction() * local_z


func facing_direction(dock_index: int) -> Vector3:
	var points := _dock_points()
	if dock_index < 0 or dock_index >= capacity():
		return _owner.exit_direction()
	var degrees := float((points[dock_index] as Dictionary).get("angle", 0.0))
	return _owner.exit_direction().rotated(Vector3.UP, deg_to_rad(-degrees)).normalized()


func navigation_cells(navigation_grid) -> Dictionary:
	if navigation_grid == null:
		return {}
	var footprint := BuildingFootprintScript.nav_cells_by_marker(
		_owner,
		_occupy_rows(),
		navigation_grid,
		BuildingPlacementScript.NAV_CELLS_PER_OCCUPY_CELL
	)
	var dock_cells := {}
	for cell in footprint:
		var marker := String(footprint[cell]).to_lower()
		if marker == "d" or marker == "p":
			dock_cells[cell] = marker
	return dock_cells


func can_add_upgrade() -> bool:
	return _owner.refinery_upgrade_state < MAX_UPGRADES


func add_upgrade() -> bool:
	if not can_add_upgrade():
		return false
	_owner.refinery_upgrade_state += 1
	_play_animation(_owner.refinery_upgrade_state - 1)
	return true


func set_upgrade_state(state: int) -> void:
	_owner.refinery_upgrade_state = clampi(state, 0, MAX_UPGRADES)
	if _owner.is_inside_tree():
		apply_upgrade_pose()


func apply_upgrade_pose() -> void:
	var player := _animation_player()
	if player == null:
		return
	for animation_index in _owner.refinery_upgrade_state:
		var animation_name := ANIMATIONS[animation_index]
		if not player.has_animation(animation_name):
			continue
		var animation := player.get_animation(animation_name)
		player.play(animation_name)
		player.seek(animation.length, true)
		player.pause()


func _play_animation(animation_index: int) -> void:
	var player := _animation_player()
	if player == null or animation_index < 0 or animation_index >= ANIMATIONS.size():
		return
	var animation_name := ANIMATIONS[animation_index]
	if player.has_animation(animation_name):
		player.play(animation_name)


func _animation_player() -> AnimationPlayer:
	var state_root: Node3D = _owner.call("state_root", _owner.current_state)
	if state_root == null:
		state_root = _owner.get_node_or_null("States/Idle")
	if state_root == null:
		return null
	return state_root.get_node_or_null("AnimationPlayer") as AnimationPlayer


func _front_footprint_extent() -> float:
	var rows := _occupy_rows()
	if not rows.is_empty():
		return float(rows.size()) * OCCUPY_CELL_WORLD_SPAN * 0.5
	return AuthoredModelScript.front_collision_extent(_owner)


func _dock_points() -> Array:
	var source_points: Array = (
		_owner.building_definition.deploy_points
		if _owner.building_definition != null else []
	)
	var ordered_points: Array = []
	for source_index in POINT_ORDER:
		if source_index < source_points.size():
			ordered_points.append(source_points[source_index])
	return ordered_points


func _occupy_rows() -> Array:
	return _owner.building_definition.occupy_rows \
		if _owner.building_definition != null else []


func _prune_users() -> void:
	for dock_index in _users.keys():
		var harvester = _users[dock_index]
		if not is_instance_valid(harvester) or harvester.is_queued_for_deletion():
			_users.erase(dock_index)
