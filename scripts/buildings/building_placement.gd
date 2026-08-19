class_name BuildingPlacement
extends Node3D

const TerrainProbeScript := preload("res://scripts/world/terrain_probe.gd")
const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")
const BuildingConstructionSoundScript := preload(
	"res://scripts/buildings/building_construction_sound.gd"
)

signal building_placed(building: Node3D)

enum PlaceResult {
	PLACED,
	INACTIVE,
	NEEDS_TERRAIN,
	CANNOT_BUILD,
	INVALID_SCENE,
	MISSING_BUILDINGS_ROOT,
	AVAILABLE,
}

const NAV_CELLS_PER_OCCUPY_CELL := 2
const CELL_SURFACE_OFFSET := 0.06
const INVALID_ANCHOR := Vector2i(-999999, -999999)
const QUARTER_TURN_RADIANS := PI * 0.5

const UnitPushAsideScript := preload("res://scripts/buildings/unit_push_aside.gd")
const BuildRadiusScript := preload("res://scripts/buildings/build_radius.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")
const PlacementContextScript := preload("res://scripts/buildings/placement_context.gd")
const OccupyGridScript := preload("res://scripts/buildings/occupy_grid.gd")
const PlacementMaterialsScript := preload("res://scripts/buildings/placement_materials.gd")

var _camera: Camera3D
var _navigation_grid
var _buildings_root: Node3D
var _arrow_scene: PackedScene
var _building_preview_scene: PackedScene
var _cant_build_preview_scene: PackedScene
var _skirt_preview_scene: PackedScene
var _existing_building_occupy_rows: Callable
var _existing_building_is_wall: Callable
var _build_radius_provider: Callable
var _placement_owner_player_id_provider: Callable

var _building_id: StringName = &""
var _display_name := ""
var _source_occupy_rows: Array[String] = []
var _occupy_rows: Array[String] = []
var _rotation_quarter_turns := 0
var _anchor_cell := INVALID_ANCHOR
var _preview_anchor_cells: Array[Vector2i] = []
var _available_preview_anchor_cells: Array[Vector2i] = []
var _preview_cells_by_grid_cell: Dictionary = {}
var _preview_arrow: Node3D
var _has_anchor := false
var _can_build := false
var _is_wall_candidate := false
var _skip_build_radius_check := false

# _occupied_building_nav_cells() answers from map-wide building state, so this
# cache used to be `static var` shared by every BuildingPlacement, with
# SceneTree.node_added/node_removed subscriptions that were never disconnected
# -- shared mutable state plus a leak, and a source of cross-test coupling in
# headless runs where the scene is rebuilt. It is per-instance now, and
# _exit_tree() unsubscribes.
#
# The tradeoff that buys, spelled out because the static version existed for a
# reason: the per-frame consumer (_rebuild_preview_for_anchors, which reads
# this every frame while a placement preview is live) keeps its cache, because
# that BuildingPlacement lives for the whole placement session. The one
# consumer that loses caching is UnitDeploymentController._deployment_candidate,
# which builds a throwaway BuildingPlacement per call and frees it -- so it now
# rescans instead of reusing a valid cache. That path is throttled to
# DEPLOYMENT_CURSOR_CHECK_INTERVAL_MSEC (1000 ms, unit_command_controller.gd)
# and only runs while the pointer is over a selected MCV, so it is one scan a
# second, not a per-frame cost.
var _occupied_cells_cache: Dictionary = {}
var _occupied_cells_cache_valid := false
var _occupied_cells_tracking_started := false


func setup(context: PlacementContextScript) -> void:
	_camera = context.camera
	_navigation_grid = context.navigation_grid
	_buildings_root = context.buildings_root
	_arrow_scene = context.arrow_scene
	_building_preview_scene = context.building_preview_scene
	_cant_build_preview_scene = context.cant_build_preview_scene
	_skirt_preview_scene = context.skirt_preview_scene
	_existing_building_occupy_rows = context.existing_building_occupy_rows
	_existing_building_is_wall = context.existing_building_is_wall
	_build_radius_provider = context.build_radius_provider
	_placement_owner_player_id_provider = context.owner_player_id_provider
	name = "BuildingPlacementPreview"
	_occupied_cells_cache_valid = false


func _exit_tree() -> void:
	if not _occupied_cells_tracking_started:
		return
	var tree := get_tree()
	if tree != null:
		if tree.node_added.is_connected(_on_occupied_cells_tracked_node_added):
			tree.node_added.disconnect(_on_occupied_cells_tracked_node_added)
		if tree.node_removed.is_connected(_on_occupied_cells_tracked_node_removed):
			tree.node_removed.disconnect(_on_occupied_cells_tracked_node_removed)
	_occupied_cells_tracking_started = false
	_occupied_cells_cache.clear()
	_occupied_cells_cache_valid = false


## skip_build_radius_check exists for the future MCV deploy flow (docs/mechanics/production.md
## section 1 "MCV"): deploying an MCV into a Construction Yard is the one case that must bypass
## the build radius check. Every other call site (the normal building/wall order flow) leaves it
## at the default and is subject to the check.
func begin(
		building_id: StringName,
		building_display_name: String,
		occupy_rows: Array[String],
		is_wall: bool = false,
		skip_build_radius_check: bool = false
	) -> bool:
	if building_id == &"" or not _has_occupy_cells(occupy_rows):
		return false

	_clear()
	_building_id = building_id
	_display_name = building_display_name
	_source_occupy_rows = occupy_rows.duplicate()
	_occupy_rows = _source_occupy_rows.duplicate()
	_rotation_quarter_turns = 0
	_is_wall_candidate = is_wall
	_skip_build_radius_check = skip_build_radius_check
	visible = false
	return true


func process(pointer_position: Vector2) -> void:
	if not is_active():
		return
	var hover_cell = _hover_cell_from_pointer(pointer_position)
	if hover_cell == null:
		_hide_preview()
		return
	_update_for_hover_cell(hover_cell)


## Draws the same placement footprint at every supplied hover cell. Wall-line
## selection uses this to preview all segments between its A/B points at once.
func preview_at_hover_cells(hover_cells: Array[Vector2i]) -> void:
	if not is_active():
		return
	if hover_cells.is_empty():
		_hide_preview()
		return

	var anchor_cells: Array[Vector2i] = []
	for hover_cell in hover_cells:
		var anchor_cell := _anchor_for_hover_cell(hover_cell)
		if not anchor_cells.has(anchor_cell):
			anchor_cells.append(anchor_cell)
	if visible and anchor_cells == _preview_anchor_cells:
		return
	visible = true
	_anchor_cell = anchor_cells[0]
	_preview_anchor_cells = anchor_cells
	_has_anchor = true
	_rebuild_preview_for_anchors(anchor_cells)


func available_preview_anchor_cells() -> Array[Vector2i]:
	return _available_preview_anchor_cells.duplicate()


func wall_marker_world_position(anchor_cell: Vector2i) -> Vector3:
	return (
		_snap_to_ground(_occupy_cell_world_center(anchor_cell))
		+ Vector3.UP * CELL_SURFACE_OFFSET
	)


## Faces the building's local +Z exit toward the dominant grid direction from
## the press point to the cursor. Returns true only when this call performs an
## actual 90-degree turn, so the controller can distinguish a rotation gesture
## from the later click that confirms placement.
func face_toward_pointer(press_position: Vector2, pointer_position: Vector2) -> bool:
	var press_cell = _hover_cell_from_pointer(press_position)
	var pointer_cell = _hover_cell_from_pointer(pointer_position)
	if press_cell == null or pointer_cell == null:
		return false
	return face_toward_cells(press_cell, pointer_cell)


func face_toward_cells(press_cell: Vector2i, pointer_cell: Vector2i) -> bool:
	if not is_active():
		return false
	var delta := pointer_cell - press_cell
	if delta == Vector2i.ZERO:
		return false

	var quarter_turns := 0
	if absi(delta.x) > absi(delta.y):
		quarter_turns = 1 if delta.x > 0 else 3
	elif delta.y < 0:
		quarter_turns = 2
	return _set_rotation_quarter_turns(quarter_turns)


func rotation_quarter_turns() -> int:
	return _rotation_quarter_turns


func set_rotation_quarter_turns(value: int) -> void:
	_set_rotation_quarter_turns(value)


## Performs the same terrain/footprint/occupancy check as try_place without
## spawning anything. MCV deployment uses this before committing the unit to
## its animation, then rechecks at the handoff in case the site changed.
##
## Pure: builds, frees, or reveals no preview node. WallLineSession
## (scripts/buildings/wall_line_session.gd:293 _segment_availability) calls
## this on the simulation tick, once per wall segment, on every client -- most
## of which have no cursor anywhere near this placement -- so it cannot pay
## for drawing a preview no one will see. See _evaluate_anchor() below for the
## verdict logic this and the drawing path (_rebuild_preview_for_anchors())
## both read from.
func evaluate_at_hover_cell(hover_cell: Vector2i) -> PlaceResult:
	if not is_active():
		return PlaceResult.INACTIVE
	# The only source of NEEDS_TERRAIN: _update_for_hover_cell() reaches
	# _hide_preview() (which clears _has_anchor) solely for this condition --
	# every other path it takes funnels into _can_build instead.
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return PlaceResult.NEEDS_TERRAIN
	var anchor_cell := _anchor_for_hover_cell(hover_cell)
	var evaluation := _evaluate_anchor_at(anchor_cell)
	return PlaceResult.AVAILABLE if bool(evaluation["can_build"]) else PlaceResult.CANNOT_BUILD


func try_place(pointer_position: Vector2, building_scene: PackedScene, owner_player_id = null) -> PlaceResult:
	if not is_active():
		return PlaceResult.INACTIVE
	var hover_cell = _hover_cell_from_pointer(pointer_position)
	if hover_cell == null:
		_hide_preview()
		return PlaceResult.NEEDS_TERRAIN
	return try_place_at_hover_cell(hover_cell, building_scene, owner_player_id)


func try_place_at_hover_cell(
		hover_cell: Vector2i,
		building_scene: PackedScene,
		owner_player_id = null,
		excluded_unit: Node3D = null
	) -> PlaceResult:
	if not is_active():
		return PlaceResult.INACTIVE
	# Uses the pure evaluation rather than _update_for_hover_cell(): a click
	# does not need a preview built for the cell it is about to leave (on
	# PLACED, _clear() below removes it anyway) or bail out of (below) -- see
	# _evaluate_anchor()'s doc comment. NEEDS_TERRAIN replicates
	# _update_for_hover_cell()'s _hide_preview() call for the same condition
	# exactly, so an early return here leaves the object in the same state.
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		_hide_preview()
		return PlaceResult.NEEDS_TERRAIN
	var anchor_cell := _anchor_for_hover_cell(hover_cell)
	var evaluation := _evaluate_anchor_at(anchor_cell)
	# Matches the bookkeeping _update_for_hover_cell() would have set for this
	# anchor; only the preview nodes it would also have built are skipped.
	visible = true
	_anchor_cell = anchor_cell
	_preview_anchor_cells.assign([anchor_cell])
	_has_anchor = true
	_can_build = bool(evaluation["can_build"])
	if not _can_build:
		return PlaceResult.CANNOT_BUILD
	if building_scene == null:
		return PlaceResult.INVALID_SCENE
	var building := building_scene.instantiate() as Node3D
	if building == null:
		return PlaceResult.INVALID_SCENE
	if _buildings_root == null:
		building.free()
		return PlaceResult.MISSING_BUILDINGS_ROOT

	if building.has_method("setup"):
		building.call("setup", _building_id)
	building.rotate_y(float(_rotation_quarter_turns) * QUARTER_TURN_RADIANS)
	_buildings_root.add_child(building)
	var placement_position := _snap_to_ground(_world_center(_anchor_cell))
	if building.is_inside_tree():
		building.global_position = placement_position
	else:
		building.position = placement_position
	building.set_meta(&"placement_anchor_cell", _anchor_cell)
	if owner_player_id != null and building.has_method("set_owner_player_id"):
		building.call("set_owner_player_id", owner_player_id)
	_push_units_out_of_footprint(_anchor_cell, excluded_unit)
	var is_wall_segment := _is_wall_candidate
	building_placed.emit(building)
	_play_placed_building_animation(building)
	_clear()
	# Wall segments confirm the whole line with one WallThud when the line is
	# drawn (see WallLineSession.start_chain / play_wall_line_start_thud)
	# rather than per segment here.
	if not is_wall_segment:
		_play_placement_thud(placement_position, &"BuildingThud")
	return PlaceResult.PLACED


func cancel() -> String:
	var canceled_name := _display_name
	_clear()
	return canceled_name


func is_active() -> bool:
	return _building_id != &"" and not _occupy_rows.is_empty()


func display_name() -> String:
	return _display_name


## Public so callers that need a raw grid cell from a click without an active
## placement (e.g. the wall line A/B picker) can reuse the same raycast path.
func hover_cell_from_pointer(pointer_position: Vector2):
	return _hover_cell_from_pointer(pointer_position)


func _hover_cell_from_pointer(pointer_position: Vector2):
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return null
	var hit := _raycast(pointer_position, 1)
	if hit.is_empty():
		return null
	return _navigation_grid.world_to_grid(hit["position"])


func _push_units_out_of_footprint(anchor_cell: Vector2i, excluded_unit: Node3D = null) -> void:
	if not is_inside_tree() or _navigation_grid == null:
		return
	var units := get_tree().get_nodes_in_group("units").filter(
		func(unit: Node) -> bool: return unit != excluded_unit
	)
	if units.is_empty():
		return

	var footprint_size := _nav_size()
	var start: Vector3 = _navigation_grid.grid_to_world(anchor_cell, false)
	var end: Vector3 = _navigation_grid.grid_to_world(anchor_cell + footprint_size, false)
	var cell_step: Vector3 = (
		_navigation_grid.grid_to_world(Vector2i(1, 0), false)
		- _navigation_grid.grid_to_world(Vector2i.ZERO, false)
	)
	var margin := maxf(cell_step.length(), 0.1)
	UnitPushAsideScript.push_units_out_of_footprint(units, start, end, margin)


func _update_for_hover_cell(hover_cell: Vector2i) -> void:
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		_hide_preview()
		return
	var anchor_cell := _anchor_for_hover_cell(hover_cell)
	if _has_anchor and _preview_anchor_cells == [anchor_cell] and visible:
		return

	visible = true
	_anchor_cell = anchor_cell
	_preview_anchor_cells.assign([anchor_cell])
	_has_anchor = true
	_rebuild_preview(anchor_cell)


func _rebuild_preview(anchor_cell: Vector2i) -> void:
	_rebuild_preview_for_anchors([anchor_cell])


## The inputs _evaluate_anchor() needs beyond the anchor cell itself, gathered
## once per call site rather than once per anchor. Building footprints are
## map-wide input shared by every segment of a wall-line preview or every
## per-tick availability check; scanning them per anchor made long wall lines
## increasingly expensive as the cursor moved.
func _current_build_radius_inputs() -> Dictionary:
	var radius_tiles := 0
	var existing_footprints: Array = []
	if not _skip_build_radius_check and not _build_radius_provider.is_null():
		radius_tiles = int(_build_radius_provider.call())
		if radius_tiles > 0:
			existing_footprints = _existing_building_footprints()
	return {
		"occupied_cells": _occupied_building_nav_cells(),
		"radius_tiles": radius_tiles,
		"existing_footprints": existing_footprints,
	}


## Convenience for the single-anchor verdict callers (evaluate_at_hover_cell,
## try_place_at_hover_cell): gathers this call's shared inputs once and
## evaluates the one anchor they care about.
func _evaluate_anchor_at(anchor_cell: Vector2i) -> Dictionary:
	var inputs := _current_build_radius_inputs()
	return _evaluate_anchor(
		anchor_cell, inputs["occupied_cells"], inputs["radius_tiles"], inputs["existing_footprints"]
	)


## Pure verdict for one anchor cell: whether its footprint has any occupy
## cells at all, whether every one of them is available, and the per-cell
## availability the drawing path needs to pick a red or green preview scene.
## Creates, frees, colours, and reparents nothing, and never touches
## visible/_preview_cells_by_grid_cell/_available_preview_anchor_cells/
## _can_build/_has_anchor/_anchor_cell/_preview_anchor_cells -- callers decide
## what, if anything, to draw from the verdict. This is what lets
## evaluate_at_hover_cell() run on the simulation tick without paying for a
## preview no one will see (see its doc comment).
func _evaluate_anchor(
		anchor_cell: Vector2i,
		occupied_cells: Dictionary,
		radius_tiles: int,
		existing_footprints: Array
	) -> Dictionary:
	var has_cells := false
	var can_build := true
	var available_by_grid_cell: Dictionary = {}
	# Checked once per anchor rather than per cell: it does not depend on the
	# individual occupy cell, and every cell's preview material must reflect
	# it, not just the aggregate can_build result.
	var within_radius := (
		_skip_build_radius_check
		or radius_tiles <= 0
		or BuildRadiusScript.is_within_radius(
			_footprint_nav_cells(anchor_cell),
			_is_wall_candidate,
			existing_footprints,
			radius_tiles
		)
	)
	for row_index in _occupy_rows.size():
		for column_index in _occupy_rows[row_index].length():
			var marker := _occupy_rows[row_index].substr(column_index, 1)
			if _is_empty_occupy_marker(marker):
				continue
			var grid_cell := anchor_cell + _occupy_offset_to_nav_cell(column_index, row_index)
			var available := _is_occupy_cell_buildable(grid_cell) \
				and _is_occupy_cell_unoccupied(grid_cell, occupied_cells) and within_radius
			has_cells = true
			can_build = can_build and available
			available_by_grid_cell[grid_cell] = available
	return {
		"has_cells": has_cells,
		"can_build": has_cells and can_build,
		"available_by_grid_cell": available_by_grid_cell,
	}


func _rebuild_preview_for_anchors(anchor_cells: Array[Vector2i]) -> void:
	var has_cells := false
	var can_build := true
	var inputs := _current_build_radius_inputs()
	var occupied_cells: Dictionary = inputs["occupied_cells"]
	var radius_tiles: int = inputs["radius_tiles"]
	var existing_footprints: Array = inputs["existing_footprints"]
	var next_preview_cells: Dictionary = {}
	var available_anchor_cells: Array[Vector2i] = []
	for anchor_index in anchor_cells.size():
		var anchor_cell := anchor_cells[anchor_index]
		var evaluation := _evaluate_anchor(anchor_cell, occupied_cells, radius_tiles, existing_footprints)
		var anchor_has_cells: bool = evaluation["has_cells"]
		var anchor_can_build: bool = evaluation["can_build"]
		var available_by_grid_cell: Dictionary = evaluation["available_by_grid_cell"]
		for row_index in _occupy_rows.size():
			for column_index in _occupy_rows[row_index].length():
				var cell := _preview_cell_for(
					anchor_cell, anchor_index, row_index, column_index,
					available_by_grid_cell, next_preview_cells
				)
				if not bool(cell.get("has_cell", false)):
					continue
				has_cells = true
				var grid_cell: Vector2i = cell["grid_cell"]
				var entry: Dictionary = cell.get("entry", {})
				if not entry.is_empty():
					if not next_preview_cells.has(grid_cell):
						next_preview_cells[grid_cell] = entry
		can_build = can_build and anchor_can_build
		if anchor_has_cells and anchor_can_build:
			available_anchor_cells.append(anchor_cell)

	for grid_cell in _preview_cells_by_grid_cell:
		if not next_preview_cells.has(grid_cell):
			var stale_entry: Dictionary = _preview_cells_by_grid_cell[grid_cell]
			_release_preview_cell(stale_entry.get("node") as Node3D)
	_preview_cells_by_grid_cell = next_preview_cells
	_available_preview_anchor_cells = available_anchor_cells

	_can_build = has_cells and can_build
	if has_cells and not _is_wall_candidate and not anchor_cells.is_empty():
		_add_arrow(anchor_cells[0])
	else:
		_remove_arrow()


func _preview_cell_for(
		anchor_cell: Vector2i,
		anchor_index: int,
		row_index: int,
		column_index: int,
		available_by_grid_cell: Dictionary,
		next_preview_cells: Dictionary
) -> Dictionary:
	var marker := _occupy_rows[row_index].substr(column_index, 1)
	if _is_empty_occupy_marker(marker):
		return {"has_cell": false}
	var grid_cell := anchor_cell + _occupy_offset_to_nav_cell(column_index, row_index)
	if next_preview_cells.has(grid_cell):
		return {
			"has_cell": true,
			"grid_cell": grid_cell,
			"entry": next_preview_cells[grid_cell],
		}
	var available := bool(available_by_grid_cell.get(grid_cell, false))
	var preview_scene := _preview_scene_for_marker(marker, available)
	var entry: Dictionary = _preview_cells_by_grid_cell.get(grid_cell, {})
	if preview_scene != null and entry.get("scene") != preview_scene:
		_release_preview_cell(entry.get("node") as Node3D)
		entry = _create_preview_cell(
			grid_cell,
			preview_scene,
			"Cell_%d_%d_%d_%s" % [anchor_index, column_index, row_index, marker]
		)
	return {
		"has_cell": true,
		"grid_cell": grid_cell,
		"entry": entry if preview_scene != null else {},
	}


func _create_preview_cell(
		grid_cell: Vector2i, preview_scene: PackedScene, preview_name: String
	) -> Dictionary:
	var preview_cell := preview_scene.instantiate() as Node3D
	if preview_cell == null:
		return {}
	preview_cell.name = preview_name
	_configure_preview_visuals(preview_cell)
	add_child(preview_cell)
	var preview_position := (
		_snap_to_ground(_occupy_cell_world_center(grid_cell))
		+ Vector3.UP * CELL_SURFACE_OFFSET
	)
	if preview_cell.is_inside_tree():
		preview_cell.global_position = preview_position
	else:
		preview_cell.position = preview_position
	return {"node": preview_cell, "scene": preview_scene}


func _release_preview_cell(preview_cell: Node3D) -> void:
	if preview_cell == null:
		return
	if preview_cell.get_parent() == self:
		remove_child(preview_cell)
	preview_cell.queue_free()


func _footprint_nav_cells(anchor_cell: Vector2i) -> Array[Vector2i]:
	return _occupy_rows_nav_cells(anchor_cell, _occupy_rows)


func _existing_building_footprints() -> Array:
	var footprints: Array = []
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return footprints

	var buildings: Array = []
	if is_inside_tree():
		buildings = get_tree().get_nodes_in_group("buildings")
	elif _buildings_root != null:
		buildings = _buildings_root.get_children()

	for node in buildings:
		var building := node as Node3D
		if building == null:
			continue
		if not _placement_owner_player_id_provider.is_null():
			var player_id := int(_placement_owner_player_id_provider.call())
			if not EntityQueryScript.is_owned_by(building, player_id):
				continue
		var occupy_rows: Array[String] = []
		if not _existing_building_occupy_rows.is_null():
			occupy_rows.assign(_existing_building_occupy_rows.call(building))
		if occupy_rows.is_empty():
			continue
		var is_wall := false
		if not _existing_building_is_wall.is_null():
			is_wall = bool(_existing_building_is_wall.call(building))
		var footprint_cells: Array = BuildingFootprintScript.nav_cells_by_marker(
			building, occupy_rows, _navigation_grid, NAV_CELLS_PER_OCCUPY_CELL
		).keys()
		footprints.append({
			"cells": footprint_cells,
			"bounds": BuildRadiusScript.bounds(footprint_cells),
			"is_wall": is_wall,
		})
	return footprints


func _occupy_rows_nav_cells(anchor_cell: Vector2i, occupy_rows: Array[String]) -> Array[Vector2i]:
	return OccupyGridScript.nav_cells(anchor_cell, occupy_rows, NAV_CELLS_PER_OCCUPY_CELL)


func _clear() -> void:
	_building_id = &""
	_display_name = ""
	_source_occupy_rows.clear()
	_occupy_rows.clear()
	_rotation_quarter_turns = 0
	_is_wall_candidate = false
	_skip_build_radius_check = false
	_anchor_cell = INVALID_ANCHOR
	_preview_anchor_cells.clear()
	_available_preview_anchor_cells.clear()
	_has_anchor = false
	_can_build = false
	visible = false
	_clear_preview_cells()


func _clear_preview_cells() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_preview_cells_by_grid_cell.clear()
	_preview_arrow = null


func _hide_preview() -> void:
	_anchor_cell = INVALID_ANCHOR
	_preview_anchor_cells.clear()
	_available_preview_anchor_cells.clear()
	_has_anchor = false
	_can_build = false
	visible = false


func _add_arrow(anchor_cell: Vector2i) -> void:
	if _arrow_scene == null:
		return
	if _preview_arrow == null:
		_preview_arrow = _arrow_scene.instantiate() as Node3D
		if _preview_arrow == null:
			return
		_preview_arrow.name = "CenterArrow"
		_configure_arrow_visuals(_preview_arrow)
		add_child(_preview_arrow)
	_preview_arrow.rotation = Vector3.ZERO
	_preview_arrow.rotate_y(float(_rotation_quarter_turns) * QUARTER_TURN_RADIANS)
	_preview_arrow.global_position = (
		_snap_to_ground(_world_center(anchor_cell)) + Vector3.UP * CELL_SURFACE_OFFSET
	)


func _remove_arrow() -> void:
	if _preview_arrow == null:
		return
	if _preview_arrow.get_parent() == self:
		remove_child(_preview_arrow)
	_preview_arrow.queue_free()
	_preview_arrow = null


func _set_rotation_quarter_turns(value: int) -> bool:
	var normalized := posmod(value, 4)
	if normalized == _rotation_quarter_turns:
		return false
	_rotation_quarter_turns = normalized
	_occupy_rows = _rotated_occupy_rows(_source_occupy_rows, normalized)
	# Rotation can swap footprint width/depth while the pointer remains in the
	# same cell, so force the next process() call to rebuild rather than taking
	# the unchanged-anchor fast path.
	_anchor_cell = INVALID_ANCHOR
	_preview_anchor_cells.clear()
	_available_preview_anchor_cells.clear()
	_has_anchor = false
	return true


func _rotated_occupy_rows(source_rows: Array[String], quarter_turns: int) -> Array[String]:
	var rows := source_rows.duplicate()
	for _turn in posmod(quarter_turns, 4):
		rows = _rotate_occupy_rows_counterclockwise(rows)
	return rows


func _rotate_occupy_rows_counterclockwise(rows: Array[String]) -> Array[String]:
	var rotated: Array[String] = []
	if rows.is_empty():
		return rotated
	var width := OccupyGridScript.width(rows)
	for new_row_index in width:
		var new_row := ""
		var source_column := width - 1 - new_row_index
		for source_row_index in rows.size():
			var source_row := rows[source_row_index]
			new_row += source_row.substr(source_column, 1) if source_column < source_row.length() else "."
		rotated.append(new_row)
	return rotated


func _configure_arrow_visuals(node: Node) -> void:
	PlacementMaterialsScript.configure_arrow(node)


func _configure_preview_visuals(node: Node) -> void:
	PlacementMaterialsScript.configure_preview(node)

func _anchor_for_hover_cell(hover_cell: Vector2i) -> Vector2i:
	var footprint_size := _occupy_size()
	var hover_occupy_cell := _nav_cell_to_occupy_cell(hover_cell)
	var anchor_occupy_cell := hover_occupy_cell - Vector2i(
		int(floor(float(footprint_size.x) * 0.5)), int(floor(float(footprint_size.y) * 0.5))
	)
	return _occupy_cell_to_nav_cell(anchor_occupy_cell)


func _occupy_size() -> Vector2i:
	return OccupyGridScript.size(_occupy_rows)


func _world_center(anchor_cell: Vector2i) -> Vector3:
	var footprint_size := _nav_size()
	var start: Vector3 = _navigation_grid.grid_to_world(anchor_cell, false)
	var end: Vector3 = _navigation_grid.grid_to_world(anchor_cell + footprint_size, false)
	return (start + end) * 0.5


func _nav_size() -> Vector2i:
	var occupy_size := _occupy_size()
	return Vector2i(
		occupy_size.x * NAV_CELLS_PER_OCCUPY_CELL, occupy_size.y * NAV_CELLS_PER_OCCUPY_CELL
	)


func _occupy_offset_to_nav_cell(column_index: int, row_index: int) -> Vector2i:
	return OccupyGridScript.occupy_cell_to_nav_cell(
		Vector2i(column_index, row_index), NAV_CELLS_PER_OCCUPY_CELL
	)


func _nav_cell_to_occupy_cell(nav_cell: Vector2i) -> Vector2i:
	return OccupyGridScript.nav_cell_to_occupy_cell(nav_cell, NAV_CELLS_PER_OCCUPY_CELL)


func _occupy_cell_to_nav_cell(occupy_cell: Vector2i) -> Vector2i:
	return OccupyGridScript.occupy_cell_to_nav_cell(occupy_cell, NAV_CELLS_PER_OCCUPY_CELL)


func _occupy_cell_world_center(nav_cell: Vector2i) -> Vector3:
	var start: Vector3 = _navigation_grid.grid_to_world(nav_cell, false)
	var end: Vector3 = _navigation_grid.grid_to_world(
		nav_cell + Vector2i(NAV_CELLS_PER_OCCUPY_CELL, NAV_CELLS_PER_OCCUPY_CELL), false
	)
	return (start + end) * 0.5


func _is_occupy_cell_buildable(nav_cell: Vector2i) -> bool:
	for y in NAV_CELLS_PER_OCCUPY_CELL:
		for x in NAV_CELLS_PER_OCCUPY_CELL:
			if not _is_nav_cell_buildable(nav_cell + Vector2i(x, y)):
				return false
	return true


func _is_occupy_cell_unoccupied(nav_cell: Vector2i, occupied_cells: Dictionary) -> bool:
	for y in NAV_CELLS_PER_OCCUPY_CELL:
		for x in NAV_CELLS_PER_OCCUPY_CELL:
			if occupied_cells.has(nav_cell + Vector2i(x, y)):
				return false
	return true


func _occupied_building_nav_cells() -> Dictionary:
	if _navigation_grid == null or not _navigation_grid.is_loaded():
		return {}
	# Only the in-tree path can observe every Building via the global group (see
	# _scan_occupied_building_nav_cells), which is the only path the tracked
	# enter/exit-tree invalidation below actually covers. The out-of-tree
	# fallback is test-only scaffolding and stays uncached.
	if not is_inside_tree():
		return _scan_occupied_building_nav_cells()
	_ensure_occupied_cells_tracking()
	if not _occupied_cells_cache_valid:
		_occupied_cells_cache = _scan_occupied_building_nav_cells()
		_occupied_cells_cache_valid = true
	return _occupied_cells_cache


func _scan_occupied_building_nav_cells() -> Dictionary:
	var cells := {}
	var buildings: Array = []
	if is_inside_tree():
		buildings = get_tree().get_nodes_in_group("buildings")
	elif _buildings_root != null:
		buildings = _buildings_root.get_children()
	for node in buildings:
		var building := node as Node3D
		if building == null:
			continue
		var occupy_rows: Array[String] = []
		if not _existing_building_occupy_rows.is_null():
			occupy_rows.assign(_existing_building_occupy_rows.call(building))
		if occupy_rows.is_empty():
			continue
		for cell in BuildingFootprintScript.nav_cells_by_marker(
			building, occupy_rows, _navigation_grid, NAV_CELLS_PER_OCCUPY_CELL
		):
			cells[cell] = true
	return cells


## Connected once per placement instance (guarded by tracking_started).
## Building's own group membership is only set inside its _ready(), which
## SceneTree.node_added fires before -- checking `is Building` instead of the
## group sidesteps that ordering gap for both enter and exit.
func _ensure_occupied_cells_tracking() -> void:
	if _occupied_cells_tracking_started:
		return
	_occupied_cells_tracking_started = true
	var tree := get_tree()
	if tree == null:
		return
	tree.node_added.connect(_on_occupied_cells_tracked_node_added)
	tree.node_removed.connect(_on_occupied_cells_tracked_node_removed)


func _on_occupied_cells_tracked_node_added(node: Node) -> void:
	if node is Building:
		_occupied_cells_cache_valid = false


func _on_occupied_cells_tracked_node_removed(node: Node) -> void:
	if node is Building:
		_occupied_cells_cache_valid = false


func _is_nav_cell_buildable(grid_cell: Vector2i) -> bool:
	var debug: Dictionary = _navigation_grid.cell_debug(grid_cell)
	return bool(debug.get("valid", false)) and bool(debug.get("buildable", false))


func _preview_scene_for_marker(marker: String, buildable: bool) -> PackedScene:
	if not buildable:
		return _cant_build_preview_scene
	if marker.to_lower() == "s":
		return _skirt_preview_scene
	return _building_preview_scene


func _is_empty_occupy_marker(marker: String) -> bool:
	return OccupyGridScript.is_empty_marker(marker)


func _has_occupy_cells(occupy_rows: Array[String]) -> bool:
	for row in occupy_rows:
		for column_index in row.length():
			if not _is_empty_occupy_marker(row.substr(column_index, 1)):
				return true
	return false


func _raycast(screen_position: Vector2, collision_mask: int) -> Dictionary:
	if _camera == null or not is_inside_tree():
		return {}
	return TerrainProbeScript.screen_pick(_camera, get_world_3d(), screen_position, collision_mask)


func _snap_to_ground(point: Vector3) -> Vector3:
	if not is_inside_tree():
		return Vector3(point.x, 0.0, point.z)
	return TerrainProbeScript.snap_to_ground(get_world_3d(), point)


## These confirmation sounds belong to placement rather than construction:
## walls confirm each completed segment with WallThud, while every other
## successfully placed building uses BuildingThud.
## The section is passed in because _clear() must remove the placement-preview
## children before its one-shot audio player is attached.
func _play_placement_thud(world_position: Vector3, section_id: StringName) -> void:
	SfxSectionCatalogScript.play_at(self, world_position, section_id)


## Wall lines confirm once, when the user finishes drawing the line -- before
## the first queued segment starts building -- rather than per segment.
func play_wall_line_start_thud(world_position: Vector3) -> void:
	_play_placement_thud(world_position, &"WallThud")


func _play_placed_building_animation(building: Node3D) -> void:
	_begin_building_construction(building)
	_set_building_invulnerable(building, true)
	# Building._ready() only schedules its neighbour-mask/topology refresh via
	# call_deferred, which would run after the construct animation below has
	# already started -- refresh it now so the construction mesh picks up the
	# correct orientation for its neighbours right away.
	if building.has_method("_refresh_wall_topology"):
		building.call("_refresh_wall_topology")
	if AuthoredModelScript.play_one_shot(
		building,
		&"construct",
		_on_placed_building_animation_finished.bind(building)
	):
		BuildingConstructionSoundScript.play(building)
		return
	# No construct clip means the building pops in instantly - there is no
	# vulnerable transition window to protect, so invulnerability is skipped.
	_play_building_state(building, &"idle")
	_set_building_invulnerable(building, false)
	_finish_building_construction(building)


func _on_placed_building_animation_finished(animation_name: StringName, building: Node3D) -> void:
	if animation_name != &"construct":
		return
	if is_instance_valid(building):
		_play_building_state(building, &"idle")
		_set_building_invulnerable(building, false)
		_finish_building_construction(building)


func _begin_building_construction(building: Node3D) -> void:
	if building.has_method("begin_construction"):
		building.call("begin_construction")


func _finish_building_construction(building: Node3D) -> void:
	if building.has_method("finish_construction"):
		building.call("finish_construction")


func _set_building_invulnerable(building: Node3D, value: bool) -> void:
	if building.has_method("set_invulnerable"):
		building.call("set_invulnerable", value)


func _play_building_state(building: Node3D, state: StringName) -> void:
	AuthoredModelScript.play_state(building, state)
