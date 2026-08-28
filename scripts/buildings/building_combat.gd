class_name BuildingCombat
extends RefCounted

const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const CombatTargetAcquisitionScript := preload(
	"res://scripts/combat/combat_target_acquisition.gd"
)
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

enum PopupState { RETRACTED, DEPLOYING, DEPLOYED, UNDEPLOYING }

const POPUP_TURRET_ROLE := &"PopupTurret"
const POPUP_DEPLOY_ANIMATION := &"Deploy_Gun"
const POPUP_HOLD_ANIMATION := &"Deploy_Gun_Hold"
const POPUP_UNDEPLOY_ANIMATION := &"Undeploy_Gun"
const DEFENSIVE_TURRET_IDS: Array[StringName] = [
	&"HKFlameTurret", &"TLTurret", &"HKGunTurret", &"ORGasTurret",
	&"ORPopUpTurret", &"ATPillbox", &"ATRocketTurret",
]

var _owner: Node3D
var _fire_controller
var _has_order := false
var _is_ground := false
var _ground_position := Vector3.INF
var _target_ref: WeakRef
var _target_acquisition := CombatTargetAcquisitionScript.new()
var _popup_state := PopupState.RETRACTED
var _transition_player: AnimationPlayer
var _transition_animation: StringName = &""
var _transition_elapsed := 0.0
var _transition_duration := 0.0


func configure(owner: Node3D, fire_controller) -> void:
	_owner = owner
	_fire_controller = fire_controller
	_target_acquisition.configure(owner)


## This module's view half: turret aim and target acquisition, both of which
## visibly ride toward a moving target rather than advancing on a countdown --
## see Building.sim_tick()'s doc comment for the split this leaves in place.
## _advance_engagement() below can still commit a shot directly
## (turret.try_fire_at()) for a turret with no authored fire animation at all
## (has_fire_animation() false): every DEFENSIVE_TURRET_IDS entry configured
## today has one, so that fallback is not reachable by any current building,
## and it is left on this clock rather than the tick pending whatever slice
## next gives combat_turret.gd's aim/target-acquisition a tick half to join --
## see network-multiplayer.md's B3 inventory.
func advance(delta: float) -> void:
	if _owner == null:
		return
	_target_acquisition.advance(delta)
	# The engagement and the authored fire animation may both drive the active
	# model. Restore the hold pose on each side of them -- here so aiming sees
	# it, and again in after_authored_advance() so the rendered frame keeps it
	# once the authored controller has advanced on the facade. See
	# restore_popup_hold_pose()'s own doc comment for why this ordering
	# survives the fire controller's advance() moving onto the tick.
	restore_popup_hold_pose()
	_advance_engagement(delta)


func after_authored_advance() -> void:
	restore_popup_hold_pose()


## This module's simulation half: advances the popup deploy/undeploy
## transition's own countdown by exactly one combat tick. Called once per
## simulation tick from Building.sim_tick() -- never call this from
## BuildingCombat's own advance() above, which is why _advance_popup_transition
## no longer lives in that function's body.
##
## _popup_state gates whether _advance_engagement() lets a popup turret fire
## (see the DEPLOYING/UNDEPLOYING/DEPLOYED checks there), so which clock
## decides "the transition is complete" is a simulation decision, not merely a
## cosmetic one -- the same reasoning that puts a projectile's flight and an
## authored fire sequence's shot committal on the tick rather than the frame.
##
## _advance_popup_transition() itself never reads _transition_player's
## playback position, only its own _transition_elapsed accumulator compared
## against _transition_duration (cached once, in _begin_popup_transition(),
## from animation.length) -- the identical shape AuthoredFireController's
## "elapsed"/shot_times split uses, and verified the same way: moving this
## onto the tick is a change of delta source only. The popup clip itself keeps
## playing at the speed_scale _begin_popup_transition() set, via Godot's own
## per-frame AnimationPlayer processing, regardless of which clock calls this
## function -- so the popup visibly rises or falls exactly as before; only the
## tick on which the simulation considers the transition finished (and
## _popup_state flips) now lands on the 25 Hz grid instead of the frame grid.
func sim_tick() -> void:
	_advance_popup_transition(MatchClockScript.SECONDS_PER_TICK)


## Lifecycle protocol, required of every module that caches a reference into the
## owner's model subtree: detach_model() drops those references and dispose()
## drops the rest. _transition_player is such a reference, so it must be
## droppable without waiting for the module itself to die. Both entry points are
## idempotent: bind_model() detaches before it re-attaches, and the facade's
## _exit_tree() can run after a detach has already happened.
func detach_model() -> void:
	_popup_state = PopupState.RETRACTED
	_transition_player = null
	_transition_animation = &""
	_transition_elapsed = 0.0
	_transition_duration = 0.0


## detach_model() plus the rest of the module's state, including the back
## reference to the facade. Building never re-enters the tree (the only
## remove_child of a live building, match_snapshot._clear_children, frees it
## immediately), and Node._ready() would not run a second time anyway, so this
## is terminal -- every entry point below tolerates a null _owner rather than
## assuming it is called again.
func dispose() -> void:
	detach_model()
	if _fire_controller != null:
		_fire_controller.cancel()
	_has_order = false
	_is_ground = false
	_ground_position = Vector3.INF
	_target_ref = null
	_target_acquisition.dispose()
	_owner = null
	_fire_controller = null


func can_attack(target_or_position: Variant) -> bool:
	if not _is_operational():
		return false
	for turret in _owner.combat_turrets:
		if turret.can_target(target_or_position):
			return true
	return false


## Buildings accept the same explicit attack contract as units. They retain an
## out-of-range target rather than pursuing it and begin firing if it later
## enters range. Relation checks remain in UnitCommandController so Ctrl can
## deliberately force fire against allied or neutral targets.
func command_attack(target_or_position: Variant) -> bool:
	if not can_attack(target_or_position):
		return false
	_fire_controller.cancel()
	_has_order = true
	_is_ground = target_or_position is Vector3
	_ground_position = target_or_position if _is_ground else Vector3.INF
	_target_ref = null if _is_ground else weakref(target_or_position as Object)
	_target_acquisition.clear()
	_owner.call("_emit_attack_order_changed", true, target_or_position)
	return true


func cancel_order() -> void:
	if _fire_controller != null:
		_fire_controller.cancel()
	_target_acquisition.clear()
	if not _has_order:
		return
	_has_order = false
	_is_ground = false
	_ground_position = Vector3.INF
	_target_ref = null
	_owner.call("_emit_attack_order_changed", false, null)


## Shared Stop-command contract. Stationary buildings can only have an explicit
## attack order, so Stop deliberately leaves rally points and production state
## unchanged.
func cancel_all_orders() -> bool:
	if not _has_order:
		return false
	cancel_order()
	return true


func has_order() -> bool:
	return _has_order


func order_target() -> Variant:
	if not _has_order:
		return null
	if _is_ground:
		return _ground_position
	return _target_ref.get_ref() if _target_ref != null else null


func popup_state() -> int:
	return _popup_state


func active_animation_player(animation_name: StringName) -> AnimationPlayer:
	return _active_animation_player(animation_name)


func bind_model(model_root: Node3D) -> void:
	if _owner == null:
		return
	_fire_controller.cancel()
	# Damage-state changes bind the same runtime turrets to a different authored
	# model copy. bind_model() resets its logical angles, which is correct for a
	# newly configured entity but used to make every defensive building snap its
	# visible gun straight ahead as soon as it crossed a damage band.
	var aim_angles: Array[Vector2] = []
	for turret in _owner.combat_turrets:
		aim_angles.append(turret.aim_angles())
	detach_model()
	for turret_index in _owner.combat_turrets.size():
		var turret = _owner.combat_turrets[turret_index]
		turret.bind_model(model_root, turret.weapon_index())
		if turret_index < aim_angles.size():
			turret.restore_aim_angles(aim_angles[turret_index])
		if model_root != null:
			for node in model_root.find_children("*", "AnimationPlayer", true, false):
				var player := node as AnimationPlayer
				player.process_priority = mini(player.process_priority, _owner.process_priority - 1)
	if not _owner.combat_turrets.is_empty():
		_fire_controller.configure(_owner, _owner.combat_turrets.front(), model_root)


## Repairs a *rendered* pose the fire controller's authored clip may just have
## overwritten -- it never changes _popup_state, reload, or anything else a
## replay or checksum can see, so it belongs on the frame's clock and stays in
## _process() (via advance() and after_authored_advance() above) rather than
## joining sim_tick(). It used to sit immediately after
## AuthoredFireController.advance() specifically because that call, back when
## it also ran from _process(), could finish a sequence mid-frame and leave the
## Fire clip's final pose showing; now that advance() runs from
## Building.sim_tick() instead, Match already runs every due tick before any
## Building's own _process() this same frame (see that function's doc
## comment), so this call -- wherever it sits within _process() -- always
## observes whatever the most recent tick left. The adjacency is therefore no
## longer load-bearing, but two calls remain (see advance()'s and
## Building._process()'s doc comments) because splitting them costs nothing:
## the function is idempotent, and removing either call is a behavior change
## this slice was not asked to make.
func restore_popup_hold_pose() -> void:
	if not _uses_popup_turret() or _popup_state != PopupState.DEPLOYED \
		or _fire_controller == null or _fire_controller.is_active():
		return
	var player := _active_animation_player(POPUP_HOLD_ANIMATION)
	if player == null:
		return
	player.stop(true)
	player.play(POPUP_HOLD_ANIMATION)
	player.advance(0.0)
	player.pause()
	for turret in _owner.combat_turrets:
		turret.restore_aim_pose()


func _advance_engagement(delta: float) -> void:
	if not _is_operational() or _owner.combat_turrets.is_empty():
		return
	var turret = _owner.combat_turrets.front()
	var target: Variant = order_target()
	if _has_order and ((not _is_ground and not CombatTargetScript.is_alive(target)) \
		or not _target_position(target).is_finite()):
		cancel_order()
		target = null
	# A stationary turret cannot solve a blocked line of fire by moving, and
	# shelling the building or cliff in the way is never what the shot was for.
	# The ordered target stays attached -- the obstacle may fall, or a mobile
	# target may leave cover -- while the weapon serves reachable enemies.
	if target == null or not turret.has_line_of_fire(target, _owner):
		target = _target_acquisition.target_for(turret)

	var target_in_range: bool = target != null and turret.target_range(target) \
		== CombatTurretScript.TargetRange.IN_RANGE
	var target_position := _target_position(target) if target_in_range else Vector3.INF
	if target_in_range and turret.requires_hull_turn_for(target_position):
		target_in_range = false

	if _uses_popup_turret():
		if _popup_state in [PopupState.DEPLOYING, PopupState.UNDEPLOYING]:
			return
		if target_in_range and _popup_state == PopupState.RETRACTED:
			_begin_popup_transition(true)
			return
		if not target_in_range and _popup_state == PopupState.DEPLOYED \
			and not _fire_controller.is_active():
			if turret.recenter(delta):
				_begin_popup_transition(false)
			return
		if _popup_state != PopupState.DEPLOYED:
			return

	if not target_in_range:
		if not _fire_controller.is_active():
			turret.idle_scan(delta)
		return
	var is_group_yaw_turret: bool = _owner.config_id == &"ATRocketTurret"
	var aimed := bool(turret.aim_at(target_position, delta, is_group_yaw_turret))
	if is_group_yaw_turret:
		aimed = bool(turret.is_group_yaw_aimed_at(target_position))
	if not aimed or _fire_controller.is_active():
		return
	if _fire_controller.try_start(target) or _fire_controller.has_fire_animation():
		return
	var projectiles: Array = turret.try_fire_at(FireRequestScript.at(target, _owner))
	if not projectiles.is_empty():
		_owner.call("_emit_weapon_fired", projectiles, target, turret.weapon_index())


func _target_position(target: Variant) -> Vector3:
	# simulation_position(), not global_position, since slice R6: this origin
	# is what CombatTarget.position_of() measures a hull aim point from.
	return CombatTargetScript.position_of(target, _owner.simulation_position())


func _is_operational() -> bool:
	# _owner is null after dispose(); every public entry point funnels through
	# here or _uses_popup_turret(), so guarding both covers a disposed module.
	return _owner != null and _owner.config_id in DEFENSIVE_TURRET_IDS \
		and _owner.is_construction_complete() and _owner.health > 0.0 \
		and not _owner.is_queued_for_deletion() and not _owner.combat_turrets.is_empty()


func _uses_popup_turret() -> bool:
	return _owner != null and _owner.building_definition != null \
		and POPUP_TURRET_ROLE in _owner.building_definition.roles


func _begin_popup_transition(deploying: bool) -> void:
	var animation_name := POPUP_DEPLOY_ANIMATION if deploying else POPUP_UNDEPLOY_ANIMATION
	var player := _active_animation_player(animation_name)
	if player == null:
		_popup_state = PopupState.DEPLOYED if deploying else PopupState.RETRACTED
		return
	var animation := player.get_animation(animation_name)
	if animation == null:
		return
	_fire_controller.cancel()
	_popup_state = PopupState.DEPLOYING if deploying else PopupState.UNDEPLOYING
	_transition_player = player
	_transition_animation = animation_name
	_transition_elapsed = 0.0
	_transition_duration = animation.length
	player.speed_scale = 1.0
	player.stop(true)
	player.play(animation_name)


func _advance_popup_transition(delta: float) -> void:
	if _popup_state not in [PopupState.DEPLOYING, PopupState.UNDEPLOYING]:
		return
	if _transition_player == null or not is_instance_valid(_transition_player):
		_finish_popup_transition()
		return
	_transition_elapsed = minf(_transition_elapsed + maxf(delta, 0.0), _transition_duration)
	if _transition_elapsed + 0.0001 < _transition_duration:
		return
	var animation := _transition_player.get_animation(_transition_animation)
	if animation != null:
		_transition_player.seek(animation.length, true)
	_transition_player.pause()
	_finish_popup_transition()


func _finish_popup_transition() -> void:
	var was_deploying := _popup_state == PopupState.DEPLOYING
	var player := _transition_player
	_popup_state = PopupState.DEPLOYED if was_deploying else PopupState.RETRACTED
	_transition_player = null
	_transition_animation = &""
	_transition_elapsed = 0.0
	_transition_duration = 0.0
	if was_deploying and player != null and player.has_animation(POPUP_HOLD_ANIMATION):
		player.stop(true)
		player.play(POPUP_HOLD_ANIMATION)
		player.advance(0.0)
		player.pause()
	for turret in _owner.combat_turrets:
		turret.capture_current_rest_pose()


func _active_animation_player(animation_name: StringName) -> AnimationPlayer:
	if _owner == null:
		return null
	var state_root: Node3D = _owner.call("state_root", _owner.current_state)
	if state_root == null:
		return null
	for node in state_root.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		if player.has_animation(animation_name):
			return player
	return null
