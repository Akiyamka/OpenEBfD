class_name AdvancedCarryallAbility
extends RefCounted
## Selection-level adapter for Advanced Carryall's two target abilities.
##
## It deliberately chooses one carrier from a group here, instead of making
## UnitCommandController know carrier details.  Future target abilities use
## the same `definitions`/`validate`/`execute` contract.

const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")

const PICKUP_ID := &"pickup"
const DROP_ID := &"drop"


func definitions(selection: Array[Node]) -> Array[Dictionary]:
	var available: Array[Dictionary] = []
	if _has_pickup_carrier(selection):
		available.append({
			"id": PICKUP_ID, "slot": PICKUP_ID, "label": "F",
			"tooltip": "Pick Up (F)", "keycode": KEY_F, "enabled": true,
		})
	if _has_drop_carrier(selection):
		available.append({
			"id": DROP_ID, "slot": DROP_ID, "label": "C",
			"tooltip": "Drop Cargo (C)", "keycode": KEY_C, "enabled": true,
		})
	return available


func validate(ability_id: StringName, selection: Array[Node], target, world_position := Vector3.INF) -> Dictionary:
	match ability_id:
		PICKUP_ID:
			var target_unit := target as Node3D
			if _nearest_pickup_carrier(selection, target_unit) != null:
				return {"valid": true, "message": ""}
			return {"valid": false, "message": "Select eligible ground vehicle"}
		DROP_ID:
			if _nearest_drop_carrier(selection, world_position) != null:
				return {"valid": true, "message": ""}
			return {"valid": false, "message": "Cargo cannot be dropped there"}
	return {"valid": false, "message": "Unknown ability"}


func cursor_for(ability_id: StringName, selection: Array[Node], target, world_position := Vector3.INF) -> int:
	var valid := bool(validate(ability_id, selection, target, world_position).get("valid", false))
	if ability_id == PICKUP_ID:
		return CursorManagerScript.CursorType.DN5 if valid else CursorManagerScript.CursorType.CANT_MOVE
	if ability_id == DROP_ID:
		return CursorManagerScript.CursorType.DEPLOY if valid else CursorManagerScript.CursorType.CANT_DEPLOY
	return CursorManagerScript.CursorType.CANT_MOVE


func execute(ability_id: StringName, selection: Array[Node], target, world_position := Vector3.INF) -> Dictionary:
	match ability_id:
		PICKUP_ID:
			var carrier := _nearest_pickup_carrier(selection, target as Node3D)
			if carrier != null and bool(carrier.call("command_pickup", target)):
				return {"ok": true, "message": "Carryall moving to pick up %s" % target.name}
		DROP_ID:
			var carrier := _nearest_drop_carrier(selection, world_position)
			if carrier != null and bool(carrier.call("command_drop", world_position)):
				return {"ok": true, "message": "Carryall moving to unload cargo"}
	return {"ok": false, "message": "Ability target is invalid"}


func _has_pickup_carrier(selection: Array[Node]) -> bool:
	for entity in selection:
		if _is_empty_advanced_carrier(entity):
			return true
	return false


func _has_drop_carrier(selection: Array[Node]) -> bool:
	for entity in selection:
		if _is_loaded_advanced_carrier(entity):
			return true
	return false


func _nearest_pickup_carrier(selection: Array[Node], target: Node3D) -> Node3D:
	if target == null:
		return null
	var candidates: Array[Node3D] = []
	for entity in selection:
		var carrier := entity as Node3D
		if carrier != null and carrier.has_method("can_pickup") \
		and bool(carrier.call("can_pickup", target)):
			candidates.append(carrier)
	return _nearest(candidates, target.simulation_position())


func _nearest_drop_carrier(selection: Array[Node], world_position: Vector3) -> Node3D:
	if not world_position.is_finite():
		return null
	var candidates: Array[Node3D] = []
	for entity in selection:
		var carrier := entity as Node3D
		if carrier != null and carrier.has_method("can_drop_at") \
		and bool(carrier.call("can_drop_at", world_position)):
			candidates.append(carrier)
	return _nearest(candidates, world_position)


func _is_empty_advanced_carrier(entity: Node) -> bool:
	return entity != null and is_instance_valid(entity) and entity.has_method("is_advanced_carryall") \
		and bool(entity.call("is_advanced_carryall")) \
		and entity.has_method("can_offer_transport_pickup") \
		and bool(entity.call("can_offer_transport_pickup")) \
		and entity.has_method("can_receive_commands") \
		and bool(entity.call("can_receive_commands"))


func _is_loaded_advanced_carrier(entity: Node) -> bool:
	return entity != null and is_instance_valid(entity) and entity.has_method("is_advanced_carryall") \
		and bool(entity.call("is_advanced_carryall")) \
		and entity.has_method("can_offer_transport_drop") \
		and bool(entity.call("can_offer_transport_drop")) \
		and entity.has_method("can_receive_commands") \
		and bool(entity.call("can_receive_commands"))


func _nearest(candidates: Array[Node3D], world_position: Vector3) -> Node3D:
	var closest: Node3D = null
	var closest_distance := INF
	for candidate in candidates:
		var distance: float = candidate.simulation_position().distance_squared_to(world_position)
		if distance < closest_distance \
		or (is_equal_approx(distance, closest_distance) and closest != null \
		and candidate.get_instance_id() < closest.get_instance_id()):
			closest = candidate
			closest_distance = distance
	return closest
