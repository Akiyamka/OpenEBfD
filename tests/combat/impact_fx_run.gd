extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const CombatGroundDecalScript := preload("res://scripts/combat/combat_ground_decal.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const ImpactDebrisScript := preload("res://scripts/combat/fx/impact_debris.gd")
const Fx := preload("res://tests/combat/support/combat_fx_probe.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")

var _bullets := Bullets.new()


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("ground decals fade through seven overlapping crater layers", _test_ground_decal_overlap_budget)
	await _run_async_case("Deviate_B/Gas_B compose the DeviateHit impact FX", _test_deviate_hit_impact_fx)
	await _run_async_case("DevPlasma_B impacts as its own DevImpact cloud, never the generic ShellHit", _test_dev_impact_fx)
	_finish("Impact FX tests")


func _run_case(case_name: String, test: Callable) -> void:
	Fx.free_all(root)
	super._run_case(case_name, test)
	Fx.free_all(root)


func _run_async_case(case_name: String, test: Callable) -> void:
	Fx.free_all(root)
	await super._run_async_case(case_name, test)
	Fx.free_all(root)

func _test_ground_decal_overlap_budget() -> void:
	Fx.free_ground_decals(root)
	var created_decals: Array[Node3D] = []
	for index in CombatGroundDecalScript.MAXIMUM_OVERLAPPING_DECALS:
		var decal = CombatGroundDecalScript.new()
		root.add_child(decal)
		_expect(
			decal.configure(30.0, Vector3(20.0, 0.0, 20.0)),
			"overlap-budget fixture decal %d must configure" % index
		)
		created_decals.append(decal)
	var oldest_mesh := created_decals.front().get_node("Decal") as MeshInstance3D
	_expect(
		int(created_decals.front().get_meta("overlap_fade_steps", 0))
			== CombatGroundDecalScript.MAXIMUM_OVERLAPPING_DECALS - 1
			and is_equal_approx(
				float(oldest_mesh.get_instance_shader_parameter(&"decal_opacity")),
				1.0 / float(CombatGroundDecalScript.MAXIMUM_OVERLAPPING_DECALS)
			),
		"each newer overlap must progressively fade the oldest crater"
	)

	var eighth_decal = CombatGroundDecalScript.new()
	root.add_child(eighth_decal)
	_expect(
		eighth_decal.configure(30.0, Vector3(20.0, 0.0, 20.0)),
		"eighth overlap-budget fixture decal must configure"
	)
	created_decals.append(eighth_decal)
	var clustered_decals := Fx.ground_decals(root)
	_expect(
		clustered_decals.size() \
			== CombatGroundDecalScript.MAXIMUM_OVERLAPPING_DECALS,
		"an eighth overlapping crater must remove the oldest one"
	)
	_expect(
		not is_instance_valid(created_decals.front())
			and is_instance_valid(created_decals.back())
			and int(created_decals[1].get_meta("overlap_fade_steps", 0))
				== CombatGroundDecalScript.MAXIMUM_OVERLAPPING_DECALS - 1,
		"the seventh fade step must remove only the oldest crater"
	)

	var surviving_oldest_steps := int(
		created_decals[1].get_meta("overlap_fade_steps", 0)
	)
	var distant_decal = CombatGroundDecalScript.new()
	root.add_child(distant_decal)
	_expect(
		distant_decal.configure(30.0, Vector3(30.0, 0.0, 20.0)),
		"distant overlap-budget fixture decal must configure"
	)
	_expect(
		Fx.ground_decals(root).size() \
			== CombatGroundDecalScript.MAXIMUM_OVERLAPPING_DECALS + 1
			and int(created_decals[1].get_meta("overlap_fade_steps", 0))
				== surviving_oldest_steps,
		"a distant crater must not fade or remove a separate stack"
	)
	Fx.free_ground_decals(root)












func _test_deviate_hit_impact_fx() -> void:
	Fx.free_impact_effects(root)
	var bullet = _bullets.bullet_with_impact_scenes(&"Deviate_B")
	var launch_position := Vector3(0.0, 1.0, 0.0)
	var ground_position := Vector3(0.0, 0.0, -6.0)
	# A yaw-only marker cannot encode the vertical component of an
	# attack-ground shot; CombatTurret supplies target_direction for that case
	# (see combat_turret.gd's try_fire_at), so a direct launch() call bypassing
	# the turret must do the same or it flies its flat authored heading instead.
	var emission := Bullets.emission(launch_position, Vector3.FORWARD)
	emission["target_direction"] = launch_position.direction_to(ground_position)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(bullet, emission, ground_position),
		"Deviate_B must accept an in-range attack-ground point"
	)
	projectile.advance(2.0)
	_expect(
		projectile.finish_reason == &"impact_ground",
		"Deviate_B must resolve its impact at the sampled ground point"
	)
	var deviate_hits := Fx.impact_effects(root, &"DeviateHit")
	var deviate_hit: Node3D = deviate_hits.front() if not deviate_hits.is_empty() else null
	_expect(
		deviate_hits.size() == 1
		and deviate_hit != null
		and deviate_hit.global_position.is_equal_approx(ground_position),
		"one DeviateHit visual must spawn at the resolved impact position"
	)
	await process_frame
	var particle_counts := {&"!cexp": 0, &"!sess": 0}
	var particle_nodes := deviate_hit.find_children(
		"ImpactParticle_*", "Node3D", true, false
	) if deviate_hit != null else []
	for child in particle_nodes:
		var sequence := StringName(String(child.get_meta("combat_impact_particle", "")))
		if particle_counts.has(sequence):
			particle_counts[sequence] += 1
	_expect(
		particle_counts[&"!cexp"] == 1 and particle_counts[&"!sess"] == 0,
		"DeviateHit must spawn only its tinted gas burst, not the unused !sess swirl"
	)
	var deviate_particle: Node3D = particle_nodes.front() if not particle_nodes.is_empty() else null
	var deviate_material := (
		(deviate_particle.get_node_or_null("Visual") as MeshInstance3D).mesh as QuadMesh
	).material as StandardMaterial3D if deviate_particle != null else null
	_expect(
		deviate_material != null
		and deviate_material.albedo_color.is_equal_approx(Color(0.0, 128.0 / 255.0, 0.0, 1.0)),
		"DeviateHit's gas burst must render in its authored dark-green bank tint"
	)
	_expect(
		deviate_hit == null or deviate_hit.get_node_or_null("ImpactLight") == null,
		"DeviateHit has no authored light piece and must not spawn one"
	)
	var deviate_visual := deviate_hit.get_node_or_null("Visual") if deviate_hit != null else null
	var emitter_meshes := deviate_visual.find_children(
		"*", "MeshInstance3D", true, false
	) if deviate_visual != null else []
	_expect(
		emitter_meshes.all(func(mesh: Node) -> bool: return not (mesh as MeshInstance3D).visible),
		"DeviateHit's anchor markers must remain invisible"
	)
	# Let the follow-particle tween finish before freeing; killing the effect
	# node mid-tween is what ShellHit/MissileHit's tests avoid the same way.
	await create_timer(1.1).timeout
	if is_instance_valid(projectile):
		projectile.free()
	Fx.free_impact_effects(root)


## Rules.txt authors ExplosionType twice on DevPlasma_B and the later DevImpact
## wins, so the Devastator's plasma must show its own expanding cloud and NOT
## the generic ShellHit burst rockets and shells use. ShellHit's own rig stays
## covered by the Minotaurus/KobraHowitzer_B case above.
func _test_dev_impact_fx() -> void:
	Fx.free_impact_effects(root)
	var bullet = _bullets.bullet_with_impact_scenes(&"DevPlasma_B")
	var launch_position := Vector3(0.0, 1.0, 0.0)
	var ground_position := Vector3(0.0, 0.0, -8.0)
	# See _test_deviate_hit_impact_fx: launch() no longer derives an
	# attack-ground direction on its own, so a direct call must supply the
	# same target_direction CombatTurret would.
	var emission := Bullets.emission(launch_position, Vector3.FORWARD)
	emission["target_direction"] = launch_position.direction_to(ground_position)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(bullet, emission, ground_position),
		"DevPlasma_B must accept an in-range attack-ground point"
	)
	projectile.advance(2.0)
	_expect(
		projectile.finish_reason == &"impact_ground",
		"DevPlasma_B must resolve its impact at the sampled ground point"
	)
	_expect(
		bullet.explosion_effect_ids() == [&"DevImpact"],
		"the later ExplosionType must override the earlier one, leaving DevImpact alone"
	)
	_expect(
		Fx.impact_effects(root, &"ShellHit").is_empty(),
		"DevPlasma_B must not spawn the generic ShellHit burst rockets and shells use"
	)
	var dev_impacts := Fx.impact_effects(root, &"DevImpact")
	var dev_impact: Node3D = dev_impacts.front() if not dev_impacts.is_empty() else null
	_expect(
		dev_impacts.size() == 1
		and dev_impact != null
		and dev_impact.global_position.is_equal_approx(ground_position),
		"one DevImpact visual must spawn at the resolved impact position"
	)
	await process_frame
	var particle_nodes := dev_impact.find_children(
		"ImpactParticle_*", "Node3D", true, false
	) if dev_impact != null else []
	var splat_offsets: Array[Vector3] = []
	for child in particle_nodes:
		if child.get_meta("combat_impact_particle", &"") == &"!sm":
			splat_offsets.append(Vector3(
				child.get_meta("combat_impact_offset", Vector3.ZERO)
			))
	_expect(
		splat_offsets.size() == ImpactDebrisScript.DEV_IMPACT_COUNT,
		"DevImpact must spawn its whole authored cloud, not one billboard"
	)
	# The cloud must cover the circle without being a regular polygon: every
	# puff sits in its own angular slot, jittered inside it, at a radius that
	# varies by no more than the authored fraction.
	var angular_step := TAU / float(ImpactDebrisScript.DEV_IMPACT_COUNT)
	var covers_circle := not splat_offsets.is_empty()
	var any_uneven := false
	for offset_index in splat_offsets.size():
		var offset := splat_offsets[offset_index]
		var neighbour := splat_offsets[(offset_index + 1) % splat_offsets.size()]
		var radius_ratio := offset.length() / ImpactDebrisScript.DEV_IMPACT_RADIUS
		var gap := angle_difference(
			atan2(offset.x, offset.z), atan2(neighbour.x, neighbour.z)
		)
		covers_circle = covers_circle \
			and is_zero_approx(offset.y) \
			and absf(radius_ratio - 1.0) <= ImpactDebrisScript.DEV_IMPACT_RADIUS_JITTER \
			and gap > 0.0 \
			and gap <= angular_step * (1.0 + 2.0 * ImpactDebrisScript.DEV_IMPACT_ANGLE_JITTER)
		any_uneven = any_uneven or not is_equal_approx(gap, angular_step)
	_expect(
		covers_circle and any_uneven,
		"DevImpact's puffs must fill the circle unevenly, not as a regular polygon"
	)
	# Fast out of the impact, then a visible coast to a stop.
	_expect(
		ImpactDebrisScript._eased_spray_progress(0.25) > 0.6
		and ImpactDebrisScript._eased_spray_progress(0.5) > 0.9
		and ImpactDebrisScript._eased_spray_progress(1.0) >= 1.0,
		"DevImpact's throw must front-load its travel and decelerate to a halt"
	)
	var first_puff := particle_nodes.front() as Node3D if not particle_nodes.is_empty() else null
	var puff_scale_early := first_puff.scale.x if first_puff != null else 0.0
	await create_timer(ImpactDebrisScript.DEV_IMPACT_DURATION * 0.5).timeout
	var puff_scale_late := first_puff.scale.x \
		if first_puff != null and is_instance_valid(first_puff) else 0.0
	_expect(
		ImpactDebrisScript.DEV_IMPACT_SCALE_START < ImpactDebrisScript.DEV_IMPACT_SCALE_END
		and puff_scale_early >= ImpactDebrisScript.DEV_IMPACT_SCALE_START
		and puff_scale_late > puff_scale_early
		and puff_scale_late <= ImpactDebrisScript.DEV_IMPACT_SCALE_END,
		"DevImpact's puffs must start small and swell across the flight"
	)
	var splat_material := (
		(particle_nodes.front().get_node_or_null("Visual") as MeshInstance3D).mesh as QuadMesh
	).material as StandardMaterial3D if not particle_nodes.is_empty() else null
	_expect(
		splat_material != null
		and Color(
			splat_material.albedo_color, 1.0
		).is_equal_approx(Color(ImpactDebrisScript.DEV_IMPACT_TINT, 1.0)),
		"DevImpact's cloud must render in its bank tint, whatever the blend mode"
	)
	_expect(
		splat_material != null
		and splat_material.albedo_color.r < splat_material.albedo_color.b * 0.5
		and splat_material.albedo_color.g < splat_material.albedo_color.b * 0.5,
		"DevImpact's tint must stay saturated enough to read as blue, not white"
	)
	# Opaque until two thirds of the sheet, then a ramp to nothing on the last
	# frame, so the cloud dissolves instead of vanishing mid-flight.
	var opacity_ramp := ImpactDebrisScript._fade_tail_opacities(
		ImpactDebrisScript.DEV_IMPACT_FRAME_COUNT, ImpactDebrisScript.DEV_IMPACT_FADE_FROM
	)
	_expect(
		opacity_ramp.size() == ImpactDebrisScript.DEV_IMPACT_FRAME_COUNT
		and is_equal_approx(opacity_ramp[0], 1.0)
		and is_equal_approx(opacity_ramp[5], 1.0)
		and opacity_ramp[ImpactDebrisScript.DEV_IMPACT_FRAME_COUNT - 2] < 1.0
		and is_zero_approx(opacity_ramp[ImpactDebrisScript.DEV_IMPACT_FRAME_COUNT - 1]),
		"DevImpact must hold full opacity, then fade out across its last third"
	)
	_expect(
		dev_impact == null or dev_impact.get_node_or_null("ImpactLight") == null,
		"DevImpact has no authored light piece and must not spawn one"
	)
	var dev_impact_visual := dev_impact.get_node_or_null("Visual") if dev_impact != null else null
	var emitter_meshes := dev_impact_visual.find_children(
		"*", "MeshInstance3D", true, false
	) if dev_impact_visual != null else []
	_expect(
		emitter_meshes.all(func(mesh: Node) -> bool: return not (mesh as MeshInstance3D).visible),
		"DevImpact's anchor marker must remain invisible"
	)
	await create_timer(1.1).timeout
	if is_instance_valid(projectile):
		projectile.free()
	Fx.free_impact_effects(root)
