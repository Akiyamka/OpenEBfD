class_name BuildingSaleService
extends RefCounted

signal completed(player_id: int, display_name: String, refund: int)

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")


class PlayerSale extends RefCounted:
	var building: Node3D
	var player
	var refund := 0


var _by_player_id: Dictionary = {}


func is_active(player_id: int) -> bool:
	var sale: PlayerSale = _by_player_id.get(player_id)
	return sale != null and is_instance_valid(sale.building)


func start(building: Node3D, player_id: int, player, config: Resource) -> bool:
	if is_active(player_id) or building == null:
		return false
	var sale := PlayerSale.new()
	sale.building = building
	sale.player = player
	sale.refund = maxi(int(config.cost) / 2, 0) if config != null else 0
	_by_player_id[player_id] = sale
	var animation_player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	if AuthoredModelScript.play_one_shot(
		building, &"sell", _on_animation_finished.bind(player_id, building, &"sell")
	):
		return true
	if animation_player != null and animation_player.has_animation(&"construct"):
		var animation := animation_player.get_animation(&"construct")
		if animation != null:
			animation.loop_mode = Animation.LOOP_NONE
		animation_player.animation_finished.connect(
			_on_animation_finished.bind(player_id, building, &"construct"), CONNECT_ONE_SHOT
		)
		AuthoredModelScript.play_state(building, &"construct")
		animation_player.seek(animation.length if animation != null else 0.0, true)
		animation_player.play_backwards(&"construct")
		animation_player.advance(0.0)
		return true
	_finish(player_id, building)
	return true


func _on_animation_finished(
		animation_name: StringName, player_id: int, building: Node3D, sale_animation: StringName
) -> void:
	if animation_name == sale_animation:
		_finish(player_id, building)


func _finish(player_id: int, building: Node3D) -> void:
	var sale: PlayerSale = _by_player_id.get(player_id)
	if sale == null or building != sale.building:
		return
	if sale.player != null and sale.refund > 0:
		sale.player.add_money(sale.refund)
	var display_name := String(building.get("config_id"))
	if display_name.is_empty():
		display_name = building.name
	var refund := sale.refund
	_by_player_id.erase(player_id)
	building.call("request_despawn")
	completed.emit(player_id, display_name, refund)
