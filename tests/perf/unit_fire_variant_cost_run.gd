extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const KobraModel := preload("res://assets/converted/models/OR_Kobra_H0/OR_Kobra_H0.scn")

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	var calls := 2000
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--calls="):
			calls = int(arg.trim_prefix("--calls="))
	var kobra = UnitScene.instantiate()
	kobra.config_id = &"ORKobra"
	root.add_child(kobra)
	kobra.replace_visual_scene(KobraModel)
	var combat = kobra.combat()
	var turret = kobra.combat_turrets[0]
	var elapsed_usec := 0
	var successes := 0
	for _i in calls:
		var begin := Time.get_ticks_usec()
		var started: bool = combat._start_authored_fire_sequence(turret, Vector3(20, 0, 20))
		elapsed_usec += Time.get_ticks_usec() - begin
		if not started:
			printerr("FAIL: attempted start did not succeed at call %d" % _i)
			kobra.free()
			quit(1)
			return
		successes += 1
		combat._cancel_all_fire_sequences()
	if successes != calls:
		printerr("FAIL: successful call count %d != %d" % [successes, calls])
		kobra.free()
		quit(1)
		return
	print("json: " + JSON.stringify({"ok": true, "successes": successes,
		"calls": calls, "usec_per_success": float(elapsed_usec) / float(calls)}))
	kobra.free()
	quit(0)
