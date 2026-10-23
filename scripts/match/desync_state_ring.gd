class_name DesyncStateRing
extends RefCounted

const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")

var _capacity: int
var _captures: Array[Dictionary] = []


func _init(capacity: int) -> void:
	_capacity = capacity


func capture(tick: int, entity_state, entity_index, navigation) -> void:
	var registry = entity_index.registry()
	var entities: Array[Dictionary] = []
	for id in registry.live_ids():
		var entity := {"id": id, "kind": registry.kind_of(id)}
		_capture_hashed_fields(entity, id, entity_state)
		var node: Node = entity_index.node_for(id)
		if node != null:
			_capture_node_fields(entity, node, navigation)
		entities.append(entity)
	_captures.append({"tick": tick, "entities": entities})
	while _captures.size() > _capacity:
		_captures.pop_front()


func has_tick(tick: int) -> bool:
	for stored_capture in _captures:
		if int(stored_capture["tick"]) == tick:
			return true
	return false


func retained_ticks() -> PackedInt32Array:
	var ticks := PackedInt32Array()
	for stored_capture in _captures:
		ticks.append(int(stored_capture["tick"]))
	return ticks


func lines_for(tick: int) -> PackedStringArray:
	for stored_capture in _captures:
		if int(stored_capture["tick"]) == tick:
			return _lines_for_capture(stored_capture)
	return PackedStringArray(["[desync-state] no state retained for tick %d" % tick])


func _capture_hashed_fields(entity: Dictionary, id: int, entity_state) -> void:
	if entity_state.has_position(id):
		entity["position"] = entity_state.position(id)
	if entity_state.has_health(id):
		entity["health"] = entity_state.health(id)
	if entity_state.has_shields(id):
		entity["shields"] = entity_state.shields(id)
	if entity_state.has_owner_player_id(id):
		entity["owner"] = entity_state.owner_player_id(id)
	if entity_state.has_invulnerability(id):
		entity["invulnerable"] = entity_state.invulnerable(id)
		entity["invulnerability_remaining_ticks"] = entity_state.invulnerability_remaining_ticks(id)
	if entity_state.has_combat_line_bounds(id):
		entity["line_r"] = entity_state.combat_line_radius(id)
		entity["line_ymin"] = entity_state.combat_line_min_y(id)
		entity["line_ymax"] = entity_state.combat_line_max_y(id)
	if entity_state.has_combat_line_carried(id):
		entity["line_carried"] = entity_state.combat_line_carried(id)


func _capture_node_fields(entity: Dictionary, node: Node, navigation) -> void:
	var spatial_node := node as Node3D
	if spatial_node != null and int(entity["kind"]) == SimEntityRegistryScript.Kind.UNIT and navigation != null:
		var nav: Dictionary = navigation.agent_debug(spatial_node)
		if not nav.is_empty():
			entity["nav"] = nav
			entity["hull_yaw"] = spatial_node.global_rotation.y
	var turrets = node.get("combat_turrets")
	if turrets is Array:
		var snapshots: Array[Dictionary] = []
		for turret in turrets:
			snapshots.append({
				"weapon": turret.weapon_index(),
				"yaw": turret.current_yaw,
				"pitch": turret.current_pitch,
			})
		entity["turrets"] = snapshots


func _lines_for_capture(stored_capture: Dictionary) -> PackedStringArray:
	var entities: Array = stored_capture["entities"]
	var lines := PackedStringArray([
		"[desync-state] state after tick %d: %d live entities" % [stored_capture["tick"], entities.size()],
	])
	for entity: Dictionary in entities:
		lines.append(_entity_line(entity))
		if entity.has("nav"):
			lines.append(_nav_line(entity))
		for turret: Dictionary in entity.get("turrets", []):
			lines.append(_turret_line(entity, turret))
	return lines


func _entity_line(entity: Dictionary) -> String:
	var position := _vector_token(entity["position"]) if entity.has("position") else "-"
	var health := _float32_token(float(entity["health"])) if entity.has("health") else "-"
	var shields := _float32_token(float(entity["shields"])) if entity.has("shields") else "-"
	var owner := str(entity["owner"]) if entity.has("owner") else "-"
	var invulnerability := "-"
	if entity.has("invulnerable"):
		invulnerability = "%d/%d" % [1 if bool(entity["invulnerable"]) else 0, entity["invulnerability_remaining_ticks"]]
	var line_r := _float32_token(float(entity["line_r"])) if entity.has("line_r") else "-"
	var line_ymin := _float32_token(float(entity["line_ymin"])) if entity.has("line_ymin") else "-"
	var line_ymax := _float32_token(float(entity["line_ymax"])) if entity.has("line_ymax") else "-"
	var line_carried := "%d[%02x]" % [1 if bool(entity["line_carried"]) else 0, 1 if bool(entity["line_carried"]) else 0] if entity.has("line_carried") else "-"
	return "[desync-state] entity %d %s pos=%s hp=%s sh=%s own=%s inv=%s line_r=%s line_ymin=%s line_ymax=%s line_carried=%s" % [
		entity["id"], _kind_name(int(entity["kind"])), position, health, shields, owner, invulnerability, line_r, line_ymin, line_ymax, line_carried,
	]


func _nav_line(entity: Dictionary) -> String:
	var nav: Dictionary = entity["nav"]
	return "[desync-state] nav %d agent=%d cmd=%d mode=%d order=%d hold=%d anchor=%d reserved=%d turn=%d yaw=%s dest=%s steer=%s path=%d/%d blocked=%s yield=%s ydir=%s swap=%d orca=%s avoid=%s" % [
		entity["id"], nav["id"], nav["command_id"], nav["mode"],
		1 if bool(nav["active_order"]) else 0, 1 if bool(nav["hold"]) else 0,
		1 if bool(nav["firing_anchor"]) else 0, 1 if bool(nav["reserved"]) else 0,
		1 if bool(nav["steering_turn_in_place"]) else 0, _float32_token(float(entity["hull_yaw"])),
		_vector_token(nav["destination"]), _vector_token(nav["steering_target"]),
		nav["path_index"], nav["path_size"], _float64_token(float(nav["blocked_time"])),
		_float64_token(float(nav["yield_remaining"])), _vector_token(nav["yield_direction"]),
		nav["swap_tick"], _vector_token(nav["orca_velocity"]), _vector_token(nav["avoidance_direction"]),
	]


func _turret_line(entity: Dictionary, turret: Dictionary) -> String:
	return "[desync-state] turret %d weapon=%d yaw=%s pitch=%s" % [
		entity["id"], turret["weapon"], _float64_token(float(turret["yaw"])), _float64_token(float(turret["pitch"])),
	]


func _kind_name(kind: int) -> String:
	if kind == SimEntityRegistryScript.Kind.UNIT:
		return "unit"
	if kind == SimEntityRegistryScript.Kind.BUILDING:
		return "building"
	return "kind%d" % kind


func _vector_token(value: Vector3) -> String:
	return "%s[%s]" % [str(value), PackedVector3Array([value]).to_byte_array().hex_encode()]


func _float32_token(value: float) -> String:
	return "%s[%s]" % [str(value), PackedFloat32Array([value]).to_byte_array().hex_encode()]


func _float64_token(value: float) -> String:
	return "%s[%s]" % [str(value), PackedFloat64Array([value]).to_byte_array().hex_encode()]
