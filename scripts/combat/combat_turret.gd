class_name CombatTurret
extends RefCounted

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const BallisticsScript := preload("res://scripts/combat/ballistics.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatDefinitionCatalogScript := preload("res://scripts/combat/combat_definition_catalog.gd")
const CombatLineOfFireScript := preload("res://scripts/combat/combat_line_of_fire.gd")
const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatTurretFxScript := preload("res://scripts/combat/turret/combat_turret_fx.gd")
const ShotPayloadScript := preload("res://scripts/combat/shot_payload.gd")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")

## Test-visible presentation constants retained as compatibility aliases.
const LASER_MUZZLE_VISUAL_SCALE := CombatTurretFxScript.LASER_MUZZLE_VISUAL_SCALE
const SHOT_LIGHT_COLOR := CombatTurretFxScript.SHOT_LIGHT_COLOR
const SHOT_LIGHT_REAR_OFFSET := CombatTurretFxScript.SHOT_LIGHT_REAR_OFFSET

## Converted XBF models preserve the original Emperor attachment markers:
##   ::N...  pivot of weapon/turret N
##   >>N...  projectile emission point
##   #muzzleNN  paired rear blast / shell-casing emitter
##   #<name>  paired launcher backblast bank (#smoke, #flare01, ...)
## A TurretNextJoint chain maps onto the nested :: pivots between a weapon's
## root marker and its muzzle markers.

## Turret rotation angles are authored as per-update steps. Use the same 20 Hz
## rules cadence as unit movement while keeping interpolation frame-rate safe.
const AIM_UPDATES_PER_SECOND := 20.0
const DEFAULT_ACCEPTABLE_AIM_DEGREES := 1.0
const IDLE_SCAN_MIN_SECONDS := 3.0
const IDLE_SCAN_MAX_SECONDS := 5.0
const IDLE_SCAN_MAX_YAW := deg_to_rad(70.0)
const TURRET_MARKER := "::"
const MUZZLE_MARKER := ">>"
const REAR_MUZZLE_MARKER := "#muzzle"
const AUTHORED_MUZZLE_FORWARD := Vector3.BACK
const LAUNCH_SMOKE_MARKER_PREFIX := "#"
## Mirrors Unit.DEPLOYED_HOLD_ANIMATION (scripts/units/unit.gd): the authored
## held pose at the end of a combat-deploy unit's fold-out clip. Deploy-only
## turret pivots must rest here, not at the model's undeployed default pose.
const DEPLOYED_HOLD_ANIMATION := &"Deploy_Gun_Hold"

enum TargetRange {
	INVALID,
	TOO_CLOSE,
	IN_RANGE,
	TOO_FAR,
}

var config: Resource
var firing_config: Resource
var bullet_config: Resource
var warhead_config: Resource
var projectile_visual_scene: PackedScene
var impact_visual_scenes: Dictionary = {}
var muzzle_flash_id: StringName = &""
var muzzle_flash_scene: PackedScene
var fire_sound_paths: Array = []
var fire_sound_volume := 100.0
## See TurretDefinition.fire_sound_exclusive. While true this turret keeps at
## most one volley's worth of fire sound alive at a time, in
## `_fire_sound_players`: the next shot fades those out instead of playing over
## them, so a burst is heard as a sequence of shots rather than as N stacked
## copies of the same sample. A volley is one `try_fire_at` call, which may
## launch several payloads (a multi-muzzle mount fires them together), so this
## holds an array rather than a single player — those siblings are meant to
## sound at once; only the *next* volley retires them.
var fire_sound_exclusive := true
var _fire_sound_players: Array[DeathSoundPlayer] = []
var joint_configs: Array[Resource] = []
var reload_ticks_remaining := 0.0
var continuous_burst_ticks_remaining := 0.0
## A continuous (stream) weapon replays its short authored Fire clip
## back-to-back for the whole burst window (see `begin_continuous_burst`),
## calling `try_fire_at` once per replay. Playing `fire_sound_paths` on every
## one of those calls layers the same one-shot sample dozens of times over a
## single flame/gas burst. This gates it to once per burst instead: set when
## a fresh burst starts, consumed by the first `try_fire_at` afterwards.
var _continuous_fire_sound_pending := true
var bullet_gravity := 1.0
var _definition_bullet

var current_yaw := 0.0
var current_pitch := 0.0
var _idle_scan_rng := RandomNumberGenerator.new()
var _idle_scan_active := false
var _idle_scan_seconds_until_target := 0.0
var _idle_scan_target_yaw := 0.0

var _model_root: Node3D
var _fx_model_root: Node3D
var _weapon_index := -1
var _root_pivot: Node3D
var _yaw_pivot: Node3D
var _pitch_pivot: Node3D
var _reference_pivot: Node3D
var _pivot_rest_transforms: Dictionary = {}
var _muzzles: Array[Node3D] = []
## Model-local neutral muzzle-group position used only for aim/arc selection.
## The actual projectile still launches from the animated world-space muzzle.
## Keeping this origin independent from current_pitch prevents a long shared
## yaw/pitch barrel (the deployed Kobra) from feeding its previous pose back
## into the next ballistic solution.
var _trajectory_aim_origin_local := Vector3.INF
var _rear_muzzles: Dictionary = {}
var _launch_smokes: Dictionary = {}
var _uses_embedded_muzzle_flash := false
var _next_muzzle_index := 0
var _last_emissions: Array[Dictionary] = []
var _fx = CombatTurretFxScript.new()
## Test-only shim: tests/combat/shot_fx_composition_run.gd observes scheduled FX timelines.
@warning_ignore("unused_private_class_variable")
var _particle_timeline_tweens: Array[Tween]:
	get:
		return _fx.particle_timeline_tweens()
static var _definition_catalog := CombatDefinitionCatalogScript.new()

func configure(turret_id: StringName) -> bool:
	unbind_model()
	_idle_scan_rng.randomize()
	_reset_idle_scan()
	_definition_bullet = null
	_fx.configure(self)
	_weapon_index = -1
	config = _definition_catalog.turret(turret_id)
	joint_configs = _joint_chain(config)
	firing_config = _last_firing_joint(joint_configs)
	bullet_config = null
	warhead_config = null
	projectile_visual_scene = null
	impact_visual_scenes.clear()
	muzzle_flash_id = &""
	muzzle_flash_scene = null
	fire_sound_paths = []
	fire_sound_volume = 100.0
	fire_sound_exclusive = true
	_fire_sound_players.clear()
	_continuous_fire_sound_pending = true
	reload_ticks_remaining = 0.0
	bullet_gravity = 1.0
	if firing_config == null:
		return false
	var general_config: Resource = _definition_catalog.settings()
	if general_config != null:
		bullet_gravity = maxf(float(general_config.bullet_gravity), 0.0)

	var bullet_id: StringName = firing_config.bullet_id
	if bullet_id == &"":
		return false
	bullet_config = _definition_catalog.bullet(bullet_id)
	if bullet_config == null:
		return false
	projectile_visual_scene = _definition_catalog.scene(bullet_config.projectile_scene_path)
	var explosion_effect_ids: Array = bullet_config.explosion_effect_ids
	for value in explosion_effect_ids:
		var effect_id := StringName(String(value))
		var effect_scene := _definition_catalog.scene(String(bullet_config.impact_scene_paths.get(effect_id, "")))
		if effect_scene != null:
			impact_visual_scenes[effect_id] = effect_scene
	muzzle_flash_id = firing_config.muzzle_flash_id
	if muzzle_flash_id != &"":
		muzzle_flash_scene = _definition_catalog.scene(firing_config.muzzle_flash_scene_path)
	fire_sound_paths = firing_config.fire_sound_paths
	fire_sound_volume = firing_config.fire_sound_volume
	fire_sound_exclusive = firing_config.fire_sound_exclusive

	var warhead_id: StringName = bullet_config.warhead_id
	if warhead_id != &"":
		warhead_config = _definition_catalog.warhead(warhead_id)
	return true


func bind_model(model_root: Node3D, model_weapon_index: int) -> bool:
	unbind_model()
	_weapon_index = model_weapon_index
	if model_root == null or model_weapon_index < 0:
		return false
	_model_root = model_root
	_fx_model_root = _find_fx_model_root(model_root)

	var pivot_candidates: Array[Node3D] = []
	_collect_markers(model_root, TURRET_MARKER, model_weapon_index, pivot_candidates)
	_root_pivot = _pivot_with_muzzles(pivot_candidates)
	if _root_pivot == null and not pivot_candidates.is_empty():
		_root_pivot = pivot_candidates.front()

	if _root_pivot != null:
		_collect_markers(_root_pivot, MUZZLE_MARKER, -1, _muzzles)
	if _muzzles.is_empty():
		_collect_markers(model_root, MUZZLE_MARKER, model_weapon_index, _muzzles)
	if _muzzles.is_empty():
		_collect_visual_muzzle_fallbacks(_root_pivot if _root_pivot != null else model_root, _muzzles)
	_muzzles.sort_custom(_muzzle_less)
	var effect_root := _root_pivot if _root_pivot != null else model_root
	# Scoped to the gun object this weapon's pivot hangs off, not the whole
	# model: bigflash geometry is authored as a sibling of the `::` pivot (AT
	# Infantry's ?~~0?bigflash1 next to ::0gun#), while a second weapon lives
	# under its own object. Reading the whole model let the Devastator's ::0plas
	# barrel flashes suppress the muzzle flash, shot light and launch backblast
	# of its ::1 salvo launcher, which authors none of its own.
	_uses_embedded_muzzle_flash = _has_embedded_muzzle_flash(
		_embedded_muzzle_flash_root(model_root)
	)
	_bind_rear_muzzles(effect_root)
	_bind_launch_smokes(effect_root)

	var pivot_chain := _pivot_chain_to(_muzzles.front() if not _muzzles.is_empty() else null)
	if pivot_chain.is_empty() and _root_pivot != null:
		pivot_chain.append(_root_pivot)
	_reference_pivot = _root_pivot
	if _reference_pivot == null and not _muzzles.is_empty():
		_reference_pivot = _nearest_node3d_parent(_muzzles.front())

	for joint_index in joint_configs.size():
		var joint_config: Resource = joint_configs[joint_index]
		var pivot: Node3D = pivot_chain[mini(joint_index, pivot_chain.size() - 1)] \
			if not pivot_chain.is_empty() else null
		if pivot == null:
			continue
		if _yaw_pivot == null and _axis_speed(joint_config, &"yaw_speed") > 0.0:
			_yaw_pivot = pivot
		if _pitch_pivot == null and _axis_speed(joint_config, &"pitch_speed") > 0.0:
			_pitch_pivot = pivot

	var deploy_only := is_active_while_deployed(true) \
		and not is_active_while_deployed(false)
	for pivot in [_root_pivot, _yaw_pivot, _pitch_pivot, _reference_pivot]:
		if deploy_only:
			var authored_rest: Variant = _authored_hold_transform(model_root, pivot)
			if authored_rest != null:
				_pivot_rest_transforms[pivot] = authored_rest as Transform3D
				continue
		_store_rest_transform(pivot)
	current_yaw = 0.0
	current_pitch = 0.0
	_reset_idle_scan()
	_next_muzzle_index = 0
	_apply_aim_transforms()
	var neutral_muzzle_origin := _muzzle_group_origin()
	_trajectory_aim_origin_local = _model_root.to_local(neutral_muzzle_origin) \
		if neutral_muzzle_origin.is_finite() else Vector3.INF
	return _reference_pivot != null or not _muzzles.is_empty()


func unbind_model() -> void:
	cancel_authored_fire_fx()
	_restore_pivot_transforms()
	_model_root = null
	_fx_model_root = null
	_root_pivot = null
	_yaw_pivot = null
	_pitch_pivot = null
	_reference_pivot = null
	_pivot_rest_transforms.clear()
	_muzzles.clear()
	_trajectory_aim_origin_local = Vector3.INF
	_rear_muzzles.clear()
	_launch_smokes.clear()
	_uses_embedded_muzzle_flash = false
	_next_muzzle_index = 0
	_last_emissions.clear()
	current_yaw = 0.0
	current_pitch = 0.0
	_reset_idle_scan()


func is_configured() -> bool:
	return config != null and firing_config != null and bullet_config != null


## Shared immutable view used by targeting, range, and trajectory queries.
## Shot payloads deliberately remain fresh instances in try_fire(), because
## damage_scale belongs to an individual in-flight shot.
func _definition_view():
	if _definition_bullet == null:
		_definition_bullet = CombatBulletScript.new(
			bullet_config, warhead_config,
			projectile_visual_scene, impact_visual_scenes
		)
	return _definition_bullet


func is_bound() -> bool:
	return _model_root != null and is_instance_valid(_model_root) \
		and (_reference_pivot != null or not _muzzles.is_empty())


func is_fixed() -> bool:
	return _yaw_pivot == null and _pitch_pivot == null


func weapon_index() -> int:
	return _weapon_index


## Whether this turret is live given the unit's current deploy state (Unit's
## TRAVEL/DEPLOYED, never during a DEPLOYING/UNDEPLOYING transition). Reads
## TurretDefinition.disabled_when_deployed/disabled_when_undeployed, generated
## from Rules.txt's turret_disable_if_unit_deployed/undeployed and otherwise
## unused before the combat-deploy strategy. Ordinary units carry both flags
## false, so this is always true regardless of `deployed`.
func is_active_while_deployed(deployed: bool) -> bool:
	if config == null:
		return true
	if deployed:
		return not bool(config.disabled_when_deployed)
	return not bool(config.disabled_when_undeployed)


func requires_hull_turn() -> bool:
	return _yaw_pivot == null


func has_independent_yaw() -> bool:
	return _yaw_pivot != null and _axis_speed(_yaw_config(), &"yaw_speed") > 0.0


## True when an animation target belongs to this weapon's articulated branch
## or to the ancestor chain that carries that branch. A Fire clip confined to
## this set can be layered over sibling locomotion branches.
func owns_aim_branch(node: Node) -> bool:
	if node == null or _root_pivot == null or not is_instance_valid(_root_pivot):
		return false
	return node == _root_pivot \
		or _root_pivot.is_ancestor_of(node) \
		or node.is_ancestor_of(_root_pivot)


func requires_hull_turn_for(world_position: Vector3) -> bool:
	if _yaw_pivot == null:
		return true
	var yaw_config := _yaw_config()
	if yaw_config == null:
		return true
	_apply_aim_transforms()
	var desired_yaw := _desired_yaw(world_position)
	var reachable_yaw := _clamp_rule_angle(
		desired_yaw, yaw_config,
		&"minimum_yaw", &"maximum_yaw"
	)
	return absf(angle_difference(desired_yaw, reachable_yaw)) \
		> deg_to_rad(_acceptable_yaw_degrees())


## Signed world-Y rotation still required from the owner hull before the target
## reaches this turret's nearest authored yaw limit. Zero means the servo can
## already acquire it without changing the hull heading.
func hull_yaw_adjustment_for(world_position: Vector3) -> float:
	if _yaw_pivot == null:
		var emission := peek_emission()
		if emission.is_empty():
			return 0.0
		var direction: Vector3 = emission["direction"]
		var target_direction := world_position - Vector3(emission["position"])
		var horizontal_direction := Vector2(direction.x, direction.z)
		var horizontal_target := Vector2(target_direction.x, target_direction.z)
		if horizontal_direction.is_zero_approx() or horizontal_target.is_zero_approx():
			return 0.0
		return angle_difference(
			atan2(horizontal_direction.x, horizontal_direction.y),
			atan2(horizontal_target.x, horizontal_target.y)
		)
	var yaw_config := _yaw_config()
	if yaw_config == null:
		return 0.0
	_apply_aim_transforms()
	var desired_yaw := _desired_yaw(world_position)
	var reachable_yaw := _clamp_rule_angle(
		desired_yaw, yaw_config,
		&"minimum_yaw", &"maximum_yaw"
	)
	return angle_difference(reachable_yaw, desired_yaw)


func joint_count() -> int:
	return joint_configs.size()


func muzzle_count() -> int:
	return _muzzles.size()


func rear_muzzle_count() -> int:
	return _rear_muzzles.size()


func current_yaw_degrees() -> float:
	return rad_to_deg(current_yaw)


func current_pitch_degrees() -> float:
	return rad_to_deg(current_pitch)


## Saves the combat-owned aim independently of the authored model subtree.
## Building damage states replace that subtree with an equivalent copy, so the
## caller can carry this pose across the rebind instead of exposing the new
## copy's straight-ahead authored rest pose.
func aim_angles() -> Vector2:
	return Vector2(current_yaw, current_pitch)


## Restores angles obtained from aim_angles() after binding an equivalent
## model.  bind_model() deliberately resets its angles for a genuinely new
## entity model; this narrower API makes a visual-state replacement explicit.
func restore_aim_angles(angles: Vector2) -> void:
	current_yaw = angles.x
	current_pitch = angles.y
	_apply_aim_transforms()


## Reapplies the combat-owned yaw and pitch after an AnimationPlayer changes
## clips. Converted animations key the authored turret pivots as part of the
## full model pose, so stop()/play() can otherwise expose their straight-ahead
## transform for one rendered frame without changing the logical aim angles.
func restore_aim_pose() -> void:
	_apply_aim_transforms()


## Makes the model's currently evaluated pose the servo's new zero angle.
## Popup buildings call this at the end of their authored deploy/undeploy
## clips: the animation owns every transform during the transition, then the
## combat servo takes ownership from exactly that visible endpoint.
func capture_current_rest_pose() -> void:
	current_yaw = 0.0
	current_pitch = 0.0
	_pivot_rest_transforms.clear()
	for pivot in [_root_pivot, _yaw_pivot, _pitch_pivot, _reference_pivot]:
		_store_rest_transform(pivot)
	_apply_aim_transforms()
	var neutral_muzzle_origin := _muzzle_group_origin()
	_trajectory_aim_origin_local = _model_root.to_local(neutral_muzzle_origin) \
		if _model_root != null and neutral_muzzle_origin.is_finite() \
		else Vector3.INF


func aim_at(world_position: Vector3, delta: float, pivot_relative_yaw := false) -> bool:
	if not is_bound():
		return false
	_idle_scan_active = false
	# Authored Stationary/Move tracks can key a turret ancestor back to its
	# animation pose before Unit combat runs. Restore the combat-owned angles
	# first, otherwise the muzzle servo observes the rest direction every frame
	# while current_yaw/current_pitch drift independently without converging.
	_apply_aim_transforms()
	if _yaw_pivot != null:
		var yaw_config := _yaw_config()
		var desired_yaw := _clamp_rule_angle(
			_desired_yaw(world_position, pivot_relative_yaw), yaw_config,
			&"minimum_yaw", &"maximum_yaw"
		)
		_turn_yaw_toward(
			world_position, desired_yaw,
			_axis_speed(yaw_config, &"yaw_speed"), delta
		)
		_apply_aim_transforms()
	if _pitch_pivot != null:
		var pitch_config := _pitch_config()
		var desired_pitch := _clamp_rule_angle(
			_desired_firing_pitch(world_position), pitch_config,
			&"minimum_pitch", &"maximum_pitch"
		)
		_turn_pitch_toward(
			world_position, desired_pitch,
			_axis_speed(pitch_config, &"pitch_speed"), delta
		)
		_apply_aim_transforms()
	return is_aimed_at(world_position)


## A joint-space yaw step is not always a world-space heading step of the same
## size. On a pivot that also carries a steeply elevated barrel (notably the
## deployed Kobra), the authored rest basis couples yaw and pitch: one 4-degree
## rules step can move the projected muzzle heading by more than 10 degrees.
## Taking that full step forever overshoots targets in alternating directions,
## leaving the weapon in a dead zone where it never becomes "aimed".
##
## Keep the rules-rate upper bound, but test progressively smaller fractions
## of that step against the actual world-space muzzle heading and retain the
## largest one that improves it.
func _turn_yaw_toward(
		world_position: Vector3,
		desired_yaw: float,
		speed_degrees: float,
		delta: float
	) -> void:
	_turn_shared_axis(world_position, desired_yaw, speed_degrees, delta, false)


func _world_yaw_error(world_position: Vector3) -> float:
	var emission := peek_emission()
	if emission.is_empty():
		return INF
	var direction: Vector3 = emission["direction"]
	var target_direction := _desired_firing_direction(world_position)
	target_direction = _yaw_target_direction(world_position, target_direction)
	return _angular_errors(direction, target_direction, target_direction).x


## The same shared pivot can amplify a pitch step and, near the point where a
## trajectory mount changes between its high and low solutions, can also move
## the muzzle enough to change the solution being evaluated. Choose a
## world-space-improving fraction so the servo crosses that discontinuity
## instead of alternating forever on its two sides.
func _turn_pitch_toward(
		world_position: Vector3,
		desired_pitch: float,
		speed_degrees: float,
		delta: float
	) -> void:
	_turn_shared_axis(world_position, desired_pitch, speed_degrees, delta, true)


func _turn_shared_axis(
		world_position: Vector3,
		desired_angle: float,
		speed_degrees: float,
		delta: float,
		pitch_axis: bool
	) -> void:
	var starting_angle := current_pitch if pitch_axis else current_yaw
	var full_step := _turn_axis(starting_angle, desired_angle, speed_degrees, delta)
	if is_equal_approx(full_step, starting_angle):
		return
	if _yaw_pivot == null or _pitch_pivot == null or _yaw_pivot != _pitch_pivot:
		if pitch_axis:
			current_pitch = full_step
		else:
			current_yaw = full_step
		return
	var best_angle := starting_angle
	var best_error := _world_pitch_error(world_position) \
		if pitch_axis else _world_yaw_error(world_position)
	for fraction in [1.0, 0.5, 0.25, 0.125, 0.0625]:
		var candidate_angle := lerp_angle(starting_angle, full_step, fraction)
		if pitch_axis:
			current_pitch = candidate_angle
		else:
			current_yaw = candidate_angle
		_apply_aim_transforms()
		var candidate_error := _world_pitch_error(world_position) \
			if pitch_axis else _world_yaw_error(world_position)
		if candidate_error + 0.000001 < best_error:
			best_error = candidate_error
			best_angle = candidate_angle
	if pitch_axis:
		current_pitch = best_angle
	else:
		current_yaw = best_angle


func _world_pitch_error(world_position: Vector3) -> float:
	var emission := peek_emission()
	if emission.is_empty():
		return INF
	var direction: Vector3 = emission["direction"]
	var target_direction := _desired_firing_direction(world_position)
	return _angular_errors(direction, target_direction, target_direction).y


func _angular_errors(
		direction: Vector3,
		yaw_target_direction: Vector3,
		pitch_target_direction: Vector3
	) -> Vector2:
	var horizontal_direction := Vector2(direction.x, direction.z)
	var horizontal_yaw_target := Vector2(
		yaw_target_direction.x, yaw_target_direction.z
	)
	var yaw_error := 0.0
	if not horizontal_direction.is_zero_approx() \
	and not horizontal_yaw_target.is_zero_approx():
		yaw_error = absf(angle_difference(
			horizontal_direction.angle(), horizontal_yaw_target.angle()
		))
	var horizontal_pitch_target := Vector2(
		pitch_target_direction.x, pitch_target_direction.z
	)
	var direction_pitch := atan2(direction.y, horizontal_direction.length())
	var target_pitch := atan2(
		pitch_target_direction.y, horizontal_pitch_target.length()
	)
	return Vector2(
		yaw_error, absf(angle_difference(direction_pitch, target_pitch))
	)


func recenter(delta: float) -> bool:
	_idle_scan_active = false
	current_yaw = _turn_axis(current_yaw, 0.0, _axis_speed(_yaw_config(), &"yaw_speed"), delta)
	current_pitch = _turn_axis(current_pitch, 0.0, _axis_speed(_pitch_config(), &"pitch_speed"), delta)
	_apply_aim_transforms()
	return is_zero_approx(current_yaw) and is_zero_approx(current_pitch)


## Lets a yaw-capable idle weapon look around its authored forward direction.
## The first 3–5 seconds retain the old recentering behaviour, then each
## interval chooses a fresh point within a 140-degree forward-facing sector.
## Rules-defined yaw stops still win when a particular mount is narrower.
func idle_scan(delta: float) -> void:
	if not is_bound() or not has_independent_yaw():
		return
	if not _idle_scan_active:
		_idle_scan_active = true
		_idle_scan_target_yaw = 0.0
		_idle_scan_seconds_until_target = _next_idle_scan_interval()
	_idle_scan_seconds_until_target -= maxf(delta, 0.0)
	if _idle_scan_seconds_until_target <= 0.0:
		var yaw_config := _yaw_config()
		_idle_scan_target_yaw = _clamp_rule_angle(
			_idle_scan_rng.randf_range(-IDLE_SCAN_MAX_YAW, IDLE_SCAN_MAX_YAW),
			yaw_config, &"minimum_yaw", &"maximum_yaw"
		)
		_idle_scan_seconds_until_target = _next_idle_scan_interval()
	current_yaw = _turn_axis(
		current_yaw, _idle_scan_target_yaw,
		_axis_speed(_yaw_config(), &"yaw_speed"), delta
	)
	_apply_aim_transforms()


func _reset_idle_scan() -> void:
	_idle_scan_active = false
	_idle_scan_seconds_until_target = 0.0
	_idle_scan_target_yaw = 0.0


func _next_idle_scan_interval() -> float:
	return _idle_scan_rng.randf_range(IDLE_SCAN_MIN_SECONDS, IDLE_SCAN_MAX_SECONDS)


## Zeroes the servo bookkeeping without touching the pivot transform. Used
## when a turret goes inactive on a deploy-state change: while inactive its
## pivot is owned entirely by the model's own animation (Deploy_Gun_Hold /
## Undeploy_Gun / travel idle), so stamping rest.basis here would fight or
## outlast that animation instead of just resetting the angle for next time
## the turret becomes active.
func reset_aim() -> void:
	current_yaw = 0.0
	current_pitch = 0.0


func is_aimed_at(world_position: Vector3) -> bool:
	var emission := peek_emission()
	if emission.is_empty():
		return false
	var offset: Vector3 = world_position - Vector3(emission["position"])
	if offset.length_squared() <= 0.000001:
		return true
	var direction: Vector3 = emission["direction"]
	var target_direction := _desired_firing_direction(world_position)
	if target_direction.is_zero_approx():
		target_direction = offset.normalized()
	var yaw_target_direction := _yaw_target_direction(world_position, target_direction)
	var errors := _angular_errors(
		direction, yaw_target_direction, target_direction
	)
	return errors.x <= deg_to_rad(_acceptable_yaw_degrees()) \
		and (_pitch_pivot == null \
			or errors.y <= deg_to_rad(_acceptable_pitch_degrees()))


## Readiness variant for a rigid multi-barrel mount whose yaw is authored
## around the centre pivot while its active muzzle is offset sideways. Pitch
## remains ballistic/muzzle-relative. ATRocketTurret uses this without changing
## the established aiming contract of unit weapons such as Mongoose.
func is_group_yaw_aimed_at(world_position: Vector3) -> bool:
	var emission := peek_emission()
	if emission.is_empty():
		return false
	var direction: Vector3 = emission["direction"]
	var pivot_target_direction := world_position - _aim_origin()
	var firing_direction := _desired_firing_direction(world_position)
	var errors := _angular_errors(
		direction, pivot_target_direction, firing_direction
	)
	return errors.x <= deg_to_rad(_acceptable_yaw_degrees()) \
		and (_pitch_pivot == null \
			or errors.y <= deg_to_rad(_acceptable_pitch_degrees()))


func emission_points() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for muzzle_index in _muzzles.size():
		var muzzle := _muzzles[muzzle_index]
		if muzzle == null or not is_instance_valid(muzzle):
			continue
		var transform := muzzle.global_transform
		var direction := transform.basis * AUTHORED_MUZZLE_FORWARD
		if direction.length_squared() <= 0.000001:
			continue
		var emission := {
			"index": muzzle_index,
			"node": muzzle,
			"transform": transform,
			"position": transform.origin,
			"direction": direction.normalized(),
		}
		var rear_muzzle := _rear_muzzles.get(muzzle) as Node3D
		if rear_muzzle != null and is_instance_valid(rear_muzzle):
			var rear_transform := rear_muzzle.global_transform
			emission["rear_node"] = rear_muzzle
			emission["rear_transform"] = rear_transform
			emission["rear_position"] = rear_transform.origin
			# The rear marker supplies the animated position but its empty-node
			# basis is not authored as an exhaust vector. Direction is explicitly
			# opposite the paired barrel's projectile heading.
			emission["rear_direction"] = -direction.normalized()
		var launch_smoke := _launch_smokes.get(muzzle) as Node3D
		if launch_smoke != null and is_instance_valid(launch_smoke):
			emission["smoke_node"] = launch_smoke
			emission["smoke_position"] = launch_smoke.global_position
			emission["smoke_bank_id"] = _baked_billboard_bank_id(launch_smoke)
		result.append(emission)
	if result.is_empty() and _reference_pivot != null and is_instance_valid(_reference_pivot):
		var transform := _reference_pivot.global_transform
		var direction := transform.basis * AUTHORED_MUZZLE_FORWARD
		if direction.length_squared() > 0.000001:
			result.append({
				"index": 0,
				"node": _reference_pivot,
				"transform": transform,
				"position": transform.origin,
				"direction": direction.normalized(),
			})
	return result


func peek_emission() -> Dictionary:
	var points := emission_points()
	if points.is_empty():
		return {}
	return points[_next_muzzle_index % points.size()]


## Same as peek_emission(), except an authored shot with a known muzzle_index
## (see FireRequest) previews that specific muzzle instead of the round-robin
## next one, so range/aim checks agree with the muzzle try_fire() will use.
func preview_emission_for(muzzle_index: int) -> Dictionary:
	if muzzle_index < 0 or maxi(int(firing_config.bullet_count), 1) != 1:
		return peek_emission()
	var points := emission_points()
	if muzzle_index >= points.size():
		return peek_emission()
	return points[muzzle_index]


func next_emission() -> Dictionary:
	var points := emission_points()
	if points.is_empty():
		return {}
	var emission := points[_next_muzzle_index % points.size()]
	_next_muzzle_index = (_next_muzzle_index + 1) % points.size()
	return emission


func last_emissions() -> Array[Dictionary]:
	return _last_emissions.duplicate()


func is_ready() -> bool:
	return is_configured() and reload_ticks_remaining <= 0.0


func reload_count() -> float:
	return maxf(float(firing_config.reload_count), 0.0) \
		if firing_config != null else 0.0


func maximum_range_world() -> float:
	if bullet_config == null:
		return 0.0
	return _definition_view().maximum_range_world()


func begin_reload() -> void:
	reload_ticks_remaining = reload_count()


## True while a continuous-bullet turret is still within its authored burst
## window (see `begin_continuous_burst`). Ignored for non-continuous weapons.
func continuous_burst_active() -> bool:
	return continuous_burst_ticks_remaining > 0.0


## Starts a fresh firing cycle for a `Continuous` bullet: always re-arms the
## once-per-cycle fire sound, and — only when `sustain_window` is true, i.e.
## the authored clip has more than one shot event (see
## `_fire_sequence_has_multiple_shots` in unit_combat.gd) — opens the replay
## burst window, sized to the same `ReloadCount` budget used for the cooldown
## that follows it, matching the original engine's roughly symmetric on/off
## cadence for stream weapons (e.g. the Flame Tank's ~2.4s burst followed by a
## ~2.4s reload). A single-shot `Continuous` bullet (the Sonic Tank's boom)
## leaves the window closed and just fires and reloads normally.
func begin_continuous_burst(sustain_window: bool = true) -> void:
	if sustain_window:
		continuous_burst_ticks_remaining = reload_count()
	_continuous_fire_sound_pending = true


## Fades out whatever this turret's previous volley is still playing and drops
## the references. Entries are validity-checked rather than assumed live: a
## player frees itself the moment its sample ends, which for anything firing
## slower than its own sample is the normal case, and the array then holds only
## freed instance IDs.
func _retire_fire_sounds() -> void:
	for player in _fire_sound_players:
		if is_instance_valid(player):
			player.fade_out_and_free()
	_fire_sound_players.clear()


func advance_ticks(ticks: float) -> void:
	if ticks <= 0.0:
		return
	if reload_ticks_remaining > 0.0:
		reload_ticks_remaining = maxf(reload_ticks_remaining - ticks, 0.0)
	if continuous_burst_ticks_remaining > 0.0:
		continuous_burst_ticks_remaining = maxf(
			continuous_burst_ticks_remaining - ticks, 0.0
		)
		if continuous_burst_ticks_remaining <= 0.0:
			begin_reload()


func can_target(target_or_position: Variant) -> bool:
	if not is_configured() or not is_bound():
		return false
	var target_position := _bullet_target_position(target_or_position)
	if not target_position.is_finite() or peek_emission().is_empty():
		return false
	var bullet = _definition_view()
	if target_or_position is Vector3:
		return bullet.can_hit_ground()
	if not target_or_position is Object:
		return false
	return _bullet_target_is_alive(target_or_position as Object) \
		and bullet.can_hit(target_or_position as Object)


func target_range(target_or_position: Variant, aim_offset := Vector3.ZERO) -> int:
	if not can_target(target_or_position):
		return TargetRange.INVALID
	var target_position := _bullet_target_position(target_or_position) + aim_offset
	var range_origin := _range_origin()
	if not range_origin.is_finite():
		return TargetRange.INVALID
	var bullet = _definition_view()
	var range_target := target_or_position as Object \
		if target_or_position is Object else null
	var horizontal_distance: float = bullet.horizontal_target_distance(
		range_origin, target_position, range_target
	)
	if horizontal_distance + 0.0001 < bullet.minimum_range_world():
		return TargetRange.TOO_CLOSE
	if horizontal_distance > bullet.maximum_range_world() + 0.0001:
		return TargetRange.TOO_FAR
	# Range alone is insufficient for weapons with a limited elevation arc.
	# Ink Vine, for example, cannot lower its barrel less than 20 degrees: at
	# maximum rules range a ground point is horizontally legal but still too
	# shallow to aim at. Treat that case as too far while moving closer improves
	# the pitch, so attack pursuit continues to an actually fireable position.
	if _pitch_pivot != null:
		var pitch_error := _pitch_limit_error(target_position)
		if pitch_error > deg_to_rad(_acceptable_pitch_degrees()):
			var closer_position := target_position
			closer_position.x = lerpf(range_origin.x, target_position.x, 0.5)
			closer_position.z = lerpf(range_origin.z, target_position.z, 0.5)
			if _pitch_limit_error(closer_position) + 0.0001 < pitch_error:
				return TargetRange.TOO_FAR
	return TargetRange.IN_RANGE


## Reports whether a shot fired from this weapon's muzzles would reach the
## target instead of detonating on the terrain or building in between. Being in
## range is not enough: the shell has to get there. Trajectory bullets lob over
## whatever stands in the way, so only flat-flying weapons are constrained.
func has_line_of_fire(target_or_position: Variant, shooter: Object = null) -> bool:
	return has_line_of_fire_from(muzzle_origin(), target_or_position, shooter)


## The same query for a position the shooter has not reached yet, so attack
## pursuit can pick a perch that will be able to fire once it arrives.
func has_line_of_fire_from(
		origin: Vector3, target_or_position: Variant, shooter: Object = null
	) -> bool:
	if not is_configured() or not is_bound():
		return true
	if _model_root == null or not is_instance_valid(_model_root) \
	or not _model_root.is_inside_tree():
		return true
	var bullet = _definition_view()
	if bullet.has_trajectory():
		return true
	var ignored: Array = [shooter, _model_root]
	if target_or_position is Object:
		ignored.append(target_or_position as Object)
	return CombatLineOfFireScript.is_clear(
		_model_root.get_world_3d(),
		origin,
		_bullet_target_position(target_or_position),
		ignored
	)


## World point shots leave from. Falls back to the aim pivot for a weapon whose
## muzzle markers are not currently sampled.
func muzzle_origin() -> Vector3:
	var origin := _muzzle_group_origin()
	return origin if origin.is_finite() else _aim_origin()


func try_fire(
		begin_reload_after_shot := true, committed_sequence := false, damage_scale := 1.0,
		muzzle_index := -1
	) -> Array:
	var result: Array = []
	if not is_configured() or (not committed_sequence and not is_ready()):
		return result

	_last_emissions.clear()
	var bullet_count := maxi(int(firing_config.bullet_count), 1)
	# An authored Fire clip's shot event already names the physical muzzle
	# whose bone peaks at that time (see AuthoredFireController). Only a
	# single-bullet shot can honor that muzzle unambiguously; bullet_count > 1
	# turrets keep the plain round-robin, since a burst of many bullets aimed
	# at one authored muzzle has no equivalent authored assignment for the rest.
	var forced_points: Array[Dictionary] = []
	if muzzle_index >= 0 and bullet_count == 1:
		forced_points = emission_points()
	for index in bullet_count:
		var payload = ShotPayloadScript.new(_definition_view(), damage_scale)
		result.append(payload)
		var emission := next_emission()
		if not forced_points.is_empty() and muzzle_index < forced_points.size():
			emission = forced_points[muzzle_index]
		_last_emissions.append(emission)
	if begin_reload_after_shot:
		begin_reload()
	return result


## Emits fully configured world-space projectile nodes toward either a live
## target or an attack-ground position. Range is checked before reload/muzzle
## state is consumed; the target position is sampled now (there is no lead).
func try_fire_at(request: FireRequest) -> Array:
	var target_or_position: Variant = request.target
	var aim_offset: Vector3 = request.aim_offset
	var result: Array = []
	if not is_configured() or not is_bound() \
	or (not request.committed_sequence and not is_ready()):
		return result
	var target_position := _bullet_target_position(target_or_position)
	var preview_emission := preview_emission_for(request.muzzle_index)
	if not target_position.is_finite() or preview_emission.is_empty():
		return result
	if request.require_aim and not is_aimed_at(target_position + aim_offset):
		return result
	var preview_bullet = _definition_view()
	if target_or_position is Vector3 and not preview_bullet.can_hit_ground():
		return result
	if target_or_position is Object \
	and not preview_bullet.can_hit(target_or_position as Object):
		return result
	if target_or_position is Object \
	and not _bullet_target_is_alive(target_or_position as Object):
		return result
	var range_origin := _range_origin()
	if not range_origin.is_finite() \
	or (
		target_or_position is Object
		and not preview_bullet.can_reach_target(
			range_origin,
			target_position + aim_offset,
			target_or_position as Object
		)
	) \
	or (
		not target_or_position is Object
		and not preview_bullet.can_reach(range_origin, target_position + aim_offset)
	):
		return result

	var parent: Node = request.projectile_parent \
		if request.projectile_parent != null else _default_projectile_parent()
	if parent == null or not parent.is_inside_tree():
		return result
	# Fire animations can key the barrel away from the servo-owned aim pose
	# before their authored shot event. Preserve the selected high solution for
	# elevated-only trajectory mounts instead of letting CombatProjectile infer
	# the low solution again from that transient visual muzzle direction.
	var trajectory_launch_direction := Vector3.ZERO
	if preview_bullet.has_trajectory() and _prefers_high_trajectory_arc():
		trajectory_launch_direction = _desired_firing_direction(
			target_position + aim_offset
		)
	var payloads := try_fire(
		request.begin_reload_after_shot, request.committed_sequence, request.damage_scale,
		request.muzzle_index
	)
	# One volley retires the previous volley's sounds exactly once, on its first
	# audible shot — not per payload, or a multi-muzzle mount would cut its own
	# simultaneous siblings short.
	var retired_previous_fire_sound := false
	for index in payloads.size():
		var projectile = CombatProjectileScript.new()
		parent.add_child(projectile)
		var emission: Dictionary = _last_emissions[index] \
			if index < _last_emissions.size() else preview_emission
		# A yaw-only mount can turn its visual muzzle toward a unit but cannot
		# encode the required vertical component in that marker.  Without an
		# explicit direction, a low unit target is missed while attack-ground at
		# the same point works (CombatProjectile already derives that direction
		# for Vector3 targets).  Preserve authored headings for mounts that have
		# pitch and for trajectory weapons, whose parallel barrel spread is
		# intentional.
		if target_or_position is Object and _pitch_pivot == null \
		and not preview_bullet.has_trajectory():
			var target_direction := Vector3(emission["position"]).direction_to(
				target_position + aim_offset
			)
			if not target_direction.is_zero_approx():
				emission = emission.duplicate()
				emission["target_direction"] = target_direction
		if not trajectory_launch_direction.is_zero_approx():
			emission = emission.duplicate()
			emission["direction"] = trajectory_launch_direction
		if not projectile.launch(
			payloads[index], emission, target_or_position,
			request.source if request.source != null else _model_root,
			bullet_gravity, aim_offset, range_origin
		):
			projectile.free()
			continue
		# TurretMuzzleFlash in Rules.txt supplies the standalone effect unless
		# the model already reveals embedded bigflash/bflash geometry during its
		# Fire clip. Layering both would duplicate the flash and runtime light.
		# A laser's full beam is drawn by CombatProjectile from the muzzle to the
		# resolved raycast impact. Ltmuzzle remains a short authored muzzle accent,
		# but must follow that resolved 3D segment rather than a yaw-only marker
		# direction or it floats horizontally when the target is downhill.
		var effect_emission := emission
		if preview_bullet.is_laser():
			var laser_direction := Vector3(emission["position"]).direction_to(
				projectile.global_position
			)
			if not laser_direction.is_zero_approx():
				effect_emission = emission.duplicate()
				effect_emission["direction"] = laser_direction
		if muzzle_flash_scene != null and not _uses_embedded_muzzle_flash:
			_fx.spawn_muzzle_flash(parent, effect_emission)
			# Continuous delivery is presented by the model's authored particle
			# banks. A generic ballistic flash is especially wrong for gas and
			# also competes with flame streams.
			if not preview_bullet.is_continuous():
				_fx.spawn_shot_light(parent, effect_emission)
			_fx.spawn_auxiliary_muzzle_effects(parent, effect_emission)
		var should_play_fire_sound := true
		if preview_bullet.is_continuous():
			should_play_fire_sound = _continuous_fire_sound_pending
			_continuous_fire_sound_pending = false
		if should_play_fire_sound:
			if fire_sound_exclusive and not retired_previous_fire_sound:
				retired_previous_fire_sound = true
				_retire_fire_sounds()
			var fire_sound_player: DeathSoundPlayer = DeathSoundPlayerScript.play_pool(
				parent, Vector3(effect_emission["position"]), fire_sound_paths,
				fire_sound_volume
			)
			if fire_sound_exclusive and fire_sound_player != null:
				_fire_sound_players.append(fire_sound_player)
		result.append(projectile)
	return result


func _bullet_target_position(target_or_position: Variant) -> Vector3:
	if target_or_position is Vector3:
		return target_or_position
	if target_or_position is Object and is_instance_valid(target_or_position):
		var target_object := target_or_position as Object
		if target_object.has_method("combat_aim_position_from"):
			var origin := _range_origin()
			if origin.is_finite():
				var value: Variant = target_object.call(
					"combat_aim_position_from", origin
				)
				if value is Vector3:
					return value
		if target_object.has_method("combat_aim_position"):
			var value: Variant = target_object.call("combat_aim_position")
			if value is Vector3:
				return value
		if target_object is Node3D:
			return (target_object as Node3D).global_position
	return Vector3.INF


func _bullet_target_is_alive(target: Object) -> bool:
	return CombatTargetScript.is_alive(target)


func _default_projectile_parent() -> Node:
	if _model_root == null or not is_instance_valid(_model_root) or not _model_root.is_inside_tree():
		return null
	var tree := _model_root.get_tree()
	return tree.current_scene if tree.current_scene != null else tree.root


func _joint_chain(turret_config: Resource) -> Array[Resource]:
	var result: Array[Resource] = []
	var current := turret_config
	var visited: Dictionary = {}
	while current != null:
		var current_id := String(current.config_id)
		if not current_id.is_empty() and visited.has(current_id):
			return []
		if not current_id.is_empty():
			visited[current_id] = true
		result.append(current)
		var next_joint: StringName = current.next_joint_id
		if next_joint == &"":
			break
		current = _definition_catalog.turret(next_joint)
	return result


func _last_firing_joint(configs: Array[Resource]) -> Resource:
	for index in range(configs.size() - 1, -1, -1):
		if configs[index].bullet_id != &"":
			return configs[index]
	return null


func _collect_markers(
		node: Node, marker: String, wanted_index: int, result: Array[Node3D]
	) -> void:
	if node is Node3D:
		var index := _marker_index(_original_name(node), marker)
		if index >= 0 and (wanted_index < 0 or index == wanted_index):
			result.append(node as Node3D)
	for child in node.get_children():
		_collect_markers(child, marker, wanted_index, result)


func _collect_visual_muzzle_fallbacks(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D:
		var lower_name := _original_name(node).to_lower()
		if lower_name.contains("bigflash") or lower_name.contains("bflash"):
			result.append(node as Node3D)
	for child in node.get_children():
		_collect_visual_muzzle_fallbacks(child, result)


func _embedded_muzzle_flash_root(model_root: Node3D) -> Node:
	if _root_pivot == null or not is_instance_valid(_root_pivot):
		return model_root
	var owner_object := _root_pivot.get_parent()
	return owner_object if owner_object != null else model_root


func _has_embedded_muzzle_flash(node: Node) -> bool:
	if node is Node3D:
		var lower_name := _original_name(node).to_lower()
		if lower_name.contains("bigflash") or lower_name.contains("bflash"):
			return true
	for child in node.get_children():
		if _has_embedded_muzzle_flash(child):
			return true
	return false


func _find_fx_model_root(node: Node) -> Node3D:
	if node is Node3D and node.has_meta("xbf_fx_banks"):
		return node as Node3D
	for child in node.get_children():
		var candidate := _find_fx_model_root(child)
		if candidate != null:
			return candidate
	return null


func _bind_rear_muzzles(node: Node) -> void:
	var candidates: Array[Node3D] = []
	_collect_rear_muzzles(node, candidates)
	for muzzle in _muzzles:
		for candidate in candidates:
			# Minotaurus pairs each >> marker and its rear #muzzle marker as
			# siblings under the same animated gun object. Pair by hierarchy,
			# not by the unrelated source number ranges 01-04 and 05-08.
			if candidate.get_parent() == muzzle.get_parent():
				_rear_muzzles[muzzle] = candidate
				break


## Pairs every launch tube with the authored backblast marker behind it. The
## marker is a `#` FX attachment parented alongside the `>>` tubes and offset
## along the barrel axis only: the Mongoose's `#smoke` sits opposite its single
## `>>0#flame`, and the Devastator's `#flare01..03` each share the lateral
## offset of one `>>Nmissile_salvo#` tube, so the nearest sibling is the right
## one. Only markers holding a baked non-emitting bank qualify - that billboard
## is authored with a one-frame start/stop pair, which the model clip can only
## show for a single frame, so the blast has to be replayed here. A marker whose
## bank emits (the Missile Tank's `#M0..#M5` particle streams) is already driven
## by its own Fire clip and must not be doubled.
func _bind_launch_smokes(node: Node) -> void:
	var candidates: Array[Node3D] = []
	_collect_launch_blast_markers(node, candidates)
	for muzzle in _muzzles:
		var nearest: Node3D = null
		var nearest_distance := INF
		for candidate in candidates:
			if candidate.get_parent() != muzzle.get_parent() \
			or _rear_muzzles.values().has(candidate):
				continue
			var distance := candidate.position.distance_squared_to(muzzle.position)
			if distance < nearest_distance:
				nearest = candidate
				nearest_distance = distance
		if nearest != null:
			_launch_smokes[muzzle] = nearest


func _collect_rear_muzzles(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D \
	and _original_name(node).to_lower().begins_with(REAR_MUZZLE_MARKER):
		result.append(node as Node3D)
	for child in node.get_children():
		_collect_rear_muzzles(child, result)


func _collect_launch_blast_markers(node: Node, result: Array[Node3D]) -> void:
	if node is Node3D \
	and _original_name(node).begins_with(LAUNCH_SMOKE_MARKER_PREFIX) \
	and _baked_billboard_bank_id(node) != "":
		result.append(node as Node3D)
	for child in node.get_children():
		_collect_launch_blast_markers(child, result)


## The bank id of the marker's baked still billboard, or "" when the marker
## holds no baked FX at all or holds a particle emitter (see
## converters/model_bake_builder.gd `_build_attachment_bank_effects`).
func _baked_billboard_bank_id(marker: Node) -> String:
	for child in marker.get_children():
		if child is MeshInstance3D and child.has_meta("xbf_fx_bank_id"):
			return String(child.get_meta("xbf_fx_bank_id"))
	return ""


func _pivot_with_muzzles(candidates: Array[Node3D]) -> Node3D:
	for candidate in candidates:
		var descendant_muzzles: Array[Node3D] = []
		_collect_markers(candidate, MUZZLE_MARKER, -1, descendant_muzzles)
		if not descendant_muzzles.is_empty():
			return candidate
	return null


func _pivot_chain_to(muzzle: Node3D) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if muzzle == null:
		return result
	var current: Node = muzzle.get_parent()
	var stop: Node = _root_pivot.get_parent() if _root_pivot != null else _model_root.get_parent()
	while current != null and current != stop:
		if current is Node3D and _marker_index(_original_name(current), TURRET_MARKER) >= 0:
			result.push_front(current as Node3D)
		current = current.get_parent()
	return result


func _marker_index(original_name: String, marker: String) -> int:
	var marker_position := original_name.find(marker)
	if marker_position < 0:
		return -1
	var digit_position := marker_position + marker.length()
	var end := digit_position
	while end < original_name.length():
		var code := original_name.unicode_at(end)
		if code < 48 or code > 57:
			break
		end += 1
	return int(original_name.substr(digit_position, end - digit_position)) \
		if end > digit_position else -1


func _muzzle_less(a: Node3D, b: Node3D) -> bool:
	var a_index := _marker_index(_original_name(a), MUZZLE_MARKER)
	var b_index := _marker_index(_original_name(b), MUZZLE_MARKER)
	if a_index != b_index:
		return a_index < b_index
	return String(a.get_path()) < String(b.get_path())


func _original_name(node: Node) -> String:
	if node == null:
		return ""
	return String(node.get_meta("original_name", node.name))


func _nearest_node3d_parent(node: Node) -> Node3D:
	var current := node.get_parent() if node != null else null
	while current != null:
		if current is Node3D:
			return current as Node3D
		current = current.get_parent()
	return null


func _store_rest_transform(pivot: Node3D) -> void:
	if pivot != null and is_instance_valid(pivot) and not _pivot_rest_transforms.has(pivot):
		_pivot_rest_transforms[pivot] = pivot.transform


## The converter bakes each animated node's per-frame pose as a Value track at
## "<path-from-AnimationPlayer-root>:transform" (see
## converters/model_bake_builder.gd _to_godot_transform baking). Reads the
## single authored key of DEPLOYED_HOLD_ANIMATION for `pivot`, or null if the
## model has no such clip/track (e.g. units without a deploy-hold pose).
func _authored_hold_transform(model_root: Node3D, pivot: Node3D):
	if model_root == null or pivot == null or not is_instance_valid(pivot):
		return null
	var player := model_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null or not player.has_animation(DEPLOYED_HOLD_ANIMATION):
		return null
	var animation := player.get_animation(DEPLOYED_HOLD_ANIMATION)
	if animation == null:
		return null
	var root := player.get_node_or_null(player.root_node)
	if root == null or not (root is Node3D) or not root.is_ancestor_of(pivot):
		return null
	var track_path := NodePath("%s:transform" % String(root.get_path_to(pivot)))
	var track := animation.find_track(track_path, Animation.TYPE_VALUE)
	if track < 0 or animation.track_get_key_count(track) == 0:
		return null
	var value: Variant = animation.track_get_key_value(track, 0)
	if typeof(value) != TYPE_TRANSFORM3D:
		return null
	return value


func _restore_pivot_transforms() -> void:
	for pivot in _pivot_rest_transforms:
		if pivot != null and is_instance_valid(pivot):
			(pivot as Node3D).transform = _pivot_rest_transforms[pivot]


func _apply_aim_transforms() -> void:
	if _yaw_pivot != null and _yaw_pivot == _pitch_pivot:
		_apply_pivot_rotation(_yaw_pivot, current_yaw, current_pitch)
		return
	if _yaw_pivot != null:
		_apply_pivot_rotation(_yaw_pivot, current_yaw, 0.0)
	if _pitch_pivot != null:
		_apply_pivot_rotation(_pitch_pivot, 0.0, current_pitch)


func _apply_pivot_rotation(pivot: Node3D, yaw: float, pitch: float) -> void:
	if pivot == null or not is_instance_valid(pivot) or not _pivot_rest_transforms.has(pivot):
		return
	var rest: Transform3D = _pivot_rest_transforms[pivot]
	var rotation := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	pivot.transform = Transform3D(rest.basis * rotation, rest.origin)


func _desired_yaw(world_position: Vector3, pivot_relative := false) -> float:
	var emission := peek_emission()
	if emission.is_empty():
		return current_yaw
	var direction: Vector3 = emission["direction"]
	# Must converge on exactly the criterion the caller gates firing on, or
	# the servo can settle at a point that check reports as unaimed and stop
	# moving for good. A yaw-only mount already gets pivot-relative aiming
	# from _yaw_target_direction() below regardless (aiming separately from
	# the active side muzzle would turn a rigid multi-barrel group a little
	# toward the centre and make consecutive shells converge, e.g. the
	# ORLaserTank/ATRocketTurret offset-muzzle cases). A turret with its own
	# pitch joint defaults to the same muzzle-relative direction is_aimed_at()
	# checks -- ATAPC's gun offset from its yaw pivot is the prominent case
	# where converging on the pivot instead leaves a residual error the
	# muzzle-relative check never accepts, permanently jamming the turret
	# just after its first shot -- except when the caller explicitly wants
	# the pivot-relative contract of is_group_yaw_aimed_at() instead (a
	# building's rigid multi-barrel mount with its own pitch joint, e.g.
	# ATRocketTurret).
	var target_direction: Vector3 = (world_position - _aim_origin()) \
		if (pivot_relative and _pitch_pivot != null) \
		else _yaw_target_direction(world_position, _desired_firing_direction(world_position))
	var horizontal_direction := Vector2(direction.x, direction.z)
	var horizontal_target := Vector2(target_direction.x, target_direction.z)
	if horizontal_direction.is_zero_approx() or horizontal_target.is_zero_approx():
		return current_yaw
	var direction_heading := atan2(horizontal_direction.x, horizontal_direction.y)
	var target_heading := atan2(horizontal_target.x, horizontal_target.y)
	return current_yaw + angle_difference(direction_heading, target_heading)


## A yaw-only turret is solved around its pivot, so readiness must use that
## same origin. Comparing a pivot-aimed barrel against muzzle-to-target yaw
## creates a false minimum range whenever an authored muzzle is offset sideways
## (ORLaserTank is the prominent case). Pitch-capable and fixed weapons retain
## their muzzle-relative direction because it carries their ballistic solution
## or the yaw that their owner hull must still supply.
func _yaw_target_direction(
	world_position: Vector3, fallback := Vector3.ZERO
) -> Vector3:
	if _yaw_pivot != null and _pitch_pivot == null:
		var pivot_direction := world_position - _aim_origin()
		if not pivot_direction.is_zero_approx():
			return pivot_direction
	if not fallback.is_zero_approx():
		return fallback
	var emission := peek_emission()
	if emission.is_empty():
		return Vector3.ZERO
	return world_position - Vector3(emission["position"])


func _desired_firing_pitch(world_position: Vector3) -> float:
	return _desired_pitch_for_direction(_desired_firing_direction(world_position))


func _pitch_limit_error(world_position: Vector3) -> float:
	var pitch_config := _pitch_config()
	if pitch_config == null:
		return 0.0
	var desired_pitch := _desired_firing_pitch(world_position)
	var reachable_pitch := _clamp_rule_angle(
		desired_pitch, pitch_config, &"minimum_pitch", &"maximum_pitch"
	)
	return absf(angle_difference(desired_pitch, reachable_pitch))


func _desired_firing_direction(world_position: Vector3) -> Vector3:
	var emission := peek_emission()
	if emission.is_empty():
		return Vector3.ZERO
	var emission_position := Vector3(emission["position"])
	var target_direction: Vector3 = world_position - emission_position
	if target_direction.is_zero_approx():
		return Vector3(emission["direction"]).normalized()
	var bullet = _definition_view()
	if not bullet.has_trajectory():
		return target_direction.normalized()
	# A rigid multi-barrel mount has one shared elevation. Solve that elevation
	# from the centre of the muzzle group rather than changing it whenever the
	# active >> marker advances to the next barrel.
	var trajectory_origin := _ballistic_aim_origin()
	if not trajectory_origin.is_finite():
		trajectory_origin = emission_position
	var target_heading := world_position - _aim_origin()
	target_heading.y = 0.0
	if target_heading.is_zero_approx():
		target_heading = target_direction
	var trajectory_impact_position: Vector3 = (
		BallisticsScript.parallel_impact_position(
			trajectory_origin, world_position, target_heading
		)
	)
	var trajectory_direction := trajectory_impact_position - trajectory_origin
	var velocities: Array[Vector3] = BallisticsScript.launch_velocities(
		bullet,
		trajectory_origin,
		trajectory_impact_position,
		BallisticsScript.gravity_world(bullet_gravity),
		bullet.maximum_range_world()
	)
	if velocities.is_empty():
		return trajectory_direction.normalized()

	var directions: Array[Vector3] = []
	for velocity in velocities:
		directions.append(velocity.normalized())
	if _pitch_pivot == null or directions.size() == 1:
		return directions.front()

	# A strictly negative TurretMaxXRotation is an authored high-angle mount:
	# Mortar and Ink Vine cannot lower their barrels to the direct line. Prefer
	# the high ballistic solution when both arcs fit such a mount. Other
	# trajectory weapons retain the low solution unless their limits reject it.
	var pitch_config := _pitch_config()
	var prefers_high_arc := _prefers_high_trajectory_arc()
	var best_direction: Vector3 = directions.front()
	var best_limit_error: float = INF
	for candidate in directions:
		var candidate_pitch := _desired_pitch_for_direction(candidate)
		var reachable_pitch := _clamp_rule_angle(
			candidate_pitch, pitch_config,
			&"minimum_pitch", &"maximum_pitch"
		)
		var limit_error := absf(angle_difference(candidate_pitch, reachable_pitch))
		if limit_error + 0.000001 < best_limit_error \
		or (
			prefers_high_arc
			and is_equal_approx(limit_error, best_limit_error)
			and candidate.y > best_direction.y
		):
			best_limit_error = limit_error
			best_direction = candidate
	return best_direction


func _prefers_high_trajectory_arc() -> bool:
	var pitch_config := _pitch_config()
	if pitch_config == null:
		return false
	var maximum_pitch := float(pitch_config.maximum_pitch)
	return not is_nan(maximum_pitch) and maximum_pitch < 0.0


func _desired_pitch_for_direction(target_direction: Vector3) -> float:
	var emission := peek_emission()
	if emission.is_empty() or target_direction.is_zero_approx():
		return current_pitch
	var direction: Vector3 = emission["direction"]
	var direction_pitch := atan2(direction.y, Vector2(direction.x, direction.z).length())
	var target_pitch := atan2(
		target_direction.y, Vector2(target_direction.x, target_direction.z).length()
	)
	# Positive authored X rotation lowers a BACK-facing muzzle, hence the
	# subtraction when converting world-space pitch error into joint rotation.
	return current_pitch - angle_difference(direction_pitch, target_pitch)


## Starts model-authored particle banks alongside a sliced Fire animation.
func start_authored_fire_fx(
		animation_name: StringName,
		parent: Node = null,
		playback_speed := 1.0
	) -> bool:
	return _fx.start_authored_fire_fx(animation_name, parent, playback_speed)


func has_authored_fire_fx() -> bool:
	return _fx.has_authored_fire_fx()


func cancel_authored_fire_fx() -> void:
	_fx.cancel_authored_fire_fx()


## Test-only shim: tests/combat/muzzle_fx_run.gd calls this by name.
func _spawn_muzzle_flash(parent: Node, emission: Dictionary) -> void:
	_fx.spawn_muzzle_flash(parent, emission)
## True for a stream weapon (the Harkonnen Flamer/Flame Tank's Flame_B and
## FlameTank_B). Their authored Fire clip is a short single burst meant to be
## replayed back-to-back for as long as the target stays engaged, rather than
## gated behind a full ReloadCount wait between each short clip like a normal
## discrete-shot weapon.
func is_continuous_bullet() -> bool:
	if bullet_config == null:
		return false
	var preview_bullet = _definition_view()
	return preview_bullet.is_continuous()


## World-unit reach the authored flame-jet particles should visually stretch
## to, or -1.0 when this weapon's bullet is not continuous (leaving muzzle
## banks such as casings and flashes at their authored, unscaled distance).
func _continuous_jet_reach_world() -> float:
	if bullet_config == null:
		return -1.0
	var preview_bullet = _definition_view()
	return preview_bullet.maximum_range_world() if preview_bullet.is_continuous() else -1.0



## Rules ranges belong to the gameplay entity, not to an animated muzzle.
## Using a muzzle here makes entering range depend on whether Move, Fire or an
## elevated trajectory pose happened to run on that frame.
func _range_origin() -> Vector3:
	if _model_root == null or not is_instance_valid(_model_root):
		return Vector3.INF
	return _model_root.global_position


func _aim_origin() -> Vector3:
	for pivot in [_yaw_pivot, _root_pivot, _reference_pivot]:
		if pivot != null and is_instance_valid(pivot):
			return (pivot as Node3D).global_position
	return _range_origin()


func _muzzle_group_origin() -> Vector3:
	var points := emission_points()
	if points.is_empty():
		return Vector3.INF
	var result := Vector3.ZERO
	for point in points:
		result += Vector3(point["position"])
	return result / float(points.size())


func _trajectory_aim_origin() -> Vector3:
	if (
		_model_root == null
		or not is_instance_valid(_model_root)
		or not _trajectory_aim_origin_local.is_finite()
	):
		return Vector3.INF
	return _model_root.to_global(_trajectory_aim_origin_local)


func _ballistic_aim_origin() -> Vector3:
	# Separate yaw/pitch chains do not have Kobra's self-coupling and retain
	# exact muzzle-to-projectile alignment (notably the Minotaurus salvo).
	return _trajectory_aim_origin() \
		if _yaw_pivot != null and _yaw_pivot == _pitch_pivot \
		else _muzzle_group_origin()


func _turn_axis(current: float, target: float, speed_degrees: float, delta: float) -> float:
	if speed_degrees <= 0.0 or delta <= 0.0:
		return current
	var maximum_step := deg_to_rad(speed_degrees) * AIM_UPDATES_PER_SECOND * delta
	return rotate_toward(current, target, maximum_step)


func _clamp_rule_angle(
		angle: float, joint_config: Resource, minimum_field: StringName, maximum_field: StringName
	) -> float:
	if joint_config == null:
		return 0.0
	var minimum_value := float(joint_config.get(minimum_field))
	var maximum_value := float(joint_config.get(maximum_field))
	if is_nan(minimum_value) and is_nan(maximum_value):
		return wrapf(angle, -PI, PI)
	var minimum := minimum_value if not is_nan(minimum_value) else -180.0
	var maximum := maximum_value if not is_nan(maximum_value) else 180.0
	if maximum - minimum >= 360.0:
		return wrapf(angle, -PI, PI)
	return clampf(angle, deg_to_rad(minimum), deg_to_rad(maximum))


func _axis_speed(joint_config: Resource, field_name: StringName) -> float:
	return maxf(float(joint_config.get(field_name)), 0.0) \
		if joint_config != null else 0.0


func _yaw_config() -> Resource:
	for joint_config in joint_configs:
		if _axis_speed(joint_config, &"yaw_speed") > 0.0:
			return joint_config
	return null


func _pitch_config() -> Resource:
	for joint_config in joint_configs:
		if _axis_speed(joint_config, &"pitch_speed") > 0.0:
			return joint_config
	return null


func _acceptable_yaw_degrees() -> float:
	var yaw_config := _yaw_config()
	if yaw_config != null:
		return maxf(
			float(yaw_config.acceptable_yaw),
			DEFAULT_ACCEPTABLE_AIM_DEGREES
		)
	return DEFAULT_ACCEPTABLE_AIM_DEGREES


func _acceptable_pitch_degrees() -> float:
	var pitch_config := _pitch_config()
	if pitch_config != null:
		return maxf(
			float(pitch_config.acceptable_pitch),
			DEFAULT_ACCEPTABLE_AIM_DEGREES
		)
	return DEFAULT_ACCEPTABLE_AIM_DEGREES
