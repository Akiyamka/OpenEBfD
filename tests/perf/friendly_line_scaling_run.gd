extends SceneTree

const CombatLineOfFireScript := preload("res://scripts/combat/combat_line_of_fire.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")

const SIZES := [16, 50, 200, 1000]
const BATCHES := 5
const CALLS_PER_BATCH := 5000
const WARM_CALLS := 15000


class MatchStub extends Node:
	var state
	var index
	var tick := 1

	func _init(match_state, match_index) -> void:
		state = match_state
		index = match_index

	func current_tick() -> int:
		return tick

	func entity_state():
		return state

	func entity_index():
		return index


func _initialize() -> void:
	if "--combat-cost" in OS.get_cmdline_user_args():
		await _measure_combat_cost()
		return
	var measurement := await _measure_set()
	if not bool(measurement["ok"]):
		quit(1)
		return
	if float(measurement["noise"]) > 5.0:
		print("AO1 friendly-line scaling: repeating after noisy first set")
		measurement = await _measure_set()
		if not bool(measurement["ok"]):
			quit(1)
			return
	var noise: float = measurement["noise"]
	var medians: Array[float] = measurement["medians"]
	var slope := _least_squares_slope(SIZES, medians)
	var median_of_medians := _median(medians)
	# The 2% relative floor admits benign cache-footprint variation at 1000
	# bodies while retaining the absolute/noise limits for a genuine slope.
	var tolerance := maxf(maxf(noise, 1.0), 0.02 * median_of_medians)
	var spread: float = medians.max() - medians.min()
	var slope_cost := maxf(slope, 0.0) * float(SIZES[SIZES.size() - 1] - SIZES[0])
	# A large monotonic rise is a real per-unit slope even if the host also
	# supplied noisy batches. Keep INCONCLUSIVE for ambiguous noisy sets.
	var monotonic := true
	for index in range(1, medians.size()):
		if medians[index] < medians[index - 1]:
			monotonic = false
	var clear_slope := monotonic and spread > maxf(3.0 * tolerance, 0.1 * medians.min())
	if noise > 5.0 and not clear_slope:
		push_error("AO1 friendly-line scaling: INCONCLUSIVE after repeat (noise %.3f us/call)" % noise)
		quit(1)
		return
	if slope_cost > tolerance or spread > tolerance:
		push_error("AO1 friendly-line scaling: FAIL slope=%.3f spread=%.3f tolerance=%.3f" % [slope_cost, spread, tolerance])
		quit(1)
		return
	print("AO1 friendly-line scaling: PASS slope=%.3f spread=%.3f noise=%.3f tolerance=%.3f" % [slope_cost, spread, noise, tolerance])
	quit()


func _measure_combat_cost() -> void:
	for size in [16, 200]:
		var fixture := await _build_fixture(size)
		if not bool(fixture["ok"]):
			_dispose_fixture(fixture)
			quit(1)
			return
		var key_samples: Array[float] = []
		var call_samples: Array[float] = []
		var world_root: Node3D = fixture["world_root"]
		var shooter: Node3D = fixture["shooter"]
		var endpoint: Vector3 = fixture["endpoint"]
		var match_node: Node = world_root.get_child(0)
		for _batch in 9:
			CombatLineOfFireScript._ensure_match_snapshot(self, match_node)
			var started := Time.get_ticks_usec()
			for _call in 5000:
				CombatLineOfFireScript._ensure_match_snapshot(self, match_node)
			key_samples.append(float(Time.get_ticks_usec() - started) / 5000.0)
			started = Time.get_ticks_usec()
			for _call in 5000:
				if not CombatLineOfFireScript.friendly_on_line(
					world_root.get_world_3d(), shooter.global_position, endpoint, shooter, [shooter]
				):
					push_error("combat cost %d: warm AO1 verdict changed" % size)
					_dispose_fixture(fixture)
					quit(1)
					return
			call_samples.append(float(Time.get_ticks_usec() - started) / 5000.0)
		key_samples.sort()
		call_samples.sort()
		print("combat_cost_json: %s" % JSON.stringify({
			"size": size,
			"key_us": key_samples[4], "key_range_us": [key_samples[0], key_samples[8]],
			"call_us": call_samples[4], "call_range_us": [call_samples[0], call_samples[8]],
			"local_ids": fixture["local_ids"],
		}))
		_dispose_fixture(fixture)
		await process_frame
	quit(0)


func _measure_set() -> Dictionary:
	var samples: Array = [[], [], [], []]
	var diagnostics: Array = [{}, {}, {}, {}]
	var round_spreads: Array[float] = []
	for round_index in BATCHES:
		var round_values: Array[float] = []
		for offset in SIZES.size():
			var size_index := (round_index + offset) % SIZES.size()
			var fixture := await _build_fixture(SIZES[size_index])
			if not bool(fixture["ok"]):
				_dispose_fixture(fixture)
				return {"ok": false}
			var batch := _time_batch(fixture)
			var fixture_diagnostics := {
				"bucket_writes": fixture["bucket_writes"],
				"query_cell_probes": fixture["query_cell_probes"],
				"local_ids": fixture["local_ids"],
			}
			_dispose_fixture(fixture)
			await process_frame
			if not bool(batch["ok"]):
				return {"ok": false}
			var batch_usec: float = batch["usec"]
			(samples[size_index] as Array).append(batch_usec)
			if round_index == 0:
				diagnostics[size_index] = fixture_diagnostics
			round_values.append(batch_usec)
		round_spreads.append(round_values.max() - round_values.min())
	var noise := 0.0
	# Remove common round-to-round frequency drift before estimating noise.
	# Cross-size spread is the effect the gate is meant to detect.
	var round_means: Array[float] = []
	for round_index in BATCHES:
		var sum := 0.0
		for size_index in SIZES.size():
			sum += float((samples[size_index] as Array)[round_index])
		round_means.append(sum / float(SIZES.size()))
	for size_index in SIZES.size():
		var adjusted: Array[float] = []
		for round_index in BATCHES:
			adjusted.append(float((samples[size_index] as Array)[round_index]) - round_means[round_index])
		var adjusted_median := _median(adjusted)
		var deviations: Array[float] = []
		for value in adjusted:
			deviations.append(absf(value - adjusted_median))
		# Three scaled MADs bound ordinary jitter without letting one bad
		# batch decide the entire gate.
		noise = maxf(noise, 3.0 * 1.4826 * _median(deviations))
	var medians: Array[float] = []
	for size_index in SIZES.size():
		var batches: Array = samples[size_index]
		var fixture_diagnostics: Dictionary = diagnostics[size_index]
		var result := {
			"ok": true,
			"size": SIZES[size_index],
			"batches_usec": batches,
			"median_usec": _median(batches),
			"range_usec": batches.max() - batches.min(),
			"bucket_writes": fixture_diagnostics["bucket_writes"],
			"query_cell_probes": fixture_diagnostics["query_cell_probes"],
			"local_ids": fixture_diagnostics["local_ids"],
		}
		medians.append(float(result["median_usec"]))
		print("json:       %s" % JSON.stringify(result))
	return {
		"ok": true,
		"medians": medians,
		"noise": noise,
		"round_spreads_usec": round_spreads,
	}


func _build_fixture(size: int) -> Dictionary:
	var world_root := Node3D.new()
	root.add_child(world_root)
	var index = EntityNodeIndexScript.new()
	var state = SimEntityStateScript.new(index.registry())
	var match_stub := MatchStub.new(state, index)
	world_root.add_child(match_stub)
	match_stub.add_to_group(MatchLookupScript.GROUP)
	var shooter: Node3D = _add_unit(world_root, index, state, Vector3.ZERO, 1, false)
	var enemy: Node3D = _add_unit(world_root, index, state, Vector3(6.0, 0.0, 0.1), 2, false)
	var blocked_friend: Node3D = _add_unit(world_root, index, state, Vector3(18.0, 0.0, 0.0), 1, false)
	var carried: Node3D = _add_unit(world_root, index, state, Vector3(8.0, 0.0, 0.0), 1, true)
	carried.carried = true
	var building := Doubles.PhysicsBuildingBlocker.new(Vector3(12.0, 0.0, 0.0), 0.5)
	world_root.add_child(building)
	for offset in range(size - 4):
		var distant: Node3D = _add_unit(
			world_root, index, state, Vector3(100.0 + float(offset % 32) * 3.0, 0.0, 100.0 + float(offset / 32) * 3.0), 2, false
		)
		distant.set_meta("ao1_distant", true)
	await physics_frame
	var endpoint := Vector3(20.0, 0.0, 0.0)
	# First call builds the grid. The two normal local ids are enemy/friend;
	# shooter is deliberately present in the grid but ignored by the predicate.
	var warm := CombatLineOfFireScript.friendly_on_line(
		world_root.get_world_3d(), shooter.global_position, endpoint, shooter, [shooter]
	)
	if not warm:
		push_error("AO1 scaling %d: carried friendly must answer true" % size)
		world_root.queue_free()
		return {"ok": false, "world_root": world_root}
	var local_ids := _local_ids(shooter, enemy, blocked_friend, endpoint)
	if local_ids != PackedInt32Array([int(enemy.get_meta("id")), int(blocked_friend.get_meta("id"))]):
		push_error("AO1 scaling %d: expected exactly two local normal ids, got %s" % [size, local_ids])
		world_root.queue_free()
		return {"ok": false, "world_root": world_root}
	# Let the host settle after grid construction before taking the five timed
	# batches. This is deliberately outside the measurement, like cache warmup.
	for _warm in WARM_CALLS:
		if not CombatLineOfFireScript.friendly_on_line(
			world_root.get_world_3d(), shooter.global_position, endpoint, shooter, [shooter]
		):
			push_error("AO1 scaling %d: burn-in carried verdict changed" % size)
			world_root.queue_free()
			return {"ok": false, "world_root": world_root}
	var grid = CombatLineOfFireScript.debug_grid_for_test()
	return {
		"ok": true,
		"size": size,
		"bucket_writes": grid.bucket_writes(),
		"query_cell_probes": grid.query_cell_probes(),
		"local_ids": local_ids,
		"batches_usec": [],
		"world_root": world_root,
		"shooter": shooter,
		"endpoint": endpoint,
	}


func _time_batch(fixture: Dictionary) -> Dictionary:
	var world_root: Node3D = fixture["world_root"]
	var shooter: Node3D = fixture["shooter"]
	var endpoint: Vector3 = fixture["endpoint"]
	# Switching fixtures switches the singleton Match snapshot. Rebuild it here,
	# outside the measurement, so each timed batch is a warmed whole call.
	if not CombatLineOfFireScript.friendly_on_line(
		world_root.get_world_3d(), shooter.global_position, endpoint, shooter, [shooter]
	):
		push_error("AO1 scaling %d: pre-batch carried verdict changed" % int(fixture["size"]))
		return {"ok": false}
	var started := Time.get_ticks_usec()
	for _call in CALLS_PER_BATCH:
		if not CombatLineOfFireScript.friendly_on_line(
			world_root.get_world_3d(), shooter.global_position, endpoint, shooter, [shooter]
		):
			push_error("AO1 scaling %d: warmed carried verdict changed" % int(fixture["size"]))
			return {"ok": false}
	return {"ok": true, "usec": float(Time.get_ticks_usec() - started) / float(CALLS_PER_BATCH)}


func _dispose_fixture(fixture: Dictionary) -> void:
	var world_root := fixture.get("world_root") as Node
	if world_root != null and is_instance_valid(world_root):
		world_root.queue_free()


func _add_unit(parent: Node3D, index, state, position: Vector3, owner: int, is_carried: bool) -> Node3D:
	var unit := Doubles.PhysicsCombatTarget.new(position, 0.25)
	unit.owner_player_id = owner
	parent.add_child(unit)
	unit.add_to_group(&"sim_units")
	var id: int = index.register(unit, SimEntityRegistryScript.Kind.UNIT)
	unit.set_meta("id", id)
	state.set_position(id, position)
	state.set_combat_line_bounds(id, 0.26, -0.26, 0.26)
	state.set_combat_line_carried(id, is_carried)
	return unit


func _local_ids(shooter, enemy, friend, endpoint: Vector3) -> PackedInt32Array:
	var grid = CombatLineOfFireScript.debug_grid_for_test()
	var result := PackedInt32Array()
	for id in grid.query_segment(shooter.global_position, endpoint):
		if id == int(shooter.get_meta("id")):
			continue
		if id == int(enemy.get_meta("id")) or id == int(friend.get_meta("id")):
			result.append(id)
	return result


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _least_squares_slope(xs: Array, ys: Array) -> float:
	var mean_x := 0.0
	var mean_y := 0.0
	for index in xs.size():
		mean_x += float(xs[index])
		mean_y += ys[index]
	mean_x /= float(xs.size())
	mean_y /= float(xs.size())
	var numerator := 0.0
	var denominator := 0.0
	for index in xs.size():
		var delta := float(xs[index]) - mean_x
		numerator += delta * (ys[index] - mean_y)
		denominator += delta * delta
	return numerator / denominator if denominator > 0.0 else 0.0
