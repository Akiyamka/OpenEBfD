class_name WallLineSession
extends RefCounted

const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const WallLineScript := preload("res://scripts/buildings/wall_line.gd")
const WallChainScript := preload("res://scripts/buildings/wall_chain.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")

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


## The second click no longer previews, reads the preview's anchor cells, or
## locks markers -- see this file's header comment and SimWallLineCommand's
## doc comment (scripts/sim/commands/wall_line_command.gd) for why the
## buildable set must not be captured here, at click time, and carried on the
## wire. start_chain_callback now receives only (start_cell, end_cell,
## building_id): BuildingController._finish_wall_selection() submits those
## three as a SimWallLineCommand, and start_chain() below recomputes the
## buildable set itself when that command executes.
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
	start_chain_callback.call(start, cell, _building_id)


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


## No longer takes the preview's buildable-cell snapshot: it computes the set
## itself, right here, against the map as it stands on the tick this runs --
## see this file's header comment and SimWallLineCommand's doc comment
## (scripts/sim/commands/wall_line_command.gd) for why a click-time snapshot
## is stale by construction (segments are ordered one at a time over many
## seconds) and must not be authoritative. The filter below runs every
## candidate cell through _evaluate_cell_availability() -- the same
## begin() -> evaluate_at_hover_cell() -> cancel() bracket
## _segment_availability() uses per segment -- so "is this cell buildable" has
## exactly one answer anywhere in this file.
func start_chain(
		from_nav_cell: Vector2i,
		to_nav_cell: Vector2i,
		order_building_id: StringName
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
	var display_name: String = _display_provider.call(order_building_id)
	var cells: Array[Vector2i] = []
	for cell in nav_cells_between(from_nav_cell, to_nav_cell):
		var availability := _evaluate_cell_availability(order_building_id, display_name, cell)
		if availability == BuildingPlacementScript.PlaceResult.AVAILABLE:
			cells.append(cell)
	if cells.is_empty():
		_status.call("Wall line has no buildable segments")
		_end_chain()
		return
	lock_markers(cells)
	var line_start_world_position: Vector3 = _placement.wall_marker_world_position(cells[0])
	# Two different owners are in play here and they are not interchangeable:
	# _player_provider answers the local PlayerData (what _refund() spends from),
	# while the chain needs the roster's local_player_id. Collapsing them into one
	# provider is what crashed -- PlayerData has player_id, not local_player_id.
	var owner_id = _owner_id_provider.call() if not _owner_id_provider.is_null() else null
	_chain = WallChainScript.new(
		order_building_id, display_name,
		maxi(config.cost, 0), RuleTicksScript.order_sim_ticks(config.build_time_ticks), cells, owner_id
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
	return _evaluate_cell_availability(
		active_chain.building_id, active_chain.display_name, active_chain.current_cell()
	)


## The one begin() -> evaluate_at_hover_cell() -> cancel() bracket that
## answers "is `cell` buildable for `building_id` right now" -- shared by
## _segment_availability() above (the per-segment recheck advance_chain() does
## before ordering each cell) and start_chain()'s own line filter (the
## whole-line recheck done once, at execution, before committing to a chain).
## See BuildingPlacement.evaluate_at_hover_cell()'s doc comment for why this
## is cheap enough to call once per candidate cell: it draws nothing.
func _evaluate_cell_availability(
		building_id: StringName, display_name: String, cell: Vector2i
) -> int:
	var config: Resource = _config_provider.call(building_id)
	var rows: Array[String] = _rows_provider.call(config)
	if not _placement.begin(building_id, display_name, rows, true):
		return BuildingPlacementScript.PlaceResult.INACTIVE
	var result: int = _placement.evaluate_at_hover_cell(cell)
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
