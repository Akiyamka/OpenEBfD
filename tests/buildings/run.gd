extends SceneTree

const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const BuildingScript := preload("res://scripts/buildings/building.gd")
const BuildingDefinitionScript := preload("res://scripts/buildings/building_definition.gd")
const WallLineScript := preload("res://scripts/buildings/wall_line.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 1000


class Credits:
	var money: int

	func _init(starting_money: int) -> void:
		money = starting_money

	func spend(amount: int) -> bool:
		if amount < 0 or amount > money:
			return false
		money -= amount
		return true

	func refund(amount: int) -> void:
		money += amount


func _initialize() -> void:
	_run_case("paid and free progress", _test_paid_and_free_progress)
	_run_case("incremental charging and insufficient credits", _test_incremental_charging)
	_run_case("no catch-up while credits are absent", _test_no_catch_up_without_credits)
	_run_case("pause and resume", _test_pause_and_resume)
	_run_case("cancel refunds exactly paid credits", _test_cancel_refund)
	_run_case("ready signal and consume handoff", _test_ready_and_consume)
	_run_case("start contract", _test_start_contract)
	_run_case("wall lines connect every segment by a side", _test_wall_line_side_connectivity)
	await _run_async_case(
		"rally line follows spawn, exit, and destination", _test_two_segment_rally_line
	)
	await _run_async_case(
		"attackable buildings generate bounded combat hulls",
		_test_combat_hull_budget
	)

	if _failures > 0:
		printerr("BuildingQueue tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("BuildingQueue tests: %d assertions passed" % _assertions)
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


func _run_async_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	var completed: Variant = await test.call(token)
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


func _test_paid_and_free_progress(token: int) -> int:
	var credits = Credits.new(100)
	var paid_queue = BuildingQueueScript.new()
	# Unit tests of the queue itself: build_time_ticks below is passed
	# directly in simulation ticks, not routed through RuleTicks -- that
	# conversion has its own tests (tests/rules/run.gd).
	_expect(paid_queue.start(&"Paid", "Paid", 60, 20), "a valid paid order must start")
	for _index in 10:
		paid_queue.advance_tick(credits.money, credits.spend)
	_expect(credits.money == 70, "paid construction must charge proportionally across its ticks")
	_expect(is_equal_approx(paid_queue.current_order().progress_percent(), 50.0), "paid progress must equal paid credits")

	var free_queue = BuildingQueueScript.new()
	_expect(free_queue.start(&"Free", "Free", 0, 4), "a valid free order must start")
	free_queue.advance_tick(0)
	free_queue.advance_tick(0)
	_expect(is_equal_approx(free_queue.current_order().progress_percent(), 50.0), "free progress must use elapsed ticks")
	free_queue.advance_tick(0)
	free_queue.advance_tick(0)
	_expect(free_queue.current_order().ready, "free construction must become ready at its tick duration")
	return token


func _test_incremental_charging(token: int) -> int:
	var credits = Credits.new(6)
	var queue = BuildingQueueScript.new()
	queue.start(&"Incremental", "Incremental", 20, 2)
	queue.advance_tick(credits.money, credits.spend)
	_expect(queue.current_order().paid_cost == 6, "partial funds must pay only the available credits")
	_expect(credits.money == 0, "the payer must lose exactly the paid credits")
	_expect(queue.lacks_funds(), "partial payment must leave the order waiting for credits")
	_expect(is_equal_approx(queue.current_order().charge_accumulator, 0.0), "unpaid whole credits must not stay due")
	credits.refund(14)
	queue.advance_tick(credits.money, credits.spend)
	_expect(queue.current_order().paid_cost == 16, "charging must resume incrementally after funds return")
	queue.advance_tick(credits.money, credits.spend)
	_expect(queue.current_order().ready, "paying the full cost must make the order ready")
	_expect(credits.money == 0, "all charged credits must be spent exactly once")
	return token


func _test_no_catch_up_without_credits(token: int) -> int:
	var credits = Credits.new(0)
	var queue = BuildingQueueScript.new()
	_expect(queue.start(&"NoCatchUp", "NoCatchUp", 100, 4), "a paid order must start without credits")
	queue.advance_tick(credits.money, credits.spend)
	_expect(queue.lacks_funds(), "a zero-credit tick must enter the waiting-for-credits state")
	_expect(is_equal_approx(queue.current_order().progress_percent(), 0.0), "absent credits must not advance paid progress")
	credits.refund(100)
	queue.advance_tick(credits.money, credits.spend)
	_expect(queue.current_order().paid_cost == 25, "returning credits must charge only the current tick")
	_expect(credits.money == 75, "the missed zero-credit tick must not be charged later")
	_expect(not queue.lacks_funds(), "a successful current charge must leave waiting-for-credits state")
	_expect(is_equal_approx(queue.current_order().progress_percent(), 25.0), "progress must reflect only the current tick payment")
	return token


func _test_pause_and_resume(token: int) -> int:
	var credits = Credits.new(100)
	var queue = BuildingQueueScript.new()
	queue.start(&"Paused", "Paused", 0, 1)
	_expect(queue.pause(), "a running order must pause")
	queue.advance_tick(credits.money, credits.spend)
	_expect(is_equal_approx(queue.current_order().progress_percent(), 0.0), "paused construction must not advance")
	_expect(queue.resume(), "a paused order must resume")
	queue.advance_tick(credits.money, credits.spend)
	_expect(queue.current_order().ready, "resumed construction must advance normally")
	_expect(not queue.pause(), "a ready order must not pause")
	return token


func _test_cancel_refund(token: int) -> int:
	var credits = Credits.new(100)
	var queue = BuildingQueueScript.new()
	queue.start(&"Canceled", "Canceled", 100, 4)
	queue.advance_tick(credits.money, credits.spend)
	var refund := queue.cancel()
	credits.refund(refund)
	_expect(refund == 25, "cancel must return exactly the paid amount")
	_expect(credits.money == 100, "refunding the returned amount must restore only paid credits")
	_expect(not queue.has_order(), "cancel must clear the order")
	_expect(queue.cancel() == 0, "cancel without an order must refund nothing")
	return token


func _test_ready_and_consume(token: int) -> int:
	var queue = BuildingQueueScript.new()
	var ready_events := [0]
	var emitted_orders: Array[BuildingOrder] = []
	queue.order_ready.connect(func(order: BuildingOrder) -> void:
		ready_events[0] += 1
		emitted_orders.append(order)
	)
	queue.start(&"Ready", "Ready", 0, 1)
	var adopted_order := queue.current_order()
	queue.advance_tick(0)
	queue.advance_tick(0)
	_expect(ready_events[0] == 1, "ready must emit exactly once")
	_expect(
		emitted_orders.size() == 1 and emitted_orders[0] == adopted_order,
		"ready must emit the exact typed order adopted by the shared queue"
	)
	var ready_order = queue.take_ready()
	_expect(ready_order != null and ready_order.building_id == &"Ready", "take_ready must hand off the ready order")
	_expect(ready_order == adopted_order, "take_ready must return the exact adopted order instance")
	_expect(not queue.has_order(), "take_ready must consume the queue order")
	_expect(queue.take_ready() == null, "a ready order must be consumed only once")
	return token


func _test_start_contract(token: int) -> int:
	var queue = BuildingQueueScript.new()
	_expect(not queue.start(&"", "Missing id", 0, 25), "an empty building id must be rejected")
	_expect(not queue.start(&"InvalidCost", "Invalid", -1, 25), "a negative cost must be rejected")
	_expect(not queue.start(&"InvalidTime", "Invalid", 0, 0), "a non-positive build duration must be rejected")
	_expect(queue.start(&"First", "First", 0, 25), "a valid order must start after rejected inputs")
	_expect(not queue.start(&"Second", "Second", 0, 25), "a duplicate queue start must be rejected")
	return token


func _test_wall_line_side_connectivity(token: int) -> int:
	var cases := [
		[Vector2i(0, 0), Vector2i(5, 0)],
		[Vector2i(0, 0), Vector2i(0, -4)],
		[Vector2i(0, 0), Vector2i(5, 2)],
		[Vector2i(3, -2), Vector2i(-2, 4)],
		[Vector2i(4, 4), Vector2i(-1, -1)],
	]
	for endpoints in cases:
		var start: Vector2i = endpoints[0]
		var finish: Vector2i = endpoints[1]
		var cells: Array[Vector2i] = WallLineScript.occupy_cells_between(start, finish)
		_expect(cells.front() == start, "a wall line must retain its selected start")
		_expect(cells.back() == finish, "a wall line must retain its selected end")
		_expect(
			cells.size() == absi(finish.x - start.x) + absi(finish.y - start.y) + 1,
			"a wall line must contain one side-connected step per changed coordinate"
		)
		for index in range(1, cells.size()):
			var step := cells[index] - cells[index - 1]
			_expect(
				absi(step.x) + absi(step.y) == 1,
				"neighboring wall cells must share a side, not only a corner"
			)

		var backwards: Array[Vector2i] = WallLineScript.occupy_cells_between(finish, start)
		var reversed := cells.duplicate()
		reversed.reverse()
		_expect(
			backwards == reversed,
			"reversing the selected endpoints must reverse the same wall path"
		)
	return token


func _test_two_segment_rally_line(token: int) -> int:
	var building := BuildingScript.new()
	var definition := BuildingDefinitionScript.new()
	definition.ai_manufacturing = true
	definition.occupy_rows = ["oo", "oo", "ss"]
	building.building_definition = definition
	building.position = Vector3(12.0, 3.0, 8.0)
	building.rotation.y = PI / 2.0

	var states := Node3D.new()
	states.name = "States"
	building.add_child(states)
	var idle := Node3D.new()
	idle.name = "Idle"
	states.add_child(idle)
	var slct := Node3D.new()
	slct.name = "AuthoredSpawn"
	slct.set_meta("original_name", "SLCT")
	slct.position = Vector3(1.0, 0.0, 0.5)
	idle.add_child(slct)
	root.add_child(building)
	await process_frame

	var rally_point := building.to_global(Vector3(-4.0, 0.0, 8.0))
	_expect(building.set_rally_point(rally_point), "a production building must accept a rally point")
	var rally_line := building.get_node("RallyPointLine") as MeshInstance3D
	var rally_line_arrays := rally_line.mesh.surface_get_arrays(0)
	var vertices := rally_line_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	_expect(
		vertices.size() == 12,
		"the rally line must contain separate spawn-to-exit and exit-to-rally segments"
	)
	if vertices.size() == 12:
		var first_start := (vertices[0] + vertices[5]) * 0.5
		var first_finish := (vertices[1] + vertices[2]) * 0.5
		var second_start := (vertices[6] + vertices[11]) * 0.5
		var second_finish := (vertices[7] + vertices[8]) * 0.5
		var expected_spawn := building.to_local(building.production_spawn_position())
		var expected_exit := building.to_local(building.production_exit_position())
		var expected_rally := building.to_local(rally_point)
		expected_spawn.y += BuildingScript.RALLY_POINT_LINE_HEIGHT
		expected_exit.y += BuildingScript.RALLY_POINT_LINE_HEIGHT
		expected_rally.y += BuildingScript.RALLY_POINT_LINE_HEIGHT
		_expect(
			first_start.is_equal_approx(expected_spawn)
			and first_finish.is_equal_approx(expected_exit)
			and second_start.is_equal_approx(expected_exit)
			and second_finish.is_equal_approx(expected_rally),
			"the two segments must follow the SLCT spawn, production exit, and rally point"
		)

	building.queue_free()
	return token


func _test_combat_hull_budget(token: int) -> int:
	var candidates := [
		"ORRefinery", "ORSmWindtrap", "ORStarport", "ORWall",
		"ORPalace", "ATPalace", "HKPalace", "HKStarport", "HKRefinery",
	]
	for building_name in candidates:
		var scene_path := "res://assets/converted/buildings/%s/%s.scn" % [
			building_name, building_name
		]
		var scene := load(scene_path) as PackedScene
		var building := scene.instantiate() as Building
		_expect(
			building.has_meta("combat_hull"),
			"%s combat hull must be baked into the converted scene" % building_name
		)
		_expect(
			building.get_node_or_null("CombatCollision") != null,
			"%s projectile proxy must be baked into the converted scene" % building_name
		)
		var combat_shape := building.get_node_or_null(
			"CombatCollision/CombatHull"
		) as CollisionShape3D
		_expect(
			combat_shape != null
				and combat_shape.shape is ConcavePolygonShape3D
				and int(building.get_meta(
					"combat_collision_triangle_count", 0
				)) > 0,
			"%s projectile proxy must retain filtered source triangles"
				% building_name
		)
		root.add_child(building)
		var hull := building.combat_hull()
		var minimum_y := float(building.get_meta("combat_hull_minimum_y"))
		var maximum_y := float(building.get_meta("combat_hull_maximum_y"))
		_expect(
			hull.size() >= 3
				and hull.size() <= BuildingScript.MAX_COMBAT_HULL_VERTICES,
			"%s combat hull must fit the strict vertex budget" % building_name
		)
		_expect(
			maximum_y > minimum_y,
			"%s must bake a non-empty vertical combat range" % building_name
		)
		var outside_z := hull[0].y + 100.0
		var middle_y := (minimum_y + maximum_y) * 0.5
		var low_aim := building.to_local(building.combat_aim_position_from(
			building.to_global(Vector3(0.0, minimum_y - 10.0, outside_z))
		))
		var middle_aim := building.to_local(building.combat_aim_position_from(
			building.to_global(Vector3(0.0, middle_y, outside_z))
		))
		var high_aim := building.to_local(building.combat_aim_position_from(
			building.to_global(Vector3(0.0, maximum_y + 10.0, outside_z))
		))
		_expect(
			is_equal_approx(low_aim.y, minimum_y)
				and is_equal_approx(middle_aim.y, middle_y)
				and is_equal_approx(high_aim.y, maximum_y),
			"%s aim height must follow the attacker within baked bounds" % building_name
		)
		if building_name == "HKStarport":
			_expect(
				not building.combat_contains_impact_position(
					building.to_global(Vector3(0.0, 0.0, 4.0))
				),
				"HKStarport ground apron must remain outside its combat hull"
			)
		elif building_name == "HKRefinery":
			_expect(
				not building.combat_contains_impact_position(
					building.to_global(Vector3(0.0, 0.0, 4.0))
				),
				"HKRefinery loadingramp23 must remain outside its combat hull"
			)
		building.free()
	return token
