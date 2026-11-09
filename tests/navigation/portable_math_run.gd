extends "res://tests/support/suite.gd"
const AllocatorScript := preload("res://scripts/units/navigation/ground/attack_arc_allocator.gd")
const OrcaScript := preload("res://scripts/units/navigation/ground/orca_avoidance.gd")
const SimMathScript := preload("res://scripts/sim/sim_math.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")

class UnitDouble extends Node3D:
	var sim_pos := Vector3.ZERO
	func simulation_position() -> Vector3:
		return sim_pos

class TerrainDouble extends RefCounted:
	var obstacles: Array = []
	func terrain_context(_agent, _reach) -> Dictionary:
		return {"escape": false, "hard_radius": 0.5, "obstacles": obstacles}

func _initialize() -> void:
	var oracle_only := OS.get_cmdline_user_args().has("--oracle-only")
	_run_case("allocator against independent legacy arc", _arcs)
	if not oracle_only:
		_run_case("detached no-agent lookup is null-safe", _detached)
	_run_case("production ORCA six-sector observer", _sectors)
	_run_case("production ORCA hard-line course damping against legacy", _hard_line_damping)
	if not oracle_only:
		_run_case("damping axis antiparallel matches Godot", _damping)
		await _run_async_case("real Match entity-ID fallback", _registry_ids)
	_finish("Portable navigation math tests")

func _legacy_arcs(agents: Dictionary, units: Array[Node3D], target: Vector3, radius: float) -> Dictionary:
	var centroid := Vector3.ZERO
	for unit in units:
		centroid += unit.simulation_position()
	centroid /= float(units.size())
	var base := centroid - target
	base.y = 0.0
	base = base.normalized() if base.length_squared() > 0.0001 else Vector3.BACK
	var base_angle := atan2(base.z, base.x)
	var entries: Array[Dictionary] = []
	var widest := 0.35
	for i in units.size():
		var agent: Dictionary = agents.get(units[i].get_instance_id(), {})
		widest = maxf(widest, float(agent.get("radius", 0.35)))
		var offset: Vector3 = units[i].simulation_position() - target
		offset.y = 0.0
		var bearing := atan2(offset.z, offset.x) if offset.length_squared() > 0.0001 else base_angle
		entries.append({"unit": units[i], "offset": angle_difference(base_angle, bearing),
			"id": int(agent.get("id", units[i].get_instance_id()))})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["offset"]), float(b["offset"])):
			return int(a["id"]) < int(b["id"])
		return float(a["offset"]) < float(b["offset"])
	)
	var pitch := widest * 3.0
	var step := minf(pitch / maxf(radius, pitch), PI / 6.0)
	if units.size() > 1:
		step = minf(step, PI / float(units.size() - 1))
	var result := {}
	for i in entries.size():
		var angle := base_angle + (float(i) - float(entries.size() - 1) * 0.5) * step
		result[entries[i]["unit"].get_instance_id()] = Vector3(cos(angle), 0.0, sin(angle))
	return result

func _arcs() -> void:
	var cases := [
		{"points": [Vector3(-2,0,12), Vector3(-1,0,12), Vector3(0,0,12), Vector3(1,0,12), Vector3(2,0,12)], "radius": 12.0},
		{"points": [Vector3(12,0,-2), Vector3(12,0,0), Vector3(12,0,2)], "radius": 12.0},
		{"points": [Vector3(-12,0,-2), Vector3(-12,0,0), Vector3(-12,0,2)], "radius": 12.0},
		{"points": [Vector3(1,0,0), Vector3(0,0,1), Vector3(-1,0,0), Vector3(0,0,-1)], "radius": 12.0},
		{"points": [Vector3(8,0,-0.02), Vector3(8,0,0.02), Vector3(7,0,-0.01)], "radius": 12.0},
		{"points": [Vector3(-8,0,-0.02), Vector3(-8,0,0.02), Vector3(-7,0,-0.01)], "radius": 12.0},
		{"points": [Vector3(-2,0,-12), Vector3(0,0,-12), Vector3(2,0,-12)], "radius": 12.0},
		{"points": [Vector3(7,0,10), Vector3(8,0,10), Vector3(9,0,10)], "radius": 8.0,
			"radii": [0.35, 0.8, 0.5]},
		{"points": [Vector3(10,0,1.000001), Vector3(10,0,1.0), Vector3(10,0,1.0000005)],
			"radius": 12.0, "near_equal": true},
	]
	for count in [9, 12]:
		var points: Array[Vector3] = []
		for i in count:
			points.append(Vector3(float(i) - float(count - 1) * 0.5, 0.0, 1.0))
		cases.append({"points": points, "radius": 1.05})
	for case_index in cases.size():
		var units: Array[Node3D] = []
		var agents := {}
		for position in cases[case_index]["points"]:
			var unit := UnitDouble.new()
			unit.sim_pos = position
			units.append(unit)
			if cases[case_index].has("radii"):
				var i := units.size() - 1
				agents[unit.get_instance_id()] = {"id": i + 1, "radius": cases[case_index]["radii"][i]}
		var radius := float(cases[case_index]["radius"])
		var actual: Dictionary = AllocatorScript.new().assign_arcs(agents, units, Vector3.ZERO, radius)
		var expected := _legacy_arcs(agents, units, Vector3.ZERO, radius)
		var maximum := 0.0
		var order_mismatches := 0
		for unit in units:
			var id := unit.get_instance_id()
			var deviation: float = (actual[id] as Vector3).angle_to(expected[id])
			maximum = maxf(maximum, deviation)
			order_mismatches += int(deviation > 0.001)
			if OS.get_cmdline_user_args().has("--oracle-only"):
				_expect(actual[id] == expected[id], "HEAD allocator exact oracle case %d" % case_index)
		print("A2 case %d max slot deviation %.9f rad, order mismatches %d" % [case_index, maximum, order_mismatches])
		_expect(maximum <= 2e-4 or bool(cases[case_index].get("near_equal", false)),
			"allocator case %d matches legacy slots outside allowed near-equal tie" % case_index)
		for unit in units:
			unit.free()

func _detached() -> void:
	var unit := UnitDouble.new()
	unit.sim_pos = Vector3(1, 0, 0)
	_expect(MatchLookupScript.entity_index(unit) == null, "detached unit has no entity index")
	var units: Array[Node3D] = [unit]
	var result: Variant = AllocatorScript.new().assign_arcs({}, units, Vector3.ZERO, 12.0)
	_expect(typeof(result) == TYPE_DICTIONARY and result.has(unit.get_instance_id()),
		"detached no-agent unit gets a slot with no null-call error")
	unit.free()

func _sectors() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/units/navigation/ground/orca_avoidance.gd")
	var anchor := "if not nearest_per_sector.has(sector)"
	_expect(source.count(anchor) == 1, "one production sector insertion point")
	if source.count(anchor) != 1:
		return
	source = source.replace("class_name OrcaAvoidance\n", "")
	source = source.replace("var runtime_map = null", "var sector_log: Array[int] = []\nvar runtime_map = null")
	source = source.replace(anchor, "sector_log.append(sector)\n\t\t\t" + anchor)
	var script := GDScript.new()
	script.source_code = source
	var error := script.reload()
	_expect(error == OK, "in-memory observed production ORCA compiles")
	if error != OK:
		return
	var terrain := TerrainDouble.new()
	terrain.obstacles = [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)]
	var orca = script.new()
	orca.setup(null, terrain)
	var plain := OrcaScript.new()
	plain.setup(null, terrain)
	var unit := UnitDouble.new()
	var agent := {"unit": unit, "radius": 0.35, "orca_velocity": Vector3.ZERO}
	var plain_agent := agent.duplicate(true)
	var observed: Dictionary = orca.resolve_velocity(agent, Vector3(1,0,0), 0.04, [], {})
	var uninstrumented: Dictionary = plain.resolve_velocity(plain_agent, Vector3(1,0,0), 0.04, [], {})
	_expect(observed["velocity"] == uninstrumented["velocity"],
		"in-memory sector observer preserves uninstrumented velocity")
	print("A4 observed sectors %s, sector mismatches %d" % [orca.sector_log, 0 if orca.sector_log == [0,3,1] else 1])
	_expect(orca.sector_log == [0, 3, 1], "axis sector ownership")
	var vectors := [
		Vector2(1, 0.3), Vector2(0.2, 1), Vector2(-1, 0.3),
		Vector2(-1, -0.3), Vector2(-0.2, -1), Vector2(1, -0.3),
		Vector2(0.5, 0.8660254), Vector2(0.5, -0.8660254),
		Vector2(1, 1.7320508), Vector2.ZERO,
		Vector2(1, 2), Vector2(-2, 1), Vector2(-3, -2), Vector2(4, -1),
	]
	for boundary in range(-3, 3):
		for side in [-1.0, 1.0]:
			var angle: float = float(boundary) * PI / 3.0 + float(side) * 0.0002
			vectors.append(Vector2(cos(angle), sin(angle)))
	terrain.obstacles.clear()
	for vector in vectors:
		terrain.obstacles.append(Vector3(vector.x, 0, vector.y))
	orca.sector_log.clear()
	agent["avoidance_direction"] = Vector3.ZERO
	plain_agent = agent.duplicate(true)
	observed = orca.resolve_velocity(agent, Vector3(1,0,0), 0.04, [], {})
	uninstrumented = plain.resolve_velocity(plain_agent, Vector3(1,0,0), 0.04, [], {})
	_expect(observed["velocity"] == uninstrumented["velocity"],
		"in-memory mixed-sector observer preserves uninstrumented velocity")
	var mismatches := 0
	for index in vectors.size():
		var legacy := int(floor((vectors[index] as Vector2).angle() / (PI / 3.0)))
		if orca.sector_log[index] != legacy:
			mismatches += 1
		if index < 6 or index >= 10:
			_expect(orca.sector_log[index] == legacy, "non-boundary sector %d matches legacy" % index)
	print("A4 mixed sector mismatches %d (including nominal boundary band)" % mismatches)
	if OS.get_cmdline_user_args().has("--oracle-only"):
		_expect(mismatches == 0, "HEAD observed sectors exactly match copied legacy oracle")
	else:
		_expect(orca.sector_log.slice(6, 9) == [0, -1, 0],
			"three nominal 60-degree vectors have pinned tree ownership")
		_expect(mismatches == 3, "tree sectors differ at exactly three pinned nominal boundaries")
	unit.free()

func _damping() -> void:
	var pairs := [
		[Vector3.RIGHT, Vector3.LEFT], [Vector3.LEFT, Vector3.RIGHT],
		[Vector3.BACK, Vector3.FORWARD], [Vector3.FORWARD, Vector3.BACK],
	]
	var maximum := 0.0
	for index in pairs.size():
		var pair: Array = pairs[index]
		var previous: Vector3 = pair[0]
		var target: Vector3 = pair[1]
		var gap := previous.signed_angle_to(target, Vector3.UP)
		var expected := previous.rotated(Vector3.UP, gap * 0.35)
		var actual: Vector3 = SimMathScript.damped_horizontal(previous, target)
		var deviation := actual.angle_to(expected)
		maximum = maxf(maximum, deviation)
		print("A4 antiparallel pair %d damped deviation %.9f rad" % [index, deviation])
		_expect(deviation <= 2e-4, "axis antiparallel pair %d matches legacy" % index)
	print("A4 antiparallel max damped deviation %.9f rad" % maximum)
	_expect(maximum <= 2e-4, "four axis antiparallel pairs match legacy")
	for small_gap in [0.003, 0.008, -0.008]:
		var previous := Vector3.RIGHT
		var target := Vector3(cos(small_gap), 0.0, sin(small_gap)).normalized()
		var legacy_gap := previous.signed_angle_to(target, Vector3.UP)
		var expected := previous.rotated(Vector3.UP, legacy_gap * 0.35) \
			if absf(legacy_gap) > 0.005 else previous
		var actual: Vector3 = SimMathScript.damped_horizontal(previous, target)
		_expect(actual.angle_to(expected) <= 2e-4,
			"damping threshold control %.3f rad" % small_gap)
	var near_opposite_mismatches := 0
	for i in 100:
		var angle := 0.123 + float(i) * TAU / 100.0
		var previous := Vector3(cos(angle), 0.0, sin(angle)).normalized()
		var target := -previous
		var legacy_gap := previous.signed_angle_to(target, Vector3.UP)
		var expected := previous.rotated(Vector3.UP, legacy_gap * 0.35)
		var actual: Vector3 = SimMathScript.damped_horizontal(previous, target)
		near_opposite_mismatches += int(actual.angle_to(expected) > 2e-4)
	print("A4 non-axis negated-heading mismatches %d/100 (reported tie band)" % near_opposite_mismatches)

func _hard_line_damping() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/units/navigation/ground/orca_avoidance.gd")
	var anchor := "if not hard_lines.is_empty() and result.length() > 0.01:"
	_expect(source.count(anchor) == 1, "one production damping observation point")
	if source.count(anchor) != 1:
		return
	source = source.replace("class_name OrcaAvoidance\n", "")
	source = source.replace("var runtime_map = null",
		"var observed_raw := Vector2.ZERO\nvar observed_hard: Array[Dictionary] = []\nvar runtime_map = null")
	source = source.replace(anchor, "observed_raw = result\n\tobserved_hard = hard_lines.duplicate(true)\n\t" + anchor)
	var script := GDScript.new()
	script.source_code = source
	var error := script.reload()
	_expect(error == OK, "in-memory damping observer compiles")
	if error != OK:
		return
	var terrain := TerrainDouble.new()
	var orca = script.new()
	orca.setup(null, terrain)
	var plain := OrcaScript.new()
	plain.setup(null, terrain)
	var unit := UnitDouble.new()
	var agent := {"unit": unit, "radius": 0.35, "orca_velocity": Vector3.ZERO,
		"avoidance_direction": Vector3.ZERO, "blocked_time": 0.0, "_squeeze_cooldown": 0}
	var accepted_pos := 0
	var accepted_neg := 0
	var rejected := 0
	var maximum := 0.0
	var maximum_speed := 0.0
	for obstacle in [Vector3(0.8,0,0.2), Vector3(0.8,0,-0.2), Vector3(0.2,0,0.8), Vector3(-0.2,0,0.8)]:
		terrain.obstacles = [obstacle]
		for desired in [Vector3(1,0,0), Vector3(1,0,0.4), Vector3(0.4,0,1)]:
			var route := Vector2(desired.x, desired.z).normalized()
			for angle in [-0.8, -0.5, -0.2, 0.2, 0.5, 0.8]:
				var previous := Vector3(cos(angle), 0, sin(angle))
				if Vector2(previous.x, previous.z).dot(route) <= 0.0:
					continue
				agent["avoidance_direction"] = previous
				agent["orca_velocity"] = Vector3.ZERO
				var plain_agent := agent.duplicate(true)
				var observed: Dictionary = orca.resolve_velocity(agent, desired, 0.04, [], {})
				var uninstrumented: Dictionary = plain.resolve_velocity(plain_agent, desired, 0.04, [], {})
				_expect(observed["velocity"] == uninstrumented["velocity"],
					"in-memory damping observer preserves uninstrumented velocity")
				var raw: Vector2 = orca.observed_raw
				var hard: Array = orca.observed_hard
				if hard.is_empty() or raw.length() <= 0.01:
					continue
				var target := Vector3(raw.x, 0, raw.y).normalized()
				var gap := previous.normalized().signed_angle_to(target, Vector3.UP)
				if absf(gap) <= 0.005:
					continue
				var legacy_direction := previous.normalized().rotated(Vector3.UP, gap * 0.35)
				var damped := Vector2(legacy_direction.x, legacy_direction.z) * raw.length()
				var blocked := damped.dot(route) < 0.0
				for line in hard:
					if OrcaScript._violates(line, damped):
						blocked = true
				var expected := raw if blocked else damped
				if expected.normalized().dot(route) < 0.0:
					expected = Vector2.ZERO
				var actual: Vector3 = observed["velocity"]
				var actual_flat := Vector2(actual.x, actual.z)
				maximum_speed = maxf(maximum_speed, absf(actual_flat.length() - expected.length()))
				if not actual_flat.is_zero_approx() and not expected.is_zero_approx():
					maximum = maxf(maximum, absf(actual_flat.angle_to(expected)))
				elif actual_flat.is_zero_approx() != expected.is_zero_approx():
					maximum = PI
				if blocked:
					rejected += 1
				elif gap > 0.0:
					accepted_pos += 1
				else:
					accepted_neg += 1
	print("A4 hard-line damping accepted +/− %d/%d, rejected %d, max direction deviation %.9f rad, max speed %.9f" % [accepted_pos, accepted_neg, rejected, maximum, maximum_speed])
	_expect(accepted_pos > 0 and accepted_neg > 0 and rejected > 0,
		"positive controls include both turn signs and a hard-line veto")
	_expect(maximum <= 2e-4 and maximum_speed <= 2e-4,
		"production ORCA matches independent legacy hard-line damping")
	unit.free()

func _registry_ids() -> void:
	LegacyRulesFixture.install(root)
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	await process_frame
	var parent := match_instance.get_node("Units")
	var first := match_instance.get_node("Units/ScoutA").duplicate() as Node3D
	var second := match_instance.get_node("Units/ScoutA").duplicate() as Node3D
	parent.add_child(second)
	parent.add_child(first)
	await process_frame
	first.set_simulation_position(Vector3(10,0,0))
	second.set_simulation_position(Vector3(10,0,0))
	var index = match_instance.entity_index()
	var id_first: int = index.id_for(first)
	var id_second: int = index.id_for(second)
	_expect(first.get_instance_id() < second.get_instance_id() and id_second < id_first and id_second > 0,
		"creation order opposes positive registry admission order")
	var units: Array[Node3D] = [first, second]
	var slots: Dictionary = AllocatorScript.new().assign_arcs({}, units, Vector3.ZERO, 12.0)
	var first_angle := atan2((slots[first.get_instance_id()] as Vector3).z, (slots[first.get_instance_id()] as Vector3).x)
	var second_angle := atan2((slots[second.get_instance_id()] as Vector3).z, (slots[second.get_instance_id()] as Vector3).x)
	_expect(second_angle < first_angle, "lower entity ID takes lower slot regardless of instance ID")
	units.reverse()
	slots = AllocatorScript.new().assign_arcs({}, units, Vector3.ZERO, 12.0)
	first_angle = atan2((slots[first.get_instance_id()] as Vector3).z, (slots[first.get_instance_id()] as Vector3).x)
	second_angle = atan2((slots[second.get_instance_id()] as Vector3).z, (slots[second.get_instance_id()] as Vector3).x)
	_expect(second_angle < first_angle, "lower entity ID keeps lower slot after input reversal")
	match_instance.queue_free()
	await process_frame
