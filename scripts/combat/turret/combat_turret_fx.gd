extends RefCounted

const StreamParticleScript := preload("res://scripts/combat/turret/stream_particle.gd")
const AuthoredFxBankScript := preload("res://scripts/combat/fx/authored_fx_bank.gd")

const AIM_UPDATES_PER_SECOND := 20.0
const DEFAULT_MUZZLE_FLASH_DURATION := 0.2
const LASER_MUZZLE_VISUAL_SCALE := 0.9
const MUZZLE3_PRIMARY_MESH := "Mesh_00"
const MUZZLE3_PRIMARY_SCALE := 0.5
const MUZZLE_MARKER := ">>"
const AUTHORED_MUZZLE_FORWARD := Vector3.BACK
const INLINE_FX_FRAME_SECONDS := 1.0 / AIM_UPDATES_PER_SECOND
const BARREL_SMOKE_SEQUENCE := "!%Bru"
const REAR_FLASH_FRAME_COUNT := 16
const REAR_FLASH_SIZE := 2.2
const SHOT_LIGHT_COLOR := Color(1.0, 0.34, 0.08)
const SHOT_LIGHT_ENERGY := 3.0
const SHOT_LIGHT_RANGE := 4.0
const SHOT_LIGHT_REAR_OFFSET := 0.35
const SHOT_LIGHT_HOLD_DURATION := 0.04
const SHOT_LIGHT_FADE_DURATION := 0.16
const CASING_SEQUENCE := "!%shel"
const LAUNCH_SMOKE_SEQUENCE := "!cexp"
const LAUNCH_SMOKE_FRAME_COUNT := 16
const LAUNCH_SMOKE_SIZE := 1.25
const LAUNCH_SMOKE_REFERENCE_PARTICLE_SIZE := 32.0
const JET_DENSITY_MULTIPLIER := 3
const JET_MIN_PARTICLES_PER_EMISSION := 4
const JET_MAX_PARTICLES_PER_EMISSION := 8
const JET_START_SCALE := 0.32
const JET_END_SCALE := 1.55
const JET_SIZE_VARIATION := 0.25
const JET_LIFE_VARIATION := 0.35
const JET_REACH_VARIATION := 0.18
const JET_DECELERATION_EXPONENT := 2.0
const JET_CONE_MIN_DEGREES := 1.5
const JET_CONE_MAX_DEGREES := 7.0
const JET_NOZZLE_JITTER_SCALE := 0.3
const JET_FLARE_REACH_FRACTION := 0.14
const JET_BUOYANCY_REACH_FRACTION := 0.09
const JET_IGNITION_FRACTION := 0.12
const JET_BURNOUT_FRACTION := 0.45
const JET_EMBER_COLOR := Color(0.55, 0.22, 0.1)

var _turret_ref: WeakRef
var _turret:
	get:
		return _turret_ref.get_ref() if _turret_ref != null else null
	set(value):
		_turret_ref = weakref(value) if value != null else null
var _rear_flash_textures: Array[Texture2D] = []
var _model_fx_texture_cache: Dictionary = {}
var _muzzle_bank_particle_index := 0
var _casing_particle_index := 0
var _casing_timeline_tween: Tween
var _particle_timeline_tweens: Array[Tween] = []
var _stream_particle_index := 0
var _authored_fire_fx_active := false
var _fx_random := RandomNumberGenerator.new()
func configure(turret) -> void:
	_turret = turret
	_fx_random.randomize()


func spawn_muzzle_flash(parent: Node, emission: Dictionary) -> void:
	_spawn_muzzle_flash(parent, emission)


func spawn_shot_light(parent: Node, emission: Dictionary) -> void:
	_spawn_shot_light(parent, emission)


func spawn_auxiliary_muzzle_effects(parent: Node, emission: Dictionary) -> void:
	_spawn_auxiliary_muzzle_effects(parent, emission)


func particle_timeline_tweens() -> Array[Tween]:
	return _particle_timeline_tweens


func start_authored_fire_fx(
		animation_name: StringName,
		parent: Node = null,
		playback_speed := 1.0
	) -> bool:
	cancel_authored_fire_fx()
	var casing_started := _start_model_casing_timeline(
		animation_name, parent, playback_speed
	)
	# Non-casing model banks on ordinary guns describe short muzzle smoke and
	# blast accents, not sustained projectile streams. Replaying their authored
	# speed as forward travel turns those accents into long rows of fast puffs.
	# Continuous bullets are the only weapons whose Fire banks represent a
	# visible stream; discrete weapons still retain their separate casing bank
	# and TurretMuzzleFlash effect.
	var particles_started := false
	if _turret.is_continuous_bullet():
		particles_started = _start_model_particle_timelines(
			animation_name, parent, playback_speed
		)
	_authored_fire_fx_active = casing_started or particles_started
	return _authored_fire_fx_active


func has_authored_fire_fx() -> bool:
	return _authored_fire_fx_active


func cancel_authored_fire_fx() -> void:
	_authored_fire_fx_active = false
	if _casing_timeline_tween != null and _casing_timeline_tween.is_valid():
		_casing_timeline_tween.kill()
	_casing_timeline_tween = null
	for timeline in _particle_timeline_tweens:
		if timeline != null and timeline.is_valid():
			timeline.kill()
	_particle_timeline_tweens.clear()


func _start_model_casing_timeline(
		animation_name: StringName,
		parent: Node,
		playback_speed: float
	) -> bool:
	if _turret._fx_model_root == null or not is_instance_valid(_turret._fx_model_root) \
	or not bool(_turret._fx_model_root.get_meta("xbf_fx_events_complete", false)):
		return false
	var bank := _fx_bank_by_texture(
		_turret._fx_model_root.get_meta("xbf_fx_banks", []) as Array,
		CASING_SEQUENCE
	)
	if bank.is_empty():
		return false
	var animation_entry := _model_animation_entry(animation_name)
	if animation_entry.is_empty():
		return false
	var schedule := _fx_bank_schedule(
		String(bank.get("id", "")),
		int(animation_entry.get("start_frame", 0)),
		int(animation_entry.get("end_frame", 0))
	)
	if schedule.is_empty():
		return false
	var frame_count := int(bank.get("texture_frame_count", 0))
	var textures := _muzzle_bank_textures(CASING_SEQUENCE, frame_count)
	if textures.size() != frame_count:
		return false
	var resolved_parent: Node = parent if parent != null else _turret._default_projectile_parent()
	if resolved_parent == null or not resolved_parent.is_inside_tree():
		return false

	var base_frame := int(animation_entry.get("start_frame", 0))
	var seconds_per_frame := INLINE_FX_FRAME_SECONDS / maxf(playback_speed, 0.001)
	var world_scale := float(_turret._fx_model_root.get_meta("xbf_world_scale", 1.0))
	var callbacks: Array[Dictionary] = []
	for scheduled_value: Dictionary in schedule:
		var attachment := String(scheduled_value.get("attachment", ""))
		var marker := _find_original_node(_turret._fx_model_root, attachment)
		if marker == null:
			continue
		callbacks.append({
			"frame": int(scheduled_value.get("frame", base_frame)),
			"callback": _emit_casing_particle.bind(
				weakref(resolved_parent), weakref(marker), bank, textures, world_scale,
				attachment, callbacks.size()
			),
		})
	_casing_timeline_tween = AuthoredFxBankScript.start_timeline(
		_turret._fx_model_root, callbacks, base_frame, seconds_per_frame,
		seconds_per_frame
	)
	if _casing_timeline_tween == null:
		return false
	_casing_timeline_tween.finished.connect(_finish_casing_timeline)
	return true


func _finish_casing_timeline() -> void:
	_casing_timeline_tween = null


func _start_model_particle_timelines(
		animation_name: StringName,
		parent: Node,
		playback_speed: float
	) -> bool:
	if _turret._fx_model_root == null or not is_instance_valid(_turret._fx_model_root) \
	or not bool(_turret._fx_model_root.get_meta("xbf_fx_events_complete", false)):
		return false
	var animation_entry := _model_animation_entry(animation_name)
	if animation_entry.is_empty():
		return false
	var resolved_parent: Node = parent if parent != null else _turret._default_projectile_parent()
	if resolved_parent == null or not resolved_parent.is_inside_tree():
		return false

	var clip_start := int(animation_entry.get("start_frame", 0))
	var clip_end := int(animation_entry.get("end_frame", 0))
	var seconds_per_frame := INLINE_FX_FRAME_SECONDS / maxf(playback_speed, 0.001)
	var world_scale := float(_turret._fx_model_root.get_meta("xbf_world_scale", 1.0))
	var jet_reach_world: float = _turret._continuous_jet_reach_world()
	var started := false
	for bank_value: Variant in _turret._fx_model_root.get_meta("xbf_fx_banks", []) as Array:
		var bank := bank_value as Dictionary
		var texture_name := String(bank.get("texture", ""))
		if texture_name.nocasecmp_to(CASING_SEQUENCE) == 0:
			continue
		var schedule := _stream_fx_bank_schedule(
			String(bank.get("id", "")), clip_start, clip_end
		)
		if schedule.is_empty():
			continue
		var frame_count := maxi(int(bank.get("texture_frame_count", 1)), 1)
		var textures := _model_fx_bank_textures(texture_name, frame_count)
		if textures.size() != frame_count:
			continue

		var callbacks: Array[Dictionary] = []
		for scheduled_value: Dictionary in schedule:
			var attachment := String(scheduled_value.get("attachment", ""))
			var marker := _find_original_node(_turret._fx_model_root, attachment)
			if marker == null:
				continue
			callbacks.append({
				"frame": int(scheduled_value.get("frame", clip_start)),
				"callback": _emit_model_stream_particles.bind(
					weakref(resolved_parent), weakref(marker), bank, textures,
					world_scale, attachment, jet_reach_world
				),
			})
		var timeline := AuthoredFxBankScript.start_timeline(
			_turret._fx_model_root, callbacks, clip_start, seconds_per_frame,
			seconds_per_frame
		)
		if timeline == null:
			continue
		_particle_timeline_tweens.append(timeline)
		timeline.finished.connect(_finish_particle_timeline.bind(timeline))
		started = true
	return started


func _finish_particle_timeline(timeline: Tween) -> void:
	_particle_timeline_tweens.erase(timeline)


func _stream_fx_bank_schedule(
		bank_id: String,
		clip_start_frame: int,
		clip_end_frame: int
	) -> Array[Dictionary]:
	return AuthoredFxBankScript.particle_schedule(
		_turret._fx_model_root.get_meta("xbf_fx_events", []) as Array,
		bank_id, clip_start_frame, clip_end_frame,
		_is_projectile_fx_attachment, true
	)




func _is_projectile_fx_attachment(attachment: String) -> bool:
	var lower := attachment.to_lower()
	return lower.begins_with(MUZZLE_MARKER) or lower.contains("gun")


func _emit_model_stream_particles(
		parent_ref: WeakRef,
		marker_ref: WeakRef,
		bank: Dictionary,
		textures: Array[Texture2D],
		world_scale: float,
		attachment: String,
		jet_reach_world: float
	) -> void:
	var parent := parent_ref.get_ref() as Node if parent_ref != null else null
	var marker := marker_ref.get_ref() as Node3D if marker_ref != null else null
	if parent == null or not parent.is_inside_tree() \
	or marker == null or not is_instance_valid(marker) or textures.is_empty():
		return
	var particles_per_frame := 1
	var parameters: Variant = bank.get("int_parameters_0_3", [])
	if _fx_parameter_count(parameters) >= 2:
		particles_per_frame = clampi(int(parameters[1]), 1, 8)
	if _is_jet_bank(bank, jet_reach_world):
		particles_per_frame = clampi(
			particles_per_frame * JET_DENSITY_MULTIPLIER,
			JET_MIN_PARTICLES_PER_EMISSION,
			JET_MAX_PARTICLES_PER_EMISSION
		)
	for particle_number in particles_per_frame:
		_emit_model_stream_particle(
			parent, marker, bank, textures, world_scale,
			attachment, particle_number, particles_per_frame, jet_reach_world
		)


func _emit_model_stream_particle(
		parent: Node,
		marker: Node3D,
		bank: Dictionary,
		textures: Array[Texture2D],
		world_scale: float,
		attachment: String,
		particle_number: int,
		particles_per_frame: int,
		jet_reach_world: float
	) -> void:
	var stream := StreamParticleScript.new()
	stream.parent = parent
	stream.bank = bank
	stream.textures = textures
	stream.jet_reach_world = jet_reach_world
	stream.number = particle_number
	stream.per_frame = particles_per_frame
	var particle := Node3D.new()
	stream.node = particle
	particle.name = "AuthoredStream_%d_%d" % [
		_turret._weapon_index, _stream_particle_index,
	]
	particle.set_meta("combat_muzzle_fx", &"authored_stream")
	particle.set_meta("emission_index", particle_number)
	particle.set_meta("combat_fx_bank_id", StringName(String(bank.get("id", ""))))
	particle.set_meta("combat_fx_texture", StringName(String(bank.get("texture", ""))))
	particle.set_meta("combat_fx_attachment", attachment)
	_stream_particle_index += 1
	var start := marker.global_position
	stream.start = start
	particle.set_meta("combat_muzzle_start_position", start)

	var particle_size := float(bank.get(
		"world_particle_size",
		float(bank.get("particle_size", 0.0)) * world_scale
	))
	var material := _fx_bank_material(bank, textures.front())
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * particle_size
	quad.material = material
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = quad
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particle.add_child(visual)
	particle.set_meta("combat_fx_particle_size", particle_size)
	stream.material = material
	stream.quad = quad
	stream.visual = visual
	stream.size = particle_size

	var direction := Vector3(
		_turret.peek_emission().get("direction", marker.global_basis * AUTHORED_MUZZLE_FORWARD)
	).normalized()
	if direction.is_zero_approx():
		direction = Vector3.FORWARD
	stream.direction = direction
	var integer_parameters: Variant = bank.get("int_parameters_0_3", [])
	var spread_degrees := float(integer_parameters[3]) \
		if _fx_parameter_count(integer_parameters) >= 4 else 0.0
	stream.spread_degrees = spread_degrees
	var source_gravity := float(bank.get("gravity", _fx_bank_gravity(bank)))
	var world_gravity := float(bank.get(
		"world_gravity",
		source_gravity * world_scale \
			* AIM_UPDATES_PER_SECOND * AIM_UPDATES_PER_SECOND
	))
	particle.set_meta("combat_fx_source_gravity", source_gravity)
	var duration := float(textures.size()) * INLINE_FX_FRAME_SECONDS
	stream.world_gravity = world_gravity
	stream.duration = duration

	if _is_jet_bank(bank, jet_reach_world):
		_launch_jet_particle(stream)
		return

	direction = _random_stream_direction(direction, spread_degrees)
	var float_parameters: Variant = bank.get("float_parameters_4_6", [])
	var source_speed := float(float_parameters[0]) \
		if _fx_parameter_count(float_parameters) >= 1 else 0.0
	var variation_parameters: Variant = bank.get("float_parameters_12_14", [])
	var source_speed_variation := absf(float(variation_parameters[0])) \
		if _fx_parameter_count(variation_parameters) >= 1 else 0.0
	var varied_source_speed := maxf(
		source_speed + _fx_random.randf_range(
			-source_speed_variation, source_speed_variation
		),
		0.0
	)
	var velocity := direction * varied_source_speed * world_scale \
		* AIM_UPDATES_PER_SECOND
	var acceleration := Vector3.DOWN * world_gravity
	AuthoredFxBankScript.spawn_frame_animated_quad(parent, textures, {
		"particle": particle,
		"visual": visual,
		"name": particle.name,
		"position": start,
		"size": particle_size,
		"tint": material.albedo_color,
		"frame_seconds": INLINE_FX_FRAME_SECONDS,
		"opacities": _fx_bank_frame_opacities(bank, textures.size()),
		"velocity": velocity,
		"acceleration": acceleration,
		"metadata": {
			"combat_muzzle_velocity": velocity,
			"combat_muzzle_acceleration": acceleration,
		},
	})


## True for a bank that draws the visible stream of a continuous weapon: the
## flamethrowers' burning fuel, the Chemical Trooper's spray. `jet_reach_world`
## is only positive for a `Continuous` bullet, and a stream bank is the one
## that actually launches its particles away from the nozzle — which excludes
## the same weapons' zero-speed pilot-light banks and the Flame Tank's
## stationary drum smoke, matched by authored speed rather than by texture name
## so a gas spray drawn with a smoke texture is still treated as a jet.
func _is_jet_bank(bank: Dictionary, jet_reach_world: float) -> bool:
	if jet_reach_world <= 0.0:
		return false
	var parameters: Variant = bank.get("float_parameters_4_6", [])
	if _fx_parameter_count(parameters) < 1:
		return false
	return float(parameters[0]) > 0.0


## Set up one jet particle's whole life — travel, growth, tint and fade are all
## driven from a single normalized age so they stay in step. The authored bank
## contributes the sprite sheet, the base size, the colour and the gravity; the
## jet shape itself is derived from the bullet's real reach, because the source
## banks were authored for a much shorter particle reach than a converted
## weapon's `MaxRange`.
func _launch_jet_particle(stream: StreamParticle) -> void:
	var cone_degrees := clampf(
		absf(stream.spread_degrees) * 0.25, JET_CONE_MIN_DEGREES, JET_CONE_MAX_DEGREES
	)
	var axis := _random_stream_direction(stream.direction, cone_degrees)
	var start := _jittered_stream_start(stream.start, axis, stream.size)
	stream.node.set_meta("combat_muzzle_start_position", start)

	var side := axis.cross(Vector3.UP)
	if side.is_zero_approx():
		side = axis.cross(Vector3.RIGHT)
	side = side.normalized()
	var flare_angle := _fx_random.randf_range(0.0, TAU)
	var flare_direction := side * cos(flare_angle) \
		+ axis.cross(side).normalized() * sin(flare_angle)

	var life := stream.duration * _fx_random.randf_range(1.0 - JET_LIFE_VARIATION, 1.0)
	var reach := stream.jet_reach_world * _fx_random.randf_range(
		1.0 - JET_REACH_VARIATION, 1.0 + JET_REACH_VARIATION
	)
	# Every particle of one emission would otherwise leave the nozzle at the
	# same instant from the same point, turning a stream into a march of
	# discrete puffs one source frame apart. Spreading their launch times
	# across the frame they belong to — by starting each one already that far
	# into its own life — makes the column continuous.
	var launch_age := (float(stream.number) + _fx_random.randf()) \
		/ float(maxi(stream.per_frame, 1)) * INLINE_FX_FRAME_SECONDS
	var launch_fraction := clampf(launch_age / maxf(life, 0.0001), 0.0, 0.9)

	var jet := StreamParticleScript.Jet.new()
	jet.start = start
	jet.axis = axis
	jet.flare_direction = flare_direction
	jet.reach = reach
	jet.life = life
	jet.gravity = stream.world_gravity
	jet.base_size = stream.size * _fx_random.randf_range(
		1.0 - JET_SIZE_VARIATION, 1.0 + JET_SIZE_VARIATION
	)
	jet.textures = stream.textures
	jet.tint = stream.material.albedo_color
	jet.is_fire = String(stream.bank.get("texture", "")).to_lower().contains("fire")
	jet.frame_opacities = _fx_bank_frame_opacities(stream.bank, stream.textures.size())

	# Mirroring the sprite sheet per particle costs nothing and breaks up the
	# repetition of one authored flame shape stamped over and over.
	var material := stream.material
	material.uv1_scale = Vector3(
		-1.0 if _fx_random.randi() % 2 == 0 else 1.0,
		-1.0 if _fx_random.randi() % 2 == 0 else 1.0,
		1.0
	)
	material.uv1_offset = Vector3(
		1.0 if material.uv1_scale.x < 0.0 else 0.0,
		1.0 if material.uv1_scale.y < 0.0 else 0.0,
		0.0
	)
	stream.quad.size = Vector2.ONE * jet.base_size

	var particle := stream.node
	particle.set_meta("combat_fx_particle_size", jet.base_size)
	particle.set_meta("combat_muzzle_velocity", axis * reach / maxf(life, 0.0001))
	particle.set_meta("combat_muzzle_acceleration", Vector3.DOWN * stream.world_gravity)
	stream.parent.add_child(particle)
	particle.top_level = true
	_update_jet_particle(launch_fraction, stream, jet)

	var motion := particle.create_tween().set_process_mode(
		Tween.TWEEN_PROCESS_PHYSICS
	)
	motion.tween_method(
		_update_jet_particle.bind(stream, jet),
		launch_fraction, 1.0, life * (1.0 - launch_fraction)
	)
	motion.finished.connect(particle.queue_free)


func _update_jet_particle(
		age: float, stream: StreamParticle, jet: StreamParticle.Jet
	) -> void:
	var particle := stream.node
	if particle == null or not is_instance_valid(particle):
		return
	var t := clampf(age, 0.0, 1.0)
	var reach := jet.reach
	# Fuel leaves the nozzle fast and gives its momentum up to the air, so the
	# stream is dense and bright close in and piles up at its own tip. Flare
	# and rise grow with t^2 so the column stays a tight rod at the muzzle and
	# only opens into a plume where it is burning out.
	var travel := reach * (1.0 - pow(1.0 - t, JET_DECELERATION_EXPONENT))
	var spread := t * t
	particle.global_position = jet.start \
		+ jet.axis * travel \
		+ jet.flare_direction * reach * JET_FLARE_REACH_FRACTION * spread \
		+ Vector3.UP * reach * JET_BUOYANCY_REACH_FRACTION * spread \
		+ Vector3.DOWN * jet.gravity * 0.5 * pow(t * jet.life, 2.0)

	stream.quad.size = Vector2.ONE * jet.base_size \
		* lerpf(JET_START_SCALE, JET_END_SCALE, t)

	var frame_index := clampi(
		int(t * float(jet.textures.size())), 0, jet.textures.size() - 1
	)
	stream.material.albedo_texture = jet.textures[frame_index]
	var color := jet.tint
	if jet.is_fire:
		color = color.lerp(JET_EMBER_COLOR, smoothstep(0.35, 1.0, t))
	color.a = jet.frame_opacities[frame_index] * _jet_envelope(t)
	stream.material.albedo_color = color


## Opacity envelope over a jet particle's life: a short ignition ramp so fuel
## does not appear at full brightness inside the nozzle, and a long burnout so
## the tip of the stream dissolves. The authored banks' own frame opacity ramp
## bottoms out around a third rather than at zero, which would otherwise pop
## every particle out of existence mid-flame.
func _jet_envelope(t: float) -> float:
	if t < JET_IGNITION_FRACTION:
		return t / JET_IGNITION_FRACTION
	if t > 1.0 - JET_BURNOUT_FRACTION:
		return (1.0 - t) / JET_BURNOUT_FRACTION
	return 1.0


func _fx_bank_frame_opacities(bank: Dictionary, count: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	for frame_index in count:
		result.append(_fx_bank_frame_opacity(bank, frame_index))
	return result


func _random_stream_direction(direction: Vector3, spread_degrees: float) -> Vector3:
	var spread := deg_to_rad(clampf(absf(spread_degrees), 0.0, 60.0))
	if spread <= 0.0001:
		return direction
	var yaw := _fx_random.randf_range(-spread, spread)
	var pitch := _fx_random.randf_range(-spread, spread)
	var result := direction.rotated(Vector3.UP, yaw)
	var side := result.cross(Vector3.UP).normalized()
	if side.is_zero_approx():
		side = Vector3.RIGHT
	return result.rotated(side, pitch).normalized()


## Sideways spawn offset for one jet particle, within a nozzle-width disc
## perpendicular to `direction`. Several particles per source frame all leaving
## from the exact same point read as one thick sprite rather than a stream, and
## the Flame Tank's banks author no spread at all, so the jitter comes from the
## nozzle's own width instead of from the authored spread angle.
func _jittered_stream_start(
		start: Vector3, direction: Vector3, particle_size: float
	) -> Vector3:
	var jitter_radius := particle_size * JET_NOZZLE_JITTER_SCALE
	if jitter_radius <= 0.0001:
		return start
	var side := direction.cross(Vector3.UP)
	if side.is_zero_approx():
		side = Vector3.RIGHT
	side = side.normalized()
	var up := direction.cross(side).normalized()
	var angle := _fx_random.randf_range(0.0, TAU)
	var radius := _fx_random.randf_range(0.0, jitter_radius)
	return start + (side * cos(angle) + up * sin(angle)) * radius


func _model_fx_bank_textures(
		base_name: String,
		count: int
	) -> Array[Texture2D]:
	var cache_key := "%s:%d" % [base_name.to_lower(), count]
	var result: Array[Texture2D] = []
	if _model_fx_texture_cache.has(cache_key):
		for texture: Texture2D in _model_fx_texture_cache[cache_key]:
			result.append(texture)
		return result
	var textures: Array[Texture2D] = _muzzle_bank_textures(base_name, count)
	if not textures.is_empty() or count != 1:
		if not textures.is_empty():
			_model_fx_texture_cache[cache_key] = textures.duplicate()
		return textures
	var source_path := AuthoredFxBankScript.resolved_texture_path(base_name + ".tga")
	var source_texture := load(source_path) as Texture2D \
		if not source_path.is_empty() else null
	if source_texture != null:
		textures.append(AuthoredFxBankScript.opaque_additive_texture(source_texture))
		_model_fx_texture_cache[cache_key] = textures.duplicate()
	return textures


func _fx_parameter_count(parameters: Variant) -> int:
	if parameters is Array \
	or parameters is PackedInt32Array \
	or parameters is PackedInt64Array \
	or parameters is PackedFloat32Array \
	or parameters is PackedFloat64Array:
		return parameters.size()
	return 0


func _model_animation_entry(animation_name: StringName) -> Dictionary:
	if _turret._fx_model_root == null or not is_instance_valid(_turret._fx_model_root):
		return {}
	var wanted := String(animation_name).strip_edges().replace(" ", "_")
	var entries := _turret._fx_model_root.get_meta("xbf_animation_entries", []) as Array
	for entry_value: Variant in entries:
		var entry := entry_value as Dictionary
		var candidate := String(entry.get("name", "")).strip_edges().replace(" ", "_")
		if candidate.nocasecmp_to(wanted) == 0:
			return entry
	return {}


func _fx_bank_schedule(
		bank_id: String, clip_start_frame: int, clip_end_frame: int
	) -> Array[Dictionary]:
	return AuthoredFxBankScript.particle_schedule(
		_turret._fx_model_root.get_meta("xbf_fx_events", []) as Array,
		bank_id, clip_start_frame, clip_end_frame
	)


func _emit_casing_particle(
		parent_ref: WeakRef,
		marker_ref: WeakRef,
		bank: Dictionary,
		textures: Array[Texture2D],
		world_scale: float,
		attachment: String,
		particle_number: int
	) -> void:
	var parent := parent_ref.get_ref() as Node if parent_ref != null else null
	var marker := marker_ref.get_ref() as Node3D if marker_ref != null else null
	if parent == null or not parent.is_inside_tree() \
	or marker == null or not is_instance_valid(marker) or textures.is_empty():
		return
	var particle_size := float(bank.get(
		"world_particle_size",
		float(bank.get("particle_size", 0.0)) * world_scale
	))
	var source_gravity := float(bank.get("gravity", _fx_bank_gravity(bank)))
	var world_gravity := float(bank.get(
		"world_gravity",
		source_gravity * world_scale \
			* AIM_UPDATES_PER_SECOND * AIM_UPDATES_PER_SECOND
	))
	var acceleration := Vector3.DOWN * world_gravity
	var current_emission: Dictionary = _turret.peek_emission()
	var firing_direction := Vector3(
		current_emission.get("direction", Vector3.FORWARD)
	).normalized()
	if firing_direction.is_zero_approx():
		firing_direction = Vector3.FORWARD
	var eject_direction := -firing_direction
	var side := eject_direction.cross(Vector3.UP).normalized()
	if side.is_zero_approx():
		side = Vector3.RIGHT
	var variation := particle_number % 3
	var side_sign := -1.0 if particle_number % 2 == 0 else 1.0
	var velocity := (
		eject_direction * (1.4 + 0.2 * variation)
		+ Vector3.UP * (1.55 + 0.15 * variation)
		+ side * (0.35 * side_sign)
	)

	var particle_name := "Casing_%d_%d" % [
		_turret._weapon_index, _casing_particle_index
	]
	_casing_particle_index += 1
	var start := marker.global_position
	AuthoredFxBankScript.spawn_frame_animated_quad(parent, textures, {
		"name": particle_name,
		"position": start,
		"size": particle_size,
		"tint": _fx_bank_material(bank, textures.front()).albedo_color,
		"frame_seconds": INLINE_FX_FRAME_SECONDS,
		"opacities": _fx_bank_frame_opacities(bank, textures.size()),
		"velocity": velocity,
		"acceleration": acceleration,
		"metadata": {
			"combat_muzzle_fx": &"casing",
			"emission_index": particle_number,
			"combat_fx_bank_id": StringName(String(bank.get("id", ""))),
			"combat_fx_texture": StringName(String(bank.get("texture", ""))),
			"combat_fx_attachment": attachment,
			"combat_fx_particle_size": particle_size,
			"combat_fx_source_gravity": source_gravity,
			"combat_muzzle_acceleration": acceleration,
			"combat_muzzle_velocity": velocity,
			"combat_muzzle_start_position": start,
		},
	})


func _spawn_muzzle_flash(parent: Node, emission: Dictionary) -> void:
	if _turret.muzzle_flash_scene == null or parent == null or not parent.is_inside_tree():
		return
	var authored_visual := _turret.muzzle_flash_scene.instantiate() as Node3D
	if authored_visual == null:
		return
	if _turret.muzzle_flash_id == &"Muzzle3":
		_scale_muzzle3_primary_mesh(authored_visual)
	elif _turret.muzzle_flash_id == &"Ltmuzzle":
		authored_visual.scale *= LASER_MUZZLE_VISUAL_SCALE
	var effect := Node3D.new()
	effect.name = "MuzzleFlash_%s" % String(_turret.muzzle_flash_id)
	effect.set_meta("combat_muzzle_fx", &"front_flash")
	parent.add_child(effect)
	effect.top_level = true
	effect.global_position = Vector3(emission.get("position", Vector3.ZERO))
	var direction := Vector3(emission.get("direction", Vector3.FORWARD)).normalized()
	if direction.is_zero_approx():
		direction = Vector3.FORWARD
	var up := Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.999 \
		else Vector3.UP
	effect.global_basis = Basis.looking_at(direction, up, true)
	authored_visual.name = "Visual"
	effect.add_child(authored_visual)
	var bank_emission_lifetime := _start_barrel_smoke_bank(
		parent, effect, authored_visual, emission
	)

	var lifetime := DEFAULT_MUZZLE_FLASH_DURATION
	var player := authored_visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player != null:
		var animation_name := &"Stationary" if player.has_animation(&"Stationary") \
			else &"timeline"
		if player.has_animation(animation_name):
			player.play(animation_name)
			var animation := player.get_animation(animation_name)
			if animation != null:
				# Standalone muzzle effects use a source clip named Stationary, but
				# unlike a unit idle it is a one-shot. Prevent a last-frame wrap to
				# the bright first frame before the cleanup timer removes the effect.
				animation.loop_mode = Animation.LOOP_NONE
				lifetime = maxf(animation.length, 1.0 / AIM_UPDATES_PER_SECOND)
	lifetime = maxf(lifetime, bank_emission_lifetime)
	var cleanup := Timer.new()
	cleanup.name = "Cleanup"
	cleanup.one_shot = true
	cleanup.wait_time = lifetime
	effect.add_child(cleanup)
	cleanup.timeout.connect(effect.queue_free)
	cleanup.start()


func _start_barrel_smoke_bank(
		parent: Node,
		effect: Node3D,
		authored_visual: Node3D,
		emission: Dictionary
	) -> float:
	if not bool(authored_visual.get_meta("xbf_fx_events_complete", false)):
		return 0.0
	var banks := authored_visual.get_meta("xbf_fx_banks", []) as Array
	var smoke_bank := _fx_bank_by_texture(banks, BARREL_SMOKE_SEQUENCE)
	if smoke_bank.is_empty():
		return 0.0
	var frame_count := int(smoke_bank.get("texture_frame_count", 0))
	var textures := _muzzle_bank_textures(BARREL_SMOKE_SEQUENCE, frame_count)
	if textures.size() != frame_count:
		return 0.0

	var events := authored_visual.get_meta("xbf_fx_events", []) as Array
	var scheduled := AuthoredFxBankScript.particle_schedule(
		events, String(smoke_bank.get("id", "")), -2147483648, 2147483647
	)
	if scheduled.is_empty():
		return 0.0

	var world_scale := float(authored_visual.get_meta("xbf_world_scale", 1.0))
	var emitted_index := int(emission.get("index", 0))
	var callbacks: Array[Dictionary] = []
	for scheduled_value: Dictionary in scheduled:
		var marker := _find_original_node(
			authored_visual, String(scheduled_value["attachment"])
		)
		if marker == null:
			continue
		callbacks.append({
			"frame": int(scheduled_value["frame"]),
			"callback": _emit_barrel_smoke_particle.bind(
				parent, marker, smoke_bank, textures, world_scale, emitted_index
			),
		})
	var timeline := AuthoredFxBankScript.start_timeline(
		effect, callbacks, 0, INLINE_FX_FRAME_SECONDS
	)
	if timeline == null:
		return 0.0
	return float(int(callbacks.back()["frame"]) + 1) * INLINE_FX_FRAME_SECONDS


func _emit_barrel_smoke_particle(
		parent: Node,
		marker: Node3D,
		bank: Dictionary,
		textures: Array[Texture2D],
		world_scale: float,
		emission_index: int
	) -> void:
	if parent == null or not parent.is_inside_tree() \
	or marker == null or not is_instance_valid(marker) or textures.is_empty():
		return
	var particle_name := "BarrelSmoke_%d_%d" % [
		emission_index, _muzzle_bank_particle_index,
	]
	_muzzle_bank_particle_index += 1
	var start := marker.global_position
	var particle_size := float(bank.get(
		"world_particle_size",
		float(bank.get("particle_size", 0.0)) * world_scale
	))
	var source_gravity := float(bank.get("gravity", _fx_bank_gravity(bank)))
	var world_gravity := float(bank.get(
		"world_gravity",
		source_gravity * world_scale \
			* AIM_UPDATES_PER_SECOND * AIM_UPDATES_PER_SECOND
	))
	var acceleration := Vector3.DOWN * world_gravity
	AuthoredFxBankScript.spawn_frame_animated_quad(parent, textures, {
		"name": particle_name,
		"position": start,
		"size": particle_size,
		"tint": _fx_bank_material(bank, textures.front()).albedo_color,
		"frame_seconds": INLINE_FX_FRAME_SECONDS,
		"opacities": _fx_bank_frame_opacities(bank, textures.size()),
		"acceleration": acceleration,
		"metadata": {
			"combat_muzzle_fx": &"barrel_smoke",
			"emission_index": emission_index,
			"combat_fx_bank_id": StringName(String(bank.get("id", ""))),
			"combat_fx_texture": StringName(String(bank.get("texture", ""))),
			"combat_fx_particle_size": particle_size,
			"combat_fx_source_gravity": source_gravity,
			"combat_muzzle_acceleration": acceleration,
			"combat_muzzle_start_position": start,
		},
	})


func _fx_bank_by_texture(banks: Array, texture_name: String) -> Dictionary:
	for bank_value: Variant in banks:
		var bank := bank_value as Dictionary
		if String(bank.get("texture", "")).nocasecmp_to(texture_name) == 0:
			return bank
	return {}


func _find_original_node(node: Node, original_name: String) -> Node3D:
	return AuthoredFxBankScript.find_original_node(node, original_name)


func _muzzle_bank_textures(base_name: String, count: int) -> Array[Texture2D]:
	if count <= 0:
		var empty: Array[Texture2D] = []
		return empty
	var textures: Array[Texture2D] = _load_fx_texture_sequence(base_name, count)
	if textures.size() != count:
		textures.clear()
	return textures


func _fx_bank_material(
		bank: Dictionary, texture: Texture2D
	) -> StandardMaterial3D:
	var tint := Color.WHITE
	var colors: Variant = bank.get("int_parameters_7_11", [])
	if _fx_parameter_count(colors) >= 3:
		tint = Color(
			clampf(float(colors[0]) / 255.0, 0.0, 1.0),
			clampf(float(colors[1]) / 255.0, 0.0, 1.0),
			clampf(float(colors[2]) / 255.0, 0.0, 1.0),
			_fx_bank_frame_opacity(bank, 0)
		)
	return AuthoredFxBankScript.billboard_material(texture, tint)


func _fx_bank_gravity(bank: Dictionary) -> float:
	var parameters: Variant = bank.get("float_parameters_4_6", [])
	if _fx_parameter_count(parameters) < 2:
		return 0.0
	return float(parameters[1])


func _fx_bank_frame_opacity(bank: Dictionary, frame_index: int) -> float:
	var trailing: Variant = bank.get("trailing_words", [])
	if _fx_parameter_count(trailing) < 2:
		return 1.0
	return clampf(
		float(trailing[0] + trailing[1] * frame_index) / 255.0,
		0.0, 1.0
	)






func _scale_muzzle3_primary_mesh(authored_visual: Node3D) -> void:
	var primary_mesh := authored_visual.find_child(
		MUZZLE3_PRIMARY_MESH, true, false
	) as MeshInstance3D
	if primary_mesh == null:
		return
	var mesh_parent := primary_mesh.get_parent() as Node3D
	if mesh_parent == null:
		return

	# Muzzle3 animates Mesh_00's transform. Keep that authored track targeting
	# a proxy while the actual mesh remains at half size beneath it.
	var authored_transform := primary_mesh.transform
	var sibling_index := primary_mesh.get_index()
	primary_mesh.name = "%s_Visual" % MUZZLE3_PRIMARY_MESH
	var animated_transform := Node3D.new()
	animated_transform.name = MUZZLE3_PRIMARY_MESH
	mesh_parent.add_child(animated_transform)
	mesh_parent.move_child(animated_transform, sibling_index)
	animated_transform.transform = authored_transform
	primary_mesh.reparent(animated_transform, false)
	primary_mesh.transform = Transform3D(
		Basis.from_scale(Vector3.ONE * MUZZLE3_PRIMARY_SCALE), Vector3.ZERO
	)


func _spawn_auxiliary_muzzle_effects(parent: Node, emission: Dictionary) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	if emission.has("smoke_position"):
		_spawn_launch_smoke(parent, emission)
	if not emission.has("rear_position"):
		return
	_ensure_inline_fx_textures()
	if _rear_flash_textures.size() == REAR_FLASH_FRAME_COUNT:
		_spawn_rear_flash(parent, emission)


## Replays the launcher's own backblast bank: the Mongoose's 16-frame `!cexp`
## puff, the Devastator's 20-frame `!exp0` rocket flare. The authored start/stop
## pair spans a single frame, so the baked billboard cannot show the sequence -
## the model only marks where and when it goes off.
func _spawn_launch_smoke(parent: Node, emission: Dictionary) -> void:
	var bank := _fx_bank_by_id(String(emission.get("smoke_bank_id", "")))
	var sequence := String(bank.get("texture", LAUNCH_SMOKE_SEQUENCE))
	var frame_count := int(bank.get("texture_frame_count", LAUNCH_SMOKE_FRAME_COUNT))
	var textures := _model_fx_bank_textures(sequence, frame_count)
	if textures.size() != frame_count or textures.is_empty():
		return
	var effect := Node3D.new()
	effect.name = "LaunchSmoke_%d" % int(emission.get("index", 0))
	effect.set_meta("combat_muzzle_fx", &"launch_smoke")
	effect.set_meta("emission_index", int(emission.get("index", 0)))
	parent.add_child(effect)
	effect.top_level = true
	effect.global_position = Vector3(emission["smoke_position"])
	var visual := _fx_quad(textures.front(), _launch_smoke_size(bank))
	visual.name = "Visual"
	effect.add_child(visual)
	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D
	var animation := effect.create_tween()
	for texture in textures:
		animation.tween_callback(_set_fx_texture.bind(material, texture))
		animation.tween_interval(INLINE_FX_FRAME_SECONDS)
	animation.finished.connect(effect.queue_free)


## LAUNCH_SMOKE_SIZE is the on-screen size hand-picked for the Mongoose's
## backblast, whose bank authors LAUNCH_SMOKE_REFERENCE_PARTICLE_SIZE. Carry
## that same tuning to a launcher with a differently sized bank rather than
## reading the source size as world units, so the Mongoose keeps its look.
func _launch_smoke_size(bank: Dictionary) -> float:
	var particle_size := float(
		bank.get("particle_size", LAUNCH_SMOKE_REFERENCE_PARTICLE_SIZE)
	)
	if particle_size <= 0.0:
		return LAUNCH_SMOKE_SIZE
	return LAUNCH_SMOKE_SIZE * particle_size / LAUNCH_SMOKE_REFERENCE_PARTICLE_SIZE


func _fx_bank_by_id(bank_id: String) -> Dictionary:
	if bank_id.is_empty() or _turret == null \
	or _turret._fx_model_root == null or not is_instance_valid(_turret._fx_model_root):
		return {}
	for bank_value: Variant in _turret._fx_model_root.get_meta("xbf_fx_banks", []) as Array:
		var bank := bank_value as Dictionary
		if String(bank.get("id", "")) == bank_id:
			return bank
	return {}


func _spawn_shot_light(parent: Node, emission: Dictionary) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var shot_direction := Vector3(
		emission.get("direction", Vector3.FORWARD)
	).normalized()
	if shot_direction.is_zero_approx():
		shot_direction = Vector3.FORWARD
	var rear_direction := Vector3(
		emission.get("rear_direction", -shot_direction)
	).normalized()
	if rear_direction.is_zero_approx():
		rear_direction = -shot_direction
	var origin := Vector3(
		emission.get(
			"rear_position",
			emission.get("smoke_position", emission.get("position", Vector3.ZERO))
		)
	)

	var light := OmniLight3D.new()
	light.name = "ShotLight_%d" % int(emission.get("index", 0))
	light.set_meta("combat_muzzle_fx", &"shot_light")
	light.set_meta("emission_index", int(emission.get("index", 0)))
	light.light_color = SHOT_LIGHT_COLOR
	light.light_energy = SHOT_LIGHT_ENERGY
	light.omni_range = SHOT_LIGHT_RANGE
	light.shadow_enabled = false
	parent.add_child(light)
	light.top_level = true
	light.global_position = origin + rear_direction * SHOT_LIGHT_REAR_OFFSET

	var flash := light.create_tween()
	flash.tween_interval(SHOT_LIGHT_HOLD_DURATION)
	flash.tween_property(
		light, "light_energy", 0.0, SHOT_LIGHT_FADE_DURATION
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	flash.finished.connect(light.queue_free)


func _spawn_rear_flash(parent: Node, emission: Dictionary) -> void:
	var effect := Node3D.new()
	effect.name = "RearMuzzleFlash_%d" % int(emission.get("index", 0))
	effect.set_meta("combat_muzzle_fx", &"rear_flash")
	effect.set_meta("emission_index", int(emission.get("index", 0)))
	parent.add_child(effect)
	effect.top_level = true
	effect.global_position = Vector3(emission["rear_position"])
	var visual := _fx_quad(_rear_flash_textures.front(), REAR_FLASH_SIZE)
	visual.name = "Visual"
	effect.add_child(visual)
	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D
	var animation := effect.create_tween()
	for texture in _rear_flash_textures:
		animation.tween_callback(_set_fx_texture.bind(material, texture))
		animation.tween_interval(INLINE_FX_FRAME_SECONDS)
	animation.finished.connect(effect.queue_free)


func _fx_quad(texture: Texture2D, size: float) -> MeshInstance3D:
	return AuthoredFxBankScript.billboard_quad(texture, size)


func _ensure_inline_fx_textures() -> void:
	if _rear_flash_textures.is_empty():
		_rear_flash_textures = _load_fx_texture_sequence("!cexp", REAR_FLASH_FRAME_COUNT)


func _load_fx_texture_sequence(base_name: String, count: int) -> Array[Texture2D]:
	return AuthoredFxBankScript.load_texture_sequence(base_name, count)


func _set_fx_texture(material: StandardMaterial3D, texture: Texture2D) -> void:
	if material != null:
		material.albedo_texture = texture
