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
