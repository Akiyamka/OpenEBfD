extends SceneTree

## Replays a command log through a Match without rendering or frame-driven
## simulation:
##   ./tools/godot-container godot --headless --path /workspace --script res://tools/run_headless_match.gd -- --replay=res://tests/fixtures/headless_match_smoke.oebr

const DEFAULT_SCENE_PATH := "res://scenes/match/demo_match.tscn"
const DEFAULT_MAX_TICKS := 10000
const BOOT_SETTLE_FRAMES := 2

var _replay_path := ""
var _scene_path := DEFAULT_SCENE_PATH
var _max_ticks := DEFAULT_MAX_TICKS


func _initialize() -> void:
	_parse_args()
	if _replay_path.is_empty():
		printerr("--replay is required")
		quit(1)
		return
	if not FileAccess.file_exists(_replay_path):
		printerr("--replay file not found: %s" % _replay_path)
		quit(1)
		return

	var packed_scene := load(_scene_path) as PackedScene
	if packed_scene == null:
		printerr("Cannot load --scene: %s" % _scene_path)
		quit(1)
		return
	var match_instance := packed_scene.instantiate()
	if not match_instance.has_method("load_replay") or not match_instance.has_method("advance_ticks") \
	or not match_instance.has_method("replay_exhausted"):
		printerr("--scene does not instantiate a Match: %s" % _scene_path)
		quit(1)
		return

	root.add_child(match_instance)
	match_instance.set_process(false)
	for _frame in BOOT_SETTLE_FRAMES:
		await process_frame
		match_instance.set_process(false)

	var result: Dictionary = match_instance.load_replay(_replay_path)
	if not bool(result.get("ok", false)):
		printerr(String(result.get("message", "Replay load failed")))
		quit(1)
		return

	for _tick in _max_ticks:
		if match_instance.replay_exhausted():
			quit(0)
			return
		match_instance.advance_ticks(1)
	if match_instance.replay_exhausted():
		quit(0)
		return
	printerr("Replay max-ticks bound hit: %d" % _max_ticks)
	quit(1)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=", true, 1)
		var key := parts[0]
		var value := parts[1] if parts.size() > 1 else ""
		match key:
			"--replay":
				_replay_path = value
			"--scene":
				_scene_path = value
			"--max-ticks":
				_max_ticks = maxi(int(value), 1)
			_:
				push_warning("Unknown headless replay argument: %s" % arg)
