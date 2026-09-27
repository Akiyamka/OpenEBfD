extends "res://tests/support/suite.gd"

const RttTrackerScript := preload("res://scripts/net/rtt_tracker.gd")


func _initialize() -> void:
	_run_case("an untouched tracker has no known measurements", _test_starts_empty)
	_run_case("one peer's measurement is available as the worst", _test_one_peer)
	_run_case("a newer measurement replaces the same peer's older one", _test_replaces_measurement)
	_run_case("two peers retain independent measurements", _test_tracks_peers_independently)
	_run_case("the recommended delay floors an unknown RTT", _test_recommendation_without_measurements)
	_run_case("the recommended delay floors an RTT below two ticks", _test_recommendation_below_floor)
	_run_case("the recommended delay keeps an RTT at the floor", _test_recommendation_at_floor)
	_run_case("the recommended delay preserves an RTT above the floor", _test_recommendation_above_floor)
	_run_case("the recommended delay uses the worst peer RTT", _test_recommendation_uses_worst_peer)
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


func _test_recommendation_without_measurements() -> void:
	var tracker = RttTrackerScript.new()
	_expect(tracker.worst_known_rtt_ticks() == -1, "an untouched tracker must retain the unseen sentinel")
	_expect(tracker.recommended_input_delay_ticks() == 2, "the recommendation must floor the unseen sentinel")


func _test_recommendation_below_floor() -> void:
	var tracker = RttTrackerScript.new()
	tracker.on_pong_received(2, 1)
	_expect(tracker.recommended_input_delay_ticks() == 2, "the recommendation must floor a one-tick RTT")


func _test_recommendation_at_floor() -> void:
	var tracker = RttTrackerScript.new()
	tracker.on_pong_received(2, 2)
	_expect(tracker.recommended_input_delay_ticks() == 2, "the recommendation must preserve the two-tick boundary")


func _test_recommendation_above_floor() -> void:
	var tracker = RttTrackerScript.new()
	tracker.on_pong_received(2, 9)
	_expect(tracker.recommended_input_delay_ticks() == 9, "the recommendation must not halve or pad a nine-tick RTT")


func _test_recommendation_uses_worst_peer() -> void:
	var tracker = RttTrackerScript.new()
	tracker.on_pong_received(2, 4)
	tracker.on_pong_received(3, 9)
	_expect(tracker.recommended_input_delay_ticks() == 9, "the recommendation must use the larger peer RTT")
