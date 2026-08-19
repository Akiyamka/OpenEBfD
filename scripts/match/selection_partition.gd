class_name SelectionPartition
extends RefCounted

## What a selection looks like to a movement order: who can walk to the target,
## who can only answer with a rally point, and how many are locked in place by
## deployment.
##
## Three call sites used to derive this independently -- the move command, the
## "can this order be issued at all" probe, and the cursor's movement-or-rally
## test -- so the same classification had to be kept in step by hand across
## three loops.
##
## Deliberately a plain bucket with no logic of its own: deciding which
## bucket an entity lands in needs a deployment controller collaborator that
## does not belong to this struct, now that both UnitCommandController and
## CommandExecutor fill instances of it in -- see
## scripts/match/selection_classifier.gd, which holds that logic and is
## shared by both.

## Entities that carry their own move_to().
var movable: Array[Node] = []
## Buildings that answer a move order with a rally point, or by undeploying.
var rally: Array[Node] = []
## Selected and controllable, but immobile for the whole deploy span.
var immobilized := 0
## True when the selection holds anything that answers a move order at all --
## including a deployed unit that is currently refusing to. Lets the cursor
## tell "this selection has nothing to do with movement" (no override) apart
## from "it does, but not here" (the can't-move cursor).
var movement_capable := false


func is_empty() -> bool:
	return movable.is_empty() and rally.is_empty()
