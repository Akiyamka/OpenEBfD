extends SceneTree

## docs/mechanics/production.md section 4 "Upgrades" (+ section 5 tech tree
## link). Covers the parts that do not need a live BuildingUpgradeController
## (queue/order math, dock layout math, player-owned purchase state, applying
## a purchase to existing buildings) the same way placement_run.gd covers
## BuildingPlacement in isolation.

const UpgradeQueueScript := preload("res://scripts/buildings/upgrade_queue.gd")
const UpgradeOrderScript := preload("res://scripts/buildings/upgrade_order.gd")
const UpgradeEffectsScript := preload("res://scripts/buildings/upgrade_effects.gd")
const BuildingScript := preload("res://scripts/buildings/building.gd")
const BuildingUpgradeControllerScript := preload("res://scripts/buildings/building_upgrade_controller.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const BuildingSurvivorsScript := preload("res://scripts/buildings/building_survivors.gd")
const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 4000


class FakeBuilding extends Node3D:
	var owner_player_id := 0
	var config_id: StringName
	var set_upgrade_level_calls: Array[int] = []

	func set_upgrade_level(level: int) -> void:
		set_upgrade_level_calls.append(level)


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Upgrade Tester", Color.RED, &"Atreides", [], 1, 1000, 0)
	players.local_player_id = 1

	_run_case("start rejects invalid orders", _test_start_rejects_invalid)
	_run_case("tick spends credits gradually and completes", _test_tick_gradual_payment)
	_run_case("tick reports lacking funds without spending", _test_tick_lacks_funds)
	_run_case("pause and resume stop and restart ticking", _test_pause_resume)
	_run_case("cancel refunds paid-in credits", _test_cancel_refund)
	_run_case("free upgrades complete on elapsed time alone", _test_free_upgrade_time_only)
	_run_case("order_ready fires exactly once per completed order", _test_order_ready_signal)

	_run_case("progress_percent tracks cost or time", _test_progress_percent)

	_run_case(
		"apply_to_existing_buildings only touches the buying player's matching buildings",
		_test_upgrade_effects_filters.bind(local_player)
	)

	_run_case("refinery dock upgrades use three persistent animated states", _test_refinery_dock_states)
	_run_case("refinery dock reservations include a departure cooldown", _test_refinery_dock_reservations)
	_run_case("refinery side docks follow upgrade side and rules angles", _test_refinery_side_dock_layout)
	_run_case(
		"dock orders auto-select an eligible refinery and never create a building",
		_test_automatic_refinery_upgrade.bind(local_player)
	)
	_run_case("missing survivor count means no survivors", _test_missing_survivor_count)
	_run_case("refinery docks use UpgradeBuildTime", _test_dock_upgrade_build_time)
	_run_case("Construction Yard upgrade uses its linked MCV build time", _test_con_yard_upgrade_build_time.bind(local_player))

	_run_case(
		"a purchased upgrade is irreversible player state, not building state",
		_test_player_purchase_state.bind(local_player)
	)

	_run_case(
		"a purchase propagates end to end: existing buildings, future buildings, tech tree gating",
		_test_purchase_propagates_end_to_end.bind(local_player)
	)

	players.reset_for_match()
	if _failures > 0:
		printerr("Upgrade tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Upgrade tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	var completed: Variant = test.call(token)
	if completed != token:
		_failures += 1
		printerr("FAIL: %s: case did not return its completion token" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_start_rejects_invalid(token: int) -> int:
	var queue := UpgradeQueueScript.new()
	# Unit tests of the queue itself: build_time_ticks below is passed
	# directly in simulation ticks (60 rule ticks == 25 sim ticks), not
	# routed through RuleTicks -- that conversion has its own tests
	# (tests/rules/run.gd).
	_expect(not queue.start(&"", "Nothing", 100, 25), "an empty upgrade id must be rejected")
	_expect(not queue.start(&"AT", "Negative cost", -1, 25), "a negative cost must be rejected")
	_expect(not queue.start(&"AT", "Zero build time", 100, 0), "a non-positive build time must be rejected")
	_expect(not queue.has_order(), "rejected starts must leave the queue empty")
	_expect(queue.start(&"AT", "Valid", 100, 25), "a valid order must start")
	_expect(not queue.start(&"AT2", "Second", 50, 13), "the queue is one order at a time, like BuildingQueue")
	return token


func _test_tick_gradual_payment(token: int) -> int:
	var queue := UpgradeQueueScript.new()
	# Unit test of the queue itself: 60 rule ticks == 25 sim ticks (see
	# tests/rules/run.gd for the conversion's own tests).
	queue.start(&"ATBarracks", "Barracks upgrade", 600, 25)
	# GDScript lambdas capture outer locals by value, not by reference, so a
	# plain int can't accumulate across calls -- box it in an Array (arrays
	# are reference types) the way BuildingQueue's own tests do.
	var spent_box := [0]
	var spend := func(amount: int) -> bool:
		spent_box[0] += amount
		return true

	# 600 credits over 25 sim ticks of build time => 24 credits per tick while
	# paying. advance_tick()'s return value means "state changed for the UI",
	# not "order complete" -- completion is read off current_order().ready.
	queue.advance_tick(1000, spend)
	_expect(not queue.current_order().ready, "a partial tick must not complete the order")
	_expect(spent_box[0] > 0 and spent_box[0] < 600, "a partial tick must spend a partial amount")
	_expect(queue.current_order().paid_cost == spent_box[0], "paid_cost must track what was actually spent")

	var iterations := 0
	while not queue.current_order().ready and iterations < 30:
		queue.advance_tick(1000, spend)
		iterations += 1

	_expect(queue.current_order().ready, "enough ticks must complete the order")
	_expect(spent_box[0] == 600, "total spend must equal exactly the order cost, no overpayment")
	return token


func _test_tick_lacks_funds(token: int) -> int:
	var queue := UpgradeQueueScript.new()
	queue.start(&"AT", "Broke", 100, 25)
	var spend_called := false
	var spend := func(_amount: int) -> bool:
		spend_called = true
		return true

	queue.advance_tick(0, spend)
	_expect(queue.lacks_funds(), "zero available credits must be reported as lacking funds")
	_expect(not spend_called, "spend_credits must not be invoked with zero available credits")
	_expect(queue.current_order().paid_cost == 0, "no credits must be paid while funds are lacking")
	return token


func _test_pause_resume(token: int) -> int:
	var queue := UpgradeQueueScript.new()
	queue.start(&"AT", "Pausable", 100, 25)
	_expect(queue.pause(), "pausing an active order must succeed")
	_expect(queue.current_order().manually_paused, "pause must flag the order as manually paused")
	var spend := func(_amount: int) -> bool:
		return true
	_expect(not queue.advance_tick(1000, spend), "a paused order must not tick")
	_expect(queue.resume(), "resuming a paused order must succeed")
	_expect(not queue.current_order().manually_paused, "resume must clear the paused flag")
	return token


func _test_cancel_refund(token: int) -> int:
	var queue := UpgradeQueueScript.new()
	queue.start(&"AT", "Cancellable", 100, 25)
	var spend := func(_amount: int) -> bool:
		return true
	queue.advance_tick(1000, spend)
	var paid := queue.current_order().paid_cost
	_expect(paid > 0, "the setup tick must have paid something")
	var refund := queue.cancel()
	_expect(refund == paid, "cancel must refund exactly what was paid in so far")
	_expect(not queue.has_order(), "cancel must clear the active order")
	return token


func _test_free_upgrade_time_only(token: int) -> int:
	var queue := UpgradeQueueScript.new()
	# Unit test of the queue itself: 3 sim ticks stands in for a short free
	# build (the rules -> sim conversion has its own tests).
	queue.start(&"AT", "Free", 0, 3)
	queue.advance_tick(0)
	_expect(not queue.current_order().ready, "an elapsed tick under build_time_ticks must not finish a free upgrade")
	queue.advance_tick(0)
	queue.advance_tick(0)
	_expect(queue.current_order().ready, "elapsed build time alone must finish a zero-cost upgrade")
	return token


func _test_order_ready_signal(token: int) -> int:
	var queue := UpgradeQueueScript.new()
	var ready_orders: Array[UpgradeOrder] = []
	queue.order_ready.connect(func(order: UpgradeOrder) -> void:
		ready_orders.append(order)
	)
	queue.start(&"AT", "Signal", 0, 1)
	var adopted_order := queue.current_order()
	queue.advance_tick(0)
	queue.advance_tick(0)
	_expect(ready_orders.size() == 1, "order_ready must fire exactly once even if advance_tick keeps being called")
	_expect(
		ready_orders.size() == 1 and ready_orders[0] == adopted_order,
		"order_ready must retransmit the exact typed order adopted by the shared queue"
	)
	return token


func _test_progress_percent(token: int) -> int:
	var costed := UpgradeOrderScript.new()
	costed.cost = 200
	costed.paid_cost = 50
	_expect(is_equal_approx(costed.progress_percent(), 25.0), "cost-based progress must be paid/cost")

	var timed := UpgradeOrderScript.new()
	timed.build_time_ticks = 100
	timed.elapsed_ticks = 40
	_expect(is_equal_approx(timed.progress_percent(), 40.0), "free upgrades must fall back to elapsed/build_time")

	var done := UpgradeOrderScript.new()
	done.ready = true
	_expect(is_equal_approx(done.progress_percent(), 100.0), "a ready order must always report 100%")
	return token


func _test_upgrade_effects_filters(token: int, _local_player: PlayerData) -> int:
	var owned_match := FakeBuilding.new()
	owned_match.owner_player_id = 1
	owned_match.config_id = &"ATBarracks"

	var owned_other_type := FakeBuilding.new()
	owned_other_type.owner_player_id = 1
	owned_other_type.config_id = &"ATSmWindtrap"

	var other_player_match := FakeBuilding.new()
	other_player_match.owner_player_id = 2
	other_player_match.config_id = &"ATBarracks"

	var buildings: Array = [owned_match, owned_other_type, other_player_match]
	UpgradeEffectsScript.apply_to_existing_buildings(buildings, 1, &"ATBarracks")

	_expect(owned_match.set_upgrade_level_calls == [1], "the owning player's matching-type building must be upgraded")
	_expect(owned_other_type.set_upgrade_level_calls.is_empty(), "a different building type must not be upgraded")
	_expect(other_player_match.set_upgrade_level_calls.is_empty(), "another player's building must not be upgraded")

	owned_match.free()
	owned_other_type.free()
	other_player_match.free()
	return token


func _test_refinery_dock_states(token: int) -> int:
	for refinery_id in [&"ATRefinery", &"ORRefinery", &"HKRefinery"]:
		_test_refinery_dock_states_for(refinery_id)
	return token


func _test_refinery_dock_states_for(refinery_id: StringName) -> void:
	var scene := load("res://assets/converted/buildings/%s/%s.scn" % [refinery_id, refinery_id]) as PackedScene
	var refinery := scene.instantiate() as Building
	root.add_child(refinery)

	var player := refinery.get_node_or_null("States/Idle/AnimationPlayer") as AnimationPlayer
	var first_pad := refinery.find_child("_3SmallPad01", true, false) as Node3D
	var second_pad := refinery.find_child("_4SmallPad02", true, false) as Node3D
	_expect(player != null, "%s idle model must expose its dock AnimationPlayer" % refinery_id)
	_expect(first_pad != null and second_pad != null, "%s must contain both built-in refinery pads" % refinery_id)
	if player == null or first_pad == null or second_pad == null:
		refinery.free()
		return

	var first_initial := first_pad.transform
	var second_initial := second_pad.transform
	_expect(refinery.dock_count() == 0 and refinery.can_add_dock(), "%s must begin in the no-upgrades state" % refinery_id)
	_expect(refinery.add_refinery_dock_upgrade(), "%s first dock state transition must succeed" % refinery_id)
	_expect(player.current_animation == &"Refinery_Pad_1", "%s first upgrade must animate _3SmallPad01" % refinery_id)
	player.advance(player.get_animation(&"Refinery_Pad_1").length + 0.1)
	var first_final := first_pad.transform
	_expect(not first_final.is_equal_approx(first_initial), "%s first pad must finish in its unfolded pose" % refinery_id)
	_expect(second_pad.transform.is_equal_approx(second_initial), "%s first upgrade must not move _4SmallPad02" % refinery_id)

	_expect(refinery.add_refinery_dock_upgrade(), "%s second dock state transition must succeed" % refinery_id)
	_expect(player.current_animation == &"Refinery_Pad_2", "%s second upgrade must animate _4SmallPad02" % refinery_id)
	player.advance(player.get_animation(&"Refinery_Pad_2").length + 0.1)
	var second_final := second_pad.transform
	_expect(not second_final.is_equal_approx(second_initial), "%s second pad must finish in its unfolded pose" % refinery_id)
	_expect(first_pad.transform.is_equal_approx(first_final), "%s opening the second pad must preserve the first pad's final pose" % refinery_id)
	player.advance(1.0)
	_expect(
		first_pad.transform.is_equal_approx(first_final) and second_pad.transform.is_equal_approx(second_final),
		"%s both dock animations must remain at their final transforms" % refinery_id
	)
	_expect(refinery.dock_count() == 2 and not refinery.can_add_dock(), "%s state 2 must be the refinery maximum" % refinery_id)
	_expect(not refinery.add_refinery_dock_upgrade(), "%s must reject a third dock state" % refinery_id)

	refinery.free()


func _test_refinery_dock_reservations(token: int) -> int:
	var refinery := BuildingScript.new()
	refinery.config_id = &"ATRefinery"
	root.add_child(refinery)
	var first := Node.new()
	var second := Node.new()
	root.add_child(first)
	root.add_child(second)

	_expect(refinery.is_refinery(), "the Refinery role must enable the runtime dock API")
	_expect(refinery.refinery_dock_capacity() == 1, "an unupgraded refinery must expose its central dock")
	var first_dock := refinery.try_reserve_refinery_dock(first)
	_expect(first_dock == 0, "the first harvester must reserve the central dock immediately")
	_expect(refinery.try_reserve_refinery_dock(second) == -1, "a reserved dock must reject a second harvester")
	refinery.release_refinery_dock(first)
	refinery._process(2.9)
	_expect(refinery.try_reserve_refinery_dock(second) == -1, "the dock must remain unavailable during its three-second departure gap")
	refinery._process(0.1)
	_expect(refinery.try_reserve_refinery_dock(second) == 0, "the dock must reopen after exactly three seconds")
	_expect(refinery.refinery_dock_world_position(0).is_finite(), "the central DeployTile must resolve to a world position")

	refinery.abandon_refinery_dock(second)
	refinery.set_refinery_upgrade_state(2)
	_expect(refinery.refinery_dock_capacity() == 3, "two completed upgrades must expose all three DeployTile entries")
	var users: Array[Node] = []
	for expected_index in 3:
		var user := Node.new()
		users.append(user)
		root.add_child(user)
		_expect(refinery.try_reserve_refinery_dock(user) == expected_index, "active docks must be reserved in deterministic rules order")

	for user in users:
		user.free()
	first.free()
	second.free()
	refinery.free()
	return token


func _test_refinery_side_dock_layout(token: int) -> int:
	var refinery := BuildingScript.new()
	refinery.config_id = &"ATRefinery"
	root.add_child(refinery)
	refinery.set_refinery_upgrade_state(1)

	var centre_user := Node.new()
	var side_user := Node.new()
	root.add_child(centre_user)
	root.add_child(side_user)
	_expect(refinery.try_reserve_refinery_dock(centre_user) == 0, "the base pad must remain the first dock")
	_expect(refinery.try_reserve_refinery_dock(side_user) == 1, "the first upgrade must expose the next logical dock")

	var right := refinery.global_transform.basis * Vector3.RIGHT
	right.y = 0.0
	right = right.normalized()
	var first_side_offset := refinery.refinery_dock_world_position(1) - refinery.global_position
	_expect(first_side_offset.dot(right) < 0.0, "the first upgrade must send its harvester to the left pad")
	var expected_left_facing := refinery.exit_direction().rotated(Vector3.UP, deg_to_rad(-45.0)).normalized()
	_expect(
		refinery.refinery_dock_facing_direction(1).is_equal_approx(expected_left_facing),
		"the left pad must apply its +45 rules angle with the converted negative yaw"
	)

	refinery.set_refinery_upgrade_state(2)
	var second_side_offset := refinery.refinery_dock_world_position(2) - refinery.global_position
	_expect(second_side_offset.dot(right) > 0.0, "the second upgrade must expose the right pad")
	var expected_right_facing := refinery.exit_direction().rotated(Vector3.UP, deg_to_rad(45.0)).normalized()
	_expect(
		refinery.refinery_dock_facing_direction(2).is_equal_approx(expected_right_facing),
		"the right pad must apply its -45 rules angle with the converted positive yaw"
	)
	refinery.set_meta(&"placement_anchor_cell", Vector2i.ZERO)
	var docking_cells := refinery.refinery_dock_navigation_cells(RefCounted.new())
	var docking_markers: Array = docking_cells.values()
	_expect(not docking_markers.is_empty(), "a refinery must expose its d/p docking cells")
	_expect(
		docking_markers.all(func(marker): return marker == "d" or marker == "p"),
		"a docking exception must include d/p cells and never building body or skirt cells"
	)

	centre_user.free()
	side_user.free()
	refinery.free()
	return token


func _test_automatic_refinery_upgrade(token: int, local_player: PlayerData) -> int:
	var full_refinery := BuildingScript.new()
	full_refinery.config_id = &"ATRefinery"
	full_refinery.owner_player_id = local_player.player_id
	root.add_child(full_refinery)
	full_refinery.set_refinery_upgrade_state(2)

	var eligible_refinery := BuildingScript.new()
	eligible_refinery.config_id = &"ATRefinery"
	eligible_refinery.owner_player_id = local_player.player_id
	root.add_child(eligible_refinery)

	var controller := BuildingUpgradeControllerScript.new()
	root.add_child(controller)
	var option_states: Array[BuildingOptionState] = []
	controller.upgrade_option_state_changed.connect(func(state: BuildingOptionState) -> void:
		if state.building_id == &"ATRefineryDock":
			option_states.append(state)
	)
	var upgrade_ids: Array[StringName] = [&"ATRefineryDock"]
	controller.setup(upgrade_ids)
	_expect(
		not option_states.is_empty() and option_states.back().state == BuildingOptionStateScript.State.AVAILABLE,
		"the dock option must be visible while any compatible refinery can upgrade"
	)

	var building_count_before := get_nodes_in_group("buildings").size()
	controller.handle_upgrade_intent(&"ATRefineryDock", MOUSE_BUTTON_LEFT)
	var order: UpgradeOrder = controller._upgrade_queue.current_order()
	_expect(order != null, "clicking the dock option must start an order immediately")
	_expect(order != null and order.target_refinery == eligible_refinery, "automatic selection must skip a full refinery")

	local_player.add_money(2400)
	# process(delta) no longer drives simulation; advance_tick() does, one
	# MatchClock.SECONDS_PER_TICK period per call. 20 simulated seconds is
	# roundi(20.0 / SECONDS_PER_TICK) ticks at the fixed 25 Hz rate.
	for _i in roundi(20.0 / MatchClockScript.SECONDS_PER_TICK):
		controller.advance_tick()
	_expect(eligible_refinery.refinery_upgrade_state == 1, "completion must advance the selected refinery to state 1")
	_expect(get_nodes_in_group("buildings").size() == building_count_before, "completion must not add a RefineryDock building")

	controller.handle_upgrade_intent(&"ATRefineryDock", MOUSE_BUTTON_LEFT)
	# Same 20-second-to-ticks conversion as above.
	for _i in roundi(20.0 / MatchClockScript.SECONDS_PER_TICK):
		controller.advance_tick()
	_expect(eligible_refinery.refinery_upgrade_state == 2, "the next order must advance the refinery to state 2")
	_expect(get_nodes_in_group("buildings").size() == building_count_before, "the second completion must not add a building either")
	_expect(
		not option_states.is_empty() and option_states.back().state == BuildingOptionStateScript.State.DISABLED,
		"the dock option must disappear when no compatible refinery can upgrade"
	)

	controller.free()
	eligible_refinery.free()
	full_refinery.free()
	return token


func _test_missing_survivor_count(token: int) -> int:
	var building := BuildingScript.new()
	building.config_id = &"ATWall"
	_expect(BuildingSurvivorsScript._survivor_count(building) == 0, "a building without NumInfantryWhenGone must not invent a survivor")
	building.config_id = &"ATSmWindtrap"
	_expect(BuildingSurvivorsScript._survivor_count(building) == 1, "an explicit NumInfantryWhenGone value must still be honored")
	building.free()
	return token


func _test_dock_upgrade_build_time(token: int) -> int:
	var definitions := BuildingDefinitionCatalogScript.new()
	var controller := BuildingUpgradeControllerScript.new()
	root.add_child(controller)
	var no_ids: Array[StringName] = []
	controller.setup(no_ids)
	var dock_config: Resource = definitions.definition(&"ATRefineryDock")
	# 720 rule ticks (DEFAULT_DOCK_UPGRADE_BUILD_TIME_TICKS) -> roundi(720 * 25 / 60) = 300 sim ticks.
	_expect(
		controller._upgrade_build_time_sim_ticks(dock_config, true) == 300,
		"refinery docks must use Rules.txt UpgradeBuildTime (720 rule ticks -> 300 sim ticks) instead of ordinary BuildTime"
	)
	controller.free()
	return token


func _test_con_yard_upgrade_build_time(token: int, local_player: PlayerData) -> int:
	var controller := BuildingUpgradeControllerScript.new()
	root.add_child(controller)
	var upgrade_ids: Array[StringName] = [&"ATConYard"]
	controller.setup(upgrade_ids)

	var con_yard := BuildingScript.new()
	con_yard.config_id = &"ATConYard"
	con_yard.owner_player_id = local_player.player_id
	root.add_child(con_yard)
	controller._start_global_upgrade_order(&"ATConYard")
	var order: UpgradeOrder = controller._upgrade_queue.current_order()
	_expect(order != null, "an owned Construction Yard must start its upgrade order")
	# 864 rule ticks (the linked MCV's build time) -> roundi(864 * 25 / 60) = 360 sim ticks.
	_expect(
		order != null and order.build_time_ticks == 360,
		"Construction Yard upgrade must use the linked MCV's 864-rule-tick build time (360 sim ticks)"
	)

	# 0.1 simulated seconds is roundi(0.1 / SECONDS_PER_TICK) ticks -- a short
	# elapsed time, same intent as the old controller.process(0.1) call.
	for _i in roundi(0.1 / MatchClockScript.SECONDS_PER_TICK):
		controller.advance_tick()
	_expect(not local_player.has_purchased_upgrade(&"ATConYard"), "Construction Yard upgrade must not complete on its first short tick")

	controller.free()
	con_yard.free()
	return token


func _test_player_purchase_state(token: int, local_player: PlayerData) -> int:
	_expect(not local_player.has_purchased_upgrade(&"ATBarracks"), "a fresh player must not start with a purchased upgrade")
	local_player.grant_upgrade(&"ATBarracks")
	_expect(local_player.has_purchased_upgrade(&"ATBarracks"), "grant_upgrade must persist as player-owned state")
	_expect(local_player.purchased_upgrade_ids().has(&"ATBarracks"), "purchased_upgrade_ids must list granted upgrades")
	_expect(not local_player.has_purchased_upgrade(&"ATSmWindtrap"), "purchases must not leak across building types")
	return token


## docs/mechanics/production.md section 5: exercises the full purchase path
## with real Building instances and real Rules data instead of stand-ins --
## grant_upgrade + apply_to_existing_buildings must reach a building already
## on the map, Building._sync_purchased_upgrade() must reach one built
## afterwards, and TechnologyTree must then treat an
## upgraded_primary_required entry as unlocked (ATRocketTurret requires an
## upgraded ATConYard plus any house's Barracks, see
## assets/converted/rules/buildings/ATRocketTurret.tres). Uses ATConYard
## (not ATBarracks, already purchased by the previous case on this same
## shared local_player) to stay independent of case order.
func _test_purchase_propagates_end_to_end(token: int, local_player: PlayerData) -> int:
	var definitions := BuildingDefinitionCatalogScript.new()

	var existing_con_yard := BuildingScript.new()
	existing_con_yard.config_id = &"ATConYard"
	existing_con_yard.owner_player_id = local_player.player_id
	root.add_child(existing_con_yard)
	_expect(existing_con_yard.upgrade_level == 0, "a building must start unupgraded before any purchase")

	_expect(not local_player.has_purchased_upgrade(&"ATConYard"), "ATConYard must not be pre-purchased on a fresh player")
	local_player.grant_upgrade(&"ATConYard")
	UpgradeEffectsScript.apply_to_existing_buildings(get_nodes_in_group("buildings"), local_player.player_id, &"ATConYard")
	_expect(existing_con_yard.upgrade_level == 1, "apply_to_existing_buildings must reach a building already on the map")

	var later_con_yard := BuildingScript.new()
	later_con_yard.config_id = &"ATConYard"
	later_con_yard.owner_player_id = local_player.player_id
	root.add_child(later_con_yard)
	_expect(later_con_yard.upgrade_level == 1, "Building._sync_purchased_upgrade must pick up a purchase on placement")

	var secondary_barracks := BuildingScript.new()
	secondary_barracks.config_id = &"ATBarracks"
	secondary_barracks.owner_player_id = local_player.player_id
	root.add_child(secondary_barracks)

	var tree := TechnologyTreeScript.new()
	var turret_config: Resource = definitions.definition(&"ATRocketTurret")
	var owned: Array[Node] = [existing_con_yard, later_con_yard, secondary_barracks]
	_expect(
		tree.is_available(turret_config, local_player, owned),
		"an upgraded_primary_required entry must unlock once the primary building's purchase has propagated"
	)

	existing_con_yard.free()
	later_con_yard.free()
	secondary_barracks.free()
	return token
