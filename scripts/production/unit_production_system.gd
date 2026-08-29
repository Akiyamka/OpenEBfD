class_name UnitProductionSystem
extends Node

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const BuildingDefinitionCatalogScript := preload(
	"res://scripts/buildings/building_definition_catalog.gd"
)
const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")

signal unit_order_execution(player_id: int, execution: UnitOrderExecution)
signal unit_queue_progressed(player_id: int)

const UNIT_POPULATION_LIMIT := 1000
const UNIT_QUEUE_CAPACITY := 100


enum UnitOrderOutcome {
	NOT_AVAILABLE, NO_PRODUCTION_BUILDING, RESUMED, QUEUE_FULL, QUEUED,
	REMOVED, PAUSED, COMPLETED,
}


class UnitOrderExecution extends RefCounted:
	var kind: UnitOrderOutcome = UnitOrderOutcome.NOT_AVAILABLE
	var unit_id: StringName = &""
	var display_name := ""
	var production_building_id: StringName = &""
	var count := 0
	var queue_size := 0
	var refund := 0


class PlayerUnitProduction extends RefCounted:
	var production_queues: Dictionary = {}
	var pending_unit_ids: Dictionary = {}


var _players
var _is_unit_available: Callable
var _by_player_id: Dictionary = {}
var _unit_scene_catalog := UnitSceneCatalogScript.shared()
var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()


func configure(players, is_unit_available: Callable) -> void:
	_players = players
	_is_unit_available = is_unit_available


func execute_unit_order(player_id: int, unit_id: StringName, button_index: int, quantity: int) -> void:
	match button_index:
		MOUSE_BUTTON_LEFT:
			_on_unit_slot_left_pressed(player_id, unit_id, quantity)
		MOUSE_BUTTON_RIGHT:
			_on_unit_slot_right_pressed(player_id, unit_id, quantity)


func advance_tick() -> void:
	if _players == null:
		return
	for player_id in _players.player_ids():
		var player = _players.player(player_id)
		if player == null:
			continue
		var production := _production_for(player_id)
		for production_building_id in production.production_queues.keys():
			var queue: BuildingQueue = production.production_queues[production_building_id]
			var order = queue.current_order()
			if order == null:
				continue
			var advanced := false
			if not order.ready:
				advanced = queue.advance_tick(player.money, Callable(player, &"spend_money"))
				order = queue.current_order()
			if advanced:
				# Unlike building production, this explicit signal keeps the local
				# unit sidebar independent of PlayerData.resources_changed().
				unit_queue_progressed.emit(player_id)
			if order != null and order.ready and spawn_completed_unit(
				player_id, order.building_id, StringName(production_building_id)
			):
				queue.take_ready()
				_start_next_unit_order(player_id, StringName(production_building_id))
				_emit(player_id, UnitOrderOutcome.COMPLETED, order.building_id, order.display_name)


## Read-only seam for sidebar state and queue observers. Queue mutation stays
## inside execute_unit_order(), so readers cannot alter production state.
func unit_queue_for_player(player_id: int, production_building_id: StringName) -> BuildingQueue:
	return _queue_for(player_id, production_building_id)


## Test seam for assertions that distinguish an untouched queue from one with
## pending work. Shipping readers only need the active order or one unit's
## count, so they cannot otherwise derive active-plus-pending queue size.
func unit_queue_size_for_player(player_id: int, production_building_id: StringName) -> int:
	return _unit_queue_size(player_id, production_building_id)


func queued_unit_count_for_player(
		player_id: int, production_building_id: StringName, unit_id: StringName
	) -> int:
	return _queued_unit_count(player_id, production_building_id, unit_id)


func production_building_id_for(player_id: int, unit_id: StringName) -> StringName:
	var definition: Resource = _unit_scene_catalog.definition_for(unit_id)
	if definition == null:
		return &""
	var primary_buildings: Array[StringName] = []
	primary_buildings.assign(definition.primary_building_ids)
	var player = _players.player(player_id) if _players != null else null
	if player != null:
		for building_id in primary_buildings:
			var building_definition := _building_definition_catalog.definition(building_id)
			if building_definition != null and building_definition.house_id == player.house_id \
			and _production_building_for(building_id, player_id) != null:
				return building_id
	for building_id in primary_buildings:
		if _production_building_for(building_id, player_id) != null:
			return building_id
	return &""


func spawn_completed_unit(player_id: int, unit_id: StringName, production_building_id: StringName) -> bool:
	var building := _production_building_for(production_building_id, player_id)
	if building == null:
		return false
	var parent := _units_parent(building)
	if parent == null or _owned_unit_count(player_id) >= UNIT_POPULATION_LIMIT:
		return false
	var unit = _unit_scene_catalog.instantiate(unit_id, UnitScene)
	if unit == null:
		return false
	unit.name = String(unit_id)
	unit.config_id = unit_id
	parent.add_child(unit)
	var spawn_position = building.call("production_spawn_position") if building.has_method("production_spawn_position") else building.simulation_position()
	unit.set_simulation_position(spawn_position)
	unit.face_direction(_production_exit_direction(building))
	unit.set_owner_player_id(player_id)
	var rally_point = building.call("rally_point_position") if building.has_method("rally_point_position") else _default_rally_point(building)
	var exit_point: Vector3 = building.call("production_exit_position") if building.has_method("production_exit_position") else Vector3.INF
	if unit.has_method("begin_hangar_takeoff") and unit.unit_definition != null and bool(unit.unit_definition.can_fly):
		unit.begin_hangar_takeoff(rally_point, exit_point)
	else:
		unit.move_to(rally_point, exit_point)
	return true


func _on_unit_slot_left_pressed(player_id: int, unit_id: StringName, quantity: int) -> void:
	if not _is_unit_available.is_valid() or not _is_unit_available.call(player_id, unit_id):
		_emit(player_id, UnitOrderOutcome.NOT_AVAILABLE, unit_id)
		return
	var production_building_id := production_building_id_for(player_id, unit_id)
	if production_building_id == &"":
		_emit(player_id, UnitOrderOutcome.NO_PRODUCTION_BUILDING, unit_id)
		return
	var queue := _queue_for(player_id, production_building_id)
	var order = queue.current_order()
	if order != null and order.building_id == unit_id and order.manually_paused:
		queue.resume()
		_emit(player_id, UnitOrderOutcome.RESUMED, unit_id, order.display_name)
		return
	var quantity_to_add := clampi(quantity, 1, UNIT_QUEUE_CAPACITY)
	var remaining_capacity := UNIT_QUEUE_CAPACITY - _unit_queue_size(player_id, production_building_id)
	if remaining_capacity <= 0:
		_emit(player_id, UnitOrderOutcome.QUEUE_FULL, unit_id, "", production_building_id)
		return
	quantity_to_add = mini(quantity_to_add, remaining_capacity)
	var pending := _pending_queue_for(player_id, production_building_id)
	for _index in quantity_to_add:
		pending.append(unit_id)
	_start_next_unit_order(player_id, production_building_id)
	_emit(
		player_id, UnitOrderOutcome.QUEUED, unit_id, "", production_building_id,
		quantity_to_add, _unit_queue_size(player_id, production_building_id)
	)


func _on_unit_slot_right_pressed(player_id: int, unit_id: StringName, quantity: int) -> void:
	var production_building_id := production_building_id_for(player_id, unit_id)
	if production_building_id == &"":
		return
	var queue := _queue_for(player_id, production_building_id)
	var order = queue.current_order()
	if order == null:
		return
	if order.manually_paused:
		var removed := _remove_queued_units(
			player_id, production_building_id, unit_id, clampi(quantity, 1, UNIT_QUEUE_CAPACITY)
		)
		if removed.is_empty():
			return
		_emit(
			player_id, UnitOrderOutcome.REMOVED, unit_id, "", production_building_id,
			int(removed.get("count", 0)), 0, int(removed.get("refund", 0))
		)
		return
	if order.building_id != unit_id:
		return
	queue.pause()
	_emit(player_id, UnitOrderOutcome.PAUSED, unit_id, order.display_name, production_building_id)


func _production_building_for(building_id: StringName, player_id: int) -> Node3D:
	if building_id == &"" or not is_inside_tree():
		return null
	var players = _players if _players != null else AutoloadLookupScript.roster(self)
	if players != null:
		var primary = players.primary_building(player_id, String(building_id)) as Node3D
		if _is_owned_production_building(primary, building_id, player_id):
			return primary
	# "sim_buildings" serves both command execution and completed spawns; a
	# producer must be admitted before the simulation may select it.
	for node in get_tree().get_nodes_in_group("sim_buildings"):
		var candidate := node as Node3D
		if not _is_owned_production_building(candidate, building_id, player_id):
			continue
		if players != null:
			players.designate_primary_building(candidate, player_id, String(building_id))
		return candidate
	return null


func _is_owned_production_building(building: Node3D, building_id: StringName, player_id: int) -> bool:
	return EntityQueryScript.is_live(building) \
		and StringName(String(building.get("config_id"))) == building_id \
		and EntityQueryScript.is_owned_by(building, player_id) \
		and EntityQueryScript.is_operational(building)


func _queue_for(player_id: int, production_building_id: StringName) -> BuildingQueue:
	var production := _production_for(player_id)
	var queue: BuildingQueue = production.production_queues.get(production_building_id)
	if queue == null:
		queue = BuildingQueueScript.new()
		production.production_queues[production_building_id] = queue
	return queue


func _pending_queue_for(player_id: int, production_building_id: StringName) -> Array[StringName]:
	var pending_unit_ids := _production_for(player_id).pending_unit_ids
	if not pending_unit_ids.has(production_building_id):
		var pending: Array[StringName] = []
		pending_unit_ids[production_building_id] = pending
	return pending_unit_ids[production_building_id]


func _unit_queue_size(player_id: int, production_building_id: StringName) -> int:
	var queue := _queue_for(player_id, production_building_id)
	return (1 if queue.has_order() else 0) + _pending_queue_for(player_id, production_building_id).size()


func _queued_unit_count(player_id: int, production_building_id: StringName, unit_id: StringName) -> int:
	var count := 0
	var queue: BuildingQueue = _production_for(player_id).production_queues.get(production_building_id)
	var order = queue.current_order() if queue != null else null
	if order != null and order.building_id == unit_id:
		count += 1
	for queued_unit_id in _pending_queue_for(player_id, production_building_id):
		if queued_unit_id == unit_id:
			count += 1
	return count


func _remove_queued_units(
		player_id: int, production_building_id: StringName, unit_id: StringName, quantity: int
	) -> Dictionary:
	var pending := _pending_queue_for(player_id, production_building_id)
	var removed_count := 0
	for index in range(pending.size() - 1, -1, -1):
		if removed_count >= quantity:
			break
		if pending[index] == unit_id:
			pending.remove_at(index)
			removed_count += 1
	var refunded := 0
	var queue := _queue_for(player_id, production_building_id)
	var order = queue.current_order()
	if removed_count < quantity and order != null and order.building_id == unit_id:
		refunded = queue.cancel()
		removed_count += 1
		var player = _players.player(player_id) if _players != null else null
		if player != null and refunded > 0:
			player.add_money(refunded)
		_start_next_unit_order(player_id, production_building_id)
		queue.pause()
	return {"count": removed_count, "refund": refunded} if removed_count > 0 else {}


func _start_next_unit_order(player_id: int, production_building_id: StringName) -> void:
	var queue := _queue_for(player_id, production_building_id)
	if queue.has_order():
		return
	var pending := _pending_queue_for(player_id, production_building_id)
	if pending.is_empty():
		return
	var unit_id: StringName = pending.pop_front()
	var definition: Resource = _unit_scene_catalog.definition_for(unit_id)
	if definition == null:
		push_warning("Unit definition not found for queued unit: %s" % String(unit_id))
		_start_next_unit_order(player_id, production_building_id)
		return
	if not queue.start(
		unit_id, String(unit_id), maxi(int(definition.cost), 0),
		RuleTicksScript.order_sim_ticks(definition.build_time_ticks)
	):
		push_warning("Unit could not be started from production queue: %s" % String(unit_id))


func _units_parent(building: Node3D) -> Node:
	return EntityQueryScript.units_parent(get_tree(), building.get_parent())


func _owned_unit_count(player_id: int) -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group("sim_units"):
		if EntityQueryScript.is_owned_by(node, player_id):
			count += 1
	return count


func _default_rally_point(building: Node3D) -> Vector3:
	return building.simulation_position() + _production_exit_direction(building) * 2.0


func _production_exit_direction(building: Node3D) -> Vector3:
	return EntityQueryScript.exit_direction(building)


func _production_for(player_id: int) -> PlayerUnitProduction:
	if _by_player_id.has(player_id):
		return _by_player_id[player_id] as PlayerUnitProduction
	var production := PlayerUnitProduction.new()
	_by_player_id[player_id] = production
	return production


func _emit(
		player_id: int, kind: UnitOrderOutcome, unit_id: StringName, display_name := "",
		production_building_id: StringName = &"", count := 0, queue_size := 0, refund := 0
	) -> void:
	var execution := UnitOrderExecution.new()
	execution.kind = kind
	execution.unit_id = unit_id
	execution.display_name = display_name
	execution.production_building_id = production_building_id
	execution.count = count
	execution.queue_size = queue_size
	execution.refund = refund
	unit_order_execution.emit(player_id, execution)
