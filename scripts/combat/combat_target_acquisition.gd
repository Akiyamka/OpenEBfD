class_name CombatTargetAcquisition
extends RefCounted

## Picks what an idle turret shoots at on its own: the nearest live enemy in
## range with a line of fire, cached per weapon and re-picked at most every
## AUTO_TARGET_REFRESH_SECONDS.
##
## Shared by Unit and BuildingCombat — this is the one part of their combat
## drivers that was byte-identical, everything around it (pursuit and repath
## for a mobile shooter, the popup transition for a static one) is not.
##
## Holds no model nodes: the cache is weak references to other entities, so a
## target freed between two ticks simply reads back as null.

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")

const AUTO_TARGET_REFRESH_SECONDS := 0.25
## How far off the hull's own heading a target may sit and still count as
## "already covered" by a weapon that has no yaw of its own. Deliberately
## coarser than TurretDefinition.acceptable_yaw, which is measured from a
## muzzle that can sit well off the hull centreline: a Devastator facing its
## target dead-on still reads a double-digit bearing error at its outboard
## plasma barrels.
const HULL_BEARING_TOLERANCE_DEGREES := 5.0

## What a weapon without its own yaw servo is allowed to assume about the hull
## while picking a target of its own. Such a weapon aims only by turning the
## whole shooter, so whether a target is reachable is a question about the hull,
## not about the turret.
enum HullAim {
	## The hull is unavailable: a yaw-less weapon cannot auto-acquire at all.
	## Static shooters (BuildingCombat) and units under a move order stay here.
	NONE,
	## The hull is spoken for, but a target it already happens to face is fair
	## game. The caller does not turn.
	ALIGNED_ONLY,
	## The hull is free and the caller turns it onto whatever this weapon picks.
	TURN,
}

var _shooter: Node3D
var _targets: Dictionary = {}
var _cooldowns: Dictionary = {}


func configure(shooter: Node3D) -> void:
	_shooter = shooter


func dispose() -> void:
	clear()
	_shooter = null


func clear() -> void:
	_targets.clear()
	_cooldowns.clear()


func forget(weapon_index: int) -> void:
	_targets.erase(weapon_index)
	_cooldowns.erase(weapon_index)


func advance(delta: float) -> void:
	for weapon_index: Variant in _cooldowns.keys():
		var remaining := maxf(float(_cooldowns[weapon_index]) - maxf(delta, 0.0), 0.0)
		if remaining <= 0.0:
			_cooldowns.erase(weapon_index)
		else:
			_cooldowns[weapon_index] = remaining


## The cached target while it stays usable, otherwise a fresh scan — but only
## once the per-weapon cooldown has expired, so a shooter with nothing to
## shoot at does not walk both entity groups every frame.
func target_for(turret, hull_aim: HullAim = HullAim.NONE) -> Variant:
	if turret == null or _shooter == null:
		return null
	var weapon_index: int = turret.weapon_index()
	var cached_ref: WeakRef = _targets.get(weapon_index) as WeakRef
	var cached: Variant = cached_ref.get_ref() if cached_ref != null else null
	if is_usable(turret, cached, hull_aim):
		return cached
	if float(_cooldowns.get(weapon_index, 0.0)) > 0.0:
		return null
	_cooldowns[weapon_index] = AUTO_TARGET_REFRESH_SECONDS
	var tree := _shooter.get_tree()
	if tree == null:
		return null

	var best_target: Node3D = null
	var best_distance := INF
	var candidates: Array[Node] = []
	# "sim_units"/"sim_buildings", not "units"/"buildings": choosing what to
	# shoot is a simulation decision -- the shot it leads to changes health,
	# which no view/UI reader does -- even though this call currently still
	# reaches here from UnitCombat.advance()/BuildingCombat.advance() on frame
	# delta rather than the tick (a separate, already-recorded gap; see
	# docs/architecture/network-multiplayer.md's "turret aim and target
	# acquisition ... unmoved" notes). Reading "units"/"buildings" here would
	# let a shooter target-acquire an entity C6b's admission queue has not yet
	# let the tick simulate.
	candidates.append_array(tree.get_nodes_in_group(&"sim_units"))
	candidates.append_array(tree.get_nodes_in_group(&"sim_buildings"))
	for candidate_node in candidates:
		if not candidate_node is Node3D or candidate_node == _shooter:
			continue
		var candidate := candidate_node as Node3D
		if not is_usable(turret, candidate, hull_aim):
			continue
		var distance := _shooter.global_position.distance_squared_to(candidate.global_position)
		# Instance id breaks ties so two equidistant candidates resolve the
		# same way on every shooter, instead of by group iteration order.
		if distance < best_distance \
		or (
			is_equal_approx(distance, best_distance)
			and best_target != null
			and candidate.get_instance_id() < best_target.get_instance_id()
		):
			best_distance = distance
			best_target = candidate
	if best_target == null:
		_targets.erase(weapon_index)
		return null
	_targets[weapon_index] = weakref(best_target)
	return best_target


func is_usable(turret, target: Variant, hull_aim: HullAim = HullAim.NONE) -> bool:
	if not target is Node3D or not is_instance_valid(target):
		return false
	var candidate := target as Node3D
	if not CombatTargetScript.is_alive(candidate) \
	or not candidate.has_method("is_enemy_of") \
	or not bool(candidate.call("is_enemy_of", _shooter.owner_player_id)):
		return false
	if turret.target_range(candidate) != CombatTurretScript.TargetRange.IN_RANGE:
		return false
	var target_world_position := CombatTargetScript.position_of(
		candidate, _shooter.global_position
	)
	if not target_world_position.is_finite():
		return false
	return hull_allows(turret, target_world_position, hull_aim) \
		and turret.has_line_of_fire(candidate, _shooter)


## requires_hull_turn_for() answers "can this weapon's own servo get there", and
## for a weapon with no servo at all the answer is always no. That verdict is
## only the end of the story while the hull is off limits; when the caller may
## turn it -- or when it already points the right way -- such a weapon can hold
## a target like any other.
func hull_allows(turret, target_world_position: Vector3, hull_aim: HullAim) -> bool:
	if not bool(turret.requires_hull_turn()):
		return not turret.requires_hull_turn_for(target_world_position)
	match hull_aim:
		HullAim.TURN:
			return true
		HullAim.ALIGNED_ONLY:
			return hull_bears_on(_shooter, target_world_position)
		_:
			return false


## Whether the shooter's own heading already points close enough at a position
## for a yaw-less weapon bolted to it to be considered on target.
static func hull_bears_on(shooter: Node3D, world_position: Vector3) -> bool:
	if shooter == null or not is_instance_valid(shooter):
		return false
	var offset := world_position - shooter.global_position
	offset.y = 0.0
	if offset.length_squared() <= 0.000001:
		return true
	var facing := SpatialOrientationScript.world_forward(shooter)
	facing.y = 0.0
	if facing.length_squared() <= 0.000001:
		return false
	var bearing_error := absf(
		facing.normalized().signed_angle_to(offset.normalized(), Vector3.UP)
	)
	return bearing_error <= deg_to_rad(HULL_BEARING_TOLERANCE_DEGREES)
