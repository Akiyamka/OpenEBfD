extends "res://scripts/match/match.gd"

var restore_startup_for_test := false
var snapshot_path_for_test := ""
var match_seed_args_for_test := PackedStringArray()


func _match_seed_args() -> PackedStringArray:
	return match_seed_args_for_test


func _snapshot_storage_path() -> String:
	return snapshot_path_for_test if not snapshot_path_for_test.is_empty() else super._snapshot_storage_path()

## Automated match tests must always start from the authored fixture below.
## The manual demo scene deliberately restores user://main_snapshot.json, which
## would make test contents depend on the last F7 snapshot made by a developer.
func _restore_saved_startup_state() -> void:
	if restore_startup_for_test:
		super._restore_saved_startup_state()
