class_name UnitLocalAvoidance
extends RefCounted
## Continuous local steering layered on top of the discrete A* route.
##
## Pathfinding owns only the list of waypoints. This class owns the short-range
## geometry between them. Hard/soft geometry (terrain swept discs, elastic
## friendly separation, enemy swept discs, the non-holonomic chassis rate
## limiter) lives in `SteeringStabilizer` and is shared with the ORCA solver;
## this class is a thin facade over both, plus the stable entry point every
## white-box test exercises directly as `navigation.avoidance`.

const SteeringStabilizerScript := preload("res://scripts/units/navigation/ground/steering_stabilizer.gd")
const OrcaAvoidanceScript := preload("res://scripts/units/navigation/ground/orca_avoidance.gd")

var runtime_map = null
var stabilizer := SteeringStabilizerScript.new()
var orca := OrcaAvoidanceScript.new()
## Production default. The authored chassis TurnRate is still enforced by
## Unit.navigation_step() either way; this flag additionally lets the
## navigation side pre-rotate successive steering targets into a driven arc so
## a non-omnidirectional unit's course changes smoothly instead of snapping to
## a target its chassis cannot yet face. It exists only so a white-box test
## can force it false and isolate the raw ORCA output from that pre-rotation.
var turn_rate_stabilization_enabled := true


func setup(source_runtime_map) -> void:
	runtime_map = source_runtime_map
	stabilizer.setup(source_runtime_map)
	orca.setup(source_runtime_map, stabilizer)


func prewarm(pass_mask: int, terrain_mask: int) -> void:
	stabilizer.prewarm(pass_mask, terrain_mask)


func reset_agent(agent: Dictionary) -> void:
	agent["avoidance_direction"] = Vector3.ZERO
	agent["steering_turn_in_place"] = false
	agent["orca_velocity"] = Vector3.ZERO
	agent["_achieved_velocity"] = Vector3.ZERO
	agent["_squeeze_cooldown"] = 0


## Neighbour/terrain avoidance for one agent. Contract: `{velocity, enemies,
## friends}`. `nearby` is the candidate agent list (self included, filtered
## out below); `resolved` is unused by ORCA's two-phase tick, which keeps
## every neighbour at its start-of-tick position instead, but stays part of
## the contract for the facade's per-tick call site.
func resolve_velocity(
		agent: Dictionary,
		desired: Vector3,
		delta: float,
		nearby: Array,
		resolved: Dictionary
	) -> Dictionary:
	if desired.is_zero_approx():
		reset_agent(agent)
		return _empty_result()
	return orca.resolve_velocity(agent, desired, delta, nearby, resolved)


func stabilize_velocity(
		agent: Dictionary,
		proposed: Vector3,
		delta: float,
		nearby: Array,
		resolved: Dictionary
	) -> Vector3:
	if not turn_rate_stabilization_enabled:
		agent["steering_turn_in_place"] = false
		return proposed
	return stabilizer.stabilize_velocity(agent, proposed, delta, nearby, resolved)


func terrain_sweep_fraction(agent: Dictionary, displacement: Vector3) -> float:
	return stabilizer.terrain_sweep_fraction(agent, displacement)


func motion_is_passable(agent: Dictionary, displacement: Vector3) -> bool:
	return stabilizer.motion_is_passable(agent, displacement)


func terrain_pressure(agent: Dictionary) -> Vector3:
	return stabilizer.terrain_pressure(agent)


func enemy_sweep_fraction(
		agent: Dictionary,
		displacement: Vector3,
		nearby: Array,
		resolved: Dictionary
	) -> float:
	return stabilizer.enemy_sweep_fraction(agent, displacement, nearby, resolved)


func unit_sweep_fraction(
		agent: Dictionary,
		displacement: Vector3,
		nearby: Array,
		radius_factor := 1.0
	) -> float:
	return stabilizer.unit_sweep_fraction(agent, displacement, nearby, radius_factor)


func separation_velocity(agent: Dictionary, nearby: Array) -> Vector3:
	return stabilizer.separation_velocity(agent, nearby)


static func _empty_result() -> Dictionary:
	return {
		"velocity": Vector3.ZERO,
		"enemies": [] as Array[Node3D],
		"friends": [] as Array[Node3D],
	}
