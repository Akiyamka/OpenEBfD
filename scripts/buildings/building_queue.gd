class_name BuildingQueue
extends RefCounted

signal order_ready(order: BuildingOrder)

const BuildingOrderScript := preload("res://scripts/buildings/building_order.gd")
const ProductionQueueScript := preload("res://scripts/buildings/production_queue.gd")

var _queue := ProductionQueueScript.new()


func _init() -> void:
	_queue.order_ready.connect(_on_order_ready)


func has_order() -> bool:
	return _queue.has_order()


func current_order() -> BuildingOrder:
	return _queue.current_order() as BuildingOrder


func lacks_funds() -> bool:
	return _queue.lacks_funds()


## build_time_ticks is already simulation-domain (MatchClock.TICKS_PER_SECOND
## per second) -- convert a rules-domain value with RuleBuildTime.to_sim_ticks()
## before calling this, so a caller can never mistake it for the rules-domain
## number it used to be.
func start(building_id: StringName, display_name: String, cost: int, build_time_ticks: int) -> bool:
	if building_id == &"":
		return false
	var order := BuildingOrderScript.new()
	order.building_id = building_id
	order.display_name = display_name
	order.cost = cost
	order.build_time_ticks = build_time_ticks
	return _queue.adopt(order)


func advance_tick(available_credits: int, spend_credits: Callable = Callable()) -> bool:
	return _queue.advance_tick(available_credits, spend_credits)


func pause() -> bool:
	return _queue.pause()


func resume() -> bool:
	return _queue.resume()


func cancel() -> int:
	return _queue.cancel()


func take_ready() -> BuildingOrder:
	return _queue.take_ready() as BuildingOrder


func _on_order_ready(order) -> void:
	order_ready.emit(order as BuildingOrder)
