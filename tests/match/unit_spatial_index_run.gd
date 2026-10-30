extends "res://tests/support/suite.gd"

const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const SimAdmissionQueueScript := preload("res://scripts/match/sim_admission_queue.gd")
const MatchUnitSpatialIndexScript := preload("res://scripts/match/match_unit_spatial_index.gd")
const UnitGridScript := preload("res://scripts/sim/persistent_unit_grid.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")

class StubMatch extends Node3D:
	var index := EntityNodeIndexScript.new()
	var state := SimEntityStateScript.new(index.registry())
	var queue := SimAdmissionQueueScript.new()
	var spatial = MatchUnitSpatialIndexScript.new(self, index, state, queue)

class ErrorLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		errors.append(str(code) + str(rationale))


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("J1: dirty presence, coalescing and unchanged footprints", _test_journal)
	_run_case("J2: radius, carried and repeated query", _test_profile)
	_run_case("J3: admission, release and out-of-group movement", _test_lifecycle)
	_run_case("J3: two Match grids with overlapping ids", _test_two_matches)
	_run_case("J5: rectangle and segment geometry", _test_geometry)
	_run_case("J5: stored-circle capsule oracle", _test_segment_oracle)
	_run_case("J5: restore generation", _test_restore)
	await _run_async_case("J3: no-query Match lifecycle drain", _test_no_query_tick)
	_finish("Persistent unit index")


func _stub() -> StubMatch:
	var match_instance := StubMatch.new()
	root.add_child(match_instance)
	return match_instance


func _body(match_instance: StubMatch, at: Vector3, radius: float = 0.2) -> int:
	var body := Node3D.new()
	match_instance.add_child(body)
	body.add_to_group(&"sim_units")
	var id: int = match_instance.index.register(body, 1)
	match_instance.state.set_position(id, at)
	match_instance.state.set_combat_line_bounds(id, radius, -0.2, 0.2)
	return id


func _has(ids: PackedInt32Array, id: int) -> bool:
	return ids.has(id)


func _test_journal() -> void:
	var m := _stub()
	var node := Node3D.new()
	m.add_child(node)
	node.add_to_group(&"sim_units")
	var id: int = m.index.register(node, 1)
	m.state.set_combat_line_bounds(id, 0.2, -0.2, 0.2)
	m.state.set_combat_line_carried(id, false)
	m.spatial.sync()
	_expect(not m.spatial.has_raw_id(id), "bounds alone do not index an unwritten position")
	m.state.set_position(id, Vector3.ZERO)
	_expect(m.state.spatial_dirty_count() == 1, "first zero position marks presence")
	_expect(_has(m.spatial.rectangle_candidates(Vector2(-1, -1), Vector2(1, 1)), id), "origin enters after first position")
	m.state.set_position(id, Vector3.ZERO)
	m.state.set_combat_line_bounds(id, 0.2, -0.2, 0.2)
	m.state.set_combat_line_carried(id, false)
	_expect(m.state.spatial_dirty_count() == 0, "identical packed writes do not dirty")
	var writes: int = m.spatial.bucket_writes()
	m.state.set_position(id, Vector3(0.1, 0, 0))
	m.state.set_position(id, Vector3.ZERO)
	_expect(m.state.spatial_dirty_count() == 1, "two writes coalesce")
	m.state.begin_tick()
	_expect(m.state.spatial_dirty_count() == 1, "dirty id survives a tick without query")
	m.spatial.sync()
	_expect(m.spatial.bucket_writes() == writes, "out and back does not rewrite buckets")
	m.state.set_position(id, Vector3(8, 0, 0))
	_expect(_has(m.spatial.rectangle_candidates(Vector2(8, 0), Vector2(8, 0)), id), "post-sync write is observed")
	m.free()


func _test_profile() -> void:
	var m := _stub()
	var id := _body(m, Vector3(1, 0, 1))
	m.spatial.sync()
	_expect(not _has(m.spatial.rectangle_candidates(Vector2(5, 1), Vector2(5, 1)), id), "small radius misses distant cell")
	m.state.set_combat_line_bounds(id, 4.0, -0.2, 0.2)
	_expect(_has(m.spatial.rectangle_candidates(Vector2(5, 1), Vector2(5, 1)), id), "radius growth is indexed")
	m.state.set_combat_line_bounds(id, 0.2, -0.2, 0.2)
	_expect(not _has(m.spatial.rectangle_candidates(Vector2(5, 1), Vector2(5, 1)), id), "radius shrink is indexed")
	m.state.set_combat_line_carried(id, true)
	_expect(not m.spatial.has_raw_id(id) or not _has(m.spatial.rectangle_candidates(Vector2(1, 1), Vector2(1, 1)), id), "carried unit leaves raw grid")
	m.state.set_combat_line_carried(id, false)
	_expect(_has(m.spatial.rectangle_candidates(Vector2(1, 1), Vector2(1, 1)), id), "uncarried unit returns")
	m.free()


func _test_lifecycle() -> void:
	var m := _stub()
	var node := Node3D.new()
	m.add_child(node)
	var id: int = m.index.register(node, 1)
	m.state.set_position(id, Vector3(50, 0, 50))
	m.state.set_combat_line_bounds(id, 0.2, -0.2, 0.2)
	m.spatial.sync()
	_expect(not m.spatial.has_raw_id(id), "pre-admission dirty is excluded")
	m.queue.request_entry(node, &"sim_units")
	_expect(m.queue.apply_pending_entries() == 1, "first admission occurred")
	_expect(_has(m.spatial.rectangle_candidates(Vector2(50, 50), Vector2(50, 50)), id), "admission re-offers prior writes")
	node.remove_from_group(&"sim_units")
	m.state.set_position(id, Vector3(2, 0, 2))
	_expect(_has(m.spatial.rectangle_candidates(Vector2(2, 2), Vector2(2, 2)), id), "indexed unit moves while outside group")
	node.add_to_group(&"sim_units")
	_expect(_has(m.spatial.rectangle_candidates(Vector2(2, 2), Vector2(2, 2)), id), "re-add needs no write")
	m.index.request_release(id)
	m.spatial.sync()
	_expect(not m.spatial.has_raw_id(id), "request release removes raw member")
	_expect(m.index.registry().spatial_release_count() == 0 and m.queue.spatial_admission_count() == 0, "lifecycle journals drain")
	m.free()


func _test_geometry() -> void:
	var grid := UnitGridScript.new()
	grid.upsert(9, Vector3(-4, 0, -4), 0.2)
	grid.upsert(3, Vector3(4, 0, 4), 0.2)
	grid.upsert(7, Vector3(6, 0, 5), 0.2)
	_expect(grid.rectangle_candidates(Vector2(-4, -4), Vector2(-4, -4)) == PackedInt32Array([9]), "negative closed edge")
	_expect(grid.padded_segment_candidates(Vector3.ZERO, Vector3.ZERO, 0).has(3), "zero-length corner touches adjacent cell")
	var ids := grid.padded_segment_candidates(Vector3(0, 0, 0), Vector3(8, 0, 8), 0.4)
	_expect(ids == PackedInt32Array([3, 7, 9]), "corner diagonal and pad return sorted unique ids")
	grid.upsert(11, Vector3(2, 0, 4.1), 0.05)
	_expect(grid.padded_segment_candidates(Vector3.ZERO, Vector3(4, 0, 0), 4.1).has(11), "padding halo reaches adjacent row")
	_expect(grid.padded_segment_candidates(Vector3(8, 0, 8), Vector3.ZERO, 0.4).has(9), "reverse diagonal keeps closed origin corner")
	var before: int = grid.query_cell_probes()
	grid.padded_segment_candidates(Vector3(0, 0, 0), Vector3(400, 0, 400), 0.4)
	_expect(grid.query_cell_probes() - before < 1500, "long diagonal visits row halo, not bounding square")
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	var bad_rect := grid.rectangle_candidates(Vector2(INF, 0), Vector2(1, 1))
	var bad_pad := grid.padded_segment_candidates(Vector3.ZERO, Vector3.ONE, -1.0)
	var bad_point := grid.padded_segment_candidates(Vector3(INF, 0, 0), Vector3.ZERO, 0.0)
	OS.remove_logger(logger)
	_expect(bad_rect.is_empty() and bad_pad.is_empty() and bad_point.is_empty() \
	and logger.errors.size() == 3, "invalid inputs return empty and log each error")


func _test_two_matches() -> void:
	var a := _stub()
	var b := _stub()
	var id_a := _body(a, Vector3(10, 0, 10))
	var id_b := _body(b, Vector3(90, 0, 90))
	_expect(id_a == id_b, "matches allocate overlapping local stable ids")
	_expect(_has(a.spatial.rectangle_candidates(Vector2(10, 10), Vector2(10, 10)), id_a), "first Match keeps its candidate")
	_expect(not _has(b.spatial.rectangle_candidates(Vector2(10, 10), Vector2(10, 10)), id_b), "second Match has no first-Match candidate")
	_expect(_has(b.spatial.rectangle_candidates(Vector2(90, 90), Vector2(90, 90)), id_b), "second Match keeps its own candidate")
	_expect(_has(a.spatial.rectangle_candidates(Vector2(10, 10), Vector2(10, 10)), id_a), "first Match remains correct after second Match sync")
	a.free()
	b.free()


func _test_segment_oracle() -> void:
	var grid := UnitGridScript.new()
	var centres: Array[Vector2] = []
	var radii: Array[float] = []
	for i in 50:
		var centre := Vector2(float((i * 37) % 81 - 40) * 0.47, float((i * 53) % 79 - 39) * 0.51)
		var radius := 0.2 + float(i % 4) * 0.3
		centres.append(centre)
		radii.append(radius)
		grid.upsert(i + 1, Vector3(centre.x, 0, centre.y), radius)
	var hits := 0
	for j in 40:
		var a := Vector2(float((j * 29) % 73 - 36) * 0.5, float((j * 47) % 71 - 35) * 0.5)
		var b := Vector2(float((j * 41) % 67 - 33) * 0.5, float((j * 31) % 61 - 30) * 0.5)
		var padding := [0.0, 0.4, 4.1][j % 3] as float
		var candidates := grid.padded_segment_candidates(Vector3(a.x, 0, a.y), Vector3(b.x, 0, b.y), padding)
		var direction := b - a
		for i in 50:
			var t := clampf((centres[i] - a).dot(direction) / direction.length_squared(), 0.0, 1.0)
			if centres[i].distance_to(a + direction * t) < radii[i] + padding - 0.00001:
				hits += 1
				_expect(candidates.has(i + 1), "capsule oracle keeps intersecting circle %d on segment %d" % [i, j])
	_expect(hits > 20, "oracle exercises multiple actual capsule intersections")


func _test_restore() -> void:
	var m := _stub()
	var id := _body(m, Vector3(20, 0, 20))
	m.spatial.sync()
	var snapshot: Dictionary = m.state.capture()
	m.state.set_position(id, Vector3(40, 0, 40))
	m.spatial.sync()
	_expect(m.state.restore(snapshot), "state restore succeeds")
	_expect(_has(m.spatial.rectangle_candidates(Vector2(20, 20), Vector2(20, 20)), id), "restore seeds original cell")
	_expect(not _has(m.spatial.rectangle_candidates(Vector2(40, 40), Vector2(40, 40)), id), "restore discards stale cell")
	m.index.release_id(id)
	m.spatial.sync()
	_expect(not m.spatial.has_raw_id(id), "direct release removes raw id")
	m.free()


func _test_no_query_tick() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=456"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var units = match_instance.get_node("Units")
	var added: Array = []
	for i in 30:
		var unit = ATAPCScene.instantiate()
		unit.owner_player_id = 1
		units.add_child(unit)
		unit.set_simulation_position(Vector3(500.0 + i * 8.0, 8.0, 500.0))
		added.append(unit)
	_expect(match_instance.admission_queue().pending_entry_count() >= 30, "births are queued before tick")
	match_instance.advance_ticks(1)
	_expect(match_instance.admission_queue().spatial_admission_count() == 0 \
	and match_instance.entity_state().spatial_dirty_count() == 0, "end sync drains births and positions without queries")
	for unit in added:
		unit.free()
	match_instance.advance_ticks(1)
	_expect(match_instance.entity_index().registry().spatial_release_count() == 0, "end sync drains releases without queries")
	match_instance.queue_free()
	await process_frame
