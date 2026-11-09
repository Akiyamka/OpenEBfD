extends SceneTree

const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const ATBarracksScene := preload("res://scenes/buildings/at_barracks.tscn")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const ResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const BulletsScript := preload("res://tests/combat/support/combat_bullets.gd")
const OracleScript := preload("res://tests/combat/support/splash_physics_oracle.gd")

const WARM_CALLS := 200
const TIMED_CALLS := 1000
const PAIRS := 7

var _bullets := BulletsScript.new()
var _failed := false


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	var head_script: Script = load("/ao3_head/ao3_head_resolver.gd")
	_check(head_script != null and head_script.resource_path == "/ao3_head/ao3_head_resolver.gd",
		"absolute mounted HEAD resolver loads")
	if _failed:
		quit(1)
		return
	var head = head_script.new()
	var tree = ResolverScript.new()
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var centre := Vector3(500.0, 0.8, 500.0)
	var bullet = _bullets.runtime_bullet(&"Mortar_B")
	_check(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"settled HEAD oracle hits APC")
	_check(not OracleScript.hits(match_instance.get_world_3d(), centre + Vector3(30, 0, 0), 4.0, unit),
		"settled HEAD oracle misses distant APC")
	_check(match_instance.unit_spatial_index().rectangle_candidates(Vector2(496, 496),
		Vector2(504, 504)).has(unit.entity_id), "tree index admits one local APC")
	_reset_health(unit)
	var probes_before: int = unit.projectile_hull_diagnostics()["probes"]
	var tree_hit: Array[Dictionary] = tree.resolve(bullet, match_instance, centre)
	_check(tree_hit.size() == 1 and tree_hit[0]["target"] == unit, "tree public hit")
	_check(unit.projectile_hull_diagnostics()["probes"] - probes_before == 1,
		"exactly one APC hull probe per tree call")
	_reset_health(unit)
	var head_hit: Array[Dictionary] = head.resolve(bullet, match_instance, centre)
	_check(head_hit.size() == 1 and head_hit[0]["target"] == unit, "HEAD public hit")
	if _failed:
		match_instance.free()
		quit(1)
		return
	var ratios: Array[float] = []
	var head_costs: Array[float] = []
	var tree_costs: Array[float] = []
	for pair in PAIRS:
		var first = head if pair % 2 == 0 else tree
		var second = tree if pair % 2 == 0 else head
		var first_cost: float = _time_arm(first, match_instance, unit, bullet, centre, true)
		var second_cost: float = _time_arm(second, match_instance, unit, bullet, centre, true)
		var head_cost: float = first_cost if pair % 2 == 0 else second_cost
		var tree_cost: float = second_cost if pair % 2 == 0 else first_cost
		head_costs.append(head_cost)
		tree_costs.append(tree_cost)
		ratios.append(tree_cost / head_cost)
		print("AO3 one APC pair %d: HEAD %.3f tree %.3f ratio %.3f" % [pair + 1,
			head_cost, tree_cost, ratios[-1]])
	var passing := 0
	for ratio in ratios:
		if ratio <= 1.8:
			passing += 1
	print("AO3 one APC vote: %d/7 within 1.8" % passing)
	var ratio_status := _vote_status(passing)
	print("AO3 one APC status: " + ratio_status)
	var zero_centre := Vector3(530.0, 0.8, 500.0)
	var zero_deltas: Array[float] = []
	for pair in PAIRS:
		var first = head if pair % 2 == 0 else tree
		var second = tree if pair % 2 == 0 else head
		var first_cost: float = _time_arm(first, match_instance, unit, bullet, zero_centre, false)
		var second_cost: float = _time_arm(second, match_instance, unit, bullet, zero_centre, false)
		zero_deltas.append((second_cost - first_cost) if pair % 2 == 0 else (first_cost - second_cost))
		print("AO3 empty pair %d: added %.3f us" % [pair + 1, zero_deltas[-1]])
	var zero_passing := 0
	for delta in zero_deltas:
		if delta < 20.0:
			zero_passing += 1
	print("AO3 empty vote: %d/7 below 20 us" % zero_passing)
	var empty_status := _vote_status(zero_passing)
	print("AO3 empty status: " + empty_status)
	_reset_health(unit)
	var fifty_head_start := Time.get_ticks_usec()
	var fifty_head_hits := 0
	for _i in 50:
		fifty_head_hits += head.resolve(bullet, match_instance, centre, null, null, 1.0).size()
	var fifty_head_us := Time.get_ticks_usec() - fifty_head_start
	_check(fifty_head_hits == 50 and unit.health < 1000000.0, "HEAD 50 impacts and health loss")
	_reset_health(unit)
	var fifty_tree_start := Time.get_ticks_usec()
	var fifty_tree_hits := 0
	for _i in 50:
		fifty_tree_hits += tree.resolve(bullet, match_instance, centre, null, null, 1.0).size()
	var fifty_tree_us := Time.get_ticks_usec() - fifty_tree_start
	_check(fifty_tree_hits == 50 and unit.health < 1000000.0, "tree 50 impacts and health loss")
	var added: Array[float] = []
	for i in PAIRS:
		added.append(tree_costs[i] - head_costs[i])
	print("AO3 50 impacts report only: HEAD %d us tree %d us; 50 x median paired added %.1f us" % [
		fifty_head_us, fifty_tree_us, 50.0 * _median(added)])
	_component_cost(match_instance, unit, centre)
	match_instance.free()
	await physics_frame
	await physics_frame
	_check(get_nodes_in_group(&"sim_units").is_empty(), "paired fixture removed before slope")
	if not _failed:
		await _extra_arms(head, tree, bullet, centre)
	var slope_status := "ERROR"
	if not _failed:
		slope_status = await _population_slope(head, tree, bullet, centre)
	if _failed or slope_status == "ERROR":
		quit(2)
		return
	print("AO3 gate set ratio=%s empty=%s slope=%s" % [ratio_status, empty_status, slope_status])
	quit(0 if ratio_status == "PASS" and empty_status == "PASS" and slope_status == "PASS" else 3)


func _vote_status(passing: int) -> String:
	if passing >= 5:
		return "PASS"
	return "FAIL" if PAIRS - passing >= 5 else "INCONCLUSIVE"


func _reset_health(unit: Node) -> void:
	unit.max_health = 1000000.0
	unit.health = 1000000.0


func _time_arm(resolver: Object, match_instance: Node, unit: Node, bullet: Object,
		centre: Vector3, expected_hit: bool) -> float:
	_reset_health(unit)
	var warm_hits := 0
	for _i in WARM_CALLS:
		var results: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
		warm_hits += results.size()
	_check(warm_hits == (WARM_CALLS if expected_hit else 0), "warm hit count")
	_reset_health(unit)
	var timed_hits := 0
	var started := Time.get_ticks_usec()
	for _i in TIMED_CALLS:
		var results: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
		timed_hits += results.size()
	var elapsed := Time.get_ticks_usec() - started
	_check(timed_hits == (TIMED_CALLS if expected_hit else 0), "timed hit count")
	if expected_hit:
		_check(unit.health < 1000000.0, "timed health loss is visible at 1e6 HP")
	else:
		_check(unit.health == 1000000.0, "empty arm does not damage APC")
	return float(elapsed) / TIMED_CALLS


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("AO3 cost precondition/ceiling failed: ", message)


func _component_cost(match_instance: Node, unit: Node, centre: Vector3) -> void:
	var spatial = match_instance.unit_spatial_index()
	var state = match_instance.entity_state()
	var started := Time.get_ticks_usec()
	for _i in TIMED_CALLS:
		spatial.rectangle_candidates(Vector2(centre.x - 4.0, centre.z - 4.0),
			Vector2(centre.x + 4.0, centre.z + 4.0))
	var rectangle_us := float(Time.get_ticks_usec() - started) / TIMED_CALLS
	started = Time.get_ticks_usec()
	for _i in TIMED_CALLS:
		unit.projectile_hull_contact(centre - Vector3.UP * 4.0,
			centre + Vector3.UP * 4.0, state.position(unit.entity_id), 4.0)
	var hull_us := float(Time.get_ticks_usec() - started) / TIMED_CALLS
	started = Time.get_ticks_usec()
	for _i in TIMED_CALLS:
		OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit)
	var physics_us := float(Time.get_ticks_usec() - started) / TIMED_CALLS
	print("AO3 components report only: rectangle %.3f hull %.3f old-physics oracle %.3f us/call" % [
		rectangle_us, hull_us, physics_us])


func _extra_arms(head: Object, tree: Object, bullet: Object, centre: Vector3) -> void:
	for arm in ["Building", "cube", "eight local APCs"]:
		var match_instance = MatchFixtureScene.instantiate()
		root.add_child(match_instance)
		match_instance.set_process(false)
		for mound in get_nodes_in_group(&"spice_mounds"):
			if match_instance.is_ancestor_of(mound):
				mound.free()
		match_instance.terrain.spice_layer = null
		for existing in match_instance.get_node("Units").get_children():
			existing.free()
		var targets: Array[Node] = []
		var arm_centre := centre
		if arm == "Building":
			var building = ATBarracksScene.instantiate()
			building.owner_player_id = 2
			building.position = centre - Vector3.UP * 0.8
			match_instance.get_node("Buildings").add_child(building)
			building.set_process(false)
			targets.append(building)
		elif arm == "cube":
			var cube = UnitScript.new()
			cube.config_id = &"ATAPC"
			cube.owner_player_id = 2
			cube.add_to_group(&"units")
			var visual := Node3D.new()
			visual.name = "VisualRoot"
			cube.add_child(visual)
			var source := Node3D.new()
			source.name = "CubeSource"
			source.set_meta("original_name", "slctCube")
			var points := PackedVector3Array()
			for x in [-0.6, 0.6]:
				for y in [-0.6, 0.6]:
					for z in [-0.6, 0.6]:
						points.append(Vector3(x, y, z))
			source.set_meta("collision_points", points)
			visual.add_child(source)
			match_instance.get_node("Units").add_child(cube)
			cube.set("_simulation_halted", true)
			cube.set_process(false)
			cube.set_simulation_position(centre - Vector3.UP * 0.8)
			targets.append(cube)
		else:
			for i in 8:
				var unit = ATAPCScene.instantiate()
				unit.owner_player_id = 2
				match_instance.get_node("Units").add_child(unit)
				unit.set("_simulation_halted", true)
				unit.set_process(false)
				unit.set_simulation_position(centre - Vector3.UP * 0.8 \
					+ Vector3(float(i % 4) - 1.5, 0.0, float(i / 4) - 0.5))
				targets.append(unit)
		match_instance.advance_ticks(1)
		await physics_frame
		await physics_frame
		if arm == "Building":
			arm_centre = targets[0].combat_aim_position()
		for target in targets:
			_check(OracleScript.hits(match_instance.get_world_3d(), arm_centre, 4.0, target),
				"settled HEAD oracle positively hits " + arm)
			_check(not OracleScript.hits(match_instance.get_world_3d(), arm_centre + Vector3(30, 0, 0),
				4.0, target), "settled HEAD oracle misses distant " + arm)
		var expected := targets.size()
		var head_pre: Array[Dictionary] = head.resolve(bullet, match_instance, arm_centre)
		var tree_pre: Array[Dictionary] = tree.resolve(bullet, match_instance, arm_centre)
		_check(head_pre.size() == expected and tree_pre.size() == expected,
			arm + " HEAD/tree result parity")
		if _failed:
			match_instance.free()
			await physics_frame
			await physics_frame
			return
		var head_costs: Array[float] = []
		var tree_costs: Array[float] = []
		for pair in PAIRS:
			var head_first := pair % 2 == 0
			var first = head if head_first else tree
			var second = tree if head_first else head
			var first_cost: float = _time_extra(first, match_instance, targets, bullet, arm_centre)
			var second_cost: float = _time_extra(second, match_instance, targets, bullet, arm_centre)
			head_costs.append(first_cost if head_first else second_cost)
			tree_costs.append(second_cost if head_first else first_cost)
			print("AO3 %s pair %d: HEAD %.3f tree %.3f us/call" % [
				arm, pair + 1, head_costs[-1], tree_costs[-1]])
		print("AO3 %s medians: HEAD %.3f tree %.3f; spans HEAD %.3f tree %.3f us/call" % [
			arm, _median(head_costs), _median(tree_costs),
			head_costs.max() - head_costs.min(), tree_costs.max() - tree_costs.min()])
		match_instance.free()
		await physics_frame
		await physics_frame
		_check(get_nodes_in_group(&"sim_units").is_empty(), arm + " fixture removed")
		if _failed:
			return


func _time_extra(resolver: Object, match_instance: Node, targets: Array[Node],
		bullet: Object, centre: Vector3) -> float:
	for target in targets:
		_reset_extra(target)
	var warm_hits := 0
	for _i in WARM_CALLS:
		warm_hits += resolver.resolve(bullet, match_instance, centre).size()
	_check(warm_hits == WARM_CALLS * targets.size(), "extra arm warm hit count")
	for target in targets:
		_reset_extra(target)
	var timed_hits := 0
	var started := Time.get_ticks_usec()
	for _i in TIMED_CALLS:
		timed_hits += resolver.resolve(bullet, match_instance, centre).size()
	var elapsed := Time.get_ticks_usec() - started
	_check(timed_hits == TIMED_CALLS * targets.size(), "extra arm timed hit count")
	for target in targets:
		_check(target.health < 1000000.0 if "health" in target else target.damage_taken > 0.0,
			"extra arm damage visible")
	return float(elapsed) / TIMED_CALLS


func _reset_extra(target: Node) -> void:
	if "health" in target and "max_health" in target:
		target.max_health = 1000000.0
		target.health = 1000000.0
		if "shields" in target:
			target.shields = 0.0
	else:
		target.damage_taken = 0.0


func _population_slope(head: Object, tree: Object, bullet: Object, centre: Vector3) -> String:
	var populations := [16, 50, 200, 1000]
	var head_samples: Dictionary = {16: [], 50: [], 200: [], 1000: []}
	var tree_samples: Dictionary = {16: [], 50: [], 200: [], 1000: []}
	var added_samples: Dictionary = {16: [], 50: [], 200: [], 1000: []}
	for sweep in 7:
		for offset in 4:
			var population: int = populations[(sweep + offset) % 4]
			print("AO3 slope sweep %d/7 population %d: setup" % [sweep + 1, population])
			var match_instance = MatchFixtureScene.instantiate()
			root.add_child(match_instance)
			match_instance.set_process(false)
			for mound in get_nodes_in_group(&"spice_mounds"):
				if match_instance.is_ancestor_of(mound):
					mound.free()
			match_instance.terrain.spice_layer = null
			for existing in match_instance.get_node("Units").get_children():
				existing.free()
			var local: Node = null
			for i in population:
				var unit = ATAPCScene.instantiate()
				unit.owner_player_id = 2
				match_instance.get_node("Units").add_child(unit)
				unit.set("_simulation_halted", true)
				unit.set_process(false)
				unit.set_simulation_position(centre - Vector3.UP * 0.8 \
					if i == 0 else Vector3(700.0 + i * 4.0, 0.0, 700.0))
				if i == 0:
					local = unit
			match_instance.advance_ticks(1)
			await physics_frame
			await physics_frame
			_check(get_nodes_in_group(&"sim_units").size() == population,
				"entire SceneTree has exact slope population")
			var ids: PackedInt32Array = match_instance.unit_spatial_index().rectangle_candidates(
				Vector2(centre.x - 4.0, centre.z - 4.0),
				Vector2(centre.x + 4.0, centre.z + 4.0))
			_check(ids.size() == 1 and ids[0] == local.entity_id, "one local slope candidate")
			_check(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, local),
				"settled HEAD population oracle hits local APC")
			var head_first := (sweep + offset) % 2 == 0
			var first = head if head_first else tree
			var second = tree if head_first else head
			var first_cost: float = _time_arm(first, match_instance, local, bullet, centre, true)
			var second_cost: float = _time_arm(second, match_instance, local, bullet, centre, true)
			var head_cost: float = first_cost if head_first else second_cost
			var tree_cost: float = second_cost if head_first else first_cost
			head_samples[population].append(head_cost)
			tree_samples[population].append(tree_cost)
			added_samples[population].append(tree_cost - head_cost)
			print("AO3 slope sweep %d/7 population %d: HEAD %.3f tree %.3f added %.3f us/call" % [
				sweep + 1, population, head_cost, tree_cost, tree_cost - head_cost])
			match_instance.free()
			await physics_frame
			await physics_frame
			_check(get_nodes_in_group(&"sim_units").is_empty(), "slope fixture fully removed")
			if _failed:
				return "ERROR"
	var head_summary := _slope_summary(head_samples, populations, "HEAD")
	var tree_summary := _slope_summary(tree_samples, populations, "tree")
	var added_summary := _slope_summary(added_samples, populations, "tree-minus-HEAD")
	print("AO3 control slopes: HEAD %.3f tree %.3f added %.3f us/call (16 to 1000)" % [
		head_summary["end_slope"], tree_summary["end_slope"], added_summary["end_slope"]])
	var slope_status := "PASS" if added_summary["spread"] <= added_summary["tolerance"] else "FAIL"
	print("AO3 tree-minus-HEAD slope status: " + slope_status)
	return slope_status


func _slope_summary(samples: Dictionary, populations: Array, label: String) -> Dictionary:
	var medians: Array[float] = []
	var max_mad := 0.0
	for population in populations:
		var values: Array[float] = []
		for value in samples[population]:
			values.append(float(value))
		var middle := _median(values)
		medians.append(middle)
		var deviations: Array[float] = []
		for value in values:
			deviations.append(absf(value - middle))
		max_mad = maxf(max_mad, _median(deviations))
	print("AO3 %s slope medians 16/50/200/1000: %s max MAD %.3f" % [
		label, medians, max_mad])
	var spread: float = medians.max() - medians.min()
	var floor_us := 10.0 if label == "tree-minus-HEAD" else 1.0
	var tolerance: float = maxf(3.0 * max_mad, maxf(floor_us, 0.05 * absf(_median(medians))))
	print("AO3 %s MAD convention: unscaled median absolute deviation about the median" % label)
	print("AO3 %s slope spread %.3f tolerance %.3f" % [label, spread, tolerance])
	return {"spread": spread, "tolerance": tolerance,
		"end_slope": medians[-1] - medians[0]}


func _median(values: Array[float]) -> float:
	var ordered := values.duplicate()
	ordered.sort()
	var middle := int(ordered.size() / 2)
	return (ordered[middle - 1] + ordered[middle]) * 0.5 if ordered.size() % 2 == 0 \
		else ordered[middle]
