extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const HKGunTurretScene := preload("res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn")

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	var calls := 10000
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--calls="):
			calls = int(argument.trim_prefix("--calls="))
	if calls <= 0:
		printerr("FAIL: calls must be positive")
		quit(2)
		return
	var building = HKGunTurretScene.instantiate()
	root.add_child(building)
	if building.combat_turrets.size() != 1:
		printerr("FAIL: fixture has no turret")
		quit(2)
		return
	var turret = building.combat_turrets[0]
	turret.idle_scan(0.0)
	if not turret._idle_scan_active or turret._idle_scan_seconds_until_target <= 0.0:
		printerr("FAIL: first idle_scan call did not activate a positive wait")
		quit(2)
		return
	var waiting: Array[float] = []
	var expiry: Array[float] = []
	for _repeat in 3:
		var began := Time.get_ticks_usec()
		for _call in calls:
			turret.idle_scan(0.0)
		waiting.append(float(Time.get_ticks_usec() - began) / float(calls))
		began = Time.get_ticks_usec()
		for _call in calls:
			turret._idle_scan_seconds_until_target = 0.0
			turret.idle_scan(0.0)
			if turret._idle_scan_seconds_until_target <= 0.0:
				printerr("FAIL: forced expiry did not restore a positive wait")
				quit(2)
				return
		expiry.append(float(Time.get_ticks_usec() - began) / float(calls))
	print("json: ", JSON.stringify({"ok": true, "calls": calls, "waiting_us": waiting, "expiry_us": expiry}))
	building.free()
	quit(0)
