extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"Match refreshes player elimination after real despawns in the same tick",
		_test_match_refreshes_after_real_despawns
	)
	if _failures > 0:
		printerr("Player elimination wiring tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Player elimination wiring tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	if _assertions == assertions_before:
		_failures += 1
		printerr("FAIL: %s: the case ended before asserting anything" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_match_refreshes_after_real_despawns() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 3:
		await process_frame
	match_instance.advance_ticks(1)
	var tracker = match_instance.player_elimination_tracker()
	_expect(tracker != null, "Match must expose its constructed PlayerEliminationTracker")
	_expect(
		tracker != null and not tracker.is_player_eliminated(1),
		"player 1's live Construction Yard and infantry must prevent elimination at boot"
	)
	var con_yard = match_instance.get_node("Buildings/ATConYard")
	var scout = match_instance.get_node("Units/ScoutA")
	# request_despawn() releases the id synchronously, while the navigation
	# system otherwise retains this fixture unit until the tick's final drain.
	# Removing that unrelated movement participant keeps this case focused on
	# Match's elimination observation rather than provoking a refused position
	# write from navigation after the id is intentionally dead.
	match_instance._unit_navigation_system.unregister_unit(scout)
	con_yard.request_despawn()
	scout.request_despawn()
	_expect(
		tracker != null and not tracker.is_player_eliminated(1),
		"request_despawn itself must not change the observable before Match refreshes it"
	)
	match_instance.advance_ticks(1)
	_expect(
		tracker != null and tracker.is_player_eliminated(1),
		"player 1 must be eliminated in the tick that observes both released counting entities"
	)
	_expect(
		tracker != null and not tracker.is_player_eliminated(2),
		"player 2's untouched APC and NIAB tank must keep player 2 alive"
	)
	match_instance.queue_free()
	await process_frame
