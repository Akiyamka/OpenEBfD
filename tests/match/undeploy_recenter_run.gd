extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const UnitScene := preload("res://scenes/units/unit.tscn")
const KobraModelScene := preload("res://assets/converted/models/OR_Kobra_H0/OR_Kobra_H0.scn")
const CombatDeployStrategyScript := preload("res://scripts/units/combat_deploy_strategy.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

class ErrorLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		var message := str(code) + " " + str(rationale)
		if "null" in message.to_lower() or "Nil" in message or "freed" in message or "Nonexistent" in message:
			errors.append(message)

var _case_completed := false


func _run_async_case(case_name: String, test: Callable) -> void:
	_case_completed = false
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	if not _case_completed or _assertions == assertions_before:
		_failures += 1
		printerr("FAIL: %s: case did not reach its final assertion" % case_name)
	elif _failures == failures_before:
		print("PASS: %s" % case_name)


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case("A1 fixed recenter and all axes gate", _test_fixed_recenter)
	await _run_async_case("A2 frames cannot decide undeploy", _test_no_frame_decision)
	await _run_async_case("A3 hold clip is repainted after a real frame", _test_repaint)
	await _run_async_case("A4 frameless and paced deadlines agree", _test_deadlines)
	await _run_async_case("A5 detached model has no pending completion or stale access", _test_detach)
	_finish("Undeploy recenter")


func _arm() -> Dictionary:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _frame in 3:
		await process_frame
	match_instance.set_process(false)
	var unit := UnitScene.instantiate() as Unit
	unit.config_id = &"ORKobra"
	unit.owner_player_id = 1
	match_instance.get_node("Units").add_child(unit)
	unit.replace_visual_scene(KobraModelScene)
	match_instance.advance_ticks(1)
	var strategy := CombatDeployStrategyScript.new()
	var result: Dictionary = strategy.try_deploy(unit)
	_expect(bool(result.get("started", false)), "real strategy must start Kobra deploy")
	var deploy_deadline: int = unit._deployment_animation_completion_ticks
	_expect(deploy_deadline > 0, "real deploy clip must schedule completion")
	match_instance.advance_ticks(deploy_deadline)
	_expect(unit.is_deployed(), "real Match ticks must complete deploy")
	var turret = unit.combat()._active_turrets()[0] if unit.combat()._active_turrets().size() == 1 else null
	_expect(turret != null and unit.is_in_group(&"sim_units"), "admitted Kobra must have deployed turret")
	if turret == null:
		return {"match": match_instance, "unit": unit, "strategy": strategy}
	turret.current_yaw = deg_to_rad(16.0)
	turret.current_pitch = deg_to_rad(6.4)
	turret.restore_aim_pose()
	result = strategy.try_undeploy(unit)
	_expect(bool(result.get("started", false)), "real strategy must start undeploy")
	return {"match": match_instance, "unit": unit, "strategy": strategy, "turret": turret}


func _close(arm: Dictionary) -> void:
	arm["match"].queue_free()
	await process_frame


func _test_fixed_recenter() -> void:
	var arm: Dictionary = await _arm()
	if not arm.has("turret"):
		await _close(arm)
		return
	var unit: Unit = arm["unit"]
	var turret = arm["turret"]
	_expect(is_equal_approx(rad_to_deg(turret.current_yaw), 16.0)
		and is_equal_approx(rad_to_deg(turret.current_pitch), 6.4), "snapshot must survive turret-set sync")
	_expect(unit._deploy.transition_player() == null and unit._deployment_animation_completion_ticks == 0,
		"clip must be absent before recenter")
	arm["match"].advance_ticks(1)
	_expect(absf(rad_to_deg(turret.current_yaw) - 12.8) < 0.02
		and absf(rad_to_deg(turret.current_pitch) - 3.2) < 0.02,
		"first admitted tick must use the authored 3.2 degree step on both axes")
	_expect(unit._deploy.transition_player() == null, "one axis still moving must block clip")
	arm["match"].advance_ticks(3)
	_expect(unit._deploy.transition_player() == null, "yaw still moving must block clip after pitch centers")
	arm["match"].advance_ticks(1)
	_expect(is_zero_approx(turret.current_yaw) and is_zero_approx(turret.current_pitch), "both axes must center")
	_expect(unit._deploy.transition_player() != null and unit._deploy._transition_animation == &"Undeploy_Gun",
		"Undeploy_Gun must start on the centering tick")
	await _close(arm)
	_case_completed = true


func _test_no_frame_decision() -> void:
	var arm: Dictionary = await _arm()
	if not arm.has("turret"):
		await _close(arm)
		return
	var unit: Unit = arm["unit"]
	var turret = arm["turret"]
	var angles := Vector2(turret.current_yaw, turret.current_pitch)
	var countdown: int = unit._deployment_animation_completion_ticks
	var held: bool = bool(unit._navigation_system._agents.get(unit.get_instance_id(), {}).get("hold", false))
	_expect(held, "undeploy must hold the registered navigation agent")
	for _frame in 6:
		unit._process(0.1)
	await create_timer(0.05).timeout
	_expect(Vector2(turret.current_yaw, turret.current_pitch).is_equal_approx(angles), "frames must not turn logical axes")
	_expect(unit._deploy.transition_player() == null and unit._deployment_animation_completion_ticks == countdown,
		"frames must not select clip or advance countdown")
	_expect(unit.is_deploying() and bool(unit._navigation_system._agents.get(unit.get_instance_id(), {}).get("hold", false)),
		"frames must leave the navigation hold in place")
	await _close(arm)
	_case_completed = true


func _test_repaint() -> void:
	var arm: Dictionary = await _arm()
	if not arm.has("turret"):
		await _close(arm)
		return
	var unit: Unit = arm["unit"]
	var turret = arm["turret"]
	arm["match"].advance_ticks(1)
	var pivot := turret._yaw_pivot as Node3D
	_expect(pivot != null, "real Kobra must expose a yaw pivot")
	if pivot == null:
		await _close(arm)
		return
	var tick_pose := pivot.transform
	var angles := Vector2(turret.current_yaw, turret.current_pitch)
	var player: AnimationPlayer = null
	if player == null:
		for candidate in unit.visual_root.find_children("*", "AnimationPlayer", true, false):
			if candidate.has_animation(&"Deploy_Gun_Hold"):
				player = candidate
				break
	_expect(player != null, "real hold animation player must exist")
	if player != null:
		player.play(&"Deploy_Gun_Hold")
		player.advance(0.1)
		_expect(not pivot.transform.is_equal_approx(tick_pose), "hold clip must overwrite recenter pose")
		await create_timer(0.05).timeout
		_expect(pivot.transform.is_equal_approx(tick_pose), "real frame must restore the tick pose")
		_expect(Vector2(turret.current_yaw, turret.current_pitch).is_equal_approx(angles), "repaint must not turn logical axes")
	await _close(arm)
	_case_completed = true


func _test_deadlines() -> void:
	var outcomes: Array[Dictionary] = []
	for paced in [false, true]:
		var arm: Dictionary = await _arm()
		if not arm.has("turret"):
			await _close(arm)
			continue
		var unit: Unit = arm["unit"]
		var start_tick := 0
		for tick in 12:
			if paced:
				for _frame in 3:
					unit._process(0.1)
			arm["match"].advance_ticks(1)
			if unit._deploy.transition_player() != null:
				start_tick = tick + 1
				break
		_expect(unit.is_deploying() and not unit.prepare_navigation_order(unit.global_position + Vector3(10, 0, 0)),
				"recenter gate must lock orders")
		_expect(bool(unit._navigation_system._agents.get(unit.get_instance_id(), {}).get("hold", false)),
				"navigation hold must stay set through recenter gate")
		_expect(start_tick == 5, "clip must start on tick five in each arm")
		var player := unit._deploy.transition_player()
		_expect(player != null and unit._deploy._transition_animation == &"Undeploy_Gun",
			"real Undeploy_Gun player must own the clip")
		if player == null:
			await _close(arm)
			continue
		var animation := player.get_animation(&"Undeploy_Gun")
		_expect(animation != null, "real Undeploy_Gun animation must exist")
		if animation == null:
			await _close(arm)
			continue
		var deadline: int = unit._deployment_animation_completion_ticks
		var authored_deadline := maxi(int(ceilf(
			animation.length / maxf(absf(player.speed_scale), 0.01)
				/ MatchClockScript.SECONDS_PER_TICK
		)), 1)
		_expect(deadline > 1 and deadline == authored_deadline,
			"queued deadline must equal the authored Undeploy_Gun length in ticks")
		var completion_tick := 0
		for elapsed in deadline + 2:
			var before_frames: int = unit._deployment_animation_completion_ticks
			if paced:
				for _frame in 3:
					unit._process(0.1)
				_expect(unit.is_deploying() and unit._deployment_animation_completion_ticks == before_frames,
					"clip frames must not advance completion or release the unit")
			arm["match"].advance_ticks(1)
			if not unit.is_deploying():
				completion_tick = start_tick + elapsed + 1
				break
			_expect(unit._deployment_animation_completion_ticks == deadline - elapsed - 1,
				"only a Match tick may decrement the clip deadline")
			_expect(not unit.prepare_navigation_order(unit.global_position + Vector3(10, 0, 0)),
				"clip must lock movement orders")
			_expect(bool(unit._navigation_system._agents.get(unit.get_instance_id(), {}).get("hold", false)),
				"navigation hold must stay set through the clip")
		_expect(completion_tick == start_tick + deadline,
			"completion must occur on the authored final tick in each arm")
		_expect(not unit.is_deployed() and unit._deployment_animation_completion_ticks == 0,
			"completion must return to travel with no countdown")
		_expect(not bool(unit._navigation_system._agents.get(unit.get_instance_id(), {}).get("hold", true)),
			"completion tick must release the navigation hold")
		_expect(unit.prepare_navigation_order(unit.global_position + Vector3(10, 0, 0)),
			"released unit must accept a movement order")
		outcomes.append({"start": start_tick, "deadline": deadline, "completion": completion_tick})
		await _close(arm)
	_expect(outcomes.size() == 2, "both frameless and paced arms must finish")
	if outcomes.size() == 2:
		_expect(outcomes[0] == outcomes[1],
			"frameless and paced arms must share clip-start, deadline, and completion ticks")
	_case_completed = true


func _test_detach() -> void:
	var arm: Dictionary = await _arm()
	if not arm.has("turret"):
		await _close(arm)
		return
	var unit: Unit = arm["unit"]
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	unit.prepare_model_for_corpse(unit.visual_root.get_child(0))
	for _tick in 7:
		unit._deploy.advance_undeploy_tick()
		unit._deploy.restore_undeploy_alignment_pose()
	OS.remove_logger(logger)
	_expect(unit._deploy._recentering_turrets.is_empty(), "corpse handoff must clear recenter list")
	_expect(unit._deploy.transition_player() == null and unit._deployment_animation_completion_ticks == 0,
		"detached model must not queue even a clipless completion")
	_expect(logger.errors.is_empty(), "detached hooks must not call through stale pivots")
	await _close(arm)
	_case_completed = true
