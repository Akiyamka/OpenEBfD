class_name BuildingWallVisual
extends RefCounted

const WallConnectivityScript := preload("res://scripts/buildings/wall_connectivity.gd")

const WALL_ANCHOR_CELL_SPAN := 2
const OCCUPY_CELL_WORLD_SPAN := 2.0
const WORLD_NEIGHBOR_TOLERANCE := 0.35

var _owner: Node3D
var _connection_mask := 0
var _topology: StringName = WallConnectivityScript.SINGLE
var _rotation_quarters := 0


func configure(owner: Node3D) -> void:
	_owner = owner


func refresh_connections() -> void:
	if not _is_active():
		return
	refresh_topology()
	for candidate in _owner.get_tree().get_nodes_in_group("wall_buildings"):
		if candidate == _owner or not is_instance_valid(candidate) \
		or candidate.is_queued_for_deletion():
			continue
		if direction_to(candidate as Node3D) != 0:
			candidate.call("_refresh_wall_topology")


func connection_mask() -> int:
	return _connection_mask


func topology() -> StringName:
	return _topology


func rotation_quarters() -> int:
	return _rotation_quarters


func active_variant_path() -> NodePath:
	var variants := _owner.get_node_or_null("WallVariants")
	if variants == null:
		return NodePath()
	for variant in variants.get_children():
		for state_node in variant.get_children():
			if state_node is Node3D and state_node.visible:
				return state_node.get_path()
	return NodePath()


func refresh_topology() -> void:
	if not _is_active():
		return
	_connection_mask = _neighbor_mask()
	var selection: Dictionary = WallConnectivityScript.selection_for_mask(_connection_mask)
	_topology = selection["topology"]
	_rotation_quarters = int(selection["rotation_quarters"])
	refresh_variant_visual()


func direction_to(other: Node3D) -> int:
	if other == null:
		return 0
	if _owner.has_meta(&"placement_anchor_cell") and other.has_meta(&"placement_anchor_cell"):
		var delta: Vector2i = (
			other.get_meta(&"placement_anchor_cell") as Vector2i
			- _owner.get_meta(&"placement_anchor_cell") as Vector2i
		)
		match delta:
			Vector2i(0, -WALL_ANCHOR_CELL_SPAN):
				return WallConnectivityScript.NORTH
			Vector2i(WALL_ANCHOR_CELL_SPAN, 0):
				return WallConnectivityScript.EAST
			Vector2i(0, WALL_ANCHOR_CELL_SPAN):
				return WallConnectivityScript.SOUTH
			Vector2i(-WALL_ANCHOR_CELL_SPAN, 0):
				return WallConnectivityScript.WEST
			_:
				return 0

	var delta_world := other.global_position - _owner.global_position
	if absf(delta_world.x) <= WORLD_NEIGHBOR_TOLERANCE:
		if absf(delta_world.z + OCCUPY_CELL_WORLD_SPAN) <= WORLD_NEIGHBOR_TOLERANCE:
			return WallConnectivityScript.NORTH
		if absf(delta_world.z - OCCUPY_CELL_WORLD_SPAN) <= WORLD_NEIGHBOR_TOLERANCE:
			return WallConnectivityScript.SOUTH
	if absf(delta_world.z) <= WORLD_NEIGHBOR_TOLERANCE:
		if absf(delta_world.x - OCCUPY_CELL_WORLD_SPAN) <= WORLD_NEIGHBOR_TOLERANCE:
			return WallConnectivityScript.EAST
		if absf(delta_world.x + OCCUPY_CELL_WORLD_SPAN) <= WORLD_NEIGHBOR_TOLERANCE:
			return WallConnectivityScript.WEST
	return 0


func refresh_variant_visual() -> void:
	if not _has_wall_role():
		return
	var variants := _owner.get_node_or_null("WallVariants") as Node3D
	if variants != null:
		for variant in variants.get_children():
			if variant is Node3D:
				variant.visible = false
			for state_node in variant.get_children():
				if state_node is Node3D:
					state_node.visible = false

	var visual_state := String(_owner.current_state)
	if visual_state != "idle" and not visual_state.begins_with("damage"):
		# Non-idle states (construct, deconstruct, sell, ...) have only one
		# generic States/<state> mesh, not a per-topology WallVariants family,
		# so it can't be swapped for a pre-rotated model -- instead rotate that
		# single mesh by the same quarter-turn a WallVariants mesh would get
		# for this neighbour mask, so a segment between north/south neighbours
		# turns 90 degrees relative to one between east/west neighbours.
		# The visible child is found by visibility rather than state_root(),
		# because state_root() matches on the authored state name ("construction")
		# while current_state here holds the clip name ("construct").
		var transitional_states := _owner.get_node_or_null("States") as Node3D
		if transitional_states != null:
			for child in transitional_states.get_children():
				if child is Node3D and (child as Node3D).visible:
					(child as Node3D).rotation.y = (
						float(_rotation_quarters) * PI * 0.5 - transitional_states.global_rotation.y
					)
					break
		return
	if variants == null:
		return
	var state_player := _owner.get_node_or_null("StatePlayer") as AnimationPlayer
	if state_player != null:
		state_player.pause()

	var states := _owner.get_node_or_null("States")
	var base_state := _owner.call("state_root", _owner.current_state) as Node3D
	if states != null:
		for child in states.get_children():
			var child_state := String(child.get_meta("state", child.name.to_lower()))
			if child_state == "idle" or child_state.begins_with("damage"):
				child.visible = false

	if _topology == WallConnectivityScript.SINGLE:
		if base_state != null:
			base_state.visible = true
		return

	var variant_name := WallConnectivityScript.variant_node_name(_topology)
	var variant_root := variants.get_node_or_null(NodePath(String(variant_name))) as Node3D
	if variant_root == null:
		if base_state != null:
			base_state.visible = true
		return
	variant_root.visible = true
	variant_root.rotation.y = float(_rotation_quarters) * PI * 0.5 - variants.global_rotation.y

	var state_node_name := "Damage2" if visual_state.begins_with("damage") else "Idle"
	var active_state := variant_root.get_node_or_null(NodePath(state_node_name)) as Node3D
	if active_state == null:
		active_state = variant_root.get_node_or_null("Idle") as Node3D
	if active_state != null:
		active_state.visible = true
	elif base_state != null:
		base_state.visible = true


func defer_adjacent_refresh() -> void:
	var tree := _owner.get_tree()
	if tree == null:
		return
	# No shipping reader of these wall-topology values exists outside this
	# visual module, and navigation never reads wall connectivity. Deferring a
	# neighbour refresh can therefore leave a frameless view stale, not change
	# the simulation it draws.
	for candidate in tree.get_nodes_in_group("wall_buildings"):
		if candidate == _owner or not is_instance_valid(candidate) \
		or candidate.is_queued_for_deletion():
			continue
		if direction_to(candidate as Node3D) != 0:
			candidate.call_deferred("_refresh_wall_topology")


func _neighbor_mask() -> int:
	var mask := 0
	for candidate in _owner.get_tree().get_nodes_in_group("wall_buildings"):
		if candidate == _owner or not is_instance_valid(candidate) \
		or candidate.is_queued_for_deletion():
			continue
		mask |= direction_to(candidate as Node3D)
	return mask


func _is_active() -> bool:
	return _owner != null and _owner.is_inside_tree() and _has_wall_role()


func _has_wall_role() -> bool:
	return _owner.building_definition != null \
		and _owner.building_definition.roles.has("Wall")
