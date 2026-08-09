extends SceneTree

## Construction SFX schedules retain the XBF's authored type-9 frame timing.

const BuildingConstructionSoundScript := preload(
	"res://scripts/buildings/building_construction_sound.gd"
)
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")
const ModelXbfScript := preload("res://converters/xbf/model_xbf.gd")
const ATBarracksScene := preload("res://assets/converted/buildings/ATBarracks/ATBarracks.scn")
const ATRocketTurretScene := preload(
	"res://assets/converted/buildings/ATRocketTurret/ATRocketTurret.scn"
)
const ATSmWindtrapScene := preload(
	"res://assets/converted/buildings/ATSmWindtrap/ATSmWindtrap.scn"
)
const ATHelipadScene := preload("res://assets/converted/buildings/ATHelipad/ATHelipad.scn")
const FRCampDefinition := preload("res://resources/buildings/definitions/FRCamp.tres")
const FRCampScene := preload("res://scenes/buildings/fr_camp.tscn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	_run_case("Atreides Barracks keeps all three authored construction thuds", _test_at_barracks)
	_run_case("Atreides small construction events resolve", _test_at_small_construction)
	_run_case("Ordos construction and spark sections retain their authored frames", _test_ordos)
	_run_case("Fremen Camp gets its single source-authored fallback", _test_fremen)
	_run_case("source supplements preserve construction samples and volumes", _test_supplements)
	_run_case("every authored building construction SFX section resolves", _test_all_construction_sections_resolve)
	if _failures > 0:
		printerr("BuildingConstructionSound tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("BuildingConstructionSound tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var before := _failures
	test.call()
	if before == _failures:
		print("PASS: %s" % case_name)


func _test_at_barracks() -> void:
	var building := ATBarracksScene.instantiate() as Node3D
	_expect(building != null, "the converted ATBarracks scene must instantiate")
	if building == null:
		return
	var schedule := BuildingConstructionSoundScript.schedule_for(&"ATBarracks", building)
	_expect_events(schedule, [&"atmediumconstruction", &"mediumconstruction", &"mediumconstruction"], [0.2, 1.0, 2.75])
	for event in schedule:
		_expect_section(StringName(event.get("section", &"")), "mcv_g_building_out_1.wav", 60)
	building.free()


func _test_at_small_construction() -> void:
	_expect_scene_events(
		ATRocketTurretScene, &"ATRocketTurret",
		[&"atsmallconstruction", &"atsmallconstruction", &"atsmallconstruction"],
		[0.15, 1.15, 1.7]
	)
	_expect_scene_events(
		ATSmWindtrapScene, &"ATSmWindtrap",
		[&"atsmallconstruction", &"atsmallconstruction"], [0.55, 1.25]
	)
	_expect_scene_events(
		ATHelipadScene, &"ATHelipad",
		[&"atsmallconstruction", &"atsmallconstruction"], [0.2, 1.55]
	)


func _test_ordos() -> void:
	var model := _model(
		[_entry("construct", 0, 42)],
		[_sound(4, "ORSmallConstruction"), _sound(15, "ORConstructSpark"), _sound(21, "ORMediumConstruction"), _sound(38, "ORConstructSpark"), _sound(42, "ORSmallConstruction")]
	)
	var schedule := BuildingConstructionSoundScript.schedule_for(&"ORBarracks", model)
	_expect_events(schedule, [&"orsmallconstruction", &"orconstructspark", &"ormediumconstruction", &"orconstructspark", &"orsmallconstruction"], [0.2, 0.75, 1.05, 1.9, 2.1])
	model.free()


func _test_fremen() -> void:
	var camp_id := StringName(FRCampDefinition.get("config_id"))
	_expect(camp_id == &"FRCamp", "the original Fremen Camp definition must select the fallback target")
	var building := FRCampScene.instantiate() as Node3D
	_expect(building != null, "the converted FRCamp scene must instantiate")
	if building != null:
		_expect_events(
			BuildingConstructionSoundScript.schedule_for(camp_id, building),
			[&"frementent"], [0.85]
		)
		building.free()
	var missing_table := _model([_entry("construct", 0, 30)], [])
	_expect_events(
		BuildingConstructionSoundScript.schedule_for(camp_id, missing_table),
		[&"frementent"], [0.0]
	)
	_expect(BuildingConstructionSoundScript.schedule_for(&"ATBarracks", missing_table).is_empty(), "a missing FX table must not invent sounds for other buildings")
	missing_table.free()


func _test_supplements() -> void:
	_expect_section(&"atmediumconstruction", "mcv_g_building_out_1.wav", 60)
	_expect_section(&"atmcvdeploy", "mcv_b_open_1.wav", 60)
	_expect_section(&"atcyconstructingabuilding", "mcv_d_drill_dig_1.wav", 60)
	_expect_section(&"atconstructspark", "constructionsparks.wav", 60)
	_expect_section(&"atmcvundeploy", "mcv_e_flatten_1.wav", 80)
	_expect_section(&"frementent", "fremen_tent_build_1.wav", 80)
	_expect_section(&"hksmallconstruction", "mcv_f_scaffold_up_1.wav", 40)
	_expect_section(&"hkmediumconstruction", "mcv_g_building_out_1.wav", 40)
	_expect_section(&"hkmcvdeploy", "mcv_b_open_1.wav", 40)
	_expect_section(&"hkcyconstructingabuilding", "mcv_d_drill_dig_1.wav", 40)
	_expect_section(&"hkmcvundeploy", "mcv_e_flatten_1.wav", 80)
	_expect_section(&"ormcvundeploy", "mcv_e_flatten_1.wav", 80)
	_expect_section(&"fleshvatbirth", "tx_flesh_born_2.wav", 50)
	_expect_section(&"orconstructspark", "constructionsparks.wav", 40)
	_expect(SfxSectionCatalogScript.has_section(&"constructspark"), "ConstructSpark must resolve its original mixed sample pool")


func _test_all_construction_sections_resolve() -> void:
	var directory := DirAccess.open("res://assets/raw_original_content/3DDATA/Buildings")
	_expect(directory != null, "the original building XBF directory must be available")
	if directory == null:
		return
	var event_count := 0
	directory.list_dir_begin()
	var filename := directory.get_next()
	while not filename.is_empty():
		if not directory.current_is_dir() and filename.to_lower().ends_with("_hc.xbf"):
			var xbf = ModelXbfScript.load_file("res://assets/raw_original_content/3DDATA/Buildings/%s" % filename)
			for event: Dictionary in xbf.fx_events:
				if int(event.get("type", -1)) != 9:
					continue
				var strings := event.get("strings", []) as Array
				if strings.is_empty():
					continue
				event_count += 1
				var section := StringName(String(strings[0]).strip_edges().to_lower())
				_expect(SfxSectionCatalogScript.has_section(section), "%s must resolve %s" % [filename, section])
		filename = directory.get_next()
	directory.list_dir_end()
	_expect(event_count > 0, "the construction XBF audit must inspect authored SFX events")


func _model(entries: Array, events: Array) -> Node3D:
	var wrapper := Node3D.new()
	var model := Node3D.new()
	wrapper.add_child(model)
	model.set_meta("xbf_animation_entries", entries)
	model.set_meta("xbf_fx_events", events)
	model.set_meta("xbf_fx_events_complete", true)
	return wrapper


func _entry(name: String, start_frame: int, end_frame: int) -> Dictionary:
	return {"name": name, "start_frame": start_frame, "end_frame": end_frame}


func _sound(frame: int, section: String) -> Dictionary:
	return {"frame": frame, "type": 9, "strings": [section]}


func _expect_events(schedule: Array[Dictionary], sections: Array[StringName], times: Array[float]) -> void:
	_expect(schedule.size() == sections.size(), "expected %d events, got %s" % [sections.size(), schedule])
	for index in mini(schedule.size(), sections.size()):
		_expect(schedule[index].get("section", &"") == sections[index], "event %d section must be %s" % [index, sections[index]])
		_expect(is_equal_approx(float(schedule[index].get("time", -1.0)), times[index]), "event %d time must be %s" % [index, times[index]])


func _expect_scene_events(
		scene: PackedScene, building_id: StringName, sections: Array[StringName], times: Array[float]
	) -> void:
	var building := scene.instantiate() as Node3D
	_expect(building != null, "%s scene must instantiate" % building_id)
	if building == null:
		return
	var schedule := BuildingConstructionSoundScript.schedule_for(building_id, building)
	_expect_events(schedule, sections, times)
	for event in schedule:
		_expect_section(StringName(event.get("section", &"")), "mcv_f_scaffold_up_1.wav", 60)
	building.free()


func _expect_section(section_id: StringName, sample: String, volume: int) -> void:
	var section := SfxSectionCatalogScript.section(section_id)
	_expect(not section.is_empty(), "%s must resolve" % section_id)
	_expect(section.get("paths", []).has("res://assets/converted/audio/sfx/%s" % sample), "%s must use %s" % [section_id, sample])
	_expect(int(section.get("volume", -1)) == volume, "%s volume must be %d" % [section_id, volume])


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
