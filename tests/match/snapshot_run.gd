extends SceneTree

const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
const SnapshotFixtureScene := preload("res://tests/fixtures/snapshot_fixture.tscn")
const ATRefineryScene := preload("res://assets/converted/buildings/ATRefinery/ATRefinery.scn")
const ATAdvancedCarryallScene := preload("res://scenes/units/atadv_carryall.tscn")
const ATScoutScene := preload("res://scenes/units/at_trike.tscn")
const TEST_SNAPSHOT_PATH := "user://match_snapshot_test.json"

var _failures := 0


func _initialize() -> void:
	await process_frame
	_configure_players()
	var snapshot = MatchSnapshotScript.new(TEST_SNAPSHOT_PATH)
	snapshot.erase()
	var source = SnapshotFixtureScene.instantiate()
	get_root().add_child(source)
	await physics_frame
	await physics_frame

	var source_building := source.get_node("Buildings/ATSmWindtrap") as Node3D
	var source_unit := source.get_node("Units/OrdosAPC") as Node3D
	var source_refinery := ATRefineryScene.instantiate() as Building
	source_refinery.name = "SnapshotRefinery"
	source_refinery.owner_player_id = 1
	source.get_node("Buildings").add_child(source_refinery)
	source_refinery.set_refinery_upgrade_state(2)
	var source_carryall := ATAdvancedCarryallScene.instantiate() as Unit
	var source_cargo := ATScoutScene.instantiate() as Unit
	source_carryall.name = "SnapshotCarryall"
	source_cargo.name = "SnapshotCargo"
	source.get_node("Units").add_child(source_carryall)
	source.get_node("Units").add_child(source_cargo)
	await process_frame
	source_carryall.transport_attach_cargo(source_cargo, Vector3(0.0, -2.0, 0.0))
	var building_transform := Transform3D(Basis(Vector3.UP, 0.4), Vector3(84.0, 0.0, 96.0))
	var unit_transform := Transform3D(Basis(Vector3.UP, -0.7), Vector3(145.0, 0.0, 72.0))
	source_building.global_transform = building_transform
	source_unit.global_transform = unit_transform
	var save_result: Dictionary = snapshot.save(source.get_node("Buildings"), source.get_node("Units"))
	_expect(bool(save_result.get("ok", false)), "snapshot should be written")
	source.queue_free()
	await process_frame

	var restored = SnapshotFixtureScene.instantiate()
	get_root().add_child(restored)
	await physics_frame
	await physics_frame
	var restore_result: Dictionary = snapshot.restore(restored.get_node("Buildings"), restored.get_node("Units"))
	_expect(bool(restore_result.get("ok", false)), "snapshot should be restored")
	await physics_frame

	var restored_building := restored.get_node_or_null("Buildings/ATSmWindtrap") as Node3D
	var restored_refinery := restored.get_node_or_null("Buildings/SnapshotRefinery") as Building
	var restored_unit := restored.get_node_or_null("Units/OrdosAPC") as Unit
	var restored_carryall := restored.get_node_or_null("Units/SnapshotCarryall") as Unit
	var restored_cargo := restored.get_node_or_null("Units/SnapshotCargo") as Unit
	_expect(restored_building != null, "saved building should exist after restore")
	_expect(restored_unit != null, "saved unit should exist after restore")
	_expect(
		restored_carryall != null and restored_cargo != null,
		"snapshot must retain both a carryall and its carried Unit"
	)
	_expect(
		restored_cargo != null and not restored_cargo.is_carried()
			and restored_cargo.get_parent() == restored.get_node("Units"),
		"snapshot must restore cargo independently without persisting transport state"
	)
	_expect(
		restored_refinery != null and restored_refinery.refinery_upgrade_state == 2,
		"refinery dock state should be restored without separate dock buildings"
	)
	_expect(restored_building != null and restored_building.global_position.is_equal_approx(building_transform.origin), "building position should be restored")
	_expect(restored_unit != null and restored_unit.global_position.is_equal_approx(unit_transform.origin), "unit position should be restored")
	_expect(restored_building != null and restored_building.global_transform.basis.is_equal_approx(building_transform.basis), "building rotation should be restored")
	_expect(restored_unit != null and restored_unit.global_transform.basis.is_equal_approx(unit_transform.basis), "unit rotation should be restored")
	var shield_meshes := _shield_meshes(restored_unit)
	_expect(shield_meshes.size() == 1, "restored OrdosAPC should retain its shield mesh")
	_expect(not shield_meshes.is_empty() and shield_meshes[0].visible, "restored OrdosAPC should show its charged shield")
	_expect(
		not shield_meshes.is_empty()
			and _mesh_team_color(shield_meshes[0]).is_equal_approx(restored_unit.owner_player().team_color),
		"restored OrdosAPC visual should retain its owner's team color"
	)
	var ordinary_building_mesh := _mesh_without_team_color_uniform(restored_building)
	var ordinary_unit_mesh := _mesh_without_team_color_uniform(restored_unit)
	_expect(
		ordinary_building_mesh != null
			and ordinary_building_mesh.get_instance_shader_parameter("team_color") == null,
		"owner color refresh should not attach an unknown instance uniform to ordinary building meshes"
	)
	_expect(
		ordinary_unit_mesh != null
			and ordinary_unit_mesh.get_instance_shader_parameter("team_color") == null,
		"owner color refresh should not attach an unknown instance uniform to ordinary unit meshes"
	)

	snapshot.erase()
	restored.queue_free()
	if _failures > 0:
		printerr("Match snapshot tests: %d failures" % _failures)
		quit(1)
		return
	print("Match snapshot tests passed")
	quit(0)


func _configure_players() -> void:
	var players = get_root().get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Snapshot Atreides", Color(0.12, 0.44, 1.0), &"Atreides", [], 1)
	players.create_player(2, "Snapshot Ordos", Color(0.16, 0.75, 0.34), &"Ordos", [], 2)
	players.local_player_id = 1


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)


func _shield_meshes(unit: Unit) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if unit == null:
		return result
	for node in unit.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if String(mesh.get_parent().name).to_lower().contains("shield"):
			result.append(mesh)
	return result


func _mesh_team_color(mesh: MeshInstance3D) -> Color:
	var value: Variant = mesh.get_instance_shader_parameter("team_color")
	return value as Color if value is Color else Color.TRANSPARENT


func _mesh_without_team_color_uniform(root: Node) -> MeshInstance3D:
	if root == null:
		return null
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if not _mesh_has_team_color_shader(mesh):
			return mesh
	return null


func _mesh_has_team_color_shader(mesh: MeshInstance3D) -> bool:
	var materials: Array[Material] = []
	if mesh.material_override != null:
		materials.append(mesh.material_override)
	if mesh.material_overlay != null:
		materials.append(mesh.material_overlay)
	if mesh.mesh != null:
		for surface_index in mesh.mesh.get_surface_count():
			var material := mesh.get_surface_override_material(surface_index)
			if material == null:
				material = mesh.mesh.surface_get_material(surface_index)
			if material != null:
				materials.append(material)
	for material in materials:
		if material is ShaderMaterial:
			var shader := (material as ShaderMaterial).shader
			if shader != null and "instance uniform vec4 team_color" in shader.code:
				return true
	return false
