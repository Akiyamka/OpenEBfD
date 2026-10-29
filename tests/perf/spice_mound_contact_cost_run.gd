extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const CombatLineOfFireScript := preload("res://scripts/combat/combat_line_of_fire.gd")

const SIZES := [16, 50, 200, 1000]
const BATCHES := 5
const CALLS := 200

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	if OS.get_cmdline_user_args().has("--cold-only"):
		await _measure_cold_only()
		return
	var result := await _measure_set()
	if float(result["noise"]) > 5.0:
		print("AP23 spice grid scaling: repeating after noise > 5.0 us/call")
		result = await _measure_set()
	var medians: Array[float] = result["medians"]
	var noise: float = result["noise"]
	var spread: float = medians.max() - medians.min()
	var tolerance := maxf(maxf(noise, 1.0), 0.02 * _median(medians))
	var slope_cost := maxf(_slope(SIZES, medians), 0.0) * 984.0
	var monotonic := true
	for i in range(1, medians.size()):
		if medians[i] < medians[i - 1]:
			monotonic = false
	var clear_rise := monotonic and spread > maxf(3.0 * tolerance, 0.1 * medians.min())
	print("AP23 warmed medians=%s slope_cost=%.3f spread=%.3f noise=%.3f tolerance=%.3f us/two-mound-call" % [medians, slope_cost, spread, noise, tolerance])
	if clear_rise or (noise <= 5.0 and (slope_cost > tolerance or spread > tolerance)):
		printerr("AP23 spice grid scaling: FAIL")
		quit(1)
	elif noise > 5.0:
		printerr("AP23 spice grid scaling: INCONCLUSIVE")
		quit(1)
	else:
		print("AP23 spice grid scaling: PASS")
		quit(0)

func _measure_set() -> Dictionary:
	var samples: Array = [[], [], [], []]
	var diagnostics: Array = [{}, {}, {}, {}]
	var probe_us: Array = [[], [], [], []]
	for batch in BATCHES:
		for offset in SIZES.size():
			var size_index := (batch + offset) % SIZES.size()
			var fixture := _build_fixture(SIZES[size_index])
			var mounds: Array = fixture["mounds"]
			var match_instance: Node = fixture["match"]
			# Each fixture switch invalidates the shared static snapshot. Warm it
			# before the timed whole-call pair, including both mounds' candidates.
			for mound in mounds:
				var centre: Vector3 = mound.global_position
				CombatLineOfFireScript.rectangle_candidates(match_instance, self, Vector2(centre.x - 2.0, centre.z - 2.0), Vector2(centre.x + 2.0, centre.z + 2.0))
			var grid = CombatLineOfFireScript.debug_grid_for_test()
			var writes: int = grid.bucket_writes()
			var probes_before: int = grid.query_cell_probes()
			var probe_start := Time.get_ticks_usec()
			for _probe in 5000:
				if not CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self):
					printerr("warm probe lost current snapshot")
					quit(1)
					return {}
			(probe_us[size_index] as Array).append(float(Time.get_ticks_usec() - probe_start) / 5000.0)
			for _warm in 20:
				for mound in mounds:
					mound.sim_tick()
			var start := Time.get_ticks_usec()
			for _call in CALLS:
				for mound in mounds:
					mound.sim_tick()
			var warmed := float(Time.get_ticks_usec() - start) / CALLS
			(samples[size_index] as Array).append(warmed)
			var probes: int = grid.query_cell_probes() - probes_before
			if batch == 0:
				diagnostics[size_index] = {"candidates": [mounds[0]._contact_entries().size(), mounds[1]._contact_entries().size()], "bucket_writes": writes, "cell_probes": probes / CALLS}
			match_instance.queue_free()
			await process_frame
	var round_means: Array[float] = []
	for batch in BATCHES:
		var total := 0.0
		for size_index in SIZES.size():
			total += float((samples[size_index] as Array)[batch])
		round_means.append(total / SIZES.size())
	var noise := 0.0
	var medians: Array[float] = []
	for size_index in SIZES.size():
		var values: Array = samples[size_index]
		var adjusted: Array[float] = []
		for batch in BATCHES:
			adjusted.append(float(values[batch]) - round_means[batch])
		var centre := _median(adjusted)
		var deviations: Array[float] = []
		for value in adjusted:
			deviations.append(absf(value - centre))
		noise = maxf(noise, 3.0 * 1.4826 * _median(deviations))
		medians.append(_median(values))
		print(
				"AP23 size=%d warmed_batches_us=%s warmed_median_us=%.3f warmed_spread_us=%.3f warm_probe_us=%s diagnostics=%s" % [
				SIZES[size_index], values, _median(values), values.max() - values.min(),
				probe_us[size_index],
				diagnostics[size_index]
			]
		)
	return {"medians": medians, "noise": noise}


func _measure_cold_only() -> void:
	var sizes := SIZES
	var batches := BATCHES
	var samples_per_batch := 25
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sizes="):
			sizes = Array(arg.trim_prefix("--sizes=").split(",")).map(func(x): return int(x))
		elif arg.begins_with("--batches="):
			batches = int(arg.trim_prefix("--batches="))
		elif arg.begins_with("--samples-per-batch="):
			samples_per_batch = int(arg.trim_prefix("--samples-per-batch="))
	var samples := {}
	for size in sizes:
		samples[size] = []
	for batch in batches:
		for offset in sizes.size():
			var size: int = sizes[(batch + offset) % sizes.size()]
			var fixture := _build_fixture(size)
			var match_instance: Node = fixture["match"]
			var state = match_instance.entity_state()
			var distant = fixture["distant"]
			var mounds: Array = fixture["mounds"]
			var grid = CombatLineOfFireScript.debug_grid_for_test()
			var times: Array[float] = []
			var contacts := [0, 0]
			var writes: int = grid.bucket_writes()
			var probes: int = grid.query_cell_probes()
			for sample in samples_per_batch:
				state.set_position(distant.entity_id, state.position(distant.entity_id))
				if CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self):
					printerr("cold fixture became warm")
					quit(1)
					return
				var start := Time.get_ticks_usec()
				for mound in mounds:
					mound.sim_tick()
				times.append(float(Time.get_ticks_usec() - start))
				if sample == 0:
					for i in mounds.size():
						contacts[i] = mounds[i]._contact_entries().size()
			if grid.bucket_writes() != writes or grid.query_cell_probes() != probes:
				printerr("cold call touched grid")
				quit(1)
				return
			(samples[size] as Array).append(times)
			var sorted := times.duplicate()
			sorted.sort()
			print("cold_json: %s" % JSON.stringify({"size": size, "batch": batch, "median_us": sorted[sorted.size() / 2], "min_us": sorted.min(), "max_us": sorted.max(), "contacts": contacts, "bucket_writes_delta": grid.bucket_writes() - writes, "cell_probes_delta": grid.query_cell_probes() - probes, "samples_us": times}))
			match_instance.queue_free()
			await process_frame
	print("AP23 cold samples: PASS")
	quit(0)

func _build_fixture(count: int) -> Dictionary:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=456"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	match_instance.get_node("Units/ScoutA").free()
	match_instance.get_node("Units/OrdosAPC").free()
	match_instance.get_node("Units/NIABTank").free()
	var units = match_instance.get_node("Units")
	var distant = null
	for n in count:
		var unit = ATAPCScene.instantiate()
		unit.owner_player_id = 1
		units.add_child(unit)
		unit.set_simulation_position(Vector3(500.0 + float(n % 40) * 8.0, 8.0, 500.0 + float(n / 40) * 8.0))
		distant = unit
	match_instance.advance_ticks(1)
	var mounds: Array = []
	for mound in get_nodes_in_group(&"sim_spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mounds.append(mound)
	mounds.sort_custom(func(a, b): return a.source_cell.x < b.source_cell.x)
	for i in 2:
		var unit = units.get_child(i)
		unit.set_simulation_position(mounds[i].global_position)
	for mound in mounds:
		mound.maturity_ticks_remaining = 1000000
		mound._maturity_cycle_ticks = 1000000
	return {"match": match_instance, "mounds": mounds, "distant": distant}

func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2])

func _slope(xs: Array, ys: Array[float]) -> float:
	var mean_x := 0.0
	var mean_y := 0.0
	for i in xs.size():
		mean_x += float(xs[i])
		mean_y += ys[i]
	mean_x /= xs.size()
	mean_y /= xs.size()
	var numerator := 0.0
	var denominator := 0.0
	for i in xs.size():
		var dx := float(xs[i]) - mean_x
		numerator += dx * (ys[i] - mean_y)
		denominator += dx * dx
	return numerator / denominator
