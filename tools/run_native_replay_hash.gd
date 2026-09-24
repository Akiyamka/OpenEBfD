extends SceneTree

## Runs the web replay ticks fixture natively and prints its final state hash:
##   ./tools/godot-container godot --headless --path /workspace --script res://tools/run_native_replay_hash.gd -- --scene=res://scenes/dev/web_replay_check_ticks.tscn

const DEFAULT_SCENE_PATH := "res://scenes/dev/web_replay_check_ticks.tscn"
const MAX_POLL_FRAMES := 1000

var _scene_path := DEFAULT_SCENE_PATH


func _initialize() -> void:
	_parse_args()
	var packed_scene := load(_scene_path) as PackedScene
	if packed_scene == null:
		printerr("Cannot load --scene: %s" % _scene_path)
		quit(1)
		return

	var match_instance := packed_scene.instantiate()
	if not match_instance.has_method("replay_exhausted") \
		or not match_instance.has_method("current_tick") \
		or not match_instance.has_method("entity_state"):
		printerr("--scene does not instantiate a replay Match: %s" % _scene_path)
		quit(1)
		return

	root.add_child(match_instance)
	for _frame in MAX_POLL_FRAMES:
		await process_frame
		if match_instance.replay_exhausted() and match_instance.current_tick() > 0:
			var ticks: int = match_instance.current_tick()
			var state_hash: int = match_instance.entity_state().state_hash()
			print("NATIVE_REPLAY_HASH ticks=%d hash=%d" % [ticks, state_hash])
			quit(0)
			return

	printerr("Native replay hash poll bound hit after %d frames" % MAX_POLL_FRAMES)
	quit(1)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=", true, 1)
		var key := parts[0]
		var value := parts[1] if parts.size() > 1 else ""
		match key:
			"--scene":
				_scene_path = value
			_:
				push_warning("Unknown native replay hash argument: %s" % arg)
