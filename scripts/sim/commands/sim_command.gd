class_name SimCommand
extends RefCounted

## Base for every serializable player intent that travels through the
## command bus (scripts/sim/command_bus.gd). See
## docs/architecture/network-multiplayer.md, decision 1 and the "Layering"
## section: only commands cross the wire, so every command type is a plain
## data struct living in the sim zone, with no Node reference and no
## behaviour of its own beyond carrying its fields -- resolving a command
## against the live world is CommandExecutor's job
## (scripts/match/command_executor.gd), deliberately outside this zone.
##
## Deliberately absent: the tick this command executes on. When a command
## runs is a scheduling fact the bus decides at submit time
## (current_tick + input_delay_ticks -- see SimCommandBus.submit()), not a
## property of the intent itself. Folding the tick into the command would let
## a bug -- or, once commands cross a real transport, a forged frame --
## carry a tick number that never passed through the bus's ordering and late
## detection at all; keeping it out is what keeps the bus the one place that
## decision is made.

## Which player issued this command. Every concrete command carries this
## regardless of what else it carries: SimCommandBus.drain() sorts its total
## order by player_id first (see that method for why the order must be
## total, not merely stable).
var player_id: int = 0


## Identifies the concrete command type for dispatch. CommandExecutor.execute()
## matches on this today; slice 3's wire codec will decode a command's
## remaining fields by matching on the same number. Returns 0 in the base,
## which no concrete command ever returns -- every subclass overrides this to
## return its own TYPE_ID constant instead.
func type_id() -> int:
	return 0
