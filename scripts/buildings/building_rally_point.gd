class_name BuildingRallyPoint
extends RefCounted

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")
const OccupyGridScript := preload("res://scripts/buildings/occupy_grid.gd")
const MARKER_SCENE := preload("res://assets/converted/ui/cursor_models/place_flag.scn")
const CELL_SPAN := OccupyGridScript.CELL_WORLD_SPAN
const CLEARANCE := 1.5
const LINE_COLOR := Color(0.12, 1.0, 0.28, 0.9)
const LINE_WIDTH := 0.10
const LINE_HEIGHT := 0.08

var _owner: Node3D
var _line: MeshInstance3D
var _mesh: ImmediateMesh
var _material: StandardMaterial3D
var _marker: Node3D
var _has_point := false
var _is_default := true


func configure(owner: Node3D) -> void:
	_owner = owner
	_add_line()
	_add_marker()


func can_set() -> bool:
	return _owner.building_definition != null and (
		_owner.building_definition.ai_manufacturing or _owner.is_refinery()
	)


func set_point(position: Vector3) -> bool:
	if not can_set():
		return false
	_assign(position, false)
	return true


func point() -> Vector3:
	set_default_if_unset()
	return _owner.rally_point


func spawn_position() -> Vector3:
	var authored_exit := _authored_exit_node()
	if authored_exit != null:
		return authored_exit.global_position # arch-allow: global-position-read-bypasses-store -- authored exit marker inside the model, no store entry
	if _owner.building_definition == null:
		return _owner.simulation_position() + _owner.exit_direction()
	var rows: Array[String] = []
	rows.assign(_owner.building_definition.occupy_rows)
	var spawn_cell := _nearest_skirt_cell(rows)
	if spawn_cell.x < 0:
		return _owner.simulation_position() + _owner.exit_direction()
	var width := OccupyGridScript.width(rows)
	var local_offset := Vector3(
		(float(spawn_cell.x) + 0.5 - float(width) * 0.5) * CELL_SPAN,
		0.0,
		(float(spawn_cell.y) + 0.5 - float(rows.size()) * 0.5) * CELL_SPAN
	)
	return _owner.simulation_position() \
		+ SpatialOrientationScript.world_right(_owner) * local_offset.x \
		+ _owner.exit_direction() * local_offset.z


func exit_position() -> Vector3:
	var spawn := spawn_position()
	var forward: Vector3 = _owner.exit_direction()
	var spawn_depth := (_owner.global_transform.affine_inverse() * spawn).z # arch-allow: global-position-read-bypasses-store -- needs the basis, which SimEntityState does not hold
	return spawn + forward * maxf(
		_front_footprint_extent() - spawn_depth + CLEARANCE, CLEARANCE
	)


func set_default_if_unset() -> void:
	if _has_point:
		return
	_assign(
		_owner.simulation_position() + _owner.exit_direction() * (CLEARANCE + _front_collision_extent()),
		true
	)


func refresh_visibility() -> void:
	if _line != null:
		_line.visible = _owner.is_selected and _has_point and not _is_default \
			and _line.mesh != null
	if _marker != null:
		if _has_point:
			_marker.position = _owner.to_local(_owner.rally_point)
		_marker.visible = _owner.is_selected and _has_point and not _is_default


func _assign(position: Vector3, is_default: bool) -> void:
	_owner.rally_point = position
	_has_point = true
	_is_default = is_default
	_rebuild_line()
	_owner.call("_emit_rally_point_changed", _owner.rally_point)


func _add_line() -> void:
	_line = MeshInstance3D.new()
	_line.name = "RallyPointLine"
	_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_line.extra_cull_margin = 1000.0
	_owner.add_child(_line)
	_mesh = ImmediateMesh.new()
	_material = StandardMaterial3D.new()
	_material.albedo_color = LINE_COLOR
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.render_priority = 19
	_rebuild_line()


func _add_marker() -> void:
	_marker = MARKER_SCENE.instantiate() as Node3D
	if _marker == null:
		return
	_marker.name = "RallyPointMarker"
	for node in _marker.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).layers = 1
	_owner.add_child(_marker)
	refresh_visibility()


func _rebuild_line() -> void:
	if _line == null:
		return
	_mesh.clear_surfaces()
	if not _has_point or _is_default:
		_line.mesh = null
		refresh_visibility()
		return
	var spawn := _owner.to_local(spawn_position())
	var exit := _owner.to_local(exit_position())
	var finish := _owner.to_local(_owner.rally_point)
	var first := exit - spawn
	var second := finish - exit
	first.y = 0.0
	second.y = 0.0
	if first.length_squared() <= 0.000001 and second.length_squared() <= 0.000001:
		_line.mesh = null
		refresh_visibility()
		return
	spawn.y += LINE_HEIGHT
	exit.y += LINE_HEIGHT
	finish.y += LINE_HEIGHT
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _material)
	_add_segment(spawn, exit)
	_add_segment(exit, finish)
	_mesh.surface_end()
	_line.mesh = _mesh
	refresh_visibility()


func _add_segment(start: Vector3, finish: Vector3) -> void:
	var direction := finish - start
	direction.y = 0.0
	if direction.length_squared() <= 0.000001:
		return
	var lateral := Vector3(-direction.z, 0.0, direction.x).normalized() * LINE_WIDTH * 0.5
	_add_triangle(start - lateral, finish - lateral, finish + lateral)
	_add_triangle(start - lateral, finish + lateral, start + lateral)


func _add_triangle(a: Vector3, b: Vector3, c: Vector3) -> void:
	_mesh.surface_add_vertex(a)
	_mesh.surface_add_vertex(b)
	_mesh.surface_add_vertex(c)


func _front_footprint_extent() -> float:
	if _owner.building_definition != null:
		var rows: Array = _owner.building_definition.occupy_rows
		if not rows.is_empty():
			return float(rows.size()) * CELL_SPAN * 0.5
	return _front_collision_extent()


func _front_collision_extent() -> float:
	return AuthoredModelScript.front_collision_extent(_owner)


func _authored_exit_node() -> Node3D:
	var idle_state := _owner.get_node_or_null("States/Idle")
	return _find_slct_node(idle_state) if idle_state != null else null


func _find_slct_node(node: Node) -> Node3D:
	if node is Node3D and String(node.get_meta("original_name", "")).to_lower().begins_with("slct"):
		return node
	for child in node.get_children():
		var found := _find_slct_node(child)
		if found != null:
			return found
	return null


func _nearest_skirt_cell(rows: Array[String]) -> Vector2i:
	if rows.is_empty():
		return Vector2i(-1, -1)
	var width := OccupyGridScript.width(rows)
	var centre := Vector2(float(width) * 0.5 - 0.5, float(rows.size()) * 0.5 - 0.5)
	var closest := Vector2i(-1, -1)
	var closest_distance := INF
	for row_index in rows.size():
		for column_index in rows[row_index].length():
			if rows[row_index].substr(column_index, 1).to_lower() != "s":
				continue
			var distance := Vector2(column_index, row_index).distance_squared_to(centre)
			if distance < closest_distance:
				closest = Vector2i(column_index, row_index)
				closest_distance = distance
	return closest
