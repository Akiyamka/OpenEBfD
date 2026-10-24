extends RefCounted

const HOLD_ANIMATION := &"Deploy_Gun_Hold"

var _snapshot: RefCounted
var _model_root: Node3D
var _rests: Dictionary = {}
var _chains: Dictionary = {}
var _yaw_pivot: Node3D
var _pitch_pivot: Node3D


func configure(
		snapshot: RefCounted, model_root: Node3D, deploy_only: bool,
		yaw_pivot: Node3D, pitch_pivot: Node3D
	) -> void:
	_snapshot = snapshot
	_model_root = model_root
	_yaw_pivot = yaw_pivot
	_pitch_pivot = pitch_pivot
	_rests.clear()
	_chains.clear()
	var player := model_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var hold: Animation = player.get_animation(HOLD_ANIMATION) \
		if deploy_only and player != null and player.has_animation(HOLD_ANIMATION) else null
	var track_root: Node = player.get_node_or_null(player.root_node) \
		if hold != null else null
	_capture(model_root, hold, track_root)


func _capture(node: Node, hold: Animation, track_root: Node) -> void:
	if node is Node3D:
		var spatial := node as Node3D
		var rest: Transform3D = _snapshot.call("rest_for", spatial)
		if hold != null and track_root != null and (track_root == spatial \
			or track_root.is_ancestor_of(spatial)):
			var track_path := NodePath("%s:transform" % String(track_root.get_path_to(spatial)))
			var track := hold.find_track(track_path, Animation.TYPE_VALUE)
			if track >= 0 and hold.track_get_key_count(track) > 0:
				var value: Variant = hold.track_get_key_value(track, 0)
				if typeof(value) == TYPE_TRANSFORM3D:
					rest = value
		_rests[spatial] = rest
	for child in node.get_children():
		_capture(child, hold, track_root)


func rest_for(node: Node3D) -> Transform3D:
	if _rests.has(node):
		return _rests[node]
	return _snapshot.call("rest_for", node)


func world_transform(node: Node3D, yaw: float, pitch: float) -> Transform3D:
	if not _chains.has(node):
		var found: Array[Node3D] = []
		var current: Node = node
		while current != null and current != _model_root:
			if current is Node3D:
				found.push_front(current as Node3D)
			current = current.get_parent()
		_chains[node] = found
	var chain: Array[Node3D] = _chains[node]
	var result := model_transform()
	for descendant in chain:
		var rest := rest_for(descendant)
		var aim_yaw := yaw if descendant == _yaw_pivot else 0.0
		var aim_pitch := pitch if descendant == _pitch_pivot else 0.0
		if aim_yaw != 0.0 or aim_pitch != 0.0:
			rest = Transform3D(
				rest.basis * Basis(Vector3.UP, aim_yaw) * Basis(Vector3.RIGHT, aim_pitch),
				rest.origin
			)
		result *= rest
	return result


func model_transform() -> Transform3D:
	return _snapshot.call("model_transform")
