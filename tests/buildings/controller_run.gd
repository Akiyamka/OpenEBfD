extends SceneTree

const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")
const BuildingOrderScript := preload("res://scripts/buildings/building_order.gd")
const UpgradeEffectsScript := preload("res://scripts/buildings/upgrade_effects.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const WallChainScript := preload("res://scripts/buildings/wall_chain.gd")
const ATConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const PlacementBuildingScene := preload("res://assets/converted/placement/build_building.scn")
const PlacementWallScene := preload("res://assets/converted/placement/build_wall.scn")
const PlacementContextScript := preload("res://scripts/buildings/placement_context.gd")
const ProductionSystemScript := preload("res://scripts/production/production_system.gd")
const SimBuildOrderCommandScript := preload("res://scripts/sim/commands/build_order_command.gd")
const CommandPumpScript := preload("res://tests/match/support/command_pump.gd")

## Status line each mode emits on its way out, keyed the same as _enter_mode().
const MODE_CANCEL_STATUS := {
	&"sell": "Sell mode canceled",
	&"repair": "Repair mode canceled",
	&"wall_line": "Wall mode canceled",
}

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 3000


## Minimal group-member stand-in for TechnologyTree/UpgradeEffects lookups
## (config_id/owner_player_id/upgrade_level), the same shape as the stubs in
## tests/characterization/run.gd and tests/buildings/upgrade_run.gd, sized
## for BuildingController's own "buildings" group polling instead.
class BuildingStub extends Node:
	signal owner_changed(player_id: int)
	signal construction_completed
	signal upgrade_level_changed(level: int)

	var owner_player_id: int
	var config_id: StringName
	var upgrade_level := 0
	var construction_complete := true

	func _init(new_config_id: StringName, new_owner_player_id: int) -> void:
		config_id = new_config_id
		owner_player_id = new_owner_player_id
		add_to_group("buildings")

	func set_upgrade_level(level: int) -> void:
		upgrade_level = level
		upgrade_level_changed.emit(level)

	func set_owner_player_id(player_id: int) -> void:
		owner_player_id = player_id
		owner_changed.emit(player_id)

	func finish_construction() -> void:
		construction_complete = true
		construction_completed.emit()

	func is_construction_complete() -> bool:
		return construction_complete


class GestureController extends BuildingController:
	var placement_attempts: Array[Vector2] = []

	func _try_place_ready_building(screen_position: Vector2) -> void:
		placement_attempts.append(screen_position)


class SaleController extends BuildingController:
	var raycast_hit: Dictionary = {}

	func _raycast(
			_screen_position: Vector2, _collision_mask: int = 0xffffffff
		) -> Dictionary:
		return raycast_hit


## Stub for the click-side pointer raycast
## (BuildingPlacement.hover_cell_from_pointer()): the real path needs a
## Camera3D and a TerrainProbe hit against real geometry, neither of which
## these controller tests set up (see _setup_controller_placement()'s own
## camera-less pattern, shared with every other case in this file).
## Overriding only this one public entry point -- not the private
## _hover_cell_from_pointer() that process()/face_toward_pointer() also use --
## leaves begin()/try_place_at_hover_cell()/etc. real, so the rest of the
## placement pipeline (occupancy, footprint, spawn) is exercised unmodified;
## only "where did the click land" is faked.
class HoverCellPlacement extends BuildingPlacement:
	var stub_cell: Variant = null

	func hover_cell_from_pointer(_pointer_position: Vector2):
		return stub_cell


## Records every call to the two methods BuildingController.process() chooses
## between once a placement is committed (see _committed_placement_cell's own
## doc comment on BuildingController): process(pointer_position), the
## pointer-following path, and preview_at_hover_cells(hover_cells), the
## pinned-cell path. Neither of these controller tests sets up a real camera,
## so the private, unstubbed _hover_cell_from_pointer() process() relies on
## always resolves to no cell either way -- recording which method gets
## called (and with what) is the only way to observe, from out here, whether
## the committed branch actually stopped reading the pointer.
class RecordingPlacement extends HoverCellPlacement:
	var process_calls: Array[Vector2] = []
	var preview_at_hover_cells_calls: Array = []

	func process(pointer_position: Vector2) -> void:
		process_calls.append(pointer_position)
		super.process(pointer_position)

	func preview_at_hover_cells(hover_cells: Array[Vector2i]) -> void:
		preview_at_hover_cells_calls.append(hover_cells.duplicate())
		super.preview_at_hover_cells(hover_cells)


class FakeGrid extends RefCounted:
	func is_loaded() -> bool:
		return true

	func grid_to_world(cell: Vector2i, centered: bool) -> Vector3:
		var offset := 0.5 if centered else 0.0
		return Vector3(float(cell.x) + offset, 0.0, float(cell.y) + offset)

	func cell_debug(_cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": true}


class MutableGrid extends FakeGrid:
	var blocked_cells: Dictionary = {}

	func block_occupy_cell(anchor: Vector2i) -> void:
		for y in BuildingPlacement.NAV_CELLS_PER_OCCUPY_CELL:
			for x in BuildingPlacement.NAV_CELLS_PER_OCCUPY_CELL:
				blocked_cells[anchor + Vector2i(x, y)] = true

	func cell_debug(cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": not blocked_cells.has(cell)}


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Controller Tester", Color.BLUE, &"Atreides", [], 1, 100, 7)
	players.local_player_id = 1

	_run_case("asset-independent setup owns one placement child", _test_asset_independent_setup)
	_run_case("controller setup uses distinct real queues for distinct players", _test_controller_setup_uses_distinct_player_queues)
	_run_case("rotation release requires a later confirmation click", _test_rotation_release_requires_confirmation)
	_run_case("repeated setup forwards resources once", _test_repeated_setup_forwards_resources_once.bind(local_player))
	_run_case("freed controller leaves no resource forwarding", _test_free_disconnects_resource_forwarding.bind(local_player))
	_run_case("failed completed wall segment refunds paid credits", _test_completed_wall_refund.bind(local_player))
	_run_case("wall line preview spans selection and stops before ordering", _test_wall_line_preview_only_during_selection)
	_run_case("wall chain skips initially blocked segments", _test_wall_chain_skips_blocked_segment)
	_run_case("wall chain continues when an ordered segment becomes blocked", _test_wall_chain_continues_after_late_block)
	_run_case("world right click does not cancel a fixed wall line", _test_fixed_wall_line_ignores_world_right_click)
	_run_case("fixed wall markers remain until built or canceled", _test_fixed_wall_marker_lifecycle)
	_run_case("building sale plays the authored sell transition", _test_sale_animation.bind(local_player))
	_run_case("building sale reverses construct without an authored sell transition", _test_sale_construct_fallback.bind(local_player))
	_run_case(
		"a sell click on no building submits nothing and still emits its status",
		_test_sell_click_on_no_building_submits_nothing
	)
	_run_case(
		"a sell click defers the sale to the tick the command executes on",
		_test_sell_click_defers_to_the_tick.bind(local_player)
	)
	_run_case(
		"a repair click defers the toggle to the tick the command executes on, reading the direction then",
		_test_repair_click_defers_and_reads_toggle_at_execution.bind(local_player)
	)
	_run_case(
		"a place click submits a command and defers instantiating the building to the tick it executes on",
		_test_place_click_defers_placement_to_the_tick
	)
	_run_case(
		"a place click whose pointer resolves to no cell submits nothing and still emits its status",
		_test_place_click_with_no_cell_submits_nothing
	)
	_run_case(
		"execution ignores a place command whose order changed underneath it before the tick it executes on",
		_test_place_execution_ignores_a_stale_command
	)
	_run_case(
		"the drag-rotation recorded at the click survives the round trip to the placed building",
		_test_place_click_rotation_survives_round_trip
	)
	_run_case(
		"a place click on a cell BuildingPlacement already knows is unbuildable submits nothing",
		_test_place_click_on_unbuildable_cell_submits_nothing
	)
	_run_case(
		"a second place click while the first is still committed submits nothing",
		_test_place_second_click_while_committed_submits_nothing
	)
	_run_case(
		"a committed placement pins its preview at the committed cell instead of following the pointer",
		_test_place_committed_preview_pinned_at_committed_cell
	)
	_run_case(
		"a right click on a committed placement is not consumed and does not cancel it",
		_test_place_committed_right_click_not_consumed
	)
	_run_case(
		"the click-time filter and the execution-time check are independent",
		_test_place_click_filter_and_execution_checks_are_independent
	)
	_run_case(
		"a wall line's first click submits nothing and still emits its existing status",
		_test_wall_line_first_click_submits_nothing
	)
	_run_case(
		"a wall line's second click submits a command and defers starting the chain and locking markers to the tick it executes",
		_test_wall_line_second_click_defers_chain_to_the_tick
	)
	_run_case(
		"the wall-line command recomputes its buildable cells at execution, not from the click-time preview",
		_test_wall_line_command_recomputes_buildable_cells_at_execution
	)
	_run_case(
		"losing and restoring a prerequisite building toggles menu availability",
		_test_availability_reacts_to_prerequisite_loss.bind(local_player)
	)
	_run_case(
		"completing a global upgrade unlocks an upgraded_primary_required entry without restarting the controller",
		_test_availability_reacts_to_upgrade_purchase.bind(local_player)
	)
	_run_case(
		"every ordered pair of sell/repair/wall-line modes deactivates the outgoing mode exactly once",
		_test_mode_transitions_deactivate_exiting_mode_once
	)
	_run_case(
		"leaving wall mode cancels its own placement preview",
		_test_leaving_wall_mode_cancels_its_own_preview
	)
	_run_case(
		"starting a wall chain stamps it with the roster's local player",
		_test_wall_chain_owner_comes_from_roster.bind(local_player)
	)
	_run_case(
		"unrelated nodes leaving the tree do not invalidate availability",
		_test_unrelated_node_removal_keeps_availability_cache.bind(local_player)
	)
	_run_case(
		"leaving and re-entering the tree does not double-connect availability signals",
		_test_availability_resubscribe_after_tree_reentry.bind(local_player)
	)
	_run_case(
		"a stale available cache does not survive leaving the tree",
		_test_availability_forces_false_when_leaving_tree.bind(local_player)
	)
	_run_case(
		"a build-order left click submits a command and defers starting the order to its execution",
		_test_handle_building_intent_defers_start.bind(local_player)
	)
	_run_case(
		"a build-order right click submits a command and defers pausing the order to its execution",
		_test_handle_building_intent_defers_pause.bind(local_player)
	)
	_run_case(
		"a queued right-click cancels production despite a preview opened before execution",
		_test_queued_right_click_uses_player_production_not_preview.bind(local_player)
	)
	_run_case(
		"entering wall-line mode from a slot click stays local and needs no command bus",
		_test_handle_building_intent_wall_entry_stays_local
	)

	players.reset_for_match()
	if _failures > 0:
		printerr("BuildingController tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("BuildingController tests: %d assertions passed" % _assertions)
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


func _new_controller() -> BuildingController:
	var controller = BuildingControllerScript.new()
	root.add_child(controller)
	_production_for(controller)
	return controller


func _production_for(controller: BuildingController) -> ProductionSystem:
	if controller._production_system == null:
		var production := ProductionSystemScript.new()
		production.configure(
			root.get_node("Players"), Callable(controller, "_is_building_available_for_player")
		)
		controller._production_system = production
	return controller._production_system


func _setup_without_assets(controller: BuildingController) -> void:
	var no_building_ids: Array[StringName] = []
	controller.setup(
		null, null, null, no_building_ids, _production_for(controller),
		null, null, null, null, null, null, Callable()
	)


func _test_asset_independent_setup(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	_expect(controller.get_child_count() == 1, "setup must own exactly one placement child without generated scenes")
	_expect(controller.get_child(0) is BuildingPlacement, "setup must add the placement feature as its child")
	controller.free()
	return token


func _test_controller_setup_uses_distinct_player_queues(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var local_queue := controller.building_queue_for_player(1)
	var remote_queue := controller.building_queue_for_player(2)
	_expect(local_queue != remote_queue, "setup must keep player 1 and player 2 in distinct real queues")
	_expect(
		controller._building_queue == local_queue,
		"the controller's local queue view must resolve through its real ProductionSystem"
	)
	controller.free()
	return token


func _test_rotation_release_requires_confirmation(token: int) -> int:
	var controller := GestureController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	controller._building_placement.begin(&"Gesture", "Gesture", ["X"])
	controller._placement_pointer_down = true
	controller._placement_press_position = Vector2(10.0, 10.0)
	controller._pointer_gesture.set_rotated_during_press(true)
	controller._finish_placement_pointer_action(Vector2(10.0, 10.0))
	_expect(
		controller._building_placement.is_active(),
		"releasing a gesture that rotated must not consume the active placement"
	)
	_expect(controller.placement_attempts.is_empty(), "rotation release must not attempt placement")
	_expect(not controller._placement_pointer_down, "rotation release must finish the held-button gesture")

	controller._begin_placement_pointer_action(Vector2(10.0, 10.0))
	controller._finish_placement_pointer_action(Vector2(10.0, 10.0))
	_expect(
		controller.placement_attempts == [Vector2(10.0, 10.0)],
		"the next full click without rotation must attempt placement exactly once"
	)
	controller.free()
	return token


func _test_repeated_setup_forwards_resources_once(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var resource_outputs: Array[Vector2i] = []
	controller.resources_changed.connect(func(credits: int, energy: int) -> void:
		resource_outputs.append(Vector2i(credits, energy))
	)
	_setup_without_assets(controller)
	_setup_without_assets(controller)
	_expect(controller.get_child_count() == 1, "repeated setup must retain one owned placement child")
	resource_outputs.clear()
	local_player.add_money(25)
	_expect(resource_outputs.size() == 1, "one player money change must produce one resource output after repeated setup")
	_expect(resource_outputs == [Vector2i(125, 7)], "resource output must preserve the current player values")
	controller.free()
	return token


func _test_free_disconnects_resource_forwarding(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var resource_outputs: Array[Vector2i] = []
	controller.resources_changed.connect(func(credits: int, energy: int) -> void:
		resource_outputs.append(Vector2i(credits, energy))
	)
	_setup_without_assets(controller)
	controller.free()
	resource_outputs.clear()
	local_player.add_money(1)
	_expect(resource_outputs.is_empty(), "a freed controller must not forward later player resource changes")
	return token


func _test_completed_wall_refund(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var order := BuildingOrderScript.new()
	order.paid_cost = 75
	var money_before := local_player.money
	_production_for(controller).refund_wall_order(local_player.player_id, order)
	_expect(local_player.money == money_before + 75, "a paid wall segment that cannot be placed must be fully refunded")
	order = null
	controller.free()
	return token


func _test_wall_line_preview_only_during_selection(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	_setup_controller_placement(controller,
		null,
		FakeGrid.new(),
		null,
		null,
		PlacementBuildingScene,
		null,
		null,
		Callable()
	)
	controller._wall_line_mode = true
	controller._wall_line_start_cell = Vector2i(2, 4)
	controller._building_placement.begin(&"ATWall", "Wall", ["b"], true)
	controller._preview_wall_line_to_hover_cell(Vector2i(6, 4))
	_expect(
		controller._building_placement.get_child_count() == 3,
		"choosing the wall end must preview every segment from the start"
	)

	controller._building_placement.cancel()
	_production_for(controller).set_wall_chain_for_player(1, WallChainScript.new(
		&"ATWall", "Wall", 10, 25, [Vector2i(6, 8)]
	))
	_production_for(controller).advance_wall_chain(1)
	_expect(
		controller._building_queue.has_order(),
		"selecting a wall segment must start its construction order"
	)
	_expect(
		not controller._building_placement.is_active(),
		"ordering the first segment must not preview it or any following segment"
	)
	controller.free()
	return token


func _test_wall_chain_skips_blocked_segment(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var grid := MutableGrid.new()
	grid.block_occupy_cell(Vector2i(2, 4))
	_setup_controller_placement(controller,
		null, grid, null, null, null, null, null, Callable()
	)
	_production_for(controller).set_wall_chain_for_player(1, WallChainScript.new(
		&"ATWall", "Wall", 0, 1, [Vector2i(2, 4), Vector2i(4, 4)]
	))
	_production_for(controller).advance_wall_chain(1)
	_expect(
		controller._building_queue.has_order(),
		"the first buildable segment after a blocked cell must still be ordered"
	)
	_expect(
		controller._wall_chain != null
		and controller._wall_chain.current_cell() == Vector2i(4, 4),
		"an initially blocked wall cell must be skipped without stopping the chain"
	)
	controller.free()
	return token


func _test_wall_chain_continues_after_late_block(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var grid := MutableGrid.new()
	_setup_controller_placement(controller,
		null, grid, null, null, null, null, null, Callable()
	)
	_production_for(controller).set_wall_chain_for_player(1, WallChainScript.new(
		&"ATWall", "Wall", 0, 1, [Vector2i(2, 4), Vector2i(4, 4)]
	))
	_production_for(controller).advance_wall_chain(1)
	grid.block_occupy_cell(Vector2i(2, 4))
	controller._building_queue.advance_tick(0)
	_expect(
		controller._building_queue.has_order(),
		"a later segment must be ordered when the completed segment became blocked"
	)
	_expect(
		controller._wall_chain != null
		and controller._wall_chain.current_cell() == Vector2i(4, 4),
		"a wall chain must advance past a segment that became blocked while building"
	)
	controller.free()
	return token


func _test_fixed_wall_line_ignores_world_right_click(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	_setup_controller_placement(controller,
		null, FakeGrid.new(), null, null, null, null, null, Callable()
	)
	var world_right_click := InputEventMouseButton.new()
	world_right_click.button_index = MOUSE_BUTTON_RIGHT
	world_right_click.pressed = true

	controller._set_wall_line_mode(true, &"ATWall")
	_expect(
		controller.handle_unhandled_input(world_right_click)
		and not controller._wall_line_mode,
		"a world right click must cancel wall-line drawing before it is fixed"
	)

	_production_for(controller).set_wall_chain_for_player(1, WallChainScript.new(
		&"ATWall", "Wall", 0, 25, [Vector2i(2, 4), Vector2i(4, 4)]
	))
	_production_for(controller).advance_wall_chain(1)

	_expect(
		not controller.handle_unhandled_input(world_right_click),
		"a world right click must remain available to other gameplay controls"
	)
	_expect(
		controller._building_queue.has_order()
		and not controller._building_queue.current_order().manually_paused,
		"a world right click must not pause or cancel a fixed wall order"
	)

	_execute_wall_build_order(controller, MOUSE_BUTTON_RIGHT)
	_expect(
		controller._building_queue.current_order().manually_paused,
		"right-clicking the wall icon must pause its running order"
	)
	_execute_wall_build_order(controller, MOUSE_BUTTON_RIGHT)
	_expect(
		not controller._building_queue.has_order() and controller._wall_chain == null,
		"right-clicking the paused wall icon must cancel the remaining chain"
	)
	controller.free()
	return token


## Must enter BuildingController's shared execute_build_order_command() path,
## not a wall-only queue helper, so pause/cancel keeps the ordinary player-keyed
## queue state machine that non-wall production uses.
func _execute_wall_build_order(controller: BuildingController, button_index: int) -> void:
	var command := SimBuildOrderCommandScript.new()
	command.player_id = 1
	command.building_id = &"ATWall"
	command.button_index = button_index
	controller.execute_build_order_command(command)


func _test_fixed_wall_marker_lifecycle(token: int) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	controller._wall_session.set_marker_scene(PlacementWallScene)
	controller._lock_wall_markers([Vector2i(2, 4), Vector2i(4, 4)])
	_expect(
		controller._wall_session.markers().size() == 2,
		"fixing a wall line must retain one build_wall marker per green segment"
	)
	var marker := controller._wall_session.markers()[Vector2i(2, 4)] as Node3D
	var marker_meshes := marker.find_children("*", "MeshInstance3D", true, false)
	var marker_uses_source_materials := not marker_meshes.is_empty()
	for node in marker_meshes:
		var mesh_instance := node as MeshInstance3D
		marker_uses_source_materials = (
			marker_uses_source_materials and mesh_instance.material_override == null
		)
		for surface_index in mesh_instance.mesh.get_surface_count():
			marker_uses_source_materials = (
				marker_uses_source_materials
				and mesh_instance.get_surface_override_material(surface_index) == null
			)
	_expect(
		marker_uses_source_materials,
		"build_wall markers must keep their ordinary authored materials"
	)

	_production_for(controller).set_wall_chain_for_player(1, WallChainScript.new(
		&"ATWall", "Wall", 0, 1, [Vector2i(2, 4), Vector2i(4, 4)]
	))
	_production_for(controller).advance_wall_chain(1)
	controller._building_queue.advance_tick(0)
	_expect(
		not controller._wall_session.markers().has(Vector2i(2, 4))
		and controller._wall_session.markers().has(Vector2i(4, 4)),
		"a completed segment must remove only its own fixed marker"
	)

	controller._cancel_building_order()
	_expect(
		controller._wall_session.markers().is_empty(),
		"canceling wall construction must remove all remaining fixed markers"
	)
	controller.free()
	buildings_root.free()
	return token


## Sell is now a command-bus intent (see SimSellBuildingCommand's doc
## comment): _try_sell_building() only submits, so this case wires in a
## CommandPump exactly the way _test_handle_building_intent_defers_start()
## does for build orders, and pumps once before asserting the effects
## _try_sell_building() itself used to produce synchronously. The assertions
## are otherwise unchanged from before the command bus existed --
## install_match_lookup_stub() is what lets `building`, a real Building, pick
## up a real resolvable entity id the same way it would under a real Match --
## see that method's doc comment. One further step slice C5 added:
## apply_pending_releases() must be called after the sell clip finishes,
## because the resolvable entity id also routes the actual free through this
## pump's own deferred-despawn queue instead of a direct queue_free() -- see
## CommandPumpScript.apply_pending_releases()'s own comment.
func _test_sale_animation(token: int, local_player: PlayerData) -> int:
	var controller := SaleController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")
	pump.install_match_lookup_stub(root)

	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = local_player.player_id
	root.add_child(building)
	var collider := Node.new()
	building.add_child(collider)
	controller.raycast_hit = {"collider": collider}
	var money_before := local_player.money

	controller._try_sell_building(Vector2.ZERO)
	pump.pump()
	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	_expect(player != null and player.current_animation == &"sell", "sale must play the authored sell clip")
	_expect(not building.is_construction_complete(), "a selling building must stop satisfying technology prerequisites immediately")
	_expect(not building.is_queued_for_deletion(), "the building must remain until sell finishes")
	if player != null:
		player.animation_finished.emit(&"sell")
	# Slice C5: BuildingSaleService._finish() now despawns through
	# request_despawn(), which -- because install_match_lookup_stub() above
	# gave `building` a resolvable entity id -- queues it in this pump's own
	# EntityNodeIndex instead of calling queue_free() directly. Nothing here
	# drives a tick loop to drain that queue on its own; see
	# CommandPumpScript.apply_pending_releases()'s own comment.
	pump.apply_pending_releases()
	_expect(building.is_queued_for_deletion(), "sell completion must remove the building")
	_expect(local_player.money == money_before + 1000, "sell completion must retain the half-cost refund")

	pump.uninstall_match_lookup_stub()
	controller.free()
	building.free()
	return token


## See _test_sale_animation()'s doc comment for why this now pumps once
## before asserting; otherwise unchanged.
func _test_sale_construct_fallback(token: int, local_player: PlayerData) -> int:
	var controller := SaleController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")
	pump.install_match_lookup_stub(root)

	var building := Building.new()
	building.owner_player_id = local_player.player_id
	var player := AnimationPlayer.new()
	player.name = "StatePlayer"
	var library := AnimationLibrary.new()
	var construct := Animation.new()
	construct.length = 1.0
	library.add_animation(&"construct", construct)
	player.add_animation_library(&"", library)
	building.add_child(player)
	root.add_child(building)
	var collider := Node.new()
	building.add_child(collider)
	controller.raycast_hit = {"collider": collider}

	controller._try_sell_building(Vector2.ZERO)
	pump.pump()
	_expect(player.current_animation == &"construct", "sale fallback must play construct")
	_expect(is_equal_approx(player.current_animation_position, construct.length), "sale fallback must start at the end of construct")
	_expect(player.get_playing_speed() < 0.0, "sale fallback must reverse construct")
	_expect(not building.is_queued_for_deletion(), "the building must remain until reversed construct finishes")
	player.animation_finished.emit(&"construct")
	# See _test_sale_animation()'s identical comment above: install_match_
	# lookup_stub() gave `building` a resolvable entity id, so request_
	# despawn() queued it in this pump's EntityNodeIndex rather than freeing
	# it directly, and nothing else here drains that queue.
	pump.apply_pending_releases()
	_expect(building.is_queued_for_deletion(), "reversed construct completion must remove the building")

	pump.uninstall_match_lookup_stub()
	controller.free()
	building.free()
	return token


## A sell click that resolves to no building must not put anything on the
## bus -- the same reason a move click onto no terrain submits nothing (see
## _try_sell_building()'s own doc comment). pending_count() is SimCommandBus's
## own surface for observing this (scripts/sim/command_bus.gd), so this does
## not need a next-tick drain to prove the bus stayed empty.
func _test_sell_click_on_no_building_submits_nothing(token: int) -> int:
	var controller := SaleController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	var pump := CommandPumpScript.new()
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")
	controller.raycast_hit = {}

	# An Array, not a plain local, because a GDScript lambda captures an
	# outer local by value -- reassigning it inside the closure would not be
	# observable out here; appending to a shared Array is, matching the
	# pattern every other status-capturing case in this file and
	# tests/match/unit_command_run.gd already uses.
	var statuses: Array[String] = []
	controller.status_changed.connect(func(status: String) -> void: statuses.append(status))
	controller._try_sell_building(Vector2.ZERO)
	_expect(
		statuses == ["Select one of your buildings to sell"],
		"a miss click must still emit the existing status, and nothing else"
	)
	_expect(pump.bus().pending_count() == 0, "a miss click must put nothing on the command bus")

	controller.free()
	return token


## Sell's command-bus counterpart to _test_sale_animation() above: the click
## must not sell anything until the command executes on its scheduled tick.
func _test_sell_click_defers_to_the_tick(token: int, local_player: PlayerData) -> int:
	var controller := SaleController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")
	pump.install_match_lookup_stub(root)

	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = local_player.player_id
	root.add_child(building)
	var collider := Node.new()
	building.add_child(collider)
	controller.raycast_hit = {"collider": collider}

	controller._try_sell_building(Vector2.ZERO)
	_expect(
		not controller._sale_service.is_active(),
		"a sell click must not start the sale before its command executes"
	)
	_expect(
		building.is_construction_complete(),
		"a sell click must not stop satisfying prerequisites before its command executes"
	)
	pump.pump()
	_expect(
		controller._sale_service.is_active(),
		"a sell click must start the sale once its command executes"
	)

	pump.uninstall_match_lookup_stub()
	controller.free()
	building.free()
	return token


## Repair's command-bus counterpart: the click must not toggle repair until
## the command executes, and -- per SimRepairBuildingCommand's doc comment --
## the toggle direction is read off the building at execution time, not
## decided at the click. Starts the building already repairing so a click
## that executed immediately (instead of deferring) would be caught either
## way: this test binds on the deferral, a mutation that made the click
## execute immediately would still see the toggle happen, just too early --
## see this suite's own mutation-proof notes for the click-time-execution
## case.
func _test_repair_click_defers_and_reads_toggle_at_execution(token: int, local_player: PlayerData) -> int:
	var controller := SaleController.new()
	root.add_child(controller)
	_setup_without_assets(controller)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")
	pump.install_match_lookup_stub(root)

	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = local_player.player_id
	root.add_child(building)
	building.health = building.max_health - 10.0
	building.is_repairing = true
	var collider := Node.new()
	building.add_child(collider)
	controller.raycast_hit = {"collider": collider}

	controller._try_toggle_building_repair(Vector2.ZERO)
	_expect(
		building.is_repairing,
		"a repair click must not toggle repair before its command executes"
	)
	pump.pump()
	_expect(
		not building.is_repairing,
		"a repair click on an already-repairing building must cancel it once the command executes"
	)

	pump.uninstall_match_lookup_stub()
	controller.free()
	building.free()
	return token


## Place's command-bus counterpart to the sell/repair deferral cases above:
## the click must not instantiate anything until its command executes. Uses a
## HoverCellPlacement stub so the click-side raycast (which needs a real
## Camera3D none of these controller tests set up) resolves to a fixed cell
## instead of failing closed -- see that class's own doc comment.
func _test_place_click_defers_placement_to_the_tick(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	stub.stub_cell = Vector2i(5, 7)
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	# cost 0, build_time_ticks 1: one advance_tick(0) call marks the order
	# ready immediately, the same shortcut the wall-chain cases in this file
	# already use (see WallChainScript.new() call sites above).
	controller._building_queue.start(&"ATBarracks", "Barracks", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()

	controller._try_place_ready_building(Vector2.ZERO)
	_expect(pump.bus().pending_count() == 1, "a place click must submit exactly one command")
	_expect(
		buildings_root.get_child_count() == 0,
		"a place click must not instantiate anything before its command executes"
	)
	_expect(
		controller._building_queue.current_order() != null,
		"a place click must not consume the ready order before its command executes"
	)

	pump.pump()
	_expect(
		buildings_root.get_child_count() == 1,
		"the placement command must instantiate the building once it executes"
	)
	_expect(
		controller._building_queue.current_order() == null,
		"executing the placement command must consume the queue's ready order"
	)

	controller.free()
	buildings_root.free()
	return token


## A place click that resolves to no cell must not put anything on the bus --
## the same reason a sell click on no building submits nothing (see
## _test_sell_click_on_no_building_submits_nothing()'s doc comment). No
## HoverCellPlacement stub here: the real hover_cell_from_pointer() already
## returns null with no camera wired in, which is exactly the case under test.
func _test_place_click_with_no_cell_submits_nothing(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._building_queue.start(&"ATBarracks", "Barracks", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()

	var statuses: Array[String] = []
	controller.status_changed.connect(func(status: String) -> void: statuses.append(status))
	controller._try_place_ready_building(Vector2.ZERO)
	_expect(
		statuses.has("Barracks placement needs terrain"),
		"a click that resolves to no cell must still emit the existing status"
	)
	_expect(
		pump.bus().pending_count() == 0,
		"a click that resolves to no cell must put nothing on the command bus"
	)

	controller.free()
	buildings_root.free()
	return token


## Binds execute_place_building_command()'s identity check: if
## order.building_id != command.building_id is deleted, this case fails,
## because the queue's real ATSmWindtrap order would then get placed at the
## stale ATBarracks command's cell instead of being left alone -- see that
## method's doc comment for why a mismatched id means the command is stale.
func _test_place_execution_ignores_a_stale_command(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	stub.stub_cell = Vector2i(5, 7)
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATBarracks", &"ATSmWindtrap"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._building_queue.start(&"ATBarracks", "Barracks", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()
	controller._try_place_ready_building(Vector2.ZERO)
	_expect(pump.bus().pending_count() == 1, "setup: the place click must submit a command")

	# The order changes underneath the in-flight command, exactly the way a
	# clicked entity can die between a click and its command's execution tick
	# (see CommandExecutor._execute_stop()'s doc comment for the identical
	# reasoning applied to an entity id instead of a queue order).
	controller._building_queue.take_ready()
	controller._building_queue.start(&"ATSmWindtrap", "Windtrap", 0, 1)
	controller._building_queue.advance_tick(0)

	pump.pump()
	_expect(
		buildings_root.get_child_count() == 0,
		"a stale place command naming a building the queue no longer has ready must place nothing"
	)
	_expect(
		controller._building_queue.current_order() != null
		and controller._building_queue.current_order().building_id == &"ATSmWindtrap"
		and controller._building_queue.current_order().ready,
		"a stale place command must leave the queue's real ready order untouched"
	)
	_expect(
		controller._committed_placement_cell == null,
		"a stale local command must clear its committed cell so a future click is live"
	)

	controller.free()
	buildings_root.free()
	return token


## The drag-rotation gesture (PlacementPointerGesture, scripts/buildings/
## placement_pointer_gesture.gd) is read off BuildingPlacement at click time
## and must reach the placed building unchanged, exactly as an immediate
## (pre-command-bus) placement would have produced -- see
## _test_rotated_placement in tests/buildings/placement_run.gd for the same
## PI * 0.5 assertion against a direct try_place_at_hover_cell() call.
func _test_place_click_rotation_survives_round_trip(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	stub.stub_cell = Vector2i(5, 7)
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._building_queue.start(&"ATBarracks", "Barracks", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()
	controller._building_placement.set_rotation_quarter_turns(1)

	controller._try_place_ready_building(Vector2.ZERO)
	pump.pump()

	_expect(buildings_root.get_child_count() == 1, "setup: the rotated placement must still succeed")
	var spawned := buildings_root.get_child(0) as Node3D
	_expect(
		spawned != null and is_equal_approx(spawned.rotation.y, PI * 0.5),
		"the drag-rotation quarter turn recorded at the click must survive to the placed building"
	)

	controller.free()
	buildings_root.free()
	return token


## Fix 1's own case (see _try_place_ready_building()'s doc comment): a click
## that resolves to a real cell BuildingPlacement already knows is
## unbuildable is just as much "not a game action" as a click that resolved
## to no cell at all (_test_place_click_with_no_cell_submits_nothing above),
## so it must not put anything on the bus either -- before the command bus
## this same check answered the click immediately, with no round trip. Uses
## ATWall (occupy_rows ["b"], a single occupy cell) at an occupy-cell-aligned
## hover cell -- (6, 4), an even multiple of BuildingPlacement.NAV_CELLS_PER_
## OCCUPY_CELL on both axes -- so its footprint's one anchor cell lands
## exactly on the clicked cell with no anchor-offset arithmetic, and
## MutableGrid.block_occupy_cell() can block precisely the cell this click
## would have claimed.
func _test_place_click_on_unbuildable_cell_submits_nothing(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	stub.stub_cell = Vector2i(6, 4)
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATWall"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, PlacementWallScene, null, Callable())
	var grid := MutableGrid.new()
	grid.block_occupy_cell(Vector2i(6, 4))
	_setup_controller_placement(controller,
		null, grid, buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._building_queue.start(&"ATWall", "Wall", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()

	var statuses: Array[String] = []
	controller.status_changed.connect(func(status: String) -> void: statuses.append(status))
	controller._try_place_ready_building(Vector2.ZERO)

	_expect(
		statuses.has("Wall cannot be placed there"),
		"a click on a cell the placement already knows is unbuildable must still emit the existing status"
	)
	_expect(
		pump.bus().pending_count() == 0,
		"a click on a cell the placement already knows is unbuildable must put nothing on the command bus"
	)
	_expect(
		controller._committed_placement_cell == null,
		"a filtered click must not leave anything committed"
	)

	controller.free()
	buildings_root.free()
	return token


## Fix 2's own case for the second bullet of its doc comment: once
## _try_place_ready_building() has committed a cell, a second click must not
## reach the bus a second time -- unlike before the command bus, when a
## second click landed on an inactive placement and simply did nothing, this
## one only stops because of the guard _committed_placement_cell adds (see
## its own doc comment).
func _test_place_second_click_while_committed_submits_nothing(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	stub.stub_cell = Vector2i(5, 7)
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._building_queue.start(&"ATBarracks", "Barracks", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()

	controller._try_place_ready_building(Vector2.ZERO)
	_expect(pump.bus().pending_count() == 1, "setup: the first click must submit exactly one command")

	controller._try_place_ready_building(Vector2.ZERO)
	_expect(
		pump.bus().pending_count() == 1,
		"a second click while the first placement is still committed must submit nothing"
	)

	controller.free()
	buildings_root.free()
	return token


## Fix 2's own case for its first bullet: process() must stop reading the
## pointer once a placement is committed, and instead pin the preview at the
## cell the pending command actually names -- see process()'s own doc comment
## and _committed_placement_cell's. RecordingPlacement (above) is what makes
## this observable: neither of process()'s two candidate calls is otherwise
## distinguishable from out here, since these controller tests have no real
## camera for the pointer-following path to resolve against anyway (see that
## class's own doc comment).
func _test_place_committed_preview_pinned_at_committed_cell(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := RecordingPlacement.new()
	stub.stub_cell = Vector2i(5, 7)
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._building_queue.start(&"ATBarracks", "Barracks", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()
	controller._try_place_ready_building(Vector2.ZERO)
	_expect(pump.bus().pending_count() == 1, "setup: the click must submit a command")

	stub.process_calls.clear()
	stub.preview_at_hover_cells_calls.clear()
	# "The mouse moves elsewhere" is stood in for by disagreeing with the
	# committed cell -- the committed branch of process() must never even ask.
	stub.stub_cell = Vector2i(9, 9)
	controller.process(0.0)

	_expect(
		stub.process_calls.is_empty(),
		"a committed placement must stop reading the pointer through BuildingPlacement.process()"
	)
	_expect(
		stub.preview_at_hover_cells_calls == [[Vector2i(5, 7)]],
		"a committed placement must pin its preview at the committed cell, not wherever the pointer is"
	)

	controller.free()
	buildings_root.free()
	return token


## Fix 2's own case for its third bullet: a right click on a committed
## placement must not be consumed -- unlike the still-cancelable preview a
## right click reaches before the click that commits it, this one has to
## fall through to whatever controller is behind BuildingController in
## Match._unhandled_input() (UnitCommandController), the same as it would
## have after a synchronous, pre-command-bus placement. Checking is_active()
## afterward is what catches a mutation that consumes the event by actually
## running _cancel_building_placement() rather than one that merely forgets
## to return true/false correctly.
func _test_place_committed_right_click_not_consumed(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	stub.stub_cell = Vector2i(5, 7)
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._building_queue.start(&"ATBarracks", "Barracks", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()
	controller._try_place_ready_building(Vector2.ZERO)
	_expect(pump.bus().pending_count() == 1, "setup: the click must submit a command")

	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	_expect(
		not controller.handle_unhandled_input(right_click),
		"a right click on a committed placement must not be consumed"
	)
	_expect(
		controller._building_placement.is_active(),
		"a right click on a committed placement must not cancel it"
	)

	controller.free()
	buildings_root.free()
	return token


## The case that proves Fix 1's click-time filter and execute_place_building_
## command()'s own check are not redundant (see _try_place_ready_building()'s
## doc comment): a click accepted by the filter, on a cell blocked afterward
## but before the command's execution tick, must still be refused -- by
## execute_place_building_command()'s own call, since the filter already
## passed and cannot run again. Deleting either check breaks a different half
## of this case: no click-time filter still reaches this same refusal (the
## filter only ever suppresses, so removing it cannot make an already-passing
## click fail here); no execution-time check would place the building anyway,
## since nothing else in this test blocks that.  Also proves the committed
## cell clears on every outcome, not just success: the fresh click at the end
## only works if execute_place_building_command() cleared it despite refusing.
func _test_place_click_filter_and_execution_checks_are_independent(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	stub.stub_cell = Vector2i(6, 4)
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATWall"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, PlacementWallScene, null, Callable())
	var grid := MutableGrid.new()
	_setup_controller_placement(controller,
		null, grid, buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._building_queue.start(&"ATWall", "Wall", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()

	var statuses: Array[String] = []
	controller.status_changed.connect(func(status: String) -> void: statuses.append(status))

	controller._try_place_ready_building(Vector2.ZERO)
	_expect(pump.bus().pending_count() == 1, "setup: a click on a still-buildable cell must submit a command")

	# Blocked between the click and the tick the command executes on -- the
	# filter above already passed, so only execute_place_building_command()'s
	# own check can still catch this.
	grid.block_occupy_cell(Vector2i(6, 4))

	pump.pump()
	_expect(
		buildings_root.get_child_count() == 0,
		"a cell blocked after the filter passed must still place nothing at execution"
	)
	_expect(
		statuses.has("Wall cannot be placed there"),
		"execution must refuse a cell blocked since the click, with the existing status"
	)
	_expect(
		controller._committed_placement_cell == null,
		"a refused command must still clear the committed cell so the next click is live"
	)

	# A fresh click on a still-buildable cell must now work again.
	stub.stub_cell = Vector2i(2, 4)
	controller._try_place_ready_building(Vector2.ZERO)
	_expect(
		pump.bus().pending_count() == 1,
		"a fresh click after a refused command must submit again"
	)
	pump.pump()
	# A Building-typed child specifically, not a bare child count: ATWall's
	# authored construction timeline schedules a one-shot AudioStreamPlayer3D
	# as a sibling of the placed building (BuildingConstructionSound._play(),
	# scripts/buildings/building_construction_sound.gd), so buildings_root
	# legitimately ends up with more than one child on a real, successful
	# placement.
	var placed_buildings := buildings_root.get_children().filter(
		func(child: Node) -> bool: return child is Building
	)
	_expect(
		placed_buildings.size() == 1,
		"a fresh click on a buildable cell must place successfully after a prior refusal"
	)

	controller.free()
	buildings_root.free()
	return token


## Wall's command-bus counterpart to _test_sell_click_on_no_building_submits_nothing()
## and _test_place_click_with_no_cell_submits_nothing(): the first wall click
## only records a start cell and changes what the player's next click means --
## it names no game action, so WallLineSession.click() must put nothing on the
## bus for it (see that method's own doc comment).
func _test_wall_line_first_click_submits_nothing(token: int) -> int:
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATWall"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, PlacementWallScene, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), null, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._set_wall_line_mode(true, &"ATWall")
	stub.stub_cell = Vector2i(2, 4)

	var statuses: Array[String] = []
	controller.status_changed.connect(func(status: String) -> void: statuses.append(status))
	controller._on_wall_line_click(Vector2.ZERO)

	_expect(
		statuses.has("Wall start set; click the line end"),
		"the first wall click must still emit the existing status"
	)
	_expect(pump.bus().pending_count() == 0, "the first wall click must put nothing on the command bus")

	controller.free()
	return token


## Wall's command-bus counterpart to _test_place_click_defers_placement_to_the_tick():
## the second click must not start a chain or lock any markers until its
## SimWallLineCommand executes -- see _submit_wall_line_command()'s and
## execute_wall_line_command()'s doc comments. Uses a HoverCellPlacement stub
## (see that class's own doc comment) so the click-side raycast resolves to a
## fixed cell without a real Camera3D, exactly as the place-command cases do,
## with a different stub_cell per click to name the line's two ends.
func _test_wall_line_second_click_defers_chain_to_the_tick(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATWall"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, PlacementWallScene, null, Callable())
	_setup_controller_placement(controller,
		null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._set_wall_line_mode(true, &"ATWall")
	stub.stub_cell = Vector2i(2, 4)
	controller._on_wall_line_click(Vector2.ZERO)
	stub.stub_cell = Vector2i(4, 4)
	controller._on_wall_line_click(Vector2.ZERO)

	_expect(pump.bus().pending_count() == 1, "a second wall click must submit exactly one command")
	_expect(
		controller._wall_chain == null,
		"a second wall click must not start a chain before its command executes"
	)
	_expect(
		controller._wall_session.markers().is_empty(),
		"a second wall click must not lock any markers before its command executes"
	)

	pump.pump()
	_expect(
		controller._wall_chain != null,
		"the wall-line command must start a chain once it executes"
	)
	_expect(
		not controller._wall_session.markers().is_empty(),
		"the wall-line command must lock markers once it executes"
	)

	controller.free()
	buildings_root.free()
	return token


## Binds the whole point of this slice (see SimWallLineCommand's doc comment
## and ProductionSystem.execute_wall_line()'s own): the buildable-cell set is
## computed when the command executes, not carried from the click-time
## preview. A cell buildable at both clicks is blocked afterward, before the
## pump -- if the command still carried a click-time snapshot (the design this
## slice replaces), that stale snapshot would still say the cell was fine, and
## this case would fail.
func _test_wall_line_command_recomputes_buildable_cells_at_execution(token: int) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var stub := HoverCellPlacement.new()
	controller._building_placement.free()
	controller._building_placement = stub
	var building_ids: Array[StringName] = [&"ATWall"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, PlacementWallScene, null, Callable())
	var grid := MutableGrid.new()
	_setup_controller_placement(controller,
		null, grid, buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller._set_wall_line_mode(true, &"ATWall")
	stub.stub_cell = Vector2i(2, 4)
	controller._on_wall_line_click(Vector2.ZERO)
	stub.stub_cell = Vector2i(6, 4)
	controller._on_wall_line_click(Vector2.ZERO)
	_expect(pump.bus().pending_count() == 1, "setup: the second wall click must submit exactly one command")

	# Blocked after the click, before the command executes.
	grid.block_occupy_cell(Vector2i(4, 4))

	pump.pump()
	_expect(
		controller._wall_chain != null,
		"the line's still-buildable cells must still produce a chain"
	)
	if controller._wall_chain != null:
		_expect(
			not controller._wall_chain.cells.has(Vector2i(4, 4)),
			"a cell blocked between the click and the command's execution tick must not enter the chain"
		)
		_expect(
			controller._wall_chain.cells.has(Vector2i(2, 4))
			and controller._wall_chain.cells.has(Vector2i(6, 4)),
			"cells that stayed buildable must still enter the chain"
		)

	controller.free()
	buildings_root.free()
	return token


## _sell_mode/_repair_mode/_wall_line_mode are property shims over a single
## Mode enum. Activating one mode must deactivate whichever of the other two
## was previously active -- emitting its own *_changed(false) exactly once,
## same as when these were three independent bool fields (git show HEAD).
## Covers every ordered pair among the three non-NONE modes (6 transitions);
## entry from NONE is already exercised by the other mode tests above.
func _test_mode_transitions_deactivate_exiting_mode_once(token: int) -> int:
	var ordered_pairs := [
		[&"sell", &"repair"],
		[&"sell", &"wall_line"],
		[&"repair", &"sell"],
		[&"repair", &"wall_line"],
		[&"wall_line", &"sell"],
		[&"wall_line", &"repair"],
	]
	for pair in ordered_pairs:
		var from_mode: StringName = pair[0]
		var to_mode: StringName = pair[1]
		var controller := _new_controller()
		_setup_without_assets(controller)

		var events: Dictionary = {&"sell": [], &"repair": [], &"wall_line": []}
		controller.sell_mode_changed.connect(func(active: bool) -> void: events[&"sell"].append(active))
		controller.repair_mode_changed.connect(func(active: bool) -> void: events[&"repair"].append(active))
		controller.wall_mode_changed.connect(func(active: bool) -> void: events[&"wall_line"].append(active))
		var statuses: Array[String] = []
		controller.status_changed.connect(func(text: String) -> void: statuses.append(text))

		_enter_mode(controller, from_mode)
		for key in events.keys():
			(events[key] as Array).clear()
		statuses.clear()

		_enter_mode(controller, to_mode)

		var from_events: Array = events[from_mode]
		_expect(
			from_events == [false],
			"%s -> %s must emit %s_mode_changed(false) exactly once for the outgoing mode (got %s)" % [
				from_mode, to_mode, from_mode, from_events
			]
		)
		# The signal is what listeners bind to, but the status line is what the
		# player actually reads, and it is emitted from a different branch of the
		# same deactivation body -- so a half-applied fix could restore one
		# without the other.
		var cancel_line: String = MODE_CANCEL_STATUS[from_mode]
		_expect(
			statuses.count(cancel_line) == 1,
			"%s -> %s must report \"%s\" exactly once (got %s)" % [
				from_mode, to_mode, cancel_line, statuses
			]
		)
		controller.free()
	return token


## The third thing a deactivation does, after the signal and the status line:
## wall mode owns a live BuildingPlacement preview, and _deactivate_wall_line_
## mode() is what tears it down. Skipping that step is not visible as a
## surviving preview -- the generic _cancel_building_placement() further down
## the same setter catches it either way. What gives it away is that the
## generic path announces "<id> placement canceled", a line the wall path never
## produces, so that stray status is the assertion.
func _test_leaving_wall_mode_cancels_its_own_preview(token: int) -> int:
	for to_mode in [&"repair", &"sell"]:
		var controller := _new_controller()
		_setup_without_assets(controller)
		_setup_controller_placement(controller,
			null, FakeGrid.new(), null, null, PlacementBuildingScene, null, null, Callable()
		)
		_enter_mode(controller, &"wall_line")
		_expect(
			controller._building_placement.is_active(),
			"wall mode must own a live placement preview before it is left"
		)

		var statuses: Array[String] = []
		controller.status_changed.connect(func(text: String) -> void: statuses.append(text))
		_enter_mode(controller, to_mode)

		_expect(
			not controller._building_placement.is_active(),
			"leaving wall mode for %s must leave no live placement preview" % to_mode
		)
		var stray: Array = statuses.filter(func(text: String) -> bool:
			return text.ends_with("placement canceled")
		)
		_expect(
			stray.is_empty(),
			"wall mode must cancel its own preview rather than leave it to the generic placement cancel (got %s)" % [stray]
		)
		controller.free()
	return token


## BuildingAvailabilityTracker connects owner_changed/construction_
## completed/upgrade_level_changed/tree_exiting on every tracked building, but
## _exit_tree() used to only forget them (clearing the tracked map)
## without disconnecting -- so a controller that leaves the tree
## (freed and replaced, or simply re-parented) and calls setup() again would
## reconnect on top of connections that were never torn down, and Godot logs
## "Signal is already connected" for every live building. Exercise exactly
## that sequence and confirm each signal ends up connected exactly once.
func _test_availability_resubscribe_after_tree_reentry(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())

	# ATBarracks needs both a primary ATConYard and a secondary Windtrap to
	# read AVAILABLE (see _test_availability_reacts_to_prerequisite_loss), so
	# the later ownership flip below actually changes its state instead of
	# leaving it permanently DISABLED regardless of connection count.
	var con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	var windtrap := BuildingStub.new(&"ATSmWindtrap", local_player.player_id)
	root.add_child(con_yard)
	root.add_child(windtrap)
	controller.process(0.0)

	root.remove_child(controller)
	# Godot's Signal.connect() itself refuses to add a true duplicate
	# connection (it just errors and leaves the original in place), so a
	# post-resubscribe connection-count check alone cannot go red on the bug
	# this guards against. Assert the actual root cause directly: leaving the
	# tree must tear down every subscription it made, not just forget about
	# it in the tracker's map.
	_expect(
		not con_yard.is_connected("owner_changed", Callable(controller._availability_tracker, "_on_owner_changed")),
		"leaving the tree must disconnect owner_changed from a tracked building"
	)
	_expect(
		not con_yard.is_connected("construction_completed", Callable(controller._availability_tracker, "mark_dirty")),
		"leaving the tree must disconnect construction_completed from a tracked building"
	)
	_expect(
		not con_yard.is_connected("upgrade_level_changed", Callable(controller._availability_tracker, "_on_upgrade_changed")),
		"leaving the tree must disconnect upgrade_level_changed from a tracked building"
	)
	_expect(
		not con_yard.is_connected("tree_exiting", Callable(controller._availability_tracker, "mark_dirty")),
		"leaving the tree must disconnect tree_exiting from a tracked building"
	)

	root.add_child(controller)
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	controller.process(0.0)

	_expect(
		con_yard.get_signal_connection_list("owner_changed").size() == 1,
		"re-entering the tree and calling setup() again must not double-connect owner_changed"
	)
	_expect(
		con_yard.get_signal_connection_list("construction_completed").size() == 1,
		"re-entering the tree and calling setup() again must not double-connect construction_completed"
	)
	_expect(
		con_yard.get_signal_connection_list("upgrade_level_changed").size() == 1,
		"re-entering the tree and calling setup() again must not double-connect upgrade_level_changed"
	)
	_expect(
		con_yard.get_signal_connection_list("tree_exiting").size() == 1,
		"re-entering the tree and calling setup() again must not double-connect tree_exiting"
	)

	# A duplicated connection cannot be detected by counting effects of firing
	# the signal once -- mark_dirty() only sets a boolean flag,
	# so N connections firing on one event still only mark it dirty once
	# either way. The exactly-one-connection assertions above are the direct
	# evidence; re-firing here just confirms the surviving connection still
	# works end to end after the resubscribe.
	# A single-element Array, not a plain int, because GDScript lambdas
	# capture outer local scalars by value: an `int` incremented inside the
	# closure would never be visible out here.
	var refresh_count := [0]
	controller.building_option_state_changed.connect(func(option_state: BuildingOptionState) -> void:
		if option_state.building_id == &"ATBarracks":
			refresh_count[0] += 1
	)
	con_yard.set_owner_player_id(2)
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		refresh_count[0] >= 1,
		"the surviving owner_changed connection must still refresh ATBarracks option state after resubscribing"
	)

	con_yard.free()
	windtrap.free()
	controller.free()
	return token


## HEAD's _is_building_available() began with `if not is_inside_tree(): return
## false`; the stage-5 refactor moved availability into a plain-cache
## _catalog_view whose is_available() has no notion of the scene tree, so a
## controller that leaves the tree without one further dirtying event would
## otherwise keep serving whatever it last computed while still inside it.
func _test_availability_forces_false_when_leaving_tree(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())

	var con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	var windtrap := BuildingStub.new(&"ATSmWindtrap", local_player.player_id)
	root.add_child(con_yard)
	root.add_child(windtrap)
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		controller._is_building_available(&"ATBarracks"),
		"prerequisite present must read available before teardown"
	)

	root.remove_child(controller)
	# _building_placement is this controller's own child, and children exit
	# the tree before their parent's own _exit_tree() runs -- so its removal
	# happens to reach the tracker's node_removed handler while the tree
	# signal is still connected, marking availability dirty as an incidental
	# side effect of this controller's own teardown cascade. Consume the flag
	# to isolate the actual scenario this guards: nothing external marks
	# availability dirty after leaving the tree, so a stale cached "true"
	# must not survive on its own.
	controller._availability_tracker.consume_dirty()
	var latest_state: Dictionary = {}
	controller.building_option_state_changed.connect(func(option_state: BuildingOptionState) -> void:
		latest_state[option_state.building_id] = option_state.state
	)
	controller._refresh_building_option_states()
	_expect(
		latest_state.get(&"ATBarracks") == BuildingOptionStateScript.State.DISABLED,
		"a controller outside the tree must report every entry unavailable, even from a stale cache"
	)

	con_yard.free()
	windtrap.free()
	controller.free()
	return token


func _enter_mode(controller: BuildingController, mode: StringName) -> void:
	match mode:
		&"sell":
			controller._set_sell_mode(true)
		&"repair":
			controller._set_repair_mode(true)
		&"wall_line":
			controller._set_wall_line_mode(true, &"ATWall")


## The wall tests above install a WallChain directly, so this case drives
## ProductionSystem.execute_wall_line() and proves its player-keyed chain
## carries the command player id as owner. The production dictionary key, not
## a local PlayerData lookup, is authoritative when a segment is placed.
##
## ProductionSystem.execute_wall_line() evaluates
## Vector2i(2, 4)/Vector2i(4, 4) for real, through BuildingPlacement, so this
## case leans on the same FakeGrid (every cell "valid"/"buildable") the other
## wall cases in this file already use, with no buildings anywhere to occupy
## either cell -- there is nothing here for the evaluation to reject.
func _test_wall_chain_owner_comes_from_roster(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	_setup_without_assets(controller)
	_setup_controller_placement(controller,
		null, FakeGrid.new(), null, null, null, null, null, Callable()
	)
	_production_for(controller).execute_wall_line(1, Vector2i(2, 4), Vector2i(4, 4), &"ATWall")
	_expect(
		controller._wall_chain != null,
		"a wall line over buildable cells must produce a chain"
	)
	if controller._wall_chain != null:
		_expect(
			controller._wall_chain.owner_player_id == local_player.player_id,
			"the chain must carry the roster's local player id, got %s" % [
				controller._wall_chain.owner_player_id
			]
		)
	controller._cancel_building_order()
	controller.free()
	return token


## node_removed fires for every node in the game. BuildingPlacement releases its
## preview cells through remove_child() on every cursor move, so treating any
## removal as an availability change put the O(ids x buildings) recompute back
## on every frame of a wall-line drag -- the exact cost the cache exists to
## avoid.
func _test_unrelated_node_removal_keeps_availability_cache(token: int, _local_player: PlayerData) -> int:
	var controller := _new_controller()
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	controller.process(0.0)
	_expect(
		not controller._availability_tracker.is_dirty(),
		"a completed refresh must leave the availability cache clean"
	)

	var scratch := Node3D.new()
	root.add_child(scratch)
	root.remove_child(scratch)
	_expect(
		not controller._availability_tracker.is_dirty(),
		"a node that was never a tracked building must not invalidate availability"
	)
	scratch.free()
	controller.free()
	return token


## handle_building_intent() now only submits a SimBuildOrderCommand for a
## click that mutates the production queue (see that method's doc comment) --
## reuses the ATBarracks/ATConYard/ATSmWindtrap availability setup from
## _test_availability_reacts_to_prerequisite_loss() above, since starting an
## order re-checks availability at execution exactly as it used to at click
## time.
func _test_handle_building_intent_defers_start(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	var con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	var windtrap := BuildingStub.new(&"ATSmWindtrap", local_player.player_id)
	root.add_child(con_yard)
	root.add_child(windtrap)
	controller.process(0.0)
	controller.refresh_availability()

	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	_expect(
		controller.handle_building_intent(&"ATBarracks", MOUSE_BUTTON_LEFT),
		"a catalog member must be handled"
	)
	_expect(
		not controller._building_queue.has_order(),
		"a build-order click must not start an order before its command executes"
	)
	pump.pump()
	_expect(
		controller._building_queue.has_order()
		and controller._building_queue.current_order().building_id == &"ATBarracks",
		"a build-order click must start an order once its command executes"
	)

	con_yard.free()
	windtrap.free()
	controller.free()
	return token


func _test_handle_building_intent_defers_pause(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())
	var con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	var windtrap := BuildingStub.new(&"ATSmWindtrap", local_player.player_id)
	root.add_child(con_yard)
	root.add_child(windtrap)
	controller.process(0.0)
	controller.refresh_availability()

	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	controller.handle_building_intent(&"ATBarracks", MOUSE_BUTTON_LEFT)
	pump.pump()
	_expect(
		controller._building_queue.has_order(),
		"setup: an order must be running before testing pause deferral"
	)

	controller.handle_building_intent(&"ATBarracks", MOUSE_BUTTON_RIGHT)
	_expect(
		not controller._building_queue.current_order().manually_paused,
		"a pause click must not take effect before its command executes"
	)
	pump.pump()
	_expect(
		controller._building_queue.current_order().manually_paused,
		"a pause click must pause the active order once its command executes"
	)

	con_yard.free()
	windtrap.free()
	controller.free()
	return token


## A right click observed while the preview is already open is input-only and
## submits nothing. This is the distinct timeline that must still execute as
## production: submit it while the order runs, let that order become ready,
## then open the local preview before the queued command drains.
func _test_queued_right_click_uses_player_production_not_preview(
		token: int, local_player: PlayerData
	) -> int:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller := _new_controller()
	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(
		null, null, null, building_ids, _production_for(controller), null, null,
		null, null, null, null, Callable()
	)
	_setup_controller_placement(
		controller, null, FakeGrid.new(), buildings_root, null, null, null, null, Callable()
	)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._command_bus = pump.bus()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")

	var queue := controller.building_queue_for_player(local_player.player_id)
	var money_before: int = local_player.money
	queue.start(&"ATBarracks", "Barracks", 10, 2)
	queue.advance_tick(local_player.money, Callable(local_player, "spend_money"))
	_expect(
		local_player.money == money_before - 5,
		"setup: the running order must have paid its first half before the right click"
	)
	controller.handle_building_intent(&"ATBarracks", MOUSE_BUTTON_RIGHT)
	_expect(
		pump.bus().pending_count() == 1,
		"setup: a right click while the order runs must submit a deferred production command"
	)
	queue.advance_tick(local_player.money, Callable(local_player, "spend_money"))
	_expect(queue.current_order() != null and queue.current_order().ready, "setup: the order must become ready")
	controller._begin_ready_building_placement()
	_expect(
		controller._building_placement.is_active(),
		"setup: the local user must be able to open the ready-building preview before drain"
	)

	pump.pump()
	_expect(
		not queue.has_order(),
		"a queued right-click must cancel its player's ready order despite the later local preview"
	)
	_expect(
		local_player.money == money_before,
		"a queued right-click must refund its player's paid construction credits"
	)
	_expect(
		not controller._building_placement.is_active(),
		"the local preview must dismiss as the local UI reaction to the canceled order"
	)

	controller.free()
	buildings_root.free()
	return token


## The other half of handle_building_intent()'s split (see its doc comment):
## left-clicking an idle wall slot changes what the player's next click means,
## not the state of any queue, so it must run immediately with no command bus
## involved at all -- this controller never has one wired in here.
func _test_handle_building_intent_wall_entry_stays_local(token: int) -> int:
	var controller := _new_controller()
	var building_ids: Array[StringName] = [&"ATWall"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())

	_expect(
		controller.handle_building_intent(&"ATWall", MOUSE_BUTTON_LEFT),
		"a catalog member must be handled"
	)
	_expect(
		controller._wall_line_mode,
		"left-clicking an idle wall slot must enter wall-line mode immediately, with no command bus needed"
	)
	controller.free()
	return token


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _setup_controller_placement(
		controller,
		camera: Camera3D,
		navigation_grid,
		buildings_root: Node3D,
		arrow_scene: PackedScene,
		building_preview_scene: PackedScene,
		cant_build_preview_scene: PackedScene,
		skirt_preview_scene: PackedScene,
		existing_rows: Callable
) -> void:
	var context := PlacementContextScript.new()
	context.camera = camera
	context.navigation_grid = navigation_grid
	context.buildings_root = buildings_root
	context.arrow_scene = arrow_scene
	context.building_preview_scene = building_preview_scene
	context.cant_build_preview_scene = cant_build_preview_scene
	context.skirt_preview_scene = skirt_preview_scene
	context.existing_building_occupy_rows = existing_rows
	controller._building_placement.setup(context)


## docs/mechanics/production.md section 5: "loss of a prerequisite building
## (verified): ... new entries disappear from menus until the prerequisite
## is restored". BuildingController.process() re-evaluates
## _is_building_available() every tick and only re-emits state when it
## changes (see building_controller.gd process()/_refresh_building_option_
## states()), so this drives that polling loop directly against real Rules
## data (ATBarracks requires a primary ATConYard + a secondary Windtrap;
## assets/converted/rules/buildings/ATBarracks.tres) instead of re-testing
## TechnologyTree in isolation (already covered in
## tests/characterization/run.gd).
func _test_availability_reacts_to_prerequisite_loss(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var latest_states: Dictionary = {}
	controller.building_option_state_changed.connect(func(option_state: BuildingOptionState) -> void:
		latest_states[option_state.building_id] = option_state.state
	)

	var building_ids: Array[StringName] = [&"ATBarracks"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())

	var con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	var windtrap := BuildingStub.new(&"ATSmWindtrap", local_player.player_id)
	root.add_child(con_yard)
	root.add_child(windtrap)

	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.AVAILABLE,
		"ATBarracks must be available once its primary and secondary prerequisites are owned"
	)

	root.remove_child(con_yard)
	con_yard.free()
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.DISABLED,
		"losing the primary prerequisite must disable the entry on the next poll, with nothing already built lost"
	)

	var restored_con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	root.add_child(restored_con_yard)
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.AVAILABLE,
		"restoring the prerequisite must re-enable the entry on the next poll"
	)

	windtrap.set_owner_player_id(2)
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.DISABLED,
		"capturing a prerequisite away from the player must invalidate availability"
	)
	windtrap.set_owner_player_id(local_player.player_id)
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.AVAILABLE,
		"recapturing a prerequisite must restore availability"
	)

	root.remove_child(windtrap)
	windtrap.free()
	var unfinished_windtrap := BuildingStub.new(&"ATSmWindtrap", local_player.player_id)
	unfinished_windtrap.construction_complete = false
	root.add_child(unfinished_windtrap)
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.DISABLED,
		"a newly added unfinished prerequisite must remain unavailable"
	)
	unfinished_windtrap.finish_construction()
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATBarracks") == BuildingOptionStateScript.State.AVAILABLE,
		"construction completion must invalidate and restore availability"
	)

	restored_con_yard.free()
	unfinished_windtrap.free()
	controller.free()
	return token


## docs/mechanics/production.md section 5: "roster expansion (verified):
## every production building and the Construction Yard has an upgrade that
## unlocks next-tech-level entries". ATRocketTurret requires an upgraded
## ATConYard plus any house's Barracks (upgraded_primary_required: true,
## assets/converted/rules/buildings/ATRocketTurret.tres) -- this drives a
## purchase through the same PlayerData.grant_upgrade + UpgradeEffects path
## BuildingUpgradeController._complete_global_upgrade() uses and checks that
## BuildingController's own polling loop (not a re-setup) picks it up.
func _test_availability_reacts_to_upgrade_purchase(token: int, local_player: PlayerData) -> int:
	var controller := _new_controller()
	var latest_states: Dictionary = {}
	controller.building_option_state_changed.connect(func(option_state: BuildingOptionState) -> void:
		latest_states[option_state.building_id] = option_state.state
	)

	var building_ids: Array[StringName] = [&"ATRocketTurret"]
	controller.setup(null, null, null, building_ids, _production_for(controller), null, null, null, null, null, null, Callable())

	var con_yard := BuildingStub.new(&"ATConYard", local_player.player_id)
	var barracks := BuildingStub.new(&"ATBarracks", local_player.player_id)
	root.add_child(con_yard)
	root.add_child(barracks)

	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATRocketTurret") == BuildingOptionStateScript.State.DISABLED,
		"an upgraded_primary_required entry must stay disabled while the primary is not yet upgraded"
	)

	local_player.grant_upgrade(&"ATConYard")
	UpgradeEffectsScript.apply_to_existing_buildings(get_nodes_in_group("buildings"), local_player.player_id, &"ATConYard")
	controller.process(0.0)
	controller.refresh_availability()
	_expect(
		latest_states.get(&"ATRocketTurret") == BuildingOptionStateScript.State.AVAILABLE,
		"the very next poll after a completed upgrade must unlock the entry, no controller restart needed"
	)

	con_yard.free()
	barracks.free()
	controller.free()
	return token
