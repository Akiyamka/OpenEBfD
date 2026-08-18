class_name ProductionQueue
extends RefCounted

signal order_ready(order)

var _order
var _lack_funds := false


func has_order() -> bool:
	return _order != null


func current_order():
	return _order


func lacks_funds() -> bool:
	return _lack_funds


func adopt(order) -> bool:
	if _order != null or order == null or order.cost < 0 or order.build_time_ticks <= 0:
		return false
	_order = order
	_lack_funds = false
	return true


## Advances the current order by exactly one simulation tick. One call is one
## tick -- callers no longer hand in a delta (see MatchClock and decision 4,
## docs/architecture/network-multiplayer.md).
func advance_tick(available_credits: int, spend_credits: Callable = Callable()) -> bool:
	if _order == null or _order.ready or _order.manually_paused:
		return false

	if _order.cost <= 0:
		_order.elapsed_ticks += 1
		if _order.elapsed_ticks >= _order.build_time_ticks:
			_mark_ready()
		return true

	if available_credits <= 0:
		return _set_lack_funds(true)

	var changed := _set_lack_funds(false)
	var remaining_cost: int = _order.cost - _order.paid_cost
	if remaining_cost <= 0:
		_mark_ready()
		return true

	# One tick's share of the total cost, spread evenly across build_time_ticks
	# -- the direct per-tick analog of the old delta * cost / build_seconds,
	# with delta fixed at exactly one tick. Summed over every tick of the
	# build (build_time_ticks calls, each adding cost / build_time_ticks) this
	# still totals exactly `cost`, just without round-tripping through seconds.
	var credits_per_tick: float = float(_order.cost) / float(_order.build_time_ticks)
	_order.charge_accumulator += credits_per_tick

	var credits_due := mini(int(floor(_order.charge_accumulator)), remaining_cost)
	if credits_due <= 0:
		return changed

	var credits_paid := mini(credits_due, available_credits)
	_order.charge_accumulator -= float(credits_due)
	if credits_paid <= 0 or spend_credits.is_null() or not bool(spend_credits.call(credits_paid)):
		return _set_lack_funds(true) or changed

	_order.paid_cost += credits_paid
	if credits_paid < credits_due:
		changed = _set_lack_funds(true) or changed

	if _order.paid_cost >= _order.cost:
		_mark_ready()
		return true
	return true


func pause() -> bool:
	if _order == null or _order.ready or _order.manually_paused:
		return false
	_order.manually_paused = true
	_lack_funds = false
	return true


func resume() -> bool:
	if _order == null or _order.ready or not _order.manually_paused:
		return false
	_order.manually_paused = false
	_lack_funds = false
	return true


func cancel() -> int:
	if _order == null:
		return 0
	var refund: int = _order.paid_cost
	_order = null
	_lack_funds = false
	return refund


func take_ready():
	if _order == null or not _order.ready:
		return null
	var ready_order = _order
	_order = null
	_lack_funds = false
	return ready_order


func _set_lack_funds(value: bool) -> bool:
	if _lack_funds == value:
		return false
	_lack_funds = value
	return true


func _mark_ready() -> void:
	if _order == null or _order.ready:
		return
	_order.ready = true
	_order.manually_paused = false
	_lack_funds = false
	order_ready.emit(_order)
