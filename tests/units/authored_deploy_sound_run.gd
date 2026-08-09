extends SceneTree

## Transition-only type-9 schedules for the three combat-deploy units.  These
## fixtures preserve the authored XBF frame ranges/events, including unrelated
## launches and reloads which must never leak into transition audio.

const AuthoredDeploySoundScript := preload("res://scripts/units/authored_deploy_sound.gd")
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	_run_case("Kindjal uses its authored deploy and undeploy frames", _test_kindjal)
	_run_case("Mortar uses its authored deploy and undeploy frames", _test_mortar)
	_run_case("Kobra falls back at the first frame in either direction", _test_kobra)
	_run_case("unknown clips, partial tables and absent sections stay silent", _test_degenerate)
	if _failures > 0:
		printerr("AuthoredDeploySound tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("AuthoredDeploySound tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var before := _failures
	test.call()
	if before == _failures:
		print("PASS: %s" % case_name)


func _test_kindjal() -> void:
	var model := _make_model(
		[_entry("Deploy Gun", 322, 384), _entry("Undeploy Gun", 496, 572)],
		[
			_sound(340, "KindjalDeploy"), _sound(374, "Atsniperreload"),
			_sound(523, "KindjalUnDeploy"), _sound(540, "GunHit"),
		]
	)
	_expect_schedule(
		AuthoredDeploySoundScript.schedule(&"ATKindjal", model, &"Deploy_Gun"),
		&"kindjaldeploy", 0.9, "Kindjal deploy"
	)
	_expect_schedule(
		AuthoredDeploySoundScript.schedule(&"ATKindjal", model, &"Undeploy_Gun"),
		&"kindjalundeploy", 1.35, "Kindjal undeploy"
	)
	model.free()


func _test_mortar() -> void:
	var model := _make_model(
		[_entry("Deploy Gun", 362, 420), _entry("Undeploy Gun", 517, 572)],
		[
			_sound(390, "MortarDeploy"), _sound(416, "ORkobrareload"),
			_sound(545, "MortarUnDeploy"), _sound(551, "GunHit2"),
		]
	)
	_expect_schedule(
		AuthoredDeploySoundScript.schedule(&"ORMortar", model, &"Deploy_Gun"),
		&"mortardeploy", 1.4, "Mortar deploy"
	)
	_expect_schedule(
		AuthoredDeploySoundScript.schedule(&"ORMortar", model, &"Undeploy_Gun"),
		&"mortarundeploy", 1.4, "Mortar undeploy"
	)
	model.free()


func _test_kobra() -> void:
	var bare := Node3D.new()
	for clip in [&"Deploy_Gun", &"Undeploy_Gun"]:
		_expect_schedule(
			AuthoredDeploySoundScript.schedule(&"ORKobra", bare, clip),
			&"klunkair.wav", 0.0, "Kobra %s fallback" % clip
		)
	_expect(
		AuthoredDeploySoundScript.schedule(&"ATKindjal", bare, &"Deploy_Gun").is_empty(),
		"Kindjal must not invent Kobra's no-event fallback"
	)
	_expect(
		AuthoredDeploySoundScript.schedule(&"ORMortar", bare, &"Undeploy_Gun").is_empty(),
		"Mortar must not invent Kobra's no-event fallback"
	)
	_expect(
		AuthoredDeploySoundScript.schedule(&"ATMCV", bare, &"Deploy_Gun").is_empty(),
		"MCV must never receive combat-deploy fallback audio"
	)
	bare.free()


func _test_degenerate() -> void:
	var model := _make_model([_entry("Deploy Gun", 10, 20)], [_sound(12, "UnknownSection")])
	_expect(
		AuthoredDeploySoundScript.schedule(&"ATKindjal", model, &"Deploy_Gun").is_empty(),
		"an unrelated or missing SFX section must not become a transition sound"
	)
	_expect(
		AuthoredDeploySoundScript.schedule(&"ORMortar", model, &"Unknown").is_empty(),
		"an unknown clip must be silent"
	)
	model.free()
	var partial := _make_model([_entry("Deploy Gun", 10, 20)], [_sound(12, "MortarDeploy")], false)
	_expect(
		AuthoredDeploySoundScript.schedule(&"ORMortar", partial, &"Deploy_Gun").is_empty(),
		"an incomplete FX table must be silent"
	)
	partial.free()
	_expect(SfxSectionCatalogScript.has_section(&"kindjaldeploy"), "source Kindjal deploy section resolves")
	_expect(SfxSectionCatalogScript.has_section(&"kindjalundeploy"), "source Kindjal undeploy section resolves")


func _make_model(entries: Array, events: Array, complete := true) -> Node:
	var wrapper := Node3D.new()
	var model := Node3D.new()
	wrapper.add_child(model)
	model.set_meta("xbf_animation_entries", entries)
	model.set_meta("xbf_fx_events", events)
	model.set_meta("xbf_fx_events_complete", complete)
	return wrapper


func _entry(name: String, start_frame: int, end_frame: int) -> Dictionary:
	return {"name": name, "start_frame": start_frame, "end_frame": end_frame}


func _sound(frame: int, section: String) -> Dictionary:
	return {"frame": frame, "type": 9, "strings": [section]}


func _expect_schedule(schedule: Array[Dictionary], section: StringName, time: float, label: String) -> void:
	_expect(schedule.size() == 1, "%s expected one event, got %s" % [label, schedule])
	if schedule.size() == 1:
		_expect(schedule[0]["section"] == section, "%s section must be %s" % [label, section])
		_expect(is_equal_approx(float(schedule[0]["time"]), time), "%s time must be %s" % [label, time])


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
