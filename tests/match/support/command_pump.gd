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
## move, attack, deploy and the panel intents all submit through the same bus
## and drain through the same executor -- but it exposes only what Stop needs
## today; a command type that does not exist yet gets no surface here.

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
