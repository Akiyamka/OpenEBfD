extends "res://scripts/match/match.gd"

const BOOT_SETTLE_FRAMES := 2
const TICKS_PER_CHUNK := 64
const YIELD_FRAMES_PER_CHUNK := 3

@export var replay_path := "res://scenes/dev/web_replay_check.oebr"
@export var drive_to_completion := false
@export var max_ticks_when_driving := 2000


func _restore_saved_startup_state() -> void:
	pass


func _ready() -> void:
	set_process(false)
	super()
	for _frame in BOOT_SETTLE_FRAMES:
		await get_tree().process_frame
		set_process(false)

	var scout := get_node("Units/ScoutA") as Unit
	if not entity_state().has_position(scout.entity_id):
		printerr("WEB_REPLAY_CHECK_BOOT_FAILED ScoutA has no settled simulation position")
		return
	var start_position := scout.simulation_position()
	var result: Dictionary = load_replay(replay_path)
	if not drive_to_completion or not bool(result.get("ok", false)):
		print(
			"WEB_REPLAY_CHECK_RESULT ok=%s message=%s"
			% [bool(result.get("ok", false)), String(result.get("message", ""))]
		)
		return

	var ticks := 0
	var chunks := 0
	var process_frames_before := Engine.get_process_frames()
	var last_process_frame := process_frames_before
	while not replay_exhausted() and ticks < max_ticks_when_driving:
		var chunk_ticks := mini(TICKS_PER_CHUNK, max_ticks_when_driving - ticks)
		advance_ticks(chunk_ticks)
		ticks += chunk_ticks
		chunks += 1
		if not replay_exhausted():
			for _frame in YIELD_FRAMES_PER_CHUNK:
				await get_tree().process_frame
				var resumed_process_frame := Engine.get_process_frames()
				if resumed_process_frame <= last_process_frame:
					printerr("WEB_REPLAY_CHECK_YIELD_FAILED engine process frame did not advance")
					return
				last_process_frame = resumed_process_frame
				set_process(false)
	var exhausted := replay_exhausted()
	var moved := not scout.simulation_position().is_equal_approx(start_position)
	var clock_ticks := current_tick()
	var state_hash := entity_state().state_hash() if exhausted else 0
	print(
		"WEB_REPLAY_CHECK_RESULT ok=%s message=%s exhausted=%s ticks=%d chunks=%d process_frame_delta=%d moved=%s clock_ticks=%d hash=%d"
		% [
			true, String(result.get("message", "")), exhausted, ticks, chunks,
			last_process_frame - process_frames_before, moved, clock_ticks, state_hash,
		]
	)
