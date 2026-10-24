extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case("real Match stores pose while presentation changes", _test_match_pose)
	_finish("Match combat pose tests")


func _test_match_pose() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	await process_frame
	await process_frame
	await process_frame
	match_instance.advance_ticks(1)
	var unit := match_instance.get_node("Units/OrdosAPC") as Node3D
	var store = match_instance.entity_state()
	var entity_id: int = unit.get("entity_id")
	_expect(entity_id != 0 and store.has_position(entity_id),
		"real Match must admit this unit and store its position")
	var position: Vector3 = store.position(entity_id)
	var heading := unit.global_basis
	var turret = unit.get("combat_turrets")[0]
	var angles := Vector2(turret.current_yaw, turret.current_pitch)
	var aim_before: Vector3 = unit.call("combat_aim_position")
	var muzzle_before: Dictionary = turret.peek_emission()
	var visual_before: Dictionary = turret.visual_peek_emission()
	var target: Vector3 = Vector3(muzzle_before["position"]) \
		+ Vector3(muzzle_before["direction"]) * 8.0
	var aligned_before: bool = turret.is_aimed_at(target)
	_expect(aligned_before, "real Match baseline must have an aligned fire decision")
	var visual_root := unit.get_node("VisualRoot") as Node3D
	visual_root.position += Vector3(1.4, 0.2, 0.7)
	var marker := visual_before["node"] as Node3D
	marker.position += Vector3(0.5, 0.0, 0.0)
	var visual_after: Dictionary = turret.visual_peek_emission()
	_expect(Vector3(visual_before["position"]).distance_to(visual_after["position"]) > 0.5,
		"real Match view-only change must move visible marker")
	_expect(store.position(entity_id).is_equal_approx(position)
		and unit.global_basis.is_equal_approx(heading)
		and Vector2(turret.current_yaw, turret.current_pitch).is_equal_approx(angles),
		"store, body heading and turret angles must remain unchanged")
	_expect(Vector3(unit.call("combat_aim_position")).distance_to(aim_before) < 0.002,
		"real Match view change must not shift combat aim")
	_expect(Vector3(turret.peek_emission()["position"]).distance_to(muzzle_before["position"]) < 0.002,
		"real Match view change must not shift muzzle")
	_expect(turret.is_aimed_at(target) == aligned_before,
		"aligned-fire decision must remain unchanged")
	var request := FireRequestScript.authored(target, unit)
	request.projectile_parent = root
	var shots: Array = turret.try_fire_at(request)
	_expect(not shots.is_empty(), "real Match pose case must emit a projectile")
	if not shots.is_empty():
		_expect(Vector3(shots[0]._launch_position).distance_to(muzzle_before["position"]) < 0.002,
			"real Match shot must launch at the stable logical muzzle")
	for shot in shots:
		shot.free()
	match_instance.queue_free()
	await process_frame
