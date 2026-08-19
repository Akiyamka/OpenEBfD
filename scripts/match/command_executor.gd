class_name CommandExecutor
extends RefCounted

## Resolves a drained SimCommand (scripts/sim/commands/sim_command.gd) to the
## live Node(s) it names and carries out its effect. This lives outside the
## sim zone deliberately: it dereferences entity ids into Nodes and calls
## methods on them, which scripts/sim/**/*.gd is forbidden from doing (see
## tools/architecture_rules.toml's sim-no-node-api and
## docs/architecture/network-multiplayer.md, decision 3). SimCommandBus
## (scripts/sim/command_bus.gd) only orders commands; this is the other half
## that actually does something with one.
##
## Dispatches on command.type_id() with a match statement, not an `is`
## chain -- the same integer slice 3's wire codec will decode a command's
## type from, so there is exactly one dispatch idiom for "which command is
## this" from the first command type onward, instead of two that drift apart
## as more are added.

const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")

var _entities: EntityNodeIndex


func _init(entities: EntityNodeIndex) -> void:
	_entities = entities


## Returns a small result Dictionary the caller can render as status text --
## e.g. {"stopped": 2} -- never raises and never blocks on anything the
## command's entities are doing.
func execute(command: SimCommand) -> Dictionary:
	match command.type_id():
		SimStopCommandScript.TYPE_ID:
			return _execute_stop(command as SimStopCommand)
		_:
			return {}


## An id that no longer resolves (node_for() returns null) is skipped
## silently, never treated as an error: the entity died somewhere between
## the click that queued this command and the tick it executes on, which is
## ordinary -- and, crucially, happens identically on every client, because
## every client reaches this tick having simulated the exact same world up
## to it. Treating a stale id as an error would be treating an unremarkable
## consequence of lockstep's one-tick-minimum latency as if it were a bug;
## this is the single most important behavioural difference between issuing
## an order (today, against a live selection) and executing a command
## (later, against whatever the world turns out to be by the time it runs).
func _execute_stop(command: SimStopCommand) -> Dictionary:
	var stopped := 0
	for id in command.entity_ids:
		var node := _entities.node_for(id)
		if node == null:
			continue
		if not node.has_method("cancel_all_orders"):
			continue
		if bool(node.call("cancel_all_orders")):
			stopped += 1
	return {"stopped": stopped}
