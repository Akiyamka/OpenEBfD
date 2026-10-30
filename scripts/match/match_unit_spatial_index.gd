extends RefCounted

const PersistentUnitGridScript := preload("res://scripts/sim/persistent_unit_grid.gd")
const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const SimAdmissionQueueScript := preload("res://scripts/match/sim_admission_queue.gd")

var _owner: Node
var _index: EntityNodeIndexScript
var _state: SimEntityStateScript
var _queue: SimAdmissionQueueScript
var _grid := PersistentUnitGridScript.new()
var _generation := -1
var _last_dirty_count := 0


func _init(owner: Node, index: EntityNodeIndexScript, state: SimEntityStateScript, queue: SimAdmissionQueueScript) -> void:
	_owner = owner
	_index = index
	_state = state
	_queue = queue


func sync() -> void:
	if _generation == _state.spatial_reset_generation() \
	and _state.spatial_dirty_count() == 0 \
	and _queue.spatial_admission_count() == 0 \
	and _index.registry().spatial_release_count() == 0:
		_last_dirty_count = 0
		return
	var ids: Dictionary = {}
	if _generation != _state.spatial_reset_generation():
		_grid.clear()
		_generation = _state.spatial_reset_generation()
		for node in _owner.get_tree().get_nodes_in_group(&"sim_units"):
			if is_instance_valid(node) and (_owner == node or _owner.is_ancestor_of(node)):
				var id := _index.id_for(node)
				if id > 0:
					ids[id] = true
	for id in _state.take_spatial_dirty_ids():
		ids[id] = true
	_last_dirty_count = ids.size()
	for node in _queue.take_spatial_admissions():
		if is_instance_valid(node) and (_owner == node or _owner.is_ancestor_of(node)):
			var id := _index.id_for(node)
			if id > 0:
				ids[id] = true
	for id in _index.registry().take_spatial_releases():
		ids[id] = true
	var sorted := PackedInt32Array()
	for id in ids:
		sorted.append(id)
	sorted.sort()
	for id in sorted:
		_update_id(id)


func _update_id(id: int) -> void:
	var registry := _index.registry()
	if not registry.is_alive(id) or registry.kind_of(id) != SimEntityRegistryScript.Kind.UNIT \
	or not _state.has_position(id) or not _state.has_combat_line_bounds(id) \
	or (_state.has_combat_line_carried(id) and _state.combat_line_carried(id)):
		_grid.remove(id)
		return
	if not _grid.has_id(id):
		var node := _index.node_for(id)
		if node == null or not node.is_in_group(&"sim_units") \
		or not (_owner == node or _owner.is_ancestor_of(node)):
			return
	_grid.upsert(id, _state.position(id), _state.combat_line_radius(id))


func rectangle_candidates(min_xz: Vector2, max_xz: Vector2) -> PackedInt32Array:
	sync()
	return _grid.rectangle_candidates(min_xz, max_xz)


func padded_segment_candidates(from: Vector3, to: Vector3, padding: float) -> PackedInt32Array:
	sync()
	return _grid.padded_segment_candidates(from, to, padding)


func bucket_writes() -> int:
	return _grid.bucket_writes()


func query_cell_probes() -> int:
	return _grid.query_cell_probes()


func last_dirty_count() -> int:
	return _last_dirty_count


func has_raw_id(id: int) -> bool:
	return _grid.has_id(id)
