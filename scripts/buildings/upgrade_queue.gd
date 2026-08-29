class_name UpgradeQueue
extends RefCounted

## docs/mechanics/production.md section 4 "Upgrades": UpgradeProductionSystem
## owns one of these queues for every player -- unlike the building and unit
## production systems' differently shaped queues. The gradual-payment tick
## itself lives in the shared ProductionQueue below; what stays here is the
## upgrade-shaped display API (UpgradeOrder, with kind and target_refinery),
## so the authoritative system never funnels building- and upgrade-shaped
## orders through one type.
signal order_ready(order: UpgradeOrder)

const UpgradeOrderScript := preload("res://scripts/buildings/upgrade_order.gd")
const ProductionQueueScript := preload("res://scripts/buildings/production_queue.gd")

var _queue := ProductionQueueScript.new()


func _init() -> void:
	_queue.order_ready.connect(_on_order_ready)


func has_order() -> bool:
	return _queue.has_order()


func current_order() -> UpgradeOrder:
	return _queue.current_order() as UpgradeOrder


func lacks_funds() -> bool:
	return _queue.lacks_funds()


## build_time_ticks is already simulation-domain (MatchClock.TICKS_PER_SECOND
## per second) -- convert a rules-domain value with RuleTicks.to_sim_ticks()
## before calling this, so a caller can never mistake it for the rules-domain
## number it used to be.
func start(
		upgrade_id: StringName,
		display_name: String,
		cost: int,
		build_time_ticks: int,
		kind: UpgradeOrder.Kind = UpgradeOrder.Kind.GLOBAL_TYPE,
		target_refinery := 0
) -> bool:
	if upgrade_id == &"":
		return false
	var order := UpgradeOrderScript.new()
	order.kind = kind
	order.upgrade_id = upgrade_id
	order.display_name = display_name
	order.cost = cost
	order.build_time_ticks = build_time_ticks
	order.target_refinery = target_refinery
	return _queue.adopt(order)


func advance_tick(available_credits: int, spend_credits: Callable = Callable()) -> bool:
	return _queue.advance_tick(available_credits, spend_credits)


func pause() -> bool:
	return _queue.pause()


func resume() -> bool:
	return _queue.resume()


func cancel() -> int:
	return _queue.cancel()


func take_ready() -> UpgradeOrder:
	return _queue.take_ready() as UpgradeOrder


func _on_order_ready(order) -> void:
	order_ready.emit(order as UpgradeOrder)
