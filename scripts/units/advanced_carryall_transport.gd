class_name AdvancedCarryallTransport
extends RefCounted
## Per-Advanced-Carryall pickup/drop state machine.
##
## The transport owns only transport state and weak references.  Unit owns
## scene-tree reparenting, navigation, flight clips and combat-facing flags
## through its small `transport_*` public surface; this keeps a carrier from
## reaching through Unit into its sibling modules.

const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const GameSettingsCatalogScript := preload("res://scripts/rules/game_settings_catalog.gd")
const GameSettingsScript := preload("res://scripts/rules/game_settings.gd")
const UnitFlightControllerScript := preload(
	"res://scripts/units/navigation/unit_flight_controller.gd"
)

enum State {
	IDLE,
	APPROACH_PICKUP,
	LAND_PICKUP,
	START_PICKUP,
	HOLD_PICKUP,
	LIFT_PICKUP,
	END_PICKUP,
	TAKEOFF_PICKUP,
	CARRYING,
	APPROACH_DROP,
	LAND_DROP,
	START_DROP,
	HOLD_DROP,
	LIFT_DROP,
	END_DROP,
	TAKEOFF_DROP,
	RECOVER_TAKEOFF,
}

const APPROACH_RADIUS := 0.65
const ALLIED_DOCK_SECONDS := 1.0
const DROP_DOCK_SECONDS := 1.0

var _owner: Node3D
var _state := State.IDLE
var _cargo_ref: WeakRef
var _pending_target_ref: WeakRef
var _cargo_parent_ref: WeakRef
var _drop_position := Vector3.INF
var _docking_elapsed := 0.0
var _docking_seconds := ALLIED_DOCK_SECONDS
var _game_settings_catalog := GameSettingsCatalogScript.new()


func configure(owner: Node3D) -> void:
	_owner = owner


func dispose() -> void:
	_owner = null
	_cargo_ref = null
	_pending_target_ref = null
	_cargo_parent_ref = null


func state() -> State:
	return _state


func state_name() -> StringName:
	return State.keys()[_state].to_snake_case()


func has_cargo() -> bool:
	return _cargo() != null


func can_offer_pickup() -> bool:
	return _state == State.IDLE and _cargo() == null and not is_command_locked()


func can_offer_drop() -> bool:
	return _state == State.CARRYING and _cargo() != null and not is_command_locked()


func cargo() -> Node3D:
	return _cargo()


func is_command_locked() -> bool:
	return _state in [
		State.LAND_PICKUP, State.START_PICKUP, State.HOLD_PICKUP, State.LIFT_PICKUP,
		State.END_PICKUP, State.TAKEOFF_PICKUP, State.LAND_DROP, State.START_DROP,
		State.HOLD_DROP, State.LIFT_DROP, State.END_DROP, State.TAKEOFF_DROP,
		State.RECOVER_TAKEOFF,
	]


## Land/Start/pause are physically on the ground.  Lift begins only after a
## pickup attach or a drop detach, which is the exact frame both carrier and
## cargo switch to their airborne combat contracts.
func counts_as_ground_target() -> bool:
	return _state in [
		State.LAND_PICKUP, State.START_PICKUP, State.HOLD_PICKUP,
		State.LAND_DROP, State.START_DROP, State.HOLD_DROP,
	]


## During final approach a player command cancels the transport order; once
## landing/docking has begun the craft is intentionally locked.  A loaded
## craft in CARRYING state remains a normal movable aircraft.
func accepts_regular_order() -> bool:
	if is_command_locked():
		return false
	if _state == State.APPROACH_PICKUP or _state == State.APPROACH_DROP:
		_abort_pending_operation()
	return true


func cancel_pending_order() -> bool:
	if _state != State.APPROACH_PICKUP and _state != State.APPROACH_DROP:
		return false
	_abort_pending_operation()
	return true


func can_pickup(target: Node3D) -> bool:
	return _owner != null and can_offer_pickup() \
		and target != null and is_instance_valid(target) \
		and target.has_method("can_be_picked_up_by") \
		and bool(target.call("can_be_picked_up_by", _owner))


func command_pickup(target: Node3D) -> bool:
	if not can_pickup(target):
		return false
	if not bool(target.call("reserve_for_transport", _owner)):
		return false
	_pending_target_ref = weakref(target)
	_drop_position = Vector3.INF
	_state = State.APPROACH_PICKUP
	_owner.call("transport_move_toward", target.global_position)
	return true


func can_drop_at(world_position: Vector3) -> bool:
	var carried := _cargo()
	return _owner != null and can_offer_drop() and _drop_point_is_valid(carried, world_position)


func command_drop(world_position: Vector3) -> bool:
	if not can_drop_at(world_position):
		return false
	_drop_position = world_position
	_state = State.APPROACH_DROP
	_owner.call("transport_move_toward", world_position)
	return true


func advance(delta: float) -> void:
	if _owner == null or not is_instance_valid(_owner):
		return
	if _state in [State.LAND_PICKUP, State.START_PICKUP, State.HOLD_PICKUP]:
		var pending := _pending_target()
		if pending == null or not _target_still_reserved(pending):
			_abort_pending_operation()
			return
	match _state:
		State.APPROACH_PICKUP:
			_advance_pickup_approach()
		State.LAND_PICKUP:
			# The target is deliberately not command-locked until we are directly
			# overhead.  It can therefore finish a movement step while the Land
			# clip plays; continuously follow its horizontal position and facing so
			# it can never be attached from a stale landing point.
			var landing_target := _pending_target()
			if landing_target == null or not _target_still_reserved(landing_target):
				_abort_pending_operation()
				return
			_owner.call("transport_track_pickup_landing", landing_target)
			if bool(_owner.call("flight_pickup_transition_finished")):
				var target := landing_target
				if target == null or not _target_still_reserved(target):
					_abort_pending_operation()
					return
				if _horizontal_distance_to(target.global_position) > APPROACH_RADIUS:
					# A moving target slipped beyond the docking aperture.  Return to
					# approach instead of locking and attaching at a distance.
					_state = State.APPROACH_PICKUP
					return
				_owner.call("transport_stop_for_docking")
				target.call("transport_lock_for_docking", _owner)
				_docking_seconds = _pickup_docking_seconds(target)
				_owner.call("flight_advance_pickup", UnitFlightControllerScript.Phase.PICKUP_START)
				_state = State.START_PICKUP
		State.START_PICKUP:
			if bool(_owner.call("flight_pickup_transition_finished")):
				_docking_elapsed = 0.0
				_state = State.HOLD_PICKUP
		State.HOLD_PICKUP:
			_advance_pickup_hold(delta)
		State.LIFT_PICKUP:
			if bool(_owner.call("flight_pickup_transition_finished")):
				_owner.call("flight_advance_pickup", UnitFlightControllerScript.Phase.PICKUP_END)
				_state = State.END_PICKUP
		State.END_PICKUP:
			if bool(_owner.call("flight_pickup_transition_finished")):
				_owner.call("flight_complete_pickup_sequence")
				_state = State.TAKEOFF_PICKUP
		State.TAKEOFF_PICKUP:
			if bool(_owner.call("flight_transport_takeoff_finished")):
				_state = State.CARRYING
		State.APPROACH_DROP:
			_advance_drop_approach()
		State.LAND_DROP:
			if bool(_owner.call("flight_pickup_transition_finished")):
				_owner.call("flight_advance_pickup", UnitFlightControllerScript.Phase.PICKUP_START)
				_state = State.START_DROP
		State.START_DROP:
			if bool(_owner.call("flight_pickup_transition_finished")):
				_docking_elapsed = 0.0
				_state = State.HOLD_DROP
		State.HOLD_DROP:
			_advance_drop_hold(delta)
		State.LIFT_DROP:
			if bool(_owner.call("flight_pickup_transition_finished")):
				_owner.call("flight_advance_pickup", UnitFlightControllerScript.Phase.PICKUP_END)
				_state = State.END_DROP
		State.END_DROP:
			if bool(_owner.call("flight_pickup_transition_finished")):
				_owner.call("flight_complete_pickup_sequence")
				_state = State.TAKEOFF_DROP
		State.TAKEOFF_DROP:
			if bool(_owner.call("flight_transport_takeoff_finished")):
				_state = State.IDLE
		State.RECOVER_TAKEOFF:
			if bool(_owner.call("flight_transport_takeoff_finished")):
				_state = State.CARRYING if _cargo() != null else State.IDLE


func on_owner_death() -> void:
	var carried := _cargo()
	if carried != null and carried.has_method("force_transport_death"):
		# Keep the normal death/corpse path, rather than queue_free(), so a cargo
		# killed in flight still gets the authored airborne corpse treatment.
		carried.call("force_transport_death", &"transport_destroyed")
	else:
		_abort_pending_operation()


## Called by a cargo Unit from its own death path before its corpse logic picks
## a parent.  Releasing it first prevents a corpse becoming a child that keeps
## following the surviving carrier.
func cargo_destroyed(cargo_unit: Node3D) -> void:
	if cargo_unit == null or cargo_unit != _cargo():
		return
	_release_cargo_to_original_parent(cargo_unit)
	_cargo_ref = null
	_cargo_parent_ref = null
	if _state == State.CARRYING:
		_state = State.IDLE
	elif _state != State.IDLE:
		_owner.call("transport_abort_docking_recover")
		_state = State.RECOVER_TAKEOFF


func _advance_pickup_approach() -> void:
	var target := _pending_target()
	if target == null or not _target_still_reserved(target):
		_abort_pending_operation()
		return
	_owner.call("transport_move_toward", target.global_position)
	if _horizontal_distance_to(target.global_position) > APPROACH_RADIUS:
		return
	_owner.call("transport_align_with", target)
	_owner.call("flight_begin_pickup_sequence", target.global_position)
	_state = State.LAND_PICKUP


func _advance_pickup_hold(delta: float) -> void:
	var target := _pending_target()
	if target == null or not _target_still_reserved(target):
		_abort_pending_operation()
		return
	_docking_elapsed += maxf(delta, 0.0)
	if _docking_elapsed < _docking_seconds:
		return
	_attach_cargo(target)
	_owner.call("flight_advance_pickup", UnitFlightControllerScript.Phase.PICKUP_LIFT)
	_state = State.LIFT_PICKUP


func _advance_drop_approach() -> void:
	var carried := _cargo()
	if carried == null or not _drop_point_is_valid(carried, _drop_position):
		# A map change may invalidate a previously legal point.  Keeping cargo
		# attached is safer than dropping into new geometry.
		_owner.call("transport_stop_for_docking")
		_state = State.CARRYING if carried != null else State.IDLE
		return
	_owner.call("transport_move_toward", _drop_position)
	if _horizontal_distance_to(_drop_position) > APPROACH_RADIUS:
		return
	_owner.call("transport_align_with_point", _drop_position)
	_owner.call("transport_stop_for_docking")
	_owner.call("flight_begin_pickup_sequence", _drop_position)
	_state = State.LAND_DROP


func _advance_drop_hold(delta: float) -> void:
	var carried := _cargo()
	if carried == null:
		_state = State.IDLE
		return
	_docking_elapsed += maxf(delta, 0.0)
	if _docking_elapsed < DROP_DOCK_SECONDS:
		return
	if not _drop_point_is_valid(carried, _drop_position):
		# The point was checked at click time and again on approach.  If another
		# body enters it while docking, recover with cargo rather than overlap.
		_owner.call("flight_complete_pickup_sequence")
		_state = State.RECOVER_TAKEOFF
		return
	_detach_cargo(carried)
	_owner.call("flight_advance_pickup", UnitFlightControllerScript.Phase.PICKUP_LIFT)
	_state = State.LIFT_DROP


func _attach_cargo(target: Node3D) -> void:
	_cargo_ref = weakref(target)
	_pending_target_ref = null
	_cargo_parent_ref = weakref(target.get_parent()) if target.get_parent() != null else null
	var offset := _cargo_anchor_offset(target)
	_owner.call("transport_attach_cargo", target, offset)


func _detach_cargo(carried: Node3D) -> void:
	var original_parent := _cargo_parent_ref.get_ref() as Node if _cargo_parent_ref != null else null
	_owner.call("transport_detach_cargo", carried, original_parent, _drop_position)
	_cargo_ref = null
	_cargo_parent_ref = null
	_drop_position = Vector3.INF


func _release_cargo_to_original_parent(carried: Node3D) -> void:
	var original_parent := _cargo_parent_ref.get_ref() as Node if _cargo_parent_ref != null else null
	_owner.call("transport_release_destroyed_cargo", carried, original_parent)


func _abort_pending_operation() -> void:
	var pending := _pending_target()
	if pending != null and pending.has_method("transport_unlock_after_abort"):
		pending.call("transport_unlock_after_abort", _owner)
	_pending_target_ref = null
	_docking_elapsed = 0.0
	if is_command_locked():
		_owner.call("transport_abort_docking_recover")
		_state = State.RECOVER_TAKEOFF
	elif _cargo() == null:
		_state = State.IDLE


func _pending_target() -> Node3D:
	var target: Variant = _pending_target_ref.get_ref() if _pending_target_ref != null else null
	return target as Node3D if target != null and is_instance_valid(target) else null


func _cargo() -> Node3D:
	var carried: Variant = _cargo_ref.get_ref() if _cargo_ref != null else null
	return carried as Node3D if carried != null and is_instance_valid(carried) else null


func _target_still_reserved(target: Node3D) -> bool:
	return target.has_method("is_reserved_for_transport") \
		and bool(target.call("is_reserved_for_transport", _owner)) \
		and target.has_method("can_be_picked_up_by") \
		and bool(target.call("can_be_picked_up_by", _owner))


func _horizontal_distance_to(world_position: Vector3) -> float:
	var offset := world_position - _owner.global_position
	offset.y = 0.0
	return offset.length()


func _pickup_docking_seconds(target: Node3D) -> float:
	if not bool(_owner.call("transport_target_is_enemy", target)):
		return ALLIED_DOCK_SECONDS
	var settings = _game_settings_catalog.settings()
	var ticks := int(settings.advanced_carryall_pickup_enemy_delay_ticks) \
		if settings != null and &"advanced_carryall_pickup_enemy_delay_ticks" in settings \
		else GameSettingsScript.DEFAULT_ADV_CARRYALL_PICKUP_ENEMY_DELAY_TICKS
	return ALLIED_DOCK_SECONDS + float(ticks) / CombatRulesScript.TICKS_PER_SECOND


func _drop_point_is_valid(carried: Node3D, world_position: Vector3) -> bool:
	return carried != null and world_position.is_finite() \
		and bool(_owner.call("transport_can_drop_cargo_at", carried, world_position))


func _cargo_anchor_offset(target: Node3D) -> Vector3:
	var carrier_extents: Vector2 = _owner.call("transport_vertical_bounds") as Vector2
	var cargo_extents: Vector2 = target.call("transport_vertical_bounds") as Vector2 \
		if target.has_method("transport_vertical_bounds") else Vector2(-0.5, 0.5)
	# Root transforms sit at different authored heights: a vehicle commonly has
	# its origin at the ground, not its centre.  Set cargo root Y from exact
	# carrier-bottom/cargo-top extents so visible bounds touch only at the gap.
	return Vector3(0.0, carrier_extents.x - cargo_extents.y - 0.05, 0.0)
