class_name UpgradeProductionSystem
extends Node

const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const UpgradeEffectsScript := preload("res://scripts/buildings/upgrade_effects.gd")
const UpgradeOrderScript := preload("res://scripts/buildings/upgrade_order.gd")
const UpgradeQueueScript := preload("res://scripts/buildings/upgrade_queue.gd")
const UpgradeRulesScript := preload("res://scripts/buildings/upgrade_rules.gd")

signal upgrade_order_execution(player_id: int, execution: UpgradeOrderExecution)
signal upgrade_queue_progressed(player_id: int)
## TODO(§3 unit production / economy.md §2.3): a completed dock should spawn
## one harvester. There is currently no subscriber to this future hook.
signal dock_completed(player_id: int, refinery_id: int)

const REFINERY_ROLE := "Refinery"

enum UpgradeOrderOutcome {
	QUEUE_BUSY, DOCK_MAXIMUM, DOCK_RULES_MISSING, DOCK_QUEUE_FAILED, ORDERED,
	PAUSED, NO_REFINERY, RESUMED, WAITING_CREDITS, ALREADY_RUNNING,
	GLOBAL_RULES_MISSING, NOT_AVAILABLE, CANCELED, UPGRADED, LOST_REFINERY,
	DOCK_CANNOT_RECEIVE, COMPLETED,
}


class UpgradeOrderExecution extends RefCounted:
	var kind: UpgradeOrderOutcome = UpgradeOrderOutcome.QUEUE_BUSY
	var display_name := ""
	var refunded := 0


class PlayerUpgradeProduction extends RefCounted:
	var upgrade_queue: UpgradeQueue = UpgradeQueueScript.new()


var _players
var _entity_index
var _by_player_id: Dictionary = {}
var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()


func configure(players, entity_index) -> void:
	_players = players
	_entity_index = entity_index


func execute_upgrade_order(player_id: int, building_id: StringName, button_index: int) -> void:
	var kind := UpgradeOrderScript.Kind.REFINERY_DOCK \
		if UpgradeRulesScript.is_refinery_dock_id(building_id) \
		else UpgradeOrderScript.Kind.GLOBAL_TYPE
	_on_slot_pressed(player_id, building_id, button_index, kind)


func advance_tick() -> void:
	if _players == null:
		return
	for player_id in _players.player_ids():
		var player = _players.player(player_id)
		if player == null:
			continue
		_process_upgrade_order(player_id, player)


## Shipping observer for the local sidebar. The returned order is observation
## data only; callers must not mutate it. Queue mutation remains private to
## this system's execution and tick paths.
func current_order_for_player(player_id: int) -> UpgradeOrder:
	var production: PlayerUpgradeProduction = _by_player_id.get(player_id)
	return production.upgrade_queue.current_order() if production != null else null


## Live execution verdict and local-sidebar availability read.
func is_upgrade_available_for(player_id: int, building_id: StringName) -> bool:
	var config: Resource = _building_definition_catalog.definition(building_id)
	if config == null or not _has_upgrade_definition(config):
		return false
	var player = _players.player(player_id) if _players != null else null
	if player == null or player.has_purchased_upgrade(building_id):
		return false
	return _player_owns_building_type(player_id, building_id)


## Live execution verdict and local-sidebar dock availability read.
func can_any_refinery_add_dock_for(player_id: int, building_id: StringName) -> bool:
	return _refinery_for_dock_upgrade(player_id, building_id) != null


func _try_start_dock_upgrade(player_id: int, refinery: Node3D, dock_building_id: StringName = &"") -> void:
	var queue := _production_for(player_id).upgrade_queue
	if queue.has_order():
		_emit(player_id, UpgradeOrderOutcome.QUEUE_BUSY)
		return
	if refinery == null or not refinery.has_method("can_add_dock") or not bool(refinery.call("can_add_dock")):
		_emit(player_id, UpgradeOrderOutcome.DOCK_MAXIMUM)
		return
	if dock_building_id == &"":
		dock_building_id = _dock_building_id_for(refinery)
	var config: Resource = _building_definition_catalog.definition(dock_building_id)
	if config == null:
		_emit(player_id, UpgradeOrderOutcome.DOCK_RULES_MISSING)
		return
	var refinery_id: int = _entity_index.id_for(refinery) if _entity_index != null else 0
	if refinery_id == 0 or not queue.start(
		dock_building_id, UpgradeRulesScript.display_name(dock_building_id), maxi(config.upgrade_cost, 0),
		UpgradeRulesScript.build_time_sim_ticks(config, true), UpgradeOrderScript.Kind.REFINERY_DOCK,
		refinery_id
	):
		_emit(player_id, UpgradeOrderOutcome.DOCK_QUEUE_FAILED)
		return
	_emit(player_id, UpgradeOrderOutcome.ORDERED, queue.current_order().display_name)


func _on_slot_pressed(player_id: int, building_id: StringName, button_index: int, kind: int) -> void:
	if button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return
	var queue := _production_for(player_id).upgrade_queue
	var order := queue.current_order()
	var matches := order != null and order.kind == kind and order.upgrade_id == building_id
	if button_index == MOUSE_BUTTON_RIGHT:
		if not matches:
			return
		if order.manually_paused:
			_cancel_upgrade_order(player_id)
		else:
			queue.pause()
			_emit(player_id, UpgradeOrderOutcome.PAUSED, order.display_name)
		return
	if order == null:
		if kind == UpgradeOrderScript.Kind.REFINERY_DOCK:
			var refinery := _refinery_for_dock_upgrade(player_id, building_id)
			if refinery == null:
				_emit(player_id, UpgradeOrderOutcome.NO_REFINERY)
			else:
				_try_start_dock_upgrade(player_id, refinery, building_id)
		else:
			_start_global_upgrade_order(player_id, building_id)
	elif not matches:
		_emit(player_id, UpgradeOrderOutcome.QUEUE_BUSY)
	elif order.manually_paused:
		queue.resume()
		_emit(player_id, UpgradeOrderOutcome.RESUMED, order.display_name)
	else:
		_emit(
			player_id,
			UpgradeOrderOutcome.WAITING_CREDITS if queue.lacks_funds() else UpgradeOrderOutcome.ALREADY_RUNNING,
			order.display_name
		)


func _start_global_upgrade_order(player_id: int, building_id: StringName) -> void:
	var config: Resource = _building_definition_catalog.definition(building_id)
	if config == null:
		_emit(player_id, UpgradeOrderOutcome.GLOBAL_RULES_MISSING)
		return
	var queue := _production_for(player_id).upgrade_queue
	if queue.has_order():
		_emit(player_id, UpgradeOrderOutcome.QUEUE_BUSY)
		return
	if not is_upgrade_available_for(player_id, building_id):
		_emit(player_id, UpgradeOrderOutcome.NOT_AVAILABLE, UpgradeRulesScript.display_name(building_id))
		return
	if not queue.start(
		building_id, UpgradeRulesScript.display_name(building_id), maxi(config.upgrade_cost, 0),
		UpgradeRulesScript.build_time_sim_ticks(config, false)
	):
		return
	_emit(player_id, UpgradeOrderOutcome.ORDERED, queue.current_order().display_name)


func _cancel_upgrade_order(player_id: int) -> void:
	var queue := _production_for(player_id).upgrade_queue
	var order := queue.current_order()
	if order == null:
		return
	var display_name := order.display_name
	var refunded := queue.cancel()
	var player = _players.player(player_id) if _players != null else null
	if player != null and refunded > 0:
		player.add_money(refunded)
	_emit(player_id, UpgradeOrderOutcome.CANCELED, display_name, refunded)


func _process_upgrade_order(player_id: int, player) -> void:
	var queue := _production_for(player_id).upgrade_queue
	var order := queue.current_order()
	if order == null:
		return
	if order.kind == UpgradeOrderScript.Kind.REFINERY_DOCK and _node_for(order.target_refinery) == null:
		_cancel_upgrade_order(player_id)
		return
	if queue.advance_tick(player.money, Callable(player, &"spend_money")):
		upgrade_queue_progressed.emit(player_id)


func _on_upgrade_queue_ready(order: UpgradeOrder, player_id: int) -> void:
	match order.kind:
		UpgradeOrderScript.Kind.GLOBAL_TYPE:
			_complete_global_upgrade(player_id, order)
		UpgradeOrderScript.Kind.REFINERY_DOCK:
			_complete_dock_upgrade(player_id, order)


func _complete_global_upgrade(player_id: int, order: UpgradeOrder) -> void:
	_production_for(player_id).upgrade_queue.take_ready()
	var player = _players.player(player_id) if _players != null else null
	if player != null:
		player.grant_upgrade(order.upgrade_id)
		var buildings: Array = []
		if is_inside_tree():
			# "sim_buildings", not "buildings": reached only from advance_tick()
			# and its queue-ready signal inside the simulation tick call graph.
			buildings.assign(get_tree().get_nodes_in_group("sim_buildings"))
		UpgradeEffectsScript.apply_to_existing_buildings(buildings, player.player_id, order.upgrade_id)
	_emit(player_id, UpgradeOrderOutcome.UPGRADED, order.display_name)


func _complete_dock_upgrade(player_id: int, order: UpgradeOrder) -> void:
	_production_for(player_id).upgrade_queue.take_ready()
	var refinery := _node_for(order.target_refinery) as Node3D
	if refinery == null:
		_emit(player_id, UpgradeOrderOutcome.LOST_REFINERY, order.display_name)
		return
	if not refinery.has_method("add_refinery_dock_upgrade") or not bool(refinery.call("add_refinery_dock_upgrade")):
		_refund_and_fail(player_id, order)
		return
	dock_completed.emit(player_id, order.target_refinery)
	_emit(player_id, UpgradeOrderOutcome.COMPLETED, order.display_name)


func _refund_and_fail(player_id: int, order: UpgradeOrder) -> void:
	var player = _players.player(player_id) if _players != null else null
	if player != null and order.cost > 0:
		player.add_money(order.cost)
	_emit(player_id, UpgradeOrderOutcome.DOCK_CANNOT_RECEIVE, order.display_name)


func _dock_building_id_for(refinery: Node3D) -> StringName:
	var refinery_id := String(refinery.get("config_id"))
	return StringName(refinery_id.substr(0, 2) + "RefineryDock")


func _is_refinery(building: Node3D) -> bool:
	var config = building.get("building_config") as Resource
	if config == null:
		config = _building_definition_catalog.definition(StringName(String(building.get("config_id"))))
	return config != null and config.roles.has(REFINERY_ROLE)


## Returns a deterministic compatible refinery. This serves both the command
## execution verdict and the sidebar poll, so each reads sim_buildings only.
func _refinery_for_dock_upgrade(player_id: int, dock_building_id: StringName) -> Node3D:
	if not is_inside_tree():
		return null
	# "sim_buildings", not "buildings": command execution must not choose a
	# building the tick has not admitted; the sidebar shares this one verdict.
	for node in get_tree().get_nodes_in_group("sim_buildings"):
		var building := node as Node3D
		if building == null or not EntityQueryScript.is_owned_by(building, player_id):
			continue
		if not _is_refinery(building) or _dock_building_id_for(building) != dock_building_id:
			continue
		if building.has_method("can_add_dock") and bool(building.call("can_add_dock")):
			return building
	return null


func _player_owns_building_type(player_id: int, building_id: StringName) -> bool:
	if not is_inside_tree():
		return false
	# The same settled sim_buildings snapshot is used by the execution verdict
	# and by the local availability poll that renders it.
	for node in get_tree().get_nodes_in_group("sim_buildings"):
		var building := node as Node3D
		if building != null and EntityQueryScript.is_owned_by(building, player_id) \
		and StringName(String(building.get("config_id"))) == building_id:
			return true
	return false


func _has_upgrade_definition(config: Resource) -> bool:
	return config.upgrade_cost > 0 and config.upgrade_tech_level > 0


func _production_for(player_id: int) -> PlayerUpgradeProduction:
	if _by_player_id.has(player_id):
		return _by_player_id[player_id] as PlayerUpgradeProduction
	var production := PlayerUpgradeProduction.new()
	production.upgrade_queue.order_ready.connect(_on_upgrade_queue_ready.bind(player_id))
	_by_player_id[player_id] = production
	return production


func _node_for(entity_id: int) -> Node:
	return _entity_index.node_for(entity_id) if _entity_index != null else null


func _emit(player_id: int, kind: UpgradeOrderOutcome, display_name := "", refunded := 0) -> void:
	var execution := UpgradeOrderExecution.new()
	execution.kind = kind
	execution.display_name = display_name
	execution.refunded = refunded
	upgrade_order_execution.emit(player_id, execution)
