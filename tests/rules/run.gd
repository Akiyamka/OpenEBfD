extends SceneTree
## Covers RulesCatalog.buildable_building_ids_for_house(): the panel-grid
## roster filter documented in docs/mechanics/production.md. Real fixtures
## (assets/converted/rules/buildings/*.tres) already exercise this indirectly
## via the match integration fixture, but this pins the filter rules directly against synthetic
## configs so a future rules-conversion change that breaks them fails loudly
## here instead of only showing up as a wrong panel roster in-game.

const RulesCatalogScript := preload("res://scripts/rules/rules_catalog.gd")
const RuleEntityConfigScript := preload("res://scripts/rules/rule_entity_config.gd")
const RuleBuildTimeScript := preload("res://scripts/rules/rule_build_time.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	_run_case("roster excludes ConYard, Wall, RefineryDock, and decorative buildings", _test_roster_filter)
	_run_case("roster matches by primary house or subhouse", _test_roster_house_matching)
	_run_case(
		"wall_building_ids_for_house and refinery_dock_building_ids_for_house surface what the roster excludes",
		_test_wall_and_dock_ids
	)
	_run_case("upgrade roster includes an upgradeable Construction Yard", _test_upgrade_roster)
	_run_case("unit roster keeps producible units and shared house-less units", _test_unit_roster)
	_run_case("RuleBuildTime.to_sim_ticks converts 60 Hz rule ticks to 25 Hz sim ticks", _test_rule_build_time_to_sim_ticks)

	if _failures > 0:
		printerr("Rules tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return

	print("Rules tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var completed: Variant = test.call()
	if completed != true:
		_failures += 1
		printerr("FAIL: %s: case aborted before normal completion" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_roster_filter() -> bool:
	var catalog = _catalog_with([
		_building(&"ATConYard", &"Atreides", {"is_con_yard": true}, [&"ConYard"]),
		_building(&"ATBarracks", &"Atreides", {}, [&"ATConYard"], [&"Barracks"]),
		_building(&"ATFactory", &"Atreides", {}, [&"ATConYard"], [&"Factory"]),
		_building(
			&"ATWall", &"Atreides", {"building_group": "Wall"}, [&"ATConYard"], [&"Wall"]
		),
		_building(
			&"ATRefineryDock",
			&"Atreides",
			{"building_group": "RefineryDock"},
			[&"ATConYard"],
			[&"Dockable"]
		),
		_building(&"ATINSultan", &"Atreides", {}, []),
	])

	var roster: Array[StringName] = catalog.buildable_building_ids_for_house(&"Atreides")

	_expect(roster.has(&"ATBarracks"), "a real buildable building must be included")
	_expect(roster.has(&"ATFactory"), "a second real buildable building must be included")
	_expect(not roster.has(&"ATConYard"), "the Construction Yard must be excluded (built only via MCV)")
	_expect(not roster.has(&"ATWall"), "Wall must be excluded (surfaced via wall_building_ids_for_house instead)")
	_expect(
		not roster.has(&"ATRefineryDock"),
		"RefineryDock must be excluded (surfaced via refinery_dock_building_ids_for_house instead)"
	)
	_expect(
		not roster.has(&"ATINSultan"),
		"a decorative building with no requires_primary must be excluded"
	)
	_expect(roster.size() == 2, "only the two real buildable buildings must remain")
	return true


func _test_roster_house_matching() -> bool:
	var catalog = _catalog_with([
		_building(&"ATBarracks", &"Atreides", {}, [&"ATConYard"], [&"Barracks"]),
		_building(&"FRCamp", &"Fremen", {}, [&"ATConYard"], [&"Camp"]),
		_building(&"ORBarracks", &"Ordos", {}, [&"ORConYard"], [&"Barracks"]),
	])

	var without_subhouse: Array[StringName] = catalog.buildable_building_ids_for_house(&"Atreides")
	_expect(without_subhouse.has(&"ATBarracks"), "the primary house must match")
	_expect(not without_subhouse.has(&"FRCamp"), "an unlisted subhouse must not match")
	_expect(not without_subhouse.has(&"ORBarracks"), "an unrelated house must not match")

	var fremen_subhouse: Array[StringName] = [&"Fremen"]
	var with_subhouse: Array[StringName] = catalog.buildable_building_ids_for_house(
		&"Atreides", fremen_subhouse
	)
	_expect(with_subhouse.has(&"ATBarracks"), "the primary house must still match alongside a subhouse")
	_expect(with_subhouse.has(&"FRCamp"), "a listed subhouse must match")
	_expect(not with_subhouse.has(&"ORBarracks"), "an unrelated house must not match even with a subhouse listed")
	return true


## Companion to _test_roster_filter(): the same Wall/RefineryDock entries the
## general roster excludes must be exactly what these two methods return, so
## BuildingController/BuildingUpgradeController can mix them back into their
## own grids (docs/mechanics/production.md sections 2 and 4).
func _test_wall_and_dock_ids() -> bool:
	var catalog = _catalog_with([
		_building(&"ATBarracks", &"Atreides", {}, [&"ATConYard"], [&"Barracks"]),
		_building(
			&"ATWall", &"Atreides", {"building_group": "Wall"}, [&"ATConYard"], [&"Wall"]
		),
		_building(
			&"ATRefineryDock",
			&"Atreides",
			{"building_group": "RefineryDock"},
			[&"ATConYard"],
			[&"Dockable"]
		),
		_building(
			&"ORWall", &"Ordos", {"building_group": "Wall"}, [&"ORConYard"], [&"Wall"]
		),
	])

	var wall_ids: Array[StringName] = catalog.wall_building_ids_for_house(&"Atreides")
	_expect(wall_ids == [&"ATWall"], "wall_building_ids_for_house must return only this house's Wall entries")

	var dock_ids: Array[StringName] = catalog.refinery_dock_building_ids_for_house(&"Atreides")
	_expect(dock_ids == [&"ATRefineryDock"], "refinery_dock_building_ids_for_house must return only this house's RefineryDock entries")

	_expect(
		not catalog.wall_building_ids_for_house(&"Ordos").has(&"ATWall"),
		"wall_building_ids_for_house must not leak another house's wall across"
	)
	return true


func _test_upgrade_roster() -> bool:
	var upgrade_fields := {"upgrade_cost": 600, "upgrade_tech_level": 4}
	var catalog = _catalog_with([
		_building(&"ATConYard", &"Atreides", upgrade_fields.merged({"is_con_yard": true}), [&"ConYard"]),
		_building(&"ATBarracks", &"Atreides", upgrade_fields, [&"ATConYard"], [&"Barracks"]),
		_building(&"ATSmWindtrap", &"Atreides", {}, [&"ATConYard"]),
		_building(&"ORConYard", &"Ordos", upgrade_fields.merged({"is_con_yard": true}), [&"ConYard"]),
	])

	var upgrades: Array[StringName] = catalog.upgrade_building_ids_for_house(&"Atreides")
	_expect(upgrades.has(&"ATConYard"), "an upgradeable Construction Yard must be available to the upgrade panel")
	_expect(upgrades.has(&"ATBarracks"), "an upgradeable constructible building must remain included")
	_expect(not upgrades.has(&"ATSmWindtrap"), "a building without upgrade fields must be excluded")
	_expect(not upgrades.has(&"ORConYard"), "another house's Construction Yard must be excluded")
	return true


func _test_unit_roster() -> bool:
	var catalog = _catalog_with([
		_unit(&"ATInfantry", &"Atreides", 60, [&"ATBarracks"]),
		_unit(&"ATMilitia", &"Atreides", 40, []),
		_unit(&"ATHawkWeapon", &"Atreides", 0, [&"ATPalace"]),
		_unit(&"FRFremen", &"Fremen", 150, [&"FRCamp"]),
		_unit(&"ORLaserTank", &"Ordos", 900, [&"ORFactory"]),
		_unit(&"Harvester", &"", 1000, [&"HKFactory", &"ATFactory", &"ORFactory"]),
		_unit(&"ATMCV", &"Atreides", 2000, [&"ATFactory"]),
		_unit(&"HKMCV", &"Harkonnen", 2000, [&"HKFactory"]),
		_unit(&"ORMCV", &"Ordos", 2000, [&"ORFactory"]),
	])

	var roster: Array[StringName] = catalog.producible_unit_ids_for_house(&"Atreides")
	_expect(roster.has(&"ATInfantry"), "a producible unit of the primary house must be included")
	_expect(roster.has(&"Harvester"), "a shared house-less unit must be included for every house")
	_expect(roster.has(&"ATMCV"), "the local factory's concrete MCV must be a roster candidate")
	_expect(
		roster.has(&"HKMCV") and roster.has(&"ORMCV"),
		"foreign MCV candidates must remain discoverable after their factories are captured"
	)
	_expect(not roster.has(&"ATMilitia"), "a unit with no primary_buildings (survivors/crates only) must be excluded")
	_expect(not roster.has(&"ATHawkWeapon"), "a cost-0 palace weapon must be excluded")
	_expect(not roster.has(&"FRFremen"), "an unlisted subhouse's unit must not match")
	_expect(not roster.has(&"ORLaserTank"), "an unrelated house's unit must not match")

	var fremen_subhouse: Array[StringName] = [&"Fremen"]
	var with_subhouse: Array[StringName] = catalog.producible_unit_ids_for_house(&"Atreides", fremen_subhouse)
	_expect(with_subhouse.has(&"FRFremen"), "a listed subhouse's unit must match")
	return true


## docs/architecture/network-multiplayer.md decision 4 ("One integer tick at
## 25 Hz"): the property this conversion exists to preserve is wall-clock
## duration, not the raw tick count, so that is what these cases assert.
func _test_rule_build_time_to_sim_ticks() -> bool:
	_expect(
		RuleBuildTimeScript.to_sim_ticks(60.0) == 25,
		"60 rule ticks (1 second at 60 Hz) must convert to 25 sim ticks (1 second at 25 Hz)"
	)

	# A longer duration must survive the round trip to within half a tick --
	# rounding to the nearest whole sim tick can cost at most that much.
	var rule_ticks := 300.0
	var rule_seconds := rule_ticks / float(RuleBuildTimeScript.RULE_BUILD_TICKS_PER_SECOND)
	var sim_ticks := RuleBuildTimeScript.to_sim_ticks(rule_ticks)
	var sim_seconds := float(sim_ticks) * MatchClockScript.SECONDS_PER_TICK
	_expect(sim_ticks == 125, "300 rule ticks (5 seconds at 60 Hz) must convert to 125 sim ticks")
	_expect(
		absf(sim_seconds - rule_seconds) <= 0.5 * MatchClockScript.SECONDS_PER_TICK,
		"the converted duration must stay within half a sim tick of the original"
	)

	_expect(RuleBuildTimeScript.to_sim_ticks(0.0) == 0, "a zero build time must convert to 0 sim ticks")
	_expect(RuleBuildTimeScript.to_sim_ticks(-10.0) == 0, "a negative build time must convert to 0 sim ticks")
	_expect(RuleBuildTimeScript.to_sim_ticks(NAN) == 0, "NaN must convert to 0 sim ticks")
	_expect(RuleBuildTimeScript.to_sim_ticks(INF) == 0, "positive infinity must convert to 0 sim ticks")
	_expect(RuleBuildTimeScript.to_sim_ticks(-INF) == 0, "negative infinity must convert to 0 sim ticks")

	_expect(
		RuleBuildTimeScript.to_sim_ticks(1.0) == 1,
		"a tiny positive build time must floor to 1 sim tick, not round down to 0"
	)

	# The order-creating form. Regression guard: 92 building definitions and 25
	# unit definitions ship with build_time_ticks = 0, and every order-creating
	# call site used to turn that into a buildable one-tick order via
	# maxf(..., 1.0). Dropping that floor would have made all of them --
	# ATConYard included -- fail ProductionQueue.adopt() and stop being
	# buildable, which no amount of green queue tests would have caught.
	_expect(
		RuleBuildTimeScript.order_sim_ticks(0.0) == 1,
		"an undefined build time must still yield a buildable one-tick order"
	)
	_expect(
		RuleBuildTimeScript.order_sim_ticks(-5.0) == 1,
		"a negative build time must still yield a buildable one-tick order"
	)
	_expect(
		RuleBuildTimeScript.order_sim_ticks(60.0) == 25,
		"a defined build time must convert identically through either entry point"
	)
	return true


func _catalog_with(configs: Array):
	var catalog = RulesCatalogScript.new()
	for config in configs:
		var bucket: Dictionary = catalog._by_type.get(String(config.entity_type), {})
		bucket[String(config.id)] = config
		catalog._by_type[String(config.entity_type)] = bucket
		catalog._all.append(config)
	return catalog


func _building(
		id: StringName,
		house: StringName,
		extra_fields: Dictionary,
		requires_primary: Array,
		roles: Array = []
):
	var config = RuleEntityConfigScript.new()
	config.id = id
	config.entity_type = &"building"
	var fields := {"house": String(house), "is_con_yard": false}
	fields.merge(extra_fields, true)
	config.fields = fields
	config.lists = {
		"requires_primary": requires_primary,
		"roles": roles,
	}
	return config


func _unit(
		id: StringName,
		house: StringName,
		cost: int,
		primary_buildings: Array
):
	var config = RuleEntityConfigScript.new()
	config.id = id
	config.entity_type = &"unit"
	var fields := {"cost": cost}
	if not String(house).is_empty():
		fields["house"] = String(house)
	config.fields = fields
	config.lists = {
		"primary_buildings": primary_buildings,
	}
	return config
