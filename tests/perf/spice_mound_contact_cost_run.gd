extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const MoundScene := preload("res://scenes/world/spice_mound.tscn")

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	for count in [16, 50, 200]:
		await _measure_count(count)
	_measure_arm()
	quit(0)

func _measure_count(count: int) -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=456"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	match_instance.get_node("Units/ScoutA").free()
	match_instance.get_node("Units/OrdosAPC").free()
	match_instance.get_node("Units/NIABTank").free()
	var units = match_instance.get_node("Units")
	for index in count:
		var unit = ATAPCScene.instantiate()
		unit.owner_player_id = 1
		units.add_child(unit)
		unit.set_simulation_position(Vector3(8.0 + float(index % 20) * 13.0, 8.0, 8.0 + float(index / 20) * 25.0))
	match_instance.advance_ticks(1)
	var mounds := []
	for mound in get_nodes_in_group(&"sim_spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mounds.append(mound)
	for mound_index in mini(mounds.size(), 2):
		units.get_child(mound_index).set_simulation_position(mounds[mound_index].global_position)
	var contact_candidates := []
	for mound in mounds:
		contact_candidates.append(mound._contact_entries().size())
	var runs := 120
	for _warmup in 20:
		for mound in mounds:
			mound.sim_tick()
	var start := Time.get_ticks_usec()
	for _sample in runs:
		for mound in mounds:
			mound.sim_tick()
	var elapsed := Time.get_ticks_usec() - start
	print("spice mound contact cost: units=%d mounds=%d candidates=%s ticks=%d us/tick=%.2f us/unit/mound=%.3f" % [count, mounds.size(), contact_candidates, runs, float(elapsed) / runs, float(elapsed) / (runs * count * mounds.size())])
	match_instance.queue_free()
	await process_frame

func _measure_arm() -> void:
	var mound = MoundScene.instantiate()
	mound.configure(Vector2i(69, 58), Vector2(4.0, 4.0))
	var samples := 1000
	var start := Time.get_ticks_usec()
	for _index in samples:
		mound._arm_pending_cycle()
		mound.restart_maturity_cycle()
	var elapsed := Time.get_ticks_usec() - start
	print("spice mound keyed arm: cycles=%d us/arm=%.3f audited_draws=%d" % [samples, float(elapsed) / samples, mound._local_rng.draw_count])
	mound.free()
