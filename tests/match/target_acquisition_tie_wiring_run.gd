extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const UnitScene := preload("res://scenes/units/unit.tscn")
const MongooseModel := preload("res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const HKGunTurretScene := preload("res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn")

var _failures: Array[String] = []

func _check(arm: String, condition: bool, message: String) -> void:
	if not condition:
		_failures.append(arm + ": " + message)

func _name(ref: WeakRef) -> String:
	if ref == null or ref.get_ref() == null:
		return "none"
	return String(ref.get_ref().name)

func _arm(kind: String) -> void:
	var m = MatchFixtureScene.instantiate()
	m.match_seed_args_for_test = PackedStringArray(["--match-seed=1"])
	root.add_child(m)
	m.set_process(false)
	var shooter
	var acq
	var hull_aim := 0
	if kind == "building":
		shooter = HKGunTurretScene.instantiate()
		shooter.owner_player_id = 1
		shooter.position = Vector3(70.0, 8.0, 40.0)
		m.get_node("Buildings").add_child(shooter)
	else:
		shooter = UnitScene.instantiate()
		shooter.config_id = &"ATMongoose"
		m.get_node("Units").add_child(shooter)
		shooter.replace_visual_scene(MongooseModel)
		shooter.owner_player_id = 1
		shooter.set_simulation_position(Vector3(70.0, 8.0, 40.0))
	for i in 4:
		await physics_frame
	await process_frame
	m.set_process(false)
	m.advance_ticks(2)
	if kind == "building":
		acq = shooter._building_combat._target_acquisition
	else:
		acq = shooter.combat()._target_acquisition
		shooter.move_to(shooter.simulation_position() + Vector3(0, 0, 2.0))
		for i in 200:
			m.advance_ticks(1)
			if not shooter.has_active_move_order():
				break
		_check(kind, shooter.combat()._moving_fire_weapons.has(0), "moving-fire autonomy absent")
		_check(kind, not shooter.has_active_move_order(), "move order still active")
		hull_aim = 2
	var turret = shooter.combat_turrets[0]
	_check(kind, acq._targets.get(0) == null, "cache was populated before candidates")
	var ua = ATAPCScene.instantiate()
	ua.name = "CandA"
	var ub = ATAPCScene.instantiate()
	ub.name = "CandB"
	ua.owner_player_id = 2
	ub.owner_player_id = 2
	ua.position = Vector3(76.0, 8.0, 40.0)
	ub.position = Vector3(76.0, 8.0, 40.0)
	m.get_node("Units").add_child(ub)
	m.get_node("Units").add_child(ua)
	var fired: Array = []
	shooter.weapon_fired.connect(func(_p, t, _w): fired.append(t))
	var selected_tick := -1
	for tick in 300:
		m.advance_ticks(1)
		if selected_tick < 0 and acq._targets.get(0) != null and acq._targets.get(0).get_ref() != null:
			selected_tick = tick
			var sp: Vector3 = shooter.simulation_position()
			var da: float = sp.distance_squared_to(ua.simulation_position())
			var db: float = sp.distance_squared_to(ub.simulation_position())
			_check(kind, tick <= 7, "selection after exact-tie window")
			_check(kind, da == db, "stored squared distances differ on selection tick")
			_check(kind, ua.get_instance_id() < ub.get_instance_id(), "instance order A<B absent")
			var index = m.entity_index()
			_check(kind, index.id_for(ub) > 0 and index.id_for(ub) < index.id_for(ua), "registry order B<A absent")
			_check(kind, acq.is_usable(turret, ua, hull_aim) and acq.is_usable(turret, ub, hull_aim), "candidate usability absent")
			_check(kind, acq._targets[0].get_ref() == ub, "cached winner is not B")
		if not fired.is_empty():
			break
	_check(kind, selected_tick >= 0, "no first selection")
	_check(kind, not fired.is_empty() and fired[0] == ub, "first shot was not B")
	m.free()

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _arm("building")
	await _arm("unit")
	for failure in _failures:
		push_error(failure)
	print("Target acquisition wiring: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
