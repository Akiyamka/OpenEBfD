class_name BuildingOrder
extends RefCounted

const ProductionProgressScript := preload("res://scripts/buildings/production_progress.gd")

var building_id: StringName
var display_name := ""
var cost := 0
var build_time_ticks := 0
var paid_cost := 0
var elapsed_ticks := 0
var charge_accumulator := 0.0
var manually_paused := false
var ready := false


func progress_percent() -> float:
	return ProductionProgressScript.percent(ready, cost, paid_cost, build_time_ticks, elapsed_ticks)
