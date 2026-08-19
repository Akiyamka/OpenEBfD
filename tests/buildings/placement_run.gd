extends SceneTree

const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const PlacementContextScript := preload("res://scripts/buildings/placement_context.gd")
const BuildingBakeBuilderScript := preload("res://converters/building_bake_builder.gd")
const ATBarracksScene := preload("res://assets/converted/buildings/ATBarracks/ATBarracks.scn")
const PlacementArrowScene := preload("res://assets/converted/placement/build_arrow.scn")
const PlacementBuildingScene := preload("res://assets/converted/placement/build_building.scn")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 2000


class FakeGrid extends RefCounted:
	func is_loaded() -> bool:
		return true

	func grid_to_world(cell: Vector2i, centered: bool) -> Vector3:
		var offset := 0.5 if centered else 0.0
		return Vector3(float(cell.x) + offset, 0.0, float(cell.y) + offset)

	func world_to_grid(position: Vector3) -> Vector2i:
		return Vector2i(floori(position.x), floori(position.z))

	func cell_debug(_cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": true}


class PartiallyBlockedGrid extends FakeGrid:
	func cell_debug(cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": cell.x < 4}


class FootprintConfig extends Resource:
	var rows: Array[String]

	func _init(new_rows: Array[String]) -> void:
		rows = new_rows

	func list(field_name: StringName) -> Array[String]:
		return rows if field_name == &"occupy_rows" else []


class ExistingBuilding extends Node3D:
	var building_config: Resource
	var config_id: StringName
	var owner_player_id := 0


func _initialize() -> void:
	_run_case("begin validation and cancel", _test_begin_and_cancel)
	_run_case("failed placement keeps active state", _test_failed_placement_keeps_active)
	_run_case("footprint occupancy and single spawn handoff", _test_occupancy_and_single_spawn)
	_run_case("construction completes only after construct animation", _test_construction_waits_for_animation)
	_run_case("building art uses the Helipad-calibrated scale", _test_building_art_scale)
	_run_case("placement rotation turns footprint and spawned building", _test_rotated_placement)
	_run_case("unmaterialed preview mesh gets fallback material", _test_unmaterialed_preview_mesh_gets_fallback_material)
	_run_case("placement arrow keeps its white fill from either camera side", _test_arrow_white_fill)
	_run_case("wall footprint omits the direction arrow", _test_wall_footprint_omits_arrow)
	_run_case("legacy building without placement anchor", _test_legacy_building_without_placement_anchor)
	_run_case("rotated existing footprint follows building transform", _test_rotated_existing_footprint)
	_run_case("resolver fallback occupancy", _test_resolver_fallback_occupancy)
	_run_case("out-of-radius cells preview as blocked", _test_out_of_radius_preview_is_blocked)
	_run_case("enemy buildings do not extend build radius", _test_enemy_building_does_not_extend_radius)
	_run_case("evaluate_at_hover_cell creates no preview nodes", _test_evaluate_at_hover_cell_creates_no_preview_nodes)
	_run_case(
		"try_place_at_hover_cell on a blocked cell creates no preview nodes",
		_test_try_place_at_hover_cell_on_blocked_cell_creates_no_preview_nodes
	)
	_run_case(
		"evaluate_at_hover_cell agrees with the interactive preview verdict",
		_test_evaluate_at_hover_cell_matches_interactive_path
	)

	if _failures > 0:
		printerr("BuildingPlacement tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("BuildingPlacement tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	var completed: Variant = test.call(token)
	if completed != token:
		_failures += 1
		printerr("FAIL: %s: case did not return its completion token" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _new_placement(existing_building_occupy_rows: Callable = Callable()) -> Array:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)
	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	_setup_placement(placement, null, FakeGrid.new(), buildings_root, null, null, null, null, existing_building_occupy_rows)
	return [placement, buildings_root]


func _setup_placement(
		placement,
		camera: Camera3D,
		navigation_grid,
		buildings_root: Node3D,
		arrow_scene: PackedScene,
		building_preview_scene: PackedScene,
		cant_build_preview_scene: PackedScene,
		skirt_preview_scene: PackedScene,
		existing_rows: Callable,
		existing_is_wall: Callable = Callable(),
		build_radius: Callable = Callable(),
		owner_id: Callable = Callable()
) -> void:
	var context := PlacementContextScript.new()
	context.camera = camera
	context.navigation_grid = navigation_grid
	context.buildings_root = buildings_root
	context.arrow_scene = arrow_scene
	context.building_preview_scene = building_preview_scene
	context.cant_build_preview_scene = cant_build_preview_scene
	context.skirt_preview_scene = skirt_preview_scene
	context.existing_building_occupy_rows = existing_rows
	context.existing_building_is_wall = existing_is_wall
	context.build_radius_provider = build_radius
	context.owner_player_id_provider = owner_id
	placement.setup(context)


func _free_pair(pair: Array) -> void:
	pair[0].queue_free()
	pair[1].queue_free()


func _rows(values: Array) -> Array[String]:
	var rows: Array[String] = []
	for value in values:
		rows.append(String(value))
	return rows


func _direct_config_rows(building: Node3D) -> Array[String]:
	var config = building.get("building_config") as Resource
	if config == null:
		return []
	return config.list(&"occupy_rows")


func _fallback_config_id_rows(building: Node3D) -> Array[String]:
	if building.config_id == &"Fallback":
		return _rows(["X"])
	return _direct_config_rows(building)


func _test_begin_and_cancel(token: int) -> int:
	var pair := _new_placement()
	var placement = pair[0]
	_expect(not placement.begin(&"", "Invalid", _rows(["X"])), "an empty building id must be rejected")
	_expect(not placement.begin(&"Invalid", "Invalid", _rows([".."])), "a footprint without occupied cells must be rejected")
	_expect(not placement.is_active(), "rejected footprints must leave placement inactive")
	_expect(placement.begin(&"Valid", "Valid", _rows(["X"])), "an occupied footprint must begin placement")
	_expect(placement.is_active(), "a valid begin must activate placement")
	_expect(placement.cancel() == "Valid", "cancel must return the active display name")
	_expect(not placement.is_active(), "cancel must clear active placement state")
	_free_pair(pair)
	return token


func _test_failed_placement_keeps_active(token: int) -> int:
	var pair := _new_placement()
	var placement = pair[0]
	placement.begin(&"Failure", "Failure", _rows(["X"]))
	var result = placement.try_place_at_hover_cell(Vector2i(2, 4), null)
	_expect(result == BuildingPlacementScript.PlaceResult.INVALID_SCENE, "a missing scene must fail explicitly")
	_expect(placement.is_active(), "a failed scene must preserve active placement")
	placement.cancel()
	_free_pair(pair)
	return token


func _test_occupancy_and_single_spawn(token: int) -> int:
	var pair := _new_placement(Callable(self, "_direct_config_rows"))
	var placement = pair[0]
	var buildings_root = pair[1]
	var existing = ExistingBuilding.new()
	existing.building_config = FootprintConfig.new(_rows(["X"]))
	existing.set_meta(&"placement_anchor_cell", Vector2i(2, 4))
	existing.add_to_group("buildings")
	buildings_root.add_child(existing)

	placement.begin(&"Blocked", "Blocked", _rows(["X"]))
	var blocked = placement.try_place_at_hover_cell(Vector2i(2, 4), null)
	_expect(blocked == BuildingPlacementScript.PlaceResult.CANNOT_BUILD, "occupied footprint cells must reject placement")
	_expect(placement.is_active(), "an occupied footprint must keep placement active")
	placement.cancel()
	buildings_root.remove_child(existing)
	existing.free()

	placement.begin(&"Spawn", "Spawn", _rows(["XX", "XX"]))
	var template := Node3D.new()
	var scene := PackedScene.new()
	_expect(scene.pack(template) == OK, "an in-memory scene must pack")
	template.free()
	var placed = placement.try_place_at_hover_cell(Vector2i(5, 7), scene, 4)
	_expect(placed == BuildingPlacementScript.PlaceResult.PLACED, "a valid footprint and injected scene must spawn")
	_expect(not placement.is_active(), "a successful placement must consume active placement once")
	_expect(buildings_root.get_child_count() == 1, "spawn must add exactly one building to the injected root")
	var spawned := buildings_root.get_child(0) as Node3D
	_expect(spawned.get_meta(&"placement_anchor_cell") == Vector2i(2, 4), "footprint orientation must center its anchor")
	_expect(spawned.position == Vector3(4.0, 0.0, 6.0), "spawn position must use the footprint center")
	_expect(
		placement.try_place_at_hover_cell(Vector2i(5, 7), scene, 4) == BuildingPlacementScript.PlaceResult.INACTIVE,
		"a successful placement handoff must not spawn twice"
	)
	_free_pair(pair)
	return token


func _test_construction_waits_for_animation(token: int) -> int:
	var pair := _new_placement()
	var placement = pair[0]
	var buildings_root = pair[1]
	placement.begin(&"ATBarracks", "Barracks", _rows(["X"]))

	var result = placement.try_place_at_hover_cell(Vector2i(5, 7), ATBarracksScene, 1)
	_expect(result == BuildingPlacementScript.PlaceResult.PLACED, "the animated building must be placed")
	var building := buildings_root.get_child(0) as Building
	_expect(building != null and not building.is_construction_complete(), "the placed building must remain incomplete while its construct clip plays")

	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	_expect(player != null and player.current_animation == &"construct", "placement must start the authored construct clip")
	var build_state := building.get_node_or_null("States/Build") as Node3D
	var idle_state := building.get_node_or_null("States/Idle") as Node3D
	_expect(
		build_state != null and build_state.visible,
		"placement must apply the construct model before the first animation frame"
	)
	_expect(
		idle_state != null and not idle_state.visible,
		"placement must hide the completed model before the first animation frame"
	)
	if player != null:
		player.animation_finished.emit(&"construct")
	_expect(building.is_construction_complete(), "only the construct animation completion signal may make the building operational")
	_expect(building.current_state == &"idle", "a completed construct animation must transition the building to idle")

	_free_pair(pair)
	return token


func _test_building_art_scale(token: int) -> int:
	var builder = BuildingBakeBuilderScript.new()
	_expect(
		is_equal_approx(builder.world_scale, 0.0703125),
		"every building conversion must use the shared 9/8 scale correction"
	)
	var scene: PackedScene = builder.build(&"ATHelipad")
	_expect(scene != null, "the Helipad scale reference must convert successfully")
	if scene == null:
		return token
	var helipad := scene.instantiate() as Node3D
	var helipad_idle := helipad.get_node_or_null("States/Idle") as Node3D
	_expect(
		helipad_idle != null and is_equal_approx(
			helipad_idle.scale.x, BuildingBakeBuilderScript.BUILDING_WORLD_SCALE
		),
		"ATHelipad must use the shared calibrated building scale"
	)
	var pad_size := _largest_named_mesh_size(helipad, &"Mesh_00")
	_expect(
		absf(pad_size.x - 4.5) < 0.01 and absf(pad_size.z - 6.75) < 0.01,
		"ATHelipad Mesh_00 must span 4.5x6.75 world units (got %s)" % pad_size
	)
	helipad.free()
	return token


func _largest_named_mesh_size(root: Node3D, mesh_name: StringName) -> Vector3:
	var largest := Vector3.ZERO
	var largest_area := 0.0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D) or node.name != mesh_name:
			continue
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var bounds: AABB = _relative_transform(mesh_instance, root) * mesh_instance.get_aabb()
		var area := bounds.size.x * bounds.size.z
		if area > largest_area:
			largest_area = area
			largest = bounds.size
	return largest


func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != ancestor:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _test_rotated_placement(token: int) -> int:
	var pair := _new_placement()
	var placement = pair[0]
	var buildings_root = pair[1]
	var source_rows := _rows(["X..", "XXX"])
	placement.begin(&"Rotated", "Rotated", source_rows)

	_expect(
		placement.face_toward_cells(Vector2i.ZERO, Vector2i(5, 0)),
		"dragging east must perform a quarter turn"
	)
	_expect(placement.rotation_quarter_turns() == 1, "east must face the building local +Z toward +X")
	_expect(
		not placement.face_toward_cells(Vector2i.ZERO, Vector2i(8, 1)),
		"continuing in the same cardinal direction must not count as another turn"
	)
	_expect(
		placement._occupy_rows == _rows([".X", ".X", "XX"]),
		"a quarter turn must rotate asymmetric occupy rows with the model"
	)

	var template := Node3D.new()
	var scene := PackedScene.new()
	_expect(scene.pack(template) == OK, "a rotated in-memory scene must pack")
	template.free()
	var placed = placement.try_place_at_hover_cell(Vector2i(9, 11), scene)
	_expect(placed == BuildingPlacementScript.PlaceResult.PLACED, "a rotated valid footprint must spawn")
	var spawned := buildings_root.get_child(0) as Node3D
	_expect(is_equal_approx(spawned.rotation.y, PI * 0.5), "the spawned building must retain the selected quarter turn")

	var expected_cells: Dictionary = {}
	for cell in placement._occupy_rows_nav_cells(spawned.get_meta(&"placement_anchor_cell"), _rows([".X", ".X", "XX"])):
		expected_cells[cell] = true
	var actual_cells := BuildingFootprint.nav_cells_by_marker(
		spawned, source_rows, FakeGrid.new(), BuildingPlacementScript.NAV_CELLS_PER_OCCUPY_CELL
	)
	_expect(actual_cells.size() == expected_cells.size(), "rotated runtime footprint must keep the preview cell count")
	for cell in expected_cells:
		_expect(actual_cells.has(cell), "rotated runtime footprint must match preview cell %s" % cell)

	_free_pair(pair)
	return token


func _test_unmaterialed_preview_mesh_gets_fallback_material(token: int) -> int:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)
	var preview_template := Node3D.new()
	var preview_mesh := MeshInstance3D.new()
	preview_mesh.mesh = BoxMesh.new()
	preview_template.add_child(preview_mesh)
	preview_mesh.owner = preview_template
	var preview_scene := PackedScene.new()
	_expect(preview_scene.pack(preview_template) == OK, "an unmaterialed preview mesh scene must pack")
	preview_template.free()

	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	_setup_placement(placement, null, FakeGrid.new(), buildings_root, null, preview_scene, preview_scene, null, Callable())
	placement.begin(&"Preview", "Preview", _rows(["X"]))
	# try_place_at_hover_cell() no longer draws a preview itself (see
	# building_placement.gd evaluate_at_hover_cell()'s doc comment on why); the
	# interactive path is what draws, so trigger it explicitly to exercise the
	# same preview-mesh material handling this test is about.
	placement.preview_at_hover_cells([Vector2i.ZERO])
	placement.try_place_at_hover_cell(Vector2i.ZERO, null)
	var preview_root := placement.get_child(0) as Node3D
	var configured_mesh := preview_root.get_child(0) as MeshInstance3D if preview_root != null else null
	_expect(configured_mesh != null, "placement must instantiate the preview mesh")
	_expect(
		configured_mesh != null and configured_mesh.material_override != null,
		"a preview mesh without a source material must receive a fallback material"
	)

	placement.cancel()
	placement.queue_free()
	buildings_root.queue_free()
	return token


func _test_arrow_white_fill(token: int) -> int:
	var placement = BuildingPlacementScript.new()
	var arrow := PlacementArrowScene.instantiate() as Node3D
	placement._configure_arrow_visuals(arrow)
	var white_material: StandardMaterial3D
	var blue_override_found := false
	for node in arrow.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		for surface in mesh_instance.mesh.get_surface_count():
			var surface_name := String(mesh_instance.mesh.surface_get_name(surface)).to_lower()
			var override := mesh_instance.get_surface_override_material(surface)
			if surface_name == "white.tga":
				white_material = override as StandardMaterial3D
			elif surface_name.contains("blue") and override != null:
				blue_override_found = true
	_expect(white_material != null, "the authored white.tga arrow surface must receive a white override")
	_expect(
		white_material != null
		and white_material.albedo_color == Color.WHITE
		and white_material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
		and white_material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
		"the placement arrow fill must remain opaque unshaded white"
	)
	_expect(
		white_material != null and white_material.cull_mode == BaseMaterial3D.CULL_DISABLED,
		"the white fill must remain visible from the gameplay camera side"
	)
	_expect(not blue_override_found, "the arrow fix must not replace its authored blue screen surface")
	arrow.free()
	placement.free()
	return token


func _test_wall_footprint_omits_arrow(token: int) -> int:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)
	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)

	_setup_placement(placement,
		null,
		FakeGrid.new(),
		buildings_root,
		PlacementArrowScene,
		PlacementBuildingScene,
		null,
		null,
		Callable()
	)
	placement.begin(&"ATWall", "Wall", _rows(["b"]), true)
	placement.preview_at_hover_cells([
		Vector2i(2, 4),
		Vector2i(4, 4),
		Vector2i(6, 4),
	])
	_expect(
		placement.get_node_or_null("CenterArrow") == null,
		"a wall footprint must not draw a direction arrow"
	)
	_expect(
		placement.get_child_count() == 3,
		"wall-line selection must draw the footprint of every selected segment"
	)
	for preview_cell in placement.get_children():
		for value in preview_cell.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := value as MeshInstance3D
			_expect(
				mesh_instance.material_override != null,
				"every wall-line preview mesh must enter the renderer with a material override"
			)
	var retained_nodes := {
		Vector2i(2, 4): placement._preview_cells_by_grid_cell[Vector2i(2, 4)]["node"],
		Vector2i(4, 4): placement._preview_cells_by_grid_cell[Vector2i(4, 4)]["node"],
		Vector2i(6, 4): placement._preview_cells_by_grid_cell[Vector2i(6, 4)]["node"],
	}
	placement.preview_at_hover_cells([
		Vector2i(2, 4),
		Vector2i(4, 4),
		Vector2i(6, 4),
		Vector2i(8, 4),
	])
	for grid_cell in retained_nodes:
		_expect(
			placement._preview_cells_by_grid_cell[grid_cell]["node"] == retained_nodes[grid_cell],
			"extending a wall line must reuse its existing preview at %s" % grid_cell
		)
	_expect(
		placement.get_child_count() == 4,
		"extending a wall line must instantiate only its new segment preview"
	)

	_setup_placement(placement,
		null,
		PartiallyBlockedGrid.new(),
		buildings_root,
		PlacementArrowScene,
		PlacementBuildingScene,
		null,
		null,
		Callable()
	)
	placement.begin(&"ATWall", "Wall", _rows(["b"]), true)
	placement.preview_at_hover_cells([
		Vector2i(2, 4),
		Vector2i(4, 4),
		Vector2i(6, 4),
	])
	_expect(
		placement.available_preview_anchor_cells() == [Vector2i(2, 4)],
		"only green wall footprints may become fixed build_wall markers"
	)
	placement.queue_free()
	buildings_root.queue_free()
	return token


func _test_legacy_building_without_placement_anchor(token: int) -> int:
	var pair := _new_placement(Callable(self, "_direct_config_rows"))
	var placement = pair[0]
	var buildings_root = pair[1]
	var existing = ExistingBuilding.new()
	existing.building_config = FootprintConfig.new(_rows(["X"]))
	# This is the centered world position for a one-cell footprint anchored at
	# (-2, -2), as used by buildings created before anchor metadata existed.
	existing.position = Vector3(-1.0, 0.0, -1.0)
	existing.add_to_group("buildings")
	buildings_root.add_child(existing)

	placement.begin(&"Blocked", "Blocked", _rows(["X"]))
	var blocked = placement.try_place_at_hover_cell(Vector2i(-2, -2), null)
	_expect(
		blocked == BuildingPlacementScript.PlaceResult.CANNOT_BUILD,
		"a legacy building without anchor metadata must use its world-position footprint"
	)
	placement.cancel()
	_free_pair(pair)
	return token


func _test_rotated_existing_footprint(token: int) -> int:
	var pair := _new_placement(Callable(self, "_direct_config_rows"))
	var placement = pair[0]
	var buildings_root = pair[1]
	var existing = ExistingBuilding.new()
	existing.building_config = FootprintConfig.new(_rows(["X.", "XX"]))
	existing.position = Vector3(10.0, 0.0, 10.0)
	existing.rotation.y = PI / 2.0
	existing.add_to_group("buildings")
	buildings_root.add_child(existing)

	var occupied: Dictionary = placement._occupied_building_nav_cells()
	_expect(occupied.has(Vector2i(8, 10)), "the back-left footprint cell must rotate from -Z to -X")
	_expect(occupied.has(Vector2i(10, 8)), "the front-right footprint cell must rotate from +X to -Z")
	_expect(not occupied.has(Vector2i(8, 8)), "the unrotated footprint location must remain free")

	_free_pair(pair)
	return token


## Regression test: the per-cell preview material must reflect the build
## radius check, not just the aggregate _can_build flag used by
## try_place_at_hover_cell() -- otherwise the grid stays green while
## placement is silently blocked by radius.
func _test_out_of_radius_preview_is_blocked(token: int) -> int:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)

	var available_template := Node3D.new()
	available_template.set_meta(&"kind", "available")
	var available_scene := PackedScene.new()
	_expect(available_scene.pack(available_template) == OK, "available preview template must pack")
	available_template.free()

	var blocked_template := Node3D.new()
	blocked_template.set_meta(&"kind", "blocked")
	var blocked_scene := PackedScene.new()
	_expect(blocked_scene.pack(blocked_template) == OK, "blocked preview template must pack")
	blocked_template.free()

	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	_setup_placement(placement,
		null, FakeGrid.new(), buildings_root, null,
		available_scene, blocked_scene, null,
		Callable(), Callable(), Callable(self, "_always_out_of_radius")
	)

	placement.begin(&"Valid", "Valid", _rows(["X"]))
	# try_place_at_hover_cell() no longer draws a preview itself; the
	# interactive path is what draws (see evaluate_at_hover_cell()'s doc
	# comment in building_placement.gd), so trigger it explicitly to exercise
	# the per-cell material this test is a regression test for.
	placement.preview_at_hover_cells([Vector2i(2, 4)])
	var result = placement.try_place_at_hover_cell(Vector2i(2, 4), null)
	_expect(result == BuildingPlacementScript.PlaceResult.CANNOT_BUILD, "an out-of-radius footprint must reject placement")

	var blocked_cells := 0
	var available_cells := 0
	for child in placement.get_children():
		if not child.has_meta(&"kind"):
			continue
		if String(child.get_meta(&"kind")) == "blocked":
			blocked_cells += 1
		else:
			available_cells += 1
	_expect(blocked_cells == 1, "an out-of-radius cell must render with the blocked preview")
	_expect(available_cells == 0, "an out-of-radius cell must not render with the available preview")

	placement.cancel()
	placement.queue_free()
	buildings_root.queue_free()
	return token


func _always_out_of_radius() -> int:
	return 5


func _test_enemy_building_does_not_extend_radius(token: int) -> int:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)
	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	_setup_placement(placement,
		null, FakeGrid.new(), buildings_root, null, null, null, null,
		Callable(self, "_direct_config_rows"), Callable(), Callable(self, "_radius_two"),
		Callable(self, "_owner_one")
	)

	var owned := ExistingBuilding.new()
	owned.owner_player_id = 1
	owned.building_config = FootprintConfig.new(_rows(["X"]))
	owned.add_to_group("buildings")
	buildings_root.add_child(owned)

	var enemy := ExistingBuilding.new()
	enemy.owner_player_id = 2
	enemy.building_config = FootprintConfig.new(_rows(["X"]))
	enemy.set_meta(&"placement_anchor_cell", Vector2i(20, 20))
	enemy.add_to_group("buildings")
	buildings_root.add_child(enemy)

	placement.begin(&"OwnedRadius", "OwnedRadius", _rows(["X"]))
	var result = placement.try_place_at_hover_cell(Vector2i(22, 20), null)
	_expect(result == BuildingPlacementScript.PlaceResult.CANNOT_BUILD, "an enemy footprint must not make an otherwise distant cell buildable")

	placement.cancel()
	placement.queue_free()
	buildings_root.queue_free()
	return token


func _radius_two() -> int:
	return 2


func _owner_one() -> int:
	return 1


func _test_resolver_fallback_occupancy(token: int) -> int:
	var pair := _new_placement(Callable(self, "_fallback_config_id_rows"))
	var placement = pair[0]
	var buildings_root = pair[1]
	var existing = ExistingBuilding.new()
	existing.config_id = &"Fallback"
	existing.set_meta(&"placement_anchor_cell", Vector2i(2, 4))
	existing.add_to_group("buildings")
	buildings_root.add_child(existing)
	placement.begin(&"FallbackBlocked", "FallbackBlocked", _rows(["X"]))
	var result = placement.try_place_at_hover_cell(Vector2i(2, 4), null)
	_expect(result == BuildingPlacementScript.PlaceResult.CANNOT_BUILD, "resolver footprint must block an existing config-id building")
	_expect(placement.is_active(), "resolver occupancy rejection must preserve active placement")
	placement.cancel()
	_free_pair(pair)
	return token


## evaluate_at_hover_cell() must answer the placement question (see its doc
## comment in building_placement.gd) without building, freeing, or revealing a
## single preview node -- it runs on the simulation tick, on every client,
## including clients whose player has no cursor anywhere near this placement.
## Real (packable) preview scenes are used here, not null, so that a
## regression which routes this call back through the drawing path would
## actually instantiate a node and fail these assertions.
func _test_evaluate_at_hover_cell_creates_no_preview_nodes(token: int) -> int:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)
	var preview_template := Node3D.new()
	var preview_scene := PackedScene.new()
	_expect(preview_scene.pack(preview_template) == OK, "preview template must pack")
	preview_template.free()

	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	_setup_placement(
		placement, null, PartiallyBlockedGrid.new(), buildings_root, null,
		preview_scene, preview_scene, null, Callable()
	)
	placement.begin(&"Pure", "Pure", _rows(["X"]))

	# PartiallyBlockedGrid blocks nav cells with x >= 4, so an anchor at x=2 is
	# fully buildable and one at x=4 is fully blocked.
	var count_before_available := placement.get_child_count()
	var visible_before_available: bool = placement.visible
	_expect(
		placement.evaluate_at_hover_cell(Vector2i(2, 4)) == BuildingPlacementScript.PlaceResult.AVAILABLE,
		"the buildable-half cell must evaluate as available"
	)
	_expect(
		placement.get_child_count() == count_before_available,
		"evaluate_at_hover_cell must not create a preview node for an available cell"
	)
	_expect(
		placement.visible == visible_before_available,
		"evaluate_at_hover_cell must not change visibility for an available cell"
	)

	var count_before_blocked := placement.get_child_count()
	var visible_before_blocked: bool = placement.visible
	_expect(
		placement.evaluate_at_hover_cell(Vector2i(4, 4)) == BuildingPlacementScript.PlaceResult.CANNOT_BUILD,
		"the blocked-half cell must evaluate as unbuildable"
	)
	_expect(
		placement.get_child_count() == count_before_blocked,
		"evaluate_at_hover_cell must not create a preview node for a blocked cell"
	)
	_expect(
		placement.visible == visible_before_blocked,
		"evaluate_at_hover_cell must not change visibility for a blocked cell"
	)

	placement.cancel()
	placement.queue_free()
	buildings_root.queue_free()
	return token


## try_place_at_hover_cell() rejecting a cell must not leave a preview node
## behind either -- it now uses the same pure evaluation as
## evaluate_at_hover_cell() for its NEEDS_TERRAIN/CANNOT_BUILD guards instead
## of rebuilding the preview it is about to discard. Real preview scenes are
## used for the same reason as above: a regression would actually instantiate
## a node here.
func _test_try_place_at_hover_cell_on_blocked_cell_creates_no_preview_nodes(token: int) -> int:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)
	var preview_template := Node3D.new()
	var preview_scene := PackedScene.new()
	_expect(preview_scene.pack(preview_template) == OK, "preview template must pack")
	preview_template.free()

	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	_setup_placement(
		placement, null, PartiallyBlockedGrid.new(), buildings_root, null,
		preview_scene, preview_scene, null, Callable()
	)
	placement.begin(&"PureClick", "PureClick", _rows(["X"]))

	var count_before := placement.get_child_count()
	var result := placement.try_place_at_hover_cell(Vector2i(4, 4), null)
	_expect(result == BuildingPlacementScript.PlaceResult.CANNOT_BUILD, "a blocked cell must still reject placement")
	_expect(
		placement.get_child_count() == count_before,
		"try_place_at_hover_cell must not create a preview node for a blocked cell"
	)

	placement.cancel()
	placement.queue_free()
	buildings_root.queue_free()
	return token


## The whole point of splitting the verdict out of the drawing is that both
## keep answering the same question. This compares evaluate_at_hover_cell()'s
## verdict against the interactive preview path's own _can_build (set by
## _rebuild_preview_for_anchors(), which preview_at_hover_cells() drives) for
## the same cell, rather than asserting a hardcoded AVAILABLE/CANNOT_BUILD --
## that is what would actually catch the two paths drifting apart.
func _test_evaluate_at_hover_cell_matches_interactive_path(token: int) -> int:
	var buildings_root := Node3D.new()
	get_root().add_child(buildings_root)
	var preview_template := Node3D.new()
	var preview_scene := PackedScene.new()
	_expect(preview_scene.pack(preview_template) == OK, "preview template must pack")
	preview_template.free()

	var placement = BuildingPlacementScript.new()
	get_root().add_child(placement)
	_setup_placement(
		placement, null, PartiallyBlockedGrid.new(), buildings_root, null,
		preview_scene, preview_scene, null, Callable()
	)
	placement.begin(&"Compare", "Compare", _rows(["X"]))

	# A footprint anchored at x=2 sits entirely inside the buildable half of
	# the grid (PartiallyBlockedGrid blocks x >= 4); one anchored at x=4 sits
	# entirely outside it.
	placement.preview_at_hover_cells([Vector2i(2, 4)])
	var interactive_buildable: bool = placement._can_build
	var pure_buildable := (
		placement.evaluate_at_hover_cell(Vector2i(2, 4)) == BuildingPlacementScript.PlaceResult.AVAILABLE
	)
	_expect(
		pure_buildable == interactive_buildable,
		"evaluate_at_hover_cell must agree with the interactive preview's verdict for a buildable cell"
	)
	_expect(
		interactive_buildable,
		"the buildable-half cell must actually be buildable for this comparison to mean anything"
	)

	placement.preview_at_hover_cells([Vector2i(4, 4)])
	var interactive_blocked: bool = placement._can_build
	var pure_blocked := (
		placement.evaluate_at_hover_cell(Vector2i(4, 4)) == BuildingPlacementScript.PlaceResult.AVAILABLE
	)
	_expect(
		pure_blocked == interactive_blocked,
		"evaluate_at_hover_cell must agree with the interactive preview's verdict for a blocked cell"
	)
	_expect(
		not interactive_blocked,
		"the blocked-half cell must actually be unbuildable for this comparison to mean anything"
	)

	placement.cancel()
	placement.queue_free()
	buildings_root.queue_free()
	return token
