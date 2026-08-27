class_name NavSpatialHash
extends RefCounted
## Uniform-grid spatial hash of navigation agents, rebuilt once per navigation
## tick and queried per agent for nearby-agent candidate lists.

const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")


## simulation_position(), not global_position, since slice R4, and this read
## had to move with the ground-navigation group rather than after it: these
## buckets are the neighbour candidate lists GroundNavigation.tick() queries,
## and that query has asked the store since slice R3. Keying the buckets from
## the node while looking them up with a store position would put an agent in
## one bucket and search for it in another the moment the two disagreed.
## Inside a match they never do, so nothing was broken -- which is exactly why
## the pair had to travel together instead of leaving a real inconsistency
## sitting in the tree between two slices. `unit` stays a bare Node3D: this
## module is duck-typed on the agent's node like the rest of navigation, so
## the call is resolved at runtime and a test double has to answer it.
func build(agents: Array[Dictionary]) -> Dictionary:
	var buckets := {}
	for agent in agents:
		var unit: Node3D = agent["unit"]
		var unit_position: Vector3 = unit.simulation_position()
		var key := bucket_key(unit_position)
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(agent)
	return buckets


func nearby(position: Vector3, buckets: Dictionary, search_radius := NavConstantsScript.CELL_BUCKET_SIZE) -> Array:
	var center := bucket_key(position)
	var result := []
	var bucket_radius := maxi(1, ceili(search_radius / NavConstantsScript.CELL_BUCKET_SIZE))
	for y in range(-bucket_radius, bucket_radius + 1):
		for x in range(-bucket_radius, bucket_radius + 1):
			result.append_array(buckets.get(center + Vector2i(x, y), []))
	return result


func bucket_key(position: Vector3) -> Vector2i:
	return Vector2i(
		floori(position.x / NavConstantsScript.CELL_BUCKET_SIZE),
		floori(position.z / NavConstantsScript.CELL_BUCKET_SIZE)
	)
