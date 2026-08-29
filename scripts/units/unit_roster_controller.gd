class_name UnitRosterController
extends Node

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")
const SimUnitOrderCommandScript := preload("res://scripts/sim/commands/unit_order_command.gd")
const UnitProductionSystemScript := preload("res://scripts/production/unit_production_system.gd")

## docs/mechanics/production.md section 3 "unit production": the roster half
## only. The Infantry/Vehicles panel tabs list the units the technology tree
## currently unlocks -- primary production building owned, its upgrade
## purchased when the unit demands one (upgraded_primary_required), and the
## map tech level cap -- all via the same TechnologyTree.is_available() the
## building grid uses. UnitProductionSystem owns player-keyed queues and the
## world-facing producer/spawn decisions; this controller renders one sidebar.

signal status_changed(status: String)
signal unit_option_state_changed(option_state: BuildingOptionState)

const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const BuildingQueueScript := preload("res://scripts/buildings/building_queue.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")
const BuildingAvailabilityTrackerScript := preload(
	"res://scripts/buildings/building_availability_tracker.gd"
)

## Same extension point as BuildingController.max_tech_level -- a future
## map/mission tech-level cap (see TechnologyTree.UNLIMITED_TECH_LEVEL).
var max_tech_level: int = TechnologyTreeScript.UNLIMITED_TECH_LEVEL
## The command bus handle_unit_intent() submits SimUnitOrderCommands to, and a
## matching way to ask "what tick would a command submitted right now
## target" -- injected together by setup(), in production by Match.
## _setup_unit_roster_controller() and in tests by
## tests/match/support/command_pump.gd, the same way UnitCommandController's
## are (see that class's own _command_bus field comment). Unlike
## BuildingController, every left/right click on a unit slot needs one -- see
## handle_unit_intent()'s doc comment for why there is no local interaction-
## mode branch to peel off first.
var _command_bus: SimCommandBus
var _submit_tick_provider: Callable

## This remains the local sidebar's unit list. Availability is cached for every
## player from the same full producible-unit candidate set, so remote orders do
## not depend on which house's sidebar happens to be rendered.
var _unit_ids: Array[StringName] = []
var _unit_definitions: Dictionary = {}
var _technology_tree: TechnologyTree = TechnologyTreeScript.new()
## Cached per-player/per-id availability, refreshed only when the tracker
## reports that something the technology tree reads has changed.
var _unit_availability: Dictionary = {}
var _availability_tracker := BuildingAvailabilityTrackerScript.new()
var _unit_production_system: UnitProductionSystem
static var _unit_scene_catalog := UnitSceneCatalogScript.shared()


func setup(
		unit_ids: Array[StringName],
		unit_production_system: UnitProductionSystem,
		command_bus: SimCommandBus = null,
		submit_tick_provider: Callable = Callable()
) -> void:
	_unit_ids = unit_ids.duplicate()
	_unit_production_system = unit_production_system
	_command_bus = command_bus
	_submit_tick_provider = submit_tick_provider
	_unit_production_system.unit_order_execution.connect(_on_unit_order_execution)
	_unit_production_system.unit_queue_progressed.connect(_on_unit_queue_progressed)
	_load_unit_definitions()
	_availability_tracker.bind(self)
	_refresh_availability_if_dirty()
	_refresh_unit_option_states()


func _exit_tree() -> void:
	_availability_tracker.unbind()


## Kept because Match calls controller process methods unconditionally. Match
## refreshes availability after admission and before command execution instead
## of making this frame callback determine a simulation verdict.
func process(_delta: float) -> void:
	pass


## Match calls this after entity admission and before command execution, so
## availability readers in that tick share the same settled snapshot.
func refresh_availability() -> void:
	if _refresh_availability_if_dirty():
		_refresh_unit_option_states()


## Unit availability depends on which buildings the player owns and whether they
## are upgraded, both of which change as buildings are placed, upgraded, sold or
## lost elsewhere on the map. It used to be re-derived every frame, which meant
## an O(unit ids x buildings) TechnologyTree scan per frame -- 3 ms of the frame
## once a base was standing, the single largest cost in it. The tracker reports
## when any of those facts actually changed; between changes the cache below
## answers.
##
## Same out-of-tree rule as BuildingController._refresh_availability_if_dirty():
## outside the tree nothing is available, and that is recomputed unconditionally
## rather than gated on the flag, so a stale cached "true" cannot outlive the
## controller's own teardown.
func _refresh_availability_if_dirty() -> bool:
	if not is_inside_tree():
		var no_buildings: Array[Node] = []
		var changed := false
		for player_id in _unit_availability.keys():
			changed = _recompute_availability(int(player_id), null, no_buildings) or changed
		return changed
	if not _availability_tracker.consume_dirty():
		return false
	var players = AutoloadLookupScript.roster(self)
	if players == null:
		return false
	var local_player = _sidebar_player()
	var local_changed := false
	var buildings := _availability_tracker.buildings()
	for player_id in players.player_ids():
		var changed := _recompute_availability(player_id, players.player(player_id), buildings)
		if local_player != null and player_id == local_player.player_id:
			local_changed = changed
	return local_changed


## One buildings array for the whole roster, not one per unit id -- rebuilding
## it per id is what made the scan quadratic.
func _recompute_availability(player_id: int, player, buildings: Array[Node]) -> bool:
	if not _unit_availability.has(player_id):
		_unit_availability[player_id] = {}
	var availability: Dictionary = _unit_availability[player_id]
	var changed := false
	for unit_id in _unit_ids:
		var config: Resource = _unit_definitions.get(unit_id)
		var available: bool = config != null and player != null \
			and _technology_tree.is_available(config, player, buildings, max_tech_level)
		if available == availability.get(unit_id, false):
			continue
		availability[unit_id] = available
		changed = true
	return changed


## The command-bus seam for the sidebar's unit slots (see
## docs/architecture/network-multiplayer.md, "Layering" -- "commands" vs
## "simulation"). Unlike BuildingController's build order, no click here ever
## opens an interaction mode of its own -- a finished unit order just spawns,
## with no placement step to preview -- so every left/right click on a unit
## slot becomes a SimUnitOrderCommand; execute_unit_order_command() forwards
## it to UnitProductionSystem, which recomputes the mutation against the queue
## as it stands on the tick the bus schedules it for. See SimUnitOrderCommand's
## doc comment.
func handle_unit_intent(unit_id: StringName, button_index: int, quantity := 1) -> bool:
	if not _unit_ids.has(unit_id):
		return false
	if button_index == MOUSE_BUTTON_LEFT or button_index == MOUSE_BUTTON_RIGHT:
		_submit_unit_order_command(unit_id, button_index, quantity)
	return true


## The issue side of a unit-order click: immediate, and split from execution
## on purpose, exactly as every other command (see SimUnitOrderCommand's doc
## comment). A controller with no command bus wired in is a wiring mistake,
## not a supported mode -- see the _command_bus field comment.
func _submit_unit_order_command(unit_id: StringName, button_index: int, quantity: int) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"UnitRosterController._submit_unit_order_command(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing " +
			"orders (see Match._setup_unit_roster_controller() or, in tests, " +
			"tests/match/support/command_pump.gd)."
		)
		return
	var command := SimUnitOrderCommandScript.new()
	var players = AutoloadLookupScript.roster(self)
	if players != null:
		command.player_id = players.local_player_id
	command.unit_id = unit_id
	command.button_index = button_index
	command.quantity = quantity
	_command_bus.submit(command, _submit_tick_provider.call())


## The execution side of a unit-order click: Match._advance_simulation_tick()
## calls this with the SimUnitOrderCommand it just drained, on the tick the
## bus scheduled it for.
func execute_unit_order_command(command: SimUnitOrderCommand) -> void:
	_unit_production_system.execute_unit_order(
		command.player_id, command.unit_id, command.button_index, command.quantity
	)


## Specialized units keep their own script/scene lifecycle while remaining
## compatible with the Unit production and navigation contracts.
func _scene_for_unit(unit_id: StringName) -> PackedScene:
	# Kept as a small compatibility seam for tests and callers that only need
	# the PackedScene. Actual production uses catalog.instantiate(), which also
	# configures the visual for the generic fallback path.
	return _unit_scene_catalog.scene_for(unit_id, UnitScene)


func _load_unit_definitions() -> void:
	for unit_id in _unit_ids:
		var config: Resource = _unit_scene_catalog.definition_for(unit_id)
		if config == null:
			push_warning("Unit definition not found: %s" % String(unit_id))
			continue
		_unit_definitions[unit_id] = config


## Reads the cache _refresh_availability_if_dirty() maintains, the same way the
## building grid reads BuildingCatalogView.is_available(). Deliberately not a
## live recompute: this is called once per configured id per option-state
## refresh, on top of every unit intent.
func _is_unit_available(unit_id: StringName) -> bool:
	var player := _sidebar_player()
	return is_unit_available_for(player.player_id if player != null else -1, unit_id)


func is_unit_available_for(player_id: int, unit_id: StringName) -> bool:
	return bool((_unit_availability.get(player_id, {}) as Dictionary).get(unit_id, false))


func _refresh_unit_option_states() -> void:
	for unit_id in _unit_ids:
		var state := BuildingOptionStateScript.State.DISABLED
		var progress := 0.0
		var status_text := ""
		var queue_quantity := 0
		if _is_unit_available(unit_id):
			state = BuildingOptionStateScript.State.AVAILABLE
			var player := _sidebar_player()
			var player_id := player.player_id if player != null else -1
			var production_building_id := _unit_production_system.production_building_id_for(player_id, unit_id)
			var queue := _unit_production_system.unit_queue_for_player(player_id, production_building_id)
			var order = queue.current_order()
			if order != null:
				var queued_count := _unit_production_system.queued_unit_count_for_player(
					player_id, production_building_id, unit_id
				)
				queue_quantity = queued_count
				if order.building_id == unit_id:
					state = BuildingOptionStateScript.State.READY if order.ready else BuildingOptionStateScript.State.PROGRESS
					progress = order.progress_percent()
					status_text = "PAUSED" if order.manually_paused else ""
				elif queued_count > 0:
					state = BuildingOptionStateScript.State.PROGRESS
				else:
					state = BuildingOptionStateScript.State.BLOCKED
		unit_option_state_changed.emit(BuildingOptionStateScript.new(
			unit_id, state, progress, status_text, _unit_tooltip(unit_id), queue_quantity
		))


func _on_unit_order_execution(player_id: int, execution: UnitProductionSystem.UnitOrderExecution) -> void:
	var player := _sidebar_player()
	if player == null or player.player_id != player_id:
		return
	match execution.kind:
		UnitProductionSystem.UnitOrderOutcome.NOT_AVAILABLE:
			status_changed.emit("%s is not available" % String(execution.unit_id))
		UnitProductionSystem.UnitOrderOutcome.NO_PRODUCTION_BUILDING:
			status_changed.emit("No production building is available for %s" % String(execution.unit_id))
		UnitProductionSystem.UnitOrderOutcome.RESUMED:
			status_changed.emit("%s production resumed" % execution.display_name)
		UnitProductionSystem.UnitOrderOutcome.QUEUE_FULL:
			status_changed.emit("%s production queue is full" % execution.production_building_id)
		UnitProductionSystem.UnitOrderOutcome.QUEUED:
			status_changed.emit("%s queued +%d (%d)" % [
				String(execution.unit_id), execution.count, execution.queue_size,
			])
		UnitProductionSystem.UnitOrderOutcome.REMOVED:
			status_changed.emit("%s removed from production queue x%d; refunded %d" % [
				String(execution.unit_id), execution.count, execution.refund,
			])
		UnitProductionSystem.UnitOrderOutcome.PAUSED:
			status_changed.emit("%s production paused" % execution.display_name)
		UnitProductionSystem.UnitOrderOutcome.COMPLETED:
			status_changed.emit("%s completed" % execution.display_name)
	_refresh_unit_option_states()


func _on_unit_queue_progressed(player_id: int) -> void:
	var player := _sidebar_player()
	if player != null and player.player_id == player_id:
		_refresh_unit_option_states()


func _unit_tooltip(unit_id: StringName) -> String:
	var config: Resource = _unit_definitions.get(unit_id)
	if config == null:
		return String(unit_id)

	var cost := int(config.cost)
	# Seconds from the actual simulation ticks the order will run for, not the
	# pre-conversion rules-domain ideal -- the duration the player really waits.
	var sim_ticks := RuleTicksScript.to_sim_ticks(config.build_time_ticks)
	var build_seconds := float(sim_ticks) * MatchClockScript.SECONDS_PER_TICK
	return "%s\nCost: %d\nBuild: %.1fs" % [String(unit_id), cost, build_seconds]


## The roster's remaining player lookup is view-only: option states and status
## text belong to the local sidebar, never to authoritative order execution.
func _sidebar_player() -> PlayerData:
	if not is_inside_tree():
		return null
	var players = AutoloadLookupScript.roster(self)
	if players == null:
		return null
	return players.local_player() as PlayerData
