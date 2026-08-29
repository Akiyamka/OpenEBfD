class_name BuildingUpgradeController
extends Node3D

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const SimUpgradeOrderCommandScript := preload("res://scripts/sim/commands/upgrade_order_command.gd")
const UpgradeOrderScript := preload("res://scripts/buildings/upgrade_order.gd")
const UpgradeProductionSystemScript := preload("res://scripts/production/upgrade_production_system.gd")
const UpgradeRulesScript := preload("res://scripts/buildings/upgrade_rules.gd")

## docs/mechanics/production.md section 4 "Upgrades" sidebar half. The
## UpgradeProductionSystem owns player-keyed queues and all authoritative
## world/credit mutations; this controller renders one local sidebar and
## translates its input to commands.
##
## Two upgrade shapes share the system queue (docs section 4 "binding"):
## GLOBAL_TYPE purchases player state and applies it to owned buildings;
## REFINERY_DOCK advances one automatically selected owned refinery.

signal status_changed(status: String)
signal upgrade_option_state_changed(option_state: BuildingOptionState)

var _building_configs: Dictionary = {}
## D5: this remains the local sidebar's upgrade list. Remote players may use
## other house-specific ids, but the input panel deliberately renders only it.
var _upgrade_option_ids: Array[StringName] = []
var _upgrade_availability: Dictionary = {}
var _upgrade_production_system: UpgradeProductionSystem
static var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()
## Command-bus collaborators are injected together by Match. A missing system
## is a wiring error, not a fallback path for fixtures.
var _command_bus: SimCommandBus
var _submit_tick_provider: Callable


func setup(
		building_ids: Array[StringName],
		upgrade_production_system: UpgradeProductionSystem,
		command_bus: SimCommandBus = null,
		submit_tick_provider: Callable = Callable()
	) -> void:
	_upgrade_production_system = upgrade_production_system
	_command_bus = command_bus
	_submit_tick_provider = submit_tick_provider
	_upgrade_production_system.upgrade_order_execution.connect(_on_upgrade_order_execution)
	_upgrade_production_system.upgrade_queue_progressed.connect(_on_upgrade_queue_progressed)
	_load_building_configs(building_ids)
	_refresh_upgrade_option_states()


func upgrade_option_ids() -> Array[StringName]:
	return _upgrade_option_ids.duplicate()


## Availability cache is a local, view-only frame poll, deliberately
## unconditional. Gating it on BuildingAvailabilityTracker was tried and
## abandoned: the tracker dirties on the immediate "buildings" join while the
## verdict below reads sim_buildings, which the admission queue fills a tick
## later (building.gd's _ready() comment), so a poll that consumed the flag
## inside that window would never retry. See the D4a entry in
## docs/architecture/network-multiplayer.md.
func process(_delta: float) -> void:
	_poll_upgrade_availability()


func handle_command(_command: StringName) -> bool:
	return false


func handle_unhandled_input(_event: InputEvent) -> bool:
	return false


func handle_upgrade_intent(building_id: StringName, button_index: int) -> bool:
	if not _upgrade_option_ids.has(building_id):
		return false
	if button_index != MOUSE_BUTTON_LEFT and button_index != MOUSE_BUTTON_RIGHT:
		return false
	_submit_upgrade_order_command(building_id, button_index)
	return true


func _submit_upgrade_order_command(building_id: StringName, button_index: int) -> void:
	if _command_bus == null or not _submit_tick_provider.is_valid():
		push_error(
			"BuildingUpgradeController._submit_upgrade_order_command(): no command bus wired in -- " +
			"call setup() with a SimCommandBus and a submit-tick provider before issuing orders."
		)
		return
	var command := SimUpgradeOrderCommandScript.new()
	var players = _players()
	if players != null:
		command.player_id = players.local_player_id
	command.upgrade_id = building_id
	command.button_index = button_index
	_command_bus.submit(command, _submit_tick_provider.call())


## The command executor calls this on the scheduled tick. The system, not the
## local sidebar, recomputes the live verdict for command.player_id.
func execute_upgrade_order_command(command: SimUpgradeOrderCommand) -> void:
	_upgrade_production_system.execute_upgrade_order(
		command.player_id, command.upgrade_id, command.button_index
	)


func _poll_upgrade_availability() -> void:
	var player := _local_player()
	var player_id := player.player_id if player != null else -1
	var changed := false
	for building_id in _upgrade_option_ids:
		var available := (
			_upgrade_production_system.can_any_refinery_add_dock_for(player_id, building_id)
			if UpgradeRulesScript.is_refinery_dock_id(building_id)
			else _upgrade_production_system.is_upgrade_available_for(player_id, building_id)
		)
		if available != _upgrade_availability.get(building_id, false):
			_upgrade_availability[building_id] = available
			changed = true
	if changed:
		_refresh_upgrade_option_states()


func _load_building_configs(building_ids: Array[StringName]) -> void:
	for building_id in building_ids:
		var config: Resource = _building_definition_catalog.definition(building_id)
		if config == null:
			continue
		_building_configs[building_id] = config
		if _has_upgrade_definition(config):
			_upgrade_option_ids.append(building_id)


func _has_upgrade_definition(config: Resource) -> bool:
	return config.upgrade_cost > 0 and config.upgrade_tech_level > 0


func _refresh_upgrade_option_states() -> void:
	var player := _local_player()
	var player_id := player.player_id if player != null else -1
	var order := _upgrade_production_system.current_order_for_player(player_id)
	for building_id in _upgrade_option_ids:
		var tooltip := _upgrade_tooltip(building_id)
		if UpgradeRulesScript.is_refinery_dock_id(building_id):
			_emit_dock_option_state(player_id, building_id, order, tooltip)
			continue
		if player != null and player.has_purchased_upgrade(building_id):
			upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
				building_id, BuildingOptionStateScript.State.DISABLED, 0.0, "", tooltip
			))
			continue
		if order == null or order.kind != UpgradeOrderScript.Kind.GLOBAL_TYPE or order.upgrade_id != building_id:
			var available := _upgrade_production_system.is_upgrade_available_for(player_id, building_id)
			var state := BuildingOptionStateScript.availability_state(available, order != null)
			upgrade_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))
			continue
		var status_text := "PAUSED" if order.manually_paused else ""
		upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id, BuildingOptionStateScript.State.PROGRESS, order.progress_percent(), status_text, tooltip
		))


func _emit_dock_option_state(
		player_id: int, building_id: StringName, order: UpgradeOrder, tooltip: String
	) -> void:
	if order != null and order.kind == UpgradeOrderScript.Kind.REFINERY_DOCK and order.upgrade_id == building_id:
		var status_text := "PAUSED" if order.manually_paused else ""
		upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id, BuildingOptionStateScript.State.PROGRESS, order.progress_percent(), status_text, tooltip
		))
		return
	var available := _upgrade_production_system.can_any_refinery_add_dock_for(player_id, building_id)
	var state := BuildingOptionStateScript.availability_state(available, order != null)
	upgrade_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))


func _on_upgrade_order_execution(
		player_id: int, execution: UpgradeProductionSystem.UpgradeOrderExecution
	) -> void:
	var player := _local_player()
	if player == null or player.player_id != player_id:
		return
	match execution.kind:
		UpgradeProductionSystem.UpgradeOrderOutcome.QUEUE_BUSY:
			status_changed.emit("Upgrade queue is busy")
		UpgradeProductionSystem.UpgradeOrderOutcome.DOCK_MAXIMUM:
			status_changed.emit("This refinery already has the maximum number of docks")
		UpgradeProductionSystem.UpgradeOrderOutcome.DOCK_RULES_MISSING:
			status_changed.emit("Refinery dock rules are not loaded")
		UpgradeProductionSystem.UpgradeOrderOutcome.DOCK_QUEUE_FAILED:
			status_changed.emit("Refinery dock could not be queued")
		UpgradeProductionSystem.UpgradeOrderOutcome.ORDERED:
			status_changed.emit("%s ordered" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.PAUSED:
			status_changed.emit("%s upgrade paused" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.NO_REFINERY:
			status_changed.emit("No refinery can receive this upgrade")
		UpgradeProductionSystem.UpgradeOrderOutcome.RESUMED:
			status_changed.emit("%s upgrade resumed" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.WAITING_CREDITS:
			status_changed.emit("%s upgrade is waiting for credits" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.ALREADY_RUNNING:
			status_changed.emit("%s upgrade is already running" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.GLOBAL_RULES_MISSING:
			status_changed.emit("Upgrade rules are not loaded")
		UpgradeProductionSystem.UpgradeOrderOutcome.NOT_AVAILABLE:
			status_changed.emit("%s upgrade is not available" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.CANCELED:
			status_changed.emit("%s canceled; refunded %d" % [execution.display_name, execution.refunded])
		UpgradeProductionSystem.UpgradeOrderOutcome.UPGRADED:
			status_changed.emit("%s upgraded" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.LOST_REFINERY:
			status_changed.emit("%s lost its refinery before it could be completed" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.DOCK_CANNOT_RECEIVE:
			status_changed.emit("%s refinery can no longer receive this upgrade" % execution.display_name)
		UpgradeProductionSystem.UpgradeOrderOutcome.COMPLETED:
			status_changed.emit("%s completed" % execution.display_name)
	_refresh_upgrade_option_states()


func _on_upgrade_queue_progressed(player_id: int) -> void:
	var player := _local_player()
	if player != null and player.player_id == player_id:
		_refresh_upgrade_option_states()


func _upgrade_tooltip(building_id: StringName) -> String:
	var config: Resource = _building_configs.get(building_id)
	if config == null:
		return UpgradeRulesScript.display_name(building_id)
	var cost: int = int(config.upgrade_cost)
	var sim_ticks := UpgradeRulesScript.build_time_sim_ticks(
		config, UpgradeRulesScript.is_refinery_dock_id(building_id)
	)
	var build_seconds := float(sim_ticks) * MatchClockScript.SECONDS_PER_TICK
	return "%s\nCost: %d\nBuild: %.1fs" % [UpgradeRulesScript.display_name(building_id), cost, build_seconds]


## The remaining player lookup is view-only: input identity, availability
## polling, option states and status text belong to the local sidebar.
func _players():
	return AutoloadLookupScript.roster(self)


func _local_player() -> PlayerData:
	var players = _players()
	if players == null:
		return null
	return players.local_player() as PlayerData
