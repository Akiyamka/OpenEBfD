extends SceneTree
const ArcTree := preload("res://scripts/units/navigation/ground/attack_arc_allocator.gd")
const OrcaTree := preload("res://scripts/units/navigation/ground/orca_avoidance.gd")
const SimMathScript := preload("res://scripts/sim/sim_math.gd")
const NavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
const NavigationTestScript := preload("res://tests/navigation/run.gd")
const SteeringStabilizerScript := preload("res://scripts/units/navigation/ground/steering_stabilizer.gd")
const COURSE_DAMPING_SHARE := 0.35

class CheapUnit extends Node3D:
	var sim_pos := Vector3.ZERO
	func simulation_position() -> Vector3:
		return sim_pos

class TerrainStub extends RefCounted:
	var obstacles: Array = []
	var visits := 0
	func terrain_context(_agent, _reach) -> Dictionary:
		visits += 1
		return {"escape": false, "hard_radius": 0.5, "obstacles": obstacles}

class CountingStabilizer extends SteeringStabilizerScript:
	var agent_ticks := 0
	var sector_calls := 0
	var hard_terrain_ticks := 0
	func terrain_context(agent: Dictionary, movement_reach: float) -> Dictionary:
		var context: Dictionary = super.terrain_context(agent, movement_reach)
		if not bool(context.get("escape", false)):
			agent_ticks += 1
			sector_calls += (context["obstacles"] as Array).size()
			if not (context["obstacles"] as Array).is_empty():
				hard_terrain_ticks += 1
		return context

func _initialize() -> void:
	await process_frame
	for base in ["attack_arc_allocator", "orca_avoidance"]:
		var source_path := "/ap9_head/%s.gd" % base
		var expected_path := "/ap9_head/%s.sha256" % base
		var source_hash := FileAccess.get_sha256(source_path)
		var expected_hash := FileAccess.get_file_as_string(expected_path).strip_edges()
		if source_hash != expected_hash:
			printerr("A7: HEAD source hash mismatch for %s: %s != %s" % [base, source_hash, expected_hash])
			quit(1)
			return
		print("A7 verified HEAD %s %s" % [base, source_hash])
	var arc_head_script = load("/ap9_head/attack_arc_allocator.gd")
	var orca_head_script = load("/ap9_head/orca_avoidance.gd")
	if arc_head_script == null or orca_head_script == null:
		printerr("A7: HEAD source failed to load")
		quit(1)
		return
	if arc_head_script.source_code != FileAccess.get_file_as_string("/ap9_head/attack_arc_allocator.gd") or \
		orca_head_script.source_code != FileAccess.get_file_as_string("/ap9_head/orca_avoidance.gd"):
		printerr("A7: loaded HEAD source differs from verified mount")
		quit(1)
		return
	if OS.get_cmdline_user_args().has("--warm-only"):
		var warm: Dictionary = _whole_arm(orca_head_script, arc_head_script)
		print("A7 discarded warm-up container: %s" % warm)
		quit(1 if warm.has("error") else 0)
		return
	var arc_head = arc_head_script.new()
	var arc_tree := ArcTree.new()
	var orca_tree := OrcaTree.new()
	var units: Array[Node3D] = []
	var arc_agents := {}
	for i in 6:
		var unit := CheapUnit.new()
		unit.sim_pos = Vector3(118.5 + i, 0, 132.5)
		units.append(unit)
		arc_agents[unit.get_instance_id()] = {"id": i + 1, "radius": 0.35}
	var arc_h := _arc_time(arc_head, arc_agents, units, 1000)
	var arc_t := _arc_time(arc_tree, arc_agents, units, 1000)
	var arc_pairs: Array[float] = []
	var arc_vote := 0
	for i in 7:
		if i % 2 == 0:
			arc_h = _arc_time(arc_head, arc_agents, units, 10000)
			arc_t = _arc_time(arc_tree, arc_agents, units, 10000)
		else:
			arc_t = _arc_time(arc_tree, arc_agents, units, 10000)
			arc_h = _arc_time(arc_head, arc_agents, units, 10000)
		arc_pairs.append(arc_t - arc_h)
		arc_vote += int(arc_t / arc_h <= 2.0)
		print("A7 arc pair %d HEAD %.3f tree %.3f ratio %.3f added %.3f us" % [i, arc_h, arc_t, arc_t / arc_h, arc_t - arc_h])
	var previous := Vector3(0.8, 0, 0.6)
	var target := Vector3(0.6, 0, 0.8)
	_damp_head(previous, target, 10000)
	_damp_tree(previous, target, 10000)
	var damp_pairs: Array[float] = []
	var damp_vote := 0
	for i in 7:
		var h: float
		var t: float
		if i % 2 == 0:
			h = _damp_head(previous, target, 100000)
			t = _damp_tree(previous, target, 100000)
		else:
			t = _damp_tree(previous, target, 100000)
			h = _damp_head(previous, target, 100000)
		damp_pairs.append(t - h)
		damp_vote += int(t - h <= 3.0)
		print("A7 damping pair %d HEAD inline %.3f tree %.3f added %.3f us ratio %.2f" % [i, h, t, t - h, t / h])
	var below_target := previous.normalized().rotated(Vector3.UP, 0.003)
	if SimMathScript.damped_horizontal(previous.normalized(), below_target) != previous.normalized():
		printerr("A7: below-threshold damping control did not exit early")
		quit(1)
		return
	print("A7 below-threshold tree helper %.3f us/call" % _damp_tree(previous, below_target, 100000))
	var full := TerrainStub.new()
	var empty := TerrainStub.new()
	var center := Vector3(100.5, 0, 100.5)
	for k in 40:
		var angle := -PI + (float(k) + 0.5) * TAU / 40.0
		full.obstacles.append(center + Vector3(cos(angle), 0, sin(angle)) * (1.2 + 0.03 * float(k % 5)))
	var heads := [orca_head_script.new(), orca_head_script.new()]
	var trees := [orca_tree, orca_tree_script_instance()]
	heads[0].setup(null, full)
	heads[1].setup(null, empty)
	trees[0].setup(null, full)
	trees[1].setup(null, empty)
	var agent := {"unit": CheapUnit.new(), "radius": 0.5, "orca_velocity": Vector3.ZERO,
		"avoidance_direction": Vector3.ZERO, "blocked_time": 0.0, "_squeeze_cooldown": 0}
	(agent["unit"] as CheapUnit).sim_pos = center
	var head_sectors := _observed_sectors("/ap9_head/orca_avoidance.gd", full, agent)
	var tree_sectors := _observed_sectors("res://scripts/units/navigation/ground/orca_avoidance.gd", full, agent)
	if head_sectors.size() != 40 or tree_sectors != head_sectors:
		printerr("A7: HEAD/tree nonboundary sector selections differ: %s / %s" % [head_sectors, tree_sectors])
		quit(1)
		return
	print("A7 HEAD/tree selected identical sectors for %d nonboundary obstacles" % head_sectors.size())
	for object in heads + trees:
		_orca_time(object, agent, 1000)
	var sector_pairs: Array[float] = []
	var sector_vote := 0
	for i in 7:
		var hfull: float
		var hempty: float
		var tfull: float
		var tempty: float
		if i % 2 == 0:
			hfull = _orca_time(heads[0], agent, 10000)
			hempty = _orca_time(heads[1], agent, 10000)
			tfull = _orca_time(trees[0], agent, 10000)
			tempty = _orca_time(trees[1], agent, 10000)
		else:
			tfull = _orca_time(trees[0], agent, 10000)
			tempty = _orca_time(trees[1], agent, 10000)
			hfull = _orca_time(heads[0], agent, 10000)
			hempty = _orca_time(heads[1], agent, 10000)
		var added := ((tfull - tempty) - (hfull - hempty)) / 40.0
		sector_pairs.append(added)
		sector_vote += int(added <= 0.07)
		print("A7 sector pair %d HEAD %.3f/%.3f tree %.3f/%.3f added %.4f us/obstacle" % [i, hfull, hempty, tfull, tempty, added])
	arc_pairs.sort()
	damp_pairs.sort()
	sector_pairs.sort()
	var da := maxf(0.0, arc_pairs[3])
	var dd := maxf(0.0, damp_pairs[3])
	var ds := maxf(0.0, sector_pairs[3])
	var e200 := 200.0 * (40.0 * ds + dd) + da
	print("A7 votes arc %d/7 sector %d/7 damping %d/7; clamped sector %.4f; E200 %.3f us/tick" % [arc_vote, sector_vote, damp_vote, ds, e200])
	var whole_pass := _whole_tick_pairs(orca_head_script, arc_head_script, ds, dd, da)
	for unit in units:
		unit.free()
	(agent["unit"] as CheapUnit).free()
	quit(0 if arc_vote >= 5 and sector_vote >= 5 and damp_vote >= 5 and e200 <= 1000.0 and whole_pass else 1)

func _make_grid():
	var total := MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE
	var cpf := PackedInt32Array()
	var terrain := PackedInt32Array()
	var source_x := PackedInt32Array()
	var source_y := PackedInt32Array()
	var spice := PackedByteArray()
	var pass_mask := PackedInt32Array()
	var movement_cost := PackedFloat32Array()
	var buildable := PackedByteArray()
	for array in [cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable]:
		array.resize(total)
	terrain.fill(MapNavigationGrid.TERRAIN_ROCK)
	pass_mask.fill(MapNavigationGrid.PASS_GROUND | MapNavigationGrid.PASS_AIR)
	movement_cost.fill(1.0)
	buildable.fill(1)
	var grid := MapNavigationGrid.new()
	grid.load_generated("ap9", AABB(Vector3.ZERO, Vector3(256.0,1.0,256.0)), 1.0,
		cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable, {}, {})
	return grid

func _whole_arm(orca_script, arc_script) -> Dictionary:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	if not navigation.setup(_make_grid()):
		return {"error": "navigation setup failed"}
	var wall := {}
	for x in range(116, 251):
		for z in range(116, 127):
			wall[Vector2i(x, z)] = true
	navigation.runtime_map.replace_blocked_cells(wall)
	var counter := CountingStabilizer.new()
	counter.setup(navigation.runtime_map)
	navigation.avoidance.stabilizer = counter
	navigation.avoidance.orca.set_script(orca_script)
	navigation.avoidance.orca.setup(navigation.runtime_map, counter)
	var allocator = arc_script.new()
	var units: Array[Node3D] = []
	for i in 16:
		var unit = NavigationTestScript.FakeUnit.new()
		root.add_child(unit)
		if not unit.is_inside_tree():
			return {"error": "unit did not enter the scene tree"}
		unit.global_position = Vector3(116.5 + float(i * 2), 0.0, 114.5)
		navigation.register_unit(unit)
		units.append(unit)
	var accepted: Array = navigation.command_move(units, Vector3(200.5, 0, 114.5))
	if accepted.size() != 16:
		return {"error": "only %d units accepted" % accepted.size()}
	for i in 20:
		navigation.call("_navigation_tick")
	var squad: Array[Node3D] = []
	for i in 6:
		squad.append(units[i])
	var arcs: Dictionary = allocator.assign_arcs(navigation._agents, squad, Vector3(200.5,0,114.5), 12.0)
	if arcs.size() != 6:
		return {"error": "arc assigned only %d units" % arcs.size()}
	var start_calls := counter.sector_calls
	var start_agents := counter.agent_ticks
	var start_hard := counter.hard_terrain_ticks
	var start := Time.get_ticks_usec()
	for i in 100:
		navigation.call("_navigation_tick")
		arcs = allocator.assign_arcs(navigation._agents, squad, Vector3(200.5,0,114.5), 12.0)
		if arcs.size() != 6:
			return {"error": "arc assignment disappeared"}
	var elapsed := Time.get_ticks_usec() - start
	var answer := {"us": float(elapsed) / 100.0,
		"sectors": float(counter.sector_calls - start_calls) / 100.0,
		"agents": float(counter.agent_ticks - start_agents) / 100.0,
		"hard": float(counter.hard_terrain_ticks - start_hard) / 100.0}
	navigation.free()
	for unit in units:
		unit.free()
	return answer

func _whole_tick_pairs(head_orca, head_arc, ds: float, dd: float, da: float) -> bool:
	var samples_h: Array[float] = []
	var samples_t: Array[float] = []
	var sector_counts: Array[float] = []
	var hard_counts: Array[float] = []
	var workload_ok := true
	for pair in 3:
		var h: Dictionary
		var t: Dictionary
		if pair % 2 == 0:
			h = _whole_arm(head_orca, head_arc)
			t = _whole_arm(OrcaTree, ArcTree)
		else:
			t = _whole_arm(OrcaTree, ArcTree)
			h = _whole_arm(head_orca, head_arc)
		if h.has("error") or t.has("error"):
			printerr("A7 whole fixture error HEAD %s tree %s" % [h, t])
			return false
		print("A7 whole pair %d HEAD %.3f tree %.3f us/tick; HEAD sectors %.1f agent-ticks %.1f hard %.1f; tree sectors %.1f agent-ticks %.1f hard %.1f" % [pair, h["us"], t["us"], h["sectors"], h["agents"], h["hard"], t["sectors"], t["agents"], t["hard"]])
		workload_ok = workload_ok and h["sectors"] >= 100.0 and h["agents"] >= 16.0 and h["hard"] > 0.0 \
			and t["sectors"] >= 100.0 and t["agents"] >= 16.0 and t["hard"] > 0.0
		samples_h.append(h["us"])
		samples_t.append(t["us"])
		sector_counts.append(t["sectors"])
		hard_counts.append(t["hard"])
	samples_h.sort()
	samples_t.sort()
	sector_counts.sort()
	hard_counts.sort()
	var span_h: float = samples_h[2] - samples_h[0]
	var span_t: float = samples_t[2] - samples_t[0]
	var added: float = samples_t[1] - samples_h[1]
	var s: float = maxf(40.0, sector_counts[1] / 16.0)
	var per_agent: float = (sector_counts[1] * ds + hard_counts[1] * dd + da) / 16.0
	print("A7 whole medians HEAD %.3f tree %.3f added %.3f us/tick spans %.3f/%.3f; added work per agent-tick %.3f us" % [samples_h[1], samples_t[1], added, span_h, span_t, per_agent])
	print("A7 measured S %.3f obstacles/agent, E200 %.3f us/tick" % [s, 200.0 * (s * ds + dd) + da])
	return workload_ok and added <= 1000.0 and span_h <= 500.0 and span_t <= 500.0 \
		and 200.0 * (s * ds + dd) + da <= 1000.0

func orca_tree_script_instance():
	return OrcaTree.new()

func _observed_sectors(path: String, terrain, agent: Dictionary) -> Array[int]:
	var source := FileAccess.get_file_as_string(path).replace("class_name OrcaAvoidance\n", "")
	var anchor := "if not nearest_per_sector.has(sector)"
	if source.count(anchor) != 1:
		return []
	source = source.replace("var runtime_map = null", "var sector_log: Array[int] = []\nvar runtime_map = null")
	source = source.replace(anchor, "sector_log.append(sector)\n\t\t\t" + anchor)
	var observer := GDScript.new()
	observer.source_code = source
	if observer.reload() != OK:
		return []
	var orca = observer.new()
	orca.setup(null, terrain)
	orca.resolve_velocity(agent.duplicate(), Vector3(1.2,0,0.4), 0.04, [], {})
	return orca.sector_log.duplicate()

func _arc_time(allocator, agents: Dictionary, units: Array[Node3D], count: int) -> float:
	var sink := 0.0
	var start := Time.get_ticks_usec()
	for i in count:
		var slots: Dictionary = allocator.assign_arcs(agents, units, Vector3(120.5,0,120.5), 12.0)
		sink += (slots[units[0].get_instance_id()] as Vector3).x
	if sink == INF:
		printerr("unreachable")
	return float(Time.get_ticks_usec() - start) / count

func _damp_head(previous_direction: Vector3, target_direction: Vector3, count: int) -> float:
	var sink := Vector3.ZERO
	var start := Time.get_ticks_usec()
	for i in count:
		var course_gap := previous_direction.normalized().signed_angle_to(target_direction, Vector3.UP)
		if absf(course_gap) > 0.005:
			var damped_direction := (previous_direction.normalized() as Vector3) \
				.rotated(Vector3.UP, course_gap * COURSE_DAMPING_SHARE)
			sink += damped_direction
	if sink.x == INF:
		printerr("unreachable")
	return float(Time.get_ticks_usec() - start) / count

func _damp_tree(previous_direction: Vector3, target_direction: Vector3, count: int) -> float:
	var sink := Vector3.ZERO
	var start := Time.get_ticks_usec()
	for i in count:
		var damped_direction := SimMathScript.damped_horizontal(previous_direction.normalized(), target_direction)
		if damped_direction != Vector3.ZERO:
			sink += damped_direction
	if sink.x == INF:
		printerr("unreachable")
	return float(Time.get_ticks_usec() - start) / count

func _orca_time(orca, agent: Dictionary, count: int) -> float:
	var start := Time.get_ticks_usec()
	for i in count:
		agent["avoidance_direction"] = Vector3.ZERO
		agent["orca_velocity"] = Vector3.ZERO
		orca.resolve_velocity(agent, Vector3(1.2,0,0.4), 0.04, [], {})
	return float(Time.get_ticks_usec() - start) / count
