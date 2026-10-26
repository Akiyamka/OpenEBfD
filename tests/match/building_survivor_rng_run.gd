extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const SimRngScript := preload("res://scripts/sim/sim_rng.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const BuildingSurvivorsScript := preload("res://scripts/buildings/building_survivors.gd")
const CombatLingerEffectScript := preload("res://scripts/combat/combat_linger_effect.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const ATWallScene := preload("res://assets/converted/buildings/ATWall/ATWall.scn")

class NullCallLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		var message := str(code) + " " + str(rationale)
		if "null value" in message or "Nil" in message or "freed" in message or "Nonexistent function" in message:
			errors.append(message)

class LethalPayload extends RefCounted:
	var config := {}
	func linger_duration_ticks() -> float:
		return 1.0
	func linger_damage() -> float:
		return 100000.0
	func linger_damage_against(_armour: StringName) -> float:
		return 100000.0
	func id() -> StringName:
		return &"AP6Test"
	func death_category() -> StringName:
		return &""
	var visual_scene: PackedScene = null

class PartialMatch extends Node:
	var index := EntityNodeIndexScript.new()
	var state := SimEntityStateScript.new(index.registry())
	var tick := 7
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func entity_index():
		return index
	func entity_state():
		return state
	func current_tick() -> int:
		return tick

class RngStub extends PartialMatch:
	var rng = SimRngScript.new(13)
	func sim_rng():
		return rng

class FailedSceneCatalog extends "res://scripts/units/unit_scene_catalog.gd":
	func instantiate(_config_id: StringName, _fallback: PackedScene = null) -> Node:
		return null

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("S1 tick birth and audit", _test_tick_birth)
	_run_case("S2 peer and keys", _test_peer_and_keys)
	_run_case("S3 fallback and store", _test_fallback_and_store)
	_finish("Building survivor RNG tests")

func _sample(seed_value: int, building_id: int, ordinal: int, tick: int, axis: int) -> int:
	return SimRngScript._sample(seed_value, SimRngScript.PURPOSE_SURVIVOR_SCATTER,
		building_id, ordinal, tick, axis)

func _fraction(sample: int) -> float:
	return float(sample & 0xffffff) / 16777216.0

func _expected(seed_value: int, building_id: int, ordinal: int, tick: int,
		origin: Vector3, half: Vector3) -> Vector3:
	return origin + Vector3((_fraction(_sample(seed_value, building_id, ordinal, tick, 0)) * 2.0 - 1.0) * half.x,
		0.7, (_fraction(_sample(seed_value, building_id, ordinal, tick, 1)) * 2.0 - 1.0) * half.z)

func _signature(seed_value: int, building_id: int, tick: int) -> int:
	var signature := 0
	for ordinal in 3:
		for axis in 2:
			signature = (signature + _sample(seed_value, building_id, ordinal, tick, axis)) & 0xffffffff
	return signature

func _survivors(parent: Node, old_ids: Array[int]) -> Array:
	var result := []
	for child in parent.get_children():
		if child.is_in_group("units") and not old_ids.has(child.get_instance_id()):
			result.append(child)
	return result

func _old_ids(parent: Node) -> Array[int]:
	var ids: Array[int] = []
	for child in parent.get_children():
		ids.append(child.get_instance_id())
	return ids

func _boot(seed_value: int = 73):
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=%d" % seed_value])
	root.add_child(match_instance)
	match_instance.set_process(false)
	match_instance.get_node("Units/OrdosAPC").free()
	match_instance.get_node("Units/NIABTank").free()
	return match_instance

func _birth(seed_value: int, global_seed: int, lethal: bool, extra_id: bool = false, death_tick: int = 1) -> Dictionary:
	seed(global_seed)
	var match_instance = _boot(seed_value)
	var building = match_instance.get_node("Buildings/ATConYard")
	if extra_id:
		var extra = ATWallScene.instantiate()
		match_instance.get_node("Buildings").add_child(extra)
		building.free()
		building = ATConYardScene.instantiate()
		building.owner_player_id = 1
		match_instance.get_node("Buildings").add_child(building)
	if death_tick > 1:
		match_instance.advance_ticks(death_tick - 1)
	var units = match_instance.get_node("Units")
	var old := _old_ids(units)
	var origin: Vector3 = building.simulation_position()
	var half: Vector3 = BuildingSurvivorsScript._footprint_half_extents(building)
	var building_id: int = building.entity_id
	var before: Dictionary = match_instance.sim_rng().capture_audit()
	var effect = CombatLingerEffectScript.new()
	match_instance.add_child(effect)
	var configured: bool = effect.configure(LethalPayload.new(), building, building.global_position)
	if not lethal:
		building.max_health = 1000000.0
		building.health = 1000000.0
	match_instance.advance_ticks(1)
	var after: Dictionary = match_instance.sim_rng().capture_audit()
	var born := _survivors(units, old)
	var positions: Array[Vector3] = []
	var ids: Array[int] = []
	var stored := true
	var health_ok := true
	for unit in born:
		positions.append(unit.simulation_position())
		ids.append(unit.entity_id)
		stored = stored and match_instance.entity_state().has_position(unit.entity_id) and \
			PackedVector3Array([match_instance.entity_state().position(unit.entity_id)]).to_byte_array() == \
			PackedVector3Array([unit.simulation_position()]).to_byte_array()
		health_ok = health_ok and is_equal_approx(unit.health, unit.max_health * 0.7) and unit.invulnerable
	var result := {"configured": configured, "delivered": effect.delivered_ticks,
		"positions": positions, "ids": ids, "stored": stored, "health_ok": health_ok,
		"count": born.size(), "before": before, "after": after, "id": building_id,
		"tick": match_instance.current_tick(), "origin": origin, "half": half,
		"checksum": match_instance.match_checksum()}
	match_instance.free()
	return result

func _check_birth_tuple(result: Dictionary, seed_value: int) -> void:
	_expect(result.count == 3, "ATConYard must birth three survivors")
	if result.count != 3:
		return
	_expect(result.configured and result.delivered == 1 and result.tick == 1,
			"real Match tick must deliver one lethal linger pass")
	_expect(result.id > 0 and result.stored and result.health_ok,
			"positive IDs, byte-exact store positions, 70 percent HP and protection")
	_expect(result.ids.size() == 3 and result.ids[0] > 0 and result.ids[1] > 0 and result.ids[2] > 0,
			"all survivors have positive ids")
	for ordinal in 3:
		_expect(result.positions[ordinal] == _expected(seed_value, result.id, ordinal, result.tick,
			result.origin, result.half), "ordinal %d matches published X/Z tuple" % ordinal)
		_expect(_sample(seed_value, result.id, ordinal, result.tick, 0) != \
			_sample(seed_value, result.id, ordinal, result.tick, 1), "X/Z samples differ")

func _test_tick_birth() -> void:
	var control := _birth(73, 1, false)
	var killed := _birth(73, 1, true)
	_expect(control.count == 0 and control.delivered == 1, "no-kill arm receives linger without births")
	_check_birth_tuple(killed, 73)
	_expect(int(killed.after.draw_count) - int(control.after.draw_count) == 6,
		"kill minus no-kill consumes six audited draws")
	_expect(((int(killed.after.draw_signature) - int(control.after.draw_signature)) & 0xffffffff) == \
		_signature(73, killed.id, 1), "kill minus no-kill signature equals six published samples")

func _test_peer_and_keys() -> void:
	var first := _birth(73, 5, true)
	var second := _birth(73, 999, true)
	_expect(first.count == 3 and second.count == 3, "both sequential peers birth three")
	if first.count != 3 or second.count != 3:
		return
	_check_birth_tuple(first, 73)
	_check_birth_tuple(second, 73)
	_expect(first.positions == second.positions and first.ids == second.ids and \
		first.after == second.after and first.checksum == second.checksum,
		"same-seed peers ignore process global RNG and instance allocation")
	var other_seed := _birth(74, 21, true)
	var other_id := _birth(73, 21, true, true)
	_expect(other_seed.count == 3 and other_id.count == 3, "changed seed and id arms birth three")
	if other_seed.count == 3 and other_id.count == 3:
		_check_birth_tuple(other_seed, 74)
		_check_birth_tuple(other_id, 73)
		_expect(other_seed.positions != first.positions and other_id.positions != first.positions,
			"seed and positive building ID change published samples")
	var tick_two := _birth(73, 21, true, false, 2)
	_expect(tick_two.count == 3, "alternate tick fixture births three")
	if tick_two.count == 3:
		_expect(tick_two.tick == 2, "alternate birth occurs on tick two")
		for ordinal in 3:
			_expect(tick_two.positions[ordinal] == _expected(73, tick_two.id, ordinal, 2,
				tick_two.origin, tick_two.half), "tick-two tuple matches published sample")
		_expect(_sample(73, tick_two.id, 0, 1, 0) != _sample(73, tick_two.id, 0, 2, 0) and \
			_sample(73, tick_two.id, 0, 1, 0) != _sample(73, tick_two.id, 1, 1, 0),
			"alternate death tick and ordinals have distinct published samples")

func _test_fallback_and_store() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var world := Node3D.new()
	root.add_child(world)
	var standalone = ATConYardScene.instantiate()
	standalone.owner_player_id = 1
	world.add_child(standalone)
	var unrelated := PartialMatch.new()
	root.add_child(unrelated)
	_expect(standalone.entity_id == 0, "standalone remains unregistered beside unrelated Match")
	var old := _old_ids(world)
	BuildingSurvivorsScript.spawn_for_destroyed_building(standalone)
	var sentinel := true
	var born := _survivors(world, old)
	_expect(born.size() == 3, "standalone births three")
	if born.size() == 3:
		for ordinal in 3:
			_expect(born[ordinal].simulation_position() == _expected(1, 0, ordinal, 0,
				standalone.simulation_position(), BuildingSurvivorsScript._footprint_half_extents(standalone)),
				"standalone uses seed one, id zero, tick zero")
	_expect(sentinel and logger.errors.is_empty(), "standalone post-call sentinel and no null errors")
	world.free()
	unrelated.free()
	var stub := PartialMatch.new()
	root.add_child(stub)
	var building = ATConYardScene.instantiate()
	building.owner_player_id = 1
	stub.add_child(building)
	old = _old_ids(stub)
	BuildingSurvivorsScript.spawn_for_destroyed_building(building)
	sentinel = true
	born = _survivors(stub, old)
	_expect(born.size() == 3 and building.entity_id > 0, "partial Match births three with positive ID")
	if born.size() == 3:
		for ordinal in 3:
			_expect(born[ordinal].simulation_position() == _expected(1, building.entity_id, ordinal, 7,
				building.simulation_position(), BuildingSurvivorsScript._footprint_half_extents(building)),
				"partial Match uses local seed and reported tick")
	_expect(sentinel and logger.errors.is_empty(), "partial Match post-call sentinel and no null errors")
	stub.free()
	var match_instance = _boot()
	var units = match_instance.get_node("Units")
	var parent = match_instance.get_node("Buildings")
	var conyard = match_instance.get_node("Buildings/ATConYard")
	conyard.set_simulation_position(Vector3(25, 8, 19))
	conyard.global_position = Vector3(200, 8, 200)
	old = _old_ids(units)
	var before: Dictionary = match_instance.sim_rng().capture_audit()
	BuildingSurvivorsScript.spawn_for_destroyed_building(conyard)
	born = _survivors(units, old)
	_expect(born.size() == 3, "desynchronized mirror still births three")
	if born.size() == 3:
		for ordinal in 3:
			var expected := _expected(73, conyard.entity_id, ordinal, 0, Vector3(25, 8, 19),
				BuildingSurvivorsScript._footprint_half_extents(conyard))
			_expect(born[ordinal].simulation_position() == expected and \
				match_instance.entity_state().has_position(born[ordinal].entity_id) and \
				match_instance.entity_state().position(born[ordinal].entity_id) == expected,
				"store origin and birth position remain authoritative without frame delta")
	_expect(match_instance.sim_rng().draw_count - int(before.draw_count) == 6,
		"direct birth audits six draws")
	var catalog = BuildingSurvivorsScript._unit_scene_catalog
	BuildingSurvivorsScript._unit_scene_catalog = FailedSceneCatalog.new()
	before = match_instance.sim_rng().capture_audit()
	BuildingSurvivorsScript.spawn_for_destroyed_building(conyard)
	BuildingSurvivorsScript._unit_scene_catalog = catalog
	_expect(match_instance.sim_rng().capture_audit() == before,
		"failed survivor instantiation makes no audit draws")
	for scene in [ATWallScene, ATConYardScene]:
		var candidate = scene.instantiate()
		candidate.owner_player_id = 1
		if scene == ATConYardScene:
			candidate.config_id = &"MissingDefinition"
		parent.add_child(candidate)
		before = match_instance.sim_rng().capture_audit()
		BuildingSurvivorsScript.spawn_for_destroyed_building(candidate)
		_expect(match_instance.sim_rng().capture_audit() == before,
			"zero-count or missing definition makes no audit draws")
		candidate.free()
	var unsupported = ATConYardScene.instantiate()
	unsupported.owner_player_id = 0
	parent.add_child(unsupported)
	before = match_instance.sim_rng().capture_audit()
	BuildingSurvivorsScript.spawn_for_destroyed_building(unsupported)
	_expect(match_instance.sim_rng().capture_audit() == before, "unsupported house draws none")
	unsupported.free()
	match_instance.free()
	OS.remove_logger(logger)
	_expect(logger.errors.is_empty(), "all null-sensitive arms have no script errors")
