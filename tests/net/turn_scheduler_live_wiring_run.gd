extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const RecordingMatchFixtureScene := preload("res://tests/fixtures/recording_transport_match_fixture.tscn")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")
const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _test_stop_reaches_the_scheduler_transport()
	if _failures > 0:
		printerr("Live TurnScheduler wiring tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Live TurnScheduler wiring tests: %d assertions passed" % _assertions)
	quit(0)


func _test_stop_reaches_the_scheduler_transport() -> void:
	var match_instance := RecordingMatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 5:
		await process_frame
	var transport = match_instance.recording_transport
	_expect(transport.sent_frames.is_empty(), "no frame is sent before a controller command")
	var scout := match_instance.get_node("Units/ScoutA")
	scout._has_pending_navigation_order = true
	var controller = match_instance._unit_command_controller
	var selection: Array[Node] = [scout]
	controller._set_selection(selection)
	var tick_before_issue: int = match_instance.current_tick()
	var event := InputEventKey.new()
	event.keycode = KEY_S
	event.pressed = true
	_expect(controller.handle_unhandled_input(event), "a real Stop input is consumed")
	while match_instance.current_tick() <= tick_before_issue:
		await process_frame
	_expect(transport.sent_frames.size() == 1, "the scheduler sends exactly one controller frame")
	if transport.sent_frames.size() == 1:
		var frame: PackedByteArray = transport.sent_frames[0]
		_expect(frame.size() >= 5 and frame[0] == 0, "the frame starts with the command discriminator")
		var buffer := StreamPeerBuffer.new()
		buffer.big_endian = true
		buffer.data_array = frame
		buffer.get_u8()
		var target_tick := buffer.get_u32()
		_expect(target_tick == tick_before_issue + 1, "the frame carries the bus-scheduled next tick")
		var command = SimCommandCodecScript.decode(frame.slice(5))
		_expect(command is SimStopCommand, "the frame payload decodes to the issued Stop command")
		if command is SimStopCommand:
			_expect(command.player_id == 1 and command.entity_ids == PackedInt32Array([scout.entity_id]), "the decoded Stop keeps its player and selected entity")
	_expect(not scout._has_pending_navigation_order, "the scheduled Stop executes through the real Match tick")
	match_instance.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures += 1
		printerr("FAIL: %s" % message)
