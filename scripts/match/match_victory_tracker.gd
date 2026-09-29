class_name MatchVictoryTracker
extends RefCounted

var _remaining_player_ids: Array[int] = []
var _is_match_decided := false


func refresh(players: PlayerRoster, elimination: PlayerEliminationTracker) -> void:
	_remaining_player_ids.clear()
	for player_id in players.player_ids(false):
		if not elimination.is_player_eliminated(player_id):
			_remaining_player_ids.append(player_id)
	_is_match_decided = _remaining_player_ids.size() <= 1
	if _is_match_decided:
		return
	for first_index in _remaining_player_ids.size():
		for second_index in range(first_index + 1, _remaining_player_ids.size()):
			if not players.are_allied(
					_remaining_player_ids[first_index], _remaining_player_ids[second_index]
			):
				return
	_is_match_decided = true


func remaining_player_ids() -> Array[int]:
	return _remaining_player_ids.duplicate()


func is_match_decided() -> bool:
	return _is_match_decided
