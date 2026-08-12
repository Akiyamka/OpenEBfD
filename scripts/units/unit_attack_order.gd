class_name UnitAttackOrder
extends RefCounted

## The mobile shooter's explicit attack order: what was ordered, and the
## pursuit that closes the distance to it. A Node target is tracked until it
## dies; a Vector3 stays a fixed attack-ground coordinate.
##
## Deliberately not shared with Building, which has its own static driver:
## everything below is about moving — repath cadence, perch selection, backing
## a rejected route toward the unit. Only target *acquisition* is common, and
## that already lives in CombatTargetAcquisition.
##
## Holds no model nodes: the target is a weak reference to another entity.

const ATTACK_REPATH_INTERVAL_SECONDS := 0.25
const ATTACK_REPATH_DISTANCE := 0.5
## How long a squadmate must sit on this unit's muzzle line before the unit
## walks off it. A friendly crossing the line is transient and must not start a
## reposition; a line that stays blocked is a genuinely stacked firing arc, and
## standing there means either never firing or shooting a squadmate in the back.
const FRIENDLY_BLOCK_REPOSITION_SECONDS := 1.0

var _unit: CharacterBody3D
var _active := false
var _is_ground := false
var _ground_position := Vector3.INF
var _target_ref: WeakRef
var _is_pursuing := false
var _repath_remaining := 0.0
var _last_path_position := Vector3.INF
var _pursuit_destination := Vector3.INF
var _pursuit_rejected := false
## Horizontal bearing from the target toward this unit's slot on the group's
## firing arc, assigned per command by AttackArcAllocator. Zero means "no arc
## was assigned" (a lone unit, an autonomous engagement) and the perch search
## falls back to its previous target-centred behaviour.
var _arc_direction := Vector3.ZERO
var _friendly_block_seconds := 0.0
## Walking to a clear slot because a squadmate is on the line. Suppresses the
## per-frame stop_pursuit() that would otherwise cancel the move immediately.
var _clearing_line := false


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func dispose() -> void:
	clear()
	_unit = null


func is_active() -> bool:
	return _active


func is_ground() -> bool:
	return _is_ground


func is_pursuing() -> bool:
	return _is_pursuing


func target() -> Variant:
	if not _active:
		return null
	if _is_ground:
		return _ground_position
	return _target_ref.get_ref() if _target_ref != null else null


## Records the order. The eligibility gate (can any active turret target this?)
## and the weapon bookkeeping around it belong to the facade; this is the
## state the order itself consists of.
func begin(target_or_position: Variant) -> void:
	_active = true
	_is_ground = target_or_position is Vector3
	_ground_position = target_or_position if _is_ground else Vector3.INF
	_target_ref = null if _is_ground else weakref(target_or_position as Object)
	_reset_pursuit()


## Returns true when there was an order to drop, so the caller knows whether
## to announce the change.
func clear() -> bool:
	var had_order := _active
	_active = false
	_is_ground = false
	_ground_position = Vector3.INF
	_target_ref = null
	_reset_pursuit()
	return had_order


## The bearing this unit should engage from, as a horizontal vector pointing
## from the target toward its slot. Assigned right after the order by
## UnitNavigationSystem.assign_attack_arcs(); a unit that never receives one
## keeps engaging from wherever it approached.
func set_arc_direction(direction: Vector3) -> void:
	var flattened := direction
	flattened.y = 0.0
	_arc_direction = flattened.normalized() if flattened.length_squared() > 0.0001 \
		else Vector3.ZERO


## Called when the unit is close enough to shoot: it stops where it stands
## rather than continuing to the perch it was walking to, and claims the spot so
## arriving squadmates steer around it instead of shoving it off mid-clip.
func stop_pursuit() -> void:
	if _is_pursuing:
		_unit.stop_at_current_position()
		_is_pursuing = false
	_set_firing_anchor(true)


## Per-frame handling for a unit that is already in range. It normally just
## stands and shoots -- but a muzzle line that stays blocked by a squadmate is
## not solved by standing there, so after FRIENDLY_BLOCK_REPOSITION_SECONDS the
## unit walks to a clear slot on the arc instead. It stays in range throughout,
## so its weapons keep firing during the sidestep.
func hold_firing_position(
	friendly_blocked: bool, target_world_position: Vector3, pursuit_turret, delta: float
) -> void:
	if friendly_blocked:
		_friendly_block_seconds += delta
	else:
		_friendly_block_seconds = 0.0
		_clearing_line = false
	if _clearing_line:
		if _unit.has_active_move_order():
			# Let the clearing move finish. advance_pursuit's own en-route gate
			# turns this into a no-op unless the target moved far enough to
			# invalidate the slot it is walking to.
			advance_pursuit(target_world_position, pursuit_turret, delta)
			return
		_clearing_line = false
	if friendly_blocked and _friendly_block_seconds >= FRIENDLY_BLOCK_REPOSITION_SECONDS:
		_friendly_block_seconds = 0.0
		_clearing_line = true
		# The unit has been standing, so the approach's repath timer and last
		# path position are stale. Clear both to force a fresh perch search.
		_repath_remaining = 0.0
		_last_path_position = Vector3.INF
		advance_pursuit(target_world_position, pursuit_turret, delta)
		return
	stop_pursuit()


## Walks toward a position from which the ordered target can actually be hit,
## re-planning at most every ATTACK_REPATH_INTERVAL_SECONDS and whenever the
## target has moved far enough to invalidate the last route.
func advance_pursuit(
	target_world_position: Vector3, primary_turret, delta: float
) -> void:
	_repath_remaining = maxf(_repath_remaining - delta, 0.0)
	var target_moved := not _last_path_position.is_finite() \
		or _last_path_position.distance_to(target_world_position) >= ATTACK_REPATH_DISTANCE
	var route_unreachable: bool = _unit.navigation_route_is_unreachable()
	if target_moved:
		_pursuit_destination = Vector3.INF
		_pursuit_rejected = false
		route_unreachable = false
	if _repath_remaining > 0.0 \
	or (
		_is_pursuing
		and not target_moved
		and not route_unreachable
		and _unit.has_active_move_order()
	):
		return
	_is_pursuing = true
	_set_firing_anchor(false)
	_last_path_position = target_world_position
	_repath_remaining = ATTACK_REPATH_INTERVAL_SECONDS
	var pursuit_position := target_world_position
	var horizontal_offset := target_world_position - _unit.global_position
	horizontal_offset.y = 0.0
	var preferred_range := float(primary_turret.maximum_range_world()) * 0.8 \
		if primary_turret != null else 0.0
	var reachable_position := Vector3.INF
	if primary_turret != null:
		var maximum_range := float(primary_turret.maximum_range_world())
		# First choice: a perch on this unit's own slot of the firing arc that
		# can see the target AND does not put the shot through a squadmate.
		reachable_position = _unit.navigation_reachable_firing_position(
			target_world_position, maximum_range, _arc_direction, preferred_range,
			_line_of_fire_probe(primary_turret, true)
		)
		if not reachable_position.is_finite():
			# A friendly on the line is transient, so failing that search must
			# not cancel the approach or -- worse -- trip the "the target is
			# shielded from this side" branch below. Retry on line of fire
			# alone; hold_firing_position() takes another run at clearing the
			# line once the unit is actually standing there.
			reachable_position = _unit.navigation_reachable_firing_position(
				target_world_position, maximum_range, _arc_direction, preferred_range,
				_line_of_fire_probe(primary_turret, false)
			)
		if not reachable_position.is_finite():
			var any_perch: Vector3 = _unit.navigation_reachable_attack_position(
				target_world_position, maximum_range
			)
			if any_perch.is_finite():
				# The search covered every reachable cell within weapon range and
				# none of them can see the target: the obstacle shields it from
				# this side entirely. Hold instead of grinding into it.
				_unit.stop_at_current_position()
				_is_pursuing = false
				_pursuit_destination = Vector3.INF
				return
	if reachable_position.is_finite():
		pursuit_position = reachable_position
	elif preferred_range > 0.0:
		# Navigate to a firing position rather than the target coordinate itself.
		# An attack-ground point on top of a cliff may be unreachable to a ground
		# unit even though a position in front of it is a valid artillery perch.
		# If that first perch still cannot satisfy the elevation limits, halve
		# the remaining distance on the next arrival and continue approaching.
		var remaining_distance := minf(preferred_range, horizontal_offset.length() * 0.5)
		pursuit_position = target_world_position \
			- horizontal_offset.normalized() * remaining_distance
	if (
		not reachable_position.is_finite()
		and (route_unreachable or _pursuit_rejected)
		and _pursuit_destination.is_finite()
	):
		# The requested perch landed on disconnected terrain (commonly the red
		# face or the separately connected top of a cliff). Back it toward the
		# unit until the navigation grid accepts a firing position on this side.
		pursuit_position = _unit.global_position.lerp(_pursuit_destination, 0.5)
	_pursuit_destination = pursuit_position
	var move_issued: bool = _unit.issue_attack_move(pursuit_position)
	_pursuit_rejected = not move_issued
	_is_pursuing = move_issued


## Accepts only perches whose muzzle would see the ordered target. The probe
## samples terrain height at the candidate because navigation cells carry the
## map floor rather than the elevation the unit will actually stand at.
##
## `avoid_friendly_lines` additionally rejects a perch whose shot would pass
## through a squadmate first. Kept optional because the two questions have
## different failure modes: an obstacle shielding the target is permanent and
## means "stop closing", while a friendly on the line is transient and means
## "prefer somewhere else, but keep going if there is nowhere else".
func _line_of_fire_probe(primary_turret, avoid_friendly_lines := false) -> Callable:
	var attack_target: Variant = target()
	if primary_turret == null or attack_target == null:
		return Callable()
	var muzzle_origin: Vector3 = primary_turret.muzzle_origin()
	var muzzle_height := maxf(muzzle_origin.y - _unit.global_position.y, 0.0) \
		if muzzle_origin.is_finite() else 0.0
	var unit := _unit
	return func(candidate: Vector3) -> bool:
		var hit: Dictionary = unit.flight_terrain_hit_at(candidate)
		var ground: Vector3 = hit["position"] if not hit.is_empty() else candidate
		var origin := ground + Vector3.UP * muzzle_height
		if not primary_turret.has_line_of_fire_from(origin, attack_target, unit):
			return false
		return not avoid_friendly_lines \
			or not primary_turret.friendly_blocks_fire_from(origin, attack_target, unit)


## Pushes the navigation agent's firing-anchor flag. Deliberately unconditional
## rather than transition-guarded: several unrelated paths clear the agent-side
## flag on their own (a cancelled order, `stop()`, a fresh command), and a
## cached "already anchored" here would leave the two silently out of step. The
## facade's own set_firing_anchor() is where the redundant write is dropped.
func _set_firing_anchor(active: bool) -> void:
	if _unit != null and is_instance_valid(_unit):
		_unit.set_navigation_firing_anchor(active)


func _reset_pursuit() -> void:
	_is_pursuing = false
	_repath_remaining = 0.0
	_last_path_position = Vector3.INF
	_pursuit_destination = Vector3.INF
	_pursuit_rejected = false
	_arc_direction = Vector3.ZERO
	_friendly_block_seconds = 0.0
	_clearing_line = false
	_set_firing_anchor(false)
