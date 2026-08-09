extends SceneTree
## Tests for AuthoredReloadSound: picking the weapon-reload sound out of the FX
## event table baked into a model, without also picking up the shot sound the
## turret already plays.
##
## Every fixture below is transcribed from the real converted model it names
## (assets/converted/{models,buildings}/*, FX event type 9 plus the animation
## frame table) rather than invented, so a case failing means either the
## resolver or the bake changed, not that a made-up expectation drifted.

const AuthoredReloadSoundScript := preload(
	"res://scripts/combat/authored_reload_sound.gd"
)
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	_run_case("AT_Sniper: the rifle reload, not the rifle shot", _test_sniper)
	_run_case("HK_Trooper Fire_0: the bazooka reload at its authored frame", _test_trooper)
	_run_case("OR_AATrooper: Fire_0 reloads, CrouchFire does not", _test_aatrooper)
	_run_case("AT_Kindjal: the deployed cannon reloads, the travel pistol does not", _test_kindjal)
	_run_case("OR_Mortar: the reload is in Deploy_Gun, not in Deployed_Fire", _test_mortar)
	_run_case("HK_Inkvine: an authored reload with no converted section is silent", _test_inkvine)
	_run_case("ATPillbox: the repaired Idle_0 range must not steal Fire_0's reload", _test_pillbox)
	_run_case("every allowlisted section a model names resolves to real samples", _test_sections_resolve)
	_run_case("an unknown clip, missing meta or incomplete table yields no sound", _test_degenerate_inputs)
	if _failures > 0:
		printerr("AuthoredReloadSound tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("AuthoredReloadSound tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	test.call()
	# A runtime error aborts the case function where it stands, which would
	# otherwise read as a silent pass.
	if _assertions == assertions_before:
		_failures += 1
		printerr("FAIL: %s: the case ended before asserting anything" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


## Stands in for a baked model root: the three metas
## converters/model_bake_builder.gd writes, on a bare Node the resolver has to
## walk down to exactly as it would in a real unit subtree.
func _make_model(entries: Array, events: Array, complete := true) -> Node:
	var wrapper := Node3D.new()
	var model_root := Node3D.new()
	wrapper.add_child(model_root)
	model_root.set_meta("xbf_animation_entries", entries)
	model_root.set_meta("xbf_fx_events", events)
	model_root.set_meta("xbf_fx_events_complete", complete)
	return wrapper


func _entry(name: String, start_frame: int, end_frame: int) -> Dictionary:
	return {"name": name, "start_frame": start_frame, "end_frame": end_frame}


func _sound(frame: int, id: String) -> Dictionary:
	return {"frame": frame, "type": 9, "strings": [id]}


func _sections(schedule: Array[Dictionary]) -> Array:
	var result := []
	for entry in schedule:
		result.append(entry["section"])
	return result


## AT_Sniper_H0. `Fire_0` [213..289] authors the rifle shot @231 and the reload
## @258; the rifle shot is ATSniperGun's own `fire_sound_paths` (sniper_3.wav),
## already played by CombatTurret, so only the reload may come out of here.
## `Lay_Down_Fire` [290..331] repeats the pair at its own frames.
func _test_sniper() -> void:
	var model := _make_model(_sniper_entries(), _sniper_events())
	var schedule := AuthoredReloadSoundScript.schedule(model, &"Fire_0")
	_expect(
		_sections(schedule) == [&"atsniperreload"],
		"Fire_0 must yield the reload alone, got %s" % [_sections(schedule)]
	)
	if schedule.size() == 1:
		_expect(
			is_equal_approx(float(schedule[0]["time"]), 2.25),
			"the reload is authored on frame 258 of [213..289], i.e. 2.25s in, got %s" % schedule[0]["time"]
		)
	var crawl_fire := AuthoredReloadSoundScript.schedule(model, &"Lay_Down_Fire")
	_expect(
		_sections(crawl_fire) == [&"atsniperreload"],
		"Lay_Down_Fire authors the same reload, got %s" % [_sections(crawl_fire)]
	)
	if crawl_fire.size() == 1:
		_expect(
			is_equal_approx(float(crawl_fire[0]["time"]), 0.95),
			"frame 309 of [290..331] is 0.95s in, got %s" % crawl_fire[0]["time"]
		)
	model.free()


## HK_Trooper_H0 `Fire_0` [195..248]: HKBazookaLaunch1 @209 is the shot,
## HKreload @237 is hk_rocket_trooper_reload_1.wav -- the one model in the game
## that does not reload out of the shared kindjal sample.
func _test_trooper() -> void:
	var model := _make_model(
		[_entry("Fire 0", 195, 248), _entry("CrouchFire", 250, 315)],
		[
			_sound(209, "HKBazookaLaunch1"), _sound(237, "HKreload"),
			_sound(266, "HKBazookaLaunch1"),
		]
	)
	var schedule := AuthoredReloadSoundScript.schedule(model, &"Fire_0")
	_expect(
		_sections(schedule) == [&"hkreload"],
		"Fire_0 must yield HKreload alone, got %s" % [_sections(schedule)]
	)
	if schedule.size() == 1:
		_expect(
			is_equal_approx(float(schedule[0]["time"]), 2.1),
			"frame 237 of [195..248] is 2.1s in, got %s" % schedule[0]["time"]
		)
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"CrouchFire").is_empty(),
		"CrouchFire authors a launch but no reload"
	)
	model.free()


## OR_AATrooper_H0: the crouched and prone variants of the same weapon author
## only their launch, so a clip without a reload must stay silent rather than
## borrow Fire_0's.
func _test_aatrooper() -> void:
	var model := _make_model(
		[
			_entry("Fire 0", 286, 353), _entry("Crouch", 354, 354),
			_entry("CrouchFire", 355, 404), _entry("Lay Down Fire", 406, 467),
		],
		[
			_sound(304, "ORBazookaLaunch1"), _sound(338, "ORkobrareload"),
			_sound(364, "ORBazookaLaunch2"), _sound(424, "ORBazookaLaunch3"),
		]
	)
	var schedule := AuthoredReloadSoundScript.schedule(model, &"Fire_0")
	_expect(
		_sections(schedule) == [&"orkobrareload"],
		"Fire_0 must yield ORkobrareload alone, got %s" % [_sections(schedule)]
	)
	if schedule.size() == 1:
		_expect(
			is_equal_approx(float(schedule[0]["time"]), 2.6),
			"frame 338 of [286..353] is 2.6s in, got %s" % schedule[0]["time"]
		)
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"CrouchFire").is_empty(),
		"CrouchFire authors no reload"
	)
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"Lay_Down_Fire").is_empty(),
		"Lay_Down_Fire authors no reload"
	)
	model.free()


## AT_Kindjal_H0 authors two reloads and neither is in the travel-mode `Fire 0`:
## `Deploy Gun` [322..384] loads the cannon as it folds out (@374), and
## `Deployed Fire` [386..436] reloads it between shells (@429). `Deploy Gun
## Hold` [384..384] is a zero-width entry that must not confuse the range walk.
func _test_kindjal() -> void:
	var model := _make_model(_kindjal_entries(), _kindjal_events())
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"Fire_0").is_empty(),
		"the travel-mode pistol clip authors no reload"
	)
	var deployed := AuthoredReloadSoundScript.schedule(model, &"Deployed_Fire")
	_expect(
		_sections(deployed) == [&"frwarriorreload"],
		"Deployed_Fire must yield the cannon reload alone, got %s" % [_sections(deployed)]
	)
	if deployed.size() == 1:
		_expect(
			is_equal_approx(float(deployed[0]["time"]), 2.15),
			"frame 429 of [386..436] is 2.15s in, got %s" % deployed[0]["time"]
		)
	var deploying := AuthoredReloadSoundScript.schedule(model, &"Deploy_Gun")
	_expect(
		_sections(deploying) == [&"atsniperreload"],
		"Deploy_Gun loads the gun as it folds out, got %s" % [_sections(deploying)]
	)
	if deploying.size() == 1:
		_expect(
			is_equal_approx(float(deploying[0]["time"]), 2.6),
			"frame 374 of [322..384] is 2.6s in, got %s" % deploying[0]["time"]
		)
	model.free()


## OR_Mortar_H0 is the mirror image of the Kindjal: it loads the tube while
## deploying (@416 of [362..420]) but authors no reload in `Deployed Fire`
## [421..452] at all -- MortarLaunch @421 there is the shot.
func _test_mortar() -> void:
	var model := _make_model(
		[
			_entry("Fire 0", 235, 265), _entry("Deploy Gun", 362, 420),
			_entry("Deploy Gun Hold", 420, 420),
			_entry("Deployed Fire", 421, 452), _entry("Undeploy Gun", 517, 572),
		],
		[
			_sound(243, "ORSingleShotPistol"), _sound(390, "MortarDeploy"),
			_sound(416, "ORkobrareload"), _sound(421, "MortarLaunch"),
			_sound(451, "ORMortarLaunch1"), _sound(545, "MortarUnDeploy"),
		]
	)
	var deploying := AuthoredReloadSoundScript.schedule(model, &"Deploy_Gun")
	_expect(
		_sections(deploying) == [&"orkobrareload"],
		"Deploy_Gun must yield the reload, got %s" % [_sections(deploying)]
	)
	if deploying.size() == 1:
		_expect(
			is_equal_approx(float(deploying[0]["time"]), 2.7),
			"frame 416 of [362..420] is 2.7s in, got %s" % deploying[0]["time"]
		)
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"Deployed_Fire").is_empty(),
		"the mortar authors no reload between shells"
	)
	model.free()


## HK_Inkvine_H0 `Fire_0` [32..58] names `HKinkvinereload` @50, but no SFX file
## ever defined that section outside ImportedSfx.txt's unconverted `$` stub, so
## the authored reload is genuinely silent. It is still in RELOAD_SECTIONS: the
## allowlist follows the SFX data, and the silence comes from the catalog.
func _test_inkvine() -> void:
	var model := _make_model(
		[_entry("Fire 0", 32, 58), _entry("Explode", 22, 31)],
		[
			_sound(33, "Catapult"), _sound(33, "HKSmallCannonSingleShot"),
			_sound(50, "HKinkvinereload"),
		]
	)
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"Fire_0").is_empty(),
		"a reload whose section resolved to no converted WAV must be silent"
	)
	_expect(
		AuthoredReloadSoundScript.RELOAD_SECTIONS.has(&"hkinkvinereload"),
		"the section stays on the allowlist so the silence is visible, not accidental"
	)
	model.free()


## ATPillbox (AT_MGT_H0) authors an `Idle 0` [200..240] nested inside its
## `Fire 0` [193..275], which would win the tightest-range rule and swallow the
## reload @257 -- except the bake repairs `Idle_0` to the file's `Stationary`
## range [104..133] and keeps the original only as `source_*_frame`
## (docs/quirks.md). This test pins that the resolver reads the repaired range.
func _test_pillbox() -> void:
	var idle := _entry("Idle 0", 104, 133)
	idle["source_start_frame"] = 200
	idle["source_end_frame"] = 240
	var model := _make_model(
		[_entry("Stationary", 104, 133), idle, _entry("Fire 0", 193, 275)],
		[
			_sound(194, "ATMedMG-Shortburst"), _sound(227, "ATMedMG-Shortburst"),
			_sound(257, "Atsniperreload"),
		]
	)
	var schedule := AuthoredReloadSoundScript.schedule(model, &"Fire_0")
	_expect(
		_sections(schedule) == [&"atsniperreload"],
		"the pillbox reload must stay in Fire_0, got %s" % [_sections(schedule)]
	)
	if schedule.size() == 1:
		_expect(
			is_equal_approx(float(schedule[0]["time"]), 3.2),
			"frame 257 of [193..275] is 3.2s in, got %s" % schedule[0]["time"]
		)
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"Idle_0").is_empty(),
		"the repaired Idle_0 range holds no sound events at all"
	)
	model.free()


## The four sections shipped models actually name. `atsniperreload` and
## `frwarriorreload` only resolve because tools/generate_voice_feedback.py
## shadow-proofs them against ImportedSfx.txt, so this is the assertion that
## catches a regenerated manifest losing them.
func _test_sections_resolve() -> void:
	for section in [&"atsniperreload", &"frwarriorreload", &"hkreload", &"orkobrareload"]:
		var entry := SfxSectionCatalogScript.section(section)
		_expect(
			not entry.is_empty(),
			"%s must be present in the generated SFX manifest" % section
		)
		_expect(
			not Array(entry.get("paths", [])).is_empty(),
			"%s must carry at least one converted WAV" % section
		)


func _test_degenerate_inputs() -> void:
	var model := _make_model(_sniper_entries(), _sniper_events())
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"Deployed_Fire").is_empty(),
		"a clip this model never authored must yield no sound"
	)
	_expect(
		AuthoredReloadSoundScript.schedule(model, &"").is_empty(),
		"an empty clip name must yield no sound"
	)
	_expect(
		AuthoredReloadSoundScript.schedule(null, &"Fire_0").is_empty(),
		"a null model must yield no sound rather than erroring"
	)
	model.free()

	var bare := Node3D.new()
	_expect(
		AuthoredReloadSoundScript.schedule(bare, &"Fire_0").is_empty(),
		"a model with no baked FX meta at all must yield no sound"
	)
	bare.free()

	# A partial event table cannot tell "no sound authored" from "sound not
	# decoded", so it must yield nothing rather than a half-guess.
	var partial := _make_model(_sniper_entries(), _sniper_events(), false)
	_expect(
		AuthoredReloadSoundScript.schedule(partial, &"Fire_0").is_empty(),
		"an incomplete FX event table must yield no sound"
	)
	partial.free()


func _sniper_entries() -> Array:
	return [
		_entry("Fire 0", 213, 289),
		_entry("Lay Down", 290, 290),
		_entry("Lay Down Fire", 290, 331),
		_entry("Crawl", 332, 356),
	]


func _sniper_events() -> Array:
	return [
		_sound(231, "ATSingleShotRifle"), _sound(258, "Atsniperreload"),
		_sound(294, "ATSingleShotRifle"), _sound(309, "Atsniperreload"),
	]


func _kindjal_entries() -> Array:
	return [
		_entry("Fire 0", 187, 216),
		_entry("Deploy Gun", 322, 384),
		_entry("Deploy Gun Hold", 384, 384),
		_entry("Deployed Fire", 386, 436),
		_entry("Deployed Idle 0", 437, 495),
	]


func _kindjal_events() -> Array:
	return [
		_sound(195, "ATSingleShotPistol"), _sound(340, "KindjalDeploy"),
		_sound(374, "Atsniperreload"), _sound(391, "ATMortarLaunch1"),
		_sound(429, "FRwarriorreload"),
	]


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
