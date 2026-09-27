extends "res://tests/support/suite.gd"

const RttTrackerScript := preload("res://scripts/net/rtt_tracker.gd")


func _initialize() -> void:
	_run_case("an untouched tracker has no known measurements", _test_starts_empty)
	_run_case("one peer's measurement is available as the worst", _test_one_peer)
	_run_case("a newer measurement replaces the same peer's older one", _test_replaces_measurement)
	_run_case("two peers retain independent measurements", _test_tracks_peers_independently)
	_finish("RTT tracker tests")


func _test_starts_empty() -> void:
	var tracker = RttTrackerScript.new()
	_expect(tracker.worst_known_rtt_ticks() == -1, "an untouched tracker must have no worst measurement")
	_expect(tracker.known_peer_count() == 0, "an untouched tracker must know no peers")
	_expect(tracker.rtt_ticks_for(99) == -1, "an untouched tracker must return the unseen sentinel")


func _test_one_peer() -> void:
	var tracker = RttTrackerScript.new()
	tracker.on_pong_received(2, 7)
	_expect(tracker.rtt_ticks_for(2) == 7, "the peer's latest measurement must be available")
	_expect(tracker.worst_known_rtt_ticks() == 7, "one peer's measurement must also be the worst")


func _test_replaces_measurement() -> void:
	var tracker = RttTrackerScript.new()
	tracker.on_pong_received(2, 9)
	tracker.on_pong_received(2, 3)
	_expect(tracker.rtt_ticks_for(2) == 3, "a smaller newer measurement must replace the older one")
	_expect(tracker.worst_known_rtt_ticks() == 3, "the replaced measurement must determine the current worst")


func _test_tracks_peers_independently() -> void:
	var tracker = RttTrackerScript.new()
	tracker.on_pong_received(2, 4)
	tracker.on_pong_received(3, 8)
	_expect(tracker.rtt_ticks_for(2) == 4, "the first peer must retain its own measurement")
	_expect(tracker.rtt_ticks_for(3) == 8, "the second peer must retain its own measurement")
	_expect(tracker.worst_known_rtt_ticks() == 8, "the largest peer measurement must be the worst")
	_expect(tracker.known_peer_count() == 2, "two distinct senders must count as two known peers")
