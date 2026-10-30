extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const SimRngScript := preload("res://scripts/sim/sim_rng.gd")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const WebSocketFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")
const MoundScene := preload("res://scenes/world/spice_mound.tscn")
const DefinitionScript := preload("res://scripts/world/map/spice_mound_definition.gd")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const CarryallScene := preload("res://scenes/units/atadv_carryall.tscn")
const MinotaurusScene := preload("res://scenes/units/at_minotaurus.tscn")
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")
const CombatLineOfFireScript := preload("res://scripts/combat/combat_line_of_fire.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const SimAdmissionQueueScript := preload("res://scripts/match/sim_admission_queue.gd")
const MatchUnitSpatialIndexScript := preload("res://scripts/match/match_unit_spatial_index.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")

class NullCallLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		var message := str(code) + " " + str(rationale)
		if "null value" in message or "Nil" in message or "Nonexistent function" in message:
			errors.append(message)

class PartialMatch extends Node3D:
	var index := EntityNodeIndexScript.new()
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func current_tick() -> int:
		return 1
	func entity_index():
		return index
	func unit_spatial_index():
		return null

class SeedMatch extends PartialMatch:
	var rng = SimRngScript.new(456)
	func sim_rng():
		return rng

class ContactMatch extends Node3D:
	var index := EntityNodeIndexScript.new()
	var state := SimEntityStateScript.new(index.registry())
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func current_tick() -> int:
		return 1
	func entity_index():
		return index
	func entity_state():
		return state

class CountingIndex extends EntityNodeIndexScript:
	var visits := 0
	func id_for(node: Node) -> int:
		visits += 1
		return super.id_for(node)

class CountingMatch extends ContactMatch:
	var queue := SimAdmissionQueueScript.new()
	var spatial
	func _init() -> void:
		index = CountingIndex.new()
		state = SimEntityStateScript.new(index.registry())
		spatial = MatchUnitSpatialIndexScript.new(self, index, state, queue)
	func unit_spatial_index():
		return spatial

class KeyMatch extends ContactMatch:
	var tick := 1
	var queue := SimAdmissionQueueScript.new()
	func current_tick() -> int:
		return tick
	func admission_queue():
		return queue

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case("S1: gathered seed gate", _test_start_gate)
	_run_case("S1b: absent Match services", _test_absent_services)
	_run_case("S1c: removed pending mound", _test_queued)
	_run_case("required maturity fraction", _test_required_fraction)
	await _run_async_case("S2: keyed peers and cycle", _test_peers)
	await _run_async_case("S3: contact boundary", _test_contact)
	await _run_async_case("S3: store authority", _test_store_authority)
	await _run_async_case("S3: repeat and priority", _test_repeat_priority)
	await _run_async_case("S3: high aircraft and carried cargo", _test_air_and_carried)
	await _run_async_case("S3: dead, missing profile and unadmitted", _test_exclusions)
	await _run_async_case("S4: Match wiring/spice", _test_wiring)
	await _run_async_case("S5: movement arrival tick", _test_movement)
	await _run_async_case("S6: mixed contacts and membership", _test_mixed_contacts)
	await _run_async_case("S7: same-tick store revision", _test_same_tick_revision)
	await _run_async_case("S8: partial and standalone services", _test_partial_and_standalone)
	await _run_async_case("S9: two Match snapshots", _test_two_matches)
	await _run_async_case("S10: bounded warmed visits", _test_bounded_visits)
	await _run_async_case("S11: first admitted tick", _test_first_admitted_tick)
	await _run_async_case("S12: warm key matrix", _test_warm_key_matrix)
	_finish("Spice mound RNG/contact tests")

func _expected(seed_value: int, cell: Vector2i, ordinal: int, config: Resource) -> int:
	var sample := SimRngScript._sample(seed_value, SimRngScript.PURPOSE_SPICE_MATURITY, cell.x, cell.y, ordinal, 0)
	var fraction := float(sample & 0xffffff) / 16777216.0
	return roundi((config.maturity_minimum_ticks + config.maturity_random_ticks * fraction) * 3.0 * 25.0 / 60.0)

func _boot(seed_value: int = 456):
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=%d" % seed_value])
	root.add_child(match_instance)
	match_instance.set_process(false)
	return match_instance

func _mounds(match_instance) -> Array:
	var result := []
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			result.append(mound)
	result.sort_custom(func(a, b): return a.source_cell.x < b.source_cell.x or (a.source_cell.x == b.source_cell.x and a.source_cell.y < b.source_cell.y))
	return result

func _fixed_mound(parent: Node, centre: Vector3, cell := Vector2i(4, 5)):
	var definition = DefinitionScript.new()
	definition.maturity_minimum_ticks = 1000
	definition.maturity_random_ticks = 500
	var mound = MoundScene.instantiate()
	mound.configure(cell, Vector2(4.0, 4.0), definition, 0.5)
	parent.add_child(mound)
	mound.global_position = centre
	return mound

func _test_start_gate() -> void:
	var hub := LoopbackHubScript.new()
	var endpoint = hub.add_endpoint(&"match")
	var match_instance = WebSocketFixtureScene.instantiate()
	match_instance.local_player_id_for_test = 2
	match_instance.net_room_url_for_test = "ws://test/room"
	match_instance.net_player_count_for_test = 2
	match_instance.transport_override = endpoint
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	var mounds := _mounds(match_instance)
	match_instance.get_node("Units/OrdosAPC").free()
	match_instance.get_node("Units/NIABTank").free()
	var rng = match_instance.sim_rng()
	var before: Dictionary = rng.capture_audit()
	for mound in mounds:
		mound.sim_tick()
	var pending := true
	for mound in mounds:
		pending = pending and mound._cycle_pending and mound.maturity_ticks_remaining == 0
	var pre_audit: Dictionary = rng.capture_audit()
	var blocked: int = match_instance.advance_ticks(1)
	var peer_endpoint = hub.add_endpoint(&"peer2")
	peer_endpoint.open("")
	var bus := SimCommandBusScript.new()
	bus.input_delay_ticks = 2
	var peer = TurnSchedulerScript.new(bus, peer_endpoint, 1, ChecksumExchangeScript.new())
	peer.begin_gathering(2, 320)
	peer.set_start_proposal(456)
	peer.begin_turn_barrier(2, 320)
	for now_msec in [0, 20, 40, 320, 340, 360]:
		match_instance.turn_scheduler().poll_gathering(now_msec)
		peer.poll_gathering(now_msec)
		hub.step()
	peer.announce_horizon(8)
	hub.step()
	match_instance.turn_scheduler().advance_tick(0)
	var admitted: int = match_instance.advance_ticks(1)
	_expect(mounds.size() == 2 and pending and blocked == 0 and before == pre_audit, "follower mounds stay pending with seed zero")
	_expect(admitted == 1 and match_instance.match_seed() == 456, "START binds before first tick")
	var exact := true
	for mound in mounds:
		exact = exact and mound._cycle_ordinal == 0 and mound.maturity_ticks_remaining == _expected(456, mound.source_cell, 0, mound.config) - 1
	_expect(exact and rng.draw_count - int(before["draw_count"]) == 2, "map source keys make exactly two first-tick draws: exact=%s audit=%s before=%s mounds=%s" % [exact, rng.capture_audit(), before, mounds.map(func(m): return [m.source_cell, m.maturity_ticks_remaining, m._maturity_cycle_ticks])])
	match_instance.queue_free()
	await process_frame

func _test_absent_services() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var bare: Node = _fixed_mound(root, Vector3.ZERO)
	bare.configure(Vector2i(4, 5), Vector2(4.0, 4.0))
	var pre: Dictionary = bare._local_rng.capture_audit()
	bare.sim_tick()
	var first: int = bare._maturity_cycle_ticks
	bare.activate(false)
	bare.sim_tick()
	var second: int = bare._maturity_cycle_ticks
	var audit: Dictionary = bare._local_rng.capture_audit()
	var bare_config: Resource = bare.config
	bare.free()
	var stub := PartialMatch.new()
	root.add_child(stub)
	var mound = MoundScene.instantiate()
	mound.configure(Vector2i(4, 5), Vector2(4.0, 4.0))
	stub.add_child(mound)
	var unit = ATAPCScene.instantiate()
	stub.add_child(unit)
	unit.set_simulation_position(mound.global_position)
	var stub_pre: Dictionary = mound._local_rng.capture_audit()
	mound.sim_tick()
	var stub_audit: Dictionary = mound._local_rng.capture_audit()
	var stub_duration: int = mound._maturity_cycle_ticks
	OS.remove_logger(logger)
	_expect(pre["draw_count"] == 0 and first == _expected(1, Vector2i(4, 5), 0, bare_config) and second == _expected(1, Vector2i(4, 5), 1, bare_config), "persistent local seed uses independent cycle keys")
	_expect(audit["draw_count"] == 2 and stub_pre["draw_count"] == 0 and stub_audit["draw_count"] == 1 and stub_duration == _expected(1, Vector2i(4, 5), 0, mound.config), "local audits and partial-stub duration use exact seed-one key")
	_expect(unit.entity_id > 0 and mound._overlapping_ids.is_empty() and logger.errors.is_empty(), "partial Match has no store contact or null call")
	stub.free()

func _test_queued() -> void:
	var stub := SeedMatch.new()
	root.add_child(stub)
	var mound = MoundScene.instantiate()
	mound.configure(Vector2i(4, 5), Vector2(4.0, 4.0))
	stub.add_child(mound)
	var before := stub.rng.capture_audit()
	mound.queue_free()
	mound.sim_tick()
	_expect(mound._cycle_pending and mound.maturity_ticks_remaining == 0 and stub.rng.capture_audit() == before, "queued pending mound does not arm")
	stub.free()

func _test_peers() -> void:
	var a := await _peer_arm(456, 11, 0)
	var b := await _peer_arm(456, 9999, 3)
	var c := await _peer_arm(457, 17, 1)
	_expect(a["durations"] == b["durations"] and a["next"] == b["next"] and a["audit"] == b["audit"] and a["bloom"] == b["bloom"] and a["stage"] == b["stage"] and a["spice"] == b["spice"], "global seed and rendered frames do not alter keyed cycles, bloom, stage or spice cell")
	_expect(a["stage_expected"] and b["stage_expected"] and a["spice"] > 0 and a["rejected"] and b["rejected"], "natural bloom stages a positive spice cell on its scheduled tick; rejected contact consumes no key")
	_expect(a["durations"] != c["durations"] or a["next"] != c["next"], "different Match seed changes the predicted sample")
	_expect(a["exact"] and b["exact"] and c["exact"], "both source cells and ordinals match independent samples")

func _peer_arm(seed_value: int, global_seed: int, frames: int) -> Dictionary:
	seed(global_seed)
	var match_instance = _boot(seed_value)
	for _i in frames:
		await process_frame
		match_instance.set_process(false)
	var mounds := _mounds(match_instance)
	match_instance.advance_ticks(1)
	var durations := []
	var next := []
	var exact := mounds.size() == 2
	var bloom: Array = []
	mounds[0].activated.connect(func(_m, early, fraction): bloom.append([match_instance.current_tick(), early, fraction]))
	for mound in mounds:
		durations.append(mound._maturity_cycle_ticks)
		exact = exact and mound._maturity_cycle_ticks == _expected(seed_value, mound.source_cell, 0, mound.config)
	mounds[0].maturity_ticks_remaining = 1
	match_instance.advance_ticks(1)
	match_instance.advance_ticks(1)
	for mound in mounds:
		next.append(mound._maturity_cycle_ticks)
		exact = exact and mound._maturity_cycle_ticks == _expected(seed_value, mound.source_cell, mound._cycle_ordinal, mound.config)
	var audit: Dictionary = match_instance.sim_rng().capture_audit()
	var rejected: bool = not mounds[0].activate(true) and audit == match_instance.sim_rng().capture_audit() and mounds[0]._cycle_ordinal == 1
	var layer = match_instance.terrain.spice_layer
	var job: Dictionary = layer.spread()._active.get(mounds[0].source_cell, {})
	var chosen: Dictionary = {}
	for entry: Dictionary in job.get("cells", []):
		if int(entry["amount"]) > 0:
			chosen = entry
			break
	var stages: Array = []
	layer.spice_spread_stage.connect(func(cell, stage, _total, changed):
		if cell == mounds[0].source_cell:
			stages.append([match_instance.current_tick(), stage, changed])
	)
	var spice := 0
	var stage_expected := false
	if not chosen.is_empty():
		layer.set_spice(chosen["cell"], 0)
		var interval: int = layer.spread().interval_ticks(mounds[0].config)
		match_instance.advance_ticks(interval * int(chosen["stage"]))
		spice = layer.spice_at(chosen["cell"])
		for event: Array in stages:
			if event[0] == 2 + interval * int(chosen["stage"]) and event[1] == chosen["stage"]:
				stage_expected = true
	var result := {"durations": durations, "next": next, "exact": exact, "audit": audit, "bloom": bloom, "stage": stages, "spice": spice, "stage_expected": stage_expected, "rejected": rejected}
	match_instance.queue_free()
	await process_frame
	return result

func _test_contact() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var match_instance = _boot()
	var unit = match_instance.get_node("Units/ScoutA")
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	match_instance.advance_ticks(1)
	var blooms: Array = []
	mound.activated.connect(func(_m, early, fraction): blooms.append([early, fraction]))
	unit.set_simulation_position(Vector3(220.0, 8.0, 200.0))
	mound.sim_tick()
	mound.body_entered.emit(unit)
	var before := blooms.size()
	unit.set_simulation_position(mound.global_position)
	mound.sim_tick()
	var first: int = blooms.size()
	mound.maturity_ticks_remaining = 1
	mound.sim_tick()
	var natural: bool = blooms.size() == 2 and blooms[1][0] == false and blooms[1][1] == 1.0
	OS.remove_logger(logger)
	_expect(before == 0 and first == 1 and blooms[0][0], "signal cannot bloom; store entry can bloom without physics")
	_expect(natural and logger.errors.is_empty(), "natural maturity has priority over a sustained overlap")
	match_instance.queue_free()
	await process_frame

func _test_wiring() -> void:
	var match_instance = _boot()
	var mounds := _mounds(match_instance)
	var mound = mounds[0]
	var unit = match_instance.get_node("Units/ScoutA")
	var blooms: Array = []
	mound.activated.connect(func(_m, early, fraction): blooms.append([match_instance.current_tick(), early, fraction]))
	unit.set_simulation_position(mound.global_position)
	match_instance.advance_ticks(1)
	var layer = match_instance.terrain.spice_layer
	var jobs: Dictionary = layer.spread()._active
	var job: Dictionary = jobs.get(mound.source_cell, {})
	var chosen: Dictionary = {}
	for entry: Dictionary in job.get("cells", []):
		if int(entry["amount"]) > 0:
			chosen = entry
			break
	var stages: Array = []
	layer.spice_spread_stage.connect(func(cell, stage, _total, changed):
		if cell == mound.source_cell:
			stages.append([stage, changed])
	)
	var original_spice := -1
	if not chosen.is_empty():
		layer.set_spice(chosen["cell"], 0)
		original_spice = layer.spice_at(chosen["cell"])
		match_instance.advance_ticks(layer.spread().interval_ticks(mound.config) * int(chosen["stage"]))
	var gained: bool = not chosen.is_empty() and layer.spice_at(chosen["cell"]) > original_spice
	mound.maturity_ticks_remaining = floori(mound._maturity_cycle_ticks * 0.6)
	match_instance.advance_ticks(1)
	_expect(blooms.size() == 1 and blooms[0][0] == 1 and blooms[0][1], "Match mound walk blooms from tick-one store contact and sustained overlap stays consumed")
	_expect(not job.is_empty() and not chosen.is_empty() and gained and not stages.is_empty(), "Match layer walk stages a positive spice cell")
	match_instance.queue_free()
	await process_frame

func _test_movement() -> void:
	var match_instance = _boot()
	var unit = match_instance.get_node("Units/ScoutA")
	match_instance.advance_ticks(1)
	match_instance._unit_navigation_system.unregister_unit(unit)
	var mound = _fixed_mound(match_instance, Vector3(210.0, 0.0, 210.0))
	match_instance.advance_ticks(1)
	var radius: float = unit.combat_line_bounds()["radius"]
	var start: Vector3 = mound.global_position + Vector3(2.0 + radius + 1.0, 0.0, 0.0)
	unit.set_simulation_position(start)
	var blooms: Array[int] = []
	mound.activated.connect(func(_m, _early, _fraction): blooms.append(match_instance.current_tick()))
	unit.move_to(mound.global_position)
	var arrival := -1
	var bounds: Dictionary = unit.combat_line_bounds()
	var was_outside := not _literal_overlap(start, radius, float(bounds["min_y"]), float(bounds["max_y"]), mound.global_position)
	for _i in 200:
		var pre: Vector3 = match_instance.entity_state().position(unit.entity_id)
		match_instance.advance_ticks(1)
		var post: Vector3 = match_instance.entity_state().position(unit.entity_id)
		var pre_inside := _literal_overlap(pre, radius, float(bounds["min_y"]), float(bounds["max_y"]), mound.global_position)
		var post_inside := _literal_overlap(post, radius, float(bounds["min_y"]), float(bounds["max_y"]), mound.global_position)
		if was_outside and not pre_inside and post_inside:
			arrival = match_instance.current_tick()
			break
		was_outside = not post_inside
	var managed_at_arrival: bool = unit.is_navigation_managed()
	if arrival > 0:
		_assert_paired(match_instance, mound, "S5 first arrival tick")
	match_instance.advance_ticks(1)
	if arrival > 0:
		_assert_parity(match_instance, mound, "S5 following tick")
	_expect(not managed_at_arrival and not unit.is_navigation_managed() and unit.is_in_group(&"sim_units"), "mover remains unmanaged and admitted through arrival and following tick")
	_expect(arrival > 0 and blooms.size() == 1 and blooms[0] == arrival, "post-movement first overlap blooms on arrival tick: arrival=%d blooms=%s position=%s" % [arrival, blooms, unit.simulation_position()])
	match_instance.queue_free()
	await process_frame

func _test_store_authority() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var match_instance = _boot()
	var unit = match_instance.get_node("Units/ScoutA")
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	match_instance.advance_ticks(1)
	var blooms := [0]
	mound.activated.connect(func(_m, _early, _fraction): blooms[0] += 1)
	unit.set_simulation_position(Vector3(220.0, 8.0, 200.0))
	unit.global_position = mound.global_position
	mound.sim_tick()
	var outside_count: int = blooms[0]
	unit.set_simulation_position(mound.global_position)
	unit.global_position = Vector3(220.0, 8.0, 200.0)
	mound.sim_tick()
	OS.remove_logger(logger)
	_expect(outside_count == 0 and blooms[0] == 1 and logger.errors.is_empty(), "store outside/node inside rejects, then store inside/node outside blooms")
	match_instance.queue_free()
	await process_frame

func _test_repeat_priority() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var match_instance = _boot()
	var unit = match_instance.get_node("Units/ScoutA")
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	match_instance.advance_ticks(1)
	var blooms: Array = []
	mound.activated.connect(func(_m, early, fraction): blooms.append([early, fraction]))
	unit.set_simulation_position(mound.global_position)
	mound.sim_tick()
	mound.maturity_ticks_remaining = 500
	mound.sim_tick()
	var sustained: int = blooms.size()
	unit.set_simulation_position(Vector3(220.0, 8.0, 200.0))
	mound.sim_tick()
	unit.set_simulation_position(mound.global_position)
	mound.maturity_ticks_remaining = mound._maturity_cycle_ticks
	mound.sim_tick()
	var rejected: int = blooms.size()
	unit.set_simulation_position(Vector3(220.0, 8.0, 200.0))
	mound.sim_tick()
	unit.set_simulation_position(mound.global_position)
	mound.maturity_ticks_remaining = floori(mound._maturity_cycle_ticks * 0.7)
	mound.sim_tick()
	var repeated: int = blooms.size()
	unit.set_simulation_position(Vector3(220.0, 8.0, 200.0))
	mound.sim_tick()
	unit.set_simulation_position(mound.global_position)
	mound.maturity_ticks_remaining = 1
	mound.sim_tick()
	OS.remove_logger(logger)
	_expect(sustained == 1 and rejected == 1 and repeated == 2, "entry is consumed until exit; repeat needs at least thirty percent")
	_expect(blooms.size() == 3 and blooms[2][0] == false and blooms[2][1] == 1.0 and logger.errors.is_empty(), "same-tick natural maturity beats fresh contact")
	match_instance.queue_free()
	await process_frame

func _test_air_and_carried() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var match_instance = _boot()
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	var aircraft = CarryallScene.instantiate()
	aircraft.owner_player_id = 1
	match_instance.get_node("Units").add_child(aircraft)
	var cargo = ATAPCScene.instantiate()
	cargo.owner_player_id = 1
	match_instance.get_node("Units").add_child(cargo)
	match_instance.advance_ticks(1)
	var blooms := [0]
	mound.activated.connect(func(_m, _early, _fraction): blooms[0] += 1)
	aircraft.set_simulation_position(mound.global_position + Vector3.UP * 40.0)
	cargo.set_simulation_position(mound.global_position)
	cargo._set_transport_carrier(aircraft)
	mound.sim_tick()
	var stored: Vector3 = match_instance.entity_state().position(cargo.entity_id)
	var carried: bool = match_instance.entity_state().combat_line_carried(cargo.entity_id)
	OS.remove_logger(logger)
	_expect(aircraft.entity_id > 0 and cargo.entity_id > 0 and cargo.is_carried() and carried and stored == mound.global_position, "real cargo remains stored inside while carried")
	_expect(blooms[0] == 0 and logger.errors.is_empty(), "high aircraft and carried cargo cannot activate ground mound")
	match_instance.queue_free()
	await process_frame


func _test_required_fraction() -> void:
	var mound = MoundScene.instantiate()
	var defaults := -1
	for method: Dictionary in mound.get_method_list():
		if method.get("name", "") == "maturity_duration_ticks":
			defaults = (method.get("default_args", []) as Array).size()
	_expect(defaults == 0, "maturity_duration_ticks requires its fraction argument")
	mound.free()


func _literal_overlap(position: Vector3, radius: float, min_y: float, max_y: float, centre: Vector3) -> bool:
	var dx := maxf(absf(position.x - centre.x) - 2.0, 0.0)
	var dz := maxf(absf(position.z - centre.z) - 2.0, 0.0)
	return dx * dx + dz * dz <= radius * radius and position.y + max_y >= centre.y and position.y + min_y <= centre.y + 4.0


func _test_exclusions() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var match_instance = _boot()
	var unit = match_instance.get_node("Units/ScoutA")
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	match_instance.advance_ticks(1)
	unit.set_simulation_position(mound.global_position)
	var blooms := [0]
	mound.activated.connect(func(_m, _early, _fraction): blooms[0] += 1)
	unit.health = 0.0
	mound.sim_tick()
	var dead_count: int = blooms[0]
	unit.health = unit.max_health
	var store = match_instance.entity_state()
	store.set_health(unit.entity_id, 0.0)
	mound.sim_tick()
	var store_dead_count: int = blooms[0]
	var live_mirror: bool = unit.health > 0.0
	store.set_health(unit.entity_id, unit.max_health)
	var bounds: Dictionary = unit.combat_line_bounds()
	store._combat_line_bounds_has_value[unit.entity_id] = 0
	mound.sim_tick()
	var missing_count: int = blooms[0]
	store.set_combat_line_bounds(unit.entity_id, bounds["radius"], bounds["min_y"], bounds["max_y"])
	unit.remove_from_group(&"sim_units")
	mound.sim_tick()
	var unadmitted_count: int = blooms[0]
	unit.add_to_group(&"sim_units")
	mound.sim_tick()
	OS.remove_logger(logger)
	_expect(dead_count == 0 and store_dead_count == 0 and live_mirror and missing_count == 0 and unadmitted_count == 0 and blooms[0] == 1, "only a store-live admitted unit with an authored profile may enter")
	_expect(logger.errors.is_empty(), "exclusion paths make no null call")
	match_instance.queue_free()
	await process_frame


func _oracle(match_instance: Node, mound: Node3D) -> Array[int]:
	var result: Array[int] = []
	var index = match_instance.entity_index()
	var state = match_instance.entity_state()
	var centre: Vector3 = mound.global_position
	var half_x: float = mound._footprint.x * 0.5
	var half_z: float = mound._footprint.y * 0.5
	var top: float = centre.y + maxf(minf(mound._footprint.x, mound._footprint.y), 0.5)
	for body in get_nodes_in_group(&"sim_units"):
		if not match_instance.is_ancestor_of(body) or not body is UnitScript or body.is_queued_for_deletion():
			continue
		var id: int = index.id_for(body)
		if id <= 0 or not state.has_position(id) or not state.has_combat_line_bounds(id):
			continue
		if not state.has_health(id) or state.health(id) <= 0.0:
			continue
		if state.has_combat_line_carried(id) and state.combat_line_carried(id):
			continue
		var position: Vector3 = state.position(id)
		var radius: float = state.combat_line_radius(id)
		var dx := maxf(absf(position.x - centre.x) - half_x, 0.0)
		var dz := maxf(absf(position.z - centre.z) - half_z, 0.0)
		if dx * dx + dz * dz <= radius * radius and position.y + state.combat_line_max_y(id) >= centre.y and position.y + state.combat_line_min_y(id) <= top:
			result.append(id)
	result.sort()
	return result


func _assert_parity(match_instance: Node, mound: Node3D, label: String) -> void:
	var expected := _oracle(match_instance, mound)
	var centre: Vector3 = mound.global_position
	var raw := CombatLineOfFireScript.rectangle_candidates(match_instance, self, Vector2(centre.x - 2.0, centre.z - 2.0), Vector2(centre.x + 2.0, centre.z + 2.0))
	for id in expected:
		_expect(raw.has(id), "%s: raw grid must contain oracle id %d" % [label, id])
	_expect(mound._contact_entries() == expected, "%s: final entries must equal independent oracle" % label)


func _assert_paired(match_instance: Node, mound: Node3D, label: String) -> void:
	var state = match_instance.entity_state()
	var index = match_instance.entity_index()
	for body in get_nodes_in_group(&"sim_units"):
		if match_instance.is_ancestor_of(body):
			var id: int = index.id_for(body)
			if id > 0 and state.has_position(id):
				state.set_position(id, state.position(id))
				break
	var rng = match_instance.sim_rng() if match_instance.has_method("sim_rng") else null
	var audit: Dictionary = rng.capture_audit() if rng != null else {}
	var expected := _oracle(match_instance, mound)
	_expect(not CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self), "%s: stored write makes contact cold" % label)
	var cold: Array[int] = mound._contact_entries()
	var centre: Vector3 = mound.global_position
	var half_x: float = mound._footprint.x * 0.5
	var half_z: float = mound._footprint.y * 0.5
	var raw := CombatLineOfFireScript.rectangle_candidates(match_instance, self, Vector2(centre.x - half_x, centre.z - half_z), Vector2(centre.x + half_x, centre.z + half_z))
	for id in expected:
		_expect(raw.has(id), "%s: warm raw grid contains oracle id %d" % [label, id])
	_expect(CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self), "%s: explicit prewarm accepted" % label)
	var warm: Array[int] = mound._contact_entries()
	_expect(cold == expected and warm == expected and cold == warm, "%s: cold/warm entries equal independent oracle" % label)
	_expect(rng == null or rng.capture_audit() == audit, "%s: contact paths consume no RNG draw" % label)


func _test_mixed_contacts() -> void:
	var match_instance = _boot()
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	var units = match_instance.get_node("Units")
	var a = match_instance.get_node("Units/ScoutA")
	var b = ATAPCScene.instantiate()
	b.owner_player_id = 1
	units.add_child(b)
	var aircraft = CarryallScene.instantiate()
	aircraft.owner_player_id = 1
	units.add_child(aircraft)
	var cargo = ATAPCScene.instantiate()
	cargo.owner_player_id = 1
	units.add_child(cargo)
	var minotaurus = MinotaurusScene.instantiate()
	minotaurus.owner_player_id = 1
	units.add_child(minotaurus)
	var queued = ATAPCScene.instantiate()
	queued.owner_player_id = 1
	units.add_child(queued)
	match_instance.advance_ticks(1)
	a.set_simulation_position(mound.global_position)
	var store = match_instance.entity_state()
	a.global_position = Vector3(240.0, 8.0, 240.0)
	_assert_paired(match_instance, mound, "stored inside node outside")
	a.global_position = mound.global_position
	store.set_position(a.entity_id, Vector3(240.0, 8.0, 240.0))
	_assert_paired(match_instance, mound, "stored outside node inside")
	store.set_position(a.entity_id, mound.global_position)
	var radius: float = 2.0
	store.set_combat_line_bounds(b.entity_id, radius, -1.0, 1.0)
	b.set_simulation_position(mound.global_position + Vector3(2.0 + radius, 0.0, 0.0))
	aircraft.set_simulation_position(mound.global_position + Vector3.UP * 40.0)
	cargo.set_simulation_position(mound.global_position)
	cargo._set_transport_carrier(aircraft)
	queued.set_simulation_position(mound.global_position)
	queued.queue_free()
	var large_radius: float = minotaurus.combat_line_bounds()["radius"]
	minotaurus.set_simulation_position(mound.global_position + Vector3(2.0 + large_radius - 0.01, 0.0, 0.0))
	_assert_paired(match_instance, mound, "tangent and high aircraft")
	var raw_cargo := CombatLineOfFireScript.rectangle_candidates(match_instance, self, Vector2(198.0, 198.0), Vector2(202.0, 202.0))
	var minotaurus_hits := 0
	for id in raw_cargo:
		if id == minotaurus.entity_id:
			minotaurus_hits += 1
	_expect(not raw_cargo.has(cargo.entity_id) and cargo.is_carried() and match_instance.entity_state().position(cargo.entity_id) == mound.global_position, "stored overlapping cargo stays out of raw grid")
	_expect(minotaurus_hits == 1 and mound._contact_entries().has(minotaurus.entity_id), "large-radius multi-cell unit appears once and contacts")
	_expect(not mound._contact_entries().has(queued.entity_id), "queued Unit is excluded before frame teardown")
	minotaurus.set_simulation_position(Vector3(240.0, 8.0, 240.0))
	var tangent: bool = mound._contact_entries().has(b.entity_id)
	b.set_simulation_position(mound.global_position + Vector3(2.0 + radius + 0.001, 0.0, 0.0))
	_assert_paired(match_instance, mound, "epsilon outside")
	_expect(not mound._contact_entries().has(b.entity_id), "epsilon outside is excluded")
	store.set_combat_line_bounds(b.entity_id, 0.1, -1.0, 1.0)
	b.set_simulation_position(mound.global_position + Vector3(3.9, 0.0, 3.9))
	var raw_false_positive := CombatLineOfFireScript.rectangle_candidates(match_instance, self, Vector2(198.0, 198.0), Vector2(202.0, 202.0))
	_expect(raw_false_positive.has(b.entity_id) and not _oracle(match_instance, mound).has(b.entity_id), "same-cell padded AABB can be a precise circle false positive")
	_assert_paired(match_instance, mound, "same-cell false positive")
	store.set_combat_line_bounds(b.entity_id, radius, -1.0, 1.0)
	b.set_simulation_position(mound.global_position)
	store.set_health(b.entity_id, 0.0)
	_assert_paired(match_instance, mound, "stored dead")
	store.set_health(b.entity_id, b.max_health)
	var body := Doubles.PhysicsCombatTarget.new(mound.global_position, 0.2)
	match_instance.add_child(body)
	body.add_to_group(&"sim_units")
	var body_id: int = match_instance.entity_index().register(body, 1)
	store.set_position(body_id, mound.global_position)
	store.set_combat_line_bounds(body_id, 0.2, -0.2, 0.2)
	store.set_combat_line_carried(body_id, false)
	store.set_health(body_id, 1.0)
	var raw := CombatLineOfFireScript.rectangle_candidates(match_instance, self, Vector2(198.0, 198.0), Vector2(202.0, 202.0))
	_expect(raw.has(body_id) and not _oracle(match_instance, mound).has(body_id), "profiled live non-Unit reaches raw grid but not oracle")
	_assert_paired(match_instance, mound, "profiled non-Unit")
	var negative_mound = _fixed_mound(match_instance, Vector3(-2.0, 8.0, -2.0), Vector2i(8, 9))
	a.set_simulation_position(Vector3(-4.0, 8.0, -4.0))
	_assert_paired(match_instance, negative_mound, "negative and zero grid cells")
	a.set_simulation_position(mound.global_position)
	var queue = match_instance.admission_queue()
	b.set_simulation_position(mound.global_position)
	b.remove_from_group(&"sim_units")
	var before_count := get_node_count_in_group(&"sim_units")
	var before_revision: int = queue.sim_unit_join_revision()
	var before_store: int = store.combat_line_revision()
	var before_tick: int = match_instance.current_tick()
	_assert_parity(match_instance, mound, "before positive swap")
	a.remove_from_group(&"sim_units")
	queue.request_entry(b, &"sim_units")
	queue.apply_pending_entries()
	_expect(get_node_count_in_group(&"sim_units") == before_count and queue.sim_unit_join_revision() == before_revision + 1 and store.combat_line_revision() == before_store and match_instance.current_tick() == before_tick, "positive swap changes only queue join revision")
	_assert_parity(match_instance, mound, "positive queue swap before store write")
	_assert_paired(match_instance, mound, "positive queue swap")
	b.remove_from_group(&"sim_units")
	a.add_to_group(&"sim_units")
	a.set_simulation_position(mound.global_position)
	b.set_simulation_position(Vector3(240.0, 8.0, 240.0))
	_assert_paired(match_instance, mound, "before negative swap")
	a.remove_from_group(&"sim_units")
	b.add_to_group(&"sim_units")
	_assert_parity(match_instance, mound, "negative direct swap")
	a.set_simulation_position(mound.global_position)
	a.remove_from_group(&"sim_units")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, Vector2(198.0, 198.0), Vector2(202.0, 202.0))
	var count_revision: int = store.combat_line_revision()
	a.add_to_group(&"sim_units")
	_expect(store.combat_line_revision() == count_revision and not CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self), "group count alone invalidates warm snapshot")
	_expect(mound._contact_entries().has(a.entity_id), "group count re-add contacts without store write")
	_expect(tangent, "literal tangent remains a contact")
	body.free()
	match_instance.queue_free()
	await process_frame


func _test_same_tick_revision() -> void:
	var match_instance = _boot()
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	var unit = match_instance.get_node("Units/ScoutA")
	match_instance.advance_ticks(1)
	unit.set_simulation_position(Vector3(220.0, 8.0, 200.0))
	_assert_paired(match_instance, mound, "same-tick outside")
	unit.set_simulation_position(mound.global_position)
	_assert_paired(match_instance, mound, "same-tick inside")
	match_instance.queue_free()
	await process_frame


func _test_partial_and_standalone() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var partial := PartialMatch.new()
	root.add_child(partial)
	var mound = _fixed_mound(partial, Vector3(200.0, 8.0, 200.0))
	var ids := CombatLineOfFireScript.rectangle_candidates(partial, self, Vector2(198.0, 198.0), Vector2(202.0, 202.0))
	var entries: Array[int] = mound._contact_entries()
	_expect(ids.is_empty() and entries.is_empty() and logger.errors.is_empty(), "partial Match returns empty without a null call")
	partial.free()
	var standalone := Node3D.new()
	root.add_child(standalone)
	var free_mound = _fixed_mound(standalone, Vector3(200.0, 8.0, 200.0))
	var unit = ATAPCScene.instantiate()
	standalone.add_child(unit)
	unit.set_simulation_position(free_mound.global_position)
	unit.add_to_group(&"sim_units")
	var blooms := [0]
	free_mound.activated.connect(func(_m, _early, _fraction): blooms[0] += 1)
	free_mound.sim_tick()
	_expect(blooms[0] == 1 and logger.errors.is_empty(), "standalone unit blooms on entry")
	OS.remove_logger(logger)
	standalone.queue_free()
	await process_frame


func _test_two_matches() -> void:
	var a := ContactMatch.new()
	var b := ContactMatch.new()
	root.add_child(a)
	root.add_child(b)
	var ma = _fixed_mound(a, Vector3(200.0, 8.0, 200.0))
	var mb = _fixed_mound(b, Vector3(200.0, 8.0, 200.0))
	var ua = ATAPCScene.instantiate()
	var ub = ATAPCScene.instantiate()
	a.add_child(ua)
	b.add_child(ub)
	ua.set_simulation_position(Vector3(240.0, 8.0, 240.0))
	ub.set_simulation_position(mb.global_position)
	ua.add_to_group(&"sim_units")
	ub.add_to_group(&"sim_units")
	_assert_paired(a, ma, "match A")
	_assert_paired(b, mb, "match B")
	_assert_paired(a, ma, "match A again")
	_expect(ua.entity_id == ub.entity_id and ma._contact_entries().is_empty() and mb._contact_entries().size() == 1, "overlapping local ids keep distinct contacts")
	a.queue_free()
	b.queue_free()
	await process_frame


func _test_bounded_visits() -> void:
	var match_instance := CountingMatch.new()
	root.add_child(match_instance)
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	var index: CountingIndex = match_instance.index
	for n in 1000:
		var body := Doubles.PhysicsCombatTarget.new(Vector3(500.0 + n, 8.0, 500.0), 0.2)
		match_instance.add_child(body)
		body.add_to_group(&"sim_units")
		var id: int = index.register(body, 1)
		match_instance.state.set_position(id, body.global_position)
		match_instance.state.set_combat_line_bounds(id, 0.2, -0.2, 0.2)
	match_instance.spatial.sync()
	var first_id: int = index.registry().live_ids()[0]
	match_instance.state.set_position(first_id, match_instance.state.position(first_id))
	index.visits = 0
	var grid = CombatLineOfFireScript.debug_grid_for_test()
	var writes: int = grid.bucket_writes()
	var probes: int = grid.query_cell_probes()
	var cold: Array[int] = mound._contact_entries()
	_expect(cold.is_empty() and index.visits == 0 and grid.bucket_writes() == writes and grid.query_cell_probes() == probes, "cold AO1 snapshot uses persistent contact index without distant id_for visits")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, Vector2(198.0, 198.0), Vector2(202.0, 202.0))
	index.visits = 0
	probes = grid.query_cell_probes()
	var warm: Array[int] = mound._contact_entries()
	_expect(warm == cold and index.visits == 0 and grid.query_cell_probes() == probes, "warmed whole contact remains on persistent index")
	match_instance.queue_free()
	await process_frame


func _test_warm_key_matrix() -> void:
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var partial := PartialMatch.new()
	root.add_child(partial)
	var partial_ready := CombatLineOfFireScript.has_warm_match_snapshot(partial, self)
	_expect(not partial_ready and logger.errors.is_empty(), "partial Match warm probe returns false without null call")
	partial.free()
	var match_instance := KeyMatch.new()
	root.add_child(match_instance)
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	var body := Doubles.PhysicsCombatTarget.new(Vector3(500.0, 8.0, 500.0), 0.2)
	match_instance.add_child(body)
	body.add_to_group(&"sim_units")
	var id: int = match_instance.index.register(body, 1)
	match_instance.state.set_position(id, body.global_position)
	match_instance.state.set_combat_line_bounds(id, 0.2, -0.2, 0.2)
	var rng_audit: Dictionary = mound._local_rng.capture_audit()
	var bounds_min := Vector2(198.0, 198.0)
	var bounds_max := Vector2(202.0, 202.0)
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	_expect(CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self), "key matrix initial snapshot warm")
	match_instance.queue = SimAdmissionQueueScript.new()
	_assert_stale_key(match_instance, "admission queue identity")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	_expect(CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self), "replacement admission queue can be warmed")
	match_instance.tick += 1
	_assert_stale_key(match_instance, "tick")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	match_instance.state.set_position(id, match_instance.state.position(id))
	_assert_stale_key(match_instance, "store revision")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	body.remove_from_group(&"sim_units")
	_assert_stale_key(match_instance, "group count")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	var other := Doubles.PhysicsCombatTarget.new(Vector3(500.0, 8.0, 500.0), 0.2)
	match_instance.add_child(other)
	other.add_to_group(&"sim_units")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	other.remove_from_group(&"sim_units")
	match_instance.queue.request_entry(body, &"sim_units")
	match_instance.queue.apply_pending_entries()
	_assert_stale_key(match_instance, "same-count admission join")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	var another := KeyMatch.new()
	root.add_child(another)
	_assert_stale_key(another, "Match identity")
	CombatLineOfFireScript.rectangle_candidates(another, self, bounds_min, bounds_max)
	_expect(CombatLineOfFireScript.has_warm_match_snapshot(another, self), "different Match can be warmed")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	var other_tree := SceneTree.new()
	_assert_stale_key(match_instance, "tree identity", other_tree)
	CombatLineOfFireScript.rectangle_candidates(match_instance, other_tree, bounds_min, bounds_max)
	_expect(CombatLineOfFireScript.has_warm_match_snapshot(match_instance, other_tree), "different tree can be warmed")
	other_tree.free()
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	match_instance.index = EntityNodeIndexScript.new()
	_assert_stale_key(match_instance, "index identity")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	_expect(CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self), "replacement index can be warmed")
	match_instance.state = SimEntityStateScript.new(match_instance.index.registry())
	_assert_stale_key(match_instance, "store identity")
	CombatLineOfFireScript.rectangle_candidates(match_instance, self, bounds_min, bounds_max)
	_expect(CombatLineOfFireScript.has_warm_match_snapshot(match_instance, self) and mound._local_rng.capture_audit() == rng_audit and logger.errors.is_empty(), "key matrix rewarm and no RNG or script error")
	OS.remove_logger(logger)
	match_instance.queue_free()
	another.queue_free()
	await process_frame


func _assert_stale_key(match_instance: Node, label: String, tree: SceneTree = null) -> void:
	var grid = CombatLineOfFireScript.debug_grid_for_test()
	var writes: int = grid.bucket_writes()
	var probes: int = grid.query_cell_probes()
	var observed := CombatLineOfFireScript.has_warm_match_snapshot(match_instance, tree if tree != null else self)
	_expect(not observed and writes == grid.bucket_writes() and probes == grid.query_cell_probes(), "%s key is cold without grid mutation" % label)


func _test_first_admitted_tick() -> void:
	var match_instance = _boot()
	match_instance.advance_ticks(1)
	var mound = _fixed_mound(match_instance, Vector3(200.0, 8.0, 200.0))
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 1
	match_instance.get_node("Units").add_child(unit)
	unit.set_simulation_position(mound.global_position)
	match_instance.unit_spatial_index().sync()
	_expect(not match_instance.unit_spatial_index().has_raw_id(unit.entity_id), "pre-admission dirty is drained while excluded")
	unit._simulation_halted = true
	var blooms := [0]
	mound.activated.connect(func(_m, _early, _fraction): blooms[0] += 1)
	mound.sim_tick()
	_expect(blooms[0] == 0 and not unit.is_in_group(&"sim_units"), "new unit has no contact before admission")
	match_instance.admission_queue().apply_pending_entries()
	_expect(unit.is_in_group(&"sim_units"), "queued unit was admitted")
	_expect(match_instance.unit_spatial_index().rectangle_candidates(
		Vector2(mound.global_position.x - 1.0, mound.global_position.z - 1.0),
		Vector2(mound.global_position.x + 1.0, mound.global_position.z + 1.0)
	).has(unit.entity_id), "admission re-offers drained pre-admission state without another position write")
	match_instance.advance_ticks(1)
	_expect(blooms[0] == 1 and unit.is_in_group(&"sim_units"), "new unit blooms on first admitted tick")
	match_instance.queue_free()
	await process_frame
