class_name ProductionSystem
extends RefCounted

const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")

signal build_order_ready(player_id: int, order)
signal build_order_canceled(player_id: int, order, refunded: int)


class PlayerProduction extends RefCounted:
	var build_queue: BuildingQueue = BuildingQueueScript.new()


var _players
var _is_building_available: Callable
var _by_player_id: Dictionary = {}


func configure(players, is_building_available: Callable) -> void:
	_players = players
	_is_building_available = is_building_available


func build_queue_for_player(player_id: int) -> BuildingQueue:
	if _by_player_id.has(player_id):
		return (_by_player_id[player_id] as PlayerProduction).build_queue
	var production := PlayerProduction.new()
	production.build_queue.order_ready.connect(_on_build_order_ready.bind(player_id))
	_by_player_id[player_id] = production
	return production.build_queue


func advance_tick() -> void:
	if _players == null:
		return
	for player_id in _players.player_ids():
		var queue := build_queue_for_player(player_id)
		var order := queue.current_order()
		if order == null:
			continue
		var player = _players.player(player_id)
		if player == null:
			continue
		if not order.ready and (not _is_building_available.is_valid() \
		or not _is_building_available.call(player_id, order.building_id)):
			var refunded := queue.cancel()
			if refunded > 0:
				player.add_money(refunded)
			build_order_canceled.emit(player_id, order, refunded)
			continue
		queue.advance_tick(player.money, Callable(player, &"spend_money"))


func _on_build_order_ready(order, player_id: int) -> void:
	build_order_ready.emit(player_id, order)
