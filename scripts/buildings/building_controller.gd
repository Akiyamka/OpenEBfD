class_name BuildingController
extends Node3D

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const TerrainProbeScript := preload("res://scripts/world/terrain_probe.gd")
const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")
const SimBuildOrderCommandScript := preload("res://scripts/sim/commands/build_order_command.gd")
const SimSellBuildingCommandScript := preload("res://scripts/sim/commands/sell_building_command.gd")
const SimRepairBuildingCommandScript := preload("res://scripts/sim/commands/repair_building_command.gd")
const SimPlaceBuildingCommandScript := preload("res://scripts/sim/commands/place_building_command.gd")
const SimWallLineCommandScript := preload("res://scripts/sim/commands/wall_line_command.gd")

signal status_changed(status: String)
signal building_option_state_changed(option_state: BuildingOptionState)
signal resources_changed(credits: int, energy: int)
signal sell_mode_changed(active: bool)
signal wall_mode_changed(active: bool)
signal repair_mode_changed(active: bool)
## One public interaction contract for all map-pointer modes.  Selection
## abilities use it to remain mutually exclusive with placement as well as the
## older sell/repair/wall modes.
signal interaction_mode_changed(active: bool)

const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const ProductionSystemScript := preload("res://scripts/production/production_system.gd")
const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const PlacementContextScript := preload("res://scripts/buildings/placement_context.gd")
const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const WallChainScript := preload("res://scripts/buildings/wall_chain.gd")
const DoubleClickTrackerScript := preload("res://scripts/buildings/double_click_tracker.gd")
const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")
const GameSettingsCatalogScript := preload("res://scripts/rules/game_settings_catalog.gd")
const BuildingRepairServiceScript := preload("res://scripts/buildings/building_repair_service.gd")
const PlacementPointerGestureScript := preload("res://scripts/buildings/placement_pointer_gesture.gd")
const BuildingSaleServiceScript := preload("res://scripts/buildings/building_sale_service.gd")
const BuildingCatalogViewScript := preload("res://scripts/buildings/building_catalog_view.gd")
const WallLineSessionScript := preload("res://scripts/buildings/wall_line_session.gd")
const BuildingAvailabilityTrackerScript := preload(
	"res://scripts/buildings/building_availability_tracker.gd"
)

const DEFAULT_BUILD_RADIUS_TILES := 6
const WALL_BUILDING_GROUP := "Wall"
const DOUBLE_CLICK_THRESHOLD_MS := 350
const BUILDING_MODE_CURSOR_OVERRIDE := &"building_mode"

enum Mode { NONE, SELL, REPAIR, WALL_LINE }
enum BuildOrderOutcome {
	NONE,
	RULES,
	UNAVAILABLE,
	ORDERED,
	BUSY,
	READY,
	RESUMED,
	WAITING,
	RUNNING,
	CANCELED,
	PAUSED,
}


class BuildOrderExecution extends RefCounted:
	var kind: BuildOrderOutcome = BuildOrderOutcome.NONE
	var display_name := ""
	var refunded := 0


func _build_order_execution(
		kind: BuildOrderOutcome, display_name: String = "", refunded: int = 0
	) -> BuildOrderExecution:
	var execution := BuildOrderExecution.new()
	execution.kind = kind
	execution.display_name = display_name
	execution.refunded = refunded
	return execution

var camera: Camera3D
## docs/mechanics/production.md section 5 "map tech level": extension point
## for a future map/mission tech-level cap (see TechnologyTree.UNLIMITED_
## TECH_LEVEL for why it defaults to unlimited -- no map data source exists
## yet to set this from).
var max_tech_level: int = TechnologyTreeScript.UNLIMITED_TECH_LEVEL
## The command bus handle_building_intent() submits SimBuildOrderCommands to,
## and a matching way to ask "what tick would a command submitted right now
## target" -- injected together by setup(), production by Match.
## _setup_building_controller() and in tests by
## tests/match/support/command_pump.gd, the same way UnitCommandController's
## are (see that class's own _command_bus field comment). A controller built
## with neither wired in still handles Sell/Repair and the two interaction-
## mode branches handle_building_intent() peels off before ever needing a
## command bus (see that method's doc comment); only a click that would
## mutate the production queue needs one, and _submit_build_order_command()
## fails loudly rather than silently if it is missing.
var _command_bus: SimCommandBus
var _submit_tick_provider: Callable

var _catalog_view = BuildingCatalogViewScript.new()
var _technology_tree: TechnologyTree = TechnologyTreeScript.new()
var _game_settings_catalog := GameSettingsCatalogScript.new()
var _availability_tracker := BuildingAvailabilityTrackerScript.new()
var _refreshing_building_option_states := false
var _production_system: ProductionSystem
var _building_queue: BuildingQueue:
	get:
		return building_queue_for_player(_local_player_id())
var _building_placement: BuildingPlacement = BuildingPlacementScript.new()
## Null when no placement command is in flight; set to the clicked nav cell by
## _try_place_ready_building() the instant it submits a SimPlaceBuildingCommand,
## and cleared by execute_place_building_command() the instant that command
## executes -- every branch, including the stale-command early return, so no
## outcome can leave this set (see that method's doc comment). Between those
## two points a committed placement counts as already placed for input
## purposes, matching what the player saw before the command bus, when the
## click placed the building synchronously: process() pins the preview here
## instead of following the pointer, handle_unhandled_input()'s placement
## branch consumes nothing, and _on_building_slot_right_pressed() will not
## cancel it. hover_cell_from_pointer() already returns this same Variant
## shape (a Vector2i or null), so this field matches it rather than inventing
## a second null-cell convention.
var _committed_placement_cell: Variant = null
var _local_player_resource: PlayerData
var _mode := Mode.NONE
var _sell_mode: bool:
	get:
		return _mode == Mode.SELL
	set(value):
		if value:
			_mode = Mode.SELL
		elif _mode == Mode.SELL:
			_mode = Mode.NONE
var _repair_mode: bool:
	get:
		return _mode == Mode.REPAIR
	set(value):
		if value:
			_mode = Mode.REPAIR
		elif _mode == Mode.REPAIR:
			_mode = Mode.NONE
## Per-building fractional-credit carry.  Credits are integral, but repair
## prices are proportional to health restored, so retaining this remainder
## makes a sequence of repair ticks cost exactly the intended amount (rounded
## down only if the player cancels before the next whole credit is due).
var _repair_service = BuildingRepairServiceScript.new()
var _sale_service = BuildingSaleServiceScript.new()
var _wall_line_mode: bool:
	get:
		return _mode == Mode.WALL_LINE
	set(value):
		if value:
			_mode = Mode.WALL_LINE
		elif _mode == Mode.WALL_LINE:
			_mode = Mode.NONE
var _wall_session = WallLineSessionScript.new()
var _wall_line_start_cell:
	get:
		return _wall_session.start_cell()
	set(value):
		_wall_session.set_start_cell(value)
var _wall_line_building_id: StringName:
	get:
		return _wall_session.current_building_id()
	set(value):
		_wall_session.set_building_id(value)
var _wall_chain: WallChain:
	get:
		return _production_system.wall_chain_for_player(_local_player_id()) if _production_system != null else null
var _building_double_click := DoubleClickTrackerScript.new()
var _pointer_gesture = PlacementPointerGestureScript.new()
var _placement_pointer_down: bool:
	get:
		return _pointer_gesture.pointer_down()
	set(value):
		_pointer_gesture.set_pointer_down(value)
var _placement_press_position: Vector2:
	get:
		return _pointer_gesture.press_position()
	set(value):
		_pointer_gesture.set_press_position(value)


func setup(
		map_loader: MapLoader,
		placement_camera: Camera3D,
		building_parent: Node3D,
		building_ids: Array[StringName],
		production_system: ProductionSystem,
		arrow_scene: PackedScene,
		building_preview_scene: PackedScene,
		cant_build_preview_scene: PackedScene,
		skirt_preview_scene: PackedScene,
		wall_marker_scene: PackedScene,
		command_bus: SimCommandBus,
		submit_tick_provider: Callable
) -> void:
	camera = placement_camera
	_command_bus = command_bus
	_submit_tick_provider = submit_tick_provider
	_production_system = production_system
	_catalog_view.configure(building_ids)
	_availability_tracker.mark_dirty()
	_wall_session.configure(self, _building_placement, wall_marker_scene)
	if _building_placement.get_parent() != self:
		add_child(_building_placement)
	_pointer_gesture.configure(_building_placement)
	var navigation_grid = map_loader.navigation_grid if map_loader != null else null
	var placement_context := PlacementContextScript.new()
	placement_context.camera = placement_camera
	placement_context.navigation_grid = navigation_grid
	placement_context.buildings_root = building_parent
	placement_context.arrow_scene = arrow_scene
	placement_context.building_preview_scene = building_preview_scene
	placement_context.cant_build_preview_scene = cant_build_preview_scene
	placement_context.skirt_preview_scene = skirt_preview_scene
	placement_context.existing_building_occupy_rows = Callable(self, "_occupy_rows_for_existing_building")
	placement_context.existing_building_is_wall = Callable(self, "_is_wall_building")
	placement_context.build_radius_provider = Callable(self, "_build_radius_tiles")
	placement_context.owner_player_id_provider = Callable(self, "_local_player_id")
	_building_placement.setup(placement_context)
	_production_system.configure_wall_chains(
		_building_placement,
		Callable(self, "_building_config"),
		Callable(self, "_building_occupy_rows"),
		Callable(self, "_building_display_name"),
		Callable(self, "_building_scene_path")
	)
	if not _production_system.build_order_ready.is_connected(_on_production_build_order_ready):
		_production_system.build_order_ready.connect(_on_production_build_order_ready)
	if not _production_system.build_order_canceled.is_connected(_on_production_build_order_canceled):
		_production_system.build_order_canceled.connect(_on_production_build_order_canceled)
	if not _production_system.wall_chain_execution.is_connected(_on_production_wall_chain_execution):
		_production_system.wall_chain_execution.connect(_on_production_wall_chain_execution)
	if not _sale_service.completed.is_connected(_on_building_sale_completed):
		_sale_service.completed.connect(_on_building_sale_completed)

	_bind_local_player_roster()
	_availability_tracker.bind(self)
	_refresh_player_resources()
	_refresh_availability_if_dirty()
	_refresh_building_option_states()
	sell_mode_changed.emit(_sell_mode)
	wall_mode_changed.emit(_wall_line_mode)
	repair_mode_changed.emit(_repair_mode)
	interaction_mode_changed.emit(false)


## Frame half of the old process(delta): cursor and placement-preview work.
## Availability is refreshed separately by Match before command execution, so
## this callback cannot make a simulation verdict depend on engine frames.
func process(_delta: float) -> void:
	_update_mode_cursor()
	if _wall_line_mode:
		_process_wall_line_preview(get_viewport().get_mouse_position())
	elif _building_placement.is_active():
		if _committed_placement_cell != null:
			# The pending command names the clicked cell, not wherever the pointer
			# drifts to before execute_place_building_command() clears this (see
			# _committed_placement_cell's own doc comment) -- pin the preview there
			# with preview_at_hover_cells(), which draws at an explicit cell and
			# never touches the pointer, instead of process()'s usual read of the
			# mouse.
			var committed_cells: Array[Vector2i] = [_committed_placement_cell]
			_building_placement.preview_at_hover_cells(committed_cells)
		else:
			var pointer_position := (
				_placement_press_position
				if _placement_pointer_down
				else get_viewport().get_mouse_position()
			)
			_building_placement.process(pointer_position)


## Simulation half of the old process(delta): construction-order progress and
## building repair, both driven from MatchClock rather than frame delta.
## Availability is refreshed separately by Match before its command drain, so
## this and the sibling controllers' advance_tick() calls read that snapshot in
## their fixed order.
func advance_tick() -> void:
	_process_repairs()


## ProductionSystem owns queues in both shipping matches and controller tests.
## This accessor is the controller's player-keyed queue seam.
func building_queue_for_player(player_id: int) -> BuildingQueue:
	return _production_system.build_queue_for_player(player_id)


func _is_building_available_for_player(player_id: int, building_id: StringName) -> bool:
	return _catalog_view.is_available_for(player_id, building_id)


func _on_production_build_order_ready(player_id: int, order: BuildingOrder) -> void:
	if player_id == _local_player_id():
		_on_building_queue_ready(order)


func _on_production_build_order_canceled(player_id: int, order: BuildingOrder, refunded: int) -> void:
	if player_id != _local_player_id():
		return
	_building_placement.cancel()
	_wall_session.clear_markers()
	status_changed.emit("%s canceled; refunded %d" % [order.display_name, refunded])
	_refresh_building_option_states()


func _on_production_wall_chain_execution(
		player_id: int, execution: ProductionSystemScript.WallChainExecution
	) -> void:
	if player_id != _local_player_id():
		return
	_apply_local_wall_chain_execution(execution)


func _apply_local_wall_chain_execution(
		execution: ProductionSystemScript.WallChainExecution
	) -> void:
	match execution.kind:
		ProductionSystemScript.WallChainOutcome.STARTED:
			_wall_session.lock_markers(execution.cells)
			if not execution.cells.is_empty():
				_building_placement.play_wall_line_start_thud(
					_building_placement.wall_marker_world_position(execution.cells[0])
				)
		ProductionSystemScript.WallChainOutcome.BUSY:
			status_changed.emit("Building queue is busy")
		ProductionSystemScript.WallChainOutcome.RULES:
			status_changed.emit("Wall rules are not loaded")
		ProductionSystemScript.WallChainOutcome.NO_BUILDABLE:
			status_changed.emit("Wall line has no buildable segments")
		ProductionSystemScript.WallChainOutcome.EVALUATION_FAILED:
			status_changed.emit("%s segment could not be evaluated" % execution.display_name)
		ProductionSystemScript.WallChainOutcome.SKIPPED:
			_wall_session.remove_marker(_local_wall_chain_cell(execution.segment_index))
			status_changed.emit("%s segment %d/%d skipped" % [
				execution.display_name, execution.segment_index, execution.segment_count,
			])
		ProductionSystemScript.WallChainOutcome.FINAL_SKIPPED:
			if execution.segment_index > 0:
				_wall_session.remove_marker(_local_wall_chain_cell(execution.segment_index))
				status_changed.emit("%s wall complete; segment %d/%d skipped" % [
					execution.display_name, execution.segment_index, execution.segment_count,
				])
			else:
				status_changed.emit("%s wall complete; final segment skipped" % execution.display_name)
		ProductionSystemScript.WallChainOutcome.QUEUE_FAILED:
			status_changed.emit("%s segment could not be queued" % execution.display_name)
		ProductionSystemScript.WallChainOutcome.ORDERED:
			status_changed.emit("%s segment %d/%d ordered" % [
				execution.display_name, execution.segment_index, execution.segment_count,
			])
		ProductionSystemScript.WallChainOutcome.MISSING_ROWS:
			status_changed.emit("%s has no occupy_rows" % execution.display_name)
		ProductionSystemScript.WallChainOutcome.MISSING_SCENE:
			status_changed.emit("%s placement valid; missing scene %s" % [
				execution.display_name, execution.scene_path,
			])
		ProductionSystemScript.WallChainOutcome.PLACEMENT_FAILED:
			status_changed.emit("%s segment could not be placed; wall chain stopped" % execution.display_name)
		ProductionSystemScript.WallChainOutcome.PLACED:
			_wall_session.remove_marker(_local_wall_chain_cell(execution.segment_index))
			status_changed.emit("%s segment %d/%d placed" % [
				execution.display_name, execution.segment_index, execution.segment_count,
			])
		ProductionSystemScript.WallChainOutcome.COMPLETE:
			status_changed.emit("%s wall complete" % execution.display_name)
		ProductionSystemScript.WallChainOutcome.ENDED:
			_wall_session.clear_markers()
	_refresh_building_option_states()


func _local_wall_chain_cell(segment_index: int):
	var chain := _wall_chain
	if chain == null or segment_index <= 0 or segment_index > chain.cells.size():
		return null
	return chain.cells[segment_index - 1]


## Match calls this after entity admission and before command execution, so
## availability readers in that tick share the same settled snapshot.
func refresh_availability() -> void:
	_refresh_availability_if_dirty()


func _exit_tree() -> void:
	_availability_tracker.unbind()
	var cursors: Variant = _cursor_manager()
	if cursors != null:
		cursors.clear_override(BUILDING_MODE_CURSOR_OVERRIDE)



## HEAD's _is_building_available() started with `if not is_inside_tree():
## return false` -- once outside the tree (mid-teardown, or before the first
## add_child()), nothing is available, full stop. _catalog_view.is_available_for()
## has no notion of "in tree" (it is a plain RefCounted), and the normal dirty
## check below only recomputes when the availability tracker has actually seen
## a change, so a controller that leaves the tree without one more dirtying
## event would otherwise keep serving its last, possibly-true, cached
## availability forever. Clear every per-player cache unconditionally
## (bypassing the dirty flag) whenever outside the tree, so no player's last
## true value can survive teardown without teaching the catalog view about
## scene-tree lifetime.
func _refresh_availability_if_dirty() -> void:
	if not is_inside_tree():
		if _catalog_view.clear_availability():
			_refresh_building_option_states()
		return
	if not _availability_tracker.consume_dirty():
		return
	var buildings := _availability_tracker.buildings()
	var local_changed := false
	var players = _players()
	if players != null:
		for player_id in players.player_ids():
			if _catalog_view.refresh_availability(
				_technology_tree, players.player(player_id), buildings, max_tech_level
			) and player_id == players.local_player_id:
				local_changed = true
	elif _catalog_view.refresh_availability(_technology_tree, _local_player(), buildings, max_tech_level):
		local_changed = true
	if local_changed:
		_refresh_building_option_states()


func handle_unhandled_input(event: InputEvent) -> bool:
	if _repair_mode:
		if not (event is InputEventMouseButton and event.pressed):
			return false
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_try_toggle_building_repair(event.position)
			return true
		if event.button_index == MOUSE_BUTTON_LEFT:
			_set_repair_mode(false)
			return true
		return false

	if _sell_mode:
		if not (event is InputEventMouseButton and event.pressed):
			return false
		if event.button_index == MOUSE_BUTTON_LEFT:
			_try_sell_building(event.position)
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_set_sell_mode(false)
			return true
		return false

	if _wall_line_mode:
		if not (event is InputEventMouseButton and event.pressed):
			return false
		if event.button_index == MOUSE_BUTTON_LEFT:
			_on_wall_line_click(event.position)
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_set_wall_line_mode(false)
			return true
		return false

	# A committed placement (see _committed_placement_cell's doc comment)
	# already counts as placed for input purposes, so it takes the same branch
	# as no placement at all -- folded in here rather than given its own early
	# return, since this function is already at the linter's max-returns cap
	# and both cases end identically: consume nothing, and let the event fall
	# through to the controllers behind this one (Match._unhandled_input()
	# offers UnitCommandController the event next). The double-click branch
	# runs in the committed case too, and deliberately: before the command
	# bus the confirming click placed the building synchronously, so the next
	# click reached exactly this path.
	if not _building_placement.is_active() or _committed_placement_cell != null:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if _try_handle_building_double_click(event.position):
				return true
		return false
	if event is InputEventMouseMotion:
		if not _placement_pointer_down:
			return false
		_update_placement_rotation(event.position)
		return true
	if not event is InputEventMouseButton:
		return false

	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_placement_pointer_action(event.position)
			else:
				_finish_placement_pointer_action(event.position)
			return true
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_reset_placement_pointer_action()
				_cancel_building_placement()
				return true
	return false


## Match composition calls this when a map-target ability takes ownership of
## pointer input.  Keeping the cancellation on BuildingController preserves
## its one authoritative mode/preview cleanup path.
func cancel_interaction_modes() -> void:
	var had_mode := _sell_mode or _repair_mode or _wall_line_mode or _building_placement.is_active()
	if _sell_mode:
		_deactivate_sell_mode()
	if _repair_mode:
		_deactivate_repair_mode(true)
	if _wall_line_mode:
		_deactivate_wall_line_mode(true)
	if _building_placement.is_active():
		_cancel_building_placement()
	if had_mode:
		status_changed.emit("Building interaction canceled")
		interaction_mode_changed.emit(false)


func _begin_placement_pointer_action(screen_position: Vector2) -> void:
	_pointer_gesture.begin(screen_position)


func _update_placement_rotation(screen_position: Vector2) -> void:
	_pointer_gesture.update_rotation(screen_position)


func _finish_placement_pointer_action(screen_position: Vector2) -> void:
	_pointer_gesture.finish(
		screen_position,
		Callable(self, "_emit_status"),
		Callable(self, "_try_place_ready_building")
	)


func _reset_placement_pointer_action() -> void:
	_pointer_gesture.reset()


func _emit_status(message: String) -> void:
	status_changed.emit(message)


func handle_command(command: StringName) -> bool:
	match command:
		&"Sell":
			_set_sell_mode(not _sell_mode)
			return true
		&"Repair":
			_set_repair_mode(not _repair_mode)
			return true
	return false


## The command-bus seam for the sidebar's building slots (see
## docs/architecture/network-multiplayer.md, "Layering" -- "commands" vs
## "simulation"). Two branches never reach the bus at all, because they are
## interaction-mode changes rather than production-queue mutations -- exactly
## the same distinction that keeps Sell/Repair (handle_command()) local, just
## reached from a different entry point:
##
## - left-clicking a wall slot with no order or chain in flight for it opens
##   wall-line picking;
## - left-clicking a slot whose order is already ready opens the interactive
##   placement preview, and right-clicking a slot while that preview is open
##   for it cancels the preview, not the order.
##
## Both change what the player's next click means, not the state of any
## queue, so both still run immediately through the existing (unchanged)
## _on_building_slot_left_pressed()/_on_building_slot_right_pressed() --
## nothing another client would ever need to agree on. Every other click is a
## real queue mutation -- start, resume, pause, cancel, or the "busy"/"waiting
## for credits" feedback for a click that cannot do any of those right now --
## and is deferred through a SimBuildOrderCommand instead, so every client
## reaches the same verdict from the same queue state on the tick it actually
## executes; see execute_build_order_command() and SimBuildOrderCommand's own
## doc comment.
func handle_building_intent(building_id: StringName, button_index: int) -> bool:
	if not _catalog_view.has(building_id):
		return false
	match button_index:
		MOUSE_BUTTON_LEFT:
			if _left_building_intent_is_mode_action(building_id):
				_on_building_slot_left_pressed(building_id)
			else:
				_submit_build_order_command(building_id, button_index)
			return true
		MOUSE_BUTTON_RIGHT:
			if _right_building_intent_is_mode_action(building_id):
				_on_building_slot_right_pressed(building_id)
			else:
				_submit_build_order_command(building_id, button_index)
			return true
	return false


## Mirrors the two local branches _on_building_slot_left_pressed() short-circuit on before ever touching
## _building_queue -- see handle_building_intent()'s doc comment. Read-only:
## deciding whether *this* click is a mode action must not itself mutate
## anything, since the mutating branch still needs an untouched queue to
## classify against if this returns false.
func _left_building_intent_is_mode_action(building_id: StringName) -> bool:
	var order := _building_queue.current_order()
	if order != null and order.building_id == building_id and order.ready:
		return true
	if not _is_wall_building_id(building_id):
		return false
	var chain_active := _wall_chain != null and _wall_chain.building_id == building_id
	return order == null and not chain_active


## Mirrors _on_building_slot_right_pressed()'s two local branches -- see
## _left_building_intent_is_mode_action()'s doc comment for why this must stay
## read-only.
func _right_building_intent_is_mode_action(building_id: StringName) -> bool:
	if _is_wall_building_id(building_id) and _wall_line_mode and _wall_line_building_id == building_id:
		return true
	var order := _building_queue.current_order()
	return order != null and order.building_id == building_id and _building_placement.is_active()


## The issue side of a build-order click, once handle_building_intent() has
## already established this is not an interaction-mode change: immediate, and
## split from execution on purpose, exactly as every other command (see
## SimBuildOrderCommand's doc comment). A controller with no command bus
## wired in is a wiring mistake, not a supported mode -- see the
## _command_bus field comment.
func _submit_build_order_command(building_id: StringName, button_index: int) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"BuildingController._submit_build_order_command(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_building_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
		return
	var command := SimBuildOrderCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.building_id = building_id
	command.button_index = button_index
	_command_bus.submit(command, _submit_tick_provider.call())


## The execution side of a build-order click: Match._advance_simulation_tick()
## calls this with the SimBuildOrderCommand it just drained, on the tick the
## bus scheduled it for. Every command runs one player-keyed queue operation;
## only the matching local client applies its returned outcome to status,
## preview, and sidebar state. handle_building_intent() keeps picker and other
## interaction-mode changes out of the bus before this point.
func execute_build_order_command(command: SimBuildOrderCommand) -> void:
	var outcome := _execute_player_build_order(command)
	if _is_wall_building_id(command.building_id) and outcome.kind == BuildOrderOutcome.CANCELED:
		_production_system.cancel_wall_chain(command.player_id)
	if command.player_id == _local_player_id():
		_apply_local_build_order_outcome(outcome)


func _execute_player_build_order(command: SimBuildOrderCommand) -> BuildOrderExecution:
	var queue = building_queue_for_player(command.player_id)
	var order := queue.current_order()
	match command.button_index:
		MOUSE_BUTTON_LEFT:
			if order == null:
				var config := _building_config(command.building_id)
				if config == null:
					return _build_order_execution(BuildOrderOutcome.RULES)
				if not _is_building_available_for_player(command.player_id, command.building_id):
					return _build_order_execution(
						BuildOrderOutcome.UNAVAILABLE, _building_display_name(command.building_id)
					)
				if not queue.start(
					command.building_id,
					_building_display_name(command.building_id),
					maxi(config.cost, 0),
					RuleTicksScript.order_sim_ticks(config.build_time_ticks)
				):
					return _build_order_execution(BuildOrderOutcome.NONE)
				return _build_order_execution(
					BuildOrderOutcome.ORDERED, _building_display_name(command.building_id)
				)
			if order.building_id != command.building_id:
				return _build_order_execution(BuildOrderOutcome.BUSY)
			if order.ready:
				return _build_order_execution(BuildOrderOutcome.READY)
			if order.manually_paused:
				queue.resume()
				return _build_order_execution(BuildOrderOutcome.RESUMED, order.display_name)
			return _build_order_execution(
				BuildOrderOutcome.WAITING if queue.lacks_funds() else BuildOrderOutcome.RUNNING,
				order.display_name
			)
		MOUSE_BUTTON_RIGHT:
			if order == null or order.building_id != command.building_id:
				return _build_order_execution(BuildOrderOutcome.NONE)
			if order.ready or order.manually_paused:
				var refunded := queue.cancel()
				var players = _players()
				var player = players.player(command.player_id) if players != null else null
				if player != null and refunded > 0:
					player.add_money(refunded)
				return _build_order_execution(
					BuildOrderOutcome.CANCELED, order.display_name, refunded
				)
			queue.pause()
			return _build_order_execution(BuildOrderOutcome.PAUSED, order.display_name)
	return _build_order_execution(BuildOrderOutcome.NONE)


func _apply_local_build_order_outcome(outcome: BuildOrderExecution) -> void:
	match outcome.kind:
		BuildOrderOutcome.RULES:
			status_changed.emit("Building rules are not loaded")
			return
		BuildOrderOutcome.UNAVAILABLE:
			status_changed.emit("%s is not available" % outcome.display_name)
		BuildOrderOutcome.ORDERED:
			_building_placement.cancel()
			status_changed.emit("%s ordered" % outcome.display_name)
		BuildOrderOutcome.BUSY:
			status_changed.emit("Building queue is busy")
		BuildOrderOutcome.READY:
			_begin_ready_building_placement()
		BuildOrderOutcome.RESUMED:
			status_changed.emit("%s construction resumed" % outcome.display_name)
		BuildOrderOutcome.WAITING:
			status_changed.emit("%s construction is waiting for credits" % outcome.display_name)
		BuildOrderOutcome.RUNNING:
			status_changed.emit("%s construction is already running" % outcome.display_name)
		BuildOrderOutcome.CANCELED:
			_building_placement.cancel()
			status_changed.emit("%s canceled; refunded %d" % [outcome.display_name, outcome.refunded])
		BuildOrderOutcome.PAUSED:
			status_changed.emit("%s construction paused" % outcome.display_name)
		BuildOrderOutcome.NONE:
			return
	_refresh_building_option_states()


## _sell_mode/_repair_mode/_wall_line_mode are property shims over the single
## _mode enum (see its declaration above), so once one of them is written the
## other two immediately read as inactive regardless of their true prior
## state. Every _set_*_mode() below therefore captures the sibling modes'
## state into was_* locals BEFORE writing its own field, and hands that
## captured state to the _deactivate_*_mode() helpers instead of letting
## those helpers re-read the (by-then-corrupted) live properties. Mirrors
## git show HEAD -- back when these were three independent bool fields, a
## plain live re-read was accurate; it no longer is.
func _set_sell_mode(active: bool) -> void:
	var was_repair := _repair_mode
	var was_wall := _wall_line_mode
	_sell_mode = active
	_update_mode_cursor()
	sell_mode_changed.emit(active)
	if active:
		_deactivate_repair_mode(was_repair)
		_deactivate_wall_line_mode(was_wall)
		_cancel_building_placement()
		status_changed.emit("Sell mode: select one of your buildings")
	else:
		status_changed.emit("Sell mode canceled")
	interaction_mode_changed.emit(active)


func _set_wall_line_mode(active: bool, building_id: StringName = &"") -> void:
	var was_repair := _repair_mode
	var was_wall := _wall_line_mode
	_wall_line_mode = active
	_wall_line_start_cell = null
	_wall_line_building_id = building_id if active else &""
	wall_mode_changed.emit(active)
	if active:
		_deactivate_repair_mode(was_repair)
		_deactivate_sell_mode()
		_cancel_building_placement()
		_begin_wall_line_preview(building_id)
		status_changed.emit("Wall mode: click the line start, then the line end")
	else:
		if was_wall:
			_building_placement.cancel()
		status_changed.emit("Wall mode canceled")
	_refresh_building_option_states()
	interaction_mode_changed.emit(active)


func _set_repair_mode(active: bool) -> void:
	if _repair_mode == active:
		return
	var was_sell := _sell_mode
	var was_wall := _wall_line_mode
	_repair_mode = active
	_update_mode_cursor()
	repair_mode_changed.emit(active)
	if active:
		if was_sell:
			_deactivate_sell_mode()
		if was_wall:
			_deactivate_wall_line_mode(was_wall)
		_cancel_building_placement()
		status_changed.emit("Repair mode: right-click a damaged building; left-click to exit")
	else:
		status_changed.emit("Repair mode canceled")
	interaction_mode_changed.emit(active)


## Deactivation body of _set_sell_mode(false); sell mode has no guard, so
## this always runs -- see the header comment above _set_sell_mode().
func _deactivate_sell_mode() -> void:
	_sell_mode = false
	_update_mode_cursor()
	sell_mode_changed.emit(false)
	status_changed.emit("Sell mode canceled")


## Deactivation body of _set_repair_mode(false); repair mode only ever acted
## when it was truly active (see the `if _repair_mode == active: return`
## guard in _set_repair_mode()), which `was_active` reproduces here now that
## a live re-read of _repair_mode can no longer be trusted mid-transition.
func _deactivate_repair_mode(was_active: bool) -> void:
	if not was_active:
		return
	_repair_mode = false
	_update_mode_cursor()
	repair_mode_changed.emit(false)
	status_changed.emit("Repair mode canceled")


## Deactivation body of _set_wall_line_mode(false); wall mode has no top-level
## guard, so the field reset/emit/status always run -- only the placement
## cancel is conditional on the mode having truly been active, per HEAD.
func _deactivate_wall_line_mode(was_active: bool) -> void:
	_wall_line_mode = false
	_wall_line_start_cell = null
	_wall_line_building_id = &""
	wall_mode_changed.emit(false)
	if was_active:
		_building_placement.cancel()
	status_changed.emit("Wall mode canceled")
	_refresh_building_option_states()


## The command-bus seam for repair mode's right-click (see
## docs/architecture/network-multiplayer.md, "Layering" -- "commands" vs
## "simulation"). Only the raycast and the "you clicked nothing" verdict stay
## here: a click that resolves to no building is not a game action and must
## not put anything on the wire, the same reason a move click onto no
## terrain submits nothing. Everything else -- ownership, the damage check,
## and which direction the toggle goes -- moves to
## execute_repair_building_command(), which SimRepairBuildingCommand's own
## doc comment explains must read the toggle direction at execution time, not
## here at click time.
func _try_toggle_building_repair(screen_position: Vector2) -> void:
	var hit := _raycast(screen_position, 2)
	var building := _find_building(hit.get("collider") as Node)
	if building == null:
		status_changed.emit("Select one of your damaged buildings to repair")
		return
	_submit_repair_building_command(building)


## Mirrors _submit_build_order_command()'s shape exactly, including its
## push_error when no command bus is wired in -- see that method's doc
## comment and the _command_bus field comment for why a missing bus is a
## wiring mistake, not a supported mode.
func _submit_repair_building_command(building: Node3D) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"BuildingController._submit_repair_building_command(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_building_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
		return
	var command := SimRepairBuildingCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.entity_id = int(building.get(&"entity_id")) if &"entity_id" in building else 0
	_command_bus.submit(command, _submit_tick_provider.call())


## The execution side of a repair click: CommandExecutor.execute()
## (scripts/match/command_executor.gd) calls this with `building` already
## resolved from the SimRepairBuildingCommand it just drained, on the tick
## the bus scheduled it for. This is the entire remaining body of what used
## to be _try_toggle_building_repair() before the command bus existed --
## ownership, the damage check, and the toggle -- unchanged except that
## is_repairing is now necessarily read here, at execution time, rather than
## at the click: two clicks landing on the same tick then toggle twice, which
## is what the player actually did.
func execute_repair_building_command(building: Node3D) -> void:
	if not _is_local_player_building(building):
		status_changed.emit("You can only repair your own buildings")
		return
	if not &"health" in building or not &"max_health" in building or float(building.get("health")) >= float(building.get("max_health")):
		status_changed.emit("Only damaged buildings can be repaired")
		return
	var repairing := bool(building.get("is_repairing")) if &"is_repairing" in building else false
	if repairing:
		_set_building_repairing(building, false)
		status_changed.emit("%s repair canceled" % _building_name(building))
		return
	_set_building_repairing(building, true)
	status_changed.emit("%s repair started" % _building_name(building))


func _process_repairs() -> void:
	var settings := _game_settings_catalog.settings()
	var repair_health := float(settings.building_repair_rate) if settings != null else 12.0
	var buildings: Array[Node] = []
	# "sim_buildings", not "buildings": only called from advance_tick(), which
	# Match._advance_simulation_tick() drives -- healing a building's health
	# is a simulation write, so this must walk the same population the tick
	# itself simulates, not everything the view layer can currently see.
	buildings.assign(get_tree().get_nodes_in_group("sim_buildings"))
	_repair_service.advance_tick(
		buildings, repair_health, _local_player(), Callable(self, "_config_of")
	)


func _set_building_repairing(building: Node3D, active: bool) -> void:
	_repair_service.set_repairing(building, active)


func _building_name(building: Node3D) -> String:
	var id := String(building.get("config_id"))
	return id if not id.is_empty() else building.name


func _on_wall_line_click(screen_position: Vector2) -> void:
	_wall_session.click(
		screen_position, Callable(self, "_emit_status"), Callable(self, "_finish_wall_selection")
	)
	_refresh_building_option_states()


## The command-bus seam for the wall line's second click (see
## docs/architecture/network-multiplayer.md, "Layering" -- "commands" vs
## "simulation"). Only leaving wall mode stays here, local and immediate: the
## player's second click ends the aiming mode whether or not the line turns
## out buildable on the tick this command executes, the same reasoning
## _try_place_ready_building()'s doc comment gives for its own "no active
## preview" guard staying local. Everything else -- which cells are buildable,
## locking markers on them, and ordering the first segment -- moves to
## execute_wall_line_command(), which recomputes the buildable set against the
## map as it stands at execution time; see SimWallLineCommand's own doc
## comment for why the preview's snapshot must not travel on the wire.
func _finish_wall_selection(
		start_cell: Vector2i,
		end_cell: Vector2i,
		building_id: StringName
) -> void:
	_set_wall_line_mode(false)
	_submit_wall_line_command(start_cell, end_cell, building_id)


func _begin_wall_line_preview(building_id: StringName) -> void:
	var occupy_rows := _building_occupy_rows(_building_config(building_id))
	if _wall_session.begin(
		building_id, _building_display_name(building_id), occupy_rows
	):
		_wall_session.process_preview(get_viewport().get_mouse_position())


func _process_wall_line_preview(screen_position: Vector2) -> void:
	if _wall_line_mode:
		_wall_session.process_preview(screen_position)


func _preview_wall_line_to_hover_cell(hover_cell: Vector2i) -> void:
	_wall_session.preview_to(hover_cell)


func _lock_wall_markers(anchor_cells: Array[Vector2i]) -> void:
	_wall_session.lock_markers(anchor_cells)


func _remove_wall_marker(anchor_cell: Vector2i) -> void:
	_wall_session.remove_marker(anchor_cell)


func _clear_wall_markers() -> void:
	_wall_session.clear_markers()

## The command-bus seam for sell mode's left-click (see
## docs/architecture/network-multiplayer.md, "Layering" -- "commands" vs
## "simulation"). Only the raycast and the "you clicked nothing" verdict stay
## here -- see _try_toggle_building_repair()'s doc comment for why, which
## applies identically. Everything else -- the sale-service busy check,
## ownership, and starting the sale -- moves to
## execute_sell_building_command().
func _try_sell_building(screen_position: Vector2) -> void:
	var hit := _raycast(screen_position, 2)
	var building := _find_building(hit.get("collider") as Node)
	if building == null:
		status_changed.emit("Select one of your buildings to sell")
		return
	_submit_sell_building_command(building)


## Mirrors _submit_build_order_command()'s shape exactly, including its
## push_error when no command bus is wired in -- see that method's doc
## comment and the _command_bus field comment for why a missing bus is a
## wiring mistake, not a supported mode.
func _submit_sell_building_command(building: Node3D) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"BuildingController._submit_sell_building_command(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_building_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
		return
	var command := SimSellBuildingCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.entity_id = int(building.get(&"entity_id")) if &"entity_id" in building else 0
	_command_bus.submit(command, _submit_tick_provider.call())


## The execution side of a sell click: CommandExecutor.execute()
## (scripts/match/command_executor.gd) calls this with `building` already
## resolved from the SimSellBuildingCommand it just drained, on the tick the
## bus scheduled it for. This is the entire remaining body of what used to be
## _try_sell_building() before the command bus existed, unchanged.
func execute_sell_building_command(building: Node3D) -> void:
	if _sale_service.is_active():
		return

	if not _is_local_player_building(building):
		status_changed.emit("You can only sell your own buildings")
		return

	_set_sell_mode(false)
	# Technology and production only count completed buildings. A selling
	# building remains visible until its transition finishes, but must stop
	# satisfying prerequisites the instant its sale begins.
	if building.has_method("begin_construction"):
		building.call("begin_construction")
	_refresh_building_option_states()
	_sale_service.start(building, _local_player(), _config_of(building))


func _update_mode_cursor() -> void:
	var cursors: Variant = _cursor_manager()
	if cursors == null:
		return
	if _sell_mode:
		var hit := _raycast(get_viewport().get_mouse_position(), 2)
		var building := _find_building(hit.get("collider") as Node)
		var cursor := (
			CursorManagerScript.CursorType.SELL
			if _is_local_player_building(building)
			else CursorManagerScript.CursorType.CANT_SELL
		)
		cursors.set_override(BUILDING_MODE_CURSOR_OVERRIDE, cursor, 50)
		return
	if _repair_mode:
		var hit := _raycast(get_viewport().get_mouse_position(), 2)
		var building := _find_building(hit.get("collider") as Node)
		var cursor := (
			CursorManagerScript.CursorType.REPAIR
			if _can_repair_building(building)
			else CursorManagerScript.CursorType.CANT_REPAIR
		)
		cursors.set_override(BUILDING_MODE_CURSOR_OVERRIDE, cursor, 50)
		return
	if _building_placement.is_active() or _wall_line_mode or _wall_chain != null:
		cursors.set_override(
			BUILDING_MODE_CURSOR_OVERRIDE, CursorManagerScript.CursorType.POINTER, 50
		)
		return
	cursors.clear_override(BUILDING_MODE_CURSOR_OVERRIDE)


## Ownership gate shared by sell, repair and primary designation -- all three
## require the building to belong to the local player.
func _is_local_player_building(building: Node3D) -> bool:
	var players = _players()
	return (
		building != null
		and players != null
		and building.has_method("is_owned_by")
		and building.call("is_owned_by", players.local_player_id)
	)


func _can_repair_building(building: Node3D) -> bool:
	return _is_local_player_building(building) \
		and &"health" in building \
		and &"max_health" in building \
		and float(building.get("health")) < float(building.get("max_health"))


func _cursor_manager() -> Variant:
	return AutoloadLookupScript.cursors(self)


func _on_building_sale_completed(display_name: String, refund: int) -> void:
	status_changed.emit("%s sold; refunded %d" % [display_name, refund])


func _try_handle_building_double_click(screen_position: Vector2) -> bool:
	var hit := _raycast(screen_position, 2)
	var building := _find_building(hit.get("collider") as Node)
	if building == null:
		return false

	if not _is_local_player_building(building):
		return false

	var now := Time.get_ticks_msec()
	if not _building_double_click.register_click(building, now, DOUBLE_CLICK_THRESHOLD_MS):
		return false

	return _designate_primary_building(building, _local_player_id())


func _designate_primary_building(building: Node3D, player_id: int) -> bool:
	var config := _config_of(building)
	if config == null or not config.can_be_primary:
		return false

	var players = _players()
	if players == null:
		return false

	if config.is_construction_yard:
		players.set_main_base(player_id, building)
		status_changed.emit("%s designated as primary Construction Yard (main base)" % String(building.get("config_id")))
		return true

	# Unit queues are shared by building type; the primary instance is the one
	# that releases completed units and owns that queue's rally point.
	var group_key := String(building.get("config_id"))
	if group_key.is_empty():
		return false
	players.designate_primary_building(building, player_id, group_key)
	status_changed.emit("%s designated as primary production building" % group_key)
	return true


func _find_building(node: Node) -> Node3D:
	var current := node
	while current != null:
		if current.is_in_group("buildings") and current is Node3D:
			return current as Node3D
		current = current.get_parent()
	return null


func _bind_local_player_roster() -> void:
	var players = _players()
	if players == null:
		_refresh_player_resources()
		return

	var callback := Callable(self, "_on_local_player_changed")
	if not players.local_player_changed.is_connected(callback):
		players.local_player_changed.connect(callback)

	_bind_local_player_resource()


func _bind_local_player_resource() -> void:
	var callback := Callable(self, "_on_local_player_resources_changed")
	if _local_player_resource != null and _local_player_resource.resources_changed.is_connected(callback):
		_local_player_resource.resources_changed.disconnect(callback)

	_local_player_resource = null
	_local_player_resource = _local_player()

	if _local_player_resource != null and not _local_player_resource.resources_changed.is_connected(callback):
		_local_player_resource.resources_changed.connect(callback)

	_refresh_player_resources()


func _on_local_player_changed(_player_id: int) -> void:
	_bind_local_player_resource()
	_refresh_building_option_states()


func _on_local_player_resources_changed(_player_id: int, _money: int, _energy: int) -> void:
	_refresh_player_resources()
	_refresh_building_option_states()


func _refresh_player_resources() -> void:
	var player = _local_player()
	resources_changed.emit(player.money if player != null else 0, player.energy if player != null else 0)


func _on_building_slot_left_pressed(building_id: StringName) -> void:
	if _is_wall_building_id(building_id):
		_set_wall_line_mode(true, building_id)
		return

	var order := _building_queue.current_order()
	if order != null and order.building_id == building_id and order.ready:
		_begin_ready_building_placement()


func _on_building_slot_right_pressed(building_id: StringName) -> void:
	if _is_wall_building_id(building_id) and _wall_line_mode and _wall_line_building_id == building_id:
		_set_wall_line_mode(false)
		return

	var order := _building_queue.current_order()
	if order == null or order.building_id != building_id:
		return

	if _building_placement.is_active():
		# A committed placement is already placed for input purposes (see
		# _committed_placement_cell's doc comment) -- the sidebar's right-click
		# cancel path must not treat it as a still-cancelable preview any more
		# than the map's own right click may (handle_unhandled_input()).
		if _committed_placement_cell == null:
			_cancel_building_placement()
		return

func _on_building_queue_ready(order: BuildingOrder) -> void:
	status_changed.emit("%s ready" % order.display_name)
	_refresh_building_option_states()


func _cancel_building_order() -> void:
	var order := _building_queue.current_order()
	if order == null:
		return

	var display_name := String(order.display_name)
	var refunded := _building_queue.cancel()
	var player = _local_player()
	if player != null and refunded > 0:
		player.add_money(refunded)

	_building_placement.cancel()
	# The wall chain only auto-orders a later buildable cell after the current
	# one finishes (blocked cells in between are skipped), so cancelling the
	# in-flight order is enough to stop the whole chain.
	_production_system.cancel_wall_chain(_local_player_id())
	_wall_session.clear_markers()
	status_changed.emit("%s canceled; refunded %d" % [display_name, refunded])
	_refresh_building_option_states()


func _begin_ready_building_placement() -> void:
	var order := _building_queue.current_order()
	if order == null or not order.ready:
		return

	var config := _building_config(order.building_id)
	var occupy_rows := _building_occupy_rows(config)
	if not _building_placement.begin(order.building_id, order.display_name, occupy_rows, _is_wall_building_id(order.building_id)):
		status_changed.emit("%s has no occupy_rows" % order.display_name)
		return

	_building_placement.process(get_viewport().get_mouse_position())
	status_changed.emit("%s placement ready" % order.display_name)
	_refresh_building_option_states()
	interaction_mode_changed.emit(true)


func _wall_nav_cells_between(
		from_nav_cell: Vector2i, to_nav_cell: Vector2i
) -> Array[Vector2i]:
	return _wall_session.nav_cells_between(from_nav_cell, to_nav_cell)


## The command-bus seam for the left click that drops a ready building order
## onto the map (see docs/architecture/network-multiplayer.md, "Layering" --
## "commands" vs "simulation"). Only what cannot be recomputed later stays
## here -- see _try_toggle_building_repair()'s doc comment for why the same
## split applies: the "no active preview" guard is view state (you can only
## click-to-place while the preview is up), and resolving the pointer to a
## nav cell is a raycast against local geometry, the same treatment
## SimMoveCommand.target gets (see its doc comment). A click that resolves to
## no cell is not a game action and must not put anything on the wire, the
## same reason a move click onto no terrain submits nothing.
##
## The evaluate_at_hover_cell() call below is a second, identically-reasoned
## filter: a click on a cell BuildingPlacement already knows is unbuildable is
## just as much "not a game action" as a click that resolved to no cell at
## all, so it must not reach the wire either -- before the command bus this
## same check (then still called synchronously) answered a doomed click
## immediately, with no round trip. evaluate_at_hover_cell() is pure and draws
## no preview (see its own doc comment), so calling it here costs nothing.
##
## This is NOT the same check execute_place_building_command() makes when the
## command actually executes, even though both calls resolve to
## BuildingPlacement's one shared implementation of "can this go here" --
## they are the same implementation used for two different jobs, and neither
## one may be deleted as redundant with the other:
##   - this one is a FILTER, over the world as the issuing client sees it
##     right now. It may only suppress a click; it never authorizes one.
##   - execute_place_building_command()'s call is the AUTHORITY, over the
##     world as it stands on the tick the command actually executes.
## The two tell different stories whenever the world moves between the click
## and that tick -- input delay is no longer zero, so another player can take
## the cell, a unit can park on it, or the order itself can change, all
## inside that window. A filter that passed here proves nothing about the
## tick execute_place_building_command() runs on; only that call decides.
## Everything else -- does the scene exist, actually spawning the building --
## moves there too, reading BuildingPlacement's verdict fresh at execution
## time, not here.
##
## _committed_placement_cell is set below the instant this submits, and is
## what makes a committed placement count as already placed for input
## purposes until execute_place_building_command() clears it -- see that
## field's own doc comment. The guard against it here covers a direct second
## call the same way handle_unhandled_input()'s own guard covers the normal
## input path (see that method's doc comment) -- belt and suspenders, not a
## second source of truth: the field stays untouched, so this returns exactly
## as if nothing had happened.
func _try_place_ready_building(screen_position: Vector2) -> void:
	var order := _building_queue.current_order()
	if order == null or not _building_placement.is_active():
		return
	if _committed_placement_cell != null:
		return

	var hover_cell = _building_placement.hover_cell_from_pointer(screen_position)
	if hover_cell == null:
		status_changed.emit("%s placement needs terrain" % order.display_name)
		return

	match _building_placement.evaluate_at_hover_cell(hover_cell):
		BuildingPlacementScript.PlaceResult.CANNOT_BUILD:
			status_changed.emit("%s cannot be placed there" % order.display_name)
			return
		BuildingPlacementScript.PlaceResult.NEEDS_TERRAIN:
			status_changed.emit("%s placement needs terrain" % order.display_name)
			return
		BuildingPlacementScript.PlaceResult.INACTIVE:
			# Unreachable: the is_active() guard above already returns before this
			# point whenever BuildingPlacement is inactive. No new status string
			# for a verdict that can never actually be reached from here.
			return

	_committed_placement_cell = hover_cell
	_submit_place_building_command(
		order.building_id, hover_cell, _building_placement.rotation_quarter_turns()
	)


## Mirrors _submit_sell_building_command()'s shape exactly, including its
## push_error when no command bus is wired in -- see that method's doc
## comment and the _command_bus field comment for why a missing bus is a
## wiring mistake, not a supported mode.
func _submit_place_building_command(
		building_id: StringName, nav_cell: Vector2i, rotation_quarter_turns: int
	) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"BuildingController._submit_place_building_command(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_building_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
		return
	var command := SimPlaceBuildingCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.building_id = building_id
	command.nav_cell = nav_cell
	command.rotation_quarter_turns = rotation_quarter_turns
	_command_bus.submit(command, _submit_tick_provider.call())


## The execution side of a place click: CommandExecutor.execute()
## (scripts/match/command_executor.gd) calls this with the
## SimPlaceBuildingCommand it just drained, on the tick the bus scheduled it
## for. Must not depend on the local placement preview being active: command
## execution evaluates and spawns through BuildingPlacement's view-less path,
## while the issuer's preview remains a local input concern.
##
## Verifies identity before doing anything else beyond clearing
## _committed_placement_cell (see the doc comment on the line that does it,
## just below): order.building_id must still match command.building_id, or
## this command is stale -- the order changed between the click and this tick
## -- and placing whatever happens to be ready now would hand the player a
## building they never chose. A stale command is discarded silently, the same
## treatment a dead entity id gets in CommandExecutor._execute_stop()'s
## identical reasoning.
##
## The two view-less calls intentionally preserve the old verdict priority:
## first evaluate terrain and occupancy, then report a missing scene only when
## that verdict is valid. Every local failure keeps its prior status string.
func execute_place_building_command(command: SimPlaceBuildingCommand) -> void:
	var is_local_command := command.player_id == _local_player_id()
	if is_local_command:
		_committed_placement_cell = null
	var queue = building_queue_for_player(command.player_id)
	var order := queue.current_order()
	if order == null or not order.ready:
		return
	if order.building_id != command.building_id:
		return

	var config := _building_config(order.building_id)
	var occupy_rows := _building_occupy_rows(config)
	if occupy_rows.is_empty():
		if is_local_command:
			status_changed.emit("%s has no occupy_rows" % order.display_name)
		return
	var is_wall := _is_wall_building_id(order.building_id)
	match _building_placement.place_without_preview(
		order.building_id, order.display_name, occupy_rows, is_wall,
		command.rotation_quarter_turns, command.nav_cell, null, command.player_id
	):
		BuildingPlacementScript.PlaceResult.NEEDS_TERRAIN:
			if is_local_command:
				status_changed.emit("%s placement needs terrain" % order.display_name)
			return
		BuildingPlacementScript.PlaceResult.CANNOT_BUILD:
			if is_local_command:
				status_changed.emit("%s cannot be placed there" % order.display_name)
			return
		BuildingPlacementScript.PlaceResult.INACTIVE:
			if is_local_command:
				status_changed.emit("%s has no occupy_rows" % order.display_name)
			return
	var scene_path := _building_scene_path(order.building_id)
	if not ResourceLoader.exists(scene_path):
		if is_local_command:
			status_changed.emit(
				"%s placement valid; missing scene %s" % [order.display_name, scene_path]
			)
		return
	var scene := load(scene_path) as PackedScene
	match _building_placement.place_without_preview(
		order.building_id,
		order.display_name,
		occupy_rows,
		_is_wall_building_id(order.building_id),
		command.rotation_quarter_turns,
		command.nav_cell,
		scene,
		command.player_id
	):
		BuildingPlacementScript.PlaceResult.NEEDS_TERRAIN:
			if is_local_command:
				status_changed.emit("%s placement needs terrain" % order.display_name)
			return
		BuildingPlacementScript.PlaceResult.CANNOT_BUILD:
			if is_local_command:
				status_changed.emit("%s cannot be placed there" % order.display_name)
			return
		BuildingPlacementScript.PlaceResult.INACTIVE:
			return
		BuildingPlacementScript.PlaceResult.PLACED:
			queue.take_ready()
			if is_local_command:
				_building_placement.cancel()
				status_changed.emit("%s placed" % order.display_name)
				_refresh_building_option_states()
		BuildingPlacementScript.PlaceResult.INVALID_SCENE:
			if is_local_command:
				status_changed.emit("%s scene is not a Node3D" % order.display_name)
		BuildingPlacementScript.PlaceResult.MISSING_BUILDINGS_ROOT:
			if is_local_command:
				status_changed.emit("Buildings root is missing")


## Mirrors _submit_place_building_command()'s shape exactly, including its
## push_error when no command bus is wired in -- see that method's doc comment
## and the _command_bus field comment for why a missing bus is a wiring
## mistake, not a supported mode.
func _submit_wall_line_command(
		start_cell: Vector2i, end_cell: Vector2i, building_id: StringName
	) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"BuildingController._submit_wall_line_command(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_building_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
		return
	var command := SimWallLineCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.building_id = building_id
	command.start_cell = start_cell
	command.end_cell = end_cell
	_command_bus.submit(command, _submit_tick_provider.call())


## The execution side of the wall line's second click: CommandExecutor.execute()
## (scripts/match/command_executor.gd) calls this with the SimWallLineCommand
## it just drained, on the tick the bus scheduled it for. ProductionSystem
## recomputes the buildable-cell set, owns the player-keyed chain and orders
## its first segment; this controller renders only the matching local outcome.
func execute_wall_line_command(command: SimWallLineCommand) -> void:
	_production_system.execute_wall_line(
		command.player_id, command.start_cell, command.end_cell, command.building_id
	)


func _cancel_building_placement() -> void:
	_reset_placement_pointer_action()
	if not _building_placement.is_active():
		return
	var display_name := _building_placement.cancel()
	status_changed.emit("%s placement canceled" % display_name)
	_refresh_building_option_states()
	interaction_mode_changed.emit(false)


func _play_building_state(building: Node3D, state: StringName) -> void:
	AuthoredModelScript.play_state(building, state)


func _building_occupy_rows(config: Resource) -> Array[String]:
	var rows: Array[String] = []
	if config == null:
		return rows

	for row in config.occupy_rows:
		var row_text := String(row)
		if not row_text.is_empty():
			rows.append(row_text)
	return rows


func _occupy_rows_for_existing_building(building: Node3D) -> Array[String]:
	return _building_occupy_rows(_config_of(building))


func _is_wall_building(building: Node3D) -> bool:
	return _is_wall_config(_config_of(building))


func _is_wall_building_id(building_id: StringName) -> bool:
	return _is_wall_config(_building_config(building_id))


func _is_wall_config(config: Resource) -> bool:
	return config != null and String(config.building_group_id) == WALL_BUILDING_GROUP


func _build_radius_tiles() -> int:
	var settings := _game_settings_catalog.settings()
	return settings.max_building_placement_tile_dist if settings != null else DEFAULT_BUILD_RADIUS_TILES


func _building_config(building_id: StringName) -> Resource:
	return _catalog_view.config(building_id)


func _config_of(building: Node) -> Resource:
	return _catalog_view.config_of(building)


func _building_scene_path(building_id: StringName) -> String:
	return _catalog_view.scene_path(building_id)


func _building_model_name(building_id: StringName) -> String:
	return _catalog_view.model_name(building_id)


func _is_building_available(building_id: StringName) -> bool:
	return _catalog_view.is_available_for(_local_player_id(), building_id)


## _is_building_available() reads _catalog_view's cache, which is only ever
## as fresh as the last _refresh_availability_if_dirty() call -- but this
## function is invoked from about a dozen call sites (selling, canceling an
## order, the wall session's _refresh callback, slot handlers...), not just
## setup()/process(), so without this it could read a stale cache on any of
## those paths. Re-entrancy guard: _refresh_availability_if_dirty() itself
## calls back into this function when the cache actually changed, and
## without the guard that nested call would run the full emit loop below on
## already-fresh data, then fall through to run it again unnecessarily here.
func _refresh_building_option_states() -> void:
	if _refreshing_building_option_states:
		return
	_refreshing_building_option_states = true
	_refresh_availability_if_dirty()
	var order := _building_queue.current_order()
	for building_id in _catalog_view.ids():
		var tooltip := _building_tooltip(building_id)

		if _is_wall_building_id(building_id) and _wall_line_mode and _wall_line_building_id == building_id:
			var picking_status := "Pick line end" if _wall_line_start_cell != null else "Pick line start"
			building_option_state_changed.emit(BuildingOptionStateScript.new(
				building_id, BuildingOptionStateScript.State.PROGRESS, 0.0, picking_status, tooltip
			))
			continue

		if order == null:
			var state := BuildingOptionStateScript.availability_state(
				_is_building_available(building_id), false
			)
			building_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))
			continue

		if order.building_id != building_id:
			var state := BuildingOptionStateScript.availability_state(
				_is_building_available(building_id), true
			)
			building_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))
			continue

		if order.ready:
			var ready_status_text := "PLACE" if _building_placement.is_active() else "READY"
			building_option_state_changed.emit(BuildingOptionStateScript.new(
				building_id, BuildingOptionStateScript.State.READY, 100.0, ready_status_text, tooltip
			))
			continue

		var status_text := ""
		if order.manually_paused:
			status_text = "PAUSED"
		building_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id,
			BuildingOptionStateScript.State.PROGRESS,
			order.progress_percent(),
			status_text,
			tooltip
		))
	_refreshing_building_option_states = false


func _building_display_name(building_id: StringName) -> String:
	return _catalog_view.display_name(building_id)


func _building_tooltip(building_id: StringName) -> String:
	return _catalog_view.tooltip(building_id)


## Default mask covers terrain (bit 1) and units/buildings (bit 2) only —
## corpses sit on their own bit 3 (see DeathCorpse) and must never block a
## click aimed at a unit/building standing behind one. Every current caller
## already passes an explicit mask; this default only guards future ones.
func _raycast(screen_position: Vector2, collision_mask: int = 3) -> Dictionary:
	if camera == null:
		return {}

	return TerrainProbeScript.screen_pick(camera, get_world_3d(), screen_position, collision_mask)


func _players():
	return AutoloadLookupScript.roster(self)


func _local_player() -> PlayerData:
	var players = _players()
	if players == null:
		return null
	return players.local_player() as PlayerData


## The roster's local player id, or null when there is no roster. Deliberately
## not _local_player_id(): that answers -1 for "nobody", while placement reads
## owner_player_id == null as "leave this building unowned", and -1 would be
## taken for a real player id.
func _local_owner_player_id():
	var players = _players()
	return players.local_player_id if players != null else null


func _local_player_id() -> int:
	var player := _local_player()
	return player.player_id if player != null else -1
