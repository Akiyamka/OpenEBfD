class_name BuildingAvailabilityTracker
extends RefCounted

## Answers one question: can technology-tree availability have changed since the
## last recompute?
##
## Both option grids need it and both need the same answer, because both depend
## on the same facts -- which buildings are in the tree, who owns them, whether
## they finished construction, whether they were upgraded. BuildingController
## gates the building grid on it; UnitRosterController gates the unit grid.
## Recomputing unconditionally instead costs an O(ids x buildings) scan per
## frame, which is milliseconds once a base is standing -- `make godot-perf`
## measures it.
##
## The tracker only reports staleness. What availability *is* stays with each
## grid, which knows its own definitions and its own player.

## instance id -> WeakRef of a tracked building. Instance ids, not the nodes:
## a tracked building can be freed between the removal signal and the cleanup.
var _tracked: Dictionary = {}
var _dirty := true
## The Node whose SceneTree this tracker listens to. Untyped access only
## (get_tree(), group queries) -- the tracker never reaches into its host.
var _host: Node = null


## Starts listening. Safe to call again on a host that re-entered the tree:
## every connect below is guarded, and unbind() tears the previous set down.
func bind(host: Node) -> void:
	_host = host
	var tree := _tree()
	if tree == null:
		return
	if not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
	if not tree.node_removed.is_connected(_on_node_removed):
		tree.node_removed.connect(_on_node_removed)
	for building in tree.get_nodes_in_group("buildings"):
		_track(building)
	mark_dirty()


## Symmetric counterpart of bind(), for the host's _exit_tree().
func unbind() -> void:
	var tree := _tree()
	if tree != null:
		if tree.node_added.is_connected(_on_node_added):
			tree.node_added.disconnect(_on_node_added)
		if tree.node_removed.is_connected(_on_node_removed):
			tree.node_removed.disconnect(_on_node_removed)
	# Disconnect every still-tracked building's subscriptions too, not just
	# forget them -- otherwise a host that re-enters the tree and binds again
	# reconnects on top of connections this teardown never removed, and Godot
	# errors with "Signal is already connected" on the next signal that
	# building fires.
	for instance_id in _tracked.keys():
		var building_ref: WeakRef = _tracked[instance_id]
		var node: Node = building_ref.get_ref() if building_ref != null else null
		if node != null and is_instance_valid(node):
			_untrack(node)
	_tracked.clear()


func mark_dirty() -> void:
	_dirty = true


func is_dirty() -> bool:
	return _dirty


## Reads the flag and clears it, so a caller that recomputes on the strength of
## a true answer cannot forget to.
func consume_dirty() -> bool:
	var was_dirty := _dirty
	_dirty = false
	return was_dirty


## The buildings availability is computed against, in the typed form
## TechnologyTree.is_available() takes. One array per recompute: callers used to
## rebuild this per option id, which is where the O(ids x buildings) came from.
func buildings() -> Array[Node]:
	var result: Array[Node] = []
	var tree := _tree()
	if tree != null:
		result.assign(tree.get_nodes_in_group("buildings"))
	return result


func _tree() -> SceneTree:
	return _host.get_tree() if _host != null and is_instance_valid(_host) else null


func _on_node_added(node: Node) -> void:
	# node_added precedes Building._ready(), where the group is assigned.
	if node.is_in_group("buildings"):
		_track(node)
		return
	# node_added fires for every node entering the tree -- projectiles,
	# decals, particles, corpses -- so cheaply rule out anything that can
	# never end up a tracked building before waiting for its ready signal.
	# Building (and the BuildingStub test double, which is a plain Node, not
	# Node3D) always declares construction_completed; incidental scenery
	# never does, so that alone is the filter -- do not additionally require
	# `is Node3D` here, or the test double stops matching.
	if node.has_signal("construction_completed"):
		# The signal fires after Building._ready() has joined "buildings", but
		# still within the tick that created this node. call_deferred() needed a
		# rendered frame to make that same post-ready check, leaving a frameless
		# tick loop with a clean availability cache on the next order.
		node.ready.connect(_track.bind(node), CONNECT_ONE_SHOT)


func _on_node_removed(node: Node) -> void:
	# node_removed fires for every node in the game. Marking availability dirty
	# unconditionally turned any churn into a full recompute on the next frame --
	# and BuildingPlacement churns hard: every cursor move while stretching a wall
	# line releases its preview cells through remove_child(), so the O(ids x
	# buildings) scan this cache exists to avoid ran every frame of the drag.
	if _untrack(node):
		mark_dirty()


func _track(candidate: Variant) -> void:
	# A node can leave the tree before this deferred post-ready check runs.
	if not is_instance_valid(candidate) or not candidate is Node:
		return
	var node := candidate as Node
	if not node.is_in_group("buildings"):
		return
	var instance_id := node.get_instance_id()
	if _tracked.has(instance_id):
		return
	_tracked[instance_id] = weakref(node)
	if node.has_signal("owner_changed") \
			and not node.is_connected("owner_changed", _on_owner_changed):
		node.connect("owner_changed", _on_owner_changed)
	if node.has_signal("construction_completed") \
			and not node.is_connected("construction_completed", mark_dirty):
		node.connect("construction_completed", mark_dirty)
	if node.has_signal("upgrade_level_changed") \
			and not node.is_connected("upgrade_level_changed", _on_upgrade_changed):
		node.connect("upgrade_level_changed", _on_upgrade_changed)
	if not node.tree_exiting.is_connected(mark_dirty):
		node.tree_exiting.connect(mark_dirty)
	mark_dirty()


## Returns whether the node really was one of the tracked buildings -- callers
## use that to decide whether anything about availability can have changed.
func _untrack(node: Node) -> bool:
	if not _tracked.erase(node.get_instance_id()):
		return false
	if not is_instance_valid(node):
		return true
	if node.has_signal("owner_changed") \
			and node.is_connected("owner_changed", _on_owner_changed):
		node.disconnect("owner_changed", _on_owner_changed)
	if node.has_signal("construction_completed") \
			and node.is_connected("construction_completed", mark_dirty):
		node.disconnect("construction_completed", mark_dirty)
	if node.has_signal("upgrade_level_changed") \
			and node.is_connected("upgrade_level_changed", _on_upgrade_changed):
		node.disconnect("upgrade_level_changed", _on_upgrade_changed)
	if node.tree_exiting.is_connected(mark_dirty):
		node.tree_exiting.disconnect(mark_dirty)
	return true


func _on_owner_changed(_player_id: int) -> void:
	mark_dirty()


func _on_upgrade_changed(_level: int) -> void:
	mark_dirty()
