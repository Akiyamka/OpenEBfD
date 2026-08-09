extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const LaserBeamScript := preload("res://scripts/combat/fx/laser_beam.gd")
const Fx := preload("res://tests/combat/support/combat_fx_probe.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const ATAPCModelScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const ATSniperModelScene := preload("res://assets/converted/models/AT_Sniper_H0/AT_Sniper_H0.scn")
const ATTrikeModelScene := preload("res://assets/converted/models/AT_Trike_H0/AT_Trike_H0.scn")
const ATMongooseModelScene := preload("res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn")
const ATMinotaurusModelScene := preload("res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn")
const ORMortarModelScene := preload("res://assets/converted/models/OR_Mortar_H0/OR_Mortar_H0.scn")
const HKAssaultModelScene := preload("res://assets/converted/models/HK_assault_H0/HK_assault_H0.scn")
const HKTrooperModelScene := preload("res://assets/converted/models/HK_Trooper_H0/HK_Trooper_H0.scn")
const HKFlamerModelScene := preload("res://assets/converted/models/HK_Flamer_H0/HK_Flamer_H0.scn")
const HKFlameModelScene := preload("res://assets/converted/models/HK_flame_H0/HK_flame_H0.scn")
const ORChemicalModelScene := preload("res://assets/converted/models/OR_Chemical_H0/OR_Chemical_H0.scn")
const ORLaserTankModelScene := preload("res://assets/converted/models/OR_Lasertank_H0/OR_Lasertank_H0.scn")
const IMAdvSardaukarModelScene := preload("res://assets/converted/models/IM_ADVSardaukar_H0/IM_ADVSardaukar_H0.scn")
const ATKindjalModelScene := preload("res://assets/converted/models/AT_Kindjal_H0/AT_Kindjal_H0.scn")
const ORKobraModelScene := preload("res://assets/converted/models/OR_Kobra_H0/OR_Kobra_H0.scn")

var _bullets := Bullets.new()


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case("lasers span the resolved 3D hit segment and remain visible briefly", _test_laser_hitscan_visual)
	await _run_async_case("muzzle FX banks emit authored rising barrel smoke", _test_muzzle_fx_bank_smoke)
	await _run_async_case("model FX banks emit authored casing counts and sizes", _test_model_fx_bank_casings)
	_run_case("discrete Fire clips do not turn muzzle accents into particle streams", _test_discrete_fire_skips_particle_streams)
	await _run_async_case("flame and chemical Fire clips emit authored particle streams", _test_model_fx_bank_streams)
	_finish("Muzzle FX tests")


func _run_case(case_name: String, test: Callable) -> void:
	Fx.free_all(root)
	super._run_case(case_name, test)
	Fx.free_all(root)


func _run_async_case(case_name: String, test: Callable) -> void:
	Fx.free_all(root)
	await super._run_async_case(case_name, test)
	Fx.free_all(root)

func _test_laser_hitscan_visual() -> void:
	var launch_position := Vector3(2.0, 5.0, 3.0)
	var ground_position := Vector3(-4.0, 0.0, -7.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_bullets.runtime_bullet(&"Laser_B"),
			Bullets.emission(launch_position, Vector3.FORWARD),
			ground_position
		),
		"Laser_B must accept an in-range downhill attack-ground shot"
	)
	_expect(
		projectile.is_finished()
		and projectile.finish_reason == &"impact_ground",
		"a laser must still resolve gameplay damage instantly"
	)
	var beam := projectile.get_node_or_null("LaserBeam") as Node3D
	var core := beam.get_node_or_null("Core") as MeshInstance3D \
		if beam != null else null
	var glow := beam.get_node_or_null("Glow") as MeshInstance3D \
		if beam != null else null
	var core_mesh := core.mesh as CylinderMesh if core != null else null
	var glow_mesh := glow.mesh as CylinderMesh if glow != null else null
	var glow_material := glow_mesh.material as StandardMaterial3D \
		if glow_mesh != null else null
	var expected_direction := launch_position.direction_to(ground_position)
	_expect(
		beam != null
		and Vector3(beam.get_meta("start_position", Vector3.INF)).is_equal_approx(
			launch_position
		)
		and Vector3(beam.get_meta("end_position", Vector3.INF)).is_equal_approx(
			ground_position
		),
		"the visual beam must retain the exact muzzle and resolved hit endpoints"
	)
	_expect(
		beam != null
		and beam.global_position.is_equal_approx(
			launch_position.lerp(ground_position, 0.5)
		)
		and beam.global_basis.y.normalized().is_equal_approx(expected_direction),
		"an elevated laser must point downhill through the hit point, not parallel to the ground"
	)
	_expect(
		core_mesh != null
		and is_equal_approx(
			core_mesh.height, launch_position.distance_to(ground_position)
		),
		"the beam mesh length must equal the full 3D distance to the hit"
	)
	_expect(
		glow_material != null
		and is_equal_approx(glow_material.albedo_color.a, 0.24)
		and glow_mesh.top_radius > LaserBeamScript.GLOW_RADIUS
		and glow_material.emission.b > glow_material.emission.g
		and glow_material.emission.g > glow_material.emission.r
		and glow_material.emission_energy_multiplier > 2.5,
		"the Laser Tank beam must have a wider blue-azure outer glow without extra opacity"
	)
	await process_frame
	_expect(
		is_instance_valid(projectile) and not projectile.is_queued_for_deletion(),
		"a laser must survive deferred hitscan cleanup long enough to render"
	)
	projectile.free()

	Fx.free_muzzle_effects(root)
	var laser_tank_model := ORLaserTankModelScene.instantiate() as Node3D
	laser_tank_model.position.y = 4.0
	root.add_child(laser_tank_model)
	var laser_tank_turret = CombatTurretScript.new()
	_expect(
		laser_tank_turret.configure(&"ORLaserTankBase")
		and laser_tank_turret.bind_model(laser_tank_model, 0),
		"the Laser Tank must bind its authored muzzle"
	)
	var tank_emission := laser_tank_turret.peek_emission()
	var tank_target := Vector3(tank_emission.get("position", Vector3.ZERO)) \
		+ Vector3(tank_emission.get("direction", Vector3.FORWARD)) * 5.0
	tank_target.y = 0.0
	for unused in 30:
		if laser_tank_turret.aim_at(tank_target, 0.05):
			break
	tank_emission = laser_tank_turret.peek_emission()
	var tank_projectiles: Array = laser_tank_turret.try_fire_at(
		FireRequestScript.at(tank_target, laser_tank_model, root)
	)
	var tank_muzzle := root.get_node_or_null("MuzzleFlash_Ltmuzzle") as Node3D
	var tank_muzzle_visual := tank_muzzle.get_node_or_null("Visual") as Node3D \
		if tank_muzzle != null else null
	var fixed_laser := tank_muzzle_visual.find_child("_laser", true, false) \
		if tank_muzzle_visual != null else null
	var fixed_laser_meshes := fixed_laser.find_children(
		"*", "MeshInstance3D", true, false
	) if fixed_laser != null else []
	var all_fixed_laser_meshes_hidden := not fixed_laser_meshes.is_empty()
	for fixed_laser_mesh in fixed_laser_meshes:
		all_fixed_laser_meshes_hidden = all_fixed_laser_meshes_hidden \
			and not (fixed_laser_mesh as MeshInstance3D).visible
	var reference_muzzle_visual := laser_tank_turret.muzzle_flash_scene.instantiate() as Node3D
	var expected_muzzle_scale := reference_muzzle_visual.scale \
		* CombatTurretScript.LASER_MUZZLE_VISUAL_SCALE
	reference_muzzle_visual.free()
	var resolved_tank_direction := Vector3(tank_emission["position"]).direction_to(
		tank_target
	)
	_expect(
		tank_projectiles.size() == 1
		and tank_projectiles[0].get_node_or_null("LaserBeam") != null
		and tank_muzzle != null
		and tank_muzzle_visual != null
		and fixed_laser_meshes.size() == 2
		and all_fixed_laser_meshes_hidden
		and tank_muzzle_visual.scale.is_equal_approx(expected_muzzle_scale)
		and tank_muzzle.global_basis.z.normalized().is_equal_approx(
			resolved_tank_direction
		),
		"ORLaserTank must keep a scaled Ltmuzzle accent aligned with the resolved beam"
	)
	for tank_projectile in tank_projectiles:
		if is_instance_valid(tank_projectile):
			tank_projectile.free()
	laser_tank_model.free()

	var infantry_model := IMAdvSardaukarModelScene.instantiate() as Node3D
	root.add_child(infantry_model)
	var infantry_turret = CombatTurretScript.new()
	_expect(
		infantry_turret.configure(&"IMADVSardaukarGun")
		and infantry_turret.bind_model(infantry_model, 0),
		"the Advanced Sardaukar gun must bind its authored firing marker"
	)
	var emission := infantry_turret.peek_emission()
	var infantry_target := Vector3(emission.get("position", Vector3.ZERO)) \
		+ Vector3(emission.get("direction", Vector3.FORWARD)) * 5.0
	var infantry_projectiles: Array = infantry_turret.try_fire_at(
		FireRequestScript.at(infantry_target, infantry_model, root)
	)
	_expect(
		infantry_projectiles.size() == 1
		and infantry_projectiles[0].bullet.id() == &"InfLaser_B"
		and infantry_projectiles[0].get_node_or_null("LaserBeam") != null,
		"InfLaser_B must create the same visible resolved beam without a muzzle-flash resource"
	)
	for infantry_projectile in infantry_projectiles:
		if is_instance_valid(infantry_projectile):
			infantry_projectile.free()
	infantry_model.free()


func _test_muzzle_fx_bank_smoke() -> void:
	var _rules = root.get_node("Rules")
	var cases := [
		[&"ATTrikeGun", &"Muzzle1", 0.5, 7.5],
		[&"ATAPCBase", &"Muzzle1", 0.5, 7.5],
		[&"ATMongooseMissile", &"Muzzle3", 0.625, 5.0],
		[&"ATMinotaurusBase", &"Muzzle3", 0.625, 5.0],
	]
	for case_index in cases.size():
		var smoke_case: Array = cases[case_index]
		var turret = CombatTurretScript.new()
		_expect(
			turret.configure(StringName(smoke_case[0])),
			"%s must configure for muzzle-bank smoke" % String(smoke_case[0])
		)
		_expect(
			turret.muzzle_flash_id == smoke_case[1]
			and turret.muzzle_flash_scene != null,
			"%s must resolve %s" % [smoke_case[0], smoke_case[1]]
		)
		var emission_index := 10 + case_index
		turret._spawn_muzzle_flash(root, {
			"index": emission_index,
			"position": Vector3(4.0 + case_index, 1.0, 3.0),
			"direction": Vector3.FORWARD,
		})
		await create_timer(0.28).timeout
		var smoke_particles := Fx.muzzle_effects(root, &"barrel_smoke", emission_index)
		_expect(
			smoke_particles.size() == 2,
			"%s must emit two particles between its authored start/stop frames"
				% String(smoke_case[1])
		)
		var bank_driven := smoke_particles.size() == 2
		for particle in smoke_particles:
			var visual := particle.get_node_or_null("Visual") as MeshInstance3D
			var quad := visual.mesh as QuadMesh if visual != null else null
			var start := Vector3(particle.get_meta(
				"combat_muzzle_start_position", particle.global_position
			))
			var acceleration := Vector3(particle.get_meta(
				"combat_muzzle_acceleration", Vector3.ZERO
			))
			bank_driven = bank_driven \
				and particle.get_meta("combat_fx_texture", &"") == &"!%Bru" \
				and quad != null \
				and quad.size.is_equal_approx(
					Vector2.ONE * float(smoke_case[2])
				) \
				and is_equal_approx(acceleration.y, float(smoke_case[3])) \
				and particle.global_position.y > start.y
		_expect(
			bank_driven,
			"%s smoke must use bank texture, size, and negative-gravity buoyancy"
				% String(smoke_case[1])
		)
		Fx.free_muzzle_effects(root)

	var no_smoke_turret = CombatTurretScript.new()
	_expect(
		no_smoke_turret.configure(&"ATSniperGun"),
		"the Sniper muzzle flash must configure for the negative smoke case"
	)
	no_smoke_turret._spawn_muzzle_flash(root, {
		"index": 20,
		"position": Vector3.ZERO,
		"direction": Vector3.FORWARD,
	})
	await create_timer(0.28).timeout
	_expect(
		Fx.muzzle_effects(root, &"barrel_smoke", 20).is_empty(),
		"Smuzz2 without an !%Bru bank must not acquire barrel smoke"
	)
	Fx.free_muzzle_effects(root)


func _test_model_fx_bank_casings() -> void:
	var cases := [
		[ATMinotaurusModelScene, &"ATMinotaurusBase", 4, 0.625, 12.5, 1.27,
			["#muzzle06", "#muzzle05", "#muzzle08", "#muzzle07"]],
		[ATTrikeModelScene, &"ATTrikeGun", 2, 0.375, 7.5, 0.22,
			["Gun", "Gun"]],
		[ATInfantryModelScene, &"ATInfGun", 7, 0.1875, 7.5, 1.37,
			["gun", "gun", "gun", "gun", "gun", "gun", "gun"]],
		[ATSniperModelScene, &"ATSniperGun", 1, 0.1875, 0.75, 1.02,
			["Agunbone"]],
		[ATAPCModelScene, &"ATAPCBase", 3, 0.25, 7.5, 0.37,
			["::1turret#", "::1turret#", "::1turret#"]],
		[ATMongooseModelScene, &"ATMongooseMissile", 0, 0.0, 0.0, 0.0, []],
	]
	for casing_case: Array in cases:
		Fx.free_muzzle_effects(root)
		var model := (casing_case[0] as PackedScene).instantiate() as Node3D
		root.add_child(model)
		var turret = CombatTurretScript.new()
		_expect(
			turret.configure(StringName(casing_case[1]))
			and turret.bind_model(model, 0),
			"%s must bind for casing-bank playback" % String(casing_case[1])
		)
		var observed: Array[Dictionary] = []
		var observe_casing := func(child: Node) -> void:
			if child.get_meta("combat_muzzle_fx", &"") != &"casing":
				return
			observed.append({
				"texture": child.get_meta("combat_fx_texture", &""),
				"size": float(child.get_meta("combat_fx_particle_size", 0.0)),
				"acceleration": Vector3(child.get_meta(
					"combat_muzzle_acceleration", Vector3.ZERO
				)),
				"velocity": Vector3(child.get_meta(
					"combat_muzzle_velocity", Vector3.ZERO
				)),
				"attachment": String(child.get_meta("combat_fx_attachment", "")),
			})
		root.child_entered_tree.connect(observe_casing)
		var started := turret.start_authored_fire_fx(&"Fire_0", root)
		_expect(
			int(casing_case[2]) == 0 or started,
			"%s must start authored FX when its !%%shel bank has emissions"
				% String(casing_case[1])
		)
		if int(casing_case[2]) > 0:
			await create_timer(float(casing_case[5])).timeout
		root.child_entered_tree.disconnect(observe_casing)
		_expect(
			observed.size() == int(casing_case[2]),
			"%s must emit %d authored casings, found %d"
				% [casing_case[1], casing_case[2], observed.size()]
		)
		var bank_driven := observed.size() == int(casing_case[2])
		var attachments: Array[String] = []
		for casing: Dictionary in observed:
			var acceleration := Vector3(casing["acceleration"])
			bank_driven = bank_driven \
				and casing["texture"] == &"!%shel" \
				and is_equal_approx(float(casing["size"]), float(casing_case[3])) \
				and is_equal_approx(-acceleration.y, float(casing_case[4])) \
				and not Vector3(casing["velocity"]).is_zero_approx()
			attachments.append(String(casing["attachment"]))
		_expect(
			bank_driven and attachments == casing_case[6],
			"%s casings must retain bank size, gravity, and authored attachments"
				% String(casing_case[1])
		)
		turret.cancel_authored_fire_fx()
		Fx.free_muzzle_effects(root)
		model.free()

	# Kobra's deployed clip is repaired from source "Fire 1" to
	# "Deployed_Fire" during conversion. Its FX range must carry the same baked
	# name so the generic runtime lookup can still find the authored shell bank.
	var kobra_model := ORKobraModelScene.instantiate() as Node3D
	root.add_child(kobra_model)
	var kobra_turret = CombatTurretScript.new()
	_expect(
		kobra_turret.configure(&"ORKobraDeployedGun")
		and kobra_turret.bind_model(kobra_model, 1),
		"the deployed Kobra turret must bind for casing-bank playback"
	)
	var kobra_casings: Array[Node] = []
	var observe_kobra_casing := func(child: Node) -> void:
		if child.get_meta("combat_muzzle_fx", &"") == &"casing":
			kobra_casings.append(child)
	root.child_entered_tree.connect(observe_kobra_casing)
	var kobra_started := kobra_turret.start_authored_fire_fx(
		&"Deployed_Fire", root
	)
	await create_timer(0.15).timeout
	root.child_entered_tree.disconnect(observe_kobra_casing)
	_expect(
		kobra_started and kobra_casings.size() == 1,
		"Deployed_Fire must emit Kobra's authored Fire 1 casing after conversion"
	)
	kobra_turret.cancel_authored_fire_fx()
	Fx.free_muzzle_effects(root)
	kobra_model.free()


func _test_discrete_fire_skips_particle_streams() -> void:
	var cases := [
		[ATKindjalModelScene, &"ATKindjalBigGun", 1, &"Deployed_Fire"],
		[ORKobraModelScene, &"ORKobraUndeployedGun", 0, &"Fire_0"],
		[HKAssaultModelScene, &"HKAssaultTankBase", 0, &"Fire_0"],
		[HKTrooperModelScene, &"HKTrooperGun", 0, &"Fire_0"],
		[ATSniperModelScene, &"ATSniperGun", 0, &"Fire_0"],
		[ORMortarModelScene, &"ORMortarInfBigGun", 1, &"Deployed_Fire"],
	]
	for discrete_case: Array in cases:
		var model := (discrete_case[0] as PackedScene).instantiate() as Node3D
		root.add_child(model)
		var turret = CombatTurretScript.new()
		var turret_id := StringName(discrete_case[1])
		_expect(
			turret.configure(turret_id)
			and turret.bind_model(model, int(discrete_case[2]))
			and not turret.is_continuous_bullet(),
			"%s must bind as a discrete weapon" % String(turret_id)
		)
		turret.start_authored_fire_fx(StringName(discrete_case[3]), root)
		_expect(
			turret._particle_timeline_tweens.is_empty(),
			"%s must not schedule its muzzle smoke/blast bank as a forward stream"
				% String(turret_id)
		)
		turret.cancel_authored_fire_fx()
		model.free()


func _test_model_fx_bank_streams() -> void:
	var cases := [
		[ORChemicalModelScene, &"ORChemicalGun", &"!sm"],
		[HKFlamerModelScene, &"HKFlamerGun", &"!%01fire"],
		[HKFlameModelScene, &"HKFlameTankRight", &"!%01fire"],
	]
	for stream_case: Array in cases:
		Fx.free_muzzle_effects(root)
		var model := (stream_case[0] as PackedScene).instantiate() as Node3D
		root.add_child(model)
		var turret = CombatTurretScript.new()
		_expect(
			turret.configure(StringName(stream_case[1]))
			and turret.bind_model(model, 0),
			"%s must bind for authored stream playback" % String(stream_case[1])
		)
		var observed: Array[Dictionary] = []
		var observe_stream := func(child: Node) -> void:
			if child.get_meta("combat_muzzle_fx", &"") != &"authored_stream":
				return
			observed.append({
				"texture": child.get_meta("combat_fx_texture", &""),
				"velocity": child.get_meta(
					"combat_muzzle_velocity", Vector3.ZERO
				),
				"attachment": child.get_meta("combat_fx_attachment", ""),
			})
		root.child_entered_tree.connect(observe_stream)
		_expect(
			turret.start_authored_fire_fx(&"Fire_0", root),
			"%s Fire_0 must start its authored particle banks"
				% String(stream_case[1])
		)
		await create_timer(0.5).timeout
		root.child_entered_tree.disconnect(observe_stream)
		_expect(
			not observed.is_empty(),
			"%s must emit visible stream particles" % String(stream_case[1])
		)
		var expected_texture := StringName(stream_case[2])
		var bank_driven := not observed.is_empty()
		var saw_expected_texture := false
		var saw_motion := false
		for particle: Dictionary in observed:
			bank_driven = bank_driven \
				and String(particle["attachment"]).begins_with(">>")
			saw_expected_texture = saw_expected_texture \
				or particle["texture"] == expected_texture
			saw_motion = saw_motion \
				or not Vector3(particle["velocity"]).is_zero_approx()
		_expect(
			bank_driven and saw_expected_texture and saw_motion,
			"%s stream must retain its authored texture, motion, and muzzle attachment: %s"
				% [stream_case[1], observed]
		)
		var emission := turret.peek_emission()
		var target_position: Vector3 = Vector3(emission["position"]) \
			+ Vector3(emission["direction"]) * 2.0
		var stream_request := FireRequestScript.at(target_position, model, root)
		stream_request.begin_reload_after_shot = false
		var projectiles: Array = turret.try_fire_at(stream_request)
		_expect(
			projectiles.size() == 1
			and Fx.muzzle_effects(root, &"shot_light").is_empty(),
			"%s continuous stream must not add a generic ballistic shot light"
				% String(stream_case[1])
		)
		if stream_case[1] == &"HKFlamerGun" and not projectiles.is_empty():
			_expect(
				projectiles[0].get_node_or_null("Visual") == null,
				"HKFlamerGun must not draw a yellow fallback bolt through its flame stream"
			)
		for projectile in projectiles:
			if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
				projectile.free()
		turret.cancel_authored_fire_fx()
		Fx.free_muzzle_effects(root)
		model.free()

