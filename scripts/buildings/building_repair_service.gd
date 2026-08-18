class_name BuildingRepairService
extends RefCounted

## docs/architecture/network-multiplayer.md decision 4: the whole simulation
## now advances by whole ticks, so this service counts ticks directly instead
## of accumulating float seconds and dividing them back out. The cadence
## itself is unchanged -- the simulation already runs at the 25 Hz this
## service was written against, so "every 10 rule ticks" (the old
## 10.0 / 25.0 second interval) and "every 10 simulation ticks" are the same
## pulse. What goes away is the round trip through float seconds, not the
## timing.
const TICKS_PER_REPAIR_PULSE := 10
const COST_FRACTION := 1.0 / 3.0

var _credit_carry: Dictionary = {}
var _ticks_since_pulse := 0


## Advances by exactly one simulation tick. A tick can never contain more
## than one repair pulse (TICKS_PER_REPAIR_PULSE is far above 1), so unlike
## the old float-delta process(), there is no loop here -- just a count and a
## single conditional call.
func advance_tick(
		buildings: Array[Node],
		repair_health: float,
		player,
		config_of: Callable
) -> void:
	_ticks_since_pulse += 1
	if _ticks_since_pulse < TICKS_PER_REPAIR_PULSE:
		return
	_ticks_since_pulse = 0
	_process_pulse(buildings, repair_health, player, config_of)


func set_repairing(building: Node3D, active: bool) -> void:
	if &"is_repairing" in building:
		building.set("is_repairing", active)
	if not active:
		_credit_carry.erase(building.get_instance_id())


## One repair pulse, not one tick -- see advance_tick() and
## TICKS_PER_REPAIR_PULSE. Named apart from the tick deliberately: the two
## used to be the same thing when this service kept its own clock, and
## conflating them again is how a future change would quietly repair
## buildings ten times too fast.
func _process_pulse(
		buildings: Array[Node], repair_health: float, player, config_of: Callable
) -> void:
	for node in buildings:
		var building := node as Node3D
		if building == null or not (&"is_repairing" in building \
			and bool(building.get("is_repairing"))):
			continue
		var max_health := float(building.get("max_health")) \
			if &"max_health" in building else 0.0
		var missing_health := maxf(max_health - float(building.get("health")), 0.0) \
			if &"health" in building else 0.0
		if max_health <= 0.0 or missing_health <= 0.0:
			set_repairing(building, false)
			continue
		var restored := minf(repair_health, missing_health)
		var config = config_of.call(building)
		var building_cost := float(config.cost) if config != null else 0.0
		var repair_cost := restored / max_health * building_cost * COST_FRACTION
		var carry := float(_credit_carry.get(building.get_instance_id(), 0.0)) + repair_cost
		var charge := floori(carry)
		if charge > 0 and (player == null or not player.spend_money(charge)):
			continue
		_credit_carry[building.get_instance_id()] = carry - float(charge)
		building.set("health", float(building.get("health")) + restored)
		if float(building.get("health")) >= max_health:
			set_repairing(building, false)
