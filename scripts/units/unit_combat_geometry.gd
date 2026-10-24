extends RefCounted

## Authored local pose, captured once per installed model. The root belongs to
## the unit scene and survives model replacement; only its descendants refresh.
var _unit: Node3D
var _visual_root: Node3D
var _root_rest := Transform3D.IDENTITY
var _rests: Dictionary = {}
var _aim_centre := Vector3(0.5, 0.5, 0.5)


func configure(unit: Node3D) -> void:
	_unit = unit


func capture_root(unit: Node3D, visual_root: Node3D) -> void:
	_unit = unit
	_visual_root = visual_root
	_root_rest = visual_root.transform if visual_root != null else Transform3D.IDENTITY


func capture_model() -> void:
	_rests.clear()
	var markers: Array[Node3D] = []
	for child in _visual_root.get_children():
		_capture_descendants(child, markers)
	var bounds := AABB()
	var found := false
	for marker in markers:
		var marker_bounds: AABB = marker.get_meta("selection_bounds")
		for x in [marker_bounds.position.x, marker_bounds.end.x]:
			for y in [marker_bounds.position.y, marker_bounds.end.y]:
				for z in [marker_bounds.position.z, marker_bounds.end.z]:
					var point := unit_transform(marker) * Vector3(x, y, z)
					if found:
						bounds = bounds.expand(point)
					else:
						bounds = AABB(point, Vector3.ZERO)
						found = true
	# AuthoredModel applies its missing-marker box in Unit space.
	_aim_centre = bounds.get_center() if found else Vector3(0.5, 0.5, 0.5)


func _capture_descendants(node: Node, markers: Array[Node3D]) -> void:
	if node is Node3D:
		var spatial := node as Node3D
		_rests[_visual_root.get_path_to(spatial)] = spatial.transform
		if spatial.has_meta("selection_bounds"):
			markers.append(spatial)
	for child in node.get_children():
		_capture_descendants(child, markers)


func rest_for(node: Node3D) -> Transform3D:
	if node == _visual_root:
		return _root_rest
	return _rests.get(_visual_root.get_path_to(node), Transform3D.IDENTITY)


func has_rest(node: Node3D) -> bool:
	return node == _visual_root or _rests.has(_visual_root.get_path_to(node))


func unit_transform(node: Node3D) -> Transform3D:
	var chain: Array[Node3D] = []
	var current: Node = node
	while current != null and current != _visual_root:
		if current is Node3D:
			chain.push_front(current as Node3D)
		current = current.get_parent()
	var result := _root_rest
	for descendant in chain:
		result *= rest_for(descendant)
	return result


func model_transform() -> Transform3D:
	return Transform3D(_unit.global_basis, _unit.call("simulation_position")) * _root_rest


func world_transform(node: Node3D) -> Transform3D:
	return Transform3D(_unit.global_basis, _unit.call("simulation_position")) * unit_transform(node)


func aim_position() -> Vector3:
	return _unit.call("simulation_position") + _unit.global_basis * _aim_centre
