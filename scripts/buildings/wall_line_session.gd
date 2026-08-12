class_name WallLineSession
extends RefCounted

const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const WallLineScript := preload("res://scripts/buildings/wall_line.gd")
const WallChainScript := preload("res://scripts/buildings/wall_chain.gd")

var _marker_parent: Node3D
var _placement
var _marker_scene: PackedScene
var _start_cell = null
var _building_id: StringName = &""
var _chain
var _markers: Dictionary = {}
var _queue
var _config_provider: Callable
var _rows_provider: Callable
var _display_provider: Callable
var _scene_provider: Callable
var _player_provider: Callable
var _owner_id_provider: Callable
var _status: Callable
var _refresh: Callable


func configure(
		marker_parent: Node3D,
		placement,
		queue,
		wall_marker_scene: PackedScene,
		config_provider: Callable,
		rows_provider: Callable,
		display_provider: Callable,
		scene_provider: Callable,
		player_provider: Callable,
		owner_id_provider: Callable,
		status: Callable,
		refresh: Callable
) -> void:
	_marker_parent = marker_parent
	_placement = placement
	_marker_scene = wall_marker_scene
	_queue = queue
	_config_provider = config_provider
	_rows_provider = rows_provider
	_display_provider = display_provider
	_scene_provider = scene_provider
	_player_provider = player_provider
	_owner_id_provider = owner_id_provider
	_status = status
	_refresh = refresh


func begin(order_building_id: StringName, display_name: String, occupy_rows: Array[String]) -> bool:
	_start_cell = null
	_building_id = order_building_id
	return _placement.begin(order_building_id, display_name, occupy_rows, true)


func end() -> void:
	_start_cell = null
	_building_id = &""


func click(
		screen_position: Vector2, status: Callable, start_chain_callback: Callable
) -> void:
	var cell = _placement.hover_cell_from_pointer(screen_position)
	if cell == null:
		status.call("Wall placement needs terrain")
		return
	if _start_cell == null:
		_start_cell = cell
		status.call("Wall start set; click the line end")
		return
	var start: Vector2i = _start_cell
	preview_to(cell)
	var buildable: Array[Vector2i] = _placement.available_preview_anchor_cells()
	lock_markers(buildable)
	start_chain_callback.call(start, cell, _building_id, buildable)


func process_preview(screen_position: Vector2) -> void:
	if not _placement.is_active():
		return
	var hover_cell = _placement.hover_cell_from_pointer(screen_position)
	if hover_cell == null:
		var no_cells: Array[Vector2i] = []
		_placement.preview_at_hover_cells(no_cells)
		return
	preview_to(hover_cell)


func preview_to(hover_cell: Vector2i) -> void:
	var preview_cells: Array[Vector2i] = [hover_cell]
	if _start_cell != null:
		preview_cells = nav_cells_between(_start_cell, hover_cell)
	_placement.preview_at_hover_cells(preview_cells)


func nav_cells_between(from_nav_cell: Vector2i, to_nav_cell: Vector2i) -> Array[Vector2i]:
	var span := BuildingPlacementScript.NAV_CELLS_PER_OCCUPY_CELL
	var from_occupy := Vector2i(
		int(floor(float(from_nav_cell.x) / float(span))),
		int(floor(float(from_nav_cell.y) / float(span)))
	)
	var to_occupy := Vector2i(
		int(floor(float(to_nav_cell.x) / float(span))),
		int(floor(float(to_nav_cell.y) / float(span)))
	)
	var occupy_cells := WallLineScript.occupy_cells_between(from_occupy, to_occupy)
	var nav_cells: Array[Vector2i] = []
	for occupy_cell in occupy_cells:
		nav_cells.append(occupy_cell * span)
	return nav_cells


func lock_markers(anchor_cells: Array[Vector2i]) -> void:
	clear_markers()
	if _marker_scene == null:
		return
	for anchor_cell in anchor_cells:
		var marker := _marker_scene.instantiate() as Node3D
		if marker == null:
			continue
		marker.name = "WallMarker_%d_%d" % [anchor_cell.x, anchor_cell.y]
		_marker_parent.add_child(marker)
		marker.global_position = _placement.wall_marker_world_position(anchor_cell)
		_markers[anchor_cell] = marker


func remove_marker(anchor_cell: Vector2i) -> void:
	var marker := _markers.get(anchor_cell) as Node3D
	_markers.erase(anchor_cell)
	if marker == null:
		return
	if marker.get_parent() == _marker_parent:
		_marker_parent.remove_child(marker)
	marker.queue_free()


func clear_markers() -> void:
	for anchor_cell in _markers.keys():
		remove_marker(anchor_cell)


func start_chain(
		from_nav_cell: Vector2i,
		to_nav_cell: Vector2i,
		order_building_id: StringName,
		selected_buildable_cells: Array[Vector2i]
) -> void:
	# Callers that never went through begin() (a direct start_chain, e.g. from
	# a test) can arrive without an id; the Atreides wall is the default the
	# wall tool has always fallen back to.
	if String(order_building_id).is_empty():
		order_building_id = &"ATWall"
	if _chain != null or _queue.has_order():
		_status.call("Building queue is busy")
		clear_markers()
		return
	var config: Resource = _config_provider.call(order_building_id)
	if config == null:
		_status.call("Wall rules are not loaded")
		clear_markers()
		return
	var cells: Array[Vector2i] = []
	for cell in nav_cells_between(from_nav_cell, to_nav_cell):
		if selected_buildable_cells.has(cell):
			cells.append(cell)
	if cells.is_empty():
		_status.call("Wall line has no buildable segments")
		_end_chain()
		return
	var line_start_world_position := _placement.wall_marker_world_position(cells[0])
	# Two different owners are in play here and they are not interchangeable:
	# _player_provider answers the local PlayerData (what _refund() spends from),
	# while the chain needs the roster's local_player_id. Collapsing them into one
	# provider is what crashed -- PlayerData has player_id, not local_player_id.
	var owner_id = _owner_id_provider.call() if not _owner_id_provider.is_null() else null
	_chain = WallChainScript.new(
		order_building_id, _display_provider.call(order_building_id),
		maxi(config.cost, 0), maxf(config.build_time_ticks, 1.0), cells, owner_id
	)
	advance_chain()
	# Played only now, after advance_chain(): _placement.begin()/.cancel() calls
	# made while evaluating segment availability free every child of _placement
	# (including a just-attached one-shot audio player) via _clear_preview_cells(),
	# so an earlier call here would be silently killed before it could be heard.
	if _chain != null:
		_placement.play_wall_line_start_thud(line_start_world_position)


func advance_chain() -> void:
	while _chain != null:
		var availability := _segment_availability(_chain)
		if availability == BuildingPlacementScript.PlaceResult.AVAILABLE:
			break
		if availability != BuildingPlacementScript.PlaceResult.CANNOT_BUILD:
			_status.call("%s segment could not be evaluated" % _chain.display_name)
			_end_chain()
			return
		var skipped_index: int = _chain.segment_index()
		remove_marker(_chain.current_cell())
		if not _chain.advance():
			_status.call("%s wall complete; segment %d/%d skipped" % [
				_chain.display_name, skipped_index, _chain.segment_count(),
			])
			_end_chain()
			return
		_status.call("%s segment %d/%d skipped" % [
			_chain.display_name, skipped_index, _chain.segment_count(),
		])
	if not _queue.start(
		_chain.building_id, _chain.display_name, _chain.cost, _chain.build_time_ticks
	):
		_status.call("%s segment could not be queued" % _chain.display_name)
		_end_chain()
		return
	_status.call("%s segment %d/%d ordered" % [
		_chain.display_name, _chain.segment_index(), _chain.segment_count(),
	])
	_refresh.call()


func place_ready_segment() -> void:
	var active_chain = _chain
	var completed_order = _queue.take_ready()
	var config: Resource = _config_provider.call(active_chain.building_id)
	var rows: Array[String] = _rows_provider.call(config)
	if not _placement.begin(
		active_chain.building_id, active_chain.display_name, rows, true
	):
		_refund(completed_order)
		_status.call("%s has no occupy_rows" % active_chain.display_name)
		_end_chain()
		return
	var scene_path: String = _scene_provider.call(active_chain.building_id)
	if not ResourceLoader.exists(scene_path):
		_refund(completed_order)
		_status.call("%s placement valid; missing scene %s" % [
			active_chain.display_name, scene_path,
		])
		_placement.cancel()
		_end_chain()
		return
	var scene := load(scene_path) as PackedScene
	var placed: int = _placement.try_place_at_hover_cell(
		active_chain.current_cell(), scene, active_chain.owner_player_id
	)
	if placed == BuildingPlacementScript.PlaceResult.CANNOT_BUILD:
		_refund(completed_order)
		_placement.cancel()
		var skipped_index: int = active_chain.segment_index()
		remove_marker(active_chain.current_cell())
		if active_chain.advance():
			_status.call("%s segment %d/%d skipped" % [
				active_chain.display_name, skipped_index, active_chain.segment_count(),
			])
			advance_chain()
		else:
			_status.call("%s wall complete; final segment skipped" % active_chain.display_name)
			_end_chain()
		return
	if placed != BuildingPlacementScript.PlaceResult.PLACED:
		_refund(completed_order)
		_status.call("%s segment could not be placed; wall chain stopped" % active_chain.display_name)
		_placement.cancel()
		_end_chain()
		return
	remove_marker(active_chain.current_cell())
	if active_chain.advance():
		_status.call("%s segment %d/%d placed" % [
			active_chain.display_name,
			active_chain.segment_index() - 1,
			active_chain.segment_count(),
		])
		advance_chain()
	else:
		_status.call("%s wall complete" % active_chain.display_name)
		_end_chain()


func refund_order(order) -> void:
	_refund(order)


func cancel_chain() -> void:
	_end_chain()


func _segment_availability(active_chain) -> int:
	var config: Resource = _config_provider.call(active_chain.building_id)
	var rows: Array[String] = _rows_provider.call(config)
	if not _placement.begin(
		active_chain.building_id, active_chain.display_name, rows, true
	):
		return BuildingPlacementScript.PlaceResult.INACTIVE
	var result: int = _placement.evaluate_at_hover_cell(active_chain.current_cell())
	_placement.cancel()
	return result


func _refund(order) -> void:
	if order == null or order.paid_cost <= 0:
		return
	var player = _player_provider.call()
	if player != null:
		player.add_money(order.paid_cost)


func _end_chain() -> void:
	_chain = null
	clear_markers()
	_refresh.call()


func start_cell():
	return _start_cell


func set_start_cell(value) -> void:
	_start_cell = value


func current_building_id() -> StringName:
	return _building_id


func set_building_id(value: StringName) -> void:
	_building_id = value


func chain():
	return _chain


func set_chain(value) -> void:
	_chain = value


func markers() -> Dictionary:
	return _markers


func set_marker_scene(value: PackedScene) -> void:
	_marker_scene = value
