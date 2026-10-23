class_name MatchSnapshot
extends RefCounted

const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const SimRngScript := preload("res://scripts/sim/sim_rng.gd")

## Exported Godot games cannot usually modify res:// resources. A compact
## snapshot in user:// gives the same "start from here" behaviour everywhere.
const DEFAULT_PATH := "user://main_snapshot.json"

var storage_path := DEFAULT_PATH


func _init(path := DEFAULT_PATH) -> void:
	storage_path = path


func save(buildings_root: Node3D, units_root: Node3D, seed: int, draw_count: int, draw_signature: int) -> Dictionary:
	if not SimRngScript.valid_match_seed(seed) or draw_count < 0 or draw_signature < 0 or draw_signature > 0xffffffff:
		return _failure("Invalid snapshot RNG metadata")
	if buildings_root == null or units_root == null:
		return _failure("Buildings or Units root is unavailable")
	var state := {
		"version": 2,
		"rng_seed": str(seed),
		"draw_count": str(draw_count),
		"draw_signature": "%08x" % draw_signature,
		"buildings": _capture_entities(buildings_root, Building),
		"units": _capture_entities(units_root, Unit),
	}
	var file := FileAccess.open(storage_path, FileAccess.WRITE)
	if file == null:
		return _failure("Cannot write %s (error %d)" % [storage_path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(state))
	file.close()
	return {"ok": true, "message": "Saved %d buildings and %d units" % [state.buildings.size(), state.units.size()]}


func restore(buildings_root: Node3D, units_root: Node3D) -> Dictionary:
	if not FileAccess.file_exists(storage_path):
		return _failure("No saved startup state")
	if buildings_root == null or units_root == null:
		return _failure("Buildings or Units root is unavailable")
	var file := FileAccess.open(storage_path, FileAccess.READ)
	if file == null:
		return _failure("Cannot read %s" % storage_path)
	var json := JSON.new()
	var parse_error := json.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not json.data is Dictionary:
		return _failure("Saved startup state is invalid")
	var state: Dictionary = json.data
	var version: Variant = state.get("version")
	if not version is float or version != 2.0:
		return _failure("Saved startup state has an unsupported version")
	if not state.get("rng_seed") is String or not state.get("draw_count") is String or not state.get("draw_signature") is String:
		return _failure("Saved startup state has missing RNG metadata")
	var seed_result: Dictionary = SimRngScript.parse_decimal(state["rng_seed"])
	var count_result: Dictionary = SimRngScript.parse_decimal(state["draw_count"], true)
	var signature_text: String = state["draw_signature"]
	if not bool(seed_result["valid"]) or not bool(count_result["valid"]) or signature_text.length() != 8:
		return _failure("Saved startup state has invalid RNG metadata")
	for character_index in signature_text.length():
		var character := signature_text.unicode_at(character_index)
		if not ((character >= 48 and character <= 57) or (character >= 97 and character <= 102)):
			return _failure("Saved startup state has invalid RNG signature")
	if not state.get("buildings") is Array or not state.get("units") is Array:
		return _failure("Saved startup state has invalid entities")

	var buildings: Array = state.get("buildings", [])
	var units: Array = state.get("units", [])
	_clear_children(buildings_root)
	_clear_children(units_root)
	var restored_buildings := _restore_entities(buildings, buildings_root, Building)
	var restored_units := _restore_entities(units, units_root, Unit)
	return {
		"ok": true,
		"message": "Restored %d buildings and %d units" % [restored_buildings, restored_units],
		"rng_seed": int(seed_result["value"]),
		"draw_count": int(count_result["value"]),
		"draw_signature": signature_text.hex_to_int(),
	}


func erase() -> Dictionary:
	if not FileAccess.file_exists(storage_path):
		return _failure("No saved startup state")
	var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(storage_path))
	if error != OK:
		return _failure("Cannot remove saved startup state (error %d)" % error)
	return {"ok": true, "message": "Saved startup state cleared"}


func _capture_entities(root: Node3D, expected_type) -> Array:
	var entities: Array = []
	_capture_entity_descendants(root, expected_type, entities)
	return entities


func _capture_entity_descendants(parent: Node, expected_type, entities: Array) -> void:
	for child in parent.get_children():
		# Transport orders and attachment state stay transient, but the carried
		# Unit itself must not disappear from an F7 snapshot merely because its
		# live instance currently sits below a CargoAnchor.
		if is_instance_of(child, expected_type):
			var entity := child as Node3D
			if entity == null or entity.scene_file_path.is_empty():
				push_warning("MatchSnapshot: cannot save %s because it has no source scene" % child.name)
			else:
				entities.append(_capture_entity(entity))
		_capture_entity_descendants(child, expected_type, entities)


func _capture_entity(entity: Node3D) -> Dictionary:
	var record := {
		"name": entity.name,
		"scene_path": entity.scene_file_path,
		"transform": _encode_transform(entity.global_transform),
		"config_id": String(entity.get("config_id")),
		"owner_player_id": EntityQueryScript.owner_id_of(entity),
	}
	if entity is Building:
		record["refinery_upgrade_state"] = int(entity.get("refinery_upgrade_state"))
	if entity is Unit:
		if "spice" in entity:
			record["spice"] = float(entity.get("spice"))
		var visual_root := entity.get_node_or_null("VisualRoot") as Node3D
		if visual_root != null and visual_root.get_child_count() > 0:
			var visual := visual_root.get_child(0)
			if not visual.scene_file_path.is_empty():
				record["visual_scene_path"] = visual.scene_file_path
	return record


func _restore_entities(records: Array, root: Node3D, expected_type) -> int:
	var restored := 0
	for record_variant in records:
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		var scene_path := String(record.get("scene_path", ""))
		var scene := load(scene_path) as PackedScene
		if scene == null:
			push_warning("MatchSnapshot: source scene is unavailable: %s" % scene_path)
			continue
		var entity := scene.instantiate() as Node3D
		if entity == null or not is_instance_of(entity, expected_type):
			push_warning("MatchSnapshot: source scene has unexpected root: %s" % scene_path)
			if entity != null:
				entity.free()
			continue
		entity.name = String(record.get("name", entity.name))
		entity.set("config_id", StringName(String(record.get("config_id", ""))))
		entity.set("owner_player_id", int(record.get("owner_player_id", 0)))
		root.add_child(entity)
		entity.global_transform = _decode_transform(record.get("transform", {}))
		# The assignment above is the only way to restore *rotation* --
		# SimEntityState holds a position and nothing else -- but on its own it
		# left the store never hearing about a restored entity at all:
		# _register_entity_id() (Unit's and Building's alike) pushes owner, not
		# position, so has_position() answered false for a live entity and slice
		# B4's interpolation skipped it. Pushing the landed position back
		# through the sanctioned setter is what makes the node and the store
		# agree again. Duck-typed because both kinds reach this loop and only
		# `expected_type` tells them apart; harmlessly a node-only write when
		# there is no Match in the tree, which is every snapshot suite.
		if entity.has_method("set_simulation_position"):
			entity.call("set_simulation_position", entity.global_position)
		_restore_entity_details(entity, record)
		restored += 1
	return restored


func _restore_entity_details(entity: Node3D, record: Dictionary) -> void:
	if entity is Building:
		entity.call("set_refinery_upgrade_state", int(record.get("refinery_upgrade_state", 0)))
	if entity is Unit:
		_restore_unit_visual(entity as Unit, String(record.get("visual_scene_path", "")))
		if "spice" in entity:
			entity.set("spice", float(record.get("spice", 0.0)))
		entity.call("stop_at_current_position")


func _restore_unit_visual(unit: Unit, scene_path: String) -> void:
	if scene_path.is_empty():
		return
	var model_scene := load(scene_path) as PackedScene
	var visual_root := unit.get_node_or_null("VisualRoot") as Node3D
	if model_scene == null or visual_root == null:
		return
	unit.replace_visual_scene(model_scene)


func _clear_children(root: Node3D) -> void:
	for child in root.get_children():
		root.remove_child(child)
		child.free()


func _encode_transform(value: Transform3D) -> Dictionary:
	return {
		"origin": _encode_vector3(value.origin),
		"x": _encode_vector3(value.basis.x),
		"y": _encode_vector3(value.basis.y),
		"z": _encode_vector3(value.basis.z),
	}


func _decode_transform(value) -> Transform3D:
	if not value is Dictionary:
		return Transform3D.IDENTITY
	var data: Dictionary = value
	return Transform3D(
		Basis(_decode_vector3(data.get("x", [])), _decode_vector3(data.get("y", [])), _decode_vector3(data.get("z", []))),
		_decode_vector3(data.get("origin", []))
	)


func _encode_vector3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


func _decode_vector3(value) -> Vector3:
	if not value is Array or value.size() != 3:
		return Vector3.ZERO
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _failure(message: String) -> Dictionary:
	return {"ok": false, "message": message}
