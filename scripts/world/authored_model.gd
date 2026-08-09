class_name AuthoredModel
extends RefCounted


static func animation_players(root: Node) -> Array[AnimationPlayer]:
	var result: Array[AnimationPlayer] = []
	if root == null:
		return result
	if root is AnimationPlayer:
		result.append(root as AnimationPlayer)
	for node in root.find_children("*", "AnimationPlayer", true, false):
		result.append(node as AnimationPlayer)
	return result


static func mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if root == null:
		return result
	if root is MeshInstance3D:
		result.append(root as MeshInstance3D)
	for node in root.find_children("*", "MeshInstance3D", true, false):
		result.append(node as MeshInstance3D)
	return result


## Meshes the converter tagged as continuously scrolling (windtrap blades,
## unit energy shields). Their phase is driven per frame by the owner, since a
## baked track would snap back to 0 on every clip loop.
static func scroll_fx_meshes(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh_instance in mesh_instances(root):
		if mesh_instance.has_meta("scroll_fx"):
			result.append(mesh_instance)
	return result


## Meshes the converter tagged as scrolling only while the owner drives: the
## vehicle track belts. Same fx_time channel as scroll_fx_meshes(), but the
## phase comes from distance travelled, so the belt stands still on idle and on
## a turn in place. Buildings never drive these, so a static model that happens
## to carry the same track texture stays static.
static func move_scroll_fx_meshes(root: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh_instance in mesh_instances(root):
		if mesh_instance.has_meta("scroll_fx_move"):
			result.append(mesh_instance)
	return result


## The node an animation track drives, resolved through the player's own
## animation root — the track path is relative to it, not to the player.
static func track_node(player: AnimationPlayer, track_path: String) -> Node:
	if player == null:
		return null
	var animation_root := player.get_node_or_null(player.root_node)
	if animation_root == null:
		return null
	var separator := track_path.find(":")
	var node_path := track_path.substr(0, separator) if separator >= 0 else track_path
	return animation_root.get_node_or_null(NodePath(node_path))


## True when a track actually animates something. Converted clips carry tracks
## that repeat one value for their whole length; those describe a rest pose,
## not motion, and layering them would fight whatever else owns the node.
static func track_changes(animation: Animation, track: int) -> bool:
	if animation.track_get_key_count(track) < 2:
		return false
	var first: Variant = animation.track_get_key_value(track, 0)
	for key in range(1, animation.track_get_key_count(track)):
		var value: Variant = animation.track_get_key_value(track, key)
		if first is Transform3D and value is Transform3D:
			var a := first as Transform3D
			var b := value as Transform3D
			if not a.origin.is_equal_approx(b.origin) \
			or not a.basis.is_equal_approx(b.basis):
				return true
		elif value != first:
			return true
	return false


static func find_clip(players: Array[AnimationPlayer], candidates: Array[StringName]) -> Dictionary:
	for candidate in candidates:
		for player in players:
			if player.has_animation(candidate):
				return {"player": player, "name": candidate}
	return {"player": null, "name": &""}


static func clip_length(clip: Dictionary) -> float:
	var player := clip.get("player") as AnimationPlayer
	var name := StringName(clip.get("name", &""))
	if player == null or name == &"" or not player.has_animation(name):
		return 0.0
	var animation := player.get_animation(name)
	return animation.length if animation != null else 0.0


static func play_clip(clip: Dictionary) -> bool:
	var player := clip.get("player") as AnimationPlayer
	var name := StringName(clip.get("name", &""))
	if player == null or name == &"" or not player.has_animation(name):
		return false
	player.play(name)
	return true


static func play_one_shot(root: Node, clip: StringName, on_finished: Callable = Callable()) -> bool:
	var found := find_clip(animation_players(root), [clip])
	var player := found.get("player") as AnimationPlayer
	if player == null:
		return false
	var animation := player.get_animation(clip)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
	if on_finished.is_valid() and not player.animation_finished.is_connected(on_finished):
		player.animation_finished.connect(on_finished, CONNECT_ONE_SHOT)
	if root.has_method("play_state"):
		root.call("play_state", clip)
		return true
	return play_clip(found)


static func play_state(node: Node, state: StringName) -> void:
	if node == null:
		return
	if node.has_method("play_state"):
		node.call("play_state", state)
		return
	var player := node.get_node_or_null("StatePlayer") as AnimationPlayer
	if player != null and player.has_animation(state):
		player.play(state)


static func collision_sources(
	root: Node,
	prefix_order: Array,
	hide_source_meshes := true
	) -> Array[Node3D]:
	for descriptor in prefix_order:
		var result: Array[Node3D] = []
		var name := String(descriptor.get("name", ""))
		var prefix := bool(descriptor.get("prefix", false))
		_collect_collision_sources(root, name, prefix, hide_source_meshes, result)
		if not result.is_empty():
			return result
	return []


static func add_selection_collision(owner: Node3D, sources: Array[Node3D]) -> StaticBody3D:
	var bounds := AABB()
	var has_bounds := false
	var body := StaticBody3D.new()
	body.name = "SelectionCollision"
	body.collision_layer = 2
	body.collision_mask = 0
	if owner.get_node_or_null("CombatCollision") != null:
		body.set_meta("combat_ignore", true)
	for source in sources:
		var shape := _collision_shape(source)
		if shape == null:
			push_warning("AuthoredModel: collision source %s has no usable convex shape" % source.get_path())
			continue
		var collision := CollisionShape3D.new()
		collision.name = "AuthoredCollision"
		collision.shape = shape
		collision.transform = owner.global_transform.affine_inverse() * source.global_transform
		body.add_child(collision)
		for source_point in _collision_bounds_points(source):
			var point := owner.to_local(source.to_global(source_point))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
	if body.get_child_count() == 0:
		body.free()
		return null
	if has_bounds:
		body.set_meta("collision_bounds", bounds)
	owner.add_child(body)
	return body


## Distance from the node's origin to the front edge of its baked selection
## collision. Converted Emperor models are Z-mirrored, placing their exit/apron
## on local +Z, so the positive-Z extent is the front-edge distance.
##
## One implementation on purpose: rally-point placement and refinery-front
## placement both measure the same edge, and when this lived as a private
## method it was shared by all three call sites. Two copies drifted apart once,
## which only showed on the no-occupy-rows fallback path.
static func front_collision_extent(node: Node3D) -> float:
	var collision_body := node.get_node_or_null("SelectionCollision") as StaticBody3D
	if collision_body == null or not collision_body.has_meta("collision_bounds"):
		return 0.0
	var bounds: AABB = collision_body.get_meta("collision_bounds")
	return maxf(absf(bounds.position.z), absf(bounds.end.z))


static func selection_bounds(root: Node, coordinate_root: Node3D) -> AABB:
	var markers: Array[Node3D] = []
	_collect_meta_nodes(root, &"selection_bounds", markers)
	var bounds := AABB()
	var has_bounds := false
	for marker in markers:
		var marker_bounds: AABB = marker.get_meta("selection_bounds")
		for corner in _aabb_corners(marker_bounds):
			var point := coordinate_root.to_local(marker.to_global(corner))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
	return bounds if has_bounds else AABB(Vector3.ZERO, Vector3.ONE)


static func _collect_collision_sources(
	node: Node,
	name: String,
	prefix: bool,
	hide_source_meshes: bool,
	result: Array[Node3D]
	) -> void:
	if node == null:
		return
	if node is Node3D:
		var source_name := String(node.get_meta("original_name", ""))
		var matches := source_name.to_lower().begins_with(name) if prefix else source_name == name
		var points: PackedVector3Array = node.get_meta("collision_points", PackedVector3Array())
		if matches and points.size() >= 4:
			if hide_source_meshes:
				for child in node.get_children():
					if child is MeshInstance3D and child.has_meta("collision_mesh"):
						child.visible = false
			result.append(node)
			return
	for child in node.get_children():
		_collect_collision_sources(child, name, prefix, hide_source_meshes, result)


static func _collision_shape(source: Node3D) -> Shape3D:
	var points: PackedVector3Array = source.get_meta("collision_points", PackedVector3Array())
	if points.size() >= 4:
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		return shape
	for child in source.get_children():
		if child is MeshInstance3D and child.mesh != null:
			return child.mesh.create_convex_shape(true, false)
	return null


static func _collision_bounds_points(source: Node3D) -> PackedVector3Array:
	var points: PackedVector3Array = source.get_meta("collision_points", PackedVector3Array())
	if not points.is_empty():
		return points
	var bounds := PackedVector3Array()
	for child in source.get_children():
		if child is MeshInstance3D and child.mesh != null:
			for corner in _aabb_corners(child.get_aabb()):
				bounds.append(child.position + corner)
	return bounds


static func _collect_meta_nodes(node: Node, meta_name: StringName, result: Array[Node3D]) -> void:
	if node == null:
		return
	if node is Node3D and node.has_meta(meta_name):
		result.append(node)
	for child in node.get_children():
		_collect_meta_nodes(child, meta_name, result)


static func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				result.append(Vector3(x, y, z))
	return result
