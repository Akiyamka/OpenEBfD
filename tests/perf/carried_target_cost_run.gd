extends SceneTree

const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const APCScene := preload("res://scenes/units/atapc.tscn")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const BulletScript := preload("res://scripts/combat/combat_bullet.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const TreeCollision := preload("res://scripts/combat/projectile_unit_collision.gd")
const TreeSplash := preload("res://scripts/combat/splash_unit_collision.gd")
const ResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")

var _match: Node
var _cargo: Array = []
var _carriers: Array = []
var _bullet
var _direct_bullet
var _mortar_bullet
var _head_collision
var _head_splash
var _set := "warm"
var _mutation := ""
var _failed := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--set="):
			_set = arg.substr(6)
		elif arg.begins_with("--mutation="):
			_mutation = arg.substr(11)
	LegacyRulesFixture.install(root)
	await process_frame
	_head_collision = load("/ap13_head/projectile_unit_collision.gd")
	_head_splash = load("/ap13_head/splash_unit_collision.gd")
	if _head_collision == null or _head_splash == null:
		_fail("HEAD helpers missing")
		return
	_match = MatchFixtureScene.instantiate()
	root.add_child(_match)
	_match.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if _match.is_ancestor_of(mound):
			mound.free()
	_match.terrain.spice_layer = null
	var config: Resource = Bullets.new().bullet_config(&"Sound_B").duplicate(true)
	config.anti_aircraft = true
	config.anti_ground = true
	_bullet = BulletScript.new(config, Bullets.new().warhead_config(config.warhead_id))
	_direct_bullet = _make_bullet(&"StraightBomb")
	_mortar_bullet = _make_bullet(&"Mortar_B")
	_match.advance_ticks(1)
	for i in 20:
		var carrier := APCScene.instantiate() as Unit
		var cargo := APCScene.instantiate() as Unit
		carrier.owner_player_id = 1
		cargo.owner_player_id = 2
		_match.get_node("Units").add_child(carrier)
		_match.get_node("Units").add_child(cargo)
		carrier.set_process(false)
		cargo.set_process(false)
		carrier.set("_simulation_halted", true)
		cargo.set("_simulation_halted", true)
		carrier.set_meta("combat_ignore", true)
		carrier.set_simulation_position(Vector3(500.0, 40.0, 500.4))
		cargo.set_simulation_position(Vector3(510.0 + i, 40.0, 500.4))
		_match.advance_ticks(1)
		carrier.transport_attach_cargo(cargo, Vector3.ZERO)
		_carriers.append(carrier)
		_cargo.append(cargo)
	_match.advance_ticks(1)
	for carrier in _carriers:
		carrier.global_basis = Basis.IDENTITY
		carrier.set_simulation_position(Vector3(500.0, 40.0, 500.4))
	for cargo in _cargo:
		cargo.combat_geometry().sync_carried()
	_match.unit_spatial_index().sync()
	await physics_frame
	await physics_frame
	await process_frame
	var arrangements := [
		["centre", _bullet, Vector3(0.0, 0.8, 0.0), Vector3(0.0, 0.8, 0.8), 1.4, 20],
		["sonic_graze", _bullet, Vector3(1.54, 0.8, 0.0), Vector3(1.54, 0.8, 0.8), 1.4, 20],
		["sonic_near", _bullet, Vector3(1.56, 0.8, 0.0), Vector3(1.56, 0.8, 0.8), 1.4, 0],
		["direct_near", _direct_bullet, Vector3(1.16, 0.8, -5.0), Vector3(1.16, 0.8, 5.0), 0.0, 0],
	]
	var results: Dictionary = {}
	for arrangement in arrangements:
		var label: String = arrangement[0]
		var bullet = arrangement[1]
		var from: Vector3 = Vector3(500.0, 0.0, 500.0) + arrangement[2]
		var to: Vector3 = Vector3(500.0, 0.0, 500.0) + arrangement[3]
		var radius: float = arrangement[4]
		var expected: int = arrangement[5]
		var candidates: PackedInt32Array = _match.unit_spatial_index().padded_segment_candidates(from, to, 0.4)
		for cargo in _cargo:
			if not candidates.has(cargo.entity_id) or not bullet.can_hit(cargo):
				_fail("%s missing an eligible indexed cargo" % label)
				return
		var tree_hits: int = _query(TreeCollision, bullet, from, to, radius, label)
		var head_hits: int = _query(_head_collision, bullet, from, to, radius, label)
		if tree_hits != expected or head_hits != expected:
			_fail("%s controls tree=%d HEAD=%d expected=%d" % [label, tree_hits, head_hits, expected])
			return
		var pairs: Array = []
		for pair in 7:
			_batch(_head_collision, bullet, from, to, radius, label, expected)
			_batch(TreeCollision, bullet, from, to, radius, label, expected)
			var head_us := 0.0
			var tree_us := 0.0
			if pair % 2 == 0:
				head_us = _time_batch(_head_collision, bullet, from, to, radius, label, expected)
				tree_us = _time_batch(TreeCollision, bullet, from, to, radius, label, expected)
			else:
				tree_us = _time_batch(TreeCollision, bullet, from, to, radius, label, expected)
				head_us = _time_batch(_head_collision, bullet, from, to, radius, label, expected)
			pairs.append({"head_us": head_us, "tree_us": tree_us, "added_us": tree_us - head_us})
		results[label] = {"eligible_probes": 640, "head_hits": head_hits,
			"tree_hits": tree_hits, "expected_hits": expected, "pairs": pairs}
	print("AP13_STRESS_RESULT ", JSON.stringify({"set": _set, "cargo": 20, "shots": 32,
		"arrangements": results}))
	await _measure_realistic()
	if _failed:
		return
	quit(0)


func _make_bullet(id: StringName):
	var config: Resource = Bullets.new().bullet_config(id).duplicate(true)
	config.anti_aircraft = true
	config.anti_ground = true
	return BulletScript.new(config, Bullets.new().warhead_config(config.warhead_id))


func _measure_realistic() -> void:
	var spatial = _match.unit_spatial_index()
	var pass_observations: Array[float] = []
	var pass_only: Array[float] = []
	var sync_only: Array[float] = []
	var sequence := 0
	for observation in 7:
		var pass_samples: Array[float] = []
		var sync_samples: Array[float] = []
		var combined: Array[float] = []
		for sample in (1 if _mutation == "single_pass" else 200):
			sequence += 1
			for i in 20:
				var carrier := _carriers[i] as Unit
				carrier.global_basis = Basis.IDENTITY
				carrier.set_simulation_position(Vector3(200.0 + i * 8.0 + sequence * 0.01, 0.0, 200.0))
			if _mutation != "no_flush":
				spatial.sync()
			if _mutation != "no_flush" and spatial.last_dirty_count() != 20:
				_fail("carrier dirty flush counted %d rather than 20" % spatial.last_dirty_count())
				return
			var previous: Vector3 = _cargo[0].simulation_position()
			var start := Time.get_ticks_usec()
			for cargo in get_nodes_in_group(&"sim_carried_units"):
				if _match.is_ancestor_of(cargo):
					if _mutation != "skip_pass":
						cargo.combat_geometry().sync_carried()
					if _mutation == "pass_delay":
						_busy_delay(100)
			var pass_us := float(Time.get_ticks_usec() - start)
			start = Time.get_ticks_usec()
			spatial.sync()
			var sync_us := float(Time.get_ticks_usec() - start)
			if spatial.last_dirty_count() != 20 or _cargo[0].simulation_position().is_equal_approx(previous):
				_fail("cargo pass timed dirty=%d (expected 20), first root moved=%s" %
					[spatial.last_dirty_count(), not _cargo[0].simulation_position().is_equal_approx(previous)])
				return
			pass_samples.append(pass_us)
			sync_samples.append(sync_us)
			combined.append(pass_us + sync_us)
		if combined.size() < 200:
			_fail("pass observation has fewer than 200 timed samples")
			return
		pass_samples.sort()
		sync_samples.sort()
		combined.sort()
		pass_only.append(pass_samples[100])
		sync_only.append(sync_samples[100])
		pass_observations.append(combined[100])
	await physics_frame
	await physics_frame
	await process_frame
	var aim_reads := 0
	for shot in 32:
		var target := _cargo[shot % 20] as Unit
		var origin: Vector3 = target.simulation_position()
		var from_graze := origin + Vector3(1.54, 0.8, -0.4)
		var to_graze := origin + Vector3(1.54, 0.8, 0.4)
		var candidate_ids: PackedInt32Array = spatial.padded_segment_candidates(from_graze, to_graze, 0.4)
		var eligible := 0
		for candidate in _cargo:
			if candidate_ids.has(candidate.entity_id) and _bullet.can_hit(candidate):
				eligible += 1
		if eligible != 1 or not candidate_ids.has(target.entity_id) \
		or target.projectile_hull_contact(from_graze, to_graze, origin, 0.4).is_empty():
			_fail("realistic shot %d does not have one graze candidate" % shot)
			return
		target.combat_aim_position()
		aim_reads += 1
	var fixed_deltas := {"sonic_hit": [3.0], "graze_130": [34.0],
		"graze_142": [34.0], "graze_154": [34.0], "sonic_near": [18.0]}
	var fixed_max := _sonic_max_delta(fixed_deltas, 0)
	if fixed_max != 34.0 or 32.0 * fixed_max != 1088.0:
		_fail("Sonic graze estimator self-check got %.1f/%.1f, expected 34/1088" %
			[fixed_max, 32.0 * fixed_max])
		return
	var cargo := _cargo[0] as Unit
	var root_position: Vector3 = cargo.simulation_position()
	var arms: Dictionary = {}
	var cases := [
		["direct_hit", Vector3(0.0, 0.8, -5.0), Vector3(0.0, 0.8, 5.0), 0.0, _direct_bullet],
		["direct_near", Vector3(1.16, 0.8, -5.0), Vector3(1.16, 0.8, 5.0), 0.0, _direct_bullet],
		["sonic_hit", Vector3(0.0, 0.8, -0.4), Vector3(0.0, 0.8, 0.4), 1.4, _bullet],
		["graze_130", Vector3(1.30, 0.8, -0.4), Vector3(1.30, 0.8, 0.4), 1.4, _bullet],
		["graze_142", Vector3(1.42, 0.8, -0.4), Vector3(1.42, 0.8, 0.4), 1.4, _bullet],
		["graze_154", Vector3(1.54, 0.8, -0.4), Vector3(1.54, 0.8, 0.4), 1.4, _bullet],
		["sonic_near", Vector3(1.56, 0.8, -0.4), Vector3(1.56, 0.8, 0.4), 1.4, _bullet],
	]
	for arm in cases:
		var label: String = arm[0]
		var from: Vector3 = root_position + arm[1]
		var to: Vector3 = root_position + arm[2]
		var radius: float = arm[3]
		var bullet = arm[4]
		var head_fn := func(): return _query_case(_head_collision, bullet, from, to, radius)
		var tree_fn := func(): return _query_tree_case(label, bullet, from, to, radius)
		var head_out: int = head_fn.call()
		var tree_out: int = tree_fn.call()
		var expected_hit := 0 if label.ends_with("near") else 1
		if head_out != tree_out or tree_out != expected_hit:
			_fail("%s HEAD/tree outcome differs: %d/%d" % [label, head_out, tree_out])
			return
		if label.begins_with("graze_"):
			if not cargo.projectile_hull_contact(from, to, root_position, 0.0).is_empty() \
			or cargo.projectile_hull_contact(from, to, root_position, 0.4).is_empty():
				_fail("%s centreline miss/capsule hit precondition failed" % label)
				return
		if _mutation != "omit_graze" or label != "graze_154":
			arms[label] = _paired_timings(head_fn, tree_fn)
	if not arms.has("graze_154"):
		_fail("Sonic graze arm missing from cost estimator")
		return
	var resolver := ResolverScript.new()
	for splash_case in [["splash_hit", Vector3.ZERO], ["splash_gatefail", Vector3(3.5, 0.0, 3.5)]]:
		var label: String = splash_case[0]
		var centre: Vector3 = root_position + splash_case[1] + Vector3.UP * 0.8
		var head_fn := func(): return _splash_case(_head_splash, resolver, centre)
		var tree_fn := func(): return _splash_tree_case(resolver, centre)
		var head_out: int = head_fn.call()
		var tree_out: int = tree_fn.call()
		if head_out != tree_out or tree_out != (1 if label == "splash_hit" else 0):
			_fail("%s HEAD/tree outcome differs: %d/%d" % [label, head_out, tree_out])
			return
		arms[label] = _paired_timings(head_fn, tree_fn)
	var centre_local: Vector3 = cargo.combat_geometry().get("_aim_centre")
	var head_aim := func(): return cargo.simulation_position() + cargo.global_basis * centre_local
	var tree_aim := func(): return _aim_tree(cargo)
	arms["aim"] = _paired_timings(head_aim, tree_aim)
	var e1: Array[float] = []
	var deltas: Dictionary = {}
	for label in arms:
		deltas[label] = []
		for timing in arms[label]:
			deltas[label].append(timing["tree_us"] - timing["head_us"])
	for i in 7:
		var direct_delta: float = maxf(deltas["direct_hit"][i], deltas["direct_near"][i])
		var sonic_delta: float = _sonic_max_delta(deltas, i)
		var splash_delta: float = maxf(deltas["splash_hit"][i], deltas["splash_gatefail"][i])
		e1.append(pass_observations[i] + 32.0 * maxf(0.0, maxf(direct_delta, sonic_delta))
			+ 10.0 * maxf(0.0, splash_delta) + float(maxi(aim_reads, 100)) * maxf(0.0, deltas["aim"][i]))
	print("AP13_REALISTIC_RESULT ", JSON.stringify({"set": _set, "samples_per_pass_observation": 200,
		"calls_per_arm_per_pair": 2000, "aim_calls": aim_reads, "pass_us": pass_only, "sync_us": sync_only,
		"pass_sync_us": pass_observations, "arms": arms, "e1_us": e1}))
	if _mutation == "" or _mutation == "scan":
		_measure_population(cases, root_position, resolver)


func _sonic_max_delta(deltas: Dictionary, index: int) -> float:
	var result: float = maxf(deltas["sonic_hit"][index], deltas["sonic_near"][index])
	if _mutation == "omit_graze_max":
		return result
	for label in ["graze_130", "graze_142", "graze_154"]:
		result = maxf(result, deltas[label][index])
	return result


func _query_tree_case(label: String, bullet, from: Vector3, to: Vector3, radius: float) -> int:
	var count := _query_case(TreeCollision, bullet, from, to, radius)
	if _mutation == "scan":
		for node in get_nodes_in_group(&"sim_units"):
			if node == null:
				break
	if _mutation == "direct_delay" and label.begins_with("direct_") \
	or _mutation == "graze_delay" and label == "graze_154":
		_busy_delay(100)
	return count


func _splash_tree_case(resolver, centre: Vector3) -> int:
	var count := _splash_case(TreeSplash, resolver, centre)
	if _mutation == "scan":
		for node in get_nodes_in_group(&"sim_units"):
			if node == null:
				break
	if _mutation == "splash_delay":
		_busy_delay(100)
	return count


func _aim_tree(cargo: Unit) -> Vector3:
	var result := cargo.combat_aim_position()
	if _mutation == "aim_delay":
		_busy_delay(100)
	return result


func _busy_delay(microseconds: int) -> void:
	var deadline := Time.get_ticks_usec() + microseconds
	while Time.get_ticks_usec() < deadline:
		pass


func _measure_population(cases: Array, root_position: Vector3, resolver) -> void:
	var dummies: Array[Node3D] = []
	var results: Dictionary = {}
	var index = _match.entity_index()
	var state = _match.entity_state()
	for population in [16, 50, 200, 1000]:
		while dummies.size() < population:
			var node := Node3D.new()
			_match.get_node("Units").add_child(node)
			node.add_to_group(&"sim_units")
			var id: int = index.register(node, 1)
			state.set_position(id, Vector3(1000.0 + dummies.size() * 8.0, 0.0, 1000.0))
			state.set_combat_line_bounds(id, 0.2, -0.2, 0.2)
			dummies.append(node)
		_match.unit_spatial_index().sync()
		var population_arms: Dictionary = {}
		for arm in cases:
			var label: String = arm[0]
			var from: Vector3 = root_position + arm[1]
			var to: Vector3 = root_position + arm[2]
			var radius: float = arm[3]
			var bullet = arm[4]
			var head_fn := func(): return _query_case(_head_collision, bullet, from, to, radius)
			var tree_fn := func(): return _query_tree_case(label, bullet, from, to, radius)
			if head_fn.call() != tree_fn.call():
				_fail("population %d %s outcome mismatch" % [population, label])
				return
			population_arms[label] = _paired_timings(head_fn, tree_fn)
		for splash_case in [["splash_hit", Vector3.ZERO], ["splash_gatefail", Vector3(3.5, 0.0, 3.5)]]:
			var label: String = splash_case[0]
			var centre: Vector3 = root_position + splash_case[1] + Vector3.UP * 0.8
			var head_fn := func(): return _splash_case(_head_splash, resolver, centre)
			var tree_fn := func(): return _splash_tree_case(resolver, centre)
			if head_fn.call() != tree_fn.call():
				_fail("population %d %s outcome mismatch" % [population, label])
				return
			population_arms[label] = _paired_timings(head_fn, tree_fn)
		results[str(population)] = population_arms
	print("AP13_POPULATION_RESULT ", JSON.stringify({"set": _set, "results": results}))


func _query_case(collision, bullet, from: Vector3, to: Vector3, radius: float) -> int:
	var excludes: Array[RID] = []
	var hits: Array[Dictionary] = []
	collision.collect(_match, _match, _match.entity_index(), _match.entity_state(),
		_match.unit_spatial_index(), from, to, radius, bullet, null, excludes,
		CombatRulesScript.COLLISION_MASK, hits)
	var count := 0
	for hit in hits:
		if hit.get("collider") == _cargo[0]:
			count += 1
	return count


func _splash_case(collision, resolver, centre: Vector3) -> int:
	var result: Dictionary = collision.collect(_match, _match, _match.entity_index(),
		_match.entity_state(), _match.unit_spatial_index(), centre, 4.0, _mortar_bullet,
		null, null, Callable(resolver, "_surface_distance"), CombatRulesScript.COLLISION_MASK)
	if not result["ok"]:
		return -1
	var count := 0
	for entry in result["entries"]:
		if entry["target"] == _cargo[0]:
			count += 1
	return count


func _paired_timings(head_fn: Callable, tree_fn: Callable) -> Array[Dictionary]:
	var values: Array[Dictionary] = []
	for pair in 7:
		var head_us := 0.0
		var tree_us := 0.0
		if pair % 2 == 0:
			head_us = _time_calls(head_fn)
			tree_us = _time_calls(tree_fn)
		else:
			tree_us = _time_calls(tree_fn)
			head_us = _time_calls(head_fn)
		values.append({"head_us": head_us, "tree_us": tree_us})
	return values


func _time_calls(fn: Callable) -> float:
	for warm in 200:
		fn.call()
	var start := Time.get_ticks_usec()
	for call_index in 2000:
		fn.call()
	return float(Time.get_ticks_usec() - start) / 2000.0


func _query(collision, bullet, from: Vector3, to: Vector3, radius: float, label: String) -> int:
	var excludes: Array[RID] = []
	var hits: Array[Dictionary] = []
	collision.collect(_match, _match, _match.entity_index(), _match.entity_state(),
		_match.unit_spatial_index(), from, to, radius, bullet, null, excludes,
		CombatRulesScript.COLLISION_MASK, hits)
	var cargo_hits := 0
	for hit in hits:
		if hit.get("collider") in _cargo:
			cargo_hits += 1
	if collision == TreeCollision and _mutation == "stress_delay" and label == "sonic_graze":
		_busy_delay(1000)
	return cargo_hits


func _batch(collision, bullet, from: Vector3, to: Vector3, radius: float, label: String, expected: int) -> void:
	for shot in 32:
		var count := _query(collision, bullet, from, to, radius, label)
		if count != expected:
			_fail("%s shot %d produced %d hits, expected %d" % [label, shot, count, expected])
			return


func _time_batch(collision, bullet, from: Vector3, to: Vector3, radius: float, label: String, expected: int) -> float:
	var start := Time.get_ticks_usec()
	for repeat in 5:
		_batch(collision, bullet, from, to, radius, label, expected)
	return float(Time.get_ticks_usec() - start) / 5.0


func _fail(message: String) -> void:
	_failed = true
	push_error("AP13 cost: " + message)
	quit(1)
