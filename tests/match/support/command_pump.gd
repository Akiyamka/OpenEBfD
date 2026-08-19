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
## through the same bus and drain through the same executor -- but it exposes
## only what those command types need today; a command type that does not
## exist yet gets no surface here. configure_move() is the one addition Move
## needed that Stop did not: a way to hand this pump's CommandExecutor the
## navigation system, the deployment controller and (for target abilities)
## the ability handler list, none of which Stop's executor ever had to
## resolve anything against.

const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const CommandExecutorScript := preload("res://scripts/match/command_executor.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

var _entities := EntityNodeIndexScript.new()
var _bus := SimCommandBusScript.new()
var _executor := CommandExecutorScript.new(_entities)
var _clock := MatchClockScript.new()


## Allocates a stable entity id for `node` and binds it both ways, exactly as
## Match._entity_index would for a real Unit/Building -- see
## EntityNodeIndex.register(). `kind` is SimEntityRegistry.Kind.UNIT or
## .BUILDING (scripts/sim/entity_registry.gd).
func register(node: Node, kind: int) -> int:
	return _entities.register(node, kind)


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
	_executor = CommandExecutorScript.new(
		_entities, navigation, deployment_controller, terrain, target_ability_handlers
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
func pump(controller: UnitCommandController) -> void:
	var tick := _clock.advance()
	for command in _bus.drain(tick):
		var result: Dictionary = _executor.execute(command)
		controller.on_command_executed(command, result)
