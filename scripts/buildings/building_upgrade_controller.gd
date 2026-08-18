class_name BuildingUpgradeController
extends Node3D

const AutoloadLookupScript := preload("res://scripts/players/autoload_lookup.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

## docs/mechanics/production.md section 4 "Upgrades". Deliberately a sibling
## of BuildingController rather than more code stuffed into it: it owns a
## second, independent RefCounted queue (UpgradeQueue, "one per player" just
## like BuildingQueue but for a different kind of order).
##
## Two upgrade shapes share this one queue (docs section 4 "binding"):
## - GLOBAL_TYPE: any building config with upgrade_cost > 0. Purchase is
##   player state (PlayerData.grant_upgrade), applied to every currently
##   owned building of that type via UpgradeEffects and picked up by future
##   ones via Building._sync_purchased_upgrade(). Completes instantly, no
##   placement step -- there is nothing to place.
## - REFINERY_DOCK: instance-bound to an automatically selected owned Refinery.
##   Completion advances that refinery's built-in three-state dock model; it
##   never creates or places another Building node.

signal status_changed(status: String)
signal upgrade_option_state_changed(option_state: BuildingOptionState)
## TODO(§3 unit production / economy.md §2.3): a completed dock should spawn
## one harvester (no carryall, no replacement on loss) at the refinery. Unit
## spawning is out of scope here; this signal is the hook for that to attach
## to once it exists.
signal dock_completed(refinery: Node3D)

const UpgradeQueueScript := preload("res://scripts/buildings/upgrade_queue.gd")
const UpgradeOrderScript := preload("res://scripts/buildings/upgrade_order.gd")
const UpgradeEffectsScript := preload("res://scripts/buildings/upgrade_effects.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")
const UnitSceneCatalogScript := preload("res://scripts/units/unit_scene_catalog.gd")

const REFINERY_ROLE := "Refinery"
const DEFAULT_GLOBAL_UPGRADE_BUILD_TIME_TICKS := 60.0
## Rules.txt defines this separately for all three refinery docks, but the
## current generated rules database predates that column. Prefer the converted
## field once available and preserve the verified Rules value until then.
const DEFAULT_DOCK_UPGRADE_BUILD_TIME_TICKS := 720.0

var _building_configs: Dictionary = {}
var _upgrade_option_ids: Array[StringName] = []
var _upgrade_queue: UpgradeQueue = UpgradeQueueScript.new()
var _upgrade_availability: Dictionary = {}
static var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()
static var _unit_definition_catalog := UnitSceneCatalogScript.shared()


func setup(building_ids: Array[StringName]) -> void:
	if not _upgrade_queue.order_ready.is_connected(_on_upgrade_queue_ready):
		_upgrade_queue.order_ready.connect(_on_upgrade_queue_ready)

	_load_building_configs(building_ids)
	_refresh_upgrade_option_states()


## The subset of building_ids passed to setup() that actually has an upgrade
## defined (see _has_upgrade_definition()) -- callers must build their grid
## from this, not from the raw roster passed into setup(), or slots with no
## upgrade defined default to QueueSlot's normal AVAILABLE look since they
## never receive an upgrade_option_state_changed signal to override it.
func upgrade_option_ids() -> Array[StringName]:
	return _upgrade_option_ids.duplicate()


func process(_delta: float) -> void:
	_poll_upgrade_availability()


## Simulation half of the old process(delta): upgrade-order progress, driven
## from MatchClock rather than frame delta. See
## match.gd::_advance_simulation_tick() for why this and the sibling
## controllers' advance_tick() run in a fixed order.
func advance_tick() -> void:
	_process_upgrade_order(MatchClockScript.SECONDS_PER_TICK)


func handle_command(_command: StringName) -> bool:
	return false


func handle_unhandled_input(_event: InputEvent) -> bool:
	return false


func handle_upgrade_intent(building_id: StringName, button_index: int) -> bool:
	if not _upgrade_option_ids.has(building_id):
		return false
	var kind := UpgradeOrderScript.Kind.REFINERY_DOCK \
		if _is_refinery_dock_id(building_id) \
		else UpgradeOrderScript.Kind.GLOBAL_TYPE
	return _on_slot_pressed(building_id, button_index, kind)


func _try_start_dock_upgrade(refinery: Node3D, dock_building_id: StringName = &"") -> void:
	if _upgrade_queue.has_order():
		status_changed.emit("Upgrade queue is busy")
		return
	if not is_instance_valid(refinery) or not refinery.has_method("can_add_dock") or not bool(refinery.call("can_add_dock")):
		status_changed.emit("This refinery already has the maximum number of docks")
		return

	if dock_building_id == &"":
		dock_building_id = _dock_building_id_for(refinery)
	var config := _building_config(dock_building_id)
	if config == null:
		status_changed.emit("Refinery dock rules are not loaded")
		return

	if not _upgrade_queue.start(
		dock_building_id,
		_upgrade_display_name(dock_building_id),
		maxi(config.upgrade_cost, 0),
		_upgrade_build_time_ticks(config, true),
		UpgradeOrderScript.Kind.REFINERY_DOCK,
		refinery
	):
		status_changed.emit("Refinery dock could not be queued")
		return

	status_changed.emit("%s ordered" % _upgrade_queue.current_order().display_name)
	_refresh_upgrade_option_states()


## One handler for both upgrade kinds; `kind` is the only thing that differed
## between the four handlers this replaced. For REFINERY_DOCK it is also the
## dock's own entry point (docs/mechanics/production.md section 4,
## "instance-bound"): a fresh click chooses the first compatible owned refinery
## with a free dock state, and once an order is in flight clicks fall through
## to the normal pause/resume behaviour shared with global upgrades.
func _on_slot_pressed(building_id: StringName, button_index: int, kind: int) -> bool:
	if button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return false
	var order := _upgrade_queue.current_order()
	var matches := order != null and order.kind == kind and order.upgrade_id == building_id
	if button_index == MOUSE_BUTTON_RIGHT:
		if not matches:
			return true
		if order.manually_paused:
			_cancel_upgrade_order()
		else:
			_upgrade_queue.pause()
			status_changed.emit("%s upgrade paused" % order.display_name)
			_refresh_upgrade_option_states()
		return true

	if order == null:
		if kind == UpgradeOrderScript.Kind.REFINERY_DOCK:
			var refinery := _refinery_for_dock_upgrade(building_id)
			if refinery == null:
				status_changed.emit("No refinery can receive this upgrade")
			else:
				_try_start_dock_upgrade(refinery, building_id)
		else:
			_start_global_upgrade_order(building_id)
	elif not matches:
		status_changed.emit("Upgrade queue is busy")
	elif order.manually_paused:
		_upgrade_queue.resume()
		status_changed.emit("%s upgrade resumed" % order.display_name)
	else:
		var status := "%s upgrade is waiting for credits" \
			if _upgrade_queue.lacks_funds() else "%s upgrade is already running"
		status_changed.emit(status % order.display_name)
	_refresh_upgrade_option_states()
	return true

func _start_global_upgrade_order(building_id: StringName) -> void:
	var config: Resource = _building_configs.get(building_id)
	if config == null:
		status_changed.emit("Upgrade rules are not loaded")
		return
	if _upgrade_queue.has_order():
		status_changed.emit("Upgrade queue is busy")
		return
	if not _is_upgrade_available(building_id):
		status_changed.emit("%s upgrade is not available" % _upgrade_display_name(building_id))
		_refresh_upgrade_option_states()
		return

	# Global upgrades normally reuse the building's build_time. Construction
	# Yards are deployed and therefore have no building time; their Resource
	# link to the corresponding ATMCV/HKMCV/ORMCV supplies it instead.
	if not _upgrade_queue.start(
		building_id,
		_upgrade_display_name(building_id),
		maxi(config.upgrade_cost, 0),
		_upgrade_build_time_ticks(config, false)
	):
		return

	status_changed.emit("%s ordered" % _upgrade_queue.current_order().display_name)
	_refresh_upgrade_option_states()


func _cancel_upgrade_order() -> void:
	var order := _upgrade_queue.current_order()
	if order == null:
		return

	var display_name := order.display_name
	var refunded := _upgrade_queue.cancel()
	var player := _local_player()
	if player != null and refunded > 0:
		player.add_money(refunded)
	status_changed.emit("%s canceled; refunded %d" % [display_name, refunded])
	_refresh_upgrade_option_states()


func _process_upgrade_order(delta: float) -> void:
	var order := _upgrade_queue.current_order()
	if order == null:
		return
	if order.kind == UpgradeOrderScript.Kind.REFINERY_DOCK and not is_instance_valid(order.target_refinery):
		_cancel_upgrade_order()
		return

	var player := _local_player()
	var available_credits: int = player.money if player != null else 0
	var spend_credits: Callable = Callable(player, &"spend_money") if player != null else Callable()
	if _upgrade_queue.tick(delta, available_credits, spend_credits):
		_refresh_upgrade_option_states()


func _on_upgrade_queue_ready(order: UpgradeOrder) -> void:
	match order.kind:
		UpgradeOrderScript.Kind.GLOBAL_TYPE:
			_complete_global_upgrade(order)
		UpgradeOrderScript.Kind.REFINERY_DOCK:
			_complete_dock_upgrade(order)


func _complete_global_upgrade(order: UpgradeOrder) -> void:
	_upgrade_queue.take_ready()
	var player := _local_player()
	if player != null:
		player.grant_upgrade(order.upgrade_id)
		var buildings: Array = []
		if is_inside_tree():
			buildings.assign(get_tree().get_nodes_in_group("buildings"))
		UpgradeEffectsScript.apply_to_existing_buildings(buildings, player.player_id, order.upgrade_id)
	status_changed.emit("%s upgraded" % order.display_name)
	_refresh_upgrade_option_states()


func _complete_dock_upgrade(order: UpgradeOrder) -> void:
	_upgrade_queue.take_ready()

	var refinery := order.target_refinery
	if not is_instance_valid(refinery):
		status_changed.emit("%s lost its refinery before it could be completed" % order.display_name)
		_refresh_upgrade_option_states()
		return

	if not refinery.has_method("add_refinery_dock_upgrade") or not bool(refinery.call("add_refinery_dock_upgrade")):
		_refund_and_fail(order, "%s refinery can no longer receive this upgrade" % order.display_name)
		return

	dock_completed.emit(refinery)
	status_changed.emit("%s completed" % order.display_name)
	_refresh_upgrade_option_states()


func _refund_and_fail(order: UpgradeOrder, message: String) -> void:
	var player := _local_player()
	if player != null and order.cost > 0:
		player.add_money(order.cost)
	status_changed.emit(message)
	_refresh_upgrade_option_states()


func _dock_building_id_for(refinery: Node3D) -> StringName:
	var refinery_id := String(refinery.get("config_id"))
	# Refinery ids follow the "<house prefix><Name>" convention (ATRefinery,
	# HKRefinery, ORRefinery -- see assets/converted/rules/buildings/); docks
	# are the same prefix + "RefineryDock" (ATRefineryDock, ...).
	return StringName(refinery_id.substr(0, 2) + "RefineryDock")


func _is_refinery(building: Node3D) -> bool:
	var config = building.get("building_config") as Resource
	if config == null:
		config = _building_config(StringName(String(building.get("config_id"))))
	return config != null and config.roles.has(REFINERY_ROLE)


func _is_refinery_dock_id(building_id: StringName) -> bool:
	var config: Resource = _building_configs.get(building_id)
	return config != null and config.building_group_id == &"RefineryDock"


## Returns a deterministic compatible refinery. The scene-tree order is stable,
## and the dock id match keeps house-specific upgrade entries bound to their
## corresponding refinery model.
func _refinery_for_dock_upgrade(dock_building_id: StringName) -> Node3D:
	if not is_inside_tree():
		return null
	var player := _local_player()
	if player == null:
		return null
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node3D
		if building == null:
			continue
		if not EntityQueryScript.is_owned_by(building, player.player_id):
			continue
		if not _is_refinery(building):
			continue
		if _dock_building_id_for(building) != dock_building_id:
			continue
		if building.has_method("can_add_dock") and bool(building.call("can_add_dock")):
			return building
	return null


func _any_refinery_can_add_dock(building_id: StringName) -> bool:
	return _refinery_for_dock_upgrade(building_id) != null


func _is_upgrade_available(building_id: StringName) -> bool:
	var config: Resource = _building_configs.get(building_id)
	if config == null or not _has_upgrade_definition(config):
		return false
	var player := _local_player()
	if player == null or player.has_purchased_upgrade(building_id):
		return false
	return _player_owns_building_type(player.player_id, building_id)


## Mirrors BuildingController.process()'s prerequisite-availability poll:
## GLOBAL_TYPE availability depends on "does the player currently own a
## building of this type" (_is_upgrade_available) and dock availability on
## "does any owned refinery still have room" (_any_refinery_can_add_dock),
## both of which change as buildings are placed/lost elsewhere on the map --
## without this poll the panel only ever reflected the roster as it stood at
## setup() and never noticed a building completing afterwards.
func _poll_upgrade_availability() -> void:
	var changed := false
	for building_id in _upgrade_option_ids:
		var available := (
			_any_refinery_can_add_dock(building_id) if _is_refinery_dock_id(building_id)
			else _is_upgrade_available(building_id)
		)
		if available != _upgrade_availability.get(building_id, false):
			_upgrade_availability[building_id] = available
			changed = true
	if changed:
		_refresh_upgrade_option_states()


func _player_owns_building_type(player_id: int, building_id: StringName) -> bool:
	if not is_inside_tree():
		return false
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node3D
		if building == null:
			continue
		if EntityQueryScript.is_owned_by(building, player_id) and StringName(String(building.get("config_id"))) == building_id:
			return true
	return false


func _load_building_configs(building_ids: Array[StringName]) -> void:
	for building_id in building_ids:
		var config: Resource = _building_definition_catalog.definition(building_id)
		if config == null:
			continue
		_building_configs[building_id] = config
		if _has_upgrade_definition(config):
			_upgrade_option_ids.append(building_id)


## Rules.txt only defines an upgrade for a building when both fields are set
## together (UpgradeCost/UpgradeTechLevel; verified across every converted
## building config -- no entry has one without the other), so requiring both
## rather than just upgrade_cost catches a config that got the field
## partially stripped instead of silently treating it as upgradeable.
func _has_upgrade_definition(config: Resource) -> bool:
	return config.upgrade_cost > 0 and config.upgrade_tech_level > 0


func _refresh_upgrade_option_states() -> void:
	var order := _upgrade_queue.current_order()
	var player := _local_player()
	for building_id in _upgrade_option_ids:
		var tooltip := _upgrade_tooltip(building_id)

		if _is_refinery_dock_id(building_id):
			_emit_dock_option_state(building_id, order, tooltip)
			continue

		# A purchased global-type upgrade is done, not "ready to place" like a
		# finished building order, so the slot just disappears
		# (DISABLED -> hidden in side_panel.gd).
		if player != null and player.has_purchased_upgrade(building_id):
			upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
				building_id, BuildingOptionStateScript.State.DISABLED, 0.0, "", tooltip
			))
			continue

		if order == null or order.kind != UpgradeOrderScript.Kind.GLOBAL_TYPE or order.upgrade_id != building_id:
			var available := _is_upgrade_available(building_id)
			var state := BuildingOptionStateScript.availability_state(available, order != null)
			upgrade_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))
			continue

		var status_text := "PAUSED" if order.manually_paused else ""
		upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id, BuildingOptionStateScript.State.PROGRESS, order.progress_percent(), status_text, tooltip
		))


## Refinery docks have no GLOBAL_TYPE "purchased once, forever" state. Their
## option is visible only while an owned refinery has a remaining state; once
## every refinery reaches state 2, DISABLED removes the option from the panel.
func _emit_dock_option_state(building_id: StringName, order: UpgradeOrder, tooltip: String) -> void:
	if order != null and order.kind == UpgradeOrderScript.Kind.REFINERY_DOCK and order.upgrade_id == building_id:
		var status_text := "PAUSED" if order.manually_paused else ""
		upgrade_option_state_changed.emit(BuildingOptionStateScript.new(
			building_id, BuildingOptionStateScript.State.PROGRESS, order.progress_percent(), status_text, tooltip
		))
		return

	var available := _any_refinery_can_add_dock(building_id)
	var state := BuildingOptionStateScript.availability_state(available, order != null)
	upgrade_option_state_changed.emit(BuildingOptionStateScript.new(building_id, state, 0.0, "", tooltip))


func _upgrade_display_name(building_id: StringName) -> String:
	return "%s upgrade" % String(building_id)


func _upgrade_tooltip(building_id: StringName) -> String:
	var config: Resource = _building_configs.get(building_id)
	if config == null:
		return _upgrade_display_name(building_id)

	var cost: int = int(config.upgrade_cost)
	var build_time_ticks := _upgrade_build_time_ticks(config, _is_refinery_dock_id(building_id))
	var build_seconds := build_time_ticks / UpgradeQueueScript.BUILD_TICKS_PER_SECOND
	return "%s\nCost: %d\nBuild: %.1fs" % [_upgrade_display_name(building_id), cost, build_seconds]


func _upgrade_build_time_ticks(config: Resource, refinery_dock: bool) -> float:
	if config == null:
		return DEFAULT_GLOBAL_UPGRADE_BUILD_TIME_TICKS
	if refinery_dock:
		return maxf(config.upgrade_build_time_ticks if config.upgrade_build_time_ticks > 0.0 else DEFAULT_DOCK_UPGRADE_BUILD_TIME_TICKS, 1.0)
	var build_time: float = float(config.build_time_ticks)
	if build_time > 0.0:
		return build_time
	var resource_build_time := _linked_resource_build_time(config)
	return resource_build_time if resource_build_time > 0.0 else DEFAULT_GLOBAL_UPGRADE_BUILD_TIME_TICKS


func _linked_resource_build_time(config: Resource) -> float:
	for target_id in config.linked_unit_ids:
		var building_definition := _building_definition_catalog.definition(target_id)
		if building_definition != null and building_definition.build_time_ticks > 0.0:
			return building_definition.build_time_ticks
		var unit_definition := _unit_definition_catalog.definition_for(target_id)
		if unit_definition != null and unit_definition.build_time_ticks > 0.0:
			return unit_definition.build_time_ticks
	return 0.0


func _building_config(building_id: StringName) -> Resource:
	return _building_definition_catalog.definition(building_id)


func _players():
	return AutoloadLookupScript.roster(self)


func _local_player() -> PlayerData:
	var players = _players()
	if players == null:
		return null
	return players.local_player() as PlayerData
