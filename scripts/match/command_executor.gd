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
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")
const SelectionClassifierScript := preload("res://scripts/match/selection_classifier.gd")

var _entities: EntityNodeIndex
## Move's collaborators, absent from Stop entirely -- see _execute_move().
## All three are optional and null-guarded exactly the way
## UnitCommandController's own copies of them were before this slice: a
## CommandExecutor built with none of them still resolves ids and moves
## entities directly via entity.move_to(), it just cannot route through the
## navigation system, offer undeployment, or classify a click onto spice or a
## refinery. _navigation is kept as its own field because _execute_move()
## also uses it directly to actually move entities, not just to ask
## _classifier whether it could; _deployment_controller is not kept
## separately because nothing here reads it outside of what _classifier
## already answers.
var _navigation
var _terrain: MapLoader
## The one shared implementation of every "what would a move order do here"
## verdict, also used by UnitCommandController's cursor code -- see
## scripts/match/selection_classifier.gd for why this exists as its own
## file. Built once, unlike UnitCommandController's per-call _classifier():
## unlike that controller, nothing here ever reassigns _navigation or
## _deployment_controller after construction, so there is no staleness risk
## to guard against by rebuilding it.
var _classifier: SelectionClassifier


func _init(entities: EntityNodeIndex, navigation = null, deployment_controller = null, terrain: MapLoader = null) -> void:
	_entities = entities
	_navigation = navigation
	_terrain = terrain
	_classifier = SelectionClassifierScript.new(deployment_controller, navigation)


## Returns a small result Dictionary the caller can render as status text --
## e.g. {"stopped": 2} -- never raises and never blocks on anything the
## command's entities are doing.
func execute(command: SimCommand) -> Dictionary:
	match command.type_id():
		SimStopCommandScript.TYPE_ID:
			return _execute_stop(command as SimStopCommand)
		SimMoveCommandScript.TYPE_ID:
			return _execute_move(command as SimMoveCommand)
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


## Resolves the command's acting entities and target, classifies them via
## _classifier (scripts/match/selection_classifier.gd -- the same object
## UnitCommandController's cursor code asks the identical questions of), and
## carries out the result: a plain move, a rally point, an undeployment, a
## harvest order, or an unload order, per acting entity. The classification
## happens here, at execution, rather than at click time, because it is a
## verdict about the world -- "can this reach that target", "is this still
## deployed", "is there spice under the cursor" -- and every client must
## reach the same verdict from the same world; see SimMoveCommand's doc
## comment. Only the classification loop's shape (which entities to ask, and
## how to bucket the answers into movable/rally/immobilized) lives here; the
## individual verdicts themselves do not, so this loop and
## UnitCommandController._partition_selection()'s cannot silently drift
## apart from each other the way they once did.
##
## The result Dictionary is read by
## UnitCommandController.on_command_executed(), which rebuilds the exact
## status text _command_move() used to assemble inline, and plays the move
## voice line -- see that method for the key-by-key contract. "had_movable"
## is the one key that is not player-visible data: it tells the controller
## which of _command_move()'s two original branches (a plain/harvest/unload
## order, versus a rally-point-or-nothing order) produced this result, since
## an empty moving_entities/harvesting_entities/unloading_entities trio is
## ambiguous between "there was nothing movable to begin with" and "movable
## entities existed and all of them ended up building an empty array in
## between" -- which cannot actually happen (every movable entity lands in
## exactly one of the three), but the flag is what lets the reader avoid
## re-deriving that invariant instead of stating it once here.
func _execute_move(command: SimMoveCommand) -> Dictionary:
	var entities: Array[Node] = []
	for id in command.entity_ids:
		var node := _entities.node_for(id)
		if node != null:
			entities.append(node)

	# See SimMoveCommand's doc comment on target_entity_id: a clicked entity
	# that died between the click and this tick simply fails to resolve here,
	# and every check below that depends on target_entity naturally falls
	# through to plain movement -- there is no special case to write.
	var target_entity: Node = null
	if command.target_entity_id != 0:
		target_entity = _entities.node_for(command.target_entity_id)

	var movable_entities: Array[Node] = []
	var rally_buildings: Array[Node] = []
	var deploying_count := 0
	for entity in entities:
		var can_move := _classifier.can_move_directly(entity)
		var can_rally := not can_move \
			and (_classifier.can_set_rally_point(entity) or _classifier.can_undeploy(entity))
		if _classifier.is_immobilized_by_deployment(entity):
			deploying_count += 1
			continue
		if can_move:
			movable_entities.append(entity)
		elif can_rally:
			rally_buildings.append(entity)

	if movable_entities.is_empty() and rally_buildings.is_empty():
		return {"deploying": deploying_count}

	var target := command.target
	var move_mode := command.move_mode

	# Computed from the pre-undeployment buckets above, on purpose: whether
	# this order can proceed at all must not depend on which of the rally
	# buildings later turn out to want undeployment instead of a rally point.
	if not _classifier.can_interact_with(entities, target_entity) \
	and not _classifier.can_reach(movable_entities, rally_buildings, target):
		return {"rejected": true}

	var undeployment_messages: Array[String] = []
	var ordinary_rally_buildings: Array[Node] = []
	for building in rally_buildings:
		var undeployment := _classifier.request_undeployment(building, target, move_mode)
		if undeployment.is_empty():
			ordinary_rally_buildings.append(building)
			continue
		undeployment_messages.append(String(undeployment.get("message", "")))
	rally_buildings = ordinary_rally_buildings

	if movable_entities.is_empty():
		for building in rally_buildings:
			building.call("set_rally_point", target)
		return {
			"rally_buildings": rally_buildings,
			"undeployment_messages": undeployment_messages,
			"deploying": deploying_count,
		}

	var target_cell := Vector2i(-1, -1)
	var spice_target := false
	if _terrain != null and _terrain.navigation_grid != null and _terrain.navigation_grid.is_loaded():
		target_cell = _terrain.navigation_grid.world_to_grid(target)
		spice_target = _terrain.spice_layer != null \
			and bool(_terrain.spice_layer.call("has_spice", target_cell))

	var harvesting_entities: Array[Node] = []
	var unloading_entities: Array[Node] = []
	var moving_entities: Array[Node] = []
	for entity in movable_entities:
		var can_unload := target_entity != null \
			and entity.has_method("can_unload_at") \
			and bool(entity.call("can_unload_at", target_entity)) \
			and entity.has_method("command_unload")
		if can_unload and _terrain != null and _terrain.navigation_grid != null \
		and bool(entity.call(
			"command_unload", target_entity, _terrain.navigation_grid, _terrain.spice_layer
		)):
			unloading_entities.append(entity)
			continue
		var can_harvest := entity.has_method("can_harvest_spice") \
			and bool(entity.call("can_harvest_spice")) \
			and entity.has_method("command_harvest")
		if spice_target and can_harvest \
		and bool(entity.call("command_harvest", _terrain.spice_layer, _terrain.navigation_grid, target_cell)):
			harvesting_entities.append(entity)
			continue
		moving_entities.append(entity)

	if not moving_entities.is_empty():
		if _navigation != null:
			_navigation.command_move(moving_entities, target, move_mode)
		else:
			for entity in moving_entities:
				entity.move_to(target)

	return {
		"had_movable": true,
		"moving_entities": moving_entities,
		"harvesting_entities": harvesting_entities,
		"unloading_entities": unloading_entities,
		"rally_buildings": rally_buildings,
		"undeployment_messages": undeployment_messages,
		"deploying": deploying_count,
		"target_entity": target_entity,
	}
