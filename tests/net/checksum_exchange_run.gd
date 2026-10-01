extends "res://tests/support/suite.gd"

const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")


func _initialize() -> void:
	_run_case("local hash followed by matching remote report agrees", _test_local_then_remote_agreement)
	_run_case("remote report followed by matching local hash agrees", _test_remote_then_local_agreement)
	_run_case("a mismatch is recorded identically in both arrival orders", _test_mismatch_both_orders)
	_run_case("different ticks resolve independently", _test_independent_ticks)
	_run_case("two peers agree against an already-recorded local hash", _test_multiple_immediate_agreements)
	_run_case("a mixed peer result attributes the mismatch to its sender", _test_mixed_peer_results)
	_run_case("two early peer reports resolve independently", _test_multiple_buffered_reports)
	_run_case("retained local hashes have an exact bounded capacity", _test_retained_local_hash_count)
	_run_case("the retention window includes its lower endpoint", _test_retention_window_edges)
	_run_case("a report for an evicted local hash is counted stale", _test_evicted_local_hash_report)
	_run_case("an evicted pending report is counted stale", _test_evicted_pending_report)
	_run_case("evicting pending reports counts each peer", _test_evicted_multiple_pending_reports)
	_run_case("eviction preserves checksum comparison history", _test_eviction_preserves_history)
	_finish("Checksum exchange tests")


func _test_local_then_remote_agreement() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.record_local_hash(5, 100)
	exchange.on_report_received(2, 5, 100)
	_expect(exchange.agreement_count() == 1, "matching hashes must count as one agreement")
	_expect(exchange.pending_remote_count() == 0, "a directly resolved report must not be pending")


func _test_remote_then_local_agreement() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.on_report_received(2, 5, 100)
	_expect(exchange.pending_remote_count() == 1, "an early remote report must be buffered")
	exchange.record_local_hash(5, 100)
	_expect(exchange.agreement_count() == 1, "the later local hash must resolve the buffered report")
	_expect(exchange.pending_remote_count() == 0, "the resolved buffered report must be removed")


func _test_mismatch_both_orders() -> void:
	var local_then_remote = ChecksumExchangeScript.new()
	local_then_remote.record_local_hash(6, 100)
	local_then_remote.on_report_received(2, 6, 999)
	_expect(local_then_remote.mismatch_count() == 1, "a differing later remote hash must count as mismatch")
	_expect(
		local_then_remote.last_mismatch()
		== {"sender_player_id": 2, "tick": 6, "local_hash": 100, "remote_hash": 999},
		"a mismatch must retain its exact tick and both hash values"
	)

	var remote_then_local = ChecksumExchangeScript.new()
	remote_then_local.on_report_received(2, 7, 999)
	remote_then_local.record_local_hash(7, 100)
	_expect(remote_then_local.mismatch_count() == 1, "a buffered differing report must count as mismatch")
	_expect(
		remote_then_local.last_mismatch()
		== {"sender_player_id": 2, "tick": 7, "local_hash": 100, "remote_hash": 999},
		"a buffered mismatch must retain its exact tick and both hash values"
	)


func _test_independent_ticks() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.on_report_received(2, 10, 10)
	exchange.on_report_received(2, 11, 20)
	exchange.record_local_hash(11, 20)
	exchange.record_local_hash(10, 10)
	_expect(exchange.agreement_count() == 2, "two separate ticks must each resolve their own agreement")
	_expect(exchange.pending_remote_count() == 0, "resolving one tick must not lose another buffered tick")


func _test_multiple_immediate_agreements() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.record_local_hash(8, 100)
	exchange.on_report_received(2, 8, 100)
	exchange.on_report_received(3, 8, 100)
	_expect(exchange.agreement_count() == 2, "each matching peer report must resolve independently")
	_expect(exchange.pending_remote_count() == 0, "immediately resolved peer reports must not be pending")


func _test_mixed_peer_results() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.record_local_hash(9, 100)
	exchange.on_report_received(2, 9, 100)
	exchange.on_report_received(3, 9, 999)
	_expect(exchange.agreement_count() == 1, "the matching peer must count as one agreement")
	_expect(exchange.mismatch_count() == 1, "the differing peer must count as one mismatch")
	_expect(
		exchange.last_mismatch()["sender_player_id"] == 3,
		"the mismatch must name the peer that sent the differing hash"
	)


func _test_multiple_buffered_reports() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.on_report_received(2, 10, 100)
	exchange.on_report_received(3, 10, 999)
	_expect(exchange.pending_remote_count() == 2, "two early reports from different peers must both be buffered")
	exchange.record_local_hash(10, 100)
	_expect(exchange.pending_remote_count() == 0, "recording the local hash must resolve every buffered peer")
	_expect(exchange.agreement_count() == 1, "the matching buffered peer must count as one agreement")
	_expect(exchange.mismatch_count() == 1, "the differing buffered peer must count as one mismatch")


func _test_retained_local_hash_count() -> void:
	var exchange = ChecksumExchangeScript.new()
	var checksum_intervals_to_record := ChecksumExchangeScript.RETAINED_TICKS / 8 + 20
	for interval in range(1, checksum_intervals_to_record + 1):
		exchange.record_local_hash(interval * 8, interval)
	_expect(
		exchange.retained_local_hash_count() == ChecksumExchangeScript.RETAINED_TICKS / 8 + 1,
		"the retained range must include both the newest tick and its lower endpoint"
	)


func _test_retention_window_edges() -> void:
	var exchange = ChecksumExchangeScript.new()
	var newest_tick := ChecksumExchangeScript.RETAINED_TICKS + 10
	var retained_lower_endpoint := newest_tick - ChecksumExchangeScript.RETAINED_TICKS
	exchange.record_local_hash(newest_tick, 100)
	exchange.on_report_received(2, retained_lower_endpoint, 200)
	_expect(exchange.pending_remote_count() == 1, "a report at the lower endpoint must be retained")
	exchange.record_local_hash(retained_lower_endpoint, 200)
	_expect(exchange.agreement_count() == 1, "a local hash at the lower endpoint must resolve its report")
	_expect(exchange.pending_remote_count() == 0, "the retained lower-endpoint report must resolve")
	exchange.on_report_received(2, retained_lower_endpoint - 1, 300)
	_expect(exchange.pending_remote_count() == 0, "a report below the lower endpoint must not be queued")
	_expect(exchange.dropped_stale_report_count() == 1, "a report below the lower endpoint must count stale")


func _test_evicted_local_hash_report() -> void:
	var exchange = ChecksumExchangeScript.new()
	var first_tick := 8
	exchange.record_local_hash(first_tick, 100)
	exchange.record_local_hash(first_tick + ChecksumExchangeScript.RETAINED_TICKS + 1, 200)
	exchange.on_report_received(2, first_tick, 100)
	_expect(exchange.agreement_count() == 0, "a matching report for an evicted hash must not agree")
	_expect(exchange.pending_remote_count() == 0, "a report for an evicted hash must not be queued")
	_expect(exchange.dropped_stale_report_count() == 1, "a report for an evicted hash must count stale")


func _test_evicted_pending_report() -> void:
	var exchange = ChecksumExchangeScript.new()
	var pending_tick := 8
	exchange.on_report_received(2, pending_tick, 100)
	_expect(exchange.pending_remote_count() == 1, "an early report must be pending before eviction")
	exchange.record_local_hash(pending_tick + ChecksumExchangeScript.RETAINED_TICKS + 1, 200)
	_expect(exchange.pending_remote_count() == 0, "a pending report outside the window must be evicted")
	_expect(exchange.dropped_stale_report_count() == 1, "an evicted pending report must count stale")


func _test_evicted_multiple_pending_reports() -> void:
	var exchange = ChecksumExchangeScript.new()
	var pending_tick := 8
	exchange.on_report_received(2, pending_tick, 100)
	exchange.on_report_received(3, pending_tick, 200)
	_expect(exchange.pending_remote_count() == 2, "two peers' reports must both be pending before eviction")
	exchange.record_local_hash(pending_tick + ChecksumExchangeScript.RETAINED_TICKS + 1, 300)
	_expect(exchange.pending_remote_count() == 0, "every pending peer report outside the window must be evicted")
	_expect(exchange.dropped_stale_report_count() == 2, "eviction must count stale reports rather than stale ticks")


func _test_eviction_preserves_history() -> void:
	var exchange = ChecksumExchangeScript.new()
	var agreement_tick := 8
	var mismatch_tick := 9
	exchange.record_local_hash(agreement_tick, 100)
	exchange.on_report_received(2, agreement_tick, 100)
	exchange.record_local_hash(mismatch_tick, 200)
	exchange.on_report_received(3, mismatch_tick, 999)
	exchange.record_local_hash(agreement_tick + ChecksumExchangeScript.RETAINED_TICKS + 2, 300)
	_expect(exchange.agreement_count() == 1, "eviction must not reset agreement history")
	_expect(exchange.mismatch_count() == 1, "eviction must not reset mismatch history")
	_expect(
		exchange.last_mismatch()
		== {"sender_player_id": 3, "tick": mismatch_tick, "local_hash": 200, "remote_hash": 999},
		"eviction must retain the original mismatch details"
	)
