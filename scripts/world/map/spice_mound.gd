class_name SpiceMound
extends Area3D
## Runtime spice-bloom trigger. The visual is converted from the original
## Spicemound.xbf mesh; this Area3D owns contact activation and the Rules.txt
## maturation cycle.
##
## The maturation cycle used to run on a child Timer node (MaturityTimer,
## still present in scenes/world/spice_mound.tscn). Phase 1
## (docs/architecture/network-multiplayer.md, decision 4) bans Timer/_process
## from driving simulation state -- a Timer advances on engine frame time, so
## no snapshot or checksum can see it -- so maturity now runs on an integer
## sim-tick countdown instead, the same design CombatLingerEffect uses for
## its own countdown (see combat_linger_effect.gd). The scene node itself is
## left alone: removing it means editing the .tscn, out of scope for this
## slice. Nothing below reads or drives it any longer.

signal activated(mound: SpiceMound, early_activation: bool, maturity_fraction: float)

const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")

## Match._advance_simulation_tick() drives every live mound's sim_tick() by
## walking this group, the same way it walks "units", "buildings" and
## "sim_linger_effects" -- see _ready() below for why the mound joins it
## itself.
const SIM_SPICE_MOUND_GROUP := "sim_spice_mounds"

const UNIT_COLLISION_LAYER := 2
const MATURITY_DURATION_MULTIPLIER := 3.0
const MIN_REPEAT_ACTIVATION_MATURITY := 0.3
const SOURCE_MODEL_DIAMETER := 32.0
const SOURCE_GROWTH_ANIMATION := &"timeline"
const SOURCE_GROWTH_TRACK := NodePath("_0Spicemound:transform")
const PARTICLES_PER_HAZARD_CELL := 3
const MIN_HAZARD_PARTICLES := 48
const MAX_HAZARD_PARTICLES := 512
const HAZARD_PARTICLE_SIZE_DIVISOR := 3.0
const HAZARD_DAMPING_MIN_RATIO := 0.24
const HAZARD_DAMPING_MAX_RATIO := 0.34
const HAZARD_DAMPING_RANGE_COMPENSATION := 1.45
const HAZARD_LAUNCH_SPEED_MULTIPLIER := 1.28
const SpiceDefinitionCatalogScript := preload("res://scripts/world/map/spice_definition_catalog.gd")
static var _definition_catalog := SpiceDefinitionCatalogScript.new()

@export var source_cell := Vector2i(-1, -1)

var config: Resource
## The maturity countdown, in simulation ticks (MatchClock.TICKS_PER_SECOND,
## 25 Hz). Public like CombatLingerEffect.remaining_ticks, for the same
## reason: tests drive and observe it directly instead of reaching for a
## private field by name.
var maturity_ticks_remaining := 0
var _footprint := Vector2.ONE
var _lifespan_random_fraction := -1.0
var _maturity_cycle_ticks := 0
var _maturity_progress := 0.0
var _activation_in_progress := false
var _has_activated := false


func configure(
	cell: Vector2i,
	footprint: Vector2,
	rules_config: Resource = null,
	lifespan_random_fraction := -1.0
) -> void:
	source_cell = cell
	_footprint = Vector2(maxf(footprint.x, 0.001), maxf(footprint.y, 0.001))
	config = rules_config if rules_config != null else _definition_catalog.mound()
	_lifespan_random_fraction = lifespan_random_fraction
	_has_activated = false
	_apply_footprint()
	restart_maturity_cycle()


func _ready() -> void:
	add_to_group(&"spice_mounds")
	collision_layer = 0
	collision_mask = UNIT_COLLISION_LAYER
	monitoring = true
	monitorable = true
	if config == null:
		config = _definition_catalog.mound()
	_apply_footprint()
	body_entered.connect(_on_body_entered)
	# The mound finds Match's central loop, not the other way around: it
	# joins the sim group itself, right here, the same point CombatLingerEffect
	# joins SIM_LINGER_GROUP in its own configure(). No matching registration
	# call is needed at any spawn site (see map_spice_layer.gd's
	# _spawn_spice_mound()). There is no matching remove_from_group() on
	# teardown, unlike CombatLingerEffect: this mound never frees itself --
	# only map_spice_layer.gd's _remove_spice_mound() does, the same as
	# Building.gd never removes itself from "buildings" -- so
	# is_instance_valid() in the central loop is what guards a freed mound
	# still listed this frame, exactly as it already does for units and
	# buildings.
	add_to_group(SIM_SPICE_MOUND_GROUP)
	restart_maturity_cycle()


## This mound's simulation half: advances the maturity countdown by exactly
## one simulation tick and fires _on_maturity_timeout() when it reaches zero
## -- the same event the old MaturityTimer.timeout signal used to fire.
## Called once per simulation tick by Match._advance_simulation_tick() via the
## SIM_SPICE_MOUND_GROUP membership joined in _ready() above.
##
## Also folds in what _process() used to do every rendered frame: sampling
## the countdown into the visible growth-animation progress. A maturity cycle
## runs for minutes, so updating that progress once per 25 Hz sim tick instead
## of once per rendered frame is not visibly different, and dropping
## _process() removes the last reason this node needed a frame callback
## purely to read simulation state -- the coupling phase 1 exists to remove.
func sim_tick() -> void:
	if maturity_ticks_remaining <= 0:
		return
	maturity_ticks_remaining -= 1
	_set_maturity_progress(maturity_progress())
	if maturity_ticks_remaining <= 0:
		_on_maturity_timeout()


## Converts this mound's authored maturity duration into whole simulation
## ticks. maturity_minimum_ticks/maturity_random_ticks are rule ticks at
## RuleTicks.RULE_TICKS_PER_SECOND (60 Hz, not this simulation's 25 Hz).
## MATURITY_DURATION_MULTIPLIER stretches the mound's real-time lifespan 3x
## beyond what those rule ticks alone would give -- applying it to the
## rule-tick count before RuleTicks.to_sim_ticks() converts once, rather than
## to the converted sim-tick count afterwards, keeps the rounding to that
## function's single roundi() call instead of stacking a second one on top;
## both orders agree to within that one rounding step, since to_sim_ticks()
## is linear in its argument.
##
## Worked example, matching the fixture in tests/maps/run.gd: minimum=1000,
## random=500, fraction=0.5 -> (1000 + 500*0.5) = 1250 rule ticks -> *3 =
## 3750 rule ticks -> to_sim_ticks(3750) = roundi(3750 * 25 / 60) =
## roundi(1562.5) = 1563 sim ticks = 62.52s -- against the pre-conversion
## value of (1250 / 60) * 3 = 62.5s, a 20 ms difference from the one rounding
## step above.
func maturity_duration_ticks(random_fraction := -1.0) -> int:
	if config == null:
		return 0
	var fraction := randf() if random_fraction < 0.0 else clampf(random_fraction, 0.0, 1.0)
	var minimum_ticks := maxf(config.maturity_minimum_ticks, 0.0)
	var random_ticks := maxf(config.maturity_random_ticks, 0.0)
	var rule_ticks := (minimum_ticks + random_ticks * fraction) * MATURITY_DURATION_MULTIPLIER
	return RuleTicksScript.to_sim_ticks(rule_ticks)


func activate(early_activation := false) -> bool:
	if _activation_in_progress:
		return false
	var maturity_fraction := maturity_progress() if early_activation else 1.0
	if early_activation and _has_activated \
	and maturity_fraction < MIN_REPEAT_ACTIVATION_MATURITY:
		return false
	_activation_in_progress = true
	# Halts the countdown the same way timer.stop() used to: sim_tick()'s
	# very first check (maturity_ticks_remaining <= 0) turns into a no-op
	# until restart_maturity_cycle() below re-arms it.
	maturity_ticks_remaining = 0
	_set_maturity_progress(1.0)
	activated.emit(self, early_activation, maturity_fraction)
	_has_activated = true
	_activation_in_progress = false
	restart_maturity_cycle()
	return true


## (Re)arms the maturity countdown from this mound's config: (re)computes the
## tick-domain duration (maturity_duration_ticks()) and resets both the
## countdown and the visible growth progress to zero. Doubles as the pre-tree
## setup configure() needs -- unlike the old timer.start(), a plain integer
## assignment has no tree-membership precondition, so configure() (called
## before this node is ever added to the tree; see map_spice_layer.gd's
## _spawn_spice_mound()) can call this directly instead of going through a
## separate "_prepare" helper.
func restart_maturity_cycle() -> void:
	_set_maturity_progress(0.0)
	_maturity_cycle_ticks = maturity_duration_ticks(_lifespan_random_fraction)
	maturity_ticks_remaining = _maturity_cycle_ticks


func growth_scale() -> float:
	var animated_node := get_node_or_null("Visual/_0Spicemound") as Node3D
	return animated_node.scale.x if animated_node != null else 0.0


func maturity_progress() -> float:
	if _maturity_cycle_ticks <= 0:
		return _maturity_progress
	return clampf(1.0 - float(maturity_ticks_remaining) / float(_maturity_cycle_ticks), 0.0, 1.0)


func _apply_footprint() -> void:
	var visual := get_node_or_null("Visual") as Node3D
	if visual != null:
		var vertical_footprint := minf(_footprint.x, _footprint.y)
		visual.scale = Vector3(_footprint.x, vertical_footprint, _footprint.y) / SOURCE_MODEL_DIAMETER
	var shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
	var box := shape_node.shape as BoxShape3D if shape_node != null else null
	if box != null:
		box.size = Vector3(_footprint.x, maxf(minf(_footprint.x, _footprint.y), 0.5), _footprint.y)
		shape_node.position.y = box.size.y * 0.5


func start_spread_hazard(local_points: PackedVector3Array, particle_size: float) -> void:
	var dust := get_node_or_null("SpreadDust") as GPUParticles3D
	var dust_material := dust.process_material as ParticleProcessMaterial if dust != null else null
	if dust == null or dust_material == null or local_points.is_empty():
		return
	var hazard_radius := 0.0
	for point: Vector3 in local_points:
		hazard_radius = maxf(hazard_radius, Vector2(point.x, point.z).length())
	# A 48-degree cone gives the burst a narrow vertical core and enough lateral
	# velocity to open into a geyser umbrella. Scaling both gravity and velocity
	# from the radius keeps the apex early while the long tail remains gentle.
	var gravity_strength := maxf(hazard_radius * 0.2, 1.2)
	# Strong early damping shortens the ballistic arc, so give the burst a
	# matching launch boost. This restores the hazard radius without sacrificing
	# the fast-to-slow motion profile.
	var outer_velocity := sqrt(maxf(hazard_radius, particle_size) * gravity_strength) \
		* HAZARD_LAUNCH_SPEED_MULTIPLIER * HAZARD_DAMPING_RANGE_COMPENSATION
	dust_material.initial_velocity_min = maxf(outer_velocity * 0.38, 0.8)
	dust_material.initial_velocity_max = maxf(outer_velocity, 1.5)
	dust_material.gravity = Vector3(0.0, -gravity_strength, 0.0)
	# Front-load the damping so the geyser bursts outward quickly, loses most of
	# its speed early, then drifts and falls gently for the rest of its lifetime.
	dust_material.damping_min = maxf(outer_velocity * HAZARD_DAMPING_MIN_RATIO, 0.55)
	dust_material.damping_max = maxf(outer_velocity * HAZARD_DAMPING_MAX_RATIO, 0.8)
	_ensure_hazard_damping_curve(dust_material)
	_ensure_hazard_scale_curve(dust_material)
	dust.amount = clampi(
		local_points.size() * PARTICLES_PER_HAZARD_CELL,
		MIN_HAZARD_PARTICLES,
		MAX_HAZARD_PARTICLES
	)
	var dust_quad := dust.draw_pass_1 as QuadMesh
	if dust_quad != null:
		var size := maxf(particle_size / HAZARD_PARTICLE_SIZE_DIVISOR, 0.1)
		dust_quad.size = Vector2(size, size)
	var margin := maxf(particle_size, 1.0) * 2.0
	var apex_height := dust_material.initial_velocity_max * dust_material.initial_velocity_max \
		/ (2.0 * gravity_strength)
	dust.visibility_aabb = AABB(
		Vector3(-hazard_radius - margin, -margin, -hazard_radius - margin),
		Vector3(
			(hazard_radius + margin) * 2.0,
			apex_height + margin * 2.0,
			(hazard_radius + margin) * 2.0
		)
	)
	dust.visible = true
	dust.restart()


func _ensure_hazard_scale_curve(dust_material: ParticleProcessMaterial) -> void:
	if dust_material.scale_curve != null:
		return
	var growth_curve := Curve.new()
	growth_curve.min_value = 0.0
	growth_curve.max_value = HAZARD_PARTICLE_SIZE_DIVISOR
	growth_curve.add_point(Vector2(0.0, 1.0))
	growth_curve.add_point(Vector2(1.0, HAZARD_PARTICLE_SIZE_DIVISOR))
	var growth_texture := CurveTexture.new()
	growth_texture.curve = growth_curve
	dust_material.scale_curve = growth_texture


func _ensure_hazard_damping_curve(dust_material: ParticleProcessMaterial) -> void:
	if dust_material.damping_curve != null:
		return
	var damping_curve := Curve.new()
	damping_curve.min_value = 0.0
	damping_curve.max_value = 1.0
	damping_curve.add_point(Vector2(0.0, 1.0))
	damping_curve.add_point(Vector2(0.1, 0.9))
	damping_curve.add_point(Vector2(0.3, 0.3))
	damping_curve.add_point(Vector2(0.62, 0.1))
	damping_curve.add_point(Vector2(1.0, 0.02))
	var damping_texture := CurveTexture.new()
	damping_texture.curve = damping_curve
	dust_material.damping_curve = damping_texture


func stop_spread_hazard() -> void:
	var dust := get_node_or_null("SpreadDust") as GPUParticles3D
	if dust == null:
		return
	dust.emitting = false
	dust.visible = false


func _set_maturity_progress(progress: float) -> void:
	_maturity_progress = clampf(progress, 0.0, 1.0)
	var player := get_node_or_null("Visual/AnimationPlayer") as AnimationPlayer
	var animated_node := get_node_or_null("Visual/_0Spicemound") as Node3D
	if player == null or animated_node == null or not player.has_animation(SOURCE_GROWTH_ANIMATION):
		return
	player.stop()
	var animation := player.get_animation(SOURCE_GROWTH_ANIMATION)
	var track := animation.find_track(SOURCE_GROWTH_TRACK, Animation.TYPE_VALUE)
	if track < 0 or animation.track_get_key_count(track) == 0:
		return
	var last_key := animation.track_get_key_count(track) - 1
	var growth_time := animation.track_get_key_time(track, last_key) * _maturity_progress
	var authored_transform: Variant = animation.value_track_interpolate(track, growth_time)
	if authored_transform is Transform3D:
		animated_node.transform = authored_transform


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(&"units"):
		activate(true)


func _on_maturity_timeout() -> void:
	activate(false)
