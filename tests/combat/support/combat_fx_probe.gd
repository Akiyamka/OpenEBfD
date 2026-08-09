extends RefCounted


static func muzzle_effects(root: Node, kind: StringName, emission_index := -1) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for child in root.get_children():
		if not child is Node3D or child.get_meta("combat_muzzle_fx", &"") != kind:
			continue
		if emission_index >= 0 and int(child.get_meta("emission_index", -1)) != emission_index:
			continue
		result.append(child as Node3D)
	return result


static func free_muzzle_effects(root: Node) -> void:
	for child in root.get_children():
		if child.has_meta("combat_muzzle_fx"):
			child.free()


static func impact_effects(root: Node, effect_id: StringName) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for child in root.get_children():
		if child is Node3D and child.get_meta("combat_impact_fx", &"") == effect_id:
			result.append(child as Node3D)
	return result


static func free_impact_effects(root: Node) -> void:
	for child in root.get_children():
		if child.has_meta("combat_impact_fx"):
			child.free()


static func ground_decals(root: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for child in root.get_children():
		if child is Node3D and child.has_meta("combat_ground_decal"):
			result.append(child as Node3D)
	return result


static func free_ground_decals(root: Node) -> void:
	for child in root.get_children():
		if child.has_meta("combat_ground_decal"):
			child.free()


static func free_all(root: Node) -> void:
	free_muzzle_effects(root)
	free_impact_effects(root)
	free_ground_decals(root)
