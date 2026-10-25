extends "res://tests/support/suite.gd"

const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")
const WebsocketMatchFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")

const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case("a halt dumps every live entity as it stood at the mismatched tick", _test_snapshot_at_mismatch)
	await _run_async_case("units carry their navigation state and turrets their aim", _test_navigation_and_turrets)
	await _run_async_case("the ring keeps exactly the window a halt can need", _test_retained_window)
	await _run_async_case("a mismatch on an uncaptured tick says so", _test_missing_tick)
	await _run_async_case("a capture changes no simulation state", _test_capture_is_read_only)
	await _run_async_case("a boot without a room captures and prints nothing", _test_no_room_has_no_ring)
	await _run_async_case("one drain resolving two mismatches dumps the earlier tick", _test_earliest_mismatch_dump)
	await _run_async_case("seed and draw use change Match checksums and retained RNG fields", _test_rng_checksum_and_retention)
	_finish("Match desync state tests")


func _test_snapshot_at_mismatch() -> void:
	var arm := await _boot_room_arm()
	var match_instance = arm["match"]
	match_instance.advance_ticks(8)
	var ids: PackedInt32Array = match_instance.entity_index().registry().live_ids()
	var unit_id := 0
	for id in ids:
		if match_instance.entity_index().registry().kind_of(id) == SimEntityRegistryScript.Kind.UNIT and match_instance.entity_state().health(id) > 0.0:
			unit_id = id
			break
	var position: Vector3 = match_instance.entity_state().position(unit_id)
	var health: float = match_instance.entity_state().health(unit_id)
	var line_radius: float = match_instance.entity_state().combat_line_radius(unit_id)
	var line_min_y: float = match_instance.entity_state().combat_line_min_y(unit_id)
	var line_max_y: float = match_instance.entity_state().combat_line_max_y(unit_id)
	var position_token := " pos=%s[%s] " % [str(position), PackedVector3Array([position]).to_byte_array().hex_encode()]
	var health_token := " hp=%s[%s] " % [str(health), PackedFloat32Array([health]).to_byte_array().hex_encode()]
	var real: int = match_instance.match_checksum()
	var unit = match_instance.entity_index().node_for(unit_id)
	unit.health = health * 0.5
	var new_health: float = health * 0.5
	var new_health_token := " hp=%s[%s] " % [str(new_health), PackedFloat32Array([new_health]).to_byte_array().hex_encode()]
	match_instance.checksum_exchange().on_report_received(2, 8, real + 1)
	match_instance.advance_ticks(1)
	var dump: PackedStringArray = match_instance.halt_state_dump()
	_expect(match_instance.is_halted() and match_instance.halted_at_tick() == 9, "the planted mismatch must halt at tick nine")
	_expect(dump.size() > 0 and dump[0] == "[desync-state] state after tick 8: %d live entities" % ids.size(), "the dump header must name the captured mismatch tick and live count")
	_expect(_entity_ids(dump) == ids, "entity lines must retain the registry's ascending live-id order")
	_expect(not _entity_line(dump, unit_id).is_empty() and position_token in _entity_line(dump, unit_id) and health_token in _entity_line(dump, unit_id), "the unit line must retain its tick-eight position and health bytes")
	var profile_tokens := " line_r=%s[%s]" % [str(line_radius), PackedFloat32Array([line_radius]).to_byte_array().hex_encode()]
	profile_tokens += " line_ymin=%s[%s]" % [str(line_min_y), PackedFloat32Array([line_min_y]).to_byte_array().hex_encode()]
	profile_tokens += " line_ymax=%s[%s]" % [str(line_max_y), PackedFloat32Array([line_max_y]).to_byte_array().hex_encode()]
	var retained_line := _entity_line(dump, unit_id)
	_expect(profile_tokens in retained_line and " line_carried=0[00]" in retained_line, "the retained line must print byte-exact profile and carried fields")
	_expect(not _entity_line(dump, unit_id).is_empty() and not new_health_token in _entity_line(dump, unit_id), "the dump must be a snapshot rather than live state at the halt")
	var all_prefixed := dump.size() > 0
	for line in dump:
		all_prefixed = all_prefixed and line.begins_with("[desync-state] ")
	_expect(all_prefixed, "every state-dump line must use the desync-state prefix")
	var halt_dump: PackedStringArray = match_instance.halt_dump()
	_expect(halt_dump.size() > 0 and halt_dump[0].begins_with("[desync] player 1 halted at tick 9") and not _has_desync_state_line(halt_dump), "the existing halt dump must remain separate from state lines")
	await _teardown_arm(match_instance)


func _test_navigation_and_turrets() -> void:
	var arm := await _boot_room_arm()
	var match_instance = arm["match"]
	match_instance.advance_ticks(7)
	match_instance.checksum_exchange().on_report_received(2, 8, 12345)
	match_instance.advance_ticks(5)
	var dump: PackedStringArray = match_instance.halt_state_dump()
	var nav = match_instance._unit_navigation_system
	var nav_id := 0
	var nav_agent: Dictionary = {}
	var turret_id := 0
	var first_turret
	var expected_nav_count := 0
	var expected_turret_count := 0
	for id in match_instance.entity_index().registry().live_ids():
		var node = match_instance.entity_index().node_for(id)
		var agent: Dictionary = _agent(nav, node)
		if not agent.is_empty():
			expected_nav_count += 1
			if nav_id == 0:
				nav_id = id
				nav_agent = agent
		var turrets: Array = node.combat_turrets
		expected_turret_count += turrets.size()
		if turret_id == 0 and not turrets.is_empty():
			turret_id = id
			first_turret = turrets[0]
	_expect(nav_id > 0 and turret_id > 0, "the fixture must provide one navigation agent and one turret")
	var nav_line := _line_after_entity(dump, nav_id)
	_expect(nav_line.begins_with("[desync-state] nav %d agent=%d cmd=%d mode=%d " % [nav_id, nav_agent["id"], nav_agent["command_id"], nav_agent["mode"]]), "the navigation line must follow its entity with core agent identifiers")
	var blocked_token := " blocked=%s[%s] " % [str(nav_agent["blocked_time"]), PackedFloat64Array([nav_agent["blocked_time"]]).to_byte_array().hex_encode()]
	var node = match_instance.entity_index().node_for(nav_id)
	var yaw_token := " yaw=%s[%s] " % [str(node.global_rotation.y), PackedFloat32Array([node.global_rotation.y]).to_byte_array().hex_encode()]
	_expect(blocked_token in nav_line and yaw_token in nav_line and " swap=%d " % nav_agent["swap_tick"] in nav_line and " path=%d/%d " % [nav_agent["path_index"], (nav_agent["path"] as Array).size()] in nav_line, "the navigation line must preserve scalar and path debug state")
	var turret_line := _first_line_with_prefix(dump, "[desync-state] turret %d weapon=%d " % [turret_id, first_turret.weapon_index()])
	var turret_yaw_token := " yaw=%s[%s] " % [str(first_turret.current_yaw), PackedFloat64Array([first_turret.current_yaw]).to_byte_array().hex_encode()]
	_expect(turret_yaw_token in turret_line, "the turret line must retain its float64 yaw bytes")
	_expect(_count_lines_with_prefix(dump, "[desync-state] nav ") == expected_nav_count and _count_lines_with_prefix(dump, "[desync-state] turret ") == expected_turret_count, "the dump must include every available navigation agent and turret")
	await _teardown_arm(match_instance)


func _test_retained_window() -> void:
	var first_arm := await _boot_room_arm()
	var first_match = first_arm["match"]
	first_match.advance_ticks(79)
	var first_ring = first_match._desync_state_ring
	_expect(first_ring != null and first_ring.retained_ticks() == PackedInt32Array([8, 16, 24, 32, 40, 48, 56, 64, 72]), "the early window must retain every checksum capture")
	var real8 := int(first_match.checksum_exchange()._local_hash_by_tick.get(8, 0))
	first_match.checksum_exchange().on_report_received(2, 8, real8 ^ 1)
	first_match.advance_ticks(5)
	_expect(first_match.halted_at_tick() == 80, "the oldest retained mismatch must halt at the documented worst-case tick")
	_expect(first_match.halt_state_dump().size() > 0 and first_match.halt_state_dump()[0].begins_with("[desync-state] state after tick 8:"), "the oldest retained capture must still format at the halt")
	await _teardown_arm(first_match)
	var second_arm := await _boot_room_arm()
	var second_match = second_arm["match"]
	second_match.advance_ticks(96)
	var second_ring = second_match._desync_state_ring
	_expect(second_ring != null and second_ring.retained_ticks() == PackedInt32Array([24, 32, 40, 48, 56, 64, 72, 80, 88, 96]), "the full ring must retain exactly ten newest captures")
	await _teardown_arm(second_match)


func _test_missing_tick() -> void:
	var arm := await _boot_room_arm()
	var match_instance = arm["match"]
	match_instance.advance_ticks(5)
	match_instance.checksum_exchange().record_local_hash(5, 1234)
	match_instance.checksum_exchange().on_report_received(2, 5, 1235)
	match_instance.advance_ticks(1)
	_expect(match_instance.halt_state_dump() == PackedStringArray(["[desync-state] no state retained for tick 5"]), "an uncaptured mismatch tick must say that its state was not retained")
	await _teardown_arm(match_instance)


func _test_capture_is_read_only() -> void:
	var arm := await _boot_room_arm()
	var match_instance = arm["match"]
	match_instance.advance_ticks(8)
	var ring = match_instance._desync_state_ring
	var before: int = match_instance.entity_state().state_hash()
	var first_unit = _first_live_unit(match_instance)
	var agent_before: Dictionary = _agent(match_instance._unit_navigation_system, first_unit).duplicate(true)
	ring.capture(8, match_instance.entity_state(), match_instance.entity_index(), match_instance._unit_navigation_system, match_instance.sim_rng())
	var after: int = match_instance.entity_state().state_hash()
	var agent_after: Dictionary = _agent(match_instance._unit_navigation_system, first_unit).duplicate(true)
	_expect(ring != null and before == after, "capturing a state dump must not change the entity hash")
	_expect(ring != null and agent_before == agent_after, "capturing a state dump must not mutate navigation state")
	await _teardown_arm(match_instance)


func _test_no_room_has_no_ring() -> void:
	var match_instance = await _boot_plain_arm()
	match_instance.advance_ticks(8)
	var real: int = match_instance.match_checksum()
	match_instance.checksum_exchange().on_report_received(2, 8, real + 1)
	match_instance.advance_ticks(1)
	_expect(match_instance._desync_state_ring == null, "a no-room boot must not allocate a desync state ring")
	_expect(match_instance.is_halted() and match_instance.halt_dump().size() > 0 and match_instance.halt_state_dump().is_empty(), "a no-room halt must retain only the existing halt dump")
	await _teardown_arm(match_instance)


func _test_earliest_mismatch_dump() -> void:
	var arm := await _boot_room_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer_endpoint = hub.add_endpoint(&"peer2")
	peer_endpoint.open("")
	var peer = TurnSchedulerScript.new(SimCommandBusScript.new(), peer_endpoint, 2, ChecksumExchangeScript.new())
	match_instance.advance_ticks(16)
	var hash8 := int(match_instance.checksum_exchange()._local_hash_by_tick.get(8, 0))
	var hash16 := int(match_instance.checksum_exchange()._local_hash_by_tick.get(16, 0))
	peer.send_checksum_report(8, hash8 ^ 1)
	peer.send_checksum_report(16, hash16 ^ 1)
	hub.step()
	match_instance.advance_ticks(1)
	_expect(match_instance.is_halted() and match_instance.halted_at_tick() == 17 and match_instance.checksum_exchange().mismatch_count() == 2, "one scheduler drain must resolve both mismatches before the halt")
	_expect(match_instance.halt_state_dump().size() > 0 and match_instance.halt_state_dump()[0].begins_with("[desync-state] state after tick 8:"), "the state dump must use the earliest mismatch rather than the last resolved one")
	_expect(match_instance.halt_diagnostic().begins_with("Match halted: simulation checksum diverged from player 2 at tick 16 "), "the existing diagnostic must continue to name the last mismatch")
	await _teardown_arm(match_instance)


func _test_rng_checksum_and_retention() -> void:
	var arm := await _boot_room_arm()
	var match_instance = arm["match"]
	var initial: int = match_instance.match_checksum()
	var seed: int = match_instance.match_seed()
	match_instance.sim_rng().seed = seed + 1
	_expect(match_instance.match_checksum() != initial, "same entities with a different seed have different checksums")
	match_instance.sim_rng().seed = seed
	match_instance.sim_rng().draw(1, 2, 3, 4, 0)
	_expect(match_instance.match_checksum() != initial, "one extra tracked draw changes the checksum")
	match_instance.advance_ticks(8)
	var recorded: int = int(match_instance.checksum_exchange()._local_hash_by_tick.get(8, -1))
	_expect(recorded == match_instance.match_checksum(), "tick-eight record uses Match composite accessor")
	var signature: int = match_instance.sim_rng().draw_signature
	var count: int = match_instance.sim_rng().draw_count
	var expected := "[desync-state] rng seed=%016x version=%08x count=%016x signature=%08x" % [seed, 1, count, signature]
	match_instance.sim_rng().draw(1, 2, 3, 4, 1)
	var retained: PackedStringArray = match_instance._desync_state_ring.lines_for(8)
	_expect(expected in retained, "retained tick keeps exact seed, version, count and signature before later draws")
	await _teardown_arm(match_instance)


func _boot_room_arm() -> Dictionary:
	var hub := LoopbackHubScript.new()
	var endpoint = hub.add_endpoint(&"match")
	var match_instance = WebsocketMatchFixtureScene.instantiate()
	match_instance.local_player_id_for_test = 1
	match_instance.net_room_url_for_test = "ws://test/room"
	match_instance.net_player_count_for_test = 0
	match_instance.transport_override = endpoint
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	return {"hub": hub, "match": match_instance}


func _boot_plain_arm():
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	return match_instance


func _teardown_arm(match_instance) -> void:
	match_instance.queue_free()
	await process_frame
	await process_frame
	for group_name in SIM_GROUPS:
		_expect(get_nodes_in_group(group_name).is_empty(), "teardown must leave %s empty before the next arm" % group_name)


func _agent(navigation, node) -> Dictionary:
	return navigation._agents.get(node.get_instance_id(), {})


func _first_live_unit(match_instance):
	for id in match_instance.entity_index().registry().live_ids():
		if match_instance.entity_index().registry().kind_of(id) == SimEntityRegistryScript.Kind.UNIT:
			return match_instance.entity_index().node_for(id)
	return null


func _entity_line(lines: PackedStringArray, id: int) -> String:
	return _first_line_with_prefix(lines, "[desync-state] entity %d " % id)


func _line_after_entity(lines: PackedStringArray, id: int) -> String:
	var entity_line := _entity_line(lines, id)
	var index := lines.find(entity_line)
	return lines[index + 1] if index >= 0 and index + 1 < lines.size() else ""


func _entity_ids(lines: PackedStringArray) -> PackedInt32Array:
	var ids := PackedInt32Array()
	for line in lines:
		if line.begins_with("[desync-state] entity "):
			ids.append(int(line.split(" ")[2]))
	return ids


func _first_line_with_prefix(lines: PackedStringArray, prefix: String) -> String:
	for line in lines:
		if line.begins_with(prefix):
			return line
	return ""


func _count_lines_with_prefix(lines: PackedStringArray, prefix: String) -> int:
	var count := 0
	for line in lines:
		if line.begins_with(prefix):
			count += 1
	return count


func _has_desync_state_line(lines: PackedStringArray) -> bool:
	return not _first_line_with_prefix(lines, "[desync-state]").is_empty()
