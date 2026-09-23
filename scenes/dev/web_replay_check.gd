extends "res://scripts/match/match.gd"

@export var replay_path := "res://scenes/dev/web_replay_check.oebr"


func _restore_saved_startup_state() -> void:
	pass


func _ready() -> void:
	super()
	var result: Dictionary = load_replay(replay_path)
	print(
		"WEB_REPLAY_CHECK_RESULT ok=%s message=%s"
		% [bool(result.get("ok", false)), String(result.get("message", ""))]
	)
