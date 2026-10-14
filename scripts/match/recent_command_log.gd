class_name RecentCommandLog
extends RefCounted

const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")

const FNV_OFFSET_BASIS := 0x811c9dc5

var _window_ticks: int
var _count_by_player: Dictionary = {}
var _content_digest_by_player: Dictionary = {}
var _timed_digest_by_player: Dictionary = {}
var _recent_entries: Array[Dictionary] = []


func _init(window_ticks: int) -> void:
	_window_ticks = window_ticks


func record(tick: int, commands: Array) -> void:
	for command in commands:
		var player_id: int = command.player_id
		var description := TurnSchedulerScript.describe_command(command)
		_count_by_player[player_id] = count_for(player_id) + 1
		_content_digest_by_player[player_id] = TurnSchedulerScript._fnv1a32(
			(description + "\n").to_utf8_buffer(), content_digest_for(player_id)
		)
		_timed_digest_by_player[player_id] = TurnSchedulerScript._fnv1a32(
			("tick %d %s\n" % [tick, description]).to_utf8_buffer(), timed_digest_for(player_id)
		)
		_recent_entries.append({"tick": tick, "player_id": player_id, "description": description})
	while not _recent_entries.is_empty() and int(_recent_entries[0]["tick"]) < tick - _window_ticks:
		_recent_entries.pop_front()


func count_for(player_id: int) -> int:
	return int(_count_by_player.get(player_id, 0))


func content_digest_for(player_id: int) -> int:
	return int(_content_digest_by_player.get(player_id, FNV_OFFSET_BASIS))


func timed_digest_for(player_id: int) -> int:
	return int(_timed_digest_by_player.get(player_id, FNV_OFFSET_BASIS))


func recent_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"[desync] commands executed in the last %d ticks: %d" % [_window_ticks, _recent_entries.size()],
	])
	for entry in _recent_entries:
		lines.append("[desync] tick %d player %d %s" % [
			entry["tick"], entry["player_id"], entry["description"],
		])
	return lines
