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
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")

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

class SeedMatch extends PartialMatch:
	var rng = SimRngScript.new(456)
	func sim_rng():
		return rng

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
	match_instance.advance_ticks(1)
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
