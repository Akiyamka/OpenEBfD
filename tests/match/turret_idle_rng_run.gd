extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const SimRngScript := preload("res://scripts/sim/sim_rng.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const HKGunTurretScene := preload("res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn")

class NullCallLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		if "null value" in str(code) or "null value" in str(rationale) or "Nil" in str(code) or "Nil" in str(rationale) or "Nonexistent function" in str(code):
			errors.append(str(code) + " " + str(rationale))

class PartialMatch extends Node:
	var index := EntityNodeIndexScript.new()
	var state := SimEntityStateScript.new(index.registry())
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func entity_index():
		return index
	func entity_state():
		return state
	func current_tick() -> int:
		return 1

class UnrelatedRngMatch extends Node:
	var rng = SimRngScript.new(998)
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func sim_rng():
		return rng

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("published tuple, expiry order and audit", _test_tuple)
	_run_case("weapon index and interleaving use independent keys", _test_keys)
	_run_case("interruptions and model rebind preserve next cycle", _test_cycles)
	_run_case("standalone construction has no null calls", _test_standalone)
	_run_case("RNG lookup rejects detached nodes", _test_detached_lookup)
	_run_case("partial Match uses positive IDs and local seed", _test_partial_match)
	await _run_async_case("real Match unit and building use shared audit", _test_real_match)
	await _run_async_case("equal-seed Matches ignore Node instance allocation", _test_real_match_pair)
	_finish("Turret idle RNG tests")

func _sample(seed: int, id: int, index: int, cycle: int, draw_index: int) -> int:
	return SimRngScript._sample(seed, SimRngScript.PURPOSE_TURRET_SCAN, id, index, cycle, draw_index)

func _interval(seed: int, id: int, index: int, cycle: int) -> float:
	return 3.0 + 2.0 * float(_sample(seed, id, index, cycle, 0) & 0xffffff) / 16777216.0

func _building() -> Node3D:
	var building = HKGunTurretScene.instantiate()
	root.add_child(building)
	return building

func _test_tuple() -> void:
	var building := _building()
	var turret = building.combat_turrets[0]
	var rng = SimRngScript.new(1)
	turret.set_idle_scan_source(rng, 1)
	_expect(_sample(1, 1, 0, 0, 0) == 0xd7c4b62b, "AP1 reference tuple must remain byte exact")
	turret.idle_scan(0.0)
	_expect(is_equal_approx(turret._idle_scan_seconds_until_target, _interval(1, 1, 0, 0)), "first interval uses cycle zero")
	_expect(rng.draw_count == 1 and rng.draw_signature == 0xd7c4b62b, "first interval makes one audited draw")
	turret.idle_scan(6.0)
	var expected_signature: int = (0xd7c4b62b + _sample(1, 1, 0, 0, 1) + _sample(1, 1, 0, 1, 0)) & 0xffffffff
	_expect(rng.draw_count == 3 and rng.draw_signature == expected_signature, "expiry audits yaw then next interval exactly once")
	_expect(is_equal_approx(turret._idle_scan_seconds_until_target, _interval(1, 1, 0, 1)), "expiry starts cycle one wait")
	_expect(absf(turret.current_yaw_degrees()) <= 70.01, "yaw stays inside forward sector")
	building.free()

func _test_keys() -> void:
	var first := _building()
	var second := _building()
	var third := _building()
	var a = first.combat_turrets[0]
	var b = second.combat_turrets[0]
	var rng = SimRngScript.new(73)
	a.set_idle_scan_source(rng, 11)
	b.set_idle_scan_source(rng, 12)
	b.idle_scan(0.0)
	a.idle_scan(0.0)
	_expect(is_equal_approx(a._idle_scan_seconds_until_target, _interval(73, 11, 0, 0)), "entity 11 uses its ID")
	_expect(is_equal_approx(b._idle_scan_seconds_until_target, _interval(73, 12, 0, 0)), "entity 12 uses its ID")
	var expected: int = (_sample(73, 11, 0, 0, 0) + _sample(73, 12, 0, 0, 0)) & 0xffffffff
	_expect(rng.draw_count == 2 and rng.draw_signature == expected, "reverse entry order has commutative audit")
	var model := Node3D.new()
	var pivot := Node3D.new()
	pivot.name = "::1turret"
	pivot.set_meta("original_name", "::1turret")
	model.add_child(pivot)
	var muzzle := Node3D.new()
	muzzle.name = ">>1muzzle"
	muzzle.set_meta("original_name", ">>1muzzle")
	pivot.add_child(muzzle)
	root.add_child(model)
	var indexed = third.combat_turrets[0]
	indexed.bind_model(model, 1)
	indexed.set_idle_scan_source(SimRngScript.new(73), 11)
	indexed.idle_scan(0.0)
	_expect(indexed.weapon_index() == 1 and is_equal_approx(indexed._idle_scan_seconds_until_target, _interval(73, 11, 1, 0)), "authored weapon one remains key one while stored alone")
	_expect(not is_equal_approx(_interval(73, 11, 1, 0), _interval(73, 11, 0, 0)), "weapon keys separate samples")
	first.free()
	second.free()
	third.free()
	model.free()

func _test_cycles() -> void:
	var building := _building()
	var turret = building.combat_turrets[0]
	var rng = SimRngScript.new(9)
	turret.set_idle_scan_source(rng, 5)
	turret.idle_scan(0.0)
	for _i in 5:
		turret.recenter(0.0)
	turret.idle_scan(0.0)
	_expect(is_equal_approx(turret._idle_scan_seconds_until_target, _interval(9, 5, 0, 1)), "many recenter calls consume only cycle one")
	var aim_point := Vector3(5.0, 0.0, 5.0)
	for _i in 5:
		turret.aim_at(aim_point, 0.0)
	turret.idle_scan(0.0)
	_expect(is_equal_approx(turret._idle_scan_seconds_until_target, _interval(9, 5, 0, 2)), "many engaged aim calls consume only cycle two")
	var model = building.state_root(building.current_state)
	turret.unbind_model()
	turret.bind_model(model, 0)
	turret.idle_scan(0.0)
	_expect(is_equal_approx(turret._idle_scan_seconds_until_target, _interval(9, 5, 0, 3)), "model rebind keeps next cycle")
	_expect(rng.draw_count == 4, "interruptions make one interval draw per entry")
	building.free()

func _test_standalone() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var building := _building()
	var unit = ATAPCScene.instantiate()
	root.add_child(unit)
	var building_turret = building.combat_turrets[0] if building.combat_turrets.size() == 1 else null
	var unit_turret = unit.combat_turrets[0] if unit.combat_turrets.size() == 1 else null
	var raw_turret = CombatTurretScript.new()
	var turret_id: StringName = building._native_definition_catalog.definition(building.config_id).turret_id
	var raw_ready: bool = raw_turret.configure(turret_id) \
		and raw_turret.bind_model(building.state_root(building.current_state), 0)
	OS.remove_logger(logger)
	_expect(logger.errors.is_empty(), "standalone constructors must not call through null")
	_expect(building_turret != null and unit_turret != null and raw_ready, "standalone owners and raw turret must bind")
	if building_turret != null and unit_turret != null and raw_ready:
		OS.add_logger(logger)
		building_turret.idle_scan(0.0)
		unit_turret.idle_scan(0.0)
		raw_turret.idle_scan(0.0)
		OS.remove_logger(logger)
		_expect(logger.errors.is_empty(), "standalone scans must not call through null")
		_expect(
			_in_wait_window(building_turret) and _in_wait_window(unit_turret)
				and _in_wait_window(raw_turret),
			"standalone waits remain in the old window"
		)
	raw_turret.unbind_model()
	building.free()
	unit.free()

func _in_wait_window(turret) -> bool:
	return turret._idle_scan_seconds_until_target >= 3.0 \
		and turret._idle_scan_seconds_until_target < 5.0

func _test_detached_lookup() -> void:
	var detached := Node.new()
	_expect(MatchLookupScript.sim_rng(null) == null and MatchLookupScript.sim_rng(detached) == null, "null and detached owners cannot borrow a Match RNG")
	detached.free()

func _test_partial_match() -> void:
	var stub := PartialMatch.new()
	root.add_child(stub)
	var unrelated := UnrelatedRngMatch.new()
	root.add_child(unrelated)
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var child = ATAPCScene.instantiate()
	stub.add_child(child)
	var beside = ATAPCScene.instantiate()
	root.add_child(beside)
	OS.remove_logger(logger)
	_expect(logger.errors.is_empty(), "partial Match constructors must not call absent sim_rng")
	for apc in [child, beside]:
		_expect(apc.entity_id > 0 and apc.combat_turrets.size() == 1, "each APC registers and creates one turret")
		if apc.entity_id > 0 and apc.combat_turrets.size() == 1:
			var turret = apc.combat_turrets[0]
			OS.add_logger(logger)
			turret.idle_scan(0.0)
			OS.remove_logger(logger)
			_expect(is_equal_approx(turret._idle_scan_seconds_until_target, _interval(1, apc.entity_id, 0, 0)), "fallback uses seed one and positive registered ID")
	_expect(logger.errors.is_empty(), "partial Match scans must not call through null")
	_expect(unrelated.rng.draw_count == 0 and MatchLookupScript.sim_rng(child) == null, "unrelated RNG is not borrowed")
	child.free()
	beside.free()
	stub.free()
	unrelated.free()

func _test_real_match() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=54321"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 1
	match_instance.get_node("Units").add_child(unit)
	var building = HKGunTurretScene.instantiate()
	building.owner_player_id = 1
	match_instance.get_node("Buildings").add_child(building)
	await process_frame
	match_instance.set_process(false)
	var rng = match_instance.sim_rng()
	var unit_turret = unit.combat_turrets[0] if unit.combat_turrets.size() == 1 else null
	var building_turret = building.combat_turrets[0] if building.combat_turrets.size() == 1 else null
	_expect(unit.entity_id > 0 and building.entity_id > 0 and unit_turret != null and building_turret != null, "real Match registers both armed owners")
	if unit_turret != null and building_turret != null:
		_expect(unit_turret._idle_scan_rng == rng and building_turret._idle_scan_rng == rng, "both turret sources are Match-owned")
		var before: int = rng.draw_count
		unit_turret.idle_scan(0.0)
		building_turret.idle_scan(0.0)
		var expected: int = (_sample(54321, unit.entity_id, 0, 0, 0) + _sample(54321, building.entity_id, 0, 0, 0)) & 0xffffffff
		_expect(is_equal_approx(unit_turret._idle_scan_seconds_until_target, _interval(54321, unit.entity_id, 0, 0)), "real unit interval uses Match seed and ID")
		_expect(is_equal_approx(building_turret._idle_scan_seconds_until_target, _interval(54321, building.entity_id, 0, 0)), "real building interval uses Match seed and ID")
		_expect(rng.draw_count == before + 2 and rng.draw_signature == expected, "two real turrets enter Match audit")
		var checksum: int = match_instance.match_checksum()
		rng.draw(1, 99, 0, 0, 0)
		_expect(match_instance.match_checksum() != checksum, "Match checksum includes audit")
		var audit: int = rng.draw_count
		var yaw: float = unit_turret.current_yaw
		unit._process(20.0)
		building._process(20.0)
		_expect(rng.draw_count == audit and is_equal_approx(unit_turret.current_yaw, yaw), "rendered owner frames do not draw or change logic yaw")
	match_instance.free()

func _test_real_match_pair() -> void:
	var first: Dictionary = await _capture_match_pair(54321, 0)
	var second: Dictionary = await _capture_match_pair(54321, 17)
	var changed: Dictionary = await _capture_match_pair(54322, 3)
	_expect(first["unit_id"] == second["unit_id"] and first["building_id"] == second["building_id"], "extra nonentity Nodes do not change registry IDs")
	_expect(first["unit_wait"] == second["unit_wait"] and first["building_wait"] == second["building_wait"] and first["audit"] == second["audit"], "same seed and IDs produce identical intervals and audit")
	_expect(changed["unit_wait"] == _interval(54322, changed["unit_id"], 0, 0) and changed["unit_wait"] != first["unit_wait"], "different explicit seed selects the known different sample")

func _capture_match_pair(seed: int, noise_count: int) -> Dictionary:
	var noise: Array[Node] = []
	for _index in noise_count:
		var extra := Node.new()
		root.add_child(extra)
		noise.append(extra)
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=%d" % seed])
	root.add_child(match_instance)
	match_instance.set_process(false)
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 1
	match_instance.get_node("Units").add_child(unit)
	var building = HKGunTurretScene.instantiate()
	building.owner_player_id = 1
	match_instance.get_node("Buildings").add_child(building)
	await process_frame
	match_instance.set_process(false)
	var unit_id: int = unit.entity_id
	var building_id: int = building.entity_id
	var unit_turret = unit.combat_turrets[0] if unit.combat_turrets.size() == 1 else null
	var building_turret = building.combat_turrets[0] if building.combat_turrets.size() == 1 else null
	_expect(unit_id > 0 and building_id > 0 and unit_turret != null and building_turret != null, "pair fixture registers its two turrets")
	var result := {"unit_id": unit_id, "building_id": building_id, "unit_wait": 0.0, "building_wait": 0.0, "audit": 0}
	if unit_turret != null and building_turret != null:
		unit_turret.idle_scan(0.0)
		building_turret.idle_scan(0.0)
		result["unit_wait"] = unit_turret._idle_scan_seconds_until_target
		result["building_wait"] = building_turret._idle_scan_seconds_until_target
		result["audit"] = match_instance.sim_rng().draw_signature
		_expect(result["unit_wait"] == _interval(seed, unit_id, 0, 0) and result["building_wait"] == _interval(seed, building_id, 0, 0), "each pair arm uses its explicit seed and stable IDs")
		_expect(match_instance.sim_rng().draw_count == 2, "each pair arm audits exactly two draws")
	match_instance.free()
	for extra in noise:
		extra.free()
	return result
