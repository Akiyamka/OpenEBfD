class_name MapSpiceHazard
extends RefCounted

## The damage field a spice bloom leaves behind when it goes off. For
## HAZARD_DURATION_TICKS the cells the bloom seeded hurt any infantry standing
## in them, on a fixed pulse; vehicles are unaffected.
##
## The rate is authored data, not a constant here: it is the damage of the
## SpicePuff bullet in the rules catalog.
##
## Both the pulse timer and the lifetime timer used to be Timer nodes parented
## under the layer's mounds root. Phase 1 (docs/architecture/network-multiplayer.md,
## decision 4) bans Timers from driving simulation state -- one advances on
## engine frame time, where no snapshot or checksum can see it -- so each job
## now carries integer tick countdowns advanced by sim_tick(). cancel() and
## cancel_all() stay idempotent; the layer still calls cancel_all() when it
## drops its visuals.

const CombatDefinitionCatalogScript := preload("res://scripts/combat/combat_definition_catalog.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

## The hazard's whole lifetime, in simulation ticks: 250 at MatchClock's 25 Hz
## is exactly the ten seconds this always lasted.
const HAZARD_DURATION_TICKS := 250
## The pulse cadence had to change, and this is the one number in this file
## that is not a straight translation.
##
## It used to be four pulses a second (TICK_SECONDS = 0.25). At 25 Hz that is
## 6.25 simulation ticks -- not a whole number, so it cannot survive the move
## to an integer tick at all. Five a second is exactly five ticks, and 250
## divides by it evenly, so the entire schedule comes out in whole numbers
## with nothing rounded anywhere.
##
## What that costs and what it does not: the damage now arrives in 50 smaller
## helpings instead of 40 larger ones, but the total over a full hazard is
## damage_per_second() * 50 * 0.2s == damage_per_second() * 10s, identical to
## the old 40 * 0.25s, and the hazard still lasts exactly ten seconds. The two
## things a player experiences -- how long it hurts and how much it takes off
## -- are unchanged; only the granularity of the ticking moved, and it moved
## finer. tests/maps/run.gd pins that equality rather than leaving it as a
## claim in this comment.
const TICKS_PER_HAZARD_PULSE := 5
const HAZARD_PULSE_COUNT := HAZARD_DURATION_TICKS / TICKS_PER_HAZARD_PULSE
const SPICE_PUFF_ID := &"SpicePuff"
const DEFAULT_DAMAGE := 10.0

static var _combat_definition_catalog := CombatDefinitionCatalogScript.new()

var _layer: MapSpiceLayer
var _active: Dictionary = {}


func configure(layer: MapSpiceLayer) -> void:
	_layer = layer


## Raises the hazard over the cells a spread job seeded. Silently does nothing
## when the bloom's mound is already gone -- the visual is anchored to it.
func start(source_cell: Vector2i, spread_cells: Array) -> void:
	cancel(source_cell)
	var mound: Variant = _layer.mound_node(source_cell)
	var mounds_root := _layer.mounds_root()
	if not is_instance_valid(mound) or not is_instance_valid(mounds_root):
		return
	var navigation_grid := _layer.nav_grid()
	var affected_cells := {}
	var local_points := PackedVector3Array()
	for entry: Dictionary in spread_cells:
		if int(entry.get("amount", 0)) <= 0:
			continue
		var cell := entry.get("cell", Vector2i(-1, -1)) as Vector2i
		if not _layer.cell_is_valid(cell):
			continue
		affected_cells[cell] = true
		var point := navigation_grid.grid_to_world(cell)
		point.y = _layer.terrain_height_at(Vector2(point.x, point.z))
		local_points.append(point - mound.global_position)
	if affected_cells.is_empty():
		return

	var cell_size := navigation_grid.cell_size()
	mound.start_spread_hazard(local_points, maxf(minf(cell_size.x, cell_size.y) * 1.35, 0.25))
	_active[source_cell] = {
		"cells": affected_cells,
		"damage": pulse_damage(),
		"pulse_ticks_remaining": TICKS_PER_HAZARD_PULSE,
		"end_ticks_remaining": HAZARD_DURATION_TICKS,
		"remaining_delayed_pulses": HAZARD_PULSE_COUNT - 1,
	}
	# The first pulse lands with the bloom rather than one interval later,
	# which is why the delayed count above is one short of the total.
	_apply_damage(source_cell)


func cancel(source_cell: Vector2i) -> void:
	_active.erase(source_cell)
	var mound: Variant = _layer.mound_node(source_cell)
	if is_instance_valid(mound):
		mound.stop_spread_hazard()


func cancel_all() -> void:
	for source_cell: Vector2i in _active.keys():
		cancel(source_cell)


## Damage per second, read from the SpicePuff bullet the original game uses for
## this effect. Falls back to DEFAULT_DAMAGE when the rules catalog has no such
## bullet, so a partial rules set still produces a hazard rather than a no-op.
func damage_per_second() -> float:
	var spice_puff := _combat_definition_catalog.bullet(SPICE_PUFF_ID)
	return maxf(
		spice_puff.damage if spice_puff != null else DEFAULT_DAMAGE,
		0.0
	)


## Returns how many units were hit, which is what the maps suite asserts on.
func damage_infantry_in_cells(cells: Dictionary, damage: float, units: Array) -> int:
	var navigation_grid := _layer.nav_grid() if _layer != null else null
	if cells.is_empty() or damage <= 0.0 or navigation_grid == null:
		return 0
	var damaged := 0
	for unit: Variant in units:
		if not is_instance_valid(unit) or not unit.has_method("take_damage"):
			continue
		var unit_definition: Resource = unit.get("unit_definition")
		if unit_definition == null or not unit_definition.infantry:
			continue
		var world_position: Vector3 = unit.global_position if unit.is_inside_tree() else unit.position
		if not cells.has(navigation_grid.world_to_grid(world_position)):
			continue
		unit.take_damage(damage)
		damaged += 1
	return damaged


## Damage delivered by one pulse: the authored per-second rate spread over the
## real time one pulse interval covers, so the rate itself is what the rules
## data controls and the cadence above only decides how it is parcelled out.
func pulse_damage() -> float:
	return damage_per_second() * float(TICKS_PER_HAZARD_PULSE) * MatchClockScript.SECONDS_PER_TICK


## Advances every active hazard by one simulation tick: one step of its
## lifetime countdown, and one of its pulse countdown. Called from
## MapSpiceLayer.sim_tick().
##
## Same snapshot-and-re-check shape as MapSpiceSpread.sim_tick(), and for the
## same reason: cancel() erases from _active, so a job that expires here would
## otherwise be mutating the dictionary this loop is walking.
func sim_tick() -> void:
	for source_cell: Vector2i in _active.keys():
		if not _active.has(source_cell):
			continue
		var hazard := _active[source_cell] as Dictionary
		var end_remaining := int(hazard.get("end_ticks_remaining", 0)) - 1
		if end_remaining <= 0:
			cancel(source_cell)
			continue
		hazard["end_ticks_remaining"] = end_remaining
		var pulse_remaining := int(hazard.get("pulse_ticks_remaining", 0)) - 1
		var delayed := int(hazard.get("remaining_delayed_pulses", 0))
		if pulse_remaining > 0 or delayed <= 0:
			hazard["pulse_ticks_remaining"] = maxi(pulse_remaining, 0)
			_active[source_cell] = hazard
			continue
		hazard["pulse_ticks_remaining"] = TICKS_PER_HAZARD_PULSE
		hazard["remaining_delayed_pulses"] = delayed - 1
		_active[source_cell] = hazard
		_apply_damage(source_cell)


func _apply_damage(source_cell: Vector2i) -> int:
	var hazard := _active.get(source_cell, {}) as Dictionary
	if hazard.is_empty():
		return 0
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return 0
	# "sim_units", not "units": this runs from sim_tick() (MapSpiceLayer.sim_tick(),
	# itself walked by Match._advance_simulation_tick()), so damaging an
	# infantry unit here is a simulation decision and must not reach a unit
	# the tick does not yet simulate.
	return damage_infantry_in_cells(
		hazard.get("cells", {}) as Dictionary,
		float(hazard.get(
			"damage",
			DEFAULT_DAMAGE * float(TICKS_PER_HAZARD_PULSE) * MatchClockScript.SECONDS_PER_TICK
		)),
		tree.get_nodes_in_group(&"sim_units")
	)
