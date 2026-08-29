extends RefCounted

## Stands in for the slice of Match that owns the command path -- the
## EntityNodeIndex, SimCommandBus and CommandExecutor triplet
## Match._ready()/_advance_simulation_tick() wire together -- for suites that
## drive a UnitCommandController by hand with no Match anywhere in the tree.
##
## Modeled on tests/combat/support/sim_tick_pump.gd, which exists for the
## identical reason one layer down: phase 1 centralized sim_tick() into
## Match._advance_simulation_tick(), so a suite that pokes an entity directly
## needs a stand-in to drive it the same way Match would. Phase 2 centralizes
## the command path into that same function -- see its doc comment for the
## order pump() below must match.
##
## Every command names its targets by stable entity id (see
## scripts/sim/entity_registry.gd), never by Node, so a fixture that invents
## its own entity_id would stop testing the id path at all. register() is the
## fix: it hands back the id this pump's own EntityNodeIndex actually
## allocated -- the same registry a real CommandExecutor resolves ids against
## via EntityNodeIndex.node_for().
##
## Written for reuse across every command type this phase and the next add --
## move, attack, deploy, target abilities and the panel intents all submit
## through the same bus, drained in the same call to pump() -- but it exposes
## only what those command types need today; a command type that does not
## exist yet gets no surface here. configure_move() is the one addition Move
## needed that Stop did not: a way to hand this pump's CommandExecutor the
## navigation system, the deployment controller and (for target abilities)
## the ability handler list, none of which Stop's executor ever had to
## resolve anything against. The panel intents' three commands (build/unit/
## upgrade order) are the other kind of addition -- see
## configure_queue_controllers()'s own comment below for how those reach
## CommandExecutor.execute() the same way every other command type does, just
## without an entity id to resolve first.

const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const CommandExecutorScript := preload("res://scripts/match/command_executor.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")

var _entities := EntityNodeIndexScript.new()
var _bus := SimCommandBusScript.new()
var _navigation = null
var _deployment_controller = null
var _terrain: MapLoader = null
var _target_ability_handlers: Array = []
var _building_controller = null
var _unit_roster_controller = null
var _building_upgrade_controller = null
var _executor := CommandExecutorScript.new(_entities)
var _clock := MatchClockScript.new()


## Allocates a stable entity id for `node` and binds it both ways, exactly as
## Match._entity_index would for a real Unit/Building -- see
## EntityNodeIndex.register(). `kind` is SimEntityRegistry.Kind.UNIT or
## .BUILDING (scripts/sim/entity_registry.gd).
func register(node: Node, kind: int) -> int:
	return _entities.register(node, kind)


## MatchLookup.GROUP stand-in (see scripts/match/match_lookup.gd): a bare
## Node whose entity_index() answers with this pump's own _entities, the
## same call shape MatchLookup.entity_index() expects from a real Match
## (`match_node.call("entity_index")`).
class _MatchLookupStub extends Node:
	var _index: EntityNodeIndex

	func _init(index: EntityNodeIndex) -> void:
		_index = index

	func entity_index() -> EntityNodeIndex:
		return _index


var _match_lookup_stub: Node = null


## Building._register_entity_id() (scripts/buildings/building.gd) -- and
## Unit's equivalent -- finds its Match through
## MatchLookup.entity_index(self), which walks up to the first node in
## MatchLookup.GROUP that answers entity_index(). Suites with a stub entity
## (tests/match/unit_command_run.gd and friends) sidestep that entirely by
## calling register() above directly on their own stub, but a suite driving
## a real Building has no such shortcut: Building.entity_id is a read-only
## getter over a private field only _register_entity_id() ever writes, so
## the only way to give a real Building a real, resolvable id is to make
## MatchLookup.entity_index() find something -- this installs that something,
## so a Building added to the tree afterward self-registers into this pump's
## own _entities through the exact production code path (add_to_group() then
## _ready() then _register_entity_id()), the same as it would under a real
## Match.
##
## Must run before the Building enters the tree: _register_entity_id() reads
## MatchLookup.entity_index() from _ready(), which Godot calls synchronously
## as part of add_child() the first time a node enters a tree, so installing
## the stub after add_child() is already too late.
##
## Call uninstall_match_lookup_stub() when the case is done with it, or the
## stub leaks into the next case's own MatchLookup.entity_index() lookup --
## see tests/match/command_bus_wiring_run.gd's comment on the identical
## hazard for a real Match's group membership.
func install_match_lookup_stub(tree_root: Node) -> void:
	if _match_lookup_stub != null:
		return
	_match_lookup_stub = _MatchLookupStub.new(_entities)
	tree_root.add_child(_match_lookup_stub)
	_match_lookup_stub.add_to_group(MatchLookupScript.GROUP)


## Removes the stub installed by install_match_lookup_stub(). Uses free(),
## not queue_free(): this file's suites run their cases synchronously, with
## no `await process_frame` between them (unlike
## tests/match/command_bus_wiring_run.gd's, which awaits precisely because
## queue_free() defers a real Match's removal from MatchLookupScript.GROUP to
## the frame's teardown), so a deferred free here would leak this stub's
## group membership into the very next case in the same synchronous run. The
## stub is a bare, childless Node, so an immediate free() is safe where it
## would not be for a live Match mid-teardown.
func uninstall_match_lookup_stub() -> void:
	if _match_lookup_stub == null:
		return
	_match_lookup_stub.free()
	_match_lookup_stub = null


## Handed to UnitCommandController.setup() as its command_bus argument.
func bus() -> SimCommandBus:
	return _bus


## Rebuilds this pump's CommandExecutor with every collaborator a command
## type past Stop might need: the navigation system, the deployment
## controller, the terrain (for its navigation grid and spice layer), and the
## target-ability handler list Deploy and target abilities want -- none of
## which Stop ever needed, so the field default of pump()'s own
## CommandExecutor(entities) leaves them all null/empty exactly like a Match
## built with none of them would. A command-issuing case passes the same
## fixture instances here that it also hands to UnitCommandController.setup(),
## matching how Match wires one shared navigation system, deployment
## controller and handler list into both _command_executor and
## _unit_command_controller (see Match._setup_unit_command_controller()'s call
## site). Kept under its original Move-era name -- every existing call site
## already reads it as "configure the executor", not "configure Move
## specifically" -- rather than renamed for a fourth and fifth command type's
## sake.
func configure_move(
		navigation = null,
		deployment_controller = null,
		terrain: MapLoader = null,
		target_ability_handlers: Array = []
	) -> void:
	_navigation = navigation
	_deployment_controller = deployment_controller
	_terrain = terrain
	_target_ability_handlers = target_ability_handlers
	_rebuild_executor()


## The panel intents' counterpart to configure_move(): command-facing
## controllers that route a build/unit/upgrade order into the production
## system that owns its queue. They are handed to the CommandExecutor,
## exactly as Match hands them to its own, rather than being dispatched to from pump() --
## a harness that answers "which command is this" in its own match statement
## would be testing a dispatch the game does not have.
func configure_queue_controllers(
		building_controller = null,
		unit_roster_controller = null,
		building_upgrade_controller = null
	) -> void:
	_building_controller = building_controller
	_unit_roster_controller = unit_roster_controller
	_building_upgrade_controller = building_upgrade_controller
	_rebuild_executor()


## CommandExecutor takes every collaborator at construction, so each
## configure_* call rebuilds it from the fields rather than mutating one in
## place. Cases call the two configure_* methods in either order, or neither.
func _rebuild_executor() -> void:
	_executor = CommandExecutorScript.new(
		_entities,
		_navigation,
		_deployment_controller,
		_terrain,
		_target_ability_handlers,
		_building_controller,
		_unit_roster_controller,
		_building_upgrade_controller
	)


## Handed to UnitCommandController.setup() as its submit_tick_provider
## argument -- this pump's equivalent of Match.next_orderable_tick(), with the
## same +1 and the same reasoning: pump()'s drain for tick T happens as the
## first step of the call that advances this clock to T, so a command
## submitted right now is late by construction unless it targets at least one
## tick past what this pump has already advanced to.
func next_orderable_tick() -> int:
	return _clock.current_tick() + 1


## Advances this pump's clock by exactly one tick, drains and executes
## whatever comes due, and hands each result to
## `controller.on_command_executed()` -- in that order, matching
## Match._advance_simulation_tick(): commands are drained and executed before
## anything else in a tick gets a chance to move, and each result is reported
## back the moment its command runs.
##
## `controller` is optional because a case exercising only the panel intents
## has no UnitCommandController to report back to -- those controllers emit
## their own status signals directly.
func pump(controller: UnitCommandController = null) -> void:
	var tick := _clock.advance()
	for command in _bus.drain(tick):
		var result: Dictionary = _executor.execute(command)
		if controller != null:
			controller.on_command_executed(command, result)


## Slice C5 stand-in for the other half of
## Match._advance_simulation_tick()'s own last statement: a real Building/
## Unit's request_despawn() (scripts/buildings/building.gd,
## scripts/units/unit.gd) queues its id in this pump's own EntityNodeIndex
## rather than calling queue_free() directly, whenever install_match_lookup_
## stub() below has given it a resolvable entity id -- the same deferred-
## despawn contract a real Match honours by draining every tick. This pump
## has no tick loop of its own to run that drain from automatically (pump()
## above only drains the command bus), so a case that sells or kills a real
## Building/Unit through the production code path must call this explicitly
## before asserting is_queued_for_deletion(), or the node is left correctly
## halted but never actually freed. tests/buildings/controller_run.gd's sale
## cases are today's example.
func apply_pending_releases() -> int:
	return _entities.apply_pending_releases()
