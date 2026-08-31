extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATMongooseModelScene := preload(
	"res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn"
)
const ORAATrooperModelScene := preload(
	"res://assets/converted/models/OR_AATrooper_H0/OR_AATrooper_H0.scn"
)


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case("mech Move_Stop completes on frameless match ticks", _test_move_stop_frameless)
	await _run_async_case("mech Move_Start ignores AnimationPlayer pacing", _test_move_start_pacing)
	await _run_async_case("infantry fire completion ignores AnimationPlayer pacing", _test_fire_pacing)
	_finish("Animation completion tests")


func _test_move_stop_frameless() -> void:
	var result := await _run_mech_arm(0.0, true)
	_expect(bool(result.get("started", false)), "the mech arm must reach Move before Stop")
	_expect(
		bool(result.get("stopped", false)),
		"a Stop command must reach Stationary from frameless advance_ticks()"
	)


func _test_move_start_pacing() -> void:
	var frameless := await _run_mech_arm(0.0, false)
	var paced := await _run_mech_arm(1.0, false)
	_expect(bool(frameless.get("started", false)), "the zero-advance arm must start")
	_expect(bool(paced.get("started", false)), "the completed-player arm must start")
	_expect(
		int(frameless.get("start_ticks", -1)) == int(paced.get("start_ticks", -2)),
		"Move_Start must reach Move on the same simulation tick at both frame pacings"
	)


func _test_fire_pacing() -> void:
	var frameless := await _run_fire_arm(0.0)
	var paced := await _run_fire_arm(1.0)
	_expect(bool(frameless.get("started", false)), "the zero-advance fire arm must start")
	_expect(bool(paced.get("started", false)), "the completed-player fire arm must start")
	_expect(
		int(frameless.get("completion_ticks", -1)) == int(paced.get("completion_ticks", -2)),
		"a fire sequence must start infantry reload on the same tick at both frame pacings"
	)


func _run_mech_arm(animation_pacing: float, stop_after_start: bool) -> Dictionary:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 3:
		await process_frame
	match_instance.set_process(false)
	var unit := match_instance.get_node("Units/ScoutA") as Unit
	unit.setup(&"ATMongoose")
	unit.replace_visual_scene(ATMongooseModelScene)
	var player := unit.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if player == null:
		match_instance.queue_free()
		await process_frame
		return {"started": false}
	unit.move_to(unit.global_position + Vector3.FORWARD * 30.0)
	match_instance.advance_ticks(1)
	if player.current_animation != &"Move_Start":
		match_instance.queue_free()
		await process_frame
		return {"started": false}
	var start_tick: int = match_instance.current_tick()
	if animation_pacing > 0.0:
		var animation := player.get_animation(&"Move_Start")
		player.advance((animation.length if animation != null else 0.0) + animation_pacing)
	var guard := 0
	while player.current_animation != &"Move" and guard < 100:
		match_instance.advance_ticks(1)
		guard += 1
	var started: bool = player.current_animation == &"Move"
	var result := {
		"started": started,
		"start_ticks": match_instance.current_tick() - start_tick,
	}
	if stop_after_start and started:
		unit.stop_at_current_position()
		match_instance.advance_ticks(100)
		result["stopped"] = player.current_animation != &"Move_Stop"
	match_instance.queue_free()
	await process_frame
	return result


func _run_fire_arm(animation_pacing: float) -> Dictionary:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 3:
		await process_frame
	match_instance.set_process(false)
	var unit := match_instance.get_node("Units/ScoutA") as Unit
	unit.setup(&"ORAATrooper")
	unit.replace_visual_scene(ORAATrooperModelScene)
	var turret = unit.combat_turrets[0]
	var binding: Dictionary = unit.fire_animation_binding(turret.weapon_index())
	var player := binding.get("player") as AnimationPlayer
	var animation_name := StringName(binding.get("name", &""))
	var target := unit.global_position + Vector3.FORWARD * 5.0
	var started: bool = player != null \
		and unit.command_attack(target) \
		and unit.combat()._start_authored_fire_sequence(turret, target)
	if not started:
		match_instance.queue_free()
		await process_frame
		return {"started": false}
	if animation_pacing > 0.0:
		var animation := player.get_animation(animation_name)
		player.advance((animation.length if animation != null else 0.0) + animation_pacing)
	var start_tick: int = match_instance.current_tick()
	var guard := 0
	while turret.reload_ticks_remaining <= 0 and guard < 100:
		match_instance.advance_ticks(1)
		guard += 1
	var result := {
		"started": true,
		"completion_ticks": match_instance.current_tick() - start_tick,
	}
	match_instance.queue_free()
	await process_frame
	return result
