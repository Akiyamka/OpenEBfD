class_name MapSpiceLayer
extends RefCounted
const TerrainProbeScript := preload("res://scripts/world/terrain_probe.gd")

## Mutable runtime state for the map's resource fields. Values are byte-density
## units from the XBF map, not player credits or harvester cargo units.

signal spice_changed(cell: Vector2i, previous: int, current: int)
signal spice_mound_changed(cell: Vector2i, present: bool)
signal spice_mound_activated(source_cell: Vector2i, early_activation: bool, world_position: Vector3)
signal spice_spread_stage(source_cell: Vector2i, stage: int, stage_count: int, changed_cells: int)
signal spice_spread_finished(source_cell: Vector2i)

const SPICE_MOUND_SCENE := preload("res://scenes/world/spice_mound.tscn")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")
const MapSpiceHazardScript := preload("res://scripts/world/map/map_spice_hazard.gd")
const MapSpiceSpreadScript := preload("res://scripts/world/map/map_spice_spread.gd")
const MapSpiceRenderScript := preload("res://scripts/world/map/map_spice_render.gd")

var world_bounds := AABB()

var _navigation_grid: MapNavigationGrid
var _spice_values := PackedByteArray()
var _spice_mounds := PackedByteArray()
var _source_grid_size := Vector2i.ZERO
var _terrain_grid_size := Vector2i.ZERO
var _terrain_mesh: MeshInstance3D
var _spice_mounds_root: Node3D
var _spice_mound_nodes: Dictionary = {}
var _hazard := MapSpiceHazardScript.new()
var _spread := MapSpiceSpreadScript.new()
var _render := MapSpiceRenderScript.new()


func _init() -> void:
	_hazard.configure(self)
	_spread.configure(self)


func load_baked(data: BakedMapData, navigation_grid: MapNavigationGrid, terrain_mesh: MeshInstance3D = null) -> bool:
	var total := MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE
	if data == null or navigation_grid == null or not navigation_grid.is_loaded():
		push_error("MapSpiceLayer: baked map and a loaded navigation grid are required")
		return false
	if data.nav_spice_value.size() != total:
		push_error("MapSpiceLayer: baked spice grid has invalid size in %s" % data.resource_path)
		return false

	_navigation_grid = navigation_grid
	world_bounds = navigation_grid.world_bounds
	_spice_values = data.nav_spice_value.duplicate()
	_navigation_grid.spice_value = _spice_values

	_spice_mounds.resize(total)
	_spice_mounds.fill(0)
	_source_grid_size = data.nav_report.get("source_spice_grid_size", Vector2i.ZERO)
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		_source_grid_size = data.nav_report.get("source_grid_size", Vector2i.ZERO)
	_terrain_grid_size = data.nav_report.get("source_grid_size", _source_grid_size)
	if _terrain_grid_size.x <= 0 or _terrain_grid_size.y <= 0:
		_terrain_grid_size = _source_grid_size
	_load_spice_mounds(data.spice_mound_cells)
	_render.build(_spice_values, _spice_mounds)
	_terrain_mesh = terrain_mesh
	_render.bind_terrain_materials(terrain_mesh, world_bounds)
	_spawn_spice_mounds(data.spice_mound_cells)
	return true


func spice_at(cell: Vector2i) -> int:
	var index := _cell_index(cell)
	return _spice_values[index] if index >= 0 else 0


func has_spice(cell: Vector2i) -> bool:
	return spice_at(cell) > 0


## `candidate_filter` keeps automatic resource searches independent from map
## visibility. It currently defaults to accepting every non-empty cell; a
## player-specific fog-of-war service can later reject cells the owner cannot
## see without changing harvesting or spice storage APIs.
func nearest_spice_cell(
		origin: Vector2i,
		minimum_amount := 1,
		maximum_distance := -1,
		candidate_filter := Callable()
	) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_distance_squared := 0x7fffffff
	var maximum_distance_squared := maximum_distance * maximum_distance
	var size := MapNavigationGridScript.NAV_SIZE
	var minimum_x := 0
	var minimum_y := 0
	var maximum_x := size - 1
	var maximum_y := size - 1
	if maximum_distance >= 0:
		minimum_x = maxi(origin.x - maximum_distance, 0)
		minimum_y = maxi(origin.y - maximum_distance, 0)
		maximum_x = mini(origin.x + maximum_distance, size - 1)
		maximum_y = mini(origin.y + maximum_distance, size - 1)
	for y in range(minimum_y, maximum_y + 1):
		for x in range(minimum_x, maximum_x + 1):
			var cell := Vector2i(x, y)
			if _spice_values[y * size + x] < maxi(minimum_amount, 1):
				continue
			if candidate_filter.is_valid() and not bool(candidate_filter.call(cell)):
				continue
			var distance_squared := origin.distance_squared_to(cell)
			if maximum_distance >= 0 and distance_squared > maximum_distance_squared:
				continue
			if distance_squared < best_distance_squared:
				best = cell
				best_distance_squared = distance_squared
	return best


func set_spice(cell: Vector2i, amount: int) -> bool:
	var index := _cell_index(cell)
	if index < 0:
		return false
	var clamped := clampi(amount, 0, 255)
	var previous := int(_spice_values[index])
	if previous == clamped:
		return true
	_spice_values[index] = clamped
	_navigation_grid.spice_value[index] = clamped
	_render.set_spice_cell(cell, clamped)
	_render.flush_spice()
	spice_changed.emit(cell, previous, clamped)
	return true


func take_spice(cell: Vector2i, requested: int) -> int:
	if requested <= 0:
		return 0
	var available := spice_at(cell)
	var taken := mini(available, requested)
	if taken > 0:
		set_spice(cell, available - taken)
	return taken


func add_spice(cell: Vector2i, amount: int) -> int:
	if amount <= 0 or _cell_index(cell) < 0:
		return 0
	var previous := spice_at(cell)
	var current := mini(previous + amount, 255)
	if current > previous:
		set_spice(cell, current)
	return current - previous


## Adds spice to many cells at once, from entries shaped {cell, amount}, and
## returns how many actually gained any. One mask upload and one composite
## refresh cover the whole batch -- a spread ring goes through here rather than
## through add_spice(), which would re-upload the texture per cell -- and the
## per-cell signals follow once the grid is fully written, so no listener sees
## a half-applied ring.
func add_spice_batch(entries: Array) -> int:
	var changes: Array[Dictionary] = []
	for entry: Dictionary in entries:
		var cell := entry.get("cell", Vector2i(-1, -1)) as Vector2i
		var index := _cell_index(cell)
		var amount := int(entry.get("amount", 0))
		if index < 0 or amount <= 0:
			continue
		var previous := int(_spice_values[index])
		var current := mini(previous + amount, 255)
		if current == previous:
			continue
		_spice_values[index] = current
		_navigation_grid.spice_value[index] = current
		_render.set_spice_cell(cell, current)
		changes.append({"cell": cell, "previous": previous, "current": current})

	if not changes.is_empty():
		_render.flush_spice()
		for change: Dictionary in changes:
			spice_changed.emit(change["cell"], change["previous"], change["current"])
	return changes.size()


func has_spice_mound(cell: Vector2i) -> bool:
	var index := _cell_index(cell)
	return index >= 0 and _spice_mounds[index] != 0


func set_spice_mound(cell: Vector2i, present: bool) -> bool:
	if _cell_index(cell) < 0:
		return false
	return _set_source_spice_mound(_nav_to_source_cell(cell), present)


func _set_source_spice_mound(source_cell: Vector2i, present: bool) -> bool:
	if not _source_cell_is_valid(source_cell):
		return false
	var value := 255 if present else 0
	var rect := _source_cell_nav_rect(source_cell)
	var changed := false
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var index := _cell_index(Vector2i(x, y))
			if _spice_mounds[index] == value:
				continue
			_spice_mounds[index] = value
			_render.set_mound_cell(Vector2i(x, y), value)
			changed = true
	if not changed:
		return true
	_render.flush_mounds()
	if present:
		_spawn_spice_mound(source_cell)
	else:
		_remove_spice_mound(source_cell)
	spice_mound_changed.emit(rect.position, present)
	return true


func spice_mask_texture() -> ImageTexture:
	return _render.spice_mask_texture()


func spice_mound_mask_texture() -> ImageTexture:
	return _render.mound_mask_texture()


## Advances both timed spice systems by one simulation tick. Called from
## Match._advance_simulation_tick() -- see its doc comment for why this is a
## direct call on an owned system rather than a group loop like units,
## buildings, linger effects and mounds.
##
## Spread before hazard, and that is a data dependency rather than a
## preference: a spread ring seeds the very cells the hazard damages
## (MapSpiceSpread.start() hands its planned cells straight to
## MapSpiceHazard.start()), so releasing the ring first means the pulse that
## covers it always sees this tick's ground, never the previous tick's.
func sim_tick() -> void:
	_spread.sim_tick()
	_hazard.sim_tick()


func detach_visuals() -> void:
	_spread.cancel_all()
	_hazard.cancel_all()
	_render.detach()
	if is_instance_valid(_spice_mounds_root):
		_spice_mounds_root.free()
	_spice_mounds_root = null
	_spice_mound_nodes.clear()


func _load_spice_mounds(source_cells: Array[Vector2i]) -> void:
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		return
	for source_cell in source_cells:
		if source_cell.x < 0 or source_cell.y < 0 or source_cell.x >= _source_grid_size.x or source_cell.y >= _source_grid_size.y:
			push_warning("MapSpiceLayer: spice mound cell %s is outside source grid %s" % [source_cell, _source_grid_size])
			continue
		var rect := _source_cell_nav_rect(source_cell)
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				_spice_mounds[y * MapNavigationGridScript.NAV_SIZE + x] = 255


func _spawn_spice_mounds(source_cells: Array[Vector2i]) -> void:
	if _terrain_mesh == null or source_cells.is_empty():
		return
	_ensure_spice_mounds_root()
	for source_cell in source_cells:
		_spawn_spice_mound(source_cell)


func _spawn_spice_mound(source_cell: Vector2i) -> void:
	if _terrain_mesh == null or not _source_cell_is_valid(source_cell) or _spice_mound_nodes.has(source_cell):
		return
	_ensure_spice_mounds_root()
	var world_rect := _source_cell_world_rect(source_cell)
	var center := world_rect.get_center()
	var mound: Variant = SPICE_MOUND_SCENE.instantiate()
	mound.name = "SpiceMound_%d_%d" % [source_cell.x, source_cell.y]
	mound.configure(source_cell, world_rect.size)
	mound.activated.connect(_on_spice_mound_activated.bind(source_cell))
	_spice_mounds_root.add_child(mound)
	mound.global_position = Vector3(center.x, _terrain_height_at(center), center.y)
	_spice_mound_nodes[source_cell] = mound


func _remove_spice_mound(source_cell: Vector2i) -> void:
	_hazard.cancel(source_cell)
	var mound: Variant = _spice_mound_nodes.get(source_cell)
	_spice_mound_nodes.erase(source_cell)
	if is_instance_valid(mound):
		mound.queue_free()


func _ensure_spice_mounds_root() -> void:
	if is_instance_valid(_spice_mounds_root) or _terrain_mesh == null:
		return
	_spice_mounds_root = Node3D.new()
	_spice_mounds_root.name = "SpiceMounds"
	_spice_mounds_root.set_as_top_level(true)
	_terrain_mesh.add_child(_spice_mounds_root)
	_spice_mounds_root.global_transform = Transform3D.IDENTITY


func _on_spice_mound_activated(
	mound: Variant,
	early_activation: bool,
	maturity_fraction: float,
	source_cell: Vector2i
) -> void:
	if _spice_mound_nodes.get(source_cell) != mound:
		return
	spice_mound_activated.emit(source_cell, early_activation, mound.global_position)
	_spread.start(source_cell, mound.config, maturity_fraction)


## Subsystem access for MapSpiceHazard and MapSpiceSpread: where the bloom's
## mound is, where their timers may be parented, and how the map's three grids
## relate. Narrow on purpose -- neither module touches the spice values or the
## textures directly, they go through add_spice_batch() and the emitters below,
## so the signals stay on the layer everyone is already connected to.
func mound_node(source_cell: Vector2i) -> Variant:
	return _spice_mound_nodes.get(source_cell)


func mounds_root() -> Node3D:
	return _spice_mounds_root


func nav_grid() -> MapNavigationGrid:
	return _navigation_grid


func terrain_height_at(world_xz: Vector2) -> float:
	return _terrain_height_at(world_xz)


func cell_is_valid(cell: Vector2i) -> bool:
	return _cell_index(cell) >= 0


func source_grid_size() -> Vector2i:
	return _source_grid_size


func terrain_grid_size() -> Vector2i:
	return _terrain_grid_size


func source_cell_is_valid(source_cell: Vector2i) -> bool:
	return _source_cell_is_valid(source_cell)


func is_passable_sand(cell: Vector2i) -> bool:
	return _is_passable_sand(cell)


## Both subsystems report through the layer's own signals rather than declaring
## their own, so a listener keeps one connection to the spice layer regardless
## of which part of it did the work.
func emit_spread_stage(source_cell: Vector2i, stage: int, stage_count: int, changed_cells: int) -> void:
	spice_spread_stage.emit(source_cell, stage, stage_count, changed_cells)


func emit_spread_finished(source_cell: Vector2i) -> void:
	spice_spread_finished.emit(source_cell)


## The two subsystems, exposed for tests/maps/run.gd and for each other -- a
## spread raises the hazard over the cells it seeded.
##
## Left unannotated on purpose: both modules name MapSpiceLayer as the type of
## their owner, so naming them back here closes a class cycle the parser
## refuses to resolve.
func hazard():
	return _hazard


func spread():
	return _spread


func _is_passable_sand(cell: Vector2i) -> bool:
	return _navigation_grid != null \
		and _navigation_grid.terrain_at(cell) == MapNavigationGridScript.TERRAIN_SAND \
		and _navigation_grid.is_passable(cell, MapNavigationGridScript.PASS_GROUND)


static func _spread_candidate_less(left: Dictionary, right: Dictionary) -> bool:
	var left_distance := float(left.get("distance_tiles", 0.0))
	var right_distance := float(right.get("distance_tiles", 0.0))
	if not is_equal_approx(left_distance, right_distance):
		return left_distance < right_distance
	var left_cell := left.get("cell", Vector2i.ZERO) as Vector2i
	var right_cell := right.get("cell", Vector2i.ZERO) as Vector2i
	return left_cell.y < right_cell.y or (left_cell.y == right_cell.y and left_cell.x < right_cell.x)


func _source_cell_world_rect(source_cell: Vector2i) -> Rect2:
	var start := Vector2(
		world_bounds.position.x + float(source_cell.x) / float(_source_grid_size.x) * world_bounds.size.x,
		world_bounds.position.z + float(source_cell.y) / float(_source_grid_size.y) * world_bounds.size.z
	)
	var end := Vector2(
		world_bounds.position.x + float(source_cell.x + 1) / float(_source_grid_size.x) * world_bounds.size.x,
		world_bounds.position.z + float(source_cell.y + 1) / float(_source_grid_size.y) * world_bounds.size.z
	)
	return Rect2(start, end - start)


func _terrain_height_at(world_xz: Vector2) -> float:
	if _terrain_mesh == null or not _terrain_mesh.is_inside_tree():
		return world_bounds.position.y
	var top := world_bounds.end.y + 200.0
	var bottom := world_bounds.position.y - 200.0
	var hit := TerrainProbeScript.cast(
		_terrain_mesh.get_world_3d(),
		Vector3(world_xz.x, top, world_xz.y),
		Vector3(world_xz.x, bottom, world_xz.y),
		1
	)
	return (hit.get("position", Vector3(0.0, world_bounds.position.y, 0.0)) as Vector3).y


func _mound_nav_rect(cell: Vector2i) -> Rect2i:
	if _source_grid_size.x <= 0 or _source_grid_size.y <= 0:
		return Rect2i(cell, Vector2i.ONE)
	return _source_cell_nav_rect(_nav_to_source_cell(cell))


func _nav_to_source_cell(cell: Vector2i) -> Vector2i:
	var nav_size := MapNavigationGridScript.NAV_SIZE
	return Vector2i(
		clampi(int(float(cell.x) / nav_size * _source_grid_size.x), 0, _source_grid_size.x - 1),
		clampi(int(float(cell.y) / nav_size * _source_grid_size.y), 0, _source_grid_size.y - 1)
	)


func _source_cell_nav_rect(source_cell: Vector2i) -> Rect2i:
	var nav_size := MapNavigationGridScript.NAV_SIZE
	var start := Vector2i(
		int(floor(float(source_cell.x) / float(_source_grid_size.x) * nav_size)),
		int(floor(float(source_cell.y) / float(_source_grid_size.y) * nav_size))
	)
	var end := Vector2i(
		int(ceil(float(source_cell.x + 1) / float(_source_grid_size.x) * nav_size)),
		int(ceil(float(source_cell.y + 1) / float(_source_grid_size.y) * nav_size))
	)
	return Rect2i(start, end - start)


func _source_cell_is_valid(source_cell: Vector2i) -> bool:
	return source_cell.x >= 0 and source_cell.y >= 0 \
		and source_cell.x < _source_grid_size.x and source_cell.y < _source_grid_size.y


## The spice arrays are indexed exactly like the navigation grid's own, so the
## grid owns this mapping. Before load_baked() there is no grid and no spice
## either, hence -1.
func _cell_index(cell: Vector2i) -> int:
	return _navigation_grid.cell_index(cell) if _navigation_grid != null else -1
