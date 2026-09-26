class_name ChecksumExchange
extends RefCounted

## Pure per-tick checksum bookkeeping for a two-client exchange. TurnScheduler
## owns transport polling and feeds remote reports here after it filters echoes.

var _local_hash_by_tick: Dictionary = {}
var _pending_remote_hash_by_tick: Dictionary = {}
var _agreement_count := 0
var _mismatch_count := 0
var _last_mismatch: Dictionary = {}


func record_local_hash(tick: int, state_hash: int) -> void:
	_local_hash_by_tick[tick] = state_hash
	if not _pending_remote_hash_by_tick.has(tick):
		return
	var remote_hash: int = _pending_remote_hash_by_tick[tick]
	_pending_remote_hash_by_tick.erase(tick)
	_resolve(tick, state_hash, remote_hash)


func on_report_received(tick: int, remote_hash: int) -> void:
	if not _local_hash_by_tick.has(tick):
		_pending_remote_hash_by_tick[tick] = remote_hash
		return
	_resolve(tick, int(_local_hash_by_tick[tick]), remote_hash)


func agreement_count() -> int:
	return _agreement_count


func mismatch_count() -> int:
	return _mismatch_count


func pending_remote_count() -> int:
	return _pending_remote_hash_by_tick.size()


func last_mismatch() -> Dictionary:
	return _last_mismatch


func _resolve(tick: int, local_hash: int, remote_hash: int) -> void:
	if local_hash == remote_hash:
		_agreement_count += 1
		return
	_mismatch_count += 1
	_last_mismatch = {"tick": tick, "local_hash": local_hash, "remote_hash": remote_hash}
