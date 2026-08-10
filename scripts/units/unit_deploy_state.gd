class_name UnitDeployState
extends RefCounted

## The deploy/undeploy state machine shared by every deployable unit: the
## locked alignment turn, the authored transition clip, and the four states
## around them. Eligibility and the per-unit strategy stay in
## UnitDeploymentController; what a deploying unit *is* lives here.
##
## MCV deploy (TRAVEL -> DEPLOYING -> [consumed: unit freed]) uses only the
## first half of this machine. Combat deploy (Kindjal/Mortar/Kobra) uses all
## four states, toggling DEPLOYED <-> TRAVEL through DEPLOYING/UNDEPLOYING.
##
## Caches the model's transition AnimationPlayer, so it implements the
## attach/detach protocol; detach_model() is idempotent because a unit killed
## mid-deploy runs the corpse handoff and then _exit_tree() as well.

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const AuthoredReloadSoundScript := preload(
	"res://scripts/combat/authored_reload_sound.gd"
)
const AuthoredDeploySoundScript := preload("res://scripts/units/authored_deploy_sound.gd")
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")

## The original MCV model has no clip literally named Deploy. Move_Stop is its
## authored transition from driving to a braced stationary pose and is the
## source-backed fallback for the first phase of deployment. Deploy_Gun is the
## authored clip for the combat-deploy strategy (Kindjal/Mortar/Kobra); it is
## first so those units resolve it before ever reaching the MCV fallback.
const DEPLOY_ANIMATION_CANDIDATES: Array[StringName] = [
	&"Deploy_Gun", &"Deploy", &"Deploying", &"Unpack", &"Move_Stop"
]
## Undeploy has no MCV-side authored clip at all (the Construction Yard's own
## Deconstruct animation handles that transformation instead), so this list
## only ever resolves for the combat-deploy strategy.
const UNDEPLOY_ANIMATION_CANDIDATES: Array[StringName] = [
	&"Undeploy_Gun", &"Undeploy", &"Undeploying"
]

enum State {
	TRAVEL,
	DEPLOYING,
	DEPLOYED,
	UNDEPLOYING,
}

var _unit: CharacterBody3D
var _state := State.TRAVEL
var _aligning := false
var _alignment_direction := Vector3.ZERO
var _transition_player: AnimationPlayer
var _transition_animation: StringName = &""
## Turrets that were active going into an undeploy, still being turned back
## toward hull-aligned before the coil clip starts. See begin_undeploy().
var _recentering_turrets: Array = []


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func detach_model() -> void:
	_transition_player = null
	_transition_animation = &""
	_recentering_turrets.clear()


func dispose() -> void:
	detach_model()
	_unit = null


## Both transition directions count as "deploying" for every gameplay lock: a
## unit is equally immobile while folding out and while folding back in.
func is_transitioning() -> bool:
	return _state == State.DEPLOYING or _state == State.UNDEPLOYING


## Stationary combat mode (Kindjal/Mortar/Kobra). Never true for the MCV,
## which has no DEPLOYED state of its own: a successful deploy consumes it
## into a Construction Yard instead.
func is_deployed() -> bool:
	return _state == State.DEPLOYED


## True only for the fold-back leg. Idle-animation selection treats this the
## same as is_deployed() so the model keeps its deployed hold/idle pose
## through the turret-recenter gate in begin_undeploy(), instead of flashing
## to the travel-mode Stationary pose before the coil clip even starts.
func is_undeploying() -> bool:
	return _state == State.UNDEPLOYING


## Read accessor for the cached transition player. Production never needs it;
## tests/units/death_animation_run.gd does, to assert the corpse handoff drops
## exactly this kind of reference.
func transition_player() -> AnimationPlayer:
	return _transition_player


func begin_deploy(desired_facing: Vector3) -> bool:
	if _state != State.TRAVEL:
		return false
	_state = State.DEPLOYING
	_unit.sync_active_turret_weapons()
	_unit.stop_at_current_position()
	_unit.set_navigation_hold(true)

	_alignment_direction = Vector3(desired_facing.x, 0.0, desired_facing.z)
	_aligning = (
		_alignment_direction.length_squared() > SpatialOrientationScript.DIRECTION_EPSILON
		and not _unit.turn_toward(_alignment_direction, 0.0)
	)
	if _aligning and float(_unit.turn_rate) > 0.0:
		_alignment_direction = _alignment_direction.normalized()
		return true
	if _aligning:
		# A deployable unit without an authored turn rate cannot complete a
		# gradual alignment, so preserve the generic deployment contract.
		_unit.face_direction(_alignment_direction)
		_aligning = false

	start_transition(DEPLOY_ANIMATION_CANDIDATES)
	return true


## Combat-deploy strategy's toggle-back. The MCV/Construction Yard pair never
## calls this: its "undeploy" is a different unit (the spawned MCV) built by
## UnitDeploymentController's own Deconstruct handling, not a state on the
## same Unit instance.
## Aims-at-anything-independent-of-the-hull turrets (e.g. the deployed
## Kobra's gun, +/-190 deg of yaw) must not simply cut to the coil clip's
## frame-0 hull-aligned pose: that reads as the turret teleporting. Snapshot
## each about-to-deactivate turret's aim before sync_active_turret_weapons()
## zeroes its servo bookkeeping via reset_aim() (which deliberately never
## touches the pivot transform, so the pivot is still at the true angle),
## restore it right after, and let advance_undeploy_alignment() walk it back
## to hull-aligned at the turret's own turn rate before the clip starts.
func begin_undeploy() -> bool:
	if _state != State.DEPLOYED:
		return false
	var turrets_to_recenter: Array = _unit.combat_turrets.filter(
		func(turret): return turret.is_active_while_deployed(true)
	)
	var snapshots: Array[Vector2] = []
	for turret in turrets_to_recenter:
		snapshots.append(Vector2(turret.current_yaw, turret.current_pitch))

	_state = State.UNDEPLOYING
	_unit.sync_active_turret_weapons()
	_unit.stop_at_current_position()
	_unit.set_navigation_hold(true)

	_recentering_turrets = turrets_to_recenter
	for i in _recentering_turrets.size():
		var turret = _recentering_turrets[i]
		turret.current_yaw = snapshots[i].x
		turret.current_pitch = snapshots[i].y

	if _recentering_turrets.is_empty():
		start_transition(UNDEPLOY_ANIMATION_CANDIDATES)
	return true


## Turns toward the requested facing while the unit is locked in place.
## Returns true on the frame the heading is reached, so the caller can settle
## the visual slope before the transition clip starts.
func advance_alignment(delta: float) -> bool:
	if not _aligning:
		return false
	if not _unit.turn_toward(_alignment_direction, delta):
		return false
	_aligning = false
	return true


func start_deploy_animation() -> void:
	start_transition(DEPLOY_ANIMATION_CANDIDATES)


## Turns whichever turret(s) were active going into undeploy gradually back
## toward hull-aligned, respecting each turret's own yaw/pitch speed. False
## while nothing to do or still turning; true exactly once, on the frame
## every recentering turret reports centered -- mirrors advance_alignment()'s
## contract for the hull-turn phase of begin_deploy().
func advance_undeploy_alignment(delta: float) -> bool:
	if _recentering_turrets.is_empty():
		return false
	var all_centered := true
	for turret in _recentering_turrets:
		if not turret.recenter(delta):
			all_centered = false
	if not all_centered:
		return false
	_recentering_turrets.clear()
	return true


func start_undeploy_animation() -> void:
	start_transition(UNDEPLOY_ANIMATION_CANDIDATES)


func start_transition(candidates: Array[StringName]) -> void:
	var found: Dictionary = _unit.find_animation_clip(candidates)
	_transition_player = found.get("player") as AnimationPlayer
	_transition_animation = StringName(found.get("name", &""))

	if _transition_player == null:
		_unit.call_deferred("emit_deployment_animation_finished")
		return

	var animation := _transition_player.get_animation(_transition_animation)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
	_transition_player.stop()
	_transition_player.play(_transition_animation)
	_schedule_authored_sounds()


## The Kindjal and the Mortar author a reload inside `Deploy Gun` itself -- the
## gun being loaded as it folds out (AT_Kindjal_H0 frame 374 `Atsniperreload`,
## OR_Mortar_H0 frame 54 `ORkobrareload`), on top of the `KindjalDeploy` /
## `MortarDeploy` servo sound at the head of the same clip. Nothing else drives
## this clip's FX events, so they are scheduled here.
##
## Timers rather than a per-frame position watcher: a transition clip runs to
## completion by construction (`is_transitioning()` locks out every order that
## could interrupt it), so there is no cancellation to unwind. The delay is
## divided by the player's speed scale because nothing resets it between clips
## -- a Kindjal that fired before deploying leaves the player at
## AuthoredFireController.FIRE_ANIMATION_SPEED_SCALE, and the clip then runs
## 25% fast.
func _schedule_authored_sounds() -> void:
	if _unit == null or not _unit.is_inside_tree():
		return
	var reload_schedule := AuthoredReloadSoundScript.schedule(
		_unit.visual_root, _transition_animation
	)
	var transition_schedule := AuthoredDeploySoundScript.schedule(
		_unit.config_id, _unit.visual_root, _transition_animation
	)
	if reload_schedule.is_empty() and transition_schedule.is_empty():
		return
	var speed_scale := maxf(absf(_transition_player.speed_scale), 0.01)
	for entry in reload_schedule + transition_schedule:
		var section := StringName(entry.get("section", &""))
		var delay := float(entry.get("time", 0.0)) / speed_scale
		if delay <= 0.0:
			_play_authored_sound(section)
			continue
		_unit.get_tree().create_timer(delay).timeout.connect(
			_play_authored_sound.bind(section)
		)


## Guarded against everything the timer can outlive: the unit dying mid-deploy,
## the transition finishing early, the match ending. Parented to the unit's
## parent so a sound already started survives the unit itself, like
## UnitMovementSounds._play().
func _play_authored_sound(section: StringName) -> void:
	if section.is_empty() or not is_transitioning():
		return
	if _unit == null or not is_instance_valid(_unit) or not _unit.is_inside_tree():
		return
	SfxSectionCatalogScript.play_at(
		_unit.get_parent(), _unit.global_position, section
	)


## True when the finished clip is the transition this machine is waiting for;
## the facade emits the signal, so subscribers stay attached to the Unit.
func on_animation_finished(animation_name: StringName, player: AnimationPlayer) -> bool:
	return is_transitioning() \
		and player == _transition_player \
		and animation_name == _transition_animation


## The deployment strategy calls this after the animation-to-world handoff.
## `consumed` means the transition completed as intended: for the MCV this is
## true only on a successful Construction Yard placement (the unit is freed
## immediately after by the caller, so the resulting state is moot); for the
## combat strategy it is true whenever deploy()/undeploy() simply run to
## completion, since nothing here is ever destroyed. `false` means the
## transition was aborted (MCV placement failed after the animation already
## played) and must fully unwind back to the state before it started.
## Returns false when there was no transition to finish.
func finish(consumed: bool) -> bool:
	if not is_transitioning():
		return false
	var was_deploying := _state == State.DEPLOYING
	_aligning = false
	_alignment_direction = Vector3.ZERO
	_recentering_turrets.clear()
	detach_model()
	if consumed:
		_state = State.DEPLOYED if was_deploying else State.TRAVEL
	else:
		_state = State.TRAVEL if was_deploying else State.DEPLOYED
	_unit.sync_active_turret_weapons()
	if consumed:
		_unit.retarget_after_deployment_state_change()
	_unit.set_navigation_hold(is_deployed())
	return true
