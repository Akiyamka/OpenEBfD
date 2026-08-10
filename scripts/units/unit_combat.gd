extends RefCounted

## Unit's combat engine: attack orders, turret engagement, weapon-target
## bookkeeping and the authored fire-sequence lifecycle. Extracted from
## unit.gd, modeled directly on scripts/buildings/building_combat.gd --
## configure()/advance()/detach_model()/dispose(), no class_name, signals
## raised through owner callbacks (_emit_attack_order_changed /
## _emit_weapon_fired, see unit.gd).
##
## Unlike BuildingCombat -- one static turret, a popup transition, a single
## AuthoredFireController the facade advances itself -- a unit fires from
## several turrets independently and can layer a synthesized "fire while
## moving" overlay animation over the ordinary Move clip. Weapon-indexed state
## therefore stays keyed by turret rather than singular, and
## AuthoredFireController is used here as a stateless-per-call helper against
## the owned _weapon_fire_sequences dictionary rather than through its own
## try_start()/advance()/cancel() convenience API (that API is BuildingCombat's
## shape, not this one's).

const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatTargetAcquisitionScript := preload(
	"res://scripts/combat/combat_target_acquisition.gd"
)
const AuthoredFireControllerScript := preload(
	"res://scripts/combat/authored_fire_controller.gd"
)
const AuthoredReloadSoundScript := preload(
	"res://scripts/combat/authored_reload_sound.gd"
)
const UnitAttackOrderScript := preload("res://scripts/units/unit_attack_order.gd")
const UnitFireOverlayScript := preload("res://scripts/units/unit_fire_overlay.gd")
const UnitTerrainAlignmentScript := preload(
	"res://scripts/units/unit_terrain_alignment.gd"
)

## Rules.txt stores TurnRate in radians per movement update. Navigation runs at
## 20 fixed updates per second, so use the same cadence for the hull-turn
## adjustment below. Mirrors Unit.RULE_MOVEMENT_UPDATES_PER_SECOND, which stays
## on the facade because tests/match/demo_boot_run.gd reads it as Unit.<const>.
const RULE_MOVEMENT_UPDATES_PER_SECOND := UnitTerrainAlignmentScript.MOVEMENT_UPDATES_PER_SECOND
## Converted XBF tracks use a 20 Hz timeline, while the original firing
## cadence measured from ReloadCount and Fire clip frame counts is 25 Hz.
## Fire clips therefore traverse the baked timeline at 25/20 speed.
const BAKED_MODEL_FRAMES_PER_SECOND := 20.0
const RULE_COMBAT_TICKS_PER_SECOND := CombatRulesScript.TICKS_PER_SECOND
const FIRE_ANIMATION_SPEED_SCALE := (
	RULE_COMBAT_TICKS_PER_SECOND / BAKED_MODEL_FRAMES_PER_SECOND
)
const FIRE_ANIMATION_PREFIX := "Fire_"
## Weapons reaching less than two tiles (Rules.txt MaxRange, converted by
## CombatBullet.RULE_TILE_WORLD_SPAN) are hand-to-hand: IMADVSardaukar's knife
## reaches one tile against the same soldier's ten-tile rifle. They never decide
## how far the unit walks, see _pursuit_attack_turret.
const MELEE_RANGE_WORLD := 2.0 * CombatBulletScript.RULE_TILE_WORLD_SPAN
const FIRE_EVENT_EPSILON := 0.0001
## Deployed-mode idle clips (Kindjal only) mirror the travel-mode Idle_*
## naming so the same random-variant machinery in _idle_animations applies.
## The single canonical deployed-mode fire clip after the converter-stage
## rename (see converters/model_bake_builder.gd CLIP_NAME_OVERRIDES).
const DEPLOYED_FIRE_ANIMATION := &"Deployed_Fire"

## What decides whether a turret is on target this frame. A turret normally
## aims itself; one that has no yaw of its own is aimed by turning the whole
## unit, so the hull turn already performed is the answer and asking the
## turret again would only report its unchanged local pose.
enum AimSource {
	TURRET,
	HULL_ON_TARGET,
	HULL_TURNING,
}

var _owner: CharacterBody3D
var _weapon_targets: Dictionary = {}
var _target_acquisition := CombatTargetAcquisitionScript.new()
var _moving_fire_weapons: Dictionary = {}
var _fire_overlay := UnitFireOverlayScript.new()
var _attack_order := UnitAttackOrderScript.new()
var _issuing_attack_move := false
var _weapon_fire_sequences: Dictionary = {}
var _authored_fire_controller := AuthoredFireControllerScript.new()


func configure(owner: CharacterBody3D) -> void:
	_owner = owner
	_target_acquisition.configure(owner)
	_attack_order.configure(owner)
	_fire_overlay.configure(owner)
	if not _authored_fire_controller.weapon_fired.is_connected(_on_authored_weapon_fired):
		_authored_fire_controller.weapon_fired.connect(_on_authored_weapon_fired)


func advance(delta: float) -> void:
	if _owner == null:
		return
	_target_acquisition.advance(delta)
	_advance_attack_order(delta)
	_advance_fire_sequences(delta)
	if (
		not _attack_order.is_active()
		and _weapon_targets.is_empty()
		and _moving_fire_weapons.is_empty()
	):
		# Movement/idle animations key some of the same model pivots as combat.
		# Keep the combat angle authoritative after an order ends: first return
		# to the authored forward pose, then periodically scan its forward arc.
		# Without this, the animation snaps the visible pivot to rest while
		# current_yaw stays cached, and the stale angle reappears on the next
		# attack order.
		# Only turrets live in the current deploy state: an inactive turret's
		# pivot is owned by its own deploy/undeploy/idle animation, not combat.
		for turret in _active_turrets():
			_scan_turret_if_idle(turret, delta)


## Lifecycle protocol, required of every module that caches a reference into
## the owner's model subtree: detach_model() drops those references and
## dispose() drops the rest. In-flight fire sequences and the fire-while-
## moving overlay AnimationPlayers are such references, so both must be
## droppable without waiting for the module itself to die -- setup(),
## replace_visual_scene() and prepare_model_for_corpse() all call this before
## rebinding or handing the model away. Both entry points are idempotent.
func detach_model() -> void:
	_cancel_all_fire_sequences(false)
	_fire_overlay.detach_model()


## detach_model() plus the rest of the module's state, including the back
## reference to the facade. Unit never re-enters the tree after _exit_tree()
## (see UnitDeathSequence.begin(), which always calls queue_free() right
## after prepare_model_for_corpse(), and match_snapshot._clear_children(),
## which frees a restored unit the same way it frees a building), so this is
## terminal -- every entry point below tolerates a null _owner.
func dispose() -> void:
	detach_model()
	_weapon_targets.clear()
	_moving_fire_weapons.clear()
	_issuing_attack_move = false
	_target_acquisition.dispose()
	_attack_order.dispose()
	_fire_overlay.dispose()
	_owner = null


## Test-only compatibility accessor: unit.gd's _fire_sequence_active property
## and tests/combat/unit_fire_movement_run.gd, tests/units/death_animation_run.gd and
## tests/match/demo_boot_run.gd read this by name.
func has_fire_sequence_active() -> bool:
	return not _weapon_fire_sequences.is_empty()


## Turrets whose TurretDefinition.disabled_when_deployed/disabled_when_undeployed
## keep them live in the unit's current deploy state. Both transition states
## (DEPLOYING/UNDEPLOYING) intentionally expose no active turret, preserving
## "cannot attack while deploying" for every unit, deployable or not.
func _active_turrets() -> Array:
	if _owner.is_deploying():
		return []
	var deployed: bool = _owner.is_deployed()
	var active: Array = []
	for turret in _owner.combat_turrets:
		if turret.is_active_while_deployed(deployed):
			active.append(turret)
	return active


func can_attack(target_or_position: Variant) -> bool:
	for turret in _active_turrets():
		if turret.can_target(target_or_position):
			return true
	return false


## Installs an explicit player attack order. A Node target is tracked until it
## dies; a Vector3 remains a fixed attack-ground coordinate. Relation checks
## belong to UnitCommandController so Ctrl can deliberately force friendly or
## neutral fire through this same combat-facing API.
func command_attack(target_or_position: Variant) -> bool:
	if not can_attack(target_or_position):
		return false
	_cancel_all_fire_sequences()
	_owner.stop_at_current_position()
	_attack_order.begin(target_or_position)
	_weapon_targets.clear()
	_target_acquisition.clear()
	_moving_fire_weapons.clear()
	for turret in _active_turrets():
		if turret.can_target(target_or_position):
			_set_weapon_target(turret.weapon_index(), target_or_position)
	_owner.call("_emit_attack_order_changed", true, target_or_position)
	return true


func cancel_attack_order() -> void:
	_cancel_all_fire_sequences()
	_weapon_targets.clear()
	_target_acquisition.clear()
	_moving_fire_weapons.clear()
	if _attack_order.clear():
		_owner.call("_emit_attack_order_changed", false, null)


func _replace_attack_with_move() -> void:
	var retained_targets: Dictionary = {}
	_moving_fire_weapons.clear()
	for turret in _owner.combat_turrets:
		var weapon_index: int = turret.weapon_index()
		if not weapon_can_fire_while_moving(weapon_index):
			continue
		_moving_fire_weapons[weapon_index] = true
		if _weapon_targets.has(weapon_index):
			retained_targets[weapon_index] = (
				_weapon_targets[weapon_index] as Dictionary
			).duplicate()
	cancel_blocking_fire_sequences()
	var had_attack_order := _attack_order.clear()
	_weapon_targets = retained_targets
	_target_acquisition.clear()
	if had_attack_order:
		_owner.call("_emit_attack_order_changed", false, null)


## Unit.prepare_navigation_order() calls this on every non-attack-move order;
## it is a no-op while that same order is the attack pursuit's own move
## (Unit.issue_attack_move() brackets that call with note_issuing_attack_move()).
func prepare_for_move_order() -> void:
	if not _issuing_attack_move:
		_replace_attack_with_move()


## Unit.issue_attack_move() brackets its own move order with this so
## prepare_for_move_order() (reached through Unit.prepare_navigation_order())
## knows the move it is about to see is the pursuit's own, not a player order.
func note_issuing_attack_move(active: bool) -> void:
	_issuing_attack_move = active


func has_attack_order() -> bool:
	return _attack_order.is_active()


func attack_order_target() -> Variant:
	return _attack_order.target()


func _advance_attack_order(delta: float) -> void:
	if _active_turrets().is_empty():
		return
	if not _attack_order.is_active():
		_advance_retained_weapon_targets(delta)
		return
	var attack_target: Variant = attack_order_target()
	if not _attack_order.is_ground() and not _combat_target_is_alive(attack_target):
		cancel_attack_order()
		_owner.stop_at_current_position()
		return
	var target_world_position := _combat_target_position(attack_target)
	if not target_world_position.is_finite():
		cancel_attack_order()
		_owner.stop_at_current_position()
		return
	var primary_turret = _primary_attack_turret(attack_target)
	if primary_turret == null:
		cancel_attack_order()
		_owner.stop_at_current_position()
		return
	var pursuit_turret = _pursuit_attack_turret(attack_target)
	if pursuit_turret == null:
		pursuit_turret = primary_turret
	var in_range_turrets: Array = []
	var obstructed_turrets: Array = []
	for turret in _active_turrets():
		if turret.target_range(attack_target) != CombatTurretScript.TargetRange.IN_RANGE:
			continue
		if turret.has_line_of_fire(attack_target, _owner):
			in_range_turrets.append(turret)
		else:
			obstructed_turrets.append(turret)
	if in_range_turrets.is_empty():
		_recenter_unengaged_turrets([], delta)
		# A blocked line is solved the same way as a distant target: keep closing
		# until the cliff shoulder or building no longer covers it. Firing from
		# here would only damage the obstacle standing in front of the order.
		if not obstructed_turrets.is_empty() \
		or pursuit_turret.target_range(attack_target) == CombatTurretScript.TargetRange.TOO_FAR:
			_attack_order.advance_pursuit(target_world_position, pursuit_turret, delta)
			return
		# A minimum-range violation is not solved by moving closer. Keep the
		# explicit order active so a moving target can re-enter weapon range.
		_attack_order.stop_pursuit()
		return
	# The long arm reaching first is not the whole unit reaching: keep closing
	# until the shortest-ranged weapon that the order actually uses can join in,
	# and let whatever already bears fire during the approach.
	var pursuing: bool = pursuit_turret.target_range(attack_target) \
		== CombatTurretScript.TargetRange.TOO_FAR
	if pursuing:
		_attack_order.advance_pursuit(target_world_position, pursuit_turret, delta)
	else:
		_attack_order.stop_pursuit()

	# A weapon with no yaw of its own aims only by turning the whole unit; one
	# with a servo is "direct" while the commanded target sits inside its
	# authored sector.
	var hull_mounted_turrets: Array = []
	var direct_turrets: Array = []
	for turret in in_range_turrets:
		if turret.requires_hull_turn():
			hull_mounted_turrets.append(turret)
		elif not turret.requires_hull_turn_for(target_world_position):
			direct_turrets.append(turret)

	var hull_turret = null
	var fixed_hull_aimed := false
	if not hull_mounted_turrets.is_empty():
		# A hull-mounted weapon is the one exception to the rule below: it has no
		# servo to fall back on, so leaving the hull alone means it never fires at
		# all. Turning onto the commanded target cannot cost the servo turrets
		# their aim either, since they are tracking that same target.
		hull_turret = _smallest_hull_adjustment_turret(
			hull_mounted_turrets, target_world_position
		)
		fixed_hull_aimed = CombatTargetAcquisitionScript.hull_bears_on(
			_owner, target_world_position
		) if pursuing else _owner.turn_toward(
			target_world_position - _owner.global_position, delta
		)
	elif direct_turrets.is_empty():
		# A limited side turret must not drag the hull away from a target already
		# covered by another weapon. Only a real all-weapon blind zone requests a
		# hull correction, and the smallest correction brings the nearest sector
		# boundary onto the commanded target.
		hull_turret = _smallest_hull_adjustment_turret(
			in_range_turrets, target_world_position
		)
		if hull_turret != null and not pursuing:
			_turn_hull_by_adjustment(
				hull_turret.hull_yaw_adjustment_for(target_world_position),
				delta
			)

	var engaged_turrets: Array = []
	for turret in in_range_turrets:
		# A braced weapon halts the unit to perform its Fire clip, which would
		# stall the approach one shot at a time. Only weapons that shoot on the
		# move engage until the unit has arrived.
		if pursuing and not weapon_can_fire_while_moving(turret.weapon_index()):
			continue
		var hull_mounted: bool = turret in hull_mounted_turrets
		var turret_target: Variant = attack_target \
			if hull_mounted or turret in direct_turrets or turret == hull_turret \
			else _target_acquisition.target_for(turret)
		var aim_source := AimSource.TURRET
		if hull_mounted:
			aim_source = AimSource.HULL_ON_TARGET if fixed_hull_aimed \
				else AimSource.HULL_TURNING
		if _advance_turret_engagement(turret, turret_target, delta, aim_source):
			engaged_turrets.append(turret)
	_advance_idle_turrets_during_attack_order(
		engaged_turrets, in_range_turrets, obstructed_turrets,
		hull_turret == null, pursuing, delta
	)
	_recenter_unengaged_turrets(engaged_turrets, delta)


## Weapons the commanded target is simply not for -- an anti-ground gun under an
## order on an aircraft, or one whose target sits outside its own range -- are
## not thereby out of the fight: they pick their own target like an idle unit
## would. They may claim the hull only when nothing about the order needs it.
func _advance_idle_turrets_during_attack_order(
		engaged_turrets: Array,
		in_range_turrets: Array,
		obstructed_turrets: Array,
		hull_unclaimed: bool,
		pursuing: bool,
		delta: float
	) -> void:
	var may_turn_hull := hull_unclaimed and not pursuing
	var hull_aim := CombatTargetAcquisitionScript.HullAim.TURN if may_turn_hull \
		else CombatTargetAcquisitionScript.HullAim.ALIGNED_ONLY
	for turret in _active_turrets():
		if turret in in_range_turrets or turret in obstructed_turrets:
			continue
		if pursuing and not weapon_can_fire_while_moving(turret.weapon_index()):
			continue
		var turret_target: Variant = _target_acquisition.target_for(turret, hull_aim)
		if turret_target == null:
			continue
		var aim_source := AimSource.TURRET
		if turret.requires_hull_turn():
			aim_source = _hull_aim_source_for(turret_target, may_turn_hull, delta)
		if _advance_turret_engagement(turret, turret_target, delta, aim_source):
			engaged_turrets.append(turret)


## Turns the hull onto an autonomously picked target when it is free to move,
## and otherwise reports whether it already happens to bear.
func _hull_aim_source_for(target: Variant, may_turn: bool, delta: float) -> AimSource:
	var target_world_position := _combat_target_position(target)
	if not target_world_position.is_finite():
		return AimSource.HULL_TURNING
	var aimed: bool = _owner.turn_toward(
		target_world_position - _owner.global_position, delta
	) if may_turn else CombatTargetAcquisitionScript.hull_bears_on(
		_owner, target_world_position
	)
	return AimSource.HULL_ON_TARGET if aimed else AimSource.HULL_TURNING


func _smallest_hull_adjustment_turret(turrets: Array, target_world_position: Vector3):
	var chosen = null
	var smallest_adjustment := INF
	for turret in turrets:
		var adjustment: float = absf(
			turret.hull_yaw_adjustment_for(target_world_position)
		)
		if adjustment < smallest_adjustment:
			smallest_adjustment = adjustment
			chosen = turret
	return chosen


func _advance_retained_weapon_targets(delta: float) -> void:
	if _weapon_targets.is_empty() and _moving_fire_weapons.is_empty():
		return
	# A standing unit owns its hull and may swing it onto whatever a yaw-less
	# weapon picks. One under a move order does not: such a weapon is braced,
	# and starting its Fire clip would halt the move it was given.
	var hull_aim := CombatTargetAcquisitionScript.HullAim.NONE \
		if _owner.has_active_move_order() \
		else CombatTargetAcquisitionScript.HullAim.TURN
	for turret in _active_turrets():
		var weapon_index: int = turret.weapon_index()
		var autonomous := _moving_fire_weapons.has(weapon_index)
		if not autonomous and not _weapon_targets.has(weapon_index):
			continue
		var retained_target: Variant = _weapon_target(weapon_index)
		if retained_target != null and not _combat_target_is_alive(retained_target):
			_weapon_targets.erase(weapon_index)
			_target_acquisition.forget(weapon_index)
			retained_target = null
		var turret_target: Variant = null
		if retained_target != null:
			var target_world_position := _combat_target_position(retained_target)
			if (
				turret.target_range(retained_target)
					== CombatTurretScript.TargetRange.IN_RANGE
				and _target_acquisition.hull_allows(
					turret, target_world_position, hull_aim
				)
				and turret.has_line_of_fire(retained_target, _owner)
			):
				turret_target = retained_target
		if turret_target == null and autonomous:
			turret_target = _target_acquisition.target_for(turret, hull_aim)
		var aim_source := AimSource.TURRET
		if turret_target != null and turret.requires_hull_turn():
			aim_source = _hull_aim_source_for(
				turret_target,
				hull_aim == CombatTargetAcquisitionScript.HullAim.TURN,
				delta
			)
		if not _advance_turret_engagement(turret, turret_target, delta, aim_source):
			_scan_turret_if_idle(turret, delta)


func _advance_turret_engagement(
	turret, target: Variant, delta: float, aim_source := AimSource.TURRET
	) -> bool:
	if turret == null or target == null:
		return false
	var target_world_position := _combat_target_position(target)
	if not target_world_position.is_finite() \
	or turret.target_range(target) != CombatTurretScript.TargetRange.IN_RANGE:
		return false
	var aimed := bool(turret.aim_at(target_world_position, delta)) \
		if aim_source == AimSource.TURRET \
		else aim_source == AimSource.HULL_ON_TARGET
	if not aimed or _weapon_fire_sequences.has(turret.weapon_index()):
		return true
	# A stream weapon's authored Fire clip is one short burst meant to replay
	# back-to-back for the duration of a burst window (sized to ReloadCount,
	# matching the original engine's roughly symmetric on/off cadence, e.g.
	# the Flame Tank's ~2.4s burst followed by a ~2.4s reload) rather than
	# waiting out the full ReloadCount between each short clip, which would
	# otherwise turn a sustained flame into one brief puff per cooldown. This
	# only applies when the authored clip actually encodes more than one shot
	# event (a real sustained stream); a `Continuous` bullet whose clip fires
	# once (e.g. the Sonic Tank's single boom) fires and reloads like any
	# ordinary weapon instead of replaying that one shot on a loop.
	var is_continuous: bool = bool(turret.is_continuous_bullet())
	var starting_new_burst := false
	var ready_to_restart: bool
	if is_continuous and bool(turret.continuous_burst_active()):
		ready_to_restart = true
	else:
		ready_to_restart = bool(turret.is_ready())
		starting_new_burst = is_continuous and ready_to_restart
	if ready_to_restart and _start_authored_fire_sequence(turret, target):
		if starting_new_burst:
			turret.begin_continuous_burst(
				_fire_sequence_has_multiple_shots(turret.weapon_index())
			)
		return true
	var projectiles: Array = turret.try_fire_at(FireRequestScript.at(target, _owner))
	if not projectiles.is_empty():
		_owner.call("_emit_weapon_fired", projectiles, target, turret.weapon_index())
	return true


func _recenter_unengaged_turrets(engaged_turrets: Array, delta: float) -> void:
	# Inactive turrets are excluded: their pivot belongs to the model's own
	# deploy/undeploy/idle animation while disabled for the current deploy
	# state, not to the combat servo.
	for turret in _active_turrets():
		if turret not in engaged_turrets:
			_scan_turret_if_idle(turret, delta)


func _scan_turret_if_idle(turret, delta: float) -> void:
	if turret == null or _weapon_fire_sequences.has(turret.weapon_index()):
		return
	turret.idle_scan(delta)


func _turn_hull_by_adjustment(adjustment: float, delta: float) -> bool:
	if absf(adjustment) <= 0.0001:
		return true
	if _owner.turn_rate <= 0.0 or delta <= 0.0:
		return false
	var current_yaw := _owner.global_rotation.y
	var target_yaw := current_yaw + adjustment
	var maximum_step: float = _owner.turn_rate * RULE_MOVEMENT_UPDATES_PER_SECOND * delta
	_owner.global_rotation.y = rotate_toward(current_yaw, target_yaw, maximum_step)
	return absf(angle_difference(_owner.global_rotation.y, target_yaw)) <= 0.0001


func _set_weapon_target(weapon_index: int, target: Variant) -> void:
	if target is Vector3:
		_weapon_targets[weapon_index] = {
			"ground": target,
			"is_ground": true,
		}
	elif target is Object and is_instance_valid(target):
		_weapon_targets[weapon_index] = {
			"ref": weakref(target as Object),
			"is_ground": false,
		}


func _weapon_target(weapon_index: int) -> Variant:
	var state: Dictionary = _weapon_targets.get(weapon_index, {})
	if state.is_empty():
		return null
	if bool(state.get("is_ground", false)):
		return state.get("ground", Vector3.INF)
	return _weak_target(state)


func _weak_target(state: Variant) -> Variant:
	if not state is Dictionary:
		return null
	var target_ref: WeakRef = (state as Dictionary).get("ref") as WeakRef
	return target_ref.get_ref() if target_ref != null else null


## Only a genuine sustained-stream clip (multiple authored shot events, e.g.
## the Flame Tank's held trigger) should replay back-to-back for a burst
## window; a `Continuous` bullet whose clip only fires once has nothing to
## gain from restarting the same shot, so it should reload like any other
## weapon. See `_advance_turret_engagement`.
func _fire_sequence_has_multiple_shots(weapon_index: int) -> bool:
	var state: Variant = _weapon_fire_sequences.get(weapon_index)
	if not state is Dictionary:
		return false
	var shot_times: Variant = (state as Dictionary).get("shot_times", [])
	return shot_times is Array and shot_times.size() > 1


func _start_authored_fire_sequence(turret, attack_target: Variant = null) -> bool:
	var weapon_index: int = turret.weapon_index()
	if _weapon_fire_sequences.has(weapon_index):
		return false
	if attack_target == null:
		attack_target = attack_order_target()
	var binding := fire_animation_binding(turret.weapon_index())
	if binding.is_empty():
		return false
	var player := binding["player"] as AnimationPlayer
	var animation_name := StringName(binding["name"])
	var animation := player.get_animation(animation_name)
	if animation == null or animation.length <= 0.0:
		return false

	var can_fire_moving := weapon_can_fire_while_moving(weapon_index)
	var playback_player: AnimationPlayer = _fire_overlay.player_for(weapon_index) \
		if can_fire_moving else player
	if not can_fire_moving:
		for state_value: Variant in _weapon_fire_sequences.values():
			if bool((state_value as Dictionary).get("blocking", false)):
				return false
		_owner.stop_at_current_position()
	return _authored_fire_controller.start_sequence(
		_weapon_fire_sequences,
		turret,
		attack_target,
		playback_player,
		animation_name,
		animation,
		_authored_fire_shot_times(player, animation, turret, animation_name),
		not can_fire_moving,
		_reload_starts_after_fire_animation(),
		restore_combat_turret_poses,
		# Resolved from the model rather than the playback player: a weapon that
		# fires while moving performs the clip on a synthesized overlay player
		# (UnitFireOverlay), but the authored FX events live on the model root
		# either way, and the sounds are driven by the sequence's own clock.
		AuthoredReloadSoundScript.schedule(_owner.visual_root, animation_name)
	)


func _advance_fire_sequences(delta: float) -> void:
	var restore_idle := _authored_fire_controller.advance_sequences(
		_weapon_fire_sequences, delta, _owner, _reload_starts_after_fire_animation()
	)
	if restore_idle and not _owner.is_movement_animation_active():
		_owner.restore_movement_animation()


func _on_authored_weapon_fired(
	projectiles: Array, target: Variant, weapon_index: int
	) -> void:
	_owner.call("_emit_weapon_fired", projectiles, target, weapon_index)


func _reload_starts_after_fire_animation() -> bool:
	return _owner.unit_definition != null and _owner.unit_definition.infantry


func _finish_fire_sequence_for(weapon_index: int) -> void:
	var restore_idle := _authored_fire_controller.finish_sequence(
		_weapon_fire_sequences, weapon_index, _reload_starts_after_fire_animation()
	)
	if restore_idle and not _owner.is_movement_animation_active():
		_owner.restore_movement_animation()


func _cancel_all_fire_sequences(restore_idle := true) -> void:
	var had_blocking := _authored_fire_controller.cancel_sequences(
		_weapon_fire_sequences, _reload_starts_after_fire_animation()
	)
	if restore_idle and had_blocking:
		_owner.restore_movement_animation()


## Public: unit.gd's _set_movement_animation() calls this to decide whether a
## blocking authored Fire clip must yield to a movement request.
func has_blocking_fire_sequence() -> bool:
	return _authored_fire_controller.has_blocking_sequence(
		_weapon_fire_sequences
	)


## Public: unit.gd's _set_movement_animation() calls this alongside
## has_blocking_fire_sequence() above.
func cancel_blocking_fire_sequences() -> void:
	_authored_fire_controller.cancel_sequences(
		_weapon_fire_sequences,
		_reload_starts_after_fire_animation(),
		true,
		false
	)


## Deployed state always resolves the single canonical Deployed_Fire clip
## (see converters/model_bake_builder.gd CLIP_NAME_OVERRIDES); the ordinary
## Fire_<index> chain below is travel-mode only and must never be reached
## while deployed, since Fire_0 is the travel-mode animation.
func fire_animation_binding(weapon_index: int) -> Dictionary:
	if _owner.is_deployed():
		for player in _owner.animation_players():
			if player.has_animation(DEPLOYED_FIRE_ANIMATION):
				return {"player": player, "name": DEPLOYED_FIRE_ANIMATION}
		return {}
	var variants := _travel_fire_variant_bindings(weapon_index)
	if not variants.is_empty():
		return variants[randi() % variants.size()]
	var fallback_candidates: Array[StringName] = [&"Fire"]
	if weapon_index != 0:
		fallback_candidates.append(&"Fire_0")
	for player in _owner.animation_players():
		for animation_name in fallback_candidates:
			if player.has_animation(animation_name):
				return {"player": player, "name": animation_name}
	return {}


## Every Fire_<N> clip belonging to this weapon: its own authored
## Fire_<weapon_index>, plus — only on a combat-deployable unit (Kindjal,
## Mortar, Kobra; see _is_combat_deployable) — any Fire_<N> whose index is not
## claimed by any configured turret (an orphan travel-mode variant, e.g.
## Kobra's Fire_2 once Fire_1 is renamed to Deployed_Fire). These orphan
## clips are equivalent shot variants for the same weapon, not per-weapon-
## index clips, and are chosen at random per shot, mirroring the idle-variant
## selection in _idle_animations/_play_random_idle. An ordinary multi-turret
## unit (e.g. ATMinotaurus, which authors an unrelated, unused Fire_1
## alongside its single real turret's Fire_0) is never a combat-deployable
## eligibility match, so it always resolves exactly one binding here — its
## own Fire_<weapon_index> — matching the previous index-keyed lookup
## byte-for-byte.
func _travel_fire_variant_bindings(weapon_index: int) -> Array[Dictionary]:
	var include_orphans := _is_combat_deployable()
	var configured_indices := {}
	if include_orphans:
		for turret in _owner.combat_turrets:
			configured_indices[turret.weapon_index()] = true
	var seen := {}
	var bindings: Array[Dictionary] = []
	for player in _owner.animation_players():
		for animation_name in player.get_animation_list():
			var name_text := String(animation_name)
			if not name_text.begins_with(FIRE_ANIMATION_PREFIX):
				continue
			var suffix := name_text.trim_prefix(FIRE_ANIMATION_PREFIX)
			if not suffix.is_valid_int():
				continue
			var suffix_index := int(suffix)
			if suffix_index != weapon_index \
			and (not include_orphans or configured_indices.has(suffix_index)):
				continue
			var key := "%d:%s" % [player.get_instance_id(), name_text]
			if seen.has(key):
				continue
			seen[key] = true
			bindings.append({"player": player, "name": animation_name})
	return bindings


## Data-driven combat-deploy eligibility (mirrors combat_deploy_strategy.gd):
## at least one configured turret gated disabled_when_deployed and at least
## one gated disabled_when_undeployed. Scoped to this unit's own turrets so it
## needs no rules database access, unlike the strategy's version which must
## work before any Unit instance exists.
func _is_combat_deployable() -> bool:
	var has_travel_gate := false
	var has_deployed_gate := false
	for turret in _owner.combat_turrets:
		if turret.config == null:
			continue
		if bool(turret.config.disabled_when_deployed):
			has_travel_gate = true
		if bool(turret.config.disabled_when_undeployed):
			has_deployed_gate = true
	return has_travel_gate and has_deployed_gate


func _authored_fire_shot_times(
		player: AnimationPlayer,
		animation: Animation,
		turret,
		animation_name: StringName = &""
	) -> Array[Dictionary]:
	## Test-only shim: tests/combat/fire_sequence_run.gd calls this by name. Not architecture.
	return AuthoredFireControllerScript.authored_fire_shot_times(
		player, animation, turret, _owner.visual_root, animation_name
	)


func _xbf_fire_shot_times(
	animation_name: StringName, animation: Animation, turret
	) -> Array[Dictionary]:
	## Test-only shim: tests/combat/fire_sequence_run.gd calls this by name. Not architecture.
	return AuthoredFireControllerScript.xbf_fire_shot_times(
		animation_name, animation, turret, _owner.visual_root
	)


func _primary_attack_turret(attack_target: Variant):
	for turret in _active_turrets():
		if turret.can_target(attack_target):
			return turret
	return null


## Which weapon decides how close the unit walks. Closing only far enough for
## the longest arm leaves a Devastator parked at plasma range with its shorter
## ranged missiles idle, so the shortest range wins -- but only among the
## weapons that can engage this target at all, so an order on an aircraft is not
## dragged into the range of a gun that cannot shoot up in the first place.
func _pursuit_attack_turret(attack_target: Variant):
	var chosen = null
	var shortest_range := INF
	for turret in _active_turrets():
		if not turret.can_target(attack_target):
			continue
		var maximum_range: float = turret.maximum_range_world()
		# A melee weapon is an opportunity, not a destination: the Sardaukar's
		# knife must never march him out of rifle range and into stabbing range.
		if maximum_range < MELEE_RANGE_WORLD:
			continue
		if maximum_range < shortest_range:
			shortest_range = maximum_range
			chosen = turret
	return chosen


func _combat_target_position(attack_target: Variant) -> Vector3:
	return CombatTargetScript.position_of(attack_target, _owner.global_position)


func _combat_target_is_alive(attack_target: Variant) -> bool:
	return CombatTargetScript.is_alive(attack_target)


## Rotates every authored weapon joint toward a world-space point. The return
## value becomes true only when every configured weapon is inside its own
## acceptable-aim tolerance from Rules.txt.
func aim_turrets_at(world_position: Vector3, delta: float) -> bool:
	if _owner.combat_turrets.is_empty():
		return false
	var all_aimed := true
	for turret in _owner.combat_turrets:
		all_aimed = turret.aim_at(world_position, delta) and all_aimed
	return all_aimed


## Returns world transforms/positions/directions for every authored muzzle of
## one weapon. Multi-barrel weapons expose all >> markers beneath their ::N
## pivot instead of confusing muzzle numbers with weapon numbers.
func turret_emission_points(weapon_index: int = 0) -> Array[Dictionary]:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return []
	return turret.emission_points()


## Selects the next muzzle in authored marker order and advances the sequence.
func next_turret_emission(weapon_index: int = 0) -> Dictionary:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return {}
	return turret.next_emission()


## Fires one rules-backed weapon from its next authored muzzle. A live target
## remains attached only for homing; ordinary projectiles keep this frame's
## position, matching the original no-lead behavior.
func fire_weapon_at(
		target_or_position: Variant,
		weapon_index: int = 0,
		projectile_parent: Node = null,
		aim_offset := Vector3.ZERO
	) -> Array:
	var turret = _combat_turret_for_weapon(weapon_index)
	if turret == null:
		return []
	return turret.try_fire_at(
		FireRequestScript.at(target_or_position, _owner, projectile_parent, aim_offset)
	)


func _combat_turret_for_weapon(weapon_index: int):
	if weapon_index < 0:
		return null
	for turret in _owner.combat_turrets:
		if turret.weapon_index() == weapon_index:
			return turret
	return null


## Cancels any in-flight fire sequence and clears retained targets for every
## weapon whose turret just became inactive under the current deploy state,
## then zeroes its servo angle for next time it's reactivated. Turrets that
## stay active are left untouched. This does not touch the pivot transform:
## while inactive, the pivot belongs to the model's own deploy/undeploy/idle
## animation, and stamping the combat-owned rest pose here would fight or
## outlast that animation (e.g. snapping a just-folded-away deploy-only
## turret back to its deployed pose).
func sync_active_turret_weapons() -> void:
	var active_indices := {}
	for turret in _active_turrets():
		active_indices[turret.weapon_index()] = true
	for turret in _owner.combat_turrets:
		var weapon_index: int = turret.weapon_index()
		if active_indices.has(weapon_index):
			continue
		_finish_fire_sequence_for(weapon_index)
		_weapon_targets.erase(weapon_index)
		_target_acquisition.forget(weapon_index)
		_moving_fire_weapons.erase(weapon_index)
		turret.reset_aim()


func weapon_can_fire_while_moving(weapon_index: int) -> bool:
	return _fire_overlay.can_fire_while_moving(weapon_index)


func refresh_weapon_runtime() -> void:
	_weapon_targets.clear()
	_target_acquisition.clear()
	_moving_fire_weapons.clear()
	_fire_overlay.rebuild(_active_turrets())


func restore_combat_turret_poses() -> void:
	# An inactive deploy-state turret shares authored pivots with the active
	# model pose but must not write its own rest transform over that animation.
	for turret in _active_turrets():
		if turret != null:
			turret.restore_aim_pose()


func configure_combat_turrets() -> void:
	_owner.combat_turrets.clear()
	var turret_values: Array = _owner.unit_definition.turret_ids
	for weapon_index in turret_values.size():
		var turret_value: Variant = turret_values[weapon_index]
		var turret = CombatTurretScript.new()
		if turret.configure(StringName(String(turret_value))):
			turret.bind_model(_owner.visual_root, weapon_index)
			_owner.combat_turrets.append(turret)


func bind_combat_turrets() -> void:
	for turret in _owner.combat_turrets:
		turret.bind_model(_owner.visual_root, turret.weapon_index())


## unit.gd's _on_animation_finished() dispatch. Returns true when the fire-
## sequence lifecycle claimed this animation event, in which case the facade
## must stop dispatching to the other model-driving modules (deploy,
## locomotion, idle) -- exactly the fire_finish_result > 0 branch this
## replaces.
func on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> bool:
	var fire_finish_result: int = _authored_fire_controller.finish_animation(
		_weapon_fire_sequences,
		player,
		animation_name,
		_owner,
		_reload_starts_after_fire_animation()
	)
	if fire_finish_result <= 0:
		return false
	if fire_finish_result == 2 and not _owner.is_movement_animation_active():
		_owner.restore_movement_animation()
	return true
