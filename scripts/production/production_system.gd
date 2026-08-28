class_name ProductionSystem
extends RefCounted

const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")
const WallChainScript := preload("res://scripts/buildings/wall_chain.gd")
const WallLineScript := preload("res://scripts/buildings/wall_line.gd")

signal build_order_ready(player_id: int, order)
signal build_order_canceled(player_id: int, order, refunded: int)
signal wall_chain_execution(player_id: int, execution: WallChainExecution)


enum WallChainOutcome {
	STARTED, BUSY, RULES, NO_BUILDABLE, EVALUATION_FAILED, SKIPPED,
	FINAL_SKIPPED, QUEUE_FAILED, ORDERED, MISSING_ROWS, MISSING_SCENE,
	PLACEMENT_FAILED, PLACED, COMPLETE, ENDED,
}


class WallChainExecution extends RefCounted:
	var kind: WallChainOutcome = WallChainOutcome.ENDED
	var display_name := ""
	var segment_index := 0
	var segment_count := 0
	var scene_path := ""
	var cells: Array[Vector2i] = []


class PlayerProduction extends RefCounted:
	var build_queue: BuildingQueue = BuildingQueueScript.new()
	var wall_chain: WallChain


var _players
var _is_building_available: Callable
var _by_player_id: Dictionary = {}
var _wall_placement
var _wall_config_provider: Callable
var _wall_rows_provider: Callable
var _wall_display_provider: Callable
var _wall_scene_provider: Callable


func configure(players, is_building_available: Callable) -> void:
	_players = players
	_is_building_available = is_building_available


## BuildingController supplies the shared world-facing placement primitives.
## This system keeps their results and every queue/credit mutation keyed by the
## command's player id; the controller only renders local outcomes.
func configure_wall_chains(
		placement, config_provider: Callable, rows_provider: Callable,
		display_provider: Callable, scene_provider: Callable
	) -> void:
	_wall_placement = placement
	_wall_config_provider = config_provider
	_wall_rows_provider = rows_provider
	_wall_display_provider = display_provider
	_wall_scene_provider = scene_provider


func build_queue_for_player(player_id: int) -> BuildingQueue:
	return _production_for(player_id).build_queue


func wall_chain_for_player(player_id: int) -> WallChain:
	return _production_for(player_id).wall_chain


## Test seam for wall-chain state. Shipping code starts chains through
## execute_wall_line(); it never installs an already-evaluated chain.
func set_wall_chain_for_player(player_id: int, chain: WallChain) -> void:
	_production_for(player_id).wall_chain = chain


func execute_wall_line(
		player_id: int, from_nav_cell: Vector2i, to_nav_cell: Vector2i, building_id: StringName
	) -> void:
	var production := _production_for(player_id)
	var queue := production.build_queue
	if production.wall_chain != null or queue.has_order():
		_emit_wall(player_id, WallChainOutcome.BUSY)
		return
	if String(building_id).is_empty():
		building_id = &"ATWall"
	var config: Resource = _wall_config_provider.call(building_id)
	if config == null:
		_emit_wall(player_id, WallChainOutcome.RULES)
		return
	var display_name: String = _wall_display_provider.call(building_id)
	var cells: Array[Vector2i] = []
	for cell in _wall_nav_cells_between(from_nav_cell, to_nav_cell):
		var availability := _evaluate_wall_cell(building_id, cell, player_id)
		if availability == BuildingPlacementScript.PlaceResult.AVAILABLE:
			cells.append(cell)
	if cells.is_empty():
		_emit_wall(player_id, WallChainOutcome.NO_BUILDABLE, display_name)
		_end_wall_chain(player_id)
		return
	production.wall_chain = WallChainScript.new(
		building_id, display_name, maxi(config.cost, 0),
		RuleTicksScript.order_sim_ticks(config.build_time_ticks), cells, player_id
	)
	_emit_wall(player_id, WallChainOutcome.STARTED, display_name, 0, 0, "", cells)
	advance_wall_chain(player_id)


func advance_wall_chain(player_id: int) -> void:
	var production := _production_for(player_id)
	var chain := production.wall_chain
	while chain != null:
		var availability := _evaluate_wall_cell(chain.building_id, chain.current_cell(), player_id)
		if availability == BuildingPlacementScript.PlaceResult.AVAILABLE:
			break
		if availability != BuildingPlacementScript.PlaceResult.CANNOT_BUILD:
			_emit_wall(player_id, WallChainOutcome.EVALUATION_FAILED, chain.display_name)
			_end_wall_chain(player_id)
			return
		var skipped_index: int = chain.segment_index()
		if not chain.advance():
			_emit_wall(player_id, WallChainOutcome.FINAL_SKIPPED, chain.display_name, skipped_index, chain.segment_count())
			_end_wall_chain(player_id)
			return
		_emit_wall(player_id, WallChainOutcome.SKIPPED, chain.display_name, skipped_index, chain.segment_count())
		chain = production.wall_chain
	if chain == null:
		return
	if not production.build_queue.start(chain.building_id, chain.display_name, chain.cost, chain.build_time_ticks):
		_emit_wall(player_id, WallChainOutcome.QUEUE_FAILED, chain.display_name)
		_end_wall_chain(player_id)
		return
	_emit_wall(player_id, WallChainOutcome.ORDERED, chain.display_name, chain.segment_index(), chain.segment_count())


func cancel_wall_chain(player_id: int) -> void:
	_end_wall_chain(player_id)


func refund_wall_order(player_id: int, order) -> void:
	_refund_wall_order(player_id, order)


func advance_tick() -> void:
	if _players == null:
		return
	for player_id in _players.player_ids():
		var production := _production_for(player_id)
		var queue := production.build_queue
		var order := queue.current_order()
		if order == null:
			continue
		var player = _players.player(player_id)
		if player == null:
			continue
		if not order.ready and (not _is_building_available.is_valid() \
		or not _is_building_available.call(player_id, order.building_id)):
			var refunded := queue.cancel()
			if refunded > 0:
				player.add_money(refunded)
			if production.wall_chain != null:
				_end_wall_chain(player_id)
			build_order_canceled.emit(player_id, order, refunded)
			continue
		queue.advance_tick(player.money, Callable(player, &"spend_money"))


func _production_for(player_id: int) -> PlayerProduction:
	if _by_player_id.has(player_id):
		return _by_player_id[player_id] as PlayerProduction
	var production := PlayerProduction.new()
	production.build_queue.order_ready.connect(_on_build_order_ready.bind(player_id))
	_by_player_id[player_id] = production
	return production


func _on_build_order_ready(order, player_id: int) -> void:
	if _production_for(player_id).wall_chain != null:
		_place_ready_wall_segment(player_id)
		return
	build_order_ready.emit(player_id, order)


func _place_ready_wall_segment(player_id: int) -> void:
	var production := _production_for(player_id)
	var chain := production.wall_chain
	if chain == null:
		return
	var completed_order := production.build_queue.take_ready()
	var config: Resource = _wall_config_provider.call(chain.building_id)
	var rows: Array[String] = _wall_rows_provider.call(config)
	if rows.is_empty():
		_refund_wall_order(player_id, completed_order)
		_emit_wall(player_id, WallChainOutcome.MISSING_ROWS, chain.display_name)
		_end_wall_chain(player_id)
		return
	var scene_path: String = _wall_scene_provider.call(chain.building_id)
	if not ResourceLoader.exists(scene_path):
		_refund_wall_order(player_id, completed_order)
		_emit_wall(player_id, WallChainOutcome.MISSING_SCENE, chain.display_name, 0, 0, scene_path)
		_end_wall_chain(player_id)
		return
	var scene := load(scene_path) as PackedScene
	# WallChain predates player-keyed storage and permits a null owner. Once the
	# chain is in PlayerProduction, the dictionary key is its sole authority.
	var owner_player_id: int = player_id
	var placed: int = _wall_placement.place_without_preview(
		chain.building_id, chain.display_name, rows, true, 0, chain.current_cell(), scene,
		owner_player_id
	)
	if placed == BuildingPlacementScript.PlaceResult.CANNOT_BUILD:
		_refund_wall_order(player_id, completed_order)
		var skipped_index: int = chain.segment_index()
		if chain.advance():
			_emit_wall(player_id, WallChainOutcome.SKIPPED, chain.display_name, skipped_index, chain.segment_count())
			advance_wall_chain(player_id)
		else:
			_emit_wall(player_id, WallChainOutcome.FINAL_SKIPPED, chain.display_name)
			_end_wall_chain(player_id)
		return
	if placed != BuildingPlacementScript.PlaceResult.PLACED:
		_refund_wall_order(player_id, completed_order)
		_emit_wall(player_id, WallChainOutcome.PLACEMENT_FAILED, chain.display_name)
		_end_wall_chain(player_id)
		return
	var placed_index: int = chain.segment_index()
	if chain.advance():
		_emit_wall(player_id, WallChainOutcome.PLACED, chain.display_name, placed_index, chain.segment_count())
		advance_wall_chain(player_id)
	else:
		_emit_wall(player_id, WallChainOutcome.COMPLETE, chain.display_name)
		_end_wall_chain(player_id)


func _evaluate_wall_cell(building_id: StringName, cell: Vector2i, player_id: int) -> int:
	var config: Resource = _wall_config_provider.call(building_id)
	var rows: Array[String] = _wall_rows_provider.call(config)
	return _wall_placement.evaluate_without_preview(building_id, rows, true, 0, cell, player_id)


func _wall_nav_cells_between(from_nav_cell: Vector2i, to_nav_cell: Vector2i) -> Array[Vector2i]:
	var span := BuildingPlacementScript.NAV_CELLS_PER_OCCUPY_CELL
	var from_occupy := Vector2i(int(floor(float(from_nav_cell.x) / float(span))), int(floor(float(from_nav_cell.y) / float(span))))
	var to_occupy := Vector2i(int(floor(float(to_nav_cell.x) / float(span))), int(floor(float(to_nav_cell.y) / float(span))))
	var occupy_cells := WallLineScript.occupy_cells_between(from_occupy, to_occupy)
	var nav_cells: Array[Vector2i] = []
	for occupy_cell in occupy_cells:
		nav_cells.append(occupy_cell * span)
	return nav_cells


func _refund_wall_order(player_id: int, order) -> void:
	if order == null or order.paid_cost <= 0:
		return
	var player = _players.player(player_id) if _players != null else null
	if player != null:
		player.add_money(order.paid_cost)


func _end_wall_chain(player_id: int) -> void:
	_production_for(player_id).wall_chain = null
	_emit_wall(player_id, WallChainOutcome.ENDED)


func _emit_wall(
		player_id: int, kind: WallChainOutcome, display_name: String = "",
		segment_index: int = 0, segment_count: int = 0, scene_path: String = "",
		cells: Array[Vector2i] = []
	) -> void:
	var execution := WallChainExecution.new()
	execution.kind = kind
	execution.display_name = display_name
	execution.segment_index = segment_index
	execution.segment_count = segment_count
	execution.scene_path = scene_path
	execution.cells = cells
	wall_chain_execution.emit(player_id, execution)
