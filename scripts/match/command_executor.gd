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
const SimAttackCommandScript := preload("res://scripts/sim/commands/attack_command.gd")
const SimDeployCommandScript := preload("res://scripts/sim/commands/deploy_command.gd")
const SimTargetAbilityCommandScript := preload("res://scripts/sim/commands/target_ability_command.gd")
const SimBuildOrderCommandScript := preload("res://scripts/sim/commands/build_order_command.gd")
const SimUnitOrderCommandScript := preload("res://scripts/sim/commands/unit_order_command.gd")
const SimUpgradeOrderCommandScript := preload("res://scripts/sim/commands/upgrade_order_command.gd")
const SimSellBuildingCommandScript := preload("res://scripts/sim/commands/sell_building_command.gd")
const SimRepairBuildingCommandScript := preload("res://scripts/sim/commands/repair_building_command.gd")
const SimPlaceBuildingCommandScript := preload("res://scripts/sim/commands/place_building_command.gd")
const SimWallLineCommandScript := preload("res://scripts/sim/commands/wall_line_command.gd")
const SelectionClassifierScript := preload("res://scripts/match/selection_classifier.gd")
const SelectionTargetAbilityControllerScript := preload(
	"res://scripts/match/selection_target_ability_controller.gd"
)

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
## already answers. _execute_attack() reuses this same field for
## _assign_attack_arcs() -- attack needs no collaborator Move does not
## already require this class to hold.
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
## Target ability's own collaborator, absent from every other command: the
## handler list SelectionTargetAbilityController.handler_for() (scripts/match/
## selection_target_ability_controller.gd) resolves an ability id against --
## the same list UnitCommandController.setup() hands to its own
## SelectionTargetAbilityController instance, so both sides resolve a given
## ability id to the same handler. See _execute_target_ability().
var _target_ability_handlers: Array = []
## Owners of the production and upgrade queues -- see _init()'s doc comment
## for why they live here rather than being dispatched to from Match.
var _building_controller
var _unit_roster_controller
var _building_upgrade_controller


## The three queue controllers are the collaborators for command types that
## name no entity at all -- a production or upgrade order is addressed to a
## player's queue, so there is nothing here for EntityNodeIndex to resolve.
## They are constructor arguments rather than a second dispatch point in
## Match for a reason worth stating: this class is where "which command is
## this" gets answered, and it has to stay the only place that answers it.
## A second match statement elsewhere would mean a new command type could be
## registered in one dispatcher and forgotten in the other, and the symptom
## would be the command vanishing without an error.
func _init(
		entities: EntityNodeIndex,
		navigation = null,
		deployment_controller = null,
		terrain: MapLoader = null,
		target_ability_handlers: Array = [],
		building_controller = null,
		unit_roster_controller = null,
		building_upgrade_controller = null
	) -> void:
	_entities = entities
	_navigation = navigation
	_terrain = terrain
	_classifier = SelectionClassifierScript.new(deployment_controller, navigation)
	_target_ability_handlers = target_ability_handlers.duplicate()
	_building_controller = building_controller
	_unit_roster_controller = unit_roster_controller
	_building_upgrade_controller = building_upgrade_controller


## Returns a small result Dictionary the caller can render as status text --
## e.g. {"stopped": 2} -- never raises and never blocks on anything the
## command's entities are doing.
func execute(command: SimCommand) -> Dictionary:
	match command.type_id():
		SimStopCommandScript.TYPE_ID:
			return _execute_stop(command as SimStopCommand)
		SimMoveCommandScript.TYPE_ID:
			return _execute_move(command as SimMoveCommand)
		SimAttackCommandScript.TYPE_ID:
			return _execute_attack(command as SimAttackCommand)
		SimDeployCommandScript.TYPE_ID:
			return _execute_deploy(command as SimDeployCommand)
		SimTargetAbilityCommandScript.TYPE_ID:
			return _execute_target_ability(command as SimTargetAbilityCommand)
		SimBuildOrderCommandScript.TYPE_ID:
			if _building_controller != null:
				_building_controller.execute_build_order_command(command as SimBuildOrderCommand)
			return {}
		SimUnitOrderCommandScript.TYPE_ID:
			if _unit_roster_controller != null:
				_unit_roster_controller.execute_unit_order_command(command as SimUnitOrderCommand)
			return {}
		SimUpgradeOrderCommandScript.TYPE_ID:
			if _building_upgrade_controller != null:
				_building_upgrade_controller.execute_upgrade_order_command(
					command as SimUpgradeOrderCommand
				)
			return {}
		SimSellBuildingCommandScript.TYPE_ID:
			return _execute_sell_building(command as SimSellBuildingCommand)
		SimRepairBuildingCommandScript.TYPE_ID:
			return _execute_repair_building(command as SimRepairBuildingCommand)
		SimPlaceBuildingCommandScript.TYPE_ID:
			if _building_controller != null:
				_building_controller.execute_place_building_command(command as SimPlaceBuildingCommand)
			return {}
		SimWallLineCommandScript.TYPE_ID:
			if _building_controller != null:
				_building_controller.execute_wall_line_command(command as SimWallLineCommand)
			return {}
		_:
			# A command the bus scheduled, the codec can carry, and nothing
			# here knows how to run. Silence would drop it without a trace --
			# the same loss SimCommandBus refuses to absorb for a late
			# command and FrameTickDriver refuses to absorb for a dropped
			# tick, and for the same reason: in lockstep a command that ran
			# on some clients and not others is a divergence, not a hiccup.
			push_error(
				"CommandExecutor.execute(): no handler for command type_id %d -- " % command.type_id()
				+ "a new SimCommand subclass must be added to this match statement, "
				+ "not only to SimCommandCodec's table."
			)
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


## Resolves the command's acting entities and target, then carries out the
## attack: an entity that is mid-deployment-transition (_classifier.
## is_deploying(), deliberately narrower than the movement-side
## is_immobilized_by_deployment() -- see that method's doc comment) or whose
## own can_attack() rejects this target is left out of the accepted list
## rather than treated as an error, and every accepted entity receives
## command_attack(). This is the one place this loop differs from
## _execute_stop()'s: that method only ever drops a *dead* id, never a living
## entity that simply cannot act; this one does both, because "can this
## entity attack this" is itself a verdict about the world that must be read
## on the execution tick, identically on every client -- see SimAttackCommand's
## doc comment.
##
## target_entity_id resolving to null (the clicked entity died between the
## click and this tick) falls through to command.target -- an attack-ground
## order at the position recorded when the order was issued -- exactly the
## way SimMoveCommand's target_entity_id falls through to plain movement; see
## SimAttackCommand.target_entity_id's doc comment for why this, rather than
## silently dropping the order, is the chosen fallback.
##
## The result Dictionary is read by
## UnitCommandController.on_command_executed(), which rebuilds the exact
## status text and voice line _issue_attack_order() used to assemble inline --
## see that method's doc comment for the key-by-key contract. "rejected" is
## the empty-accepted-list case ("Selected units cannot attack this target");
## "accepted" and "target_or_position" are what the controller needs to
## reconstruct the label and play the attack voice line, since only this
## method knows which entities actually accepted the order and what the live
## target resolved to.
func _execute_attack(command: SimAttackCommand) -> Dictionary:
	var entities: Array[Node] = []
	for id in command.entity_ids:
		var node := _entities.node_for(id)
		if node != null:
			entities.append(node)

	var target_entity: Node = null
	if command.target_entity_id != 0:
		target_entity = _entities.node_for(command.target_entity_id)
	var target_or_position: Variant = target_entity if target_entity != null else command.target

	var accepted: Array[Node] = []
	for entity in entities:
		if _classifier.is_deploying(entity):
			continue
		if not _classifier.can_attack(entity, target_or_position):
			continue
		if bool(entity.call("command_attack", target_or_position)):
			accepted.append(entity)

	if accepted.is_empty():
		return {"rejected": true}

	_assign_attack_arcs(accepted, target_or_position)

	return {
		"accepted": accepted,
		"target_or_position": target_or_position,
	}


## Spreads one attack command into an arc around the target. Moved here from
## UnitCommandController._issue_attack_order(): arc assignment changes where
## units end up standing, which makes it simulation, not view -- it belongs on
## the tick, next to the order it spreads, not at the click that merely
## scheduled it.
##
## An attack order is otherwise entirely per-unit: every shooter runs the same
## perch search, converges on the same cell, and the first arrivals stop on the
## max-range ring and wall the rest out of weapon range. Handing each unit its
## own bearing is what turns that queue into a firing line -- see
## AttackArcAllocator for the geometry.
##
## Left alone deliberately: a lone shooter (nothing to spread), a building or
## other stationary attacker (no bearing to take), and anything that cannot
## engage this target at all.
func _assign_attack_arcs(accepted: Array[Node], target_or_position: Variant) -> void:
	if _navigation == null or not _navigation.has_method("assign_attack_arcs"):
		return
	var target := Vector3.INF
	if target_or_position is Vector3:
		target = target_or_position
	elif target_or_position is Node3D:
		target = (target_or_position as Node3D).global_position
	if not target.is_finite():
		return
	var shooters: Array[Node3D] = []
	# The pitch is measured on the tightest arc anyone will actually stand on,
	# so the shortest engagement range in the group wins.
	var engagement_radius := INF
	for entity in accepted:
		var unit := entity as Node3D
		if unit == null or not unit.has_method("attack_engagement_radius") \
		or not unit.has_method("set_attack_arc_direction"):
			continue
		var radius := float(unit.call("attack_engagement_radius", target_or_position))
		if radius <= 0.0:
			continue
		shooters.append(unit)
		engagement_radius = minf(engagement_radius, radius)
	if shooters.size() <= 1 or not is_finite(engagement_radius):
		return
	_navigation.call("assign_attack_arcs", shooters, target, engagement_radius)


## Resolves the command's acting entities and asks _classifier.request_deploy()
## (scripts/match/selection_classifier.gd) to toggle each one through
## UnitDeploymentController.try_deploy() -- the single entry point that
## decides which direction (deploy a travel-mode MCV/combat-deploy unit, or
## undeploy an already-deployed one) applies to a given entity right now. An
## id that no longer resolves is skipped silently, exactly as _execute_stop()'s
## comment explains; an id that resolves but is not a deploy candidate on this
## tick (not a unit, or a unit the deployment controller has no strategy for)
## is also skipped rather than treated as an error, for the same reason
## _execute_attack() drops an entity that cannot act on this tick: "can this
## entity deploy right now" is a verdict about the world that must be read
## identically by every client on the execution tick, not at the click that
## merely scheduled it -- see SimDeployCommand's doc comment.
##
## The result Dictionary is read by UnitCommandController.on_command_executed(),
## which joins every accepted entity's message with " | ", exactly as
## _deploy_selected_entities() used to build inline before this command moved
## onto the bus.
func _execute_deploy(command: SimDeployCommand) -> Dictionary:
	var messages: Array[String] = []
	for id in command.entity_ids:
		var node := _entities.node_for(id)
		if node == null:
			continue
		var result := _classifier.request_deploy(node)
		if result.is_empty():
			continue
		var message := String(result.get("message", ""))
		if not message.is_empty():
			messages.append(message)
	return {"messages": messages}


## Resolves the command's acting entities and its optional target entity,
## resolves the handler that serves command.ability_id against that acting
## selection via SelectionTargetAbilityController.handler_for() (scripts/match/
## selection_target_ability_controller.gd -- the same lookup that
## controller's own live execute()/cursor_for() use, parameterized here on
## this command's own entity_ids instead of whatever selection
## UnitCommandController now holds; see that method's doc comment on why one
## shared implementation serves both), and calls the handler's own execute().
##
## Mirrors SelectionTargetAbilityController.execute()'s {ok, message} result
## contract exactly, so UnitCommandController.on_command_executed() can
## assemble the identical status text that controller used to emit
## synchronously. A handler that cannot be found (an id no active mode should
## be able to produce, but not one this method trusts) returns an empty
## Dictionary rather than a synthesized rejection message -- matching
## SelectionTargetAbilityController.execute()'s own silent `return false` in
## the identical case, which never emits a status either.
##
## target_entity resolving to null -- no entity was under the cursor at click
## time, or the clicked entity died between the click and this tick -- is
## simply passed through as null: unlike Move/Attack, no ability here falls
## back to a ground position when its target entity is gone, because
## AdvancedCarryallAbility's own candidate search already treats a null
## target as "no eligible carrier" and reports "Ability target is invalid",
## which is the correct behaviour for a target that no longer exists, not a
## gap this method needs to paper over.
func _execute_target_ability(command: SimTargetAbilityCommand) -> Dictionary:
	var entities: Array[Node] = []
	for id in command.entity_ids:
		var node := _entities.node_for(id)
		if node != null:
			entities.append(node)

	var target_entity: Node = null
	if command.target_entity_id != 0:
		target_entity = _entities.node_for(command.target_entity_id)

	var handler = SelectionTargetAbilityControllerScript.handler_for(
		command.ability_id, entities, _target_ability_handlers
	)
	if handler == null:
		return {}
	return handler.call(
		"execute", command.ability_id, entities, target_entity, command.target_position
	)


## Resolves the command's building and, if both it and the controller are
## still around, hands it to BuildingController.execute_sell_building_command()
## (scripts/buildings/building_controller.gd) -- see that method's and
## SimSellBuildingCommand's own doc comments for what runs there. An id that
## no longer resolves (the building died, or was already sold, between the
## click and this tick) is skipped silently, exactly as _execute_stop()'s
## comment explains for the identical case -- this method hands a resolved
## Node to BuildingController rather than an id, since this class is the only
## place in the codebase that dereferences entity ids into Nodes (see this
## class's own doc comment).
func _execute_sell_building(command: SimSellBuildingCommand) -> Dictionary:
	if _building_controller == null:
		return {}
	var node := _entities.node_for(command.entity_id)
	if node == null:
		return {}
	_building_controller.execute_sell_building_command(node)
	return {}


## The repair-toggle counterpart to _execute_sell_building() above -- same
## dead-id handling, same reason a resolved Node crosses into
## BuildingController rather than a bare id. Which direction the toggle goes
## is not this method's concern: BuildingController.
## execute_repair_building_command() reads is_repairing off `node` itself,
## on this tick, per SimRepairBuildingCommand's doc comment.
func _execute_repair_building(command: SimRepairBuildingCommand) -> Dictionary:
	if _building_controller == null:
		return {}
	var node := _entities.node_for(command.entity_id)
	if node == null:
		return {}
	_building_controller.execute_repair_building_command(node)
	return {}
