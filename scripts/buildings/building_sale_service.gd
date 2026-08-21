class_name BuildingSaleService
extends RefCounted

signal completed(display_name: String, refund: int)

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")

var _building: Node3D
var _player
var _refund := 0


func is_active() -> bool:
	return is_instance_valid(_building)


func start(building: Node3D, player, config: Resource) -> bool:
	if is_active() or building == null:
		return false
	_building = building
	_player = player
	_refund = maxi(int(config.cost) / 2, 0) if config != null else 0
	var animation_player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	if AuthoredModelScript.play_one_shot(
		building, &"sell", _on_animation_finished.bind(building, &"sell")
	):
		return true
	if animation_player != null and animation_player.has_animation(&"construct"):
		var animation := animation_player.get_animation(&"construct")
		if animation != null:
			animation.loop_mode = Animation.LOOP_NONE
		animation_player.animation_finished.connect(
			_on_animation_finished.bind(building, &"construct"), CONNECT_ONE_SHOT
		)
		AuthoredModelScript.play_state(building, &"construct")
		animation_player.seek(animation.length if animation != null else 0.0, true)
		animation_player.play_backwards(&"construct")
		animation_player.advance(0.0)
		return true
	_finish(building)
	return true


func _on_animation_finished(
		animation_name: StringName, building: Node3D, sale_animation: StringName
) -> void:
	if animation_name == sale_animation:
		_finish(building)


func _finish(building: Node3D) -> void:
	if building != _building:
		return
	if _player != null and _refund > 0:
		_player.add_money(_refund)
	var display_name := String(building.get("config_id"))
	if display_name.is_empty():
		display_name = building.name
	var refund := _refund
	_building = null
	_player = null
	_refund = 0
	# call(), not a direct method call: `building` is declared Node3D here,
	# which has queue_free() but not request_despawn() -- a direct call would
	# be a compile error that fails this whole file's parse.
	building.call("request_despawn")
	completed.emit(display_name, refund)
