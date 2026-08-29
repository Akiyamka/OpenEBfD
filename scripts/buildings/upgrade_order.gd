class_name UpgradeOrder
extends RefCounted

const ProductionProgressScript := preload("res://scripts/buildings/production_progress.gd")

## Mirrors BuildingOrder (see building_order.gd) but for the player's single
## upgrade queue (docs/mechanics/production.md section 4). "upgrade_id" is
## the building type this upgrade affects -- for a GLOBAL_TYPE order that is
## the building whose next tech level gets unlocked player-wide; for a
## REFINERY_DOCK order it is the dock's own building id (e.g.
## "ATRefineryDock"), and target_refinery is the automatically selected
## Refinery entity id whose internal dock state advances on completion.

enum Kind { GLOBAL_TYPE, REFINERY_DOCK }

var kind: Kind = Kind.GLOBAL_TYPE
var upgrade_id: StringName
var display_name := ""
var cost := 0
var build_time_ticks := 0
var paid_cost := 0
var elapsed_ticks := 0
var charge_accumulator := 0.0
var manually_paused := false
var ready := false
var target_refinery := 0


func progress_percent() -> float:
	return ProductionProgressScript.percent(ready, cost, paid_cost, build_time_ticks, elapsed_ticks)
