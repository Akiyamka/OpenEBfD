extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const SimRngScript := preload("res://scripts/sim/sim_rng.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const CombatDeployStrategyScript := preload("res://scripts/units/combat_deploy_strategy.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const UnitScene := preload("res://scenes/units/unit.tscn")
const KobraModel := preload("res://assets/converted/models/OR_Kobra_H0/OR_Kobra_H0.scn")
const KindjalModel := preload("res://assets/converted/models/AT_Kindjal_H0/AT_Kindjal_H0.scn")
const MongooseModel := preload("res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn")

class NullCallLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		if "null value" in str(code) or "Nil" in str(code) or "freed" in str(code) or "Nonexistent function" in str(code) or "null value" in str(rationale):
			errors.append(str(code) + " " + str(rationale))

class PartialMatch extends Node:
	var index := EntityNodeIndexScript.new()
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func entity_index():
		return index

class UnrelatedRngMatch extends Node:
	var rng = SimRngScript.new(998)
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func sim_rng():
		return rng

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("T-key: exact tuple, audit and refusals", _test_key_and_refusals)
	_run_case("I-index and R-order: production selector canonicalizes", _test_selector)
	_run_case("T-key: distinct entity ids use distinct keyed samples", _test_unit_ids)
	_run_case("F-fallback: standalone and partial Match never borrow RNG", _test_fallback)
	var rebind_logger := NullCallLogger.new()
	OS.add_logger(rebind_logger)
	_run_case("A2 rebind: ordinal survives model lifecycle", _test_rebind)
	OS.remove_logger(rebind_logger)
	_expect(rebind_logger.errors.is_empty(), "A2 rebind: no escaped null-call or freed-player error")
	var deploy_logger := NullCallLogger.new()
	OS.add_logger(deploy_logger)
	_run_case("D-deploy: live state switches clips without refresh", _test_deploy)
	OS.remove_logger(deploy_logger)
	_expect(deploy_logger.errors.is_empty(), "D-deploy: no null-call or freed-player script errors")
	_run_case("P-pair: same-seed Matches ignore global RNG", _test_pair)
	_run_case("W-tick: real Match tick starts authored Kobra fire", _test_tick)
	_run_case("L-length: private longer Fire_2 changes completion tick", _test_length)
	_finish("Unit fire variant RNG tests")

func _unit(id: StringName, scene: PackedScene, parent: Node = root):
	var unit = UnitScene.instantiate()
	unit.config_id = id
	parent.add_child(unit)
	unit.replace_visual_scene(scene)
	return unit

func _sample(seed_value: int, unit_id: int, weapon: int, ordinal: int) -> int:
	return SimRngScript._sample(seed_value, SimRngScript.PURPOSE_FIRE_VARIANT, unit_id, weapon, ordinal, 0)

func _state_name(unit, weapon: int) -> String:
	var state: Dictionary = unit.combat()._weapon_fire_sequences.get(weapon, {})
	return String(state.get("animation", ""))

func _test_key_and_refusals() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=1"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	var kobra = _unit(&"ORKobra", KobraModel, match_instance.get_node("Units"))
	var combat = kobra.combat()
	var turret = kobra.combat_turrets[0]
	var rng = match_instance.sim_rng()
	_expect(kobra.entity_id > 0 and rng != null, "T-key: real Match owns positive ID and RNG")
	var before: Dictionary = rng.capture_audit()
	_expect(String(kobra.fire_animation_binding(0).get("name", "")) == "Fire_0", "T-key: read-only query is canonical")
	_expect(rng.capture_audit() == before, "T-key: read-only query draws nothing")
	for ordinal in 4:
		var started: bool = combat._start_authored_fire_sequence(turret, Vector3(20, 0, 20))
		var expected_name := "Fire_0" if _sample(1, kobra.entity_id, 0, ordinal) % 2 == 0 else "Fire_2"
		_expect(started and _state_name(kobra, 0) == expected_name,
			"T-key: ordinal %d uses exact PURPOSE_FIRE_VARIANT tuple" % ordinal)
		_expect(rng.draw_count == int(before["draw_count"]) + ordinal + 1 and
			rng.draw_signature == ((int(before["draw_signature"]) + _signature(1, kobra.entity_id, ordinal + 1)) & 0xffffffff),
			"T-key: one audited bounded sample per successful sequence")
		var audit: Dictionary = rng.capture_audit()
		_expect(not combat._start_authored_fire_sequence(turret, Vector3(20, 0, 20)),
			"T-key: active sequence refuses restart")
		_expect(combat._fire_sequence_ordinals[0] == ordinal + 1 and rng.capture_audit() == audit,
			"T-key: active refusal preserves ordinal and audit")
		combat._cancel_all_fire_sequences()
	var saved: Dictionary = rng.capture_audit()
	_expect(not combat._start_authored_fire_sequence(turret, 17), "T-key: invalid target refuses")
	_expect(combat._fire_sequence_ordinals[0] == 4 and rng.capture_audit() == saved,
		"T-key: invalid target preserves ordinal and audit")
	combat._weapon_fire_sequences[1] = {"blocking": true}
	_expect(not combat._start_authored_fire_sequence(turret, Vector3(20, 0, 20)),
		"T-key: other blocking sequence refuses travel start")
	combat._weapon_fire_sequences.erase(1)
	_expect(combat._fire_sequence_ordinals[0] == 4 and rng.capture_audit() == saved,
		"T-key: blocking conflict preserves ordinal and audit")
	_expect(combat._start_authored_fire_sequence(turret, Vector3(20, 0, 20)) and
		_state_name(kobra, 0) == ("Fire_0" if _sample(1, kobra.entity_id, 0, 4) % 2 == 0 else "Fire_2"),
		"T-key: next real start uses unchanged ordinal after refusals")
	combat._cancel_all_fire_sequences()
	match_instance.free()

func _signature(seed_value: int, unit_id: int, count: int) -> int:
	var result := 0
	for ordinal in count:
		result = (result + _sample(seed_value, unit_id, 0, ordinal)) & 0xffffffff
	return result

func _test_selector() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=1"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	var mongoose = _unit(&"ATMongoose", MongooseModel, match_instance.get_node("Units"))
	var source: Dictionary = mongoose.fire_animation_binding(0)
	var player := source.get("player") as AnimationPlayer
	_expect(player != null, "I-index: real Mongoose binding exists")
	if player == null:
		match_instance.free()
		return
	var library := player.get_animation_library(&"").duplicate(true) as AnimationLibrary
	player.remove_animation_library(&"")
	player.add_animation_library(&"", library)
	library.add_animation(&"Fire_2", library.get_animation(&"Fire_0").duplicate(true))
	var first: Array[Dictionary] = [{"player": player, "name": &"Fire_0"}, {"player": player, "name": &"Fire_2"}]
	var reverse: Array[Dictionary] = [first[1], first[0]]
	var rng = match_instance.sim_rng()
	var before: Dictionary = rng.capture_audit()
	seed(1)
	var a: Dictionary = mongoose.combat()._select_fire_binding(0, first)
	var after_a: Dictionary = rng.capture_audit()
	var b: Dictionary = mongoose.combat()._select_fire_binding(0, reverse)
	var after_b: Dictionary = rng.capture_audit()
	_expect(mongoose.entity_id == 6 and a.get("name") == &"Fire_0" and b.get("name") == a.get("name"),
		"R-order: reversed candidates select same canonical name")
	_expect(int(after_a["draw_count"]) == int(before["draw_count"]) + 1 and
		int(after_b["draw_count"]) == int(after_a["draw_count"]) + 1 and
		int(after_a["draw_signature"]) == ((int(before["draw_signature"]) + _sample(1, 6, 0, 0)) & 0xffffffff) and
		int(after_b["draw_signature"]) == ((int(after_a["draw_signature"]) + _sample(1, 6, 0, 0)) & 0xffffffff),
		"R-order: both orders audit the same exact tuple")
	seed(2)
	var c: Dictionary = mongoose.combat()._select_fire_binding(1, first)
	var after_c: Dictionary = rng.capture_audit()
	_expect(c.get("name") == &"Fire_2" and _sample(1, 6, 1, 0) % 2 == 1,
		"I-index: weapon one selects its exact different keyed name")
	_expect(int(after_c["draw_count"]) == int(after_b["draw_count"]) + 1 and
		int(after_c["draw_signature"]) == ((int(after_b["draw_signature"]) + _sample(1, 6, 1, 0)) & 0xffffffff),
		"I-index: second weapon key reaches audited selector")
	match_instance.free()

func _test_unit_ids() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=3"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	var first = _unit(&"ORKobra", KobraModel, match_instance.get_node("Units"))
	var second = _unit(&"ORKobra", KobraModel, match_instance.get_node("Units"))
	var before: Dictionary = match_instance.sim_rng().capture_audit()
	var started_a: bool = first.combat()._start_authored_fire_sequence(first.combat_turrets[0], Vector3(20, 0, 20))
	var started_b: bool = second.combat()._start_authored_fire_sequence(second.combat_turrets[0], Vector3(20, 0, 20))
	_expect(first.entity_id == 6 and second.entity_id == 7 and started_a and started_b and
		_state_name(first, 0) == "Fire_2" and _state_name(second, 0) == "Fire_0",
		"T-key: different positive entity ids select independent exact names")
	var rng = match_instance.sim_rng()
	_expect(rng.draw_count == int(before["draw_count"]) + 2 and
		rng.draw_signature == ((int(before["draw_signature"]) +
		_sample(3, 6, 0, 0) + _sample(3, 7, 0, 0)) & 0xffffffff),
		"T-key: both entity samples enter the same Match audit")
	match_instance.free()

func _test_fallback() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var standalone = _unit(&"ORKobra", KobraModel)
	var started: bool = standalone.combat()._start_authored_fire_sequence(standalone.combat_turrets[0], Vector3(20, 0, 20))
	OS.remove_logger(logger)
	_expect(started and _state_name(standalone, 0) == "Fire_0", "F-fallback: standalone seed one and key zero work")
	_expect(logger.errors.is_empty(), "F-fallback: standalone has no null-call script errors")
	_expect(standalone.combat()._fire_sequence_ordinals.get(0, 0) == 1, "F-fallback: post-call sentinel ran")
	standalone.free()
	var stub := PartialMatch.new()
	root.add_child(stub)
	var unrelated := UnrelatedRngMatch.new()
	root.add_child(unrelated)
	OS.add_logger(logger)
	var child = _unit(&"ORKobra", KobraModel, stub)
	var child_started: bool = child.combat()._start_authored_fire_sequence(child.combat_turrets[0], Vector3(20, 0, 20))
	OS.remove_logger(logger)
	var expected := "Fire_0" if _sample(1, child.entity_id, 0, 0) % 2 == 0 else "Fire_2"
	_expect(child.entity_id > 0 and child_started and _state_name(child, 0) == expected,
		"F-fallback: partial Match uses positive ID and local seed")
	_expect(logger.errors.is_empty(), "F-fallback: partial Match has no null-call errors")
	_expect(unrelated.rng.draw_count == 0 and MatchLookupScript.sim_rng(child) == null,
		"F-fallback: partial Match never borrows another grouped Match's RNG")
	_expect(child.combat()._fire_sequence_ordinals.get(0, 0) == 1, "F-fallback: partial post-call sentinel ran")
	stub.free()
	unrelated.free()

func _test_rebind() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var kobra = _unit(&"ORKobra", KobraModel)
	var combat = kobra.combat()
	var first: Dictionary = kobra.fire_animation_binding(0)
	var old_player := first.get("player") as AnimationPlayer
	var started: bool = combat._start_authored_fire_sequence(kobra.combat_turrets[0], Vector3(20, 0, 20))
	combat._cancel_all_fire_sequences()
	combat.detach_model()
	var empty_after_detach: bool = combat._fire_overlay.player_for(0) == null and combat._weapon_fire_sequences.is_empty()
	kobra.replace_visual_scene(KobraModel)
	var next: Dictionary = kobra.fire_animation_binding(0)
	var raw_next: Variant = next.get("player")
	var next_valid: bool = is_instance_valid(raw_next) and raw_next is AnimationPlayer
	_expect(next_valid and kobra.visual_root.is_ancestor_of(raw_next),
		"A2 rebind: current binding belongs to the new model subtree")
	if not next_valid:
		OS.remove_logger(logger)
		_expect(combat._fire_sequence_ordinals.get(0, 0) == 1,
			"A2 rebind: rejected stale player preserves next ordinal")
		kobra.free()
		return
	var new_player := raw_next as AnimationPlayer
	var rebound: bool = combat._start_authored_fire_sequence(kobra.combat_turrets[0], Vector3(20, 0, 20))
	OS.remove_logger(logger)
	_expect(started and rebound and _state_name(kobra, 0) == "Fire_2", "A2 rebind: next ordinal survives model swap")
	_expect(empty_after_detach and new_player != null and new_player != old_player and kobra.visual_root.is_ancestor_of(new_player),
		"A2 rebind: next player is in new subtree; no old model list remains")
	_expect(logger.errors.is_empty(), "A2 rebind: no freed-player or null-call error")
	_expect(combat._fire_sequence_ordinals.get(0, 0) == 2, "A2 rebind: post-call sentinel ran")
	combat._cancel_all_fire_sequences()
	kobra.setup(&"ORKobra")
	kobra.replace_visual_scene(KobraModel)
	_expect(combat._fire_sequence_ordinals.get(0, 0) == 2, "A2 setup: same live unit preserves ordinal")
	var after_setup: bool = combat._start_authored_fire_sequence(kobra.combat_turrets[0], Vector3(20, 0, 20))
	_expect(after_setup and _state_name(kobra, 0) == "Fire_2" and
		combat._fire_sequence_ordinals.get(0, 0) == 3,
		"A2 setup: next successful start uses ordinal two")
	kobra.free()
	var detached = UnitScene.instantiate()
	detached.combat()._fire_sequence_ordinals[0] = 2
	detached.setup(&"ORKobra")
	_expect(detached.combat()._fire_sequence_ordinals.get(0, 0) == 2,
		"A2 setup: outside-tree early return retains the live object's ordinal")
	detached.free()

func _test_deploy() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=2"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	var strategy := CombatDeployStrategyScript.new()
	var kobra = _unit(&"ORKobra", KobraModel, match_instance.get_node("Units"))
	var kindjal = _unit(&"ATKindjal", KindjalModel, match_instance.get_node("Units"))
	var rng = match_instance.sim_rng()
	var combat = kobra.combat()
	seed(2)
	var first: bool = combat._start_authored_fire_sequence(kobra.combat_turrets[0], Vector3(20, 0, 20))
	_expect(first and _state_name(kobra, 0) == "Fire_2" and
		_sample(2, kobra.entity_id, 0, 0) % 2 == 1,
		"D-deploy: first Kobra travel start is calibrated Fire_2")
	combat._cancel_all_fire_sequences()
	for unit in [kobra, kindjal]:
		var started_transition: Dictionary = strategy.try_deploy(unit)
		unit.emit_deployment_animation_finished()
		var active: Array = unit.combat()._active_turrets()
		var before: Dictionary = rng.capture_audit()
		var started := false
		if active.size() == 1:
			started = unit.combat()._start_authored_fire_sequence(active[0], Vector3(20, 0, 20))
		var weapon: int = active[0].weapon_index() if active.size() == 1 else -1
		_expect(bool(started_transition.get("started", false)) and unit.is_deployed() and started,
			"D-deploy: deployed state starts on newly active turret")
		_expect(_state_name(unit, weapon) == "Deployed_Fire", "D-deploy: live enumeration selects Deployed_Fire")
		_expect(rng.capture_audit() == before, "D-deploy: singleton has no fire-variant draw")
		_expect(unit.combat()._fire_sequence_ordinals.get(weapon, 0) == 1,
			"D-deploy: successful deployed start advances its own weapon ordinal")
		unit.combat()._cancel_all_fire_sequences()
	var transition: Dictionary = strategy.try_undeploy(kobra)
	kobra.emit_deployment_animation_finished()
	var before_return: Dictionary = rng.capture_audit()
	seed(2)
	var back: bool = combat._start_authored_fire_sequence(kobra.combat_turrets[0], Vector3(20, 0, 20))
	_expect(bool(transition.get("started", false)) and back and not kobra.is_deployed(),
		"D-deploy: travel start succeeds after undeploy without refresh")
	var expected := "Fire_0" if _sample(2, kobra.entity_id, 0, 1) % 2 == 0 else "Fire_2"
	_expect(_state_name(kobra, 0) == expected, "D-deploy: preserved travel ordinal picks expected clip")
	_expect(rng.draw_count == int(before_return["draw_count"]) + 1 and
		rng.draw_signature == ((int(before_return["draw_signature"]) + _sample(2, kobra.entity_id, 0, 1)) & 0xffffffff),
		"D-deploy: return travel makes one audited draw")
	_expect(combat._fire_sequence_ordinals.get(0, 0) == 2, "D-deploy: post-call travel sentinel ran")
	match_instance.free()

func _test_pair() -> void:
	var a := _pair_arm(73, 0)
	var b := _pair_arm(73, 12)
	_expect(a["names"] == b["names"] and a["shots"] == b["shots"] and
		a["audit"] == b["audit"] and a["id"] == b["id"],
		"P-pair: same seeded Matches have identical named stream and audit")
	var expected: Array[String] = []
	for ordinal in 3:
		expected.append("Fire_0" if _sample(73, a["id"], 0, ordinal) % 2 == 0 else "Fire_2")
	_expect(a["names"] == expected and a["shots"] == [0.05, 0.05, 0.05],
		"P-pair: stream is the expected keyed name, not just equal")
	_expect(int(a["audit"]["draw_count"]) == 3 and
		int(a["audit"]["draw_signature"]) == _signature(73, a["id"], 3),
		"P-pair: three successful sequences have exact shared Match audit")

func _pair_arm(seed_value: int, noise_count: int) -> Dictionary:
	var noise: Array[Node] = []
	for index in noise_count:
		var extra := Node.new()
		root.add_child(extra)
		noise.append(extra)
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=%d" % seed_value])
	root.add_child(match_instance)
	match_instance.set_process(false)
	var kobra = _unit(&"ORKobra", KobraModel, match_instance.get_node("Units"))
	var names: Array[String] = []
	var shots: Array[float] = []
	for ordinal in 3:
		seed(1 if (noise_count + ordinal) % 2 == 0 else 2)
		var started: bool = kobra.combat()._start_authored_fire_sequence(kobra.combat_turrets[0], Vector3(20, 0, 20))
		_expect(started, "P-pair: real sequence starts")
		var state: Dictionary = kobra.combat()._weapon_fire_sequences.get(0, {})
		names.append(String(state.get("animation", "")))
		var schedule: Array = state.get("shot_times", [])
		shots.append(float(schedule[0]["time"]) if not schedule.is_empty() else -1.0)
		kobra.combat()._cancel_all_fire_sequences()
	var result := {"names": names, "shots": shots,
		"audit": match_instance.sim_rng().capture_audit(), "id": kobra.entity_id}
	match_instance.free()
	for extra in noise:
		extra.free()
	return result

func _test_tick() -> void:
	var control = MatchFixtureScene.instantiate()
	control.match_seed_args_for_test = PackedStringArray(["--match-seed=2"])
	root.add_child(control)
	control.set_process(false)
	var control_before: Dictionary = control.sim_rng().capture_audit()
	control.advance_ticks(1)
	var control_after: Dictionary = control.sim_rng().capture_audit()
	control.free()
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=2"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	var kobra = _unit(&"ORKobra", KobraModel, match_instance.get_node("Units"))
	kobra.owner_player_id = 1
	var emission: Dictionary = kobra.combat_turrets[0].peek_emission()
	var target = Doubles.PhysicsCombatTarget.new(
		Vector3(emission["position"]) + Vector3(emission["direction"]).normalized() * 10.0
	)
	match_instance.add_child(target)
	var accepted: bool = kobra.command_attack(target)
	_expect(accepted, "W-tick: in-range Kobra attack order accepted")
	var rng = match_instance.sim_rng()
	var before: Dictionary = rng.capture_audit()
	var selected := ""
	var selected_tick := -1
	for tick in 45:
		match_instance.advance_ticks(1)
		selected = _state_name(kobra, 0)
		if not selected.is_empty():
			selected_tick = tick + 1
			break
	_expect(kobra.entity_id == 6 and _sample(2, 6, 0, 0) % 2 == 1 and
		selected_tick == 1 and selected == "Fire_2",
		"W-tick: Match tick selects calibrated Fire_2 on tick one")
	var after: Dictionary = rng.capture_audit()
	var fire_signature: int = (
		int(after["draw_signature"]) - int(before["draw_signature"])
		- int(control_after["draw_signature"]) + int(control_before["draw_signature"])
	) & 0xffffffff
	_expect(int(after["draw_count"]) - int(before["draw_count"]) ==
		int(control_after["draw_count"]) - int(control_before["draw_count"]) + 1 and
		fire_signature == _sample(2, 6, 0, 0),
		"W-tick: fire-attributable audit is exactly one known sample")
	var state: Dictionary = kobra.combat()._weapon_fire_sequences.get(0, {})
	var shots: Array = state.get("shot_times", [])
	_expect(shots.size() == 1 and is_equal_approx(float(shots[0]["time"]), 0.05),
		"W-tick: authored shot is scheduled at 0.05 clip seconds")
	match_instance.advance_ticks(1)
	_expect(int(state.get("next_shot", 0)) == 1,
		"W-tick: scheduled shot commits on the next 25 Hz tick")
	_expect(kobra.combat()._fire_sequence_ordinals.get(0, 0) == 1,
		"W-tick: tick path advanced one successful sequence ordinal")
	match_instance.free()

func _test_length() -> void:
	var plain: Dictionary = _length_arm(false)
	var longer: Dictionary = _length_arm(true)
	_expect(bool(plain.get("started", false)) and bool(longer.get("started", false)) and
		plain.get("name") == "Fire_2" and longer.get("name") == "Fire_2",
		"L-length: ordinal one selects Fire_2 in both fresh standalone units")
	_expect(is_equal_approx(float(plain.get("duration", 0.0)), 0.55) and
		is_equal_approx(float(longer.get("duration", 0.0)), 1.05),
		"L-length: only fixture-private Fire_2 has longer duration")
	_expect(int(longer.get("ticks", 0)) > int(plain.get("ticks", 0)) and
		int(plain.get("ticks", 0)) == 11 and int(longer.get("ticks", 0)) == 21,
		"L-length: authored duration changes sequence completion tick")

func _length_arm(longer: bool) -> Dictionary:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var kobra = _unit(&"ORKobra", KobraModel)
	var no_match: bool = MatchLookupScript.sim_rng(kobra) == null
	var binding: Dictionary = kobra.fire_animation_binding(0)
	var player := binding.get("player") as AnimationPlayer
	var result := {"started": false, "name": "", "duration": 0.0, "ticks": 0}
	if player == null:
		OS.remove_logger(logger)
		_expect(false, "L-length: model player must exist")
		kobra.free()
		return result
	var library := player.get_animation_library(&"").duplicate(true) as AnimationLibrary
	player.remove_animation_library(&"")
	player.add_animation_library(&"", library)
	var private_second := library.get_animation(&"Fire_2").duplicate(true) as Animation
	if longer:
		private_second.length = 1.05
	library.remove_animation(&"Fire_2")
	library.add_animation(&"Fire_2", private_second)
	kobra.combat().refresh_weapon_runtime()
	var combat = kobra.combat()
	var turret = kobra.combat_turrets[0]
	var first: bool = combat._start_authored_fire_sequence(turret, Vector3(20, 0, 20))
	combat._cancel_all_fire_sequences()
	seed(2)
	var second: bool = combat._start_authored_fire_sequence(turret, Vector3(20, 0, 20))
	var state: Dictionary = combat._weapon_fire_sequences.get(0, {})
	result["started"] = first and second
	result["name"] = String(state.get("animation", ""))
	result["duration"] = float(state.get("duration", 0.0))
	for tick in 50:
		if combat._weapon_fire_sequences.is_empty():
			break
		combat._advance_fire_sequences(0.04)
		result["ticks"] = tick + 1
	OS.remove_logger(logger)
	_expect(no_match and logger.errors.is_empty(), "L-length: standalone has no Match or null-call error")
	_expect(combat._fire_sequence_ordinals.get(0, 0) == 2, "L-length: post-call sentinel ran")
	kobra.free()
	return result
