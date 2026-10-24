extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const UnitScript := preload("res://scripts/units/unit.gd")
const ORAPCScene := preload("res://scenes/units/or_apc.tscn")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const ATAPCScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const DevastatorScene := preload("res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn")
const LaserTankScene := preload("res://assets/converted/models/OR_Lasertank_H0/OR_Lasertank_H0.scn")
const MinotaurusScene := preload("res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn")


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("in-tree rest agrees with authored live geometry", _test_rest_equivalence)
	_run_case("prepared unit binds after rest snapshot", _test_ready_only_bind)
	_run_case("presentation changes leave aim, muzzle and shot stable", _test_view_perturbation)
	_run_case("model replacement retains root rest", _test_model_swap)
	_run_case("same-model setup binds an unbound weapon from saved rest", _test_same_model_setup)
	_run_case("logical yaw, pitch and barrel index affect the shot", _test_angles_and_muzzles)
	_run_case("no-marker fallback stays in Unit space", _test_selection_fallback)
	_run_case("missing VisualRoot keeps the one-unit fallback", _test_missing_visual_root)
	_run_case("bare model keeps live marker geometry", _test_bare_model_fallback)
	_run_case("cosmetic flash follows rendered muzzle", _test_visual_flash)
	_finish("Combat pose authority tests")


func _unit(unit_id: StringName, model: PackedScene, position: Vector3) -> Node3D:
	var unit := UnitScene.instantiate() as Node3D
	unit.set("config_id", unit_id)
	root.add_child(unit)
	unit.global_position = position
	unit.call("replace_visual_scene", model)
	return unit


func _near(a: Vector3, b: Vector3, epsilon := 0.002) -> bool:
	return a.distance_to(b) <= epsilon


class NullCallLogger extends Logger:
	var saw_null_call := false

	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		saw_null_call = saw_null_call or "null value" in str(code) or "null value" in str(rationale)


class NoReadyUnit extends UnitScript:
	func _ready() -> void:
		pass


func _test_ready_only_bind() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var unit := ORAPCScene.instantiate() as Node3D
	root.add_child(unit)
	var turret = unit.get("combat_turrets")[0]
	for angles in [Vector2.ZERO, Vector2(0.6, 0.0)]:
		turret.restore_aim_angles(angles)
		var logical: Dictionary = turret.peek_emission()
		var visible: Dictionary = turret.visual_peek_emission()
		_expect(_near(logical["position"], visible["position"]),
			"ready-only ORAPC logical muzzle must agree with visible muzzle at %s" % angles)
		_expect(Vector3(logical["direction"]).dot(visible["direction"]) > 0.99999,
			"ready-only ORAPC logical direction must agree with visible muzzle at %s" % angles)
		_expect(turret._trajectory_aim_origin_local.is_finite(),
			"ready-only ORAPC trajectory origin must be finite at %s" % angles)
	_expect(not logger.saw_null_call, "ready-only binding must not produce null-call script errors")
	unit.free()
	OS.remove_logger(logger)


func _test_rest_equivalence() -> void:
	var unit := _unit(&"ATAPC", ATAPCScene, Vector3(14.0, 0.0, -9.0))
	_expect(unit.is_inside_tree(), "static fixture must be in the tree")
	var old_centre: Vector3 = unit.call("simulation_position") \
		+ unit.global_basis * unit.call("_selection_bounds").get_center()
	_expect(_near(unit.call("combat_aim_position"), old_centre),
		"fresh in-tree centre must equal the authored live selection bounds")
	var turret = unit.get("combat_turrets")[0]
	var logical: Dictionary = turret.peek_emission()
	var visual: Dictionary = turret.visual_peek_emission()
	_expect(_near(logical["position"], visual["position"]),
		"neutral muzzle must agree with the in-tree rendered muzzle")
	_expect(Vector3(logical["direction"]).dot(visual["direction"]) > 0.99999,
		"neutral muzzle direction must agree with the rendered muzzle")
	unit.free()


func _test_view_perturbation() -> void:
	var unit := _unit(&"ATAPC", ATAPCScene, Vector3(20.0, 0.0, -13.0))
	var turret = unit.get("combat_turrets")[0]
	var aim_before: Vector3 = unit.call("combat_aim_position")
	var muzzle_before: Dictionary = turret.peek_emission()
	var visual_before: Dictionary = turret.visual_peek_emission()
	var marker := visual_before["node"] as Node3D
	var original_marker := marker.transform
	var visual_root := unit.get_node("VisualRoot") as Node3D
	visual_root.position += Vector3(1.2, 0.4, 0.8)
	marker.position += Vector3(0.6, 0.0, 0.0)
	var visual_after: Dictionary = turret.visual_peek_emission()
	_expect(not _near(visual_before["position"], visual_after["position"]),
		"view perturbation must visibly move the marker")
	_expect(_near(aim_before, unit.call("combat_aim_position")),
		"view translation must not move combat aim")
	_expect(_near(muzzle_before["position"], turret.peek_emission()["position"]),
		"view translation and non-pivot marker motion must not move combat muzzle")
	_expect(Vector3(muzzle_before["direction"]).dot(turret.peek_emission()["direction"]) > 0.99999,
		"non-pivot marker motion must not turn the shot")
	var forward: Vector3 = muzzle_before["direction"]
	var request := FireRequestScript.authored(
		Vector3(muzzle_before["position"]) + forward * 8.0, unit
	)
	request.projectile_parent = root
	var shots: Array = turret.try_fire_at(request)
	_expect(not shots.is_empty(), "the perturbed Unit must emit a projectile")
	if not shots.is_empty():
		_expect(_near(shots[0]._launch_position, muzzle_before["position"]),
			"projectile must start at the logical muzzle")
	for shot in shots:
		shot.free()
	marker.transform = original_marker
	unit.free()


func _test_model_swap() -> void:
	var baseline := _unit(&"HKDevastator", DevastatorScene, Vector3(7.0, 0.0, -4.0))
	var ordinary := _unit(&"ATAPC", ATAPCScene, Vector3(7.0, 0.0, -4.0))
	ordinary.call("setup", &"HKDevastator")
	ordinary.call("replace_visual_scene", DevastatorScene)
	_expect(_near(ordinary.call("combat_aim_position"), baseline.call("combat_aim_position")),
		"ordinary model swap must recompute its combat centre")
	var swapped := _unit(&"ATAPC", ATAPCScene, Vector3(7.0, 0.0, -4.0))
	swapped.call("setup", &"HKDevastator")
	var visual_root := swapped.get_node("VisualRoot") as Node3D
	visual_root.position += Vector3(1.0, 0.5, -0.8)
	visual_root.basis = visual_root.basis.rotated(Vector3.RIGHT, 0.2)
	swapped.call("replace_visual_scene", DevastatorScene)
	_expect(_near(swapped.call("combat_aim_position"), baseline.call("combat_aim_position")),
		"tilted and translated root must not shift swapped combat centre")
	for index in 2:
		var baseline_turret = baseline.get("combat_turrets")[index]
		var swapped_turret = swapped.get("combat_turrets")[index]
		_expect(_near(baseline_turret.peek_emission()["position"],
			swapped_turret.peek_emission()["position"]),
			"tilted and translated root must not shift swapped muzzle %d" % index)
	baseline.free()
	ordinary.free()
	swapped.free()


func _test_selection_fallback() -> void:
	var unit := UnitScene.instantiate() as Node3D
	root.add_child(unit)
	unit.global_position = Vector3(11.0, 0.0, 5.0)
	var visual_root := unit.get_node("VisualRoot") as Node3D
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	unit.call("combat_geometry").capture_model()
	_expect(_near(unit.call("combat_aim_position"), Vector3(11.5, 0.5, 5.5)),
		"one-unit fallback must be applied after the root rest in Unit space")
	unit.free()


func _test_missing_visual_root() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var unit := UnitScene.instantiate() as Node3D
	unit.set("visual_root_path", NodePath("MissingVisualRoot"))
	root.add_child(unit)
	unit.global_position = Vector3(11.0, 0.0, 5.0)
	_expect(_near(unit.call("combat_aim_position"), Vector3(11.5, 0.5, 5.5)),
		"missing VisualRoot must use the one-unit box in Unit space")
	_expect(not logger.saw_null_call, "missing VisualRoot must not produce null-call script errors")
	unit.free()
	var stub := NoReadyUnit.new()
	root.add_child(stub)
	stub.global_position = Vector3(3.0, 0.0, 7.0)
	_expect(_near(stub.combat_aim_position(), Vector3(3.5, 0.5, 7.5)),
		"stubbed-ready Unit must retain the one-unit combat aim fallback")
	_expect(_near(stub.combat_model_transform().origin, Vector3(3.0, 0.0, 7.0)),
		"stubbed-ready Unit must retain an identity-root model transform")
	stub.free()
	OS.remove_logger(logger)


func _test_same_model_setup() -> void:
	var baseline := _unit(&"HKDevastator", DevastatorScene, Vector3(9.0, 0.0, 4.0))
	var rebound := _unit(&"ATAPC", DevastatorScene, Vector3(9.0, 0.0, 4.0))
	var baseline_new = baseline.get("combat_turrets")[1]
	var new_pivot := baseline_new._root_pivot as Node3D
	var rebound_pivot := rebound.get_node(
		"VisualRoot/%s" % String(baseline.get_node("VisualRoot").get_path_to(new_pivot))
	) as Node3D
	var rest_pivot := baseline_new._pivot_rest_transforms[new_pivot] as Transform3D
	rebound.get("combat_turrets")[0].restore_aim_angles(Vector2(0.3, -0.1))
	rebound_pivot.transform = Transform3D(
		rebound_pivot.basis.rotated(Vector3.UP, 0.5),
		rebound_pivot.position + Vector3(0.2, 0.0, 0.0)
	)
	rebound.call("setup", &"HKDevastator")
	_expect(Vector3(rebound.get("combat_turrets")[0].peek_emission()["position"])
		.distance_to(baseline.get("combat_turrets")[0].peek_emission()["position"]) < 0.002,
		"previously bound weapon must also return to fresh-model rest")
	var rebound_new = rebound.get("combat_turrets")[1]
	_expect(Vector3(rebound_new.peek_emission()["position"]).distance_to(
		baseline_new.peek_emission()["position"]) < 0.002,
		"newly bound weapon must use previously saved logical rest")
	_expect((rebound_new._pivot_rest_transforms[rebound_pivot] as Transform3D)
		.is_equal_approx(rest_pivot),
		"newly bound servo must use previously saved visual pivot rest")
	rebound_new.restore_aim_pose()
	_expect(rebound_pivot.transform.is_equal_approx(rest_pivot),
		"restoring zero aim must return new pivot to fresh-model rest")
	baseline.free()
	rebound.free()


func _test_angles_and_muzzles() -> void:
	var unit := _unit(&"ATAPC", ATAPCScene, Vector3(2.0, 0.0, 11.0))
	var turret = unit.get("combat_turrets")[0]
	var neutral: Dictionary = turret.peek_emission()
	turret.restore_aim_angles(Vector2(0.2, -0.1))
	var aimed: Dictionary = turret.peek_emission()
	var visible: Dictionary = turret.visual_peek_emission()
	_expect(Vector3(aimed["position"]).distance_to(neutral["position"]) > 0.01,
		"nonzero servo angles must change the logical muzzle")
	_expect(Vector3(aimed["position"]).distance_to(visible["position"]) < 0.002,
		"logical yaw and pitch must match an unanimated visual servo")
	var request := FireRequestScript.authored(
		Vector3(aimed["position"]) + Vector3(aimed["direction"]) * 8.0, unit
	)
	request.projectile_parent = root
	var shots: Array = turret.try_fire_at(request)
	_expect(not shots.is_empty(), "articulated turret must emit a projectile")
	if not shots.is_empty():
		_expect(Vector3(shots[0]._launch_position).distance_to(aimed["position"]) < 0.002,
			"articulated shot must start at yaw/pitch logical muzzle")
	for shot in shots:
		shot.free()
	unit.free()
	var devastator := _unit(&"HKDevastator", DevastatorScene, Vector3(0.0, 0.0, 0.0))
	var gun = devastator.get("combat_turrets")[0]
	var points: Array[Dictionary] = gun.emission_points()
	_expect(points.size() > 1, "fixed Devastator gun must retain multiple muzzles")
	for index in points.size():
		_expect(points[index]["index"] == index
			and points[index]["node"] == gun.visual_emission_points()[index]["node"],
			"logical muzzle index must retain the authored marker identity")
	devastator.free()


func _test_bare_model_fallback() -> void:
	var model := LaserTankScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(turret.configure(&"ORLaserTankBase") and turret.bind_model(model, 0),
		"bare laser model turret must bind")
	var before: Dictionary = turret.peek_emission()
	var marker := before["node"] as Node3D
	marker.position += Vector3(20.0, 0.0, 0.0)
	var after: Dictionary = turret.peek_emission()
	_expect(Vector3(after["position"]).distance_to(before["position"]) > 0.5,
		"bare model gameplay emission must follow its live marker")
	turret.unbind_model()
	model.free()


func _test_visual_flash() -> void:
	var unit := _unit(&"ATMinotaurus", MinotaurusScene, Vector3(0.0, 0.0, 0.0))
	var turret = unit.get("combat_turrets")[0]
	var logical: Dictionary = turret.peek_emission()
	var visual_root := unit.get_node("VisualRoot") as Node3D
	visual_root.position += Vector3(1.0, 0.0, 0.0)
	var visible: Dictionary = turret.visual_peek_emission()
	_expect(Vector3(visible["position"]).distance_to(logical["position"]) > 0.5,
		"flash fixture must visibly separate render and combat muzzles")
	var target: Vector3 = Vector3(logical["position"]) \
		+ Vector3(logical["direction"]) * 10.0
	var request := FireRequestScript.authored(target, unit)
	request.projectile_parent = root
	var shots: Array = turret.try_fire_at(request)
	_expect(not shots.is_empty(), "flash fixture must emit a projectile")
	if not shots.is_empty():
		_expect(Vector3(shots[0]._launch_position).distance_to(logical["position"]) < 0.002,
			"cosmetic flash must not move projectile origin")
	var flash := root.get_node_or_null("MuzzleFlash_Muzzle3") as Node3D
	_expect(flash != null and flash.global_position.distance_to(visible["position"]) < 0.002,
		"muzzle flash must spawn at the rendered marker")
	for shot in shots:
		shot.free()
	if flash != null:
		flash.free()
	unit.free()
