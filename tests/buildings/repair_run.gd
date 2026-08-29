extends "res://tests/support/suite.gd"

## Pins down scripts/production/building_repair_service.gd: the tick-counted
## repair pulse cadence, the health/credit math each pulse performs, and the
## sub-credit carry, none of which tests/buildings/controller_run.gd exercises
## -- that suite only covers repair MODE toggling (entering/leaving repair
## mode), never an actual repair pulse. Before this suite there was no test of
## repair behaviour at all, so the tick-counting conversion in
## docs/architecture/network-multiplayer.md decision 4 had no safety net.

const BuildingRepairServiceScript := preload("res://scripts/production/building_repair_service.gd")


## Minimal Node3D stand-in for the health/max_health/is_repairing surface
## BuildingRepairService reads and writes purely through get()/set() -- the
## same shape as FakeBuilding in tests/buildings/upgrade_run.gd, sized for
## repair instead of upgrades. Must be a Node3D (not a bare Node): the
## service's `node as Node3D` cast in _process_pulse() would otherwise drop it
## silently instead of erroring.
class BuildingStub extends Node3D:
	var owner_player_id := 1
	var health := 0.0
	var max_health := 0.0
	var is_repairing := false

	func _init(new_health: float, new_max_health: float, repairing: bool = true) -> void:
		health = new_health
		max_health = new_max_health
		is_repairing = repairing


## config_of() only ever needs to yield something with a `.cost` property --
## the service never reads anything else off it.
class ConfigStub extends RefCounted:
	var cost := 0.0

	func _init(new_cost: float) -> void:
		cost = new_cost


## Stand-in for PlayerData.spend_money(). can_pay lets a case force the
## "can't afford this charge" path without needing a real balance to run dry;
## total_spent lets a case prove exactly how much (and when) was charged.
class PlayerStub extends RefCounted:
	var can_pay := true
	var total_spent := 0

	func spend_money(amount: int) -> bool:
		if not can_pay:
			return false
		total_spent += amount
		return true


class RosterStub extends RefCounted:
	var _by_id: Dictionary = {}

	func add(player_id: int, player_data: PlayerStub) -> void:
		_by_id[player_id] = player_data

	func player(player_id: int):
		return _by_id.get(player_id)


func _initialize() -> void:
	_run_case(
		"nine advance_tick() calls change nothing; the tenth restores health",
		_test_pulse_lands_on_tenth_call
	)
	_run_case("two pulses take exactly twenty ticks", _test_two_pulses_take_twenty_ticks)
	_run_case(
		"a pulse restores at most the missing health and clears is_repairing at full health",
		_test_restore_caps_at_missing_health_and_stops
	)
	_run_case(
		"the credit charge is repaired-fraction * cost * COST_FRACTION, and the remainder carries",
		_test_credit_charge_and_carry_cross_a_whole_credit
	)
	_run_case(
		"a player that cannot pay leaves health unrestored",
		_test_unaffordable_charge_blocks_the_restore
	)
	_run_case(
		"set_repairing(building, false) clears that building's carry",
		_test_set_repairing_false_clears_carry
	)
	_finish("BuildingRepairService tests")


func _test_pulse_lands_on_tenth_call() -> void:
	var service := BuildingRepairServiceScript.new()
	var building := BuildingStub.new(50.0, 100.0)
	var buildings: Array[Node] = [building]
	var player := PlayerStub.new()
	_configure(service, player)
	# Free repairs (cost 0) keep this case about the tick cadence alone --
	# credit math is covered separately below.
	var config_of := Callable(self, "_zero_cost_config")

	for i in 9:
		service.advance_tick(buildings, 12.0, config_of)
		_expect(
			building.health == 50.0,
			"call %d of 9 must not have fired a repair pulse yet" % (i + 1)
		)

	service.advance_tick(buildings, 12.0, config_of)
	_expect(
		building.health == 62.0,
		"the 10th call must land the first repair pulse, restoring the full repair_health"
	)
	building.free()


func _test_two_pulses_take_twenty_ticks() -> void:
	var service := BuildingRepairServiceScript.new()
	# max_health kept well above what two pulses can restore so missing_health
	# never caps restored -- this case is purely about pulse timing.
	var building := BuildingStub.new(0.0, 1000.0)
	var buildings: Array[Node] = [building]
	var player := PlayerStub.new()
	_configure(service, player)
	var config_of := Callable(self, "_zero_cost_config")

	for _i in 19:
		service.advance_tick(buildings, 5.0, config_of)
	_expect(building.health == 5.0, "19 ticks must contain exactly one pulse (at tick 10)")

	service.advance_tick(buildings, 5.0, config_of)
	_expect(building.health == 10.0, "the 20th tick must land the second pulse")
	building.free()


func _test_restore_caps_at_missing_health_and_stops() -> void:
	var service := BuildingRepairServiceScript.new()
	var building := BuildingStub.new(95.0, 100.0)
	var buildings: Array[Node] = [building]
	var player := PlayerStub.new()
	_configure(service, player)
	var config_of := Callable(self, "_zero_cost_config")

	# repair_health (12) overshoots the 5 missing health; restored must clamp
	# to missing_health, not repair_health.
	_advance(service, buildings, 12.0, config_of, BuildingRepairServiceScript.TICKS_PER_REPAIR_PULSE)
	_expect(building.health == 100.0, "restored health must be capped at missing_health, not repair_health")
	_expect(not building.is_repairing, "reaching max_health must clear is_repairing")

	# A further pulse must be a no-op: the building is no longer repairing.
	_advance(service, buildings, 12.0, config_of, BuildingRepairServiceScript.TICKS_PER_REPAIR_PULSE)
	_expect(building.health == 100.0, "a building that stopped repairing must not gain health from a later pulse")


## building_cost 3 makes cost * COST_FRACTION exactly 1.0 credit, and
## max_health 4 with repair_health 1 makes each pulse restore exactly a
## quarter of that -- 0.25 credit, a clean binary fraction that avoids float
## noise in the assertions below. Four pulses (40 ticks) fully heals the
## building for a total charge of exactly 1 credit; the first three pulses
## must charge nothing, proving the fractional remainder carries across
## pulses instead of being rounded away each time, and the fourth pulse's
## charge of exactly 1 proves it was not dropped either.
	building.free()


func _test_credit_charge_and_carry_cross_a_whole_credit() -> void:
	var service := BuildingRepairServiceScript.new()
	var building := BuildingStub.new(0.0, 4.0)
	var buildings: Array[Node] = [building]
	var player := PlayerStub.new()
	_configure(service, player)
	var config_of := Callable(self, "_fixed_cost_config").bind(3.0)

	for pulse in 3:
		_advance(service, buildings, 1.0, config_of, BuildingRepairServiceScript.TICKS_PER_REPAIR_PULSE)
		_expect(
			building.health == float(pulse + 1),
			"pulse %d must still restore health even while its charge is sub-credit" % (pulse + 1)
		)
		_expect(
			player.total_spent == 0,
			"pulse %d's fractional charge (0.25 credit) must carry, not round up to a charge yet" % (pulse + 1)
		)

	_advance(service, buildings, 1.0, config_of, BuildingRepairServiceScript.TICKS_PER_REPAIR_PULSE)
	_expect(building.health == 4.0, "the 4th pulse must complete the repair")
	_expect(
		player.total_spent == 1,
		"the carried remainder must cross a whole credit on the 4th pulse, charging exactly 1"
	)
	building.free()


func _test_unaffordable_charge_blocks_the_restore() -> void:
	var service := BuildingRepairServiceScript.new()
	var building := BuildingStub.new(0.0, 4.0)
	var buildings: Array[Node] = [building]
	var player := PlayerStub.new()
	_configure(service, player)
	player.can_pay = false
	# cost 3 and repair_health 4 make the very first pulse's charge exactly 1
	# whole credit (see the case above for the arithmetic), so payment is
	# required on the first pulse rather than several pulses in.
	var config_of := Callable(self, "_fixed_cost_config").bind(3.0)

	_advance(service, buildings, 4.0, config_of, BuildingRepairServiceScript.TICKS_PER_REPAIR_PULSE)
	_expect(building.health == 0.0, "a pulse whose charge the player cannot pay must leave health unrestored")
	_expect(player.total_spent == 0, "a rejected charge must not be counted as spent")
	building.free()


func _test_set_repairing_false_clears_carry() -> void:
	var service := BuildingRepairServiceScript.new()
	var building := BuildingStub.new(0.0, 4.0)
	var buildings: Array[Node] = [building]
	var player := PlayerStub.new()
	_configure(service, player)
	var config_of := Callable(self, "_fixed_cost_config").bind(3.0)

	# Three pulses at 0.25 credit each leave a 0.75 carry sitting on this
	# building (see the carry case above) -- one pulse short of the charge
	# that would fire on the next one.
	_advance(service, buildings, 1.0, config_of, 3 * BuildingRepairServiceScript.TICKS_PER_REPAIR_PULSE)
	_expect(building.health == 3.0, "setup must have run exactly three pulses")
	_expect(player.total_spent == 0, "setup's three pulses must still be sub-credit")

	service.set_repairing(building, false)
	_expect(not building.is_repairing, "set_repairing(false) must stop the building from repairing")
	service.set_repairing(building, true)
	_expect(building.is_repairing, "set_repairing(true) must resume it")

	# If the 0.75 carry had survived, this pulse's own 0.25 would cross a
	# whole credit and charge 1 immediately. It must not: the restart cleared it.
	_advance(service, buildings, 1.0, config_of, BuildingRepairServiceScript.TICKS_PER_REPAIR_PULSE)
	_expect(building.health == 4.0, "the resumed repair must still restore health")
	_expect(
		player.total_spent == 0,
		"a restarted repair must not inherit the pre-restart carry"
	)
	building.free()


func _advance(service, buildings: Array[Node], repair_health: float, config_of: Callable, ticks: int) -> void:
	for _i in ticks:
		service.advance_tick(buildings, repair_health, config_of)


func _configure(service, player: PlayerStub) -> void:
	var roster := RosterStub.new()
	roster.add(1, player)
	service.configure(roster)


func _zero_cost_config(_building: Node) -> ConfigStub:
	return ConfigStub.new(0.0)


func _fixed_cost_config(_building: Node, cost: float) -> ConfigStub:
	return ConfigStub.new(cost)
