class_name RttTracker
extends RefCounted

## Keeps the newest observed round-trip measurement for each remote peer.

var _rtt_ticks_by_sender: Dictionary = {}


func on_pong_received(sender_player_id: int, rtt_ticks: int) -> void:
	_rtt_ticks_by_sender[sender_player_id] = rtt_ticks


func rtt_ticks_for(sender_player_id: int) -> int:
	return int(_rtt_ticks_by_sender.get(sender_player_id, -1))


func worst_known_rtt_ticks() -> int:
	var worst_rtt_ticks := -1
	for rtt_ticks: int in _rtt_ticks_by_sender.values():
		worst_rtt_ticks = maxi(worst_rtt_ticks, rtt_ticks)
	return worst_rtt_ticks


func known_peer_count() -> int:
	return _rtt_ticks_by_sender.size()
