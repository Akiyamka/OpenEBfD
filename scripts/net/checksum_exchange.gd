class_name ChecksumExchange
extends RefCounted

## Bounded per-tick checksum bookkeeping for comparisons with remote peers.
## The 64-tick retention window is four times the widest 16-tick input delay
## from network-multiplayer.md; a tick exactly 64 ticks old is retained.
## TurnScheduler owns transport polling and feeds remote reports here after it
## filters echoes.

const RETAINED_TICKS := 64

var _local_hash_by_tick: Dictionary = {}
var _pending_remote_hash_by_tick: Dictionary = {}
var _newest_recorded_tick := 0
var _agreement_count := 0
var _mismatch_count := 0
var _last_mismatch: Dictionary = {}
var _dropped_stale_report_count := 0


func record_local_hash(tick: int, state_hash: int) -> void:
	_newest_recorded_tick = maxi(_newest_recorded_tick, tick)
	_local_hash_by_tick[tick] = state_hash
	if _pending_remote_hash_by_tick.has(tick):
		var remote_hashes_by_sender: Dictionary = _pending_remote_hash_by_tick[tick]
		_pending_remote_hash_by_tick.erase(tick)
		for sender_player_id: int in remote_hashes_by_sender:
			_resolve(sender_player_id, tick, state_hash, int(remote_hashes_by_sender[sender_player_id]))
	_evict_stale_entries()


func on_report_received(sender_player_id: int, tick: int, remote_hash: int) -> void:
	if _is_stale(tick):
		_dropped_stale_report_count += 1
		return
	if not _local_hash_by_tick.has(tick):
		var remote_hashes_by_sender: Dictionary = _pending_remote_hash_by_tick.get(tick, {})
		remote_hashes_by_sender[sender_player_id] = remote_hash
		_pending_remote_hash_by_tick[tick] = remote_hashes_by_sender
		return
	_resolve(sender_player_id, tick, int(_local_hash_by_tick[tick]), remote_hash)


func agreement_count() -> int:
	return _agreement_count


func mismatch_count() -> int:
	return _mismatch_count


func pending_remote_count() -> int:
	var count := 0
	for remote_hashes_by_sender: Dictionary in _pending_remote_hash_by_tick.values():
		count += remote_hashes_by_sender.size()
	return count


func retained_local_hash_count() -> int:
	return _local_hash_by_tick.size()


func dropped_stale_report_count() -> int:
	return _dropped_stale_report_count


func last_mismatch() -> Dictionary:
	return _last_mismatch


func _is_stale(tick: int) -> bool:
	return tick < _newest_recorded_tick - RETAINED_TICKS


func _evict_stale_entries() -> void:
	for stored_tick: int in _local_hash_by_tick.keys():
		if _is_stale(stored_tick):
			_local_hash_by_tick.erase(stored_tick)
	for stored_tick: int in _pending_remote_hash_by_tick.keys():
		if _is_stale(stored_tick):
			var remote_hashes_by_sender: Dictionary = _pending_remote_hash_by_tick[stored_tick]
			_dropped_stale_report_count += remote_hashes_by_sender.size()
			_pending_remote_hash_by_tick.erase(stored_tick)


func _resolve(sender_player_id: int, tick: int, local_hash: int, remote_hash: int) -> void:
	if local_hash == remote_hash:
		_agreement_count += 1
		return
	_mismatch_count += 1
	_last_mismatch = {
		"sender_player_id": sender_player_id,
		"tick": tick,
		"local_hash": local_hash,
		"remote_hash": remote_hash,
	}
