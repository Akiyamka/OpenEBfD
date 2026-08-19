class_name SelectionClassifier
extends RefCounted

## The one place that answers "what would a move order do with this entity
## (or this target)". That question used to have two independent answers:
## UnitCommandController asked it at click time, synchronously, to drive the
## hover cursor and the pre-Move-conversion issue-time order; CommandExecutor
## now asks the identical question again, on the tick the order actually
## executes. Splitting the move order onto the command bus (see
## docs/architecture/network-multiplayer.md, "Layering") made that second
## asker necessary, and for a while both callers carried their own copy of
## every verdict here -- _can_set_rally_point(), _can_undeploy(),
## _is_immobilized_by_deployment(), _can_interact_with()/_can_reach() (named
## _can_interact_with_target()/_can_reach() on CommandExecutor's side) --
## each individually correct, each individually tested, silently able to
## drift apart the day someone fixed an edge case on only one side. This
## class is that fix: exactly one implementation of every verdict, called
## from both places.
##
## Lives in scripts/match/, not scripts/sim/: every method here calls
## has_method()/call() on live Nodes (and, for can_undeploy()/
## request_undeployment(), on a deployment controller Node), which the sim
## zone (tools/architecture_rules.toml, sim-no-node-api) forbids outright.
##
## Deliberately a new file rather than added to selection_partition.gd:
## SelectionPartition's own doc comment says classification "needs the
## deployment controller and the player roster, both of which belong to
## UnitCommandController" -- true when only UnitCommandController asked, and
## no longer true now that CommandExecutor asks too. Folding the verdicts
## into SelectionPartition would have re-coupled the plain result bucket to
## a specific owner's collaborators again, just a different one; a sibling
## file lets SelectionPartition stay exactly what its own doc comment
## promises -- data, with no owner.
##
## What is deliberately NOT here: any notion of "the current selection", a
## SelectionPartition-shaped bucketing pass, or _has_movement_or_rally_selection()'s
## movement_capable flag. Those are aggregations over a caller's own list of
## entities, and the two callers aggregate for different reasons -- the
## cursor tracks a foreign-selection flag and a "capable even while
## deployed" flag that CommandExecutor has no use for; CommandExecutor counts
## an immobilized bucket the cursor never needs to size. Forcing one
## bucketing method to serve both would parameterize this file into
## something neither caller reads clearly, which is the trap the request to
## extract this warned against. Each caller keeps its own loop and its own
## SelectionPartition; only the per-entity/per-target verdicts inside that
## loop are shared.

var _deployment_controller
var _navigation


## Both collaborators are optional and null-guarded throughout, matching how
## UnitCommandController and CommandExecutor could each already be built
## with neither wired in (see CommandExecutor's own field comment).
func _init(deployment_controller = null, navigation = null) -> void:
	_deployment_controller = deployment_controller
	_navigation = navigation


## True when `entity` carries its own move_to() -- a unit, never a building.
func can_move_directly(entity: Node) -> bool:
	return entity.has_method("move_to")


## True when `entity` answers a move order with a rally point: it has
## set_rally_point(), and either has no opinion on whether that is allowed
## right now (can_set_rally_point() absent) or says yes.
func can_set_rally_point(entity: Node) -> bool:
	if not entity.has_method("set_rally_point"):
		return false
	return not entity.has_method("can_set_rally_point") \
		or bool(entity.call("can_set_rally_point"))


## True when `entity` is a building the deployment controller would let
## undeploy right now.
func can_undeploy(entity: Node) -> bool:
	return _deployment_controller != null and entity.is_in_group("buildings") \
		and _deployment_controller.has_method("can_undeploy") \
		and bool(_deployment_controller.call("can_undeploy", entity))


## Both transition states and the fully-deployed state reject movement: a
## combat-deployed unit (Kindjal/Mortar/Kobra) is immobile for its whole
## DEPLOYING -> DEPLOYED -> UNDEPLOYING span, not just while transitioning.
func is_immobilized_by_deployment(entity: Node) -> bool:
	return (
		(entity.has_method("is_deploying") and bool(entity.call("is_deploying")))
		or (entity.has_method("is_deployed") and bool(entity.call("is_deployed")))
	)


## True when at least one of `entities` can unload at target_entity. A null
## or non-building target (including one whose id no longer resolves, on
## CommandExecutor's side of a click that named a since-dead entity) always
## answers false.
func can_interact_with(entities: Array[Node], target_entity: Node) -> bool:
	if target_entity == null or not target_entity.is_in_group("buildings"):
		return false
	for entity in entities:
		if entity.has_method("can_unload_at") and entity.has_method("command_unload") \
		and bool(entity.call("can_unload_at", target_entity)):
			return true
	return false


## True when a move order to `target` can do *something* with these buckets:
## a rally-capable selection always can (it answers with a rally point
## regardless of reachability), a movable selection defers to the
## navigation system's own reachability check when one is wired in.
func can_reach(movable_entities: Array[Node], rally_buildings: Array[Node], target: Vector3) -> bool:
	if not rally_buildings.is_empty():
		return true
	if movable_entities.is_empty():
		return false
	if _navigation != null and _navigation.has_method("can_move_to"):
		return bool(_navigation.call("can_move_to", movable_entities, target))
	return true


## Asks the deployment controller to undeploy `entity` toward `target`
## instead of taking a rally point, returning its result Dictionary if it
## accepted (handled == true) or an empty Dictionary otherwise. Only
## CommandExecutor calls this today -- the cursor previews can_undeploy()'s
## yes/no but never the resulting message -- and it stays here anyway: it
## reads the same _deployment_controller this file already holds for
## can_undeploy(), and separating the two into different files would split a
## "can it" and a "do it" that only make sense read together.
func request_undeployment(entity: Node, target: Vector3, move_mode: int) -> Dictionary:
	if _deployment_controller == null or not entity.is_in_group("buildings") \
	or not _deployment_controller.has_method("try_undeploy"):
		return {}
	var result: Dictionary = _deployment_controller.call(
		"try_undeploy", entity, target, move_mode
	)
	return result if bool(result.get("handled", false)) else {}
