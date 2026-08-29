class_name BuildingRepairService
extends RefCounted

const EntityQueryScript := preload("res://scripts/world/entity_query.gd")

## The simulation already runs at 25 Hz, so ten simulation ticks preserve the
## original 10.0 / 25.0 second repair cadence without a float-time round trip.
const TICKS_PER_REPAIR_PULSE := 10
const COST_FRACTION := 1.0 / 3.0

var _players
var _credit_carry: Dictionary = {}
var _ticks_since_pulse := 0


func configure(players) -> void:
	_players = players


func advance_tick(buildings: Array[Node], repair_health: float, config_of: Callable) -> void:
	_ticks_since_pulse += 1
	if _ticks_since_pulse < TICKS_PER_REPAIR_PULSE:
		return
	_ticks_since_pulse = 0
	_process_pulse(buildings, repair_health, config_of)


func set_repairing(building: Node3D, active: bool) -> void:
	if &"is_repairing" in building:
		building.set("is_repairing", active)
	if not active:
		_credit_carry.erase(building.get_instance_id())


## One repair pulse, not one tick. The carry stays keyed by building instance:
## ownership does not change the fractional cost accumulated by that building.
func _process_pulse(buildings: Array[Node], repair_health: float, config_of: Callable) -> void:
	for node in buildings:
		var building := node as Node3D
		if building == null or not (&"is_repairing" in building and bool(building.get("is_repairing"))):
			continue
		var max_health := float(building.get("max_health")) if &"max_health" in building else 0.0
		var missing_health := maxf(max_health - float(building.get("health")), 0.0) if &"health" in building else 0.0
		if max_health <= 0.0 or missing_health <= 0.0:
			set_repairing(building, false)
			continue
		var restored := minf(repair_health, missing_health)
		var config = config_of.call(building)
		var building_cost := float(config.cost) if config != null else 0.0
		var repair_cost := restored / max_health * building_cost * COST_FRACTION
		var carry := float(_credit_carry.get(building.get_instance_id(), 0.0)) + repair_cost
		var charge := floori(carry)
		var player = _players.player(EntityQueryScript.owner_id_of(building)) if _players != null else null
		if charge > 0 and (player == null or not player.spend_money(charge)):
			continue
		_credit_carry[building.get_instance_id()] = carry - float(charge)
		building.set("health", float(building.get("health")) + restored)
		if float(building.get("health")) >= max_health:
			set_repairing(building, false)
