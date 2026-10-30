extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")

const SIZES := [16, 50, 200, 1000]
const FROM := Vector3(201.0, 8.0, 201.5)
const TO := Vector3(206.656854, 8.0, 207.156854)
const PADDING := 0.4


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	if OS.get_cmdline_user_args().has("--public-compare"):
		await _public_compare()
		return
	if OS.get_cmdline_user_args().has("--segments-only"):
		await _segments_only()
		return
	var samples: Dictionary = {}
	for size in SIZES:
		samples[size] = []
	for round_index in 5:
		for offset in SIZES.size():
			var size: int = SIZES[(round_index + offset) % SIZES.size()]
			var f := _fixture(size)
			var spatial = f["match"].unit_spatial_index()
			var units: Array = f["units"]
			var mounds: Array = f["mounds"]
			spatial.sync()
			var before_writes: int = spatial.bucket_writes()
			var start := Time.get_ticks_usec()
			for call_index in 20:
				for j in 2:
					var unit = units[j]
					unit.set_simulation_position(unit.simulation_position() + Vector3(0.001, 0, 0))
				for mound in mounds:
					mound._contact_entries()
				spatial.padded_segment_candidates(FROM, TO, PADDING)
			var elapsed := float(Time.get_ticks_usec() - start) / 20.0
			(samples[size] as Array).append(elapsed)
			print("A6 round=%d size=%d whole_us=%.2f candidates=%s dirty=%d writes=%d cells=%d" % [round_index, size, elapsed, [mounds[0]._contact_entries().size(), mounds[1]._contact_entries().size()], spatial.last_dirty_count(), spatial.bucket_writes() - before_writes, spatial.query_cell_probes()])
			if round_index == 0:
				for unit in units:
					unit.set_simulation_position(unit.simulation_position())
				for j in 2:
					units[j].set_simulation_position(units[j].simulation_position() + Vector3(0.001, 0, 0))
				var unchanged_writes: int = spatial.bucket_writes()
				spatial.sync()
				if spatial.last_dirty_count() != 2 or spatial.bucket_writes() != unchanged_writes:
					_fail("A6 unchanged population / within-cell motion changed buckets")
					return
			f["match"].queue_free()
			await process_frame
	for size in SIZES:
		print("A6 size=%d median_us=%.2f span_us=%.2f" % [size, _median(samples[size]), (samples[size] as Array).max() - (samples[size] as Array).min()])
	var small: float = _median(samples[16])
	var large: float = _median(samples[1000])
	if large - small > maxf(0.1 * small, 3.0 * maxf((samples[16] as Array).max() - (samples[16] as Array).min(), (samples[1000] as Array).max() - (samples[1000] as Array).min())):
		_fail("A6 distant-unit slope exceeds noise tolerance")
		return
	await _no_consumer()


func _segments_only() -> void:
	print("A7 segment from=%s to=%s length=%.6f padding=%.2f" % [FROM, TO, FROM.distance_to(TO), PADDING])
	for size in [16, 1000]:
		var f := _fixture(size)
		var spatial = f["match"].unit_spatial_index()
		spatial.sync()
		var ids: PackedInt32Array = spatial.padded_segment_candidates(FROM, TO, PADDING)
		var times: Array = []
		for round_index in 5:
			var start := Time.get_ticks_usec()
			for i in 100:
				spatial.padded_segment_candidates(FROM, TO, PADDING)
			times.append(float(Time.get_ticks_usec() - start) / 100.0)
		print("A7 size=%d local_candidates=%d median_us=%.3f span_us=%.3f cells=%d" % [size, ids.size(), _median(times), times.max() - times.min(), spatial.query_cell_probes()])
		var grid_start := Time.get_ticks_usec()
		for i in 1000:
			spatial._grid.padded_segment_candidates(FROM, TO, PADDING)
		print("A7 grid_only_us=%.3f" % [float(Time.get_ticks_usec() - grid_start) / 1000.0])
		if size == 16:
			var local_unit = (f["units"] as Array)[0]
			local_unit.set_simulation_position(Vector3(203.0, 8.0, 203.5))
			var local_ids: PackedInt32Array = spatial.padded_segment_candidates(FROM, TO, PADDING)
			if local_ids.size() != 1:
				_fail("A7 local arm must have exactly one candidate")
				return
			var local_start := Time.get_ticks_usec()
			for i in 100:
				spatial.padded_segment_candidates(FROM, TO, PADDING)
			print("A7 one_local_candidate_mean_us=%.3f" % [float(Time.get_ticks_usec() - local_start) / 100.0])
		if size == 1000 and _median(times) > 10.0:
			_fail("A7 100 empty segments exceed 1 ms")
			return
		f["match"].queue_free()
		await process_frame
	print("A7 PASS")
	quit(0)


func _no_consumer() -> void:
	var f := _fixture(100)
	var spatial = f["match"].unit_spatial_index()
	var units: Array = f["units"]
	spatial.sync()
	var times: Array = []
	var write_times: Array = []
	for round_index in 5:
		var start := Time.get_ticks_usec()
		for unit in units:
			unit.set_simulation_position(unit.simulation_position() + Vector3(0.001, 0, 0))
		var after_writes := Time.get_ticks_usec()
		spatial.sync()
		times.append(float(Time.get_ticks_usec() - after_writes))
		write_times.append(float(after_writes - start))
	print("A6 no-consumer 100 movers: end-sync median_us=%.2f span_us=%.2f writes_median_us=%.2f HEAD sync=0" % [_median(times), times.max() - times.min(), _median(write_times)])
	var unchanged_start := Time.get_ticks_usec()
	for unit in units:
		unit.set_simulation_position(unit.simulation_position())
	print("A6 unchanged set_position microcost_us=%.3f dirty=%d" % [float(Time.get_ticks_usec() - unchanged_start) / units.size(), f["match"].entity_state().spatial_dirty_count()])
	if _median(times) > 1000.0:
		_fail("A6 no-consumer realistic 100-mover path exceeds 1 ms")
		return
	var match_instance = f["match"]
	var fresh_service = load("res://scripts/match/match_unit_spatial_index.gd").new(
		match_instance, match_instance.entity_index(), match_instance.entity_state(), match_instance.admission_queue()
	)
	var bootstrap_start := Time.get_ticks_usec()
	fresh_service.sync()
	print("A6 one-time bootstrap_us=%d" % [Time.get_ticks_usec() - bootstrap_start])
	var snapshot: Dictionary = match_instance.entity_state().capture()
	if not match_instance.entity_state().restore(snapshot):
		_fail("A6 restore setup failed")
		return
	var restore_start := Time.get_ticks_usec()
	spatial.sync()
	print("A6 one-time restore_seed_us=%d" % [Time.get_ticks_usec() - restore_start])
	f["match"].queue_free()
	await process_frame
	print("A6 PASS")
	quit(0)


func _public_compare() -> void:
	var f := _fixture(100)
	var units: Array = f["units"]
	var mounds: Array = f["mounds"]
	var samples: Array = []
	var timed_contacts := 0
	for round_index in 3:
		var start := Time.get_ticks_usec()
		for i in 10:
			for unit in units:
				unit.set_simulation_position(unit.simulation_position() + Vector3(0.001, 0, 0))
			for mound in mounds:
				timed_contacts += mound._contact_entries().size()
		samples.append(float(Time.get_ticks_usec() - start) / 10.0)
	if timed_contacts != 60:
		_fail("public comparison must time both mound contacts in every window")
		return
	print("AP26 public compare 100 movers/two mounds median_us=%.2f span_us=%.2f contacts=%s" % [_median(samples), samples.max() - samples.min(), [mounds[0]._contact_entries().size(), mounds[1]._contact_entries().size()]])
	f["match"].queue_free()
	await process_frame
	quit(0)


func _fixture(count: int) -> Dictionary:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=456"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	for path in ["Units/ScoutA", "Units/OrdosAPC", "Units/NIABTank"]:
		match_instance.get_node(path).free()
	var parent = match_instance.get_node("Units")
	var units: Array = []
	for n in count:
		var unit = ATAPCScene.instantiate()
		unit.owner_player_id = 1
		parent.add_child(unit)
		unit.set_simulation_position(Vector3(500.0 + float(n % 40) * 8.0, 8.0, 500.0 + float(n / 40) * 8.0))
		units.append(unit)
	match_instance.advance_ticks(1)
	var mounds: Array = []
	for mound in get_nodes_in_group(&"sim_spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mounds.append(mound)
	mounds.sort_custom(func(a, b): return a.source_cell.x < b.source_cell.x)
	if mounds.size() != 2:
		_fail("fixture must have two mounds")
	for i in 2:
		units[i].set_simulation_position(mounds[i].global_position)
	if mounds[0]._contact_entries().is_empty() or mounds[1]._contact_entries().is_empty():
		_fail("fixture must exercise both mound contacts")
	return {"match": match_instance, "units": units, "mounds": mounds}


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2])


func _fail(message: String) -> void:
	printerr(message)
	quit(1)
