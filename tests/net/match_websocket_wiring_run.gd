extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const WebSocketMatchFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")
const RelayServerScript := preload("res://scripts/net/relay/relay_server.gd")
const WebSocketTransportScript := preload("res://scripts/net/websocket_transport.gd")
const NetTransportScript := preload("res://scripts/net/net_transport.gd")

const TEST_PORT := 18930
const ROOM_URL := "ws://127.0.0.1:18930/t1-room"
const CHECKSUM_ROOM_URL := "ws://127.0.0.1:18930/u1-room"
const MAX_PUMP_ITERATIONS := 5000
const MAX_PUMP_SECONDS := 5.0

var _server: RelayServer


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	_server = RelayServerScript.new()
	var err := _server.start(TEST_PORT)
	if err != OK:
		printerr("Match WebSocket wiring tests: could not bind port %d (%s)" % [TEST_PORT, error_string(err)])
		quit(1)
		return
	await _run_async_case(
		"two sequential Matches agree after a real relay forwards a Stop command",
		_test_real_match_wiring
	)
	await _run_async_case(
		"two sequential Matches agree on state checksums over a real relay",
		_test_live_checksum_exchange
	)
	_server.stop()
	_finish("Match WebSocket wiring tests")


func _test_real_match_wiring() -> void:
	var match_a = await _boot_match(1, ROOM_URL)
	if not await _await_match_connected(match_a, "player one's Match transport reaches CONNECTED"):
		await _teardown_match(match_a)
		return
	_expect(
		match_a.net_transport.state() == NetTransportScript.State.CONNECTED,
		"player one's Match must construct and connect its real WebSocket transport"
	)
	match_a.command_bus().input_delay_ticks = 2

	var transport_b: NetTransport = WebSocketTransportScript.new()
	transport_b.open(ROOM_URL)
	if not await _await_transport_connected(transport_b, "player two's pre-seated transport reaches CONNECTED"):
		transport_b.close()
		await _teardown_match(match_a)
		return

	var scout_a = match_a.get_node("Units/ScoutA")
	var controller = match_a._unit_command_controller
	scout_a._has_pending_navigation_order = true
	var selection: Array[Node] = [scout_a]
	controller._set_selection(selection)
	var tick_before: int = match_a.current_tick()
	var echoes_before: int = match_a.turn_scheduler().discarded_command_echo_count()
	var stop_event := InputEventKey.new()
	stop_event.keycode = KEY_S
	stop_event.pressed = true
	_expect(controller.handle_unhandled_input(stop_event), "the real Stop input must be consumed")
	_expect(
		scout_a._has_pending_navigation_order,
		"a delayed Stop must remain queued immediately after the controller handles input"
	)

	var target_tick: int = tick_before + 3
	while match_a.current_tick() < target_tick:
		_server.poll()
		match_a.advance_ticks(1)
		await process_frame
	_expect(
		not scout_a._has_pending_navigation_order,
		"the local Stop must execute when Match reaches its scheduled tick"
	)
	var hash_a: int = match_a.entity_state().state_hash()
	var total_ticks: int = match_a.current_tick()

	await _await_sender_echo(match_a, echoes_before)
	_expect(
		match_a.turn_scheduler().discarded_command_echo_count() > echoes_before,
		"the relay must echo player one's frame before its Match is torn down"
	)
	await _teardown_match(match_a)

	var match_b = await _boot_match(2, "", transport_b)
	_expect(
		match_b.net_transport == transport_b and match_b.net_transport.state() == NetTransportScript.State.CONNECTED,
		"player two's already-connected transport must be retained without reopening"
	)
	var scout_b = match_b.get_node("Units/ScoutA")
	# Admit and register through Match's public tick path before installing the
	# pending-order precondition. The relayed frame targets tick_before + 3, so
	# it remains scheduled rather than late during this warm-up.
	while match_b.current_tick() < tick_before:
		match_b.advance_ticks(1)
	_expect(
		match_b.command_bus().dropped_late_count() == 0,
		"joining client keeps the buffered command scheduled during warm-up"
	)
	scout_b._has_pending_navigation_order = true
	_expect(
		scout_b._has_pending_navigation_order,
		"the receiver's pending order must start true before the remote command's scheduled tick"
	)
	while match_b.current_tick() < total_ticks:
		match_b.advance_ticks(1)
	_expect(
		not scout_b._has_pending_navigation_order,
		"the received Stop command must clear the second Match's pending order"
	)
	_expect(
		match_b.entity_state().state_hash() == hash_a,
		"sequential Matches must have equal simulated entity state at tick %d (A=%d, B=%d)"
		% [total_ticks, hash_a, match_b.entity_state().state_hash()]
	)
	await _teardown_match(match_b)


func _test_live_checksum_exchange() -> void:
	const WINDOW := 16
	# Deliberately not Match.CHECKSUM_INTERVAL_TICKS: deriving this from the
	# production constant would make it track any cadence change, and the
	# exact-agreement assertion below would then pass at every cadence --
	# which is the one thing it exists to catch.
	const EXPECTED_REPORTS := WINDOW / 8
	var match_a = await _boot_match(1, CHECKSUM_ROOM_URL)
	if not await _await_match_connected_without_ticks(
		match_a, "player one's checksum Match transport reaches CONNECTED"
	):
		await _teardown_match(match_a)
		return
	_expect(match_a.current_tick() == 0, "the non-ticking connect pump must leave player one at tick zero")

	var transport_b: NetTransport = WebSocketTransportScript.new()
	transport_b.open(CHECKSUM_ROOM_URL)
	if not await _await_transport_connected(
		transport_b, "player two's checksum transport reaches CONNECTED"
	):
		transport_b.close()
		await _teardown_match(match_a)
		return

	while match_a.current_tick() < WINDOW:
		_server.poll()
		match_a.advance_ticks(1)
		await process_frame
	var echoes_before: int = match_a.turn_scheduler().discarded_echo_count()
	if echoes_before < EXPECTED_REPORTS:
		var start_msec := Time.get_ticks_msec()
		for _i in range(MAX_PUMP_ITERATIONS):
			_server.poll()
			match_a.turn_scheduler().advance_tick(match_a.current_tick())
			await process_frame
			if match_a.turn_scheduler().discarded_echo_count() >= EXPECTED_REPORTS:
				break
			if Time.get_ticks_msec() - start_msec > MAX_PUMP_SECONDS * 1000.0:
				break
	_expect(
		match_a.turn_scheduler().discarded_echo_count() >= EXPECTED_REPORTS,
		"the relay must echo both checksum reports before player one is torn down"
	)
	_expect(match_a.checksum_exchange().agreement_count() == 0, "checksum echoes must not agree with player one")
	_expect(match_a.checksum_exchange().mismatch_count() == 0, "checksum echoes must not mismatch player one")
	await _teardown_match(match_a)

	var match_b = await _boot_match(2, "", transport_b)
	while match_b.current_tick() < WINDOW:
		match_b.advance_ticks(1)
	_expect(
		match_b.checksum_exchange().agreement_count() == EXPECTED_REPORTS,
		"the receiver must agree at exactly both checksum cadence boundaries"
	)
	_expect(match_b.checksum_exchange().mismatch_count() == 0, "the receiver must not mismatch either checksum")
	_expect(match_b.checksum_exchange().pending_remote_count() == 0, "every received checksum must resolve locally")
	await _teardown_match(match_b)


func _boot_match(local_player_id: int, room_url: String, transport_override: NetTransport = null):
	var match_instance = WebSocketMatchFixtureScene.instantiate()
	match_instance.local_player_id_for_test = local_player_id
	match_instance.net_room_url_for_test = room_url
	match_instance.transport_override = transport_override
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	return match_instance


func _teardown_match(match_instance) -> void:
	match_instance.queue_free()
	await process_frame


func _await_match_connected(match_instance, description: String) -> bool:
	var start_msec := Time.get_ticks_msec()
	for _i in range(MAX_PUMP_ITERATIONS):
		_server.poll()
		match_instance.advance_ticks(1)
		if match_instance.net_transport.state() == NetTransportScript.State.CONNECTED:
			return true
		if Time.get_ticks_msec() - start_msec > MAX_PUMP_SECONDS * 1000.0:
			break
		await process_frame
	_expect(false, "timed out waiting for: %s" % description)
	return false


func _await_match_connected_without_ticks(match_instance, description: String) -> bool:
	var start_msec := Time.get_ticks_msec()
	for _i in range(MAX_PUMP_ITERATIONS):
		_server.poll()
		match_instance.turn_scheduler().advance_tick(match_instance.current_tick())
		if match_instance.net_transport.state() == NetTransportScript.State.CONNECTED:
			return true
		if Time.get_ticks_msec() - start_msec > MAX_PUMP_SECONDS * 1000.0:
			break
		await process_frame
	_expect(false, "timed out waiting for: %s" % description)
	return false


func _await_transport_connected(transport: NetTransport, description: String) -> bool:
	var start_msec := Time.get_ticks_msec()
	for _i in range(MAX_PUMP_ITERATIONS):
		_server.poll()
		transport.poll()
		if transport.state() == NetTransportScript.State.CONNECTED:
			return true
		if Time.get_ticks_msec() - start_msec > MAX_PUMP_SECONDS * 1000.0:
			break
		await process_frame
	_expect(false, "timed out waiting for: %s" % description)
	return false


func _await_sender_echo(match_instance, echoes_before: int) -> void:
	if match_instance.turn_scheduler().discarded_command_echo_count() > echoes_before:
		return
	var start_msec := Time.get_ticks_msec()
	for _i in range(MAX_PUMP_ITERATIONS):
		_server.poll()
		match_instance.turn_scheduler().advance_tick(match_instance.current_tick())
		await process_frame
		if match_instance.turn_scheduler().discarded_command_echo_count() > echoes_before:
			return
		if Time.get_ticks_msec() - start_msec > MAX_PUMP_SECONDS * 1000.0:
			break
	_expect(false, "timed out waiting for the relay to echo player one's Stop frame")
