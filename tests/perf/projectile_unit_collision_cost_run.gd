extends SceneTree

const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const ORAPCScene := preload("res://scenes/units/or_apc.tscn")
const UnitScript := preload("res://scripts/units/unit.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatLineOfFireScript := preload("res://scripts/combat/combat_line_of_fire.gd")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")

const CALLS := 500
const ROUNDS := 5

var _bullets := Bullets.new()
var _label := ""
var _mode := "public-calls"
var _skip_population := false
var _population := 200
var _shots := 2


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--label="):
			_label = arg.substr(8)
		elif arg.begins_with("--mode="):
			_mode = arg.substr(7)
		elif arg == "--skip-population":
			_skip_population = true
		elif arg.begins_with("--population="):
			_population = int(arg.substr(13))
		elif arg.begins_with("--shots="):
			_shots = int(arg.substr(8))
	LegacyRulesFixture.install(root)
	await process_frame
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=461"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var units_root := match_instance.get_node("Units")
	var atreides = ATAPCScene.instantiate()
	var ordos = ORAPCScene.instantiate()
	units_root.add_child(atreides)
	units_root.add_child(ordos)
	atreides.set_simulation_position(Vector3(600.0, 0.0, 500.0))
	ordos.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	match_instance.advance_ticks(1)
	match_instance.set("_unit_navigation_system", null)
	atreides.set("_simulation_halted", true)
	ordos.set("_simulation_halted", true)
	atreides.set_process(false)
	ordos.set_process(false)
	atreides.set_physics_process(false)
	ordos.set_physics_process(false)
	atreides.set_simulation_position(Vector3(600.0, 0.0, 500.0))
	ordos.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	if _mode == "population":
		_population_profile(match_instance)
		return
	if _mode == "match-ticks":
		_match_tick_profile(match_instance, atreides, ordos)
		return
	var spatial = match_instance.unit_spatial_index()
	var query_before := int(spatial.call("padded_query_count")) if spatial.has_method("padded_query_count") else -1
	var seed_count := int(spatial.call("full_seed_count")) if spatial.has_method("full_seed_count") else -1
	var height := 0.0 + (float(ordos.combat_line_bounds()["min_y"]) + float(ordos.combat_line_bounds()["max_y"])) * 0.5
	var graze_offset := _graze_offset(ordos, height)
	if graze_offset < 0.0:
		_fail("No Ordos physical graze fixture")
		return
	var near_offset := float(ordos.combat_line_bounds()["radius"]) + 1.1
	var arms := {
		"empty_direct": {"from": Vector3(0.0, 0.8, 500.0), "to": Vector3(8.0, 0.8, 500.0), "bullet": &"StraightBomb", "target": null, "expected": false},
		"ordos_direct": {"from": Vector3(500.0, height, 495.0), "to": Vector3(500.0, height, 505.0), "bullet": &"StraightBomb", "target": ordos, "expected": true},
		"atreides_direct": {"from": Vector3(600.0, 0.8, 495.0), "to": Vector3(600.0, 0.8, 505.0), "bullet": &"StraightBomb", "target": atreides, "expected": true},
		"empty_sonic": {"from": Vector3(0.0, 0.8, 500.0), "to": Vector3(8.0, 0.8, 500.0), "bullet": &"Sound_B", "target": null, "expected": false},
		"ordos_graze": {"from": Vector3(500.0 + graze_offset, height, 495.0), "to": Vector3(500.0 + graze_offset, height, 505.0), "bullet": &"Sound_B", "target": ordos, "expected": true},
		"ordos_halo_miss": {"from": Vector3(500.0 + near_offset, height, 495.0), "to": Vector3(500.0 + near_offset, height, 505.0), "bullet": &"Sound_B", "target": ordos, "expected": false},
	}
	var results := {}
	var candidates := 0
	var probes_before := int(ordos.projectile_hull_diagnostics()["probes"]) if ordos.has_method("projectile_hull_diagnostics") else -1
	var copies_before := int(ordos.projectile_hull_diagnostics()["copies"]) if ordos.has_method("projectile_hull_diagnostics") else -1
	for arm_name in arms:
		var arm: Dictionary = arms[arm_name]
		var from: Vector3 = arm["from"]
		var to: Vector3 = arm["to"]
		var bullet_id: StringName = arm["bullet"]
		var shot = CombatProjectileScript.new()
		match_instance.add_child(shot)
		if not shot.launch(_bullets.runtime_bullet(bullet_id), Bullets.emission(from, (to - from).normalized()), to):
			_fail("Launch failed for %s" % arm_name)
			return
		var sample: Array[Dictionary] = shot._collisions_between(from, to)
		var found := false
		for collision in sample:
			if collision.get("collider") == arm["target"]:
				found = true
		if found != bool(arm["expected"]):
			_fail("Hit precondition failed for %s: found=%s" % [arm_name, found])
			return
		var values: Array[float] = []
		for _round in ROUNDS:
			var start := Time.get_ticks_usec()
			for _call in CALLS:
				shot._collisions_between(from, to)
			values.append(float(Time.get_ticks_usec() - start) / float(CALLS))
		values.sort()
		results[arm_name] = {"median_us": values[2], "span_us": values[4] - values[0], "hit": found}
		if spatial.has_method("padded_query_count"):
			candidates += int(spatial.call("padded_query_count")) - query_before
			query_before = int(spatial.call("padded_query_count"))
		shot.free()
	var probes_after := int(ordos.projectile_hull_diagnostics()["probes"]) if probes_before >= 0 else -1
	var copies_after := int(ordos.projectile_hull_diagnostics()["copies"]) if copies_before >= 0 else -1
	var stages := {}
	if probes_before >= 0:
		var empty_arm: Dictionary = arms["empty_direct"]
		var empty_from: Vector3 = empty_arm["from"]
		var empty_to: Vector3 = empty_arm["to"]
		var stage_start := Time.get_ticks_usec()
		for _call in CALLS:
			spatial.padded_segment_candidates(empty_from, empty_to, 0.0)
		stages["empty_index_us"] = float(Time.get_ticks_usec() - stage_start) / float(CALLS)
		stage_start = Time.get_ticks_usec()
		for _call in CALLS:
			var ray := PhysicsRayQueryParameters3D.create(empty_from, empty_to, 2, [])
			ray.collide_with_areas = true
			ray.hit_from_inside = true
			ordos.get_world_3d().direct_space_state.intersect_ray(ray)
		stages["empty_physics_us"] = float(Time.get_ticks_usec() - stage_start) / float(CALLS)
		stage_start = Time.get_ticks_usec()
		for _call in CALLS:
			var temporary_hits: Array[Dictionary] = []
			var temporary_rids: Array[RID] = []
			var temporary_seen: Dictionary = {}
			var temporary_result := {"complete": true, "hits": temporary_hits}
			if temporary_rids.size() + temporary_seen.size() + temporary_result.size() < 0:
				_fail("Unreachable allocation sample")
		stages["empty_alloc_us"] = float(Time.get_ticks_usec() - stage_start) / float(CALLS)
		var direct_arm: Dictionary = arms["ordos_direct"]
		var direct_from: Vector3 = direct_arm["from"]
		var direct_to: Vector3 = direct_arm["to"]
		stage_start = Time.get_ticks_usec()
		for _call in CALLS:
			spatial.padded_segment_candidates(direct_from, direct_to, 0.0)
		stages["index_us"] = float(Time.get_ticks_usec() - stage_start) / float(CALLS)
		var registry = match_instance.entity_index().registry()
		var state = match_instance.entity_state()
		var direct_bullet = _bullets.runtime_bullet(&"StraightBomb")
		var id: int = match_instance.entity_index().id_for(ordos)
		stage_start = Time.get_ticks_usec()
		for _call in CALLS:
			var node = match_instance.entity_index().node_for(id)
			if registry.is_alive(id) and registry.kind_of(id) == 1 and state.has_position(id) \
			and node.is_in_group(&"sim_units") and match_instance.is_ancestor_of(node) \
			and not node.is_carried() and not node.get_meta("combat_ignore", false) \
			and direct_bullet.can_hit(node):
				pass
		stages["candidate_validation_us"] = float(Time.get_ticks_usec() - stage_start) / float(CALLS)
		stage_start = Time.get_ticks_usec()
		for _call in CALLS:
			ordos.projectile_hull_contact(direct_from, direct_to, ordos.simulation_position(), 0.0)
		stages["geometry_us"] = float(Time.get_ticks_usec() - stage_start) / float(CALLS)
		stage_start = Time.get_ticks_usec()
		for _call in CALLS:
			var ray := PhysicsRayQueryParameters3D.create(direct_from, direct_to, 2, [ordos.get_rid()])
			ordos.get_world_3d().direct_space_state.intersect_ray(ray)
		stages["physics_us"] = float(Time.get_ticks_usec() - stage_start) / float(CALLS)
	if copies_before >= 0 and copies_after != copies_before:
		_fail("Authored hull getter copied during timed calls")
		return
	if probes_before >= 0 and candidates < arms.size() * (CALLS * ROUNDS + 1):
		_fail("Tree collision call workload missing")
		return
	if probes_before >= 0 and probes_after <= probes_before:
		_fail("Tree did not probe the Ordos hull")
		return
	var output := {"label": _label, "mode": _mode, "calls_per_arm": CALLS * ROUNDS,
		"graze_offset": graze_offset, "halo_offset": near_offset, "results": results,
		"ap26_queries": candidates if probes_before >= 0 else -1,
		"ap26_seeds": seed_count, "ordos_probes": probes_after - probes_before if probes_before >= 0 else -1,
		"hull_copies": copies_after - copies_before if copies_before >= 0 else -1, "stages": stages}
	print("AO2_COST_RESULT ", JSON.stringify(output))
	if _skip_population:
		quit(0)
		return
	_population_profile(match_instance)


func _graze_offset(unit: Node3D, height: float) -> float:
	for step in 32:
		var offset := 0.5 + float(step) * 0.125
		var from := Vector3(500.0 + offset, height, 495.0)
		var to := Vector3(500.0 + offset, height, 505.0)
		var ray := PhysicsRayQueryParameters3D.create(from, to, 2)
		var old_ray: Dictionary = unit.get_world_3d().direct_space_state.intersect_ray(ray)
		if old_ray.get("collider") == unit:
			continue
		var shape := CapsuleShape3D.new()
		shape.radius = 1.4
		shape.height = 10.0
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape
		query.transform = Transform3D(Basis(Quaternion(Vector3.UP, Vector3.BACK)), (from + to) * 0.5)
		query.collision_mask = 2
		query.collide_with_bodies = true
		for hit in unit.get_world_3d().direct_space_state.intersect_shape(query, 64):
			if hit.get("collider") == unit:
				return offset
	return -1.0


func _population_profile(match_instance: Node) -> void:
	var index = match_instance.entity_index()
	var state = match_instance.entity_state()
	var spatial = match_instance.unit_spatial_index()
	var units_root := match_instance.get_node("Units")
	var dummies: Array[Node3D] = []
	var results := {}
	for population in [16, 50, 200, 1000]:
		while dummies.size() < population:
			var node := Node3D.new()
			units_root.add_child(node)
			node.add_to_group(&"sim_units")
			var id: int = index.register(node, 1)
			state.set_position(id, Vector3(100.0 + float(dummies.size()) * 8.0, 0.0, 500.0))
			state.set_combat_line_bounds(id, 0.2, -0.2, 0.2)
			dummies.append(node)
		spatial.sync()
		var arms := {}
		for bullet_id in [&"StraightBomb", &"Sound_B"]:
			var from := Vector3(0.0, 0.8, 500.0)
			var to := Vector3(8.0, 0.8, 500.0)
			var shot = CombatProjectileScript.new()
			match_instance.add_child(shot)
			if not shot.launch(_bullets.runtime_bullet(bullet_id), Bullets.emission(from, Vector3.RIGHT), to):
				_fail("Population launch failed")
				return
			if not shot._collisions_between(from, to).is_empty():
				_fail("Population zero-candidate precondition failed")
				return
			var samples: Array[float] = []
			var median := 0.0
			var mad := 0.0
			var attempts := 0
			for attempt in 2:
				attempts = attempt + 1
				samples.clear()
				for _round in ROUNDS:
					var start := Time.get_ticks_usec()
					for _call in CALLS:
						shot._collisions_between(from, to)
					samples.append(float(Time.get_ticks_usec() - start) / float(CALLS))
				samples.sort()
				median = samples[2]
				var deviations: Array[float] = []
				for sample in samples:
					deviations.append(absf(sample - median))
				deviations.sort()
				mad = deviations[2]
				if 1.4826 * mad <= 5.0:
					break
			arms[String(bullet_id)] = {"median_us": median, "mad_us": mad,
				"span_us": samples[4] - samples[0], "attempts": attempts,
				"noise_inconclusive": 1.4826 * mad > 5.0}
			shot.free()
		results[population] = arms
	var verdict := "PASS"
	var bounds := {}
	for bullet_id in ["StraightBomb", "Sound_B"]:
		var near: Dictionary = results[16][bullet_id]
		var far: Dictionary = results[1000][bullet_id]
		var bound: float = maxf(3.0 * 1.4826 * maxf(near["mad_us"], far["mad_us"]),
			maxf(1.0, 0.02 * near["median_us"]))
		var delta: float = absf(far["median_us"] - near["median_us"])
		bounds[bullet_id] = {"delta_us": delta, "bound_us": bound}
		for population in [16, 50, 200, 1000]:
			if results[population][bullet_id]["noise_inconclusive"]:
				verdict = "INCONCLUSIVE"
		if verdict != "INCONCLUSIVE" and delta > bound:
			verdict = "FAIL"
	print("AO2_POPULATION_RESULT ", JSON.stringify({"label": _label, "mode": _mode,
		"calls_per_arm": CALLS * ROUNDS, "populations": results, "flatness": bounds,
		"verdict": verdict,
		"ap26_queries": int(spatial.call("padded_query_count")) if spatial.has_method("padded_query_count") else -1,
		"ap26_seeds": int(spatial.call("full_seed_count")) if spatial.has_method("full_seed_count") else -1}))
	if verdict != "PASS":
		_fail("Population flatness " + verdict)
		return
	quit(0)


func _match_tick_profile(match_instance: Node, atreides: Node3D, ordos: Node3D) -> void:
	if _population not in [16, 200, 1000] or _shots not in [2, 32]:
		_fail("Invalid Match tick workload")
		return
	if _shots == 32 and _population != 200:
		_fail("32-shot mix requires 200 Units")
		return
	var units_root := match_instance.get_node("Units")
	var index = match_instance.entity_index()
	var store = match_instance.entity_state()
	var spatial = match_instance.unit_spatial_index()
	var needed := _population - 5 # Three scene Units plus the two APCs added above.
	for number in needed:
		var unit = UnitScript.new()
		unit.config_id = &"ATInfantry"
		units_root.add_child(unit)
		unit.set("_simulation_halted", true)
		unit.set_simulation_position(Vector3(100.0 + float(number) * 8.0, 0.0, 500.0))
		var id: int = index.id_for(unit)
		if id <= 0:
			_fail("Distant Unit was not registered")
			return
		store.set_combat_line_bounds(id, 0.25, -0.5, 0.5)
	match_instance.advance_ticks(1)
	spatial.sync()
	if not spatial.has_method("padded_query_count"):
		# The HEAD overlay lacks the AO2 diagnostics, as intended.
		pass
	elif int(spatial.call("full_seed_count")) != 1:
		_fail("AP26 was not preseeded exactly once")
		return
	var population_count := 0
	for node in get_nodes_in_group(&"sim_units"):
		if match_instance.is_ancestor_of(node):
			population_count += 1
	if population_count != _population:
		_fail("Admitted Unit population %d, wanted %d" % [population_count, _population])
		return
	var height := (float(ordos.combat_line_bounds()["min_y"]) + float(ordos.combat_line_bounds()["max_y"])) * 0.5
	ordos.max_health = 1000000.0
	ordos.health = 1000000.0
	atreides.max_health = 1000000.0
	atreides.health = 1000000.0
	var values: Array[float] = []
	var signatures: Array[String] = []
	var per_tick: Array[Dictionary] = []
	for round_index in 25:
		var shots: Array[Node] = []
		var deliveries := [0]
		if _shots == 2:
			shots.append(_launch_tick_shot(match_instance, &"HEAT_B", Vector3(600.0, height + 2.0, 494.0), atreides))
			shots.append(_launch_tick_shot(match_instance, &"Mortar_B", Vector3(10.0, 3.0, 500.0), Vector3(10.0, 0.0, 490.0)))
		else:
			for i in 16:
				shots.append(_launch_tick_shot(match_instance, &"StraightBomb", Vector3(float(i) * 0.05, 0.8, 500.0), Vector3(12.0, 0.8, 500.0)))
			for i in 8:
				shots.append(_launch_tick_shot(match_instance, &"StraightBomb", Vector3(500.0, height, 499.5 + float(i) * 0.01), Vector3(500.0, height, 505.0)))
			for i in 4:
				shots.append(_launch_tick_shot(match_instance, &"Sound_B", Vector3(25.0 + float(i), 0.8, 500.0), Vector3(33.0 + float(i), 0.8, 500.0)))
			for i in 4:
				var offset := 1.75 if i < 2 else 5.0
				shots.append(_launch_tick_shot(match_instance, &"Sound_B", Vector3(500.0 + offset, height, 499.6), Vector3(500.0 + offset, height, 507.6)))
		if shots.has(null):
			_fail("Flight shot failed to launch")
			return
		for shot in shots:
			shot.impacted.connect(func(_target: Object, _damage: float, _position: Vector3) -> void:
				deliveries[0] += 1)
		var warm_before := CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self)
		if warm_before:
			_fail("AO1 snapshot was warm before projectile-only tick")
			return
		var query_before := int(spatial.call("padded_query_count")) if spatial.has_method("padded_query_count") else -1
		var seed_before := int(spatial.call("full_seed_count")) if spatial.has_method("full_seed_count") else -1
		var bucket_before := int(spatial.call("bucket_writes")) if spatial.has_method("bucket_writes") else -1
		var probe_before := int(spatial.call("query_cell_probes")) if spatial.has_method("query_cell_probes") else -1
		var tick_before: int = match_instance.current_tick()
		var start := Time.get_ticks_usec()
		match_instance.advance_ticks(1)
		values.append(float(Time.get_ticks_usec() - start))
		if match_instance.current_tick() != tick_before + 1:
			_fail("Match did not advance the measured tick")
			return
		var finished := 0
		var hit := 0
		var advanced := 0
		for shot in shots:
			if shot.is_finished():
				finished += 1
			if shot.finish_reason == &"impact_target":
				hit += 1
			if shot.elapsed_seconds > 0.0:
				advanced += 1
		if advanced != _shots:
			_fail("Flight shot did not advance through Match")
			return
		var query_delta := int(spatial.call("padded_query_count")) - query_before if query_before >= 0 else -1
		if query_delta >= 0 and query_delta < _shots:
			_fail("AP26 query count did not rise for every shot")
			return
		if seed_before >= 0 and int(spatial.call("full_seed_count")) != seed_before:
			_fail("AP26 reseeded during a measured tick")
			return
		var warm_after := CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self)
		if warm_after:
			_fail("AO1 snapshot warmed during projectile-only tick")
			return
		var signature := "%d/%d/%d/%d" % [advanced, finished, hit, int(deliveries[0])]
		signatures.append(signature)
		per_tick.append({"shots": _shots, "query_delta": query_delta,
			"bucket_writes": int(spatial.call("bucket_writes")) - bucket_before if bucket_before >= 0 else -1,
			"cell_probes": int(spatial.call("query_cell_probes")) - probe_before if probe_before >= 0 else -1,
			"dirty": int(spatial.call("last_dirty_count")) if spatial.has_method("last_dirty_count") else -1,
			"finished": finished, "hit": hit, "deliveries": int(deliveries[0]), "warm": warm_after})
		for shot in shots:
			shot.free()
		ordos.health = 1000000.0
		atreides.health = 1000000.0
	values.sort()
	print("AO2_TICK_RESULT ", JSON.stringify({"label": _label, "population": _population,
		"shots": _shots, "median_us": values[12], "span_us": values[24] - values[0],
		"iqr_us": values[18] - values[6],
		"samples_us": values, "signatures": signatures, "per_tick": per_tick,
		"seed_count": int(spatial.call("full_seed_count")) if spatial.has_method("full_seed_count") else -1,
		"population_kind": "registered Unit script; distant Units have no visual model"}))
	quit(0)


func _launch_tick_shot(match_instance: Node, bullet_id: StringName, from: Vector3, target: Variant) -> Node:
	var shot = CombatProjectileScript.new()
	match_instance.add_child(shot)
	var aim: Vector3 = target.global_position if target is Node3D else target
	var heading := from.direction_to(aim)
	if not shot.launch(_bullets.runtime_bullet(bullet_id), Bullets.emission(from, heading), target):
		shot.free()
		return null
	return shot


func _fail(message: String) -> void:
	printerr("AO2 COST FAIL: ", message)
	quit(1)
