class_name EntityNodeIndex
extends RefCounted

## Binds a stable entity id (scripts/sim/entity_registry.gd) to the live Node
## that currently represents it. This lives outside the sim zone deliberately
## -- something has to hold Node references, and the sim layer is forbidden
## from doing so; see docs/architecture/network-multiplayer.md, decision 3,
## and the sim-no-node-api rule in tools/architecture_rules.toml.

const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")

var _registry: SimEntityRegistry
## node.get_instance_id() -> entity id. Keyed by the instance id, not the node
## object itself: get_instance_id() is a legitimate use here, a local,
## per-process Dictionary key, which is all it was ever good for. It is not
## the stable id a command or a replay names an entity by -- that is what
## SimEntityRegistry.allocate() returns, and what this dictionary maps to.
var _id_by_instance: Dictionary = {}
## entity id -> Node.
var _node_by_id: Dictionary = {}


func _init() -> void:
	_registry = SimEntityRegistryScript.new()


func registry() -> SimEntityRegistry:
	return _registry


## Allocates an id for `node` and binds it both ways. Registering the same
## node twice is a no-op past the first call: it returns the existing id
## rather than allocating a second one.
func register(node: Node, kind: int) -> int:
	var instance_id := node.get_instance_id()
	if _id_by_instance.has(instance_id):
		return int(_id_by_instance[instance_id])
	var id := _registry.allocate(kind)
	_id_by_instance[instance_id] = id
	_node_by_id[id] = node
	return id


func release_node(node: Node) -> void:
	release_id(id_for(node))


## Releases `id` in the registry and drops both bindings. A no-op for an id
## that is not currently bound to a node.
func release_id(id: int) -> void:
	if id == 0:
		return
	var node: Node = _node_by_id.get(id)
	if node != null and is_instance_valid(node):
		_id_by_instance.erase(node.get_instance_id())
	_node_by_id.erase(id)
	_registry.release(id)


## The node bound to `id`, or null if the id is unknown, released, or the node
## has since been freed. The is_instance_valid() check matters: queue_free()
## does not drop a node from its groups (or from here, since nothing else
## reaches in to clean this index up) until the end of the frame -- see the
## is_instance_valid() guards in Match._advance_simulation_tick().
func node_for(id: int) -> Node:
	if not _registry.is_alive(id):
		return null
	var node: Node = _node_by_id.get(id)
	if node == null or not is_instance_valid(node):
		return null
	return node


## 0 when `node` is not registered (including a freed or null node).
func id_for(node: Node) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	return int(_id_by_instance.get(node.get_instance_id(), 0))
