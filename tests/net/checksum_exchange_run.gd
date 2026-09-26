extends "res://tests/support/suite.gd"

const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")


func _initialize() -> void:
	_run_case("local hash followed by matching remote report agrees", _test_local_then_remote_agreement)
	_run_case("remote report followed by matching local hash agrees", _test_remote_then_local_agreement)
	_run_case("a mismatch is recorded identically in both arrival orders", _test_mismatch_both_orders)
	_run_case("different ticks resolve independently", _test_independent_ticks)
	_finish("Checksum exchange tests")


func _test_local_then_remote_agreement() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.record_local_hash(5, 100)
	exchange.on_report_received(5, 100)
	_expect(exchange.agreement_count() == 1, "matching hashes must count as one agreement")
	_expect(exchange.pending_remote_count() == 0, "a directly resolved report must not be pending")


func _test_remote_then_local_agreement() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.on_report_received(5, 100)
	_expect(exchange.pending_remote_count() == 1, "an early remote report must be buffered")
	exchange.record_local_hash(5, 100)
	_expect(exchange.agreement_count() == 1, "the later local hash must resolve the buffered report")
	_expect(exchange.pending_remote_count() == 0, "the resolved buffered report must be removed")


func _test_mismatch_both_orders() -> void:
	var local_then_remote = ChecksumExchangeScript.new()
	local_then_remote.record_local_hash(6, 100)
	local_then_remote.on_report_received(6, 999)
	_expect(local_then_remote.mismatch_count() == 1, "a differing later remote hash must count as mismatch")
	_expect(
		local_then_remote.last_mismatch() == {"tick": 6, "local_hash": 100, "remote_hash": 999},
		"a mismatch must retain its exact tick and both hash values"
	)

	var remote_then_local = ChecksumExchangeScript.new()
	remote_then_local.on_report_received(7, 999)
	remote_then_local.record_local_hash(7, 100)
	_expect(remote_then_local.mismatch_count() == 1, "a buffered differing report must count as mismatch")
	_expect(
		remote_then_local.last_mismatch() == {"tick": 7, "local_hash": 100, "remote_hash": 999},
		"a buffered mismatch must retain its exact tick and both hash values"
	)


func _test_independent_ticks() -> void:
	var exchange = ChecksumExchangeScript.new()
	exchange.on_report_received(10, 10)
	exchange.on_report_received(11, 20)
	exchange.record_local_hash(11, 20)
	exchange.record_local_hash(10, 10)
	_expect(exchange.agreement_count() == 2, "two separate ticks must each resolve their own agreement")
	_expect(exchange.pending_remote_count() == 0, "resolving one tick must not lose another buffered tick")
