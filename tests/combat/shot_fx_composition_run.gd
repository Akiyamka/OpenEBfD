extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const Fx := preload("res://tests/combat/support/combat_fx_probe.gd")
const ATMinotaurusModelScene := preload("res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn")
const ATMongooseModelScene := preload("res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn")
const HKDevastatorModelScene := preload("res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn")


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case("turret launches projectiles and composes the authored impact FX", _test_turret_projectile_launch)
	await _run_async_case("Mongoose composes launch backblast and missile impact FX", _test_mongoose_launch_and_impact_fx)
	_run_case("Devastator salvo tubes fire their authored rocket flare", _test_devastator_missile_launch_blast)
	_finish("Shot FX composition tests")


func _run_case(case_name: String, test: Callable) -> void:
	Fx.free_all(root)
	super._run_case(case_name, test)
	Fx.free_all(root)


func _run_async_case(case_name: String, test: Callable) -> void:
	Fx.free_all(root)
	await super._run_async_case(case_name, test)
	Fx.free_all(root)

func _test_turret_projectile_launch() -> void:
	var _rules = root.get_node("Rules")
	Fx.free_ground_decals(root)
	var model := ATMinotaurusModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	turret.configure(&"ATMinotaurusBase")
	turret.bind_model(model, 0)
	_expect(
		turret.muzzle_flash_id == &"Muzzle3" and turret.muzzle_flash_scene != null,
		"ATMinotaurusGun must resolve TurretMuzzleFlash=Muzzle3 through ArtIni"
	)
	_expect(
		turret.impact_visual_scenes.has(&"ShellHit"),
		"KobraHowitzer_B must resolve ExplosionType=ShellHit through ArtIni"
	)
	var emission := turret.peek_emission()
	var direction: Vector3 = emission["direction"]
	_expect(
		turret.try_fire_at(
			FireRequestScript.at(Vector3(emission["position"]) + direction * 100.0, model, root)
		).is_empty(),
		"an out-of-range request must not emit a projectile"
	)
	_expect(is_zero_approx(turret.reload_ticks_remaining), "a rejected request must not consume reload")
	var target_position: Vector3 = Vector3(emission["position"]) + direction * 10.0
	_expect(
		turret.try_fire_at(FireRequestScript.at(target_position, model, root)).is_empty(),
		"a trajectory weapon must not fire while its barrel still points along the direct line"
	)
	var trajectory_aimed := false
	for frame in 120:
		trajectory_aimed = turret.aim_at(target_position, 1.0 / 60.0)
		if trajectory_aimed:
			break
	_expect(trajectory_aimed, "the Minotaurus gun must elevate to its ballistic solution")
	_expect(
		turret.current_pitch_degrees() < -1.0,
		"the Minotaurus pitch joint must visibly raise the barrels for trajectory fire"
	)
	var aimed_emission := turret.peek_emission()
	var projectiles: Array = turret.try_fire_at(FireRequestScript.at(target_position, model, root))
	_expect(projectiles.size() == 1, "an in-range request must create one physical projectile")
	if not projectiles.is_empty():
		var projectile = projectiles[0]
		var muzzle_flash := root.get_node_or_null("MuzzleFlash_Muzzle3") as Node3D
		var rear_flashes := Fx.muzzle_effects(root, &"rear_flash", 0)
		var rear_flash: Node3D = rear_flashes.front() \
			if not rear_flashes.is_empty() else null
		var shot_lights := Fx.muzzle_effects(root, &"shot_light", 0)
		var shot_light := shot_lights.front() as OmniLight3D \
			if not shot_lights.is_empty() else null
		_expect(
			muzzle_flash != null
			and muzzle_flash.global_position.is_equal_approx(
				Vector3(aimed_emission["position"])
			),
			"the authored Muzzle3 effect must spawn on the active >> muzzle"
		)
		_expect(
			muzzle_flash != null
			and muzzle_flash.find_child("_flashl_0", true, false) != null,
			"the runtime muzzle flash must use the original Explosion/Muzzle3.xbf model"
		)
		var flash_player := muzzle_flash.find_child(
			"AnimationPlayer", true, false
		) as AnimationPlayer if muzzle_flash != null else null
		_expect(
			flash_player != null
			and flash_player.get_animation(&"Stationary").loop_mode == Animation.LOOP_NONE,
			"one projectile event must play exactly one muzzle flash without wrapping"
		)
		_expect(
			aimed_emission.has("rear_position")
			and rear_flash != null
			and rear_flash.global_position.is_equal_approx(
				Vector3(aimed_emission["rear_position"])
			),
			"the paired #muzzle marker must emit the original rear cannon flash"
		)
		var expected_light_position := Vector3(aimed_emission["rear_position"]) \
			+ Vector3(aimed_emission["rear_direction"]) \
			* CombatTurretScript.SHOT_LIGHT_REAR_OFFSET
		_expect(
			shot_lights.size() == 1
			and shot_light != null
			and shot_light.global_position.is_equal_approx(expected_light_position)
			and shot_light.light_color.is_equal_approx(
				CombatTurretScript.SHOT_LIGHT_COLOR
			)
			and shot_light.light_energy > 0.0,
			"each projectile event must briefly light the area behind its active barrel"
		)
		_expect(projectile.bullet.id() == &"KobraHowitzer_B", "the projectile must carry the turret's configured bullet")
		_expect(
			projectile.global_position.is_equal_approx(Vector3(aimed_emission["position"])),
			"the projectile must start at the authored >> muzzle"
		)
		_expect(
			projectile.direction().angle_to(Vector3(aimed_emission["direction"]))
				<= deg_to_rad(1.1),
			"the shell trajectory must leave along the elevated barrel direction"
		)
		_expect(
			projectile.global_basis.z.normalized().dot(projectile.direction()) > 0.999,
			"the converted projectile model's +Z nose must face along its flight direction"
		)
		_expect(
			projectile.state == CombatProjectileScript.State.FLYING,
			"a non-hitscan turret shot must remain as a world-space node"
		)
		var visual := projectile.get_node_or_null("Visual") as Node3D
		_expect(visual != null, "a physical projectile must expose visible runtime geometry")
		_expect(
			visual != null and visual.find_child("shell_0", true, false) != null,
			"KobraHowitzer_B must instantiate the original ArtIni shell.xaf model"
		)
		var source_flash := visual.find_child("*flashl*", true, false) as Node3D \
			if visual != null else null
		_expect(
			source_flash != null and not source_flash.visible,
			"the shell helper flash must not render as permanent rocket exhaust"
		)
		projectile.advance(0.1)
		var trail := projectile.get_node_or_null("MissileTrail") as MeshInstance3D
		_expect(
			trail != null
			and trail.mesh is ImmediateMesh
			and (trail.mesh as ImmediateMesh).get_surface_count() == 1,
			"KobraHowitzer_B must draw a rules-sized fading aerodynamic trail"
		)
		var expected_impact_position: Vector3 = projectile.trajectory_impact_position()
		projectile.advance(10.0)
		var shell_hits := Fx.impact_effects(root, &"ShellHit")
		var shell_hit: Node3D = shell_hits.front() if not shell_hits.is_empty() else null
		var craters := Fx.ground_decals(root)
		var crater: Node3D = craters.front() if not craters.is_empty() else null
		var crater_mesh := crater.get_node_or_null("Decal") as MeshInstance3D \
			if crater != null else null
		var impact_visual := shell_hit.get_node_or_null("Visual") as Node3D \
			if shell_hit != null else null
		var impact_player := impact_visual.find_child(
			"AnimationPlayer", true, false
		) as AnimationPlayer if impact_visual != null else null
		var active_animation := impact_player.get_animation(
			impact_player.current_animation
		) if impact_player != null else null
		_expect(
			projectile.finish_reason == &"impact_ground"
			and shell_hits.size() == 1
			and shell_hit.global_position.is_equal_approx(expected_impact_position),
			"one ShellHit visual must spawn at the resolved shell impact position"
		)
		_expect(
			craters.size() == 1
			and crater.global_position.distance_to(expected_impact_position) < 0.05
			and is_equal_approx(float(crater.get_meta("damage_to_tile", 0.0)), 30.0)
			and crater_mesh != null
			and crater_mesh.mesh is PlaneMesh,
			"ShellHit must leave one original-atlas crater decal on the ground"
		)
		var emitter_meshes := impact_visual.find_children(
			"*", "MeshInstance3D", true, false
		) if impact_visual != null else []
		var emitter_geometry_hidden := false
		for emitter_mesh in emitter_meshes:
			var current: Node = emitter_mesh
			var belongs_to_particle := false
			while current != null and current != impact_visual:
				if current.has_meta("combat_impact_particle"):
					belongs_to_particle = true
					break
				current = current.get_parent()
			if not belongs_to_particle:
				emitter_geometry_hidden = true
				if (emitter_mesh as MeshInstance3D).visible:
					emitter_geometry_hidden = false
					break
		_expect(
			emitter_geometry_hidden,
			"ShellHit's blue #bing cubes must remain invisible particle emitters"
		)
		_expect(
			active_animation != null
			and active_animation.loop_mode == Animation.LOOP_NONE,
			"the impact source animation must play once without looping"
		)
		await process_frame
		var particle_counts := {
			&"!%Bru": 0,
			&"!cexp": 0,
			&"!@sm": 0,
		}
		var particle_nodes := shell_hit.find_children(
			"ImpactParticle_*", "Node3D", true, false
		) if shell_hit != null else []
		for child in particle_nodes:
			var sequence := StringName(String(child.get_meta("combat_impact_particle", "")))
			if particle_counts.has(sequence):
				particle_counts[sequence] += 1
		_expect(
			particle_counts[&"!%Bru"] == 1
			and particle_counts[&"!cexp"] == 0
			and particle_counts[&"!@sm"] == 16,
			"ShellHit must start one central burst and sixteen independent shrapnel particles"
		)
		var shrapnel_velocities: Array[Vector3] = []
		for child in particle_nodes:
			if child.get_meta("combat_impact_particle", &"") == &"!@sm":
				shrapnel_velocities.append(Vector3(
					child.get_meta("combat_impact_velocity", Vector3.ZERO)
				))
		var shrapnel_is_independent := shrapnel_velocities.size() == 16
		for velocity_index in range(1, shrapnel_velocities.size()):
			shrapnel_is_independent = shrapnel_is_independent \
				and not shrapnel_velocities[velocity_index].is_equal_approx(
					shrapnel_velocities[velocity_index - 1]
				)
		_expect(
			shrapnel_is_independent,
			"each ShellHit shrapnel particle must receive its own randomized velocity"
		)
		var impact_light := shell_hit.get_node_or_null("ImpactLight") as OmniLight3D \
			if shell_hit != null else null
		_expect(
			impact_light != null
			and impact_light.light_color.is_equal_approx(Color(1.0, 0.43, 0.12))
			and impact_light.light_energy > 0.0,
			"ShellHit must briefly illuminate the impact area with an orange point light"
		)
		await create_timer(1.1).timeout
		_expect(
			is_instance_valid(shell_hit) and not shell_hit.is_processing(),
			"finished follow particles must leave no stale object references in the impact effect"
		)
		if is_instance_valid(projectile):
			projectile.free()
		if muzzle_flash != null and is_instance_valid(muzzle_flash):
			muzzle_flash.free()
		Fx.free_muzzle_effects(root)
		Fx.free_impact_effects(root)
		Fx.free_ground_decals(root)
	model.free()


func _test_mongoose_launch_and_impact_fx() -> void:
	var _rules = root.get_node("Rules")
	Fx.free_ground_decals(root)
	var model := ATMongooseModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATMongooseMissile"),
		"ATMongooseMissile must resolve its rules-backed presentation"
	)
	_expect(turret.bind_model(model, 0), "the Mongoose launcher must bind its authored markers")
	_expect(
		turret.muzzle_flash_id == &"Muzzle3" and turret.muzzle_flash_scene != null,
		"the Mongoose must resolve its authored Muzzle3 front flash"
	)
	_expect(
		turret.impact_visual_scenes.has(&"MissileHit"),
		"HEAT_B must resolve ExplosionType=MissileHit through ArtIni"
	)

	var emission := turret.peek_emission()
	var smoke_node := emission.get("smoke_node") as Node3D
	_expect(
		smoke_node != null
		and String(smoke_node.get_meta("original_name", "")) == "#smoke",
		"the >>0#flame launcher must pair with its sibling #smoke backblast marker"
	)
	var target_position := Vector3(emission["position"]) \
		+ Vector3(emission["direction"]) * 10.0
	target_position.y = 0.0
	_expect(
		turret.aim_at(target_position, 1.0 / 60.0),
		"the yaw-only Mongoose launcher must accept a ground point ahead"
	)
	var projectiles: Array = turret.try_fire_at(FireRequestScript.at(target_position, model, root))
	_expect(projectiles.size() == 1, "the Mongoose launch must emit one HEAT_B missile")
	if projectiles.is_empty():
		model.free()
		return
	var fired_emission: Dictionary = turret.last_emissions()[0]
	_expect(
		projectiles[0].direction().is_equal_approx(
			Vector3(fired_emission["position"]).direction_to(target_position)
		),
		"a yaw-only launcher must add the missing pitch to an attack-ground shot"
	)

	var front_flashes := Fx.muzzle_effects(root, &"front_flash")
	var launch_smokes := Fx.muzzle_effects(root, &"launch_smoke", 0)
	var shot_lights := Fx.muzzle_effects(root, &"shot_light", 0)
	_expect(
		front_flashes.size() == 1
		and front_flashes[0].global_position.is_equal_approx(
			Vector3(fired_emission["position"])
		),
		"one Muzzle3 flash must spawn at the Mongoose's >>0#flame marker"
	)
	var muzzle3_mesh := front_flashes[0].find_child(
		"Mesh_00_Visual", true, false
	) as MeshInstance3D if front_flashes.size() == 1 else null
	_expect(
		muzzle3_mesh != null
		and muzzle3_mesh.scale.is_equal_approx(Vector3.ONE * 0.5),
		"Muzzle3 must render its oversized Mesh_00 at half scale"
	)
	_expect(
		launch_smokes.size() == 1
		and launch_smokes[0].global_position.is_equal_approx(
			Vector3(fired_emission["smoke_position"])
		),
		"the original !cexp launch backblast must spawn at #smoke"
	)
	_expect(
		launch_smokes.size() == 1
		and launch_smokes[0].get_node_or_null("Visual") is MeshInstance3D,
		"the Mongoose backblast must render as an additive animated billboard"
	)
	_expect(
		shot_lights.size() == 1
		and (shot_lights[0] as OmniLight3D).light_energy > 0.0,
		"the launch event must briefly illuminate the launcher"
	)

	var projectile = projectiles[0]
	projectile.advance(1.0)
	var missile_hits := Fx.impact_effects(root, &"MissileHit")
	var missile_hit: Node3D = missile_hits.front() if not missile_hits.is_empty() else null
	var craters := Fx.ground_decals(root)
	_expect(
		projectile.finish_reason == &"impact_ground"
		and missile_hits.size() == 1
		and missile_hit.global_position.is_equal_approx(target_position),
		"one MissileHit composition must spawn at the resolved ground impact"
	)
	_expect(
		craters.size() == 1
		and craters.front().global_position.distance_to(target_position) < 0.05
		and int(craters.front().get_meta("crater_variant", -1)) in range(4),
		"MissileHit must leave one randomized original crater variant"
	)
	var impact_visual := missile_hit.get_node_or_null("Visual") as Node3D \
		if missile_hit != null else null
	var emitter_meshes := impact_visual.find_children(
		"*", "MeshInstance3D", true, false
	) if impact_visual != null else []
	var emitter_geometry_hidden := not emitter_meshes.is_empty()
	for emitter_mesh in emitter_meshes:
		emitter_geometry_hidden = emitter_geometry_hidden \
			and not (emitter_mesh as MeshInstance3D).visible
	_expect(
		emitter_geometry_hidden,
		"MissileHit's #bing cubes must remain hidden emitter helpers"
	)
	await process_frame
	var particle_counts := {
		&"!%Bru": 0,
		&"!cexp": 0,
		&"!@sm": 0,
	}
	var particle_nodes := missile_hit.find_children(
		"ImpactParticle_*", "Node3D", true, false
	) if missile_hit != null else []
	for child in particle_nodes:
		var sequence := StringName(String(child.get_meta("combat_impact_particle", "")))
		if particle_counts.has(sequence):
			particle_counts[sequence] += 1
	_expect(
		particle_counts[&"!%Bru"] == 1
		and particle_counts[&"!cexp"] == 0
		and particle_counts[&"!@sm"] == 32,
		"MissileHit must retain its loose shrapnel spray and add one particle ring"
	)
	var ring_velocities: Array[Vector3] = []
	var loose_shrapnel_count := 0
	for child in particle_nodes:
		if child.get_meta("combat_impact_ring", false):
			ring_velocities.append(Vector3(
				child.get_meta("combat_impact_velocity", Vector3.ZERO)
			))
		elif child.get_meta("combat_impact_particle", &"") == &"!@sm":
			loose_shrapnel_count += 1
	var ring_is_randomized := ring_velocities.size() == 16
	var differs_from_even_spacing := false
	for velocity_index in ring_velocities.size():
		var expected_angle := TAU * float(velocity_index) / float(ring_velocities.size())
		var expected_direction := Vector3(sin(expected_angle), 0.0, cos(expected_angle))
		var horizontal_velocity := ring_velocities[velocity_index]
		horizontal_velocity.y = 0.0
		differs_from_even_spacing = differs_from_even_spacing \
			or horizontal_velocity.normalized().dot(expected_direction) < 0.99
		ring_is_randomized = (
			ring_is_randomized
			and not horizontal_velocity.is_zero_approx()
			and is_equal_approx(
				ring_velocities[velocity_index].y, ring_velocities[0].y
			)
		)
	_expect(
		loose_shrapnel_count == 16,
		"MissileHit must preserve the original independent shrapnel spray"
	)
	_expect(
		ring_is_randomized and differs_from_even_spacing,
		"MissileHit ring points must share one radius but use randomized angles"
	)
	var impact_light := missile_hit.get_node_or_null("ImpactLight") as OmniLight3D \
		if missile_hit != null else null
	_expect(
		impact_light != null and impact_light.light_energy > 0.0,
		"MissileHit must briefly illuminate the impact area"
	)

	if is_instance_valid(projectile):
		projectile.free()
	Fx.free_muzzle_effects(root)
	Fx.free_impact_effects(root)
	Fx.free_ground_decals(root)
	model.free()


func _test_devastator_missile_launch_blast() -> void:
	var _rules = root.get_node("Rules")
	var model := HKDevastatorModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"HKDevastatorMissile"),
		"HKDevastatorMissile must resolve its rules-backed presentation"
	)
	_expect(
		turret.bind_model(model, 1),
		"the Devastator's ::1 salvo launcher must bind its authored markers"
	)
	_expect(turret.muzzle_count() == 3, "the salvo launcher must bind its three tubes")

	var emissions: Array = turret.emission_points()
	var paired_flares := PackedStringArray()
	for emission_value: Variant in emissions:
		var emission: Dictionary = emission_value
		var smoke_node := emission.get("smoke_node") as Node3D
		paired_flares.append(
			String(smoke_node.get_meta("original_name", "")) if smoke_node != null else ""
		)
	_expect(
		paired_flares == PackedStringArray(["#flare01", "#flare02", "#flare03"]),
		"each >>Nmissile_salvo tube must pair with the flare marker behind it"
	)

	var emission: Dictionary = turret.peek_emission()
	var target_position := Vector3(emission["position"]) \
		+ Vector3(emission["direction"]) * 6.0
	target_position.y = 0.0
	turret.aim_at(target_position, 1.0)
	var projectiles: Array = turret.try_fire_at(
		FireRequestScript.at(target_position, model, root)
	)
	_expect(projectiles.size() == 1, "the salvo launcher must emit one DevRocket_B")
	var launch_blasts := Fx.muzzle_effects(root, &"launch_smoke", 0)
	_expect(
		launch_blasts.size() == 1
		and launch_blasts[0].global_position.is_equal_approx(
			Vector3((turret.last_emissions()[0] as Dictionary)["smoke_position"])
		),
		"the authored !exp0 rocket flare must spawn at the tube's #flare marker"
	)
	_expect(
		launch_blasts.size() == 1
		and launch_blasts[0].get_node_or_null("Visual") is MeshInstance3D,
		"the rocket flare must render as an animated billboard"
	)

	for projectile in projectiles:
		if is_instance_valid(projectile):
			projectile.free()
	Fx.free_muzzle_effects(root)
	Fx.free_impact_effects(root)
	Fx.free_ground_decals(root)
	model.free()
