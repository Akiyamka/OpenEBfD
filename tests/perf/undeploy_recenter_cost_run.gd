extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const KobraModelScene := preload("res://assets/converted/models/OR_Kobra_H0/OR_Kobra_H0.scn")


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	var unit := UnitScene.instantiate() as Unit
	unit.config_id = &"ORKobra"
	root.add_child(unit)
	unit.replace_visual_scene(KobraModelScene)
	if not unit.deploy():
		printerr("FAIL: Kobra deploy did not start")
		quit(1)
		return
	unit.finish_deployment(true)
	var turret = unit.combat()._active_turrets()[0]
	turret.current_yaw = deg_to_rad(16.0)
	turret.restore_aim_pose()
	if not unit.undeploy():
		printerr("FAIL: Kobra undeploy did not start")
		quit(1)
		return
	# Keep the real bound turret in the active recenter branch on every call.
	# Model loading and setup are outside the timed region.
	const SAMPLES := 2000
	for _warmup in 100:
		turret.current_yaw = deg_to_rad(16.0)
		unit._deploy.advance_undeploy_tick()
	var start_us := Time.get_ticks_usec()
	for _sample in SAMPLES:
		turret.current_yaw = deg_to_rad(16.0)
		unit._deploy.advance_undeploy_tick()
	var elapsed_us := Time.get_ticks_usec() - start_us
	var per_call_ms := float(elapsed_us) / float(SAMPLES) / 1000.0
	print("AP8 recenter: %d calls in %d us; per-call %.6f ms; 100 units %.3f ms/tick" % [
		SAMPLES, elapsed_us, per_call_ms, per_call_ms * 100.0
	])
	unit.free()
	quit(0)
