extends SceneTree

class FakeTarget extends Node3D:
	var owner_player_id := 2
	func simulation_position() -> Vector3:
		return position
	func combat_aim_position() -> Vector3:
		return position
	func combat_is_alive() -> bool:
		return true
	func is_enemy_of(_id: int) -> bool:
		return true

class FakeTurret extends RefCounted:
	var checks := 0
	func weapon_index() -> int:
		return 0
	func target_range(_candidate: Object) -> int:
		checks += 1
		return 2
	func has_line_of_fire(_candidate: Object, _shooter: Object) -> bool:
		return true
	func requires_hull_turn() -> bool:
		return false
	func requires_hull_turn_for(_pos: Vector3) -> bool:
		return false

class FakeIndex extends RefCounted:
	var ids: Dictionary = {}
	func id_for(node: Node) -> int:
		return int(ids.get(node, 0))

class FakeMatch extends Node:
	var calls := 0
	var idx: FakeIndex
	func entity_index() -> FakeIndex:
		calls += 1
		return idx

func _load_script(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		push_error("AP16 probe reload: %s" % err)
		quit(2)
	return script

func _measure(script: GDScript, shooter: Node3D, turret: FakeTurret, iterations: int) -> float:
	var acquisition = script.new()
	acquisition.configure(shooter)
	for i in 1000:
		acquisition.clear()
		acquisition.target_for(turret)
	var start := Time.get_ticks_usec()
	var chosen: Node3D
	turret.checks = 0
	for i in iterations:
		acquisition.clear()
		chosen = acquisition.target_for(turret)
	if turret.checks != iterations * 16:
		push_error("AP16 expected 16 usable checks per scan, got %d" % turret.checks)
		quit(3)
	if chosen == null:
		push_error("AP16 probe no target")
		quit(3)
	return float(Time.get_ticks_usec() - start) / float(iterations)

func _initialize() -> void:
	var old_source := FileAccess.get_file_as_string("/ap16head/head.gd")
	if old_source.is_empty():
		push_error("AP16 missing mounted HEAD source")
		quit(2)
		return
	var old_script := _load_script(old_source.replace("class_name CombatTargetAcquisition\n", ""))
	var new_script := _load_script(FileAccess.get_file_as_string("res://scripts/combat/combat_target_acquisition.gd").replace("class_name CombatTargetAcquisition\n", ""))
	var match_node := FakeMatch.new()
	match_node.idx = FakeIndex.new()
	root.add_child(match_node)
	match_node.add_to_group(&"match_root")
	var shooter := FakeTarget.new()
	shooter.owner_player_id = 1
	match_node.add_child(shooter)
	var targets: Array[FakeTarget] = []
	for i in 16:
		var target := FakeTarget.new()
		target.name = "Target_%02d" % i
		target.position = Vector3(5.0, 0.0, 0.0) if i == 0 else (Vector3(-5.0, 0.0, 0.0) if i == 1 else Vector3(10.0 + i, 0.0, 0.0))
		match_node.add_child(target)
		target.add_to_group(&"sim_units")
		match_node.idx.ids[target] = 1 if i == 1 else i + 2
		targets.append(target)
	await process_frame
	var turret := FakeTurret.new()
	if shooter.position.distance_squared_to(targets[0].position) \
	!= shooter.position.distance_squared_to(targets[1].position):
		push_error("AP16 cost fixture lacks exact nearest tie")
		quit(5)
		return
	var acq_old = old_script.new()
	acq_old.configure(shooter)
	var acq_new = new_script.new()
	acq_new.configure(shooter)
	var old_pick: Node3D = acq_old.target_for(turret)
	var new_pick: Node3D = acq_new.target_for(turret)
	print("AP16 profile precondition old=", old_pick.name, " new=", new_pick.name,
		" old_id=", match_node.idx.id_for(old_pick), " new_id=", match_node.idx.id_for(new_pick))
	if old_pick != targets[0] or new_pick != targets[1]:
		push_error("AP16 profile ordering contrast failed")
		quit(5)
		return
	# The nearest candidate is unique here; index resolution must remain lazy.
	var old_position := targets[1].position
	targets[1].position = Vector3(9, 0, 0)
	var no_tie_acq = new_script.new()
	no_tie_acq.configure(shooter)
	var calls_before := match_node.calls
	no_tie_acq.target_for(turret)
	if match_node.calls != calls_before:
		push_error("AP16 no-tie scan resolved registry index")
		quit(4)
		return
	targets[1].position = old_position
	var old_times: Array[float] = []
	var new_times: Array[float] = []
	for pair in 7:
		var old_us: float
		var new_us: float
		if pair % 2 == 0:
			old_us = _measure(old_script, shooter, turret, 5000)
			new_us = _measure(new_script, shooter, turret, 5000)
		else:
			new_us = _measure(new_script, shooter, turret, 5000)
			old_us = _measure(old_script, shooter, turret, 5000)
		old_times.append(old_us)
		new_times.append(new_us)
		print("AP16 pair ", pair, " old=", old_us, " new=", new_us, " added=", new_us - old_us)
	var deltas: Array[float] = []
	var qualifying := 0
	for i in 7:
		var d := new_times[i] - old_times[i]
		deltas.append(d)
		if d <= 8.0:
			qualifying += 1
	deltas.sort()
	var median_added := deltas[3]
	var e100 := 100.0 * maxf(0.0, median_added)
	print("AP16 cost votes=", qualifying, "/7 median_added_us=", median_added, " E100_us_per_tick=", e100)
	quit(0 if qualifying >= 5 and e100 <= 800.0 else 1)
