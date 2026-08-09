extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatImpactResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")
const CombatGroundDecalScript := preload("res://scripts/combat/combat_ground_decal.gd")
const CombatLingerEffectScript := preload("res://scripts/combat/combat_linger_effect.gd")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const LaserBeamScript := preload("res://scripts/combat/fx/laser_beam.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const ShotPayloadScript := preload("res://scripts/combat/shot_payload.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Fx := preload("res://tests/combat/support/combat_fx_probe.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const Assertions := preload("res://tests/combat/support/combat_assertions.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATAPCModelScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const ATSniperModelScene := preload(
	"res://assets/converted/models/AT_Sniper_H0/AT_Sniper_H0.scn"
)
const ATTrikeModelScene := preload(
	"res://assets/converted/models/AT_Trike_H0/AT_Trike_H0.scn"
)
const ATMongooseModelScene := preload(
	"res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn"
)
const ATMinotaurusModelScene := preload(
	"res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn"
)
const ORMortarModelScene := preload(
	"res://assets/converted/models/OR_Mortar_H0/OR_Mortar_H0.scn"
)
const HKMissileModelScene := preload(
	"res://assets/converted/models/HK_missile_H0/HK_missile_H0.scn"
)
const HKDevastatorModelScene := preload(
	"res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn"
)
const HKInkVineModelScene := preload(
	"res://assets/converted/models/HK_Inkvine_H0/HK_Inkvine_H0.scn"
)
const HKFlamerModelScene := preload(
	"res://assets/converted/models/HK_Flamer_H0/HK_Flamer_H0.scn"
)
const HKFlameModelScene := preload(
	"res://assets/converted/models/HK_flame_H0/HK_flame_H0.scn"
)
const ORChemicalModelScene := preload(
	"res://assets/converted/models/OR_Chemical_H0/OR_Chemical_H0.scn"
)
const HKTrooperModelScene := preload(
	"res://assets/converted/models/HK_Trooper_H0/HK_Trooper_H0.scn"
)
const HKAssaultModelScene := preload(
	"res://assets/converted/models/HK_assault_H0/HK_assault_H0.scn"
)
const ORAATrooperModelScene := preload(
	"res://assets/converted/models/OR_AATrooper_H0/OR_AATrooper_H0.scn"
)
const ORAPCModelScene := preload("res://assets/converted/models/Or_apc_H0/Or_apc_H0.scn")
const ORLaserTankModelScene := preload(
	"res://assets/converted/models/OR_Lasertank_H0/OR_Lasertank_H0.scn"
)
const IMAdvSardaukarModelScene := preload(
	"res://assets/converted/models/IM_ADVSardaukar_H0/IM_ADVSardaukar_H0.scn"
)
const ATKindjalModelScene := preload(
	"res://assets/converted/models/AT_Kindjal_H0/AT_Kindjal_H0.scn"
)
const ORKobraModelScene := preload(
	"res://assets/converted/models/OR_Kobra_H0/OR_Kobra_H0.scn"
)
const HKGunTurretScene := preload(
	"res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn"
)
const HKStarportScene := preload(
	"res://assets/converted/buildings/HKStarport/HKStarport.scn"
)
const ATWallScene := preload(
	"res://assets/converted/buildings/ATWall/ATWall.scn"
)

var _bullets := Bullets.new()


## Stands in for a cliff face or rock shoulder: static geometry on the terrain
## collision layer between a shooter and its target.
class PhysicsCliff extends StaticBody3D:
	func _init(world_position: Vector3, size: Vector3) -> void:
		position = world_position
		collision_layer = 1
		collision_mask = 0
		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		collision.shape = box
		add_child(collision)


## Same collider and layer as Doubles.PhysicsCombatTarget, but exposing the footprint
## hull that identifies a building rather than a unit.
class RejectingAttackNavigation extends RefCounted:
	var destinations: Array[Vector3] = []

	func command_move(units: Array, target: Vector3, _mode: int) -> Array:
		destinations.append(target)
		if destinations.size() <= 2:
			return []
		for unit in units:
			unit.set_navigation_destination(target)
		return [{"unit": units.front(), "position": target}]

	func route_is_unreachable(_unit: Node3D) -> bool:
		return false

	func arrival_tolerance(_unit: Node3D) -> float:
		return 0.2

	func stop(_unit: Node3D) -> void:
		pass


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case(
		"lasers span the resolved 3D hit segment and remain visible briefly",
		_test_laser_hitscan_visual
	)
	await _run_async_case(
		"muzzle FX banks emit authored rising barrel smoke",
		_test_muzzle_fx_bank_smoke
	)
	await _run_async_case(
		"model FX banks emit authored casing counts and sizes",
		_test_model_fx_bank_casings
	)
	_run_case(
		"discrete Fire clips do not turn muzzle accents into particle streams",
		_test_discrete_fire_skips_particle_streams
	)
	await _run_async_case(
		"flame and chemical Fire clips emit authored particle streams",
		_test_model_fx_bank_streams
	)
	_run_case(
		"ground decals fade through seven overlapping crater layers",
		_test_ground_decal_overlap_budget
	)
	await _run_async_case(
		"turret launches projectiles and composes the authored impact FX",
		_test_turret_projectile_launch
	)
	await _run_async_case(
		"Mongoose composes launch backblast and missile impact FX",
		_test_mongoose_launch_and_impact_fx
	)
	await _run_async_case(
		"Deviate_B/Gas_B compose the DeviateHit impact FX",
		_test_deviate_hit_impact_fx
	)
	await _run_async_case(
		"DevPlasma_B impacts as its own DevImpact cloud, never the generic ShellHit",
		_test_dev_impact_fx
	)
	_run_case(
		"Devastator salvo tubes fire their authored rocket flare",
		_test_devastator_missile_launch_blast
	)
	_run_case(
		"Fire track topology determines firing while moving",
		_test_fire_while_moving_capability
	)
	_run_case(
		"moving after an infantry shot cancels Fire without committing reload",
		_test_blocking_fire_move_cancel
	)
	_run_case(
		"independent side turrets acquire separate targets and escape blind zones",
		_test_independent_side_turrets
	)
	_run_case("turret recenters smoothly after attack is replaced by move", _test_turret_recenter_after_move)
	_run_case("unit model replacement rebinds its turret", _test_unit_turret_rebind)
	await _run_async_case(
		"weapon range reaches the nearest building edge",
		_test_building_edge_range
	)
	await _run_async_case(
		"HKTrooper forced fire damages a friendly HKGunTurret combat hull",
		_test_hktrooper_building_damage
	)
	await _run_async_case(
		"HKStarport courtyard remains empty projectile space",
		_test_hkstarport_courtyard_collision
	)
	_run_case("unit attack orders validate targets, fire, and pursue", _test_unit_attack_order)
	_run_case("Ink Vine repeats fire while its attack order remains active", _test_ink_vine_refire)
	_run_case("attack pursuit backs rejected firing positions toward the unit", _test_rejected_attack_perch)
	_run_case("pursuit enters a stable firing range", _test_far_attack_pursuit)
	await _run_async_case(
		"an obstructed in-range order repositions instead of shooting the obstacle",
		_test_obstructed_attack_order
	)
	_run_case("building state replacement rebinds its turret", _test_building_turret_rebind)
	_run_case(
		"all seven defensive buildings automatically acquire and fire",
		_test_defensive_building_auto_fire
	)
	await _run_async_case(
		"building StatePlayer leaves visible turret aiming to the combat servo",
		_test_defensive_building_visible_aim
	)
	_run_case(
		"ATRocketTurret fires each authored shot from the muzzle its animation "
			+ "actually opens, not a plain round-robin",
		_test_atrocket_turret_muzzle_matches_authored_animation
	)
	_run_case(
		"stopping a defensive turret's burst returns its authored muzzle "
			+ "flash to rest",
		_test_defensive_turret_stop_clears_muzzle_flash
	)
	await _run_async_case(
		"Ordos popup turrets visibly deploy, hold, and undeploy",
		_test_ordos_popup_turret_animations
	)
	_run_case(
		"defensive buildings retain explicit out-of-range attack orders",
		_test_building_attack_order
	)
	await _run_async_case(
		"a defensive building skips shielded targets for reachable ones",
		_test_building_obstructed_targets
	)
	_run_case("building damage visuals use equal health bands", _test_building_damage_visual_states)

	_finish("Combat tests")


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
	var oldest_material := (oldest_mesh.mesh as PlaneMesh).material \
		as StandardMaterial3D
	_expect(
		int(created_decals.front().get_meta("overlap_fade_steps", 0))
			== CombatGroundDecalScript.MAXIMUM_OVERLAPPING_DECALS - 1
			and is_equal_approx(
				oldest_material.albedo_color.a,
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














func _test_fire_while_moving_capability() -> void:
	var mongoose = UnitScene.instantiate()
	mongoose.config_id = &"ATMongoose"
	root.add_child(mongoose)
	mongoose.replace_visual_scene(ATMongooseModelScene)
	var minotaurus = UnitScene.instantiate()
	minotaurus.config_id = &"ATMinotaurus"
	root.add_child(minotaurus)
	minotaurus.replace_visual_scene(ATMinotaurusModelScene)
	var devastator = UnitScene.instantiate()
	devastator.config_id = &"HKDevastator"
	root.add_child(devastator)
	devastator.replace_visual_scene(HKDevastatorModelScene)

	_expect(
		mongoose.weapon_can_fire_while_moving(0),
		"Mongoose Fire_0 must layer over its sibling leg locomotion"
	)
	_expect(
		not minotaurus.weapon_can_fire_while_moving(0),
		"Minotaurus Fire_0 moves its legs and must remain a braced full-body action"
	)
	_expect(
		not devastator.weapon_can_fire_while_moving(0)
		and devastator.weapon_can_fire_while_moving(1),
		"only the Devastator's independently animated missile turret may fire while moving"
	)

	var emission: Dictionary = mongoose.combat_turrets[0].peek_emission()
	var forward: Vector3 = emission["direction"]
	forward.y = 0.0
	forward = forward.normalized()
	var target_direction := forward.rotated(Vector3.UP, deg_to_rad(60.0))
	var target := Doubles.PhysicsCombatTarget.new(
		Vector3(emission["position"]) + target_direction * 5.0
	)
	root.add_child(target)
	var movement_samples: Array[bool] = []
	var projectile_directions: Array[Vector3] = []
	var muzzle_directions: Array[Vector3] = []
	var facing_directions: Array[Vector3] = []
	var fired_targets: Array = []
	mongoose.weapon_fired.connect(func(
		projectiles: Array, fired_target: Variant, _weapon_index: int
		) -> void:
		movement_samples.append(mongoose._locomotion.is_movement_animation_active())
		fired_targets.append(fired_target)
		var muzzle: Vector3 = mongoose.combat_turrets[0].peek_emission()["direction"]
		muzzle.y = 0.0
		muzzle_directions.append(muzzle.normalized())
		var facing: Vector3 = mongoose.facing_direction()
		facing.y = 0.0
		facing_directions.append(facing.normalized())
		for projectile in projectiles:
			if is_instance_valid(projectile):
				var shot_direction: Vector3 = projectile.direction()
				shot_direction.y = 0.0
				projectile_directions.append(shot_direction.normalized())
				projectile.free()
	)
	_expect(
		mongoose.command_attack(target),
		"Mongoose must accept the target before its movement order"
	)
	mongoose.move_to(mongoose.global_position + forward * 20.0)
	_expect(
		not mongoose.has_attack_order()
		and mongoose.combat()._weapon_targets.has(0)
		and mongoose.combat()._moving_fire_weapons.has(0),
		"Move must replace pursuit and enable autonomous fire for its movable turret"
	)
	for frame in 180:
		mongoose._process(1.0 / 60.0)
		mongoose._physics_process(1.0 / 60.0)
		if true in movement_samples:
			break
	_expect(
		true in movement_samples,
		"Mongoose must keep tracking and fire through its Move animation"
	)
	_expect(
		not projectile_directions.is_empty()
		and projectile_directions[0].dot(muzzle_directions[0]) > 0.999,
		"Mongoose projectiles must leave along the independently aimed turret muzzle"
	)
	_expect(
		not projectile_directions.is_empty()
		and projectile_directions[0].dot(facing_directions[0]) < 0.9,
		"Mongoose side shots must not be forced along the unit's movement heading"
	)
	target.global_position = mongoose.global_position + forward * 100.0
	for frame in 180:
		mongoose._process(1.0 / 60.0)
		mongoose._physics_process(1.0 / 60.0)
		if mongoose.combat()._weapon_fire_sequences.is_empty():
			break
	var out_of_range_yaw := absf(
		mongoose.combat_turrets[0].current_yaw_degrees()
	)
	var mongoose_player := mongoose.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if mongoose_player != null:
		mongoose_player.advance(1.0 / 60.0)
	mongoose._process(1.0 / 60.0)
	var returning_yaw := absf(mongoose.combat_turrets[0].current_yaw_degrees())
	_expect(
		returning_yaw < out_of_range_yaw and returning_yaw > 0.0,
		"an out-of-range retained target must release the Mongoose turret through its servo"
	)
	var returning_direction: Vector3 = (
		mongoose.combat_turrets[0].peek_emission()["direction"]
	)
	_expect(
		absf(
			rad_to_deg(Assertions.horizontal_angle_between(forward, returning_direction))
			- returning_yaw
		) < 0.1,
		"the visible Mongoose turret must not snap forward when its target leaves range"
	)
	var autonomous_target := Doubles.PhysicsCombatTarget.new(
		mongoose.global_position
			+ forward.rotated(Vector3.UP, deg_to_rad(-60.0)) * 5.0
	)
	autonomous_target.owner_player_id = 2
	root.add_child(autonomous_target)
	autonomous_target.add_to_group(&"units")
	for frame in 600:
		mongoose._process(1.0 / 60.0)
		mongoose._physics_process(1.0 / 60.0)
		if autonomous_target in fired_targets:
			break
	_expect(
		autonomous_target in fired_targets,
		"a moving Mongoose must acquire a new nearby enemy instead of waiting for its old target"
	)
	autonomous_target.free()
	target.free()
	mongoose.free()
	minotaurus.free()
	devastator.free()


func _test_blocking_fire_move_cancel() -> void:
	var infantry = UnitScene.instantiate()
	infantry.config_id = &"ATInfantry"
	root.add_child(infantry)
	infantry.replace_visual_scene(ATInfantryModelScene)
	var emission: Dictionary = infantry.turret_emission_points()[0]
	var target := Vector3(emission["position"]) \
		+ Vector3(emission["direction"]).normalized() * 5.0
	var projectiles: Array = []
	infantry.weapon_fired.connect(func(
		shots: Array, _target: Variant, _weapon_index: int
		) -> void:
		projectiles.append_array(shots)
	)
	_expect(
		infantry.command_attack(target),
		"infantry must begin a blocking authored Fire action"
	)
	for frame in 240:
		infantry._process(1.0 / 60.0)
		if not projectiles.is_empty():
			break
	_expect(
		not projectiles.is_empty() and infantry._fire_sequence_active,
		"the movement regression must cancel after the shot but before Fire ends"
	)
	infantry.move_to(infantry.global_position + Vector3.RIGHT * 10.0)
	_expect(
		infantry.combat()._weapon_fire_sequences.is_empty(),
		"a movement order must cancel the blocking Fire sequence"
	)
	_expect(
		is_zero_approx(infantry.combat_turrets[0].reload_ticks_remaining),
		"canceling blocking Fire for movement must not commit infantry reload"
	)
	for projectile in projectiles:
		if is_instance_valid(projectile):
			projectile.free()
	infantry.free()


func _test_independent_side_turrets() -> void:
	var pose_flame = UnitScene.instantiate()
	pose_flame.config_id = &"HKFlame"
	root.add_child(pose_flame)
	pose_flame.replace_visual_scene(HKFlameModelScene)
	var first_turret = pose_flame.combat_turrets[0]
	var second_turret = pose_flame.combat_turrets[1]
	var first_emission: Dictionary = first_turret.peek_emission()
	var second_emission: Dictionary = second_turret.peek_emission()
	var first_target := Vector3(first_emission["position"]) \
		+ Vector3(first_emission["direction"]).rotated(
			Vector3.UP, deg_to_rad(-25.0)
		).normalized() * 5.0
	var second_target := Vector3(second_emission["position"]) \
		+ Vector3(second_emission["direction"]).normalized() * 5.0
	_expect(
		pose_flame.combat()._start_authored_fire_sequence(first_turret, first_target),
		"the first side turret must start its authored sequence"
	)
	first_turret.aim_at(first_target, 10.0)
	var first_direction_before: Vector3 = first_turret.peek_emission()["direction"]
	_expect(
		pose_flame.combat()._start_authored_fire_sequence(second_turret, second_target),
		"the second side turret must start while the first sequence is active"
	)
	var first_direction_after: Vector3 = first_turret.peek_emission()["direction"]
	_expect(
		first_direction_before.normalized().dot(first_direction_after.normalized())
			> 0.9999,
		"starting a staggered second sequence must preserve the first turret aim"
	)
	pose_flame.free()

	var flame = UnitScene.instantiate()
	flame.config_id = &"HKFlame"
	flame.owner_player_id = 1
	root.add_child(flame)
	flame.replace_visual_scene(HKFlameModelScene)
	_expect(
		flame.combat_turrets.size() == 2
		and flame.weapon_can_fire_while_moving(0)
		and flame.weapon_can_fire_while_moving(1),
		"both HKFlame side turrets must be independent movable-fire weapons"
	)

	var emissions: Array[Dictionary] = [
		flame.combat_turrets[0].peek_emission(),
		flame.combat_turrets[1].peek_emission(),
	]
	var forward := (
		Vector3(emissions[0]["direction"])
		+ Vector3(emissions[1]["direction"])
	).normalized()
	forward.y = 0.0
	forward = forward.normalized()
	var side_targets: Array[Doubles.PhysicsCombatTarget] = []
	for angle in [-60.0, 60.0]:
		var direction := forward.rotated(Vector3.UP, deg_to_rad(angle))
		var target := Doubles.PhysicsCombatTarget.new(
			flame.global_position + direction * 5.0
		)
		target.owner_player_id = 2
		root.add_child(target)
		target.add_to_group(&"units")
		side_targets.append(target)

	var target_for_weapon: Dictionary = {}
	for target in side_targets:
		var reachable: Array[int] = []
		for turret in flame.combat_turrets:
			if not turret.requires_hull_turn_for(target.global_position):
				reachable.append(turret.weapon_index())
		_expect(
			reachable.size() == 1,
			"each side target must belong to exactly one HKFlame firing sector"
		)
		if reachable.size() == 1:
			target_for_weapon[reachable[0]] = target
	_expect(
		target_for_weapon.size() == 2,
		"opposite side targets must exercise both independent HKFlame turrets"
	)

	var commanded_target: Doubles.PhysicsCombatTarget = target_for_weapon.get(0) \
		as Doubles.PhysicsCombatTarget
	var fired_targets: Dictionary = {}
	flame.weapon_fired.connect(func(
		projectiles: Array, fired_target: Variant, weapon_index: int
		) -> void:
		fired_targets[weapon_index] = fired_target
		for projectile in projectiles:
			if is_instance_valid(projectile):
				projectile.free()
	)
	_expect(
		commanded_target != null and flame.command_attack(commanded_target),
		"HKFlame must accept the target in one side sector"
	)
	for frame in 240:
		flame._process(1.0 / 60.0)
		if fired_targets.size() >= 2:
			break
	_expect(
		fired_targets.get(0) == target_for_weapon.get(0)
		and fired_targets.get(1) == target_for_weapon.get(1),
		"the commanded turret and free turret must fire at separate reachable targets"
	)
	for target in side_targets:
		target.free()
	flame.free()

	var blind_flame = UnitScene.instantiate()
	blind_flame.config_id = &"HKFlame"
	root.add_child(blind_flame)
	blind_flame.replace_visual_scene(HKFlameModelScene)
	var blind_emissions: Array[Dictionary] = [
		blind_flame.combat_turrets[0].peek_emission(),
		blind_flame.combat_turrets[1].peek_emission(),
	]
	var blind_forward := (
		Vector3(blind_emissions[0]["direction"])
		+ Vector3(blind_emissions[1]["direction"])
	).normalized()
	blind_forward.y = 0.0
	blind_forward = blind_forward.normalized()
	var blind_target := Doubles.PhysicsCombatTarget.new(
		blind_flame.global_position + blind_forward * 5.0
	)
	root.add_child(blind_target)
	_expect(
		blind_flame.combat_turrets[0].requires_hull_turn_for(
			blind_target.global_position
		)
		and blind_flame.combat_turrets[1].requires_hull_turn_for(
			blind_target.global_position
		),
		"a centred target must begin inside the gap between the side sectors"
	)
	var initial_yaw: float = blind_flame.global_rotation.y
	var blind_shots: Array[int] = []
	blind_flame.weapon_fired.connect(func(
		projectiles: Array, _target: Variant, weapon_index: int
		) -> void:
		blind_shots.append(weapon_index)
		for projectile in projectiles:
			if is_instance_valid(projectile):
				projectile.free()
	)
	_expect(
		blind_flame.command_attack(blind_target),
		"HKFlame must accept a target in its current blind zone"
	)
	for frame in 360:
		blind_flame._process(1.0 / 60.0)
		if not blind_shots.is_empty():
			break
	_expect(
		absf(angle_difference(initial_yaw, blind_flame.global_rotation.y))
			> deg_to_rad(1.0),
		"the hull must turn out of the gap between the side sectors"
	)
	_expect(
		not blind_shots.is_empty(),
		"at least one side turret must fire after the hull leaves the blind zone"
	)
	blind_target.free()
	blind_flame.free()


func _test_turret_recenter_after_move() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATMinotaurus"
	root.add_child(unit)
	unit.replace_visual_scene(ATMinotaurusModelScene)
	var turret = unit.combat_turrets[0]
	var rest_emission: Dictionary = turret.peek_emission()
	var rest_direction: Vector3 = rest_emission["direction"]
	rest_direction.y = 0.0
	rest_direction = rest_direction.normalized()
	var target := Doubles.FakeCombatTarget.new(&"None")
	target.position = Vector3(rest_emission["position"]) \
		+ rest_direction.rotated(Vector3.UP, deg_to_rad(30.0)) * 10.0

	_expect(unit.command_attack(target), "the Minotaurus must accept the side target")
	for frame in 4:
		unit._process(1.0 / 20.0)
	var attack_yaw := absf(turret.current_yaw_degrees())
	_expect(
		is_equal_approx(attack_yaw, 20.0),
		"four rule updates must turn the Minotaurus turret by four 5-degree steps"
	)

	unit.move_to(unit.global_position + rest_direction * 10.0)
	_expect(not unit.has_attack_order(), "a move order must replace the attack order")
	var player := unit.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if player != null:
		# Reproduce the normal frame order: authored Move pose first, then Unit
		# combat logic restores its continuously changing servo pose.
		player.advance(1.0 / 60.0)
	unit._process(1.0 / 60.0)
	var returning_yaw := absf(turret.current_yaw_degrees())
	_expect(
		returning_yaw < attack_yaw and returning_yaw > 0.0,
		"the first movement frame must begin returning the turret instead of snapping or caching it"
	)
	_expect(
		absf(returning_yaw - (attack_yaw - 5.0 / 3.0)) < 0.01,
		"recentring must use the Minotaurus authored 5 degrees per 20 Hz update"
	)
	var returning_direction: Vector3 = turret.peek_emission()["direction"]
	_expect(
		absf(
			rad_to_deg(Assertions.horizontal_angle_between(rest_direction, returning_direction))
			- returning_yaw
		) < 0.1,
		"the visible turret pose and its logical servo angle must remain synchronized"
	)

	_expect(unit.command_attack(target), "the side target must remain attackable after moving")
	unit._process(1.0 / 60.0)
	var reacquired_direction: Vector3 = turret.peek_emission()["direction"]
	_expect(
		rad_to_deg(Assertions.horizontal_angle_between(returning_direction, reacquired_direction))
			<= 5.0 / 3.0 + 0.1,
		"a repeated attack order must resume from the visible pose without restoring a cached yaw"
	)
	unit.free()


func _test_unit_turret_rebind() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATAPC"
	root.add_child(unit)
	unit.replace_visual_scene(ATAPCModelScene)
	_expect(unit.combat_turrets.size() == 1, "ATAPC must create one runtime turret")
	_expect(unit.turret_emission_points().size() == 1, "the replacement APC model must expose >>0")
	var emission: Dictionary = unit.next_turret_emission()
	_expect(not emission.is_empty(), "Unit must forward its next world-space muzzle")
	_expect(
		unit.aim_turrets_at(Vector3(emission["position"]) + Vector3.RIGHT * 100.0, 0.05) == false,
		"Unit must forward incremental aiming before the target is reached"
	)
	var launch_emission: Dictionary = unit.turret_emission_points()[0]
	var projectiles: Array = unit.fire_weapon_at(
		Vector3(launch_emission["position"]) + Vector3(launch_emission["direction"]) * 5.0,
		0,
		root
	)
	_expect(projectiles.size() == 1, "Unit must launch its configured weapon through the turret")
	if not projectiles.is_empty():
		_expect(projectiles[0].bullet.id() == &"LMG_B", "the APC Unit API must emit LMG_B")
		projectiles[0].free()
	unit.free()


func _test_unit_attack_order() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATAPC"
	root.add_child(unit)
	unit.replace_visual_scene(ATAPCModelScene)
	var emission: Dictionary = unit.turret_emission_points()[0]
	var direction: Vector3 = emission["direction"]
	var target := Doubles.FakeCombatTarget.new(&"None")
	target.position = Vector3(emission["position"]) + direction * 5.0
	var aircraft := Doubles.FakeCombatTarget.new(&"Aircraft", true)
	aircraft.position = target.position
	_expect(unit.can_attack(target), "an armed APC must accept a compatible ground target")
	_expect(not unit.can_attack(aircraft), "the APC must reject a target its bullet cannot hit")
	_expect(not unit.command_attack(aircraft), "an incompatible target must not create an attack order")
	_expect(
		unit.combat_turrets[0].target_range(target) == CombatTurretScript.TargetRange.IN_RANGE,
		"the compatible target must start inside the APC weapon range"
	)

	var fired_batches: Array = []
	unit.weapon_fired.connect(func(projectiles: Array, fired_target: Variant, weapon_index: int) -> void:
		fired_batches.append({
			"projectiles": projectiles,
			"target": fired_target,
			"weapon_index": weapon_index,
		})
	)
	_expect(unit.command_attack(target), "a compatible target must create an attack order")
	_expect(unit.has_attack_order() and unit.attack_order_target() == target, "the live target must remain attached to the order")
	for frame in 240:
		unit._process(1.0 / 60.0)
		if not fired_batches.is_empty():
			break
	_expect(fired_batches.size() == 1, "an aimed in-range order must fire the compatible weapon")
	if not fired_batches.is_empty():
		_expect(fired_batches[0]["target"] == target, "the fired batch must retain the ordered target")
		_expect(fired_batches[0]["weapon_index"] == 0, "the primary APC weapon must execute the order")

	unit.cancel_attack_order()
	var far_ground := Vector3(emission["position"]) + direction * 30.0
	_expect(unit.command_attack(far_ground), "attack-ground validity must not depend on current range")
	unit._process(0.01)
	var original_distance := Vector2(
		far_ground.x - unit.global_position.x,
		far_ground.z - unit.global_position.z
	).length()
	var pursuit_distance := Vector2(
		far_ground.x - unit.target_position.x,
		far_ground.z - unit.target_position.z
	).length()
	_expect(
		pursuit_distance > 0.0 and pursuit_distance < original_distance,
		"an out-of-range attack order must pursue a firing position before its target"
	)
	unit.move_to(unit.global_position + Vector3.RIGHT)
	_expect(not unit.has_attack_order(), "a later ordinary movement order must cancel attack")

	var mongoose = UnitScene.instantiate()
	mongoose.config_id = &"ATMongoose"
	root.add_child(mongoose)
	mongoose.replace_visual_scene(ATMongooseModelScene)
	var mongoose_emission: Dictionary = mongoose.turret_emission_points()[0]
	var mongoose_forward: Vector3 = Vector3(mongoose_emission["direction"])
	mongoose_forward.y = 0.0
	var mongoose_side := mongoose_forward.normalized().rotated(Vector3.UP, PI * 0.5)
	unit.global_position = mongoose.global_position + mongoose_side * 25.0
	_expect(
		unit.combat_aim_position().y > unit.global_position.y,
		"a real unit target must expose an aim point inside its body rather than at ground level"
	)
	var mongoose_fired: Array = []
	mongoose.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		mongoose_fired.append_array(projectiles)
	)
	_expect(mongoose.command_attack(unit), "a Mongoose must accept a real allied ground unit as a forced target")
	_expect(
		mongoose.combat_turrets[0].target_range(unit) == CombatTurretScript.TargetRange.TOO_FAR,
		"the real-unit regression must begin outside the Mongoose weapon range"
	)
	for frame in 240:
		mongoose._process(1.0 / 60.0)
		mongoose._physics_process(1.0 / 60.0)
		if not mongoose_fired.is_empty():
			break
	_expect(
		not mongoose_fired.is_empty(),
		"a pursuing Mongoose must stop at range and fire its yaw-only turret at a real unit"
	)
	var mongoose_player := mongoose.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	var mongoose_fire_overlay := mongoose.combat()._fire_overlay.player_for(0) \
		as AnimationPlayer
	_expect(
		mongoose_player != null
		and mongoose_fire_overlay != null
		and mongoose_fire_overlay.current_animation == &"Fire_0",
		"the Mongoose shot must occur inside its turret-local Fire_0 overlay"
	)
	_expect(
		mongoose.combat_turrets[0].reload_ticks_remaining > 0.0
		and mongoose.combat_turrets[0].reload_ticks_remaining < 30.0,
		"Mongoose ReloadCount must advance alongside Fire_0"
	)
	var mongoose_refire_elapsed := 0.0
	for frame in 60:
		mongoose._process(1.0 / 60.0)
		mongoose_refire_elapsed += 1.0 / 60.0
	_expect(
		mongoose_fired.size() == 1,
		"the Mongoose must not fire again while its first Fire_0 animation is active"
	)
	for frame in 60:
		mongoose._process(1.0 / 60.0)
		mongoose_refire_elapsed += 1.0 / 60.0
		if mongoose_fired.size() >= 2:
			break
	_expect(
		mongoose_fired.size() == 2
		and absf(mongoose_refire_elapsed - 30.0 / UnitScript.RULE_COMBAT_TICKS_PER_SECOND) \
			<= 1.0 / 30.0,
		"Mongoose shots must be separated by ReloadCount, not Fire_0 plus ReloadCount"
	)

	var infantry = UnitScene.instantiate()
	infantry.config_id = &"ATInfantry"
	root.add_child(infantry)
	infantry.replace_visual_scene(ATInfantryModelScene)
	var infantry_emission: Dictionary = infantry.turret_emission_points()[0]
	var infantry_forward: Vector3 = Vector3(infantry_emission["direction"])
	var infantry_target: Vector3 = Vector3(infantry_emission["position"]) \
		+ infantry_forward.normalized() * 5.0
	var infantry_fired: Array = []
	infantry.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		infantry_fired.append_array(projectiles)
	)
	_expect(
		infantry.command_attack(infantry_target),
		"Atreides Infantry must accept an in-range ground target"
	)
	for frame in 240:
		infantry._process(1.0 / 60.0)
		if not infantry_fired.is_empty():
			break
	_expect(not infantry_fired.is_empty(), "Atreides Infantry must emit its authored shot")
	_expect(
		infantry.combat_turrets[0].has_authored_fire_fx(),
		"Fire_0 must start its casing timeline even with an embedded muzzle flash"
	)
	_expect(
		is_zero_approx(infantry.combat_turrets[0].reload_ticks_remaining),
		"infantry ReloadCount must remain deferred during its full-body Fire_0 action"
	)
	var infantry_refire_elapsed := 0.0
	for frame in 240:
		infantry._process(1.0 / 60.0)
		infantry_refire_elapsed += 1.0 / 60.0
		if not infantry._fire_sequence_active:
			break
	_expect(
		is_equal_approx(infantry.combat_turrets[0].reload_ticks_remaining, 30.0),
		"infantry ReloadCount must begin after its full-body Fire_0 action"
	)
	for frame in 120:
		infantry._process(1.0 / 60.0)
		infantry_refire_elapsed += 1.0 / 60.0
		if infantry_fired.size() >= 2:
			break
	_expect(
		infantry_fired.size() == 2
		and absf(
			infantry_refire_elapsed
			- (45.0 + 30.0) / UnitScript.RULE_COMBAT_TICKS_PER_SECOND
		) <= 1.0 / 30.0,
		"Atreides Infantry shots must combine its 45-frame action and 30-tick reload"
	)

	var minotaurus = UnitScene.instantiate()
	minotaurus.config_id = &"ATMinotaurus"
	root.add_child(minotaurus)
	minotaurus.replace_visual_scene(ATMinotaurusModelScene)
	var minotaurus_emission: Dictionary = minotaurus.turret_emission_points()[0]
	var minotaurus_forward: Vector3 = Vector3(minotaurus_emission["direction"])
	minotaurus_forward.y = 0.0
	unit.global_position = minotaurus.global_position \
		+ minotaurus_forward.normalized().rotated(Vector3.UP, deg_to_rad(30.0)) * 10.0
	var minotaurus_fired: Array = []
	var minotaurus_fire_animations: Array[StringName] = []
	var minotaurus_player := minotaurus.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	minotaurus.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		minotaurus_fired.append_array(projectiles)
		minotaurus_fire_animations.append(minotaurus_player.current_animation)
	)
	_expect(
		minotaurus.command_attack(unit),
		"a Minotaurus must accept a real allied ground unit as a forced target"
	)
	for frame in 240:
		minotaurus._process(1.0 / 60.0)
		if not minotaurus_fired.is_empty():
			break
	_expect(
		absf(minotaurus.combat_turrets[0].current_yaw_degrees()) > 1.0,
		"a Minotaurus attack order against a real unit must turn its compound turret"
	)
	_expect(
		not minotaurus_fired.is_empty(),
		"a compound Minotaurus turret must fire at a real unit after completing its aim"
	)
	var minotaurus_visible_yaw := rad_to_deg(Assertions.horizontal_angle_between(
		minotaurus_forward,
		Vector3(minotaurus.combat_turrets[0].peek_emission()["direction"])
	))
	_expect(
		absf(minotaurus_visible_yaw - absf(
			minotaurus.combat_turrets[0].current_yaw_degrees()
		)) < 0.1,
		"starting Fire_0 must preserve the Minotaurus visual turret yaw"
	)
	_expect(
		minotaurus.combat_turrets[0].reload_ticks_remaining > 0.0
		and minotaurus.combat_turrets[0].reload_ticks_remaining < 120.0,
		"Minotaurus ReloadCount must advance during its four-shot Fire_0 animation"
	)
	for frame in 120:
		minotaurus._process(1.0 / 60.0)
		if not minotaurus._fire_sequence_active:
			break
	_expect(
		minotaurus_fired.size() == 4,
		"the Minotaurus Fire_0 animation must emit one shell from each of its four muzzles"
	)
	_expect(
		minotaurus_fire_animations == [&"Fire_0", &"Fire_0", &"Fire_0", &"Fire_0"],
		"all four Minotaurus shells must belong to one authored firing animation"
	)
	_expect(
		absf(
			minotaurus.combat_turrets[0].reload_ticks_remaining
			- (120.0 - minotaurus_player.get_animation(&"Fire_0").length \
				* UnitScript.BAKED_MODEL_FRAMES_PER_SECOND)
		) <= 0.5,
		"the Minotaurus salvo animation must consume the matching part of ReloadCount"
	)
	minotaurus_visible_yaw = rad_to_deg(Assertions.horizontal_angle_between(
		minotaurus_forward,
		Vector3(minotaurus.combat_turrets[0].peek_emission()["direction"])
	))
	_expect(
		absf(minotaurus_visible_yaw - absf(
			minotaurus.combat_turrets[0].current_yaw_degrees()
		)) < 0.1,
		"returning to Stationary after Fire_0 must preserve the Minotaurus visual turret yaw"
	)

	for batch in fired_batches:
		for projectile in batch["projectiles"]:
			if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
				projectile.free()
	for projectile in mongoose_fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	for projectile in infantry_fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	for projectile in minotaurus_fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	mongoose.free()
	infantry.free()
	minotaurus.free()
	unit.free()


func _test_ink_vine_refire() -> void:
	var ink_vine = UnitScene.instantiate()
	ink_vine.config_id = &"HKInkVine"
	root.add_child(ink_vine)
	ink_vine.replace_visual_scene(HKInkVineModelScene)
	var emission: Dictionary = ink_vine.turret_emission_points()[0]
	var forward: Vector3 = emission["direction"]
	forward.y = 0.0
	var target: Vector3 = ink_vine.global_position + forward.normalized() * 60.0
	target.y += 20.0
	var fired: Array = []
	ink_vine.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
	)

	_expect(ink_vine.command_attack(target), "the Ink Vine must accept an in-range target")
	for frame in 1200:
		ink_vine._process(1.0 / 60.0)
		ink_vine._physics_process(1.0 / 60.0)
		if fired.size() >= 2:
			break
	_expect(
		fired.size() >= 2,
		"the Ink Vine must fire again after ReloadCount without a new attack order"
	)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	ink_vine.free()


func _test_rejected_attack_perch() -> void:
	var ink_vine = UnitScene.instantiate()
	ink_vine.config_id = &"HKInkVine"
	root.add_child(ink_vine)
	ink_vine.replace_visual_scene(HKInkVineModelScene)
	var navigation := RejectingAttackNavigation.new()
	ink_vine.set_navigation_controller(navigation)
	ink_vine.set_navigation_managed(true)
	var emission: Dictionary = ink_vine.turret_emission_points()[0]
	var forward: Vector3 = emission["direction"]
	forward.y = 0.0
	var target: Vector3 = ink_vine.global_position + forward.normalized() * 60.0

	_expect(ink_vine.command_attack(target), "the Ink Vine must accept the distant ground point")
	for attempt in 3:
		ink_vine._process(0.3)
	_expect(
		navigation.destinations.size() == 3,
		"rejected firing positions must be retried instead of leaving pursuit inert"
	)
	if navigation.destinations.size() == 3:
		var first_distance: float = ink_vine.global_position.distance_to(
			navigation.destinations[0]
		)
		var second_distance: float = ink_vine.global_position.distance_to(
			navigation.destinations[1]
		)
		var third_distance: float = ink_vine.global_position.distance_to(
			navigation.destinations[2]
		)
		_expect(
			first_distance > second_distance and second_distance > third_distance,
			"each rejected perch must move back toward the unit's connected region"
		)
	ink_vine.free()








func _test_far_attack_pursuit() -> void:
	var attacker = UnitScene.instantiate()
	attacker.config_id = &"ATMinotaurus"
	root.add_child(attacker)
	attacker.replace_visual_scene(ATMinotaurusModelScene)
	var target = UnitScene.instantiate()
	target.config_id = &"ATAPC"
	root.add_child(target)
	target.replace_visual_scene(ATAPCModelScene)
	var emission: Dictionary = attacker.combat_turrets[0].peek_emission()
	var forward: Vector3 = Vector3(emission["direction"])
	forward.y = 0.0
	target.global_position = attacker.global_position + forward.normalized() * 45.0

	var fired: Array = []
	attacker.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		fired.append_array(projectiles)
	)
	_expect(
		attacker.combat_turrets[0].target_range(target)
			== CombatTurretScript.TargetRange.TOO_FAR,
		"the pursuit regression must begin beyond the Minotaurus maximum range"
	)
	_expect(attacker.command_attack(target), "the Minotaurus must accept the distant target")
	for frame in 1200:
		attacker._process(1.0 / 60.0)
		attacker._physics_process(1.0 / 60.0)
		if not fired.is_empty():
			break
	_expect(
		not fired.is_empty(),
		"a Minotaurus that pursued a distant target must eventually emit its salvo"
	)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	attacker.free()
	target.free()


func _test_obstructed_attack_order() -> void:
	var attacker = UnitScene.instantiate()
	attacker.config_id = &"ATAPC"
	root.add_child(attacker)
	attacker.replace_visual_scene(ATAPCModelScene)
	var target = UnitScene.instantiate()
	target.config_id = &"ATAPC"
	root.add_child(target)
	target.replace_visual_scene(ATAPCModelScene)
	var turret = attacker.combat_turrets[0]
	var forward: Vector3 = Vector3(turret.peek_emission()["direction"])
	forward.y = 0.0
	forward = forward.normalized()
	target.global_position = attacker.global_position + forward * 8.0
	var midpoint: Vector3 = attacker.global_position + forward * 4.0
	var cliff := PhysicsCliff.new(
		midpoint + Vector3.UP * 3.0, Vector3(12.0, 6.0, 1.0)
	)
	root.add_child(cliff)
	await physics_frame

	_expect(
		turret.target_range(target) == CombatTurretScript.TargetRange.IN_RANGE,
		"the obstruction regression must begin with the target inside weapon range"
	)
	_expect(
		not turret.has_line_of_fire(target, attacker),
		"a rock face between the muzzle and the target must break the line of fire"
	)

	var fired: Array = []
	attacker.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
	)
	_expect(attacker.command_attack(target), "the blocked target must still accept an order")
	for frame in 120:
		attacker._process(1.0 / 60.0)
	_expect(
		fired.is_empty(),
		"an in-range unit without a line of fire must not shoot into the obstacle"
	)
	_expect(
		attacker.has_attack_order(),
		"a blocked order must stay active while the unit looks for a firing position"
	)
	_expect(
		Vector2(
			attacker.target_position.x - attacker.global_position.x,
			attacker.target_position.z - attacker.global_position.z
		).length() > 0.0,
		"a blocked order must send the unit toward a position that can fire"
	)
	cliff.free()

	var wall := Doubles.PhysicsBuildingBlocker.new(midpoint, 2.5)
	root.add_child(wall)
	await physics_frame
	_expect(
		not turret.has_line_of_fire(target, attacker),
		"a building footprint between the muzzle and the target must break the line of fire"
	)
	wall.free()

	var passer_by := Doubles.PhysicsCombatTarget.new(midpoint, 2.5)
	root.add_child(passer_by)
	await physics_frame
	_expect(
		turret.has_line_of_fire(target, attacker),
		"another unit crossing the line must not obstruct the shot"
	)
	for frame in 240:
		attacker._process(1.0 / 60.0)
		if not fired.is_empty():
			break
	_expect(
		not fired.is_empty(),
		"a cleared line of fire must let the standing order execute from where it is"
	)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	passer_by.free()
	attacker.free()
	target.free()


func _test_building_edge_range() -> void:
	var model := ATInfantryModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATInfGun") and turret.bind_model(model, 0),
		"the range regression turret must bind its authored weapon"
	)
	var building = HKGunTurretScene.instantiate() as Building
	root.add_child(building)
	await process_frame
	_expect(
		building.combat_hull().size() >= 3
			and building.combat_hull().size() <= Building.MAX_COMBAT_HULL_VERTICES,
		"generated building combat hulls must retain a strict low vertex budget"
	)
	var combat_body := building.get_node_or_null("CombatCollision") as StaticBody3D
	_expect(
		combat_body != null
			and (combat_body.get_node("CombatHull") as CollisionShape3D).shape
				is ConcavePolygonShape3D,
		"the filtered building triangles must provide a concave projectile proxy"
	)
	var maximum_range := turret.maximum_range_world()
	building.global_position = Vector3(0.0, 0.0, maximum_range)
	var edge_allowance: float = building.global_position.z \
		- building.combat_range_distance_from(Vector3.ZERO)
	building.global_position.z = maximum_range + edge_allowance - 0.01
	_expect(
		turret.target_range(building) == CombatTurretScript.TargetRange.IN_RANGE,
		"a building whose near edge is inside maximum range must be attackable"
	)
	var edge_request := FireRequestScript.at(building, null, root)
	edge_request.begin_reload_after_shot = false
	edge_request.require_aim = false
	var edge_projectiles: Array = turret.try_fire_at(edge_request)
	_expect(
		edge_projectiles.size() == 1,
		"projectile launch must accept the same building-edge range"
	)
	for projectile in edge_projectiles:
		projectile.free()
	building.global_position.z += 0.02
	_expect(
		turret.target_range(building) == CombatTurretScript.TargetRange.TOO_FAR,
		"a building whose near edge is beyond maximum range must remain too far"
	)

	building.rotation.y = PI * 0.5
	building.global_position = Vector3(0.0, 0.0, maximum_range)
	var rotated_edge_allowance: float = building.global_position.z \
		- building.combat_range_distance_from(Vector3.ZERO)
	building.global_position.z = maximum_range + rotated_edge_allowance - 0.01
	_expect(
		turret.target_range(building) == CombatTurretScript.TargetRange.IN_RANGE,
		"rotated rectangular buildings must use the edge facing the attacker"
	)
	building.rotation.y = 0.0
	building.global_position = Vector3.ZERO
	model.global_position = Vector3(-maximum_range, 0.0, 0.0)
	var left_aim: Vector3 = turret._bullet_target_position(building)
	model.global_position = Vector3(maximum_range, 0.0, 0.0)
	var right_aim: Vector3 = turret._bullet_target_position(building)
	_expect(
		left_aim.x < right_aim.x,
		"attackers on opposite sides must aim at different facing building edges"
	)
	_expect(
		left_aim.distance_to(model.global_position)
			> right_aim.distance_to(model.global_position),
		"each attacker must receive the building point nearest to itself"
	)
	var collision_body := building.get_node("SelectionCollision") as StaticBody3D
	var bounds: AABB = collision_body.get_meta("collision_bounds")
	var face_left_x := bounds.get_center().x - bounds.size.x * 0.25
	var face_right_x := bounds.get_center().x + bounds.size.x * 0.25
	model.global_position = Vector3(
		face_left_x, 0.0, bounds.position.z - maximum_range
	)
	var same_face_left_aim: Vector3 = turret._bullet_target_position(building)
	model.global_position = Vector3(
		face_right_x, 0.0, bounds.position.z - maximum_range
	)
	var same_face_right_aim: Vector3 = turret._bullet_target_position(building)
	_expect(
		same_face_left_aim.x < same_face_right_aim.x
			and is_equal_approx(same_face_left_aim.z, same_face_right_aim.z),
		"attackers spread along one facade must aim at distinct points on it"
	)
	await physics_frame
	var missile_origin := Vector3(0.0, 1.0, maximum_range * 0.5)
	var missile_aim := building.combat_aim_position_from(missile_origin)
	_expect(
		is_equal_approx(missile_aim.y, missile_origin.y),
		"building aim height must follow a weapon inside the baked vertical range"
	)
	var missile = CombatProjectileScript.new()
	root.add_child(missile)
	building.owner_player_id = 1
	var trooper_source := Doubles.CombatSource.new()
	trooper_source.owner_player_id = 1
	var missile_bullet = _bullets.runtime_bullet(&"HEATInf_B")
	var building_durability_before: float = building.health + building.shields
	var explosion_positions: Array[Vector3] = []
	var impact_damage: Array[float] = []
	missile.impacted.connect(
		func(target: Object, damage: float, _position: Vector3) -> void:
			if target == building:
				impact_damage.append(damage)
	)
	missile.explosion_requested.connect(
		func(_type: StringName, _effects: Array, position: Vector3) -> void:
			explosion_positions.append(position)
	)
	_expect(
		missile.launch(
			missile_bullet,
			{
				"position": missile_origin,
				"direction": missile_origin.direction_to(missile_aim),
			},
			building,
			trooper_source,
			1.0,
			Vector3.ZERO,
			missile_origin
		),
		"the building collision regression missile must launch"
	)
	var previous_missile_position: Vector3 = missile.global_position
	for frame in 600:
		previous_missile_position = missile.global_position
		missile.advance(1.0 / 60.0)
		if missile.is_finished():
			break
	_expect(
		missile.finish_reason == &"impact_target"
			and explosion_positions.size() == 1
			and missile.global_position.is_equal_approx(explosion_positions[0]),
		"the missile and its explosion must finish at the same hull impact"
	)
	_expect(
		not impact_damage.is_empty() and impact_damage[0] > 0.0
			and building.health + building.shields < building_durability_before,
		"a friendly HKTrooper missile forced onto a combat hull must damage "
			+ "its parent building as the direct target"
	)
	_expect(
		previous_missile_position.distance_to(missile.global_position)
			<= missile_bullet.speed() / 60.0 + 0.001,
		"precise building collision must not teleport the missile to its explosion"
	)
	if is_instance_valid(missile):
		missile.free()
	building.free()
	model.free()


func _test_hktrooper_building_damage() -> void:
	var trooper = UnitScene.instantiate()
	trooper.config_id = &"HKTrooper"
	trooper.owner_player_id = 1
	root.add_child(trooper)
	trooper.replace_visual_scene(HKTrooperModelScene)
	var building = HKGunTurretScene.instantiate() as Building
	building.owner_player_id = 1
	root.add_child(building)
	await process_frame

	var emission: Dictionary = trooper.combat_turrets[0].peek_emission()
	var forward: Vector3 = Vector3(emission["direction"])
	forward.y = 0.0
	building.global_position = trooper.global_position \
		+ forward.normalized() * 4.0
	var durability_before: float = building.health + building.shields
	var fired: Array = []
	trooper.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
	)
	_expect(
		trooper.command_attack(building),
		"a real HKTrooper must accept a forced attack on its friendly building"
	)
	for frame in 240:
		trooper._process(1.0 / 60.0)
		trooper._physics_process(1.0 / 60.0)
		if not fired.is_empty():
			break
	_expect(
		fired.size() == 1,
		"the HKTrooper Fire animation must emit one HEATInf_B missile"
	)
	if not fired.is_empty():
		var missile = fired[0]
		for frame in 600:
			missile.advance(1.0 / 60.0)
			if missile.is_finished():
				break
		_expect(
			missile.finish_reason == &"impact_target",
			"the HKTrooper missile must identify the combat hull as its target"
		)
		_expect(
			is_equal_approx(
				durability_before - (building.health + building.shields),
				375.0
			),
			"HEATInf_B must deal its rules-backed 375 damage to HKGunTurret"
		)
		if is_instance_valid(missile):
			missile.free()

	var ground_first_missile = CombatProjectileScript.new()
	root.add_child(ground_first_missile)
	var ground_first_bullet = _bullets.runtime_bullet(&"HEATInf_B")
	var ground_first_origin := building.combat_aim_position_from(
		trooper.global_position
	) + forward.normalized() * 2.0
	var ground_first_durability: float = building.health + building.shields
	_expect(
		ground_first_missile.launch(
			ground_first_bullet,
			{
				"position": ground_first_origin,
				"direction": ground_first_origin.direction_to(
					building.global_position
				),
			},
			building,
			trooper,
			1.0,
			Vector3.ZERO,
			ground_first_origin
		),
		"the ground-first HKTrooper regression missile must launch"
	)
	ground_first_missile._impact_ground(building.global_position)
	_expect(
		ground_first_missile.finish_reason == &"impact_target"
			and is_equal_approx(
				ground_first_durability
					- (building.health + building.shields),
				375.0
			),
		"terrain contact inside the designated friendly building hull must "
			+ "remain a direct hit rather than zero-damage friendly splash"
	)
	if is_instance_valid(ground_first_missile):
		ground_first_missile.free()
	building.free()
	trooper.free()
	await physics_frame


func _test_hkstarport_courtyard_collision() -> void:
	var building = HKStarportScene.instantiate() as Building
	root.add_child(building)
	await physics_frame
	var origin := building.to_global(Vector3(0.0, 1.0, 0.0))
	var destination := building.to_global(Vector3(0.0, 0.0, 10.0))
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_bullets.runtime_bullet(&"HEATInf_B"),
			{
				"position": origin,
				"direction": origin.direction_to(destination),
			},
			destination
		),
		"the HKStarport courtyard regression missile must launch"
	)
	projectile.advance(1.0 / 60.0)
	_expect(
		projectile.state == CombatProjectileScript.State.FLYING
			and projectile.global_position.distance_to(origin) > 0.1,
		"a projectile launched inside HKStarport must cross empty courtyard "
			+ "space instead of hitting a filled convex volume"
	)
	if is_instance_valid(projectile):
		projectile.free()
	building.free()
	await physics_frame


func _test_building_turret_rebind() -> void:
	var building = HKGunTurretScene.instantiate()
	root.add_child(building)
	_expect(building.combat_turrets.size() == 1, "HKGunTurret must create one runtime turret")
	var idle_emission: Dictionary = building.next_turret_emission()
	_expect(not idle_emission.is_empty(), "the idle building state must expose its >>0 muzzle")
	_expect(
		String((idle_emission.get("node") as Node).get_path()).contains("/Idle/"),
		"the turret must bind the visible Idle model copy"
	)
	building.play_state(&"damage1")
	var damage_emission: Dictionary = building.next_turret_emission()
	_expect(not damage_emission.is_empty(), "the damage state must retain a muzzle")
	_expect(
		String((damage_emission.get("node") as Node).get_path()).contains("/Damage1/"),
		"state changes must rebind the turret to the visible Damage1 copy"
	)
	var projectiles: Array = building.fire_weapon_at(
		Vector3(damage_emission["position"]) + Vector3(damage_emission["direction"]) * 5.0,
		0,
		root
	)
	_expect(projectiles.size() == 1, "Building must launch from the active damage-state muzzle")
	if not projectiles.is_empty():
		_expect(projectiles[0].bullet.id() == &"HKGunTurret_B", "the building API must use its rules bullet")
		projectiles[0].free()
	building.free()


func _test_defensive_building_auto_fire() -> void:
	var cases := {
		&"HKFlameTurret": &"FlameTurret_B",
		&"TLTurret": &"HKGunTurret_B",
		&"HKGunTurret": &"HKGunTurret_B",
		&"ORGasTurret": &"Gas_B",
		&"ORPopUpTurret": &"PopUp_B",
		&"ATPillbox": &"HMG_B",
		&"ATRocketTurret": &"Rocket_B",
	}
	for building_id: StringName in cases:
		var scene_path := (
			"res://assets/converted/buildings/%s/%s.scn"
			% [String(building_id), String(building_id)]
		)
		var scene := load(scene_path) as PackedScene
		var building := scene.instantiate() as Building
		building.owner_player_id = 1
		root.add_child(building)
		var emission: Dictionary = building.combat_turrets[0].peek_emission()
		var direction: Vector3 = emission.get("direction", Vector3.BACK)
		var target_position := Vector3(emission["position"]) \
			+ direction.normalized() * 5.0
		var target := Doubles.PhysicsCombatTarget.new(target_position)
		target.owner_player_id = 2
		target.add_to_group(&"units")
		root.add_child(target)
		var fired: Array = []
		building.weapon_fired.connect(
			func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
				fired.append_array(projectiles)
		)
		for frame in 900:
			building._process(1.0 / 60.0)
			if not fired.is_empty():
				break
		_expect(
			not fired.is_empty(),
			"%s must acquire a nearby enemy and fire" % String(building_id)
		)
		if not fired.is_empty():
			_expect(
				fired[0].bullet.id() == cases[building_id],
				"%s must fire %s from its rules turret"
					% [String(building_id), String(cases[building_id])]
			)
		for projectile in fired:
			if is_instance_valid(projectile) \
			and not projectile.is_queued_for_deletion():
				projectile.free()
		target.free()
		building.free()


func _test_defensive_building_visible_aim() -> void:
	var scene := load(
		"res://assets/converted/buildings/ATRocketTurret/ATRocketTurret.scn"
	) as PackedScene
	var building := scene.instantiate() as Building
	building.owner_player_id = 1
	root.add_child(building)
	await process_frame
	var turret = building.combat_turrets[0]
	var initial_emission: Dictionary = turret.peek_emission()
	var initial_direction: Vector3 = initial_emission["direction"]
	var side := initial_direction.rotated(Vector3.UP, PI * 0.5).normalized()
	var target_position := Vector3(initial_emission["position"]) + side * 8.0
	_expect(
		building.command_attack(target_position),
		"ATRocketTurret must accept a lateral ground target"
	)
	for frame in 60:
		await process_frame
		if absf(turret.current_yaw_degrees()) >= 35.0:
			break
	var visible_direction: Vector3 = turret.peek_emission()["direction"]
	_expect(
		absf(turret.current_yaw_degrees()) >= 35.0,
		"ATRocketTurret must advance its logical yaw toward a lateral target"
	)
	_expect(
		Assertions.horizontal_angle_between(initial_direction, visible_direction)
			>= deg_to_rad(30.0),
		"ATRocketTurret's visible authored pivot must follow its logical yaw"
	)
	building.cancel_attack_order()
	building.free()
	await process_frame


## Regression test for a reported bug: ATRocketTurret's four >>N muzzle
## markers are numbered by export order, not by which barrel the baked Fire_0
## animation actually opens at a given moment (see AuthoredFireController's
## type-10 event `value` handling). A plain round-robin over emission_points()
## fires the markers in numeric order — two "top" barrels, then two "bottom"
## barrels — even though the animation visibly recoils a "left" pair, then a
## "right" pair. Each projectile must spawn from the muzzle the authored shot
## schedule actually names, not from the round-robin's own counter.
func _test_atrocket_turret_muzzle_matches_authored_animation() -> void:
	var scene := load(
		"res://assets/converted/buildings/ATRocketTurret/ATRocketTurret.scn"
	) as PackedScene
	var building := scene.instantiate() as Building
	building.owner_player_id = 1
	root.add_child(building)
	var turret = building.combat_turrets[0]
	var controller = building._authored_fire_controller
	var binding: Dictionary = controller._fire_animation_binding()
	_expect(
		not binding.is_empty(), "ATRocketTurret must have an authored Fire clip"
	)
	if binding.is_empty():
		building.free()
		return
	var player: AnimationPlayer = binding["player"]
	var animation_name: StringName = binding["name"]
	var animation: Animation = player.get_animation(animation_name)
	var shot_times: Array[Dictionary] = controller._authored_fire_shot_times(
		player, animation, animation_name
	)
	_expect(
		shot_times.size() == turret.muzzle_count(),
		"ATRocketTurret must schedule one shot per muzzle marker"
	)
	var known_muzzles := shot_times.filter(func(shot: Dictionary) -> bool:
		return int(shot.get("muzzle", -1)) >= 0
	)
	_expect(
		known_muzzles.size() == shot_times.size(),
		"ATRocketTurret's authored Fire_0 clip must name a real muzzle for every shot"
	)
	var initial_emission: Dictionary = turret.peek_emission()
	var direction: Vector3 = initial_emission.get("direction", Vector3.BACK)
	var target_position := Vector3(initial_emission["position"]) \
		+ direction.normalized() * 5.0
	var target := Doubles.PhysicsCombatTarget.new(target_position)
	target.owner_player_id = 2
	target.add_to_group(&"units")
	root.add_child(target)
	var fired: Array = []
	# The muzzle markers themselves animate (barrel recoil), so their world
	# position at fire time differs from their rest pose. Read which physical
	# muzzle index the turret actually used for each shot from its own
	# last_emissions() right as weapon_fired reports it, instead of comparing
	# spawn positions against a stale pre-animation snapshot.
	var fired_muzzles: Array[int] = []
	building.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
			for emission: Dictionary in turret.last_emissions():
				fired_muzzles.append(int(emission.get("index", -1)))
	)
	for frame in 900:
		building._process(1.0 / 60.0)
		if fired.size() >= shot_times.size():
			break
	_expect(
		fired.size() == shot_times.size(),
		"ATRocketTurret must fire exactly one projectile per scheduled authored shot"
	)
	for shot_index in mini(fired_muzzles.size(), shot_times.size()):
		var expected_muzzle := int(shot_times[shot_index].get("muzzle", -1))
		if expected_muzzle < 0:
			continue
		_expect(
			fired_muzzles[shot_index] == expected_muzzle,
			(
				"ATRocketTurret shot %d must fire from the authored muzzle %d "
				+ "its Fire_0 clip names (fired from %d instead), not the "
				+ "round-robin's own muzzle"
			) % [shot_index, expected_muzzle, fired_muzzles[shot_index]]
		)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	target.free()
	building.free()


## Regression test for a reported bug: a Stop order during an ATPillbox or
## HKGunTurret burst left the authored muzzle flash frozen at whatever size the
## cancelled Fire clip had reached (both models scale their `_bigflash*` nodes
## by more than an order of magnitude mid-clip). Nothing rewrites those nodes
## afterwards -- a stationary defensive building runs no idle clip on its model
## player -- so the flash stayed on the barrels and swung around with the
## turret. Cancelling must leave the same pose a completed burst leaves.
func _test_defensive_turret_stop_clears_muzzle_flash() -> void:
	for building_id in [&"ATPillbox", &"HKGunTurret"]:
		var scene_path := (
			"res://assets/converted/buildings/%s/%s.scn"
			% [String(building_id), String(building_id)]
		)
		var scene := load(scene_path) as PackedScene
		var building := scene.instantiate() as Building
		building.owner_player_id = 1
		root.add_child(building)
		var flashes := _authored_flash_nodes(building)
		_expect(
			not flashes.is_empty(),
			"%s must expose authored bigflash nodes" % String(building_id)
		)
		if flashes.is_empty():
			building.free()
			continue
		var rest_scales: Array[Vector3] = []
		for flash in flashes:
			rest_scales.append(flash.scale)

		var turret = building.combat_turrets[0]
		var emission: Dictionary = turret.peek_emission()
		var direction: Vector3 = emission.get("direction", Vector3.BACK)
		var target := Doubles.PhysicsCombatTarget.new(
			Vector3(emission["position"]) + direction.normalized() * 5.0
		)
		target.owner_player_id = 2
		target.add_to_group(&"units")
		root.add_child(target)
		var fired: Array = []
		building.weapon_fired.connect(
			func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
				fired.append_array(projectiles)
		)
		_expect(
			building.command_attack(target),
			"%s must accept an explicit attack order" % String(building_id)
		)

		# The AnimationPlayer is driven explicitly so the burst is caught at a
		# reproducible point: awaiting real frames would leave where the flash
		# happens to be at cancellation up to the headless frame rate.
		var controller = building._authored_fire_controller
		var flash_grew := false
		for frame in 900:
			building._process(1.0 / 60.0)
			if not controller.is_active():
				continue
			for weapon_index: Variant in controller._sequences:
				var state: Dictionary = controller._sequences[weapon_index]
				var player := state["player"] as AnimationPlayer
				player.advance(1.0 / 60.0)
			flash_grew = _flash_departed_from_rest(flashes, rest_scales)
			if flash_grew:
				break
		_expect(
			flash_grew,
			"%s must visibly scale an authored muzzle flash mid-burst"
				% String(building_id)
		)

		building.cancel_all_orders()
		_expect(
			not _flash_departed_from_rest(flashes, rest_scales),
			(
				"%s must return its authored muzzle flash to rest when a burst "
				+ "is stopped, not freeze it mid-flash"
			) % String(building_id)
		)

		for projectile in fired:
			if is_instance_valid(projectile) \
			and not projectile.is_queued_for_deletion():
				projectile.free()
		target.free()
		building.free()


func _authored_flash_nodes(building) -> Array[Node3D]:
	var result: Array[Node3D] = []
	var state_root: Node3D = building.state_root(building.current_state)
	if state_root == null:
		return result
	for node in state_root.find_children("*bigflash*", "Node3D", true, false):
		result.append(node as Node3D)
	return result


func _flash_departed_from_rest(
	flashes: Array[Node3D], rest_scales: Array[Vector3]
	) -> bool:
	for index in flashes.size():
		if not flashes[index].scale.is_equal_approx(rest_scales[index]):
			return true
	return false


func _test_ordos_popup_turret_animations() -> void:
	for building_id in [&"ORGasTurret", &"ORPopUpTurret"]:
		var scene_path := (
			"res://assets/converted/buildings/%s/%s.scn"
			% [String(building_id), String(building_id)]
		)
		var scene := load(scene_path) as PackedScene
		var building := scene.instantiate() as Building
		building.owner_player_id = 1
		root.add_child(building)
		await process_frame
		var turret = building.combat_turrets[0]
		var player := building._active_model_animation_player(&"Deploy_Gun")
		var initial_emission: Dictionary = turret.peek_emission()
		var initial_position: Vector3 = initial_emission["position"]
		var initial_direction: Vector3 = initial_emission["direction"]
		var side := initial_direction.rotated(Vector3.UP, PI * 0.5).normalized()
		var target_position := initial_position + side * 8.0
		var saw_deploy := false
		var deploy_motion := 0.0
		_expect(
			building.command_attack(target_position),
			"%s must accept a target that triggers popup deployment"
				% String(building_id)
		)
		for frame in 90:
			await process_frame
			saw_deploy = saw_deploy \
				or player.current_animation == &"Deploy_Gun"
			deploy_motion = maxf(
				deploy_motion,
				Vector3(turret.peek_emission()["position"]).distance_to(
					initial_position
				)
			)
			if building._popup_turret_state == 2:
				break
		_expect(
			saw_deploy,
			"%s must play Deploy_Gun before aiming" % String(building_id)
		)
		_expect(
			deploy_motion > 0.5,
			"%s Deploy_Gun must visibly move its authored model"
				% String(building_id)
		)
		_expect(
			building._popup_turret_state == 2,
			"%s must settle in its deployed hold state" % String(building_id)
		)

		building.cancel_attack_order()
		var saw_undeploy := false
		for frame in 120:
			await process_frame
			saw_undeploy = saw_undeploy \
				or player.current_animation == &"Undeploy_Gun"
			if saw_undeploy and building._popup_turret_state == 0:
				break
		_expect(
			saw_undeploy,
			"%s must play Undeploy_Gun after losing its target"
				% String(building_id)
		)
		_expect(
			building._popup_turret_state == 0,
			"%s must return to its retracted state" % String(building_id)
		)
		building.free()
		await process_frame


func _test_building_attack_order() -> void:
	var building := HKGunTurretScene.instantiate() as Building
	building.owner_player_id = 1
	root.add_child(building)
	var emission: Dictionary = building.combat_turrets[0].peek_emission()
	var direction: Vector3 = Vector3(
		emission.get("direction", Vector3.BACK)
	).normalized()
	var target := Doubles.PhysicsCombatTarget.new(
		Vector3(emission["position"]) + direction * 100.0
	)
	target.owner_player_id = 2
	target.add_to_group(&"units")
	root.add_child(target)
	var fired: Array = []
	building.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
	)
	_expect(
		building.command_attack(target),
		"an armed building must accept a compatible target outside its range"
	)
	for frame in 120:
		building._process(1.0 / 60.0)
	_expect(
		fired.is_empty() and building.has_attack_order(),
		"the immobile building must retain, but not fire at, its distant target"
	)
	target.global_position = Vector3(emission["position"]) + direction * 5.0
	for frame in 600:
		building._process(1.0 / 60.0)
		if not fired.is_empty():
			break
	_expect(
		not fired.is_empty() and building.attack_order_target() == target,
		"the retained building order must fire when its target enters range"
	)
	_expect(
		building.cancel_all_orders() and not building.has_active_order(),
		"Stop must cancel a real building's explicit attack order"
	)
	_expect(
		not building.cancel_all_orders(),
		"Stop must ignore a building that no longer has an explicit attack order"
	)
	for projectile in fired:
		if is_instance_valid(projectile) \
		and not projectile.is_queued_for_deletion():
			projectile.free()
	target.free()
	building.free()


func _test_building_obstructed_targets() -> void:
	var building := HKGunTurretScene.instantiate() as Building
	building.owner_player_id = 1
	root.add_child(building)
	await process_frame
	var turret = building.combat_turrets[0]
	var emission: Dictionary = turret.peek_emission()
	var muzzle: Vector3 = Vector3(emission["position"])
	var direction: Vector3 = Vector3(emission.get("direction", Vector3.BACK))
	direction.y = 0.0
	direction = direction.normalized()
	var side := direction.rotated(Vector3.UP, PI * 0.5)

	var covered := Doubles.PhysicsCombatTarget.new(muzzle + direction * 8.0)
	covered.owner_player_id = 2
	covered.add_to_group(&"units")
	root.add_child(covered)
	var exposed := Doubles.PhysicsCombatTarget.new(muzzle + side * 8.0)
	exposed.owner_player_id = 2
	exposed.add_to_group(&"units")
	root.add_child(exposed)
	var obstacle := Doubles.PhysicsBuildingBlocker.new(muzzle + direction * 4.0, 2.5)
	obstacle.owner_player_id = 1
	root.add_child(obstacle)
	await physics_frame

	_expect(
		turret.target_range(covered) == CombatTurretScript.TargetRange.IN_RANGE
		and turret.target_range(exposed) == CombatTurretScript.TargetRange.IN_RANGE,
		"both regression targets must stand inside the turret's weapon range"
	)
	_expect(
		not turret.has_line_of_fire(covered, building),
		"a building standing in front of the target must break the turret's line of fire"
	)
	_expect(
		turret.has_line_of_fire(exposed, building),
		"the target beside the obstacle must remain reachable"
	)

	var fired: Array = []
	var fired_targets: Array = []
	building.weapon_fired.connect(
		func(projectiles: Array, fired_target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
			fired_targets.append(fired_target)
	)
	_expect(
		building.command_attack(covered),
		"a building must accept an order on a target it cannot currently see"
	)
	for frame in 600:
		building._process(1.0 / 60.0)
		if not fired.is_empty():
			break
	_expect(
		not fired_targets.is_empty()
		and fired_targets.all(func(target: Variant) -> bool: return target == exposed),
		"a shielded target must never be shot at: the turret serves the reachable enemy"
	)
	_expect(
		is_zero_approx(obstacle.damage_taken),
		"the building in the way must not absorb the turret's shots"
	)
	_expect(
		building.has_attack_order() and building.attack_order_target() == covered,
		"the blocked order must stay attached in case the obstacle falls"
	)

	obstacle.free()
	await physics_frame
	fired_targets.clear()
	# The committed authored Fire clip finishes on the target it started with;
	# the ordered target takes over on the first shot chosen afterwards.
	for frame in 600:
		building._process(1.0 / 60.0)
	_expect(
		not fired_targets.is_empty() and fired_targets.back() == covered,
		"once the obstacle is gone the retained order must take the weapon back"
	)

	for projectile in fired:
		if is_instance_valid(projectile) \
		and not projectile.is_queued_for_deletion():
			projectile.free()
	covered.free()
	exposed.free()
	building.free()


func _test_building_damage_visual_states() -> void:
	var turret = HKGunTurretScene.instantiate() as Building
	root.add_child(turret)
	_expect(turret.current_state == &"idle", "a healthy building must use Idle")
	turret.health = turret.max_health * (2.0 / 3.0)
	_expect(turret.current_state == &"damage1", "the second of three equal health bands must use Damage1")
	turret.health = turret.max_health * (1.0 / 3.0)
	_expect(turret.current_state == &"damage2", "the final health band must use Damage2")
	turret.health = turret.max_health
	_expect(turret.current_state == &"idle", "restoring full health must return to Idle")
	turret.free()

	var wall = ATWallScene.instantiate() as Building
	root.add_child(wall)
	_expect(wall.get_node_or_null("States/Damage1") == null, "fixture must cover a missing Damage1 state")
	wall.health = wall.max_health * 0.5
	_expect(
		wall.current_state == &"damage2",
		"a sole Damage2 state must be the damaged band rather than requiring Damage1"
	)
	wall.free()






func _test_deviate_hit_impact_fx() -> void:
	Fx.free_impact_effects(root)
	var bullet = _bullets.bullet_with_impact_scenes(&"Deviate_B")
	var launch_position := Vector3(0.0, 1.0, 0.0)
	var ground_position := Vector3(0.0, 0.0, -6.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(bullet, Bullets.emission(launch_position, Vector3.FORWARD), ground_position),
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
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(bullet, Bullets.emission(launch_position, Vector3.FORWARD), ground_position),
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
		splat_offsets.size() == ImpactDebris.DEV_IMPACT_COUNT,
		"DevImpact must spawn its whole authored cloud, not one billboard"
	)
	# The cloud must cover the circle without being a regular polygon: every
	# puff sits in its own angular slot, jittered inside it, at a radius that
	# varies by no more than the authored fraction.
	var angular_step := TAU / float(ImpactDebris.DEV_IMPACT_COUNT)
	var covers_circle := not splat_offsets.is_empty()
	var any_uneven := false
	for offset_index in splat_offsets.size():
		var offset := splat_offsets[offset_index]
		var neighbour := splat_offsets[(offset_index + 1) % splat_offsets.size()]
		var radius_ratio := offset.length() / ImpactDebris.DEV_IMPACT_RADIUS
		var gap := angle_difference(
			atan2(offset.x, offset.z), atan2(neighbour.x, neighbour.z)
		)
		covers_circle = covers_circle \
			and is_zero_approx(offset.y) \
			and absf(radius_ratio - 1.0) <= ImpactDebris.DEV_IMPACT_RADIUS_JITTER \
			and gap > 0.0 \
			and gap <= angular_step * (1.0 + 2.0 * ImpactDebris.DEV_IMPACT_ANGLE_JITTER)
		any_uneven = any_uneven or not is_equal_approx(gap, angular_step)
	_expect(
		covers_circle and any_uneven,
		"DevImpact's puffs must fill the circle unevenly, not as a regular polygon"
	)
	# Fast out of the impact, then a visible coast to a stop.
	_expect(
		ImpactDebris._eased_spray_progress(0.25) > 0.6
		and ImpactDebris._eased_spray_progress(0.5) > 0.9
		and ImpactDebris._eased_spray_progress(1.0) >= 1.0,
		"DevImpact's throw must front-load its travel and decelerate to a halt"
	)
	var first_puff := particle_nodes.front() as Node3D if not particle_nodes.is_empty() else null
	var puff_scale_early := first_puff.scale.x if first_puff != null else 0.0
	await create_timer(ImpactDebris.DEV_IMPACT_DURATION * 0.5).timeout
	var puff_scale_late := first_puff.scale.x \
		if first_puff != null and is_instance_valid(first_puff) else 0.0
	_expect(
		ImpactDebris.DEV_IMPACT_SCALE_START < ImpactDebris.DEV_IMPACT_SCALE_END
		and puff_scale_early >= ImpactDebris.DEV_IMPACT_SCALE_START
		and puff_scale_late > puff_scale_early
		and puff_scale_late <= ImpactDebris.DEV_IMPACT_SCALE_END,
		"DevImpact's puffs must start small and swell across the flight"
	)
	var splat_material := (
		(particle_nodes.front().get_node_or_null("Visual") as MeshInstance3D).mesh as QuadMesh
	).material as StandardMaterial3D if not particle_nodes.is_empty() else null
	_expect(
		splat_material != null
		and Color(
			splat_material.albedo_color, 1.0
		).is_equal_approx(Color(ImpactDebris.DEV_IMPACT_TINT, 1.0)),
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
	var opacity_ramp := ImpactDebris._fade_tail_opacities(
		ImpactDebris.DEV_IMPACT_FRAME_COUNT, ImpactDebris.DEV_IMPACT_FADE_FROM
	)
	_expect(
		opacity_ramp.size() == ImpactDebris.DEV_IMPACT_FRAME_COUNT
		and is_equal_approx(opacity_ramp[0], 1.0)
		and is_equal_approx(opacity_ramp[5], 1.0)
		and opacity_ramp[ImpactDebris.DEV_IMPACT_FRAME_COUNT - 2] < 1.0
		and is_zero_approx(opacity_ramp[ImpactDebris.DEV_IMPACT_FRAME_COUNT - 1]),
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
