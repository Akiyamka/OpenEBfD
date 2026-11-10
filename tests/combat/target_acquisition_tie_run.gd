extends SceneTree

const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const AcquisitionScript := preload("res://scripts/combat/combat_target_acquisition.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")

class FakeTarget extends Node3D:
	var owner_player_id := 2
	func simulation_position() -> Vector3:
		return position
	func combat_aim_position() -> Vector3:
		return position
	func combat_is_alive() -> bool:
		return true
	func is_enemy_of(id: int) -> bool:
		return owner_player_id != id

class FakeTurret extends RefCounted:
	var index := 0
	var visits: Array = []
	var out_of_range: Dictionary = {}
	func weapon_index() -> int:
		return index
	func target_range(c: Object) -> int:
		return 3 if out_of_range.has(c) else 2
	func has_line_of_fire(c: Object, _s: Object) -> bool:
		visits.append(c)
		return true
	func requires_hull_turn() -> bool:
		return false
	func requires_hull_turn_for(_p: Vector3) -> bool:
		return false

class FakeMatch extends Node:
	var index = EntityNodeIndexScript.new()
	var calls := 0
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func entity_index():
		calls += 1
		return index

class WarnLogger extends Logger:
	var warnings := 0
	var by_weapon: Dictionary = {}
	var errors: Array = []
	func _log_error(_f, _file, _line, code, rationale, _n, error_type, _bt) -> void:
		var text := str(code) + " " + str(rationale)
		if error_type == ERROR_TYPE_WARNING:
			if "AP16_AMBIGUOUS" in text:
				warnings += 1
				var w := text.split("weapon ")[1].split(":")[0] if "weapon " in text else "?"
				by_weapon[w] = int(by_weapon.get(w, 0)) + 1
		else:
			errors.append(text)

var _failures: Array = []
var _script: GDScript = AcquisitionScript
var _holder: Node
var _logger: WarnLogger

func _check(arm: String, cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(arm + ": " + msg)

func _begin(with_match: bool) -> Node:
	_logger = WarnLogger.new()
	OS.add_logger(_logger)
	if with_match:
		_holder = FakeMatch.new()
	else:
		_holder = Node.new()
	root.add_child(_holder)
	return _holder

func _end() -> void:
	OS.remove_logger(_logger)
	_holder.free()
	_holder = null

func _shooter() -> FakeTarget:
	var s := FakeTarget.new()
	s.owner_player_id = 1
	s.name = "Shooter"
	_holder.add_child(s)
	if not _holder is FakeMatch:
		_check("no-Match precondition", MatchLookupScript.entity_index(s) == null, "unexpected entity index")
	return s

func _cand(name: String, pos: Vector3) -> FakeTarget:
	var c := FakeTarget.new()
	c.name = name
	c.position = pos
	return c

func _place(nodes: Array) -> void:
	for n in nodes:
		_holder.add_child(n)
		n.add_to_group(&"sim_units")

func _acq(shooter: Node3D):
	var a = _script.new()
	a.configure(shooter)
	return a

func _sub(visits: Array, wanted: Array) -> Array:
	var out := []
	for v in visits:
		if v in wanted:
			out.append(v)
	return out


func _target_control(arm: String, acq, turret: FakeTurret, target: FakeTarget) -> void:
	_check(arm, target.is_inside_tree() and target.combat_is_alive(), "candidate not live")
	_check(arm, target.is_enemy_of(1), "candidate not enemy")
	_check(arm, target.is_in_group(&"sim_units"), "candidate not in simulation group")
	_check(arm, turret.target_range(target) == 2, "candidate not in range")
	_check(arm, acq.is_usable(turret, target), "candidate not usable or visible")

# ---------------- A1
func _a1(arm: String, tree_ab: bool, same_order: bool, far_first: bool) -> void:
	var m: FakeMatch = _begin(true)
	var shooter := _shooter()
	var a := _cand("A", Vector3(5, 0, 0))
	var b := _cand("B", Vector3(-5, 0, 0))
	var others: Array = []
	for i in 14:
		others.append(_cand("O%d" % i, Vector3(10.0 + i, 0, 0)))
	if same_order:
		m.index.register(a, 1)
		m.index.register(b, 1)
	else:
		m.index.register(b, 1)
		m.index.register(a, 1)
	for o in others:
		m.index.register(o, 1)
	var order: Array = [a, b] if tree_ab else [b, a]
	if far_first:
		_place(others)
		_place(order)
	else:
		_place(order)
		_place(others)
	var acq = _acq(shooter)
	var turret := FakeTurret.new()
	var sp := shooter.simulation_position()
	_check(arm, sp.distance_squared_to(a.simulation_position()) == sp.distance_squared_to(b.simulation_position()), "exact distance control")
	_check(arm, a.get_instance_id() < b.get_instance_id(), "instance A<B control")
	if same_order:
		_check(arm, m.index.id_for(a) < m.index.id_for(b), "registry A<B control")
	else:
		_check(arm, m.index.id_for(b) < m.index.id_for(a), "registry B<A control")
	_check(arm, acq.is_usable(turret, a) and acq.is_usable(turret, b), "usable control")
	_target_control(arm, acq, turret, a)
	_target_control(arm, acq, turret, b)
	turret.visits.clear()
	var got = acq.target_for(turret)
	_check(arm, _sub(turret.visits, [a, b]) == order, "visit order control")
	var expected := a if same_order else b
	_check(arm, got == expected, "winner (got %s)" % (got.name if got != null else "null"))
	_check(arm, _logger.errors.is_empty(), "errors %s" % str(_logger.errors))
	_end()

# ---------------- A3 positional
func _a3_pos(arm: String, tree_ab: bool) -> void:
	_begin(false)
	var shooter := _shooter()
	var a := _cand("A", Vector3(3, 0, 4))
	var b := _cand("B", Vector3(-3, 0, 4))
	var order: Array = [a, b] if tree_ab else [b, a]
	_place(order)
	var acq = _acq(shooter)
	var turret := FakeTurret.new()
	var sp := shooter.simulation_position()
	_check(arm, sp.distance_squared_to(a.position) == sp.distance_squared_to(b.position), "exact distance control")
	_target_control(arm, acq, turret, a)
	_target_control(arm, acq, turret, b)
	turret.visits.clear()
	var got = acq.target_for(turret)
	_check(arm, _sub(turret.visits, [a, b]) == order, "visit order control")
	_check(arm, got == b, "winner (got %s)" % (got.name if got != null else "null"))
	_check(arm, _logger.warnings == 0, "warnings %d" % _logger.warnings)
	_check(arm, _logger.errors.is_empty(), "errors %s" % str(_logger.errors))
	_end()

func _a3_unique(arm: String) -> void:
	_begin(false)
	var shooter := _shooter()
	var n := _cand("N", Vector3(2, 0, 0))
	_place([n, _cand("F1", Vector3(6, 0, 0)), _cand("F2", Vector3(-6, 0, 0))])
	var acq = _acq(shooter)
	var got = acq.target_for(FakeTurret.new())
	_check(arm, got == n, "winner (got %s)" % (got.name if got != null else "null"))
	_check(arm, _logger.errors.is_empty(), "errors %s" % str(_logger.errors))
	_end()

func _a3_dup(arm: String, xy: bool) -> void:
	_begin(false)
	var shooter := _shooter()
	var f := _cand("F", Vector3(0, 0, 8))
	var x := _cand("X", Vector3(5, 0, 0))
	var y := _cand("Y", Vector3(5, 0, 0))
	_place([f] + ([x, y] if xy else [y, x]))
	var acq = _acq(shooter)
	var turret := FakeTurret.new()
	_target_control(arm, acq, turret, x)
	_target_control(arm, acq, turret, y)
	_check(arm, shooter.position.distance_squared_to(x.position) == shooter.position.distance_squared_to(y.position), "duplicate exact distance")
	turret.visits.clear()
	var got = acq.target_for(turret)
	_check(arm, _sub(turret.visits, [x, y]) == ([x, y] if xy else [y, x]), "duplicate tree visit order")
	_check(arm, turret.visits.size() == 3, "full scan visits %d" % turret.visits.size())
	_check(arm, got == null, "null verdict (got %s)" % (got.name if got != null else "null"))
	_check(arm, _logger.warnings == 1, "warnings %d" % _logger.warnings)
	_check(arm, _logger.errors.is_empty(), "errors %s" % str(_logger.errors))
	_end()

func _a3_repeat(arm: String) -> void:
	_begin(false)
	var shooter := _shooter()
	_place([_cand("F", Vector3(0, 0, 8)), _cand("X", Vector3(5, 0, 0)), _cand("Y", Vector3(5, 0, 0))])
	var acq = _acq(shooter)
	var t0 := FakeTurret.new()
	var r1 = acq.target_for(t0)
	acq.advance(0.3)
	var r2 = acq.target_for(t0)
	acq.clear()
	acq.forget(0)
	var r3 = acq.target_for(t0)
	acq.dispose()
	acq.configure(shooter)
	var r4 = acq.target_for(t0)
	_check(arm, r1 == null and r2 == null and r3 == null and r4 == null, "all four null")
	_check(arm, int(_logger.by_weapon.get("0", 0)) == 1, "weapon0 warnings %s" % str(_logger.by_weapon))
	var t1 := FakeTurret.new()
	t1.index = 1
	var r5 = acq.target_for(t1)
	_check(arm, r5 == null, "weapon1 null")
	_check(arm, int(_logger.by_weapon.get("1", 0)) == 1, "weapon1 warnings %s" % str(_logger.by_weapon))
	_check(arm, _logger.errors.is_empty(), "errors %s" % str(_logger.errors))
	_end()

func _a3_resolver(arm: String, kind: String) -> void:
	var m = _begin(kind == "registered")
	var shooter := _shooter()
	var x := _cand("X", Vector3(5, 0, 0))
	var y := _cand("Y", Vector3(5, 0, 0))
	var r: FakeTarget
	if kind == "nearer":
		r = _cand("N", Vector3(2, 0, 0))
	elif kind == "registered":
		r = _cand("R", Vector3(0, 0, 5))
		m.index.register(r, 1)
	else:
		r = _cand("Z", Vector3(-5, 0, 0))
	if kind == "lexZXY":
		_place([r, x, y])
	else:
		_place([x, y, r])
	var acq = _acq(shooter)
	var turret := FakeTurret.new()
	_target_control(arm, acq, turret, x)
	_target_control(arm, acq, turret, y)
	_target_control(arm, acq, turret, r)
	_check(arm, acq.is_usable(turret, r), "resolver usable control")
	turret.visits.clear()
	var got = acq.target_for(turret)
	_check(arm, r in turret.visits, "resolver visited")
	_check(arm, got == r, "winner (got %s)" % (got.name if got != null else "null"))
	_check(arm, _logger.warnings == 0, "warnings %d" % _logger.warnings)
	_check(arm, _logger.errors.is_empty(), "errors %s" % str(_logger.errors))
	_end()

func _a3_mixed(arm: String, reg_first: bool) -> void:
	var m: FakeMatch = _begin(true)
	var shooter := _shooter()
	var u := _cand("U", Vector3(5, 0, 0))
	var r := _cand("R", Vector3(-5, 0, 0))
	m.index.register(r, 1)
	_place([r, u] if reg_first else [u, r])
	var acq = _acq(shooter)
	var got = acq.target_for(FakeTurret.new())
	_check(arm, got == r, "winner (got %s)" % (got.name if got != null else "null"))
	_check(arm, _logger.errors.is_empty(), "errors %s" % str(_logger.errors))
	_end()

# ---------------- A4
func _a4_nearest(arm: String) -> void:
	var m: FakeMatch = _begin(true)
	var shooter := _shooter()
	var f := _cand("F", Vector3(6, 0, 0))
	var c := _cand("C", Vector3(3, 0, 0))
	m.index.register(f, 1)
	m.index.register(c, 1)
	_place([f, c])
	var acq = _acq(shooter)
	var calls0: int = m.calls
	var got = acq.target_for(FakeTurret.new())
	_check(arm, got == c, "nearer wins (got %s)" % (got.name if got != null else "null"))
	_check(arm, m.calls == calls0, "no-tie lookups %d" % (m.calls - calls0))
	_end()

func _a4_cache(arm: String) -> void:
	var m: FakeMatch = _begin(true)
	var shooter := _shooter()
	var c := _cand("C", Vector3(3, 0, 0))
	m.index.register(c, 1)
	_place([c])
	var acq = _acq(shooter)
	var turret := FakeTurret.new()
	turret.out_of_range[c] = true
	var s1 = acq.target_for(turret)
	turret.out_of_range.erase(c)
	var s2 = acq.target_for(turret)
	_check(arm, s1 == null and s2 == null, "cooldown blocks rescan")
	acq.advance(0.3)
	var s3 = acq.target_for(turret)
	_check(arm, s3 == c, "rescan after expiry")
	var d := _cand("D", Vector3(1, 0, 0))
	m.index.register(d, 1)
	_place([d])
	var s4 = acq.target_for(turret)
	_check(arm, s4 == c, "cache retained (got %s)" % (s4.name if s4 != null else "null"))
	_end()

func _run_variant(label: String) -> void:
	_failures.clear()
	_a1("A1-opp-AB", true, false, false)
	_a1("A1-opp-BA", false, false, false)
	_a1("A1-same(B,A)", false, true, false)
	_a3_pos("A3-pos-AB", true)
	_a3_pos("A3-pos-BA", false)
	_a3_unique("A3-unique")
	_a3_dup("A3-dup-XY", true)
	_a3_dup("A3-dup-YX", false)
	_a3_repeat("A3-repeat")
	_a3_resolver("A3-res-nearer", "nearer")
	_a3_resolver("A3-res-registered", "registered")
	_a3_resolver("A3-res-lexXYZ", "lexXYZ")
	_a3_resolver("A3-res-lexZXY", "lexZXY")
	_a3_mixed("A3-mixed-UR", false)
	_a3_mixed("A3-mixed-RU", true)
	_a4_nearest("A4-nearest")
	_a4_cache("A4-cache")
	var arms := {}
	for f in _failures:
		arms[f.split(":")[0] if not f.begins_with("diag:") else "diag:" + f.split(":")[1]] = true
	print("VARIANT ", label, " failing_arms=", arms.keys())
	for f in _failures:
		print("  detail ", label, " ", f)

func _initialize() -> void:
	await process_frame
	_run_variant("BASE")
	for failure in _failures:
		push_error(failure)
	print("Target acquisition tie: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
