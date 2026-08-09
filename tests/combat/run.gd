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
class PhysicsGround extends StaticBody3D:
	func _init() -> void:
		collision_layer = 1
		collision_mask = 0
		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(200.0, 0.5, 200.0)
		collision.position.y = -0.25
		collision.shape = box
		add_child(collision)


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
	_run_case("hitscan resolves at launch without travel", _test_hitscan_projectile)
	await _run_async_case(
		"lasers span the resolved 3D hit segment and remain visible briefly",
		_test_laser_hitscan_visual
	)
	_run_case("non-homing bullets keep the sampled aim point", _test_linear_projectile_no_lead)
	_run_case(
		"the undeployed Kobra's shell leaves its muzzle",
		_test_undeployed_kobra_shell_leaves_the_muzzle
	)
	_run_case("attack-ground missiles descend to the sampled point", _test_attack_ground_missile)
	_run_case("homing respects delay, turn rate and target lifetime", _test_homing_projectile)
	_run_case(
		"homing missiles may outfly their firing range while chasing",
		_test_homing_flight_budget
	)
	_run_case("trajectory bullets follow a gravity arc", _test_trajectory_projectile)
	_run_case(
		"elevated-only trajectory mounts prefer the high ballistic arc",
		_test_elevated_trajectory_mounts
	)
	_run_case(
		"a deployed Mortar launches its projectile on the high ballistic arc",
		_test_deployed_mortar_high_arc
	)
	await _run_async_case(
		"trajectory misses continue until contact instead of bursting in air",
		_test_trajectory_moving_target_miss
	)
	await _run_async_case("projectiles collide and Sonic pierces in 3D", _test_projectile_world_collision)
	await _run_async_case(
		"flame streams pierce units and buildings but stop at walls",
		_test_continuous_stream_piercing
	)
	_run_case(
		"a continuous stream's pulses split one clip's total damage evenly",
		_test_continuous_stream_damage_split
	)
	_run_case("turret emits bursts and reloads in rule ticks", _test_turret_reload)
	_run_case("turret FX ownership does not retain its turret", _test_turret_fx_ownership)
	_run_case(
		"continuous turrets burst then reload for equal ReloadCount windows",
		_test_continuous_turret_burst_reload
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
	_run_case("compound turret binds authored pivots and muzzle", _test_compound_turret)
	_run_case("single-axis turret turns without changing pitch", _test_single_axis_turret)
	_run_case("fixed weapon keeps its authored direction", _test_fixed_turret)
	_run_case("multi-barrel turret cycles authored muzzles", _test_multi_barrel_turret)
	_run_case("trajectory barrels fire a parallel salvo", _test_parallel_trajectory_salvo)
	_run_case("limited turret turns its hull toward rear targets", _test_limited_turret_hull_turn)
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
	_run_case("XBF fire events delay infantry projectiles", _test_xbf_fire_event_timing)
	_run_case("launcher fire clips schedule every projectile before reload", _test_launcher_fire_sequences)
	_run_case("continuous flame clips schedule every stream pulse", _test_continuous_flame_sequences)
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
	_run_case(
		"a deployed Kindjal fires Kindjal_B and never Pistol_B, requiring hull-assist aiming",
		_test_kindjal_deployed_fire
	)
	_run_case(
		"deployed fire completion does not replay its first-frame bigflash",
		_test_deployed_fire_completion_preserves_hidden_flash
	)
	_run_case(
		"a deployed Kobra tracks its turret with the hull frozen",
		_test_kobra_deployed_hull_frozen
	)
	_run_case(
		"a deployed Kobra acquires targets throughout its firing range",
		_test_kobra_deployed_range_acquisition
	)
	_run_case(
		"IMADVSardaukar is not combat-deployable and both of its turrets are always active",
		_test_sardaukar_not_combat_deployable
	)
	_run_case(
		"a travel-mode Kobra only ever selects Fire_0 or Fire_2, never Deployed_Fire",
		_test_kobra_travel_fire_variants
	)
	_run_case(
		"Kobra travel fire clips apply their horizontal barrel pose at both boundaries",
		_test_kobra_travel_fire_pose_boundaries
	)

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












func _test_hitscan_projectile() -> void:
	var target := Doubles.FakeCombatTarget.new(&"None")
	target.position = Vector3(0.0, 0.0, -5.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	var launched: bool = projectile.launch(
		_bullets.runtime_bullet(&"LMG_B"),
		Bullets.emission(Vector3.ZERO, Vector3.FORWARD),
		target
	)
	_expect(launched, "an in-range conceptual bullet must launch")
	_expect(projectile.is_finished(), "hitscan must finish in the launch call")
	_expect(projectile.finish_reason == &"impact_target", "hitscan must resolve against its live target")
	_expect(is_zero_approx(projectile.traveled_distance), "hitscan must accumulate no physical travel")
	_expect(is_equal_approx(target.damage_taken, 219.0), "hitscan must deliver its payload exactly once")
	projectile.free()


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


func _test_linear_projectile_no_lead() -> void:
	var target := Doubles.FakeCombatTarget.new(&"Heavy")
	target.position = Vector3(0.0, 0.0, -12.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_bullets.runtime_bullet(&"StraightBomb"),
			Bullets.emission(Vector3.ZERO, Vector3.FORWARD),
			target
		),
		"StraightBomb must launch toward an in-range target"
	)
	target.position = Vector3(5.0, 0.0, -12.0)
	projectile.advance(0.25)
	_expect(
		projectile.state == CombatProjectileScript.State.FLYING,
		"a 24-unit/s bullet must still be flying halfway to a point twelve units away"
	)
	_expect(
		projectile.global_position.is_equal_approx(Vector3(0.0, 0.0, -6.0)),
		"linear movement must use Speed in world units per second"
	)
	projectile.advance(0.25)
	_expect(projectile.finish_reason == &"impact_ground", "a sidestepping target must escape a non-homing shot")
	_expect(is_zero_approx(target.damage_taken), "a missed non-homing shot must not damage its former target")
	projectile.free()


func _test_undeployed_kobra_shell_leaves_the_muzzle() -> void:
	# Rules.txt leaves Howitzer_B without a Speed, which made the shell resolve
	# at its own muzzle: the undeployed Kobra blew a 64-unit blast up against its
	# own barrel and took the friendly-fire share of it. See docs/quirks.md.
	var shell_config: Resource = _bullets.bullet_config(&"Howitzer_B")
	var shell = CombatBulletScript.new(
		shell_config,
		_bullets.warhead_config(shell_config.warhead_id),
		load(String(shell_config.projectile_scene_path))
	)
	_expect(
		shell.speed() > 0.0 and not shell.has_trajectory() and not shell.is_hitscan(),
		"the undeployed Kobra's gun must fire a direct shot that actually travels"
	)
	var target := Doubles.FakeCombatTarget.new(&"Heavy")
	target.position = Vector3(0.0, 0.0, -7.0)
	var launch_position := Vector3(0.0, 1.0, 0.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			shell,
			Bullets.emission(launch_position, launch_position.direction_to(target.position)),
			target
		),
		"Howitzer_B must launch at a target seven units away, well inside its eight tiles"
	)
	_expect(
		projectile.state == CombatProjectileScript.State.FLYING,
		"the shell must be in flight after launch, not already detonated at the muzzle"
	)
	projectile.advance(0.1)
	_expect(
		projectile.state == CombatProjectileScript.State.FLYING
		and projectile.global_position.distance_to(launch_position) > 2.0,
		"a 28-unit/s shell must have cleared the firing Kobra after a tenth of a second"
	)
	# Both Kobra shells share shell.xaf, whose `?flashl02` the model itself
	# switches off on frame 0 and never shows again.
	var visual := projectile.get_node_or_null("Visual") as Node3D
	var source_flash := visual.find_child("*flashl*", true, false) as Node3D \
		if visual != null else null
	_expect(
		source_flash != null and not source_flash.visible,
		"the travel-mode shell must not burn its helper flash as rocket exhaust either"
	)
	projectile.advance(0.5)
	_expect(
		projectile.finish_reason == &"impact_target" and target.damage_taken > 0.0,
		"the shell must reach and damage the target it was fired at"
	)
	projectile.free()


func _test_attack_ground_missile() -> void:
	var launch_position := Vector3(0.0, 2.0, 0.0)
	var ground_position := Vector3(0.0, 0.0, -10.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_bullets.runtime_bullet(&"HEAT_B"),
			Bullets.emission(launch_position, Vector3.FORWARD),
			ground_position
		),
		"the Mongoose missile must accept an in-range attack-ground point"
	)
	_expect(
		projectile.direction().is_equal_approx(
			launch_position.direction_to(ground_position)
		),
		"a yaw-only launcher must include the downward component in a coordinate shot"
	)
	projectile.advance(1.0)
	_expect(
		projectile.finish_reason == &"impact_ground",
		"the attack-ground missile must resolve as a ground impact"
	)
	_expect(
		projectile.global_position.is_equal_approx(ground_position),
		"a large simulation step must not carry the missile past its sampled point"
	)
	projectile.free()


func _test_homing_projectile() -> void:
	var target := Doubles.FakeCombatTarget.new(&"Aircraft", true)
	target.position = Vector3(0.0, 0.0, -20.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_bullets.runtime_bullet(&"HEATADP_B"),
			Bullets.emission(Vector3.ZERO, Vector3.FORWARD),
			target
		),
		"the AA missile must launch at its exact minimum range"
	)
	target.position = Vector3(20.0, 0.0, 0.0)
	projectile.advance(0.25)
	_expect(
		projectile.direction().is_equal_approx(Vector3.FORWARD),
		"the missile must keep its launch heading for five HomingDelay ticks"
	)
	projectile.advance(0.05)
	_expect(projectile.direction().x > 0.5, "after the delay, TurnRate must bend the missile toward the live target")
	target.alive = false
	projectile.advance(0.05)
	_expect(projectile.finish_reason == &"target_lost", "a homing missile must self-destruct when its target dies")
	_expect(is_zero_approx(target.damage_taken), "target loss must not apply an impact payload")
	projectile.free()


## Rules.txt has no missile lifetime, so MaxRange doubles as the flight budget.
## A missile chasing a retreating target flies further than the straight line
## that was range-checked at launch; the extra budget keeps it alive to hit.
func _test_homing_flight_budget() -> void:
	var heat = _bullets.runtime_bullet(&"HEAT_B")
	_expect(
		heat.flight_range_world() > heat.maximum_range_world(),
		"a homing bullet must fly further than the range it is fired at"
	)
	var lmg = _bullets.runtime_bullet(&"LMG_B")
	_expect(
		is_equal_approx(lmg.flight_range_world(), lmg.maximum_range_world()),
		"a straight shot must keep firing range and flight budget identical"
	)

	var target := Doubles.FakeCombatTarget.new(&"Vehicle")
	target.position = Vector3(0.0, 0.0, -18.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			heat, Bullets.emission(Vector3.ZERO, Vector3.FORWARD), target
		),
		"the target must start inside HEAT_B's ten-tile firing range"
	)
	# Retreats at 8 world units per second against the missile's 28.
	for _step in 30:
		if projectile.state != CombatProjectileScript.State.FLYING:
			break
		target.position.z -= 8.0 * 0.05
		projectile.advance(0.05)
	_expect(
		projectile.finish_reason == &"impact_target",
		"a missile must not burn out chasing a target it is still gaining on"
	)
	_expect(
		projectile.traveled_distance > heat.maximum_range_world(),
		"the chase must have cost more distance than the launch range check"
	)
	projectile.free()


func _test_trajectory_projectile() -> void:
	var rules = root.get_node("Rules")
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	_expect(
		projectile.launch(
			_bullets.runtime_bullet(&"Mortar_B"),
			Bullets.emission(Vector3.ZERO, Vector3.FORWARD),
			Vector3(0.0, 0.0, -20.0),
			null,
			float(rules.general_rules().field(&"bullet_gravity", 1.0))
		),
		"a trajectory bullet without Speed must derive a gravity arc"
	)
	var launch_direction: Vector3 = projectile.direction()
	var launch_pitch := rad_to_deg(atan2(
		launch_direction.y, Vector2(launch_direction.x, launch_direction.z).length()
	))
	_expect(
		launch_pitch > 15.0 and launch_pitch < 30.0,
		"a target below MaxRange must use the flatter low ballistic solution instead of a fixed 45-degree arc"
	)
	projectile.advance(0.5)
	_expect(projectile.global_position.y > 1.0, "the mortar shell must rise above the direct line")
	_expect(projectile.state == CombatProjectileScript.State.FLYING, "the shell must remain alive before its arc completes")
	projectile.advance(2.0)
	_expect(projectile.finish_reason == &"impact_ground", "an attack-ground arc must burst at its sampled point")
	_expect(
		projectile.global_position.is_equal_approx(Vector3(0.0, 0.0, -20.0)),
		"the analytic arc must finish exactly at its aim position"
	)
	projectile.free()


func _test_elevated_trajectory_mounts() -> void:
	var cases: Array = [
		[&"ORMortarInfBigGun", ORMortarModelScene, 1],
		[&"HKInkVineGun", HKInkVineModelScene, 0],
	]
	for test_case in cases:
		var turret_id: StringName = test_case[0]
		var model := (test_case[1] as PackedScene).instantiate() as Node3D
		root.add_child(model)
		var turret = CombatTurretScript.new()
		_expect(turret.configure(turret_id), "%s must configure" % turret_id)
		_expect(
			turret.bind_model(model, int(test_case[2])),
			"%s must bind its authored muzzle and pitch pivot" % turret_id
		)
		var emission := turret.peek_emission()
		var horizontal_direction: Vector3 = emission["direction"]
		horizontal_direction.y = 0.0
		var bullet = CombatBulletScript.new(
			turret.bullet_config, turret.warhead_config,
			turret.projectile_visual_scene, turret.impact_visual_scenes
		)
		var target_position := Vector3(emission["position"]) \
			+ horizontal_direction.normalized() * bullet.maximum_range_world() * 0.92
		var direction: Vector3 = turret._desired_firing_direction(target_position)
		var launch_pitch := rad_to_deg(atan2(
			direction.y, Vector2(direction.x, direction.z).length()
		))
		_expect(
			launch_pitch > 45.0,
			"%s must choose the high ballistic solution, got %.2f degrees" % [
				turret_id, launch_pitch
			]
		)
		model.free()


func _test_deployed_mortar_high_arc() -> void:
	var mortar = UnitScene.instantiate()
	mortar.config_id = &"ORMortar"
	root.add_child(mortar)
	mortar.replace_visual_scene(ORMortarModelScene)
	_expect(mortar.deploy(), "a travel-mode Mortar must accept the deploy command")
	mortar.finish_deployment(true)
	_expect(mortar.is_deployed(), "the deploy call must land the Mortar in DEPLOYED")
	mortar._process(1.0 / 60.0)

	var active_turrets: Array = mortar.combat()._active_turrets()
	_expect(
		active_turrets.size() == 1
			and active_turrets[0].config.config_id == &"ORMortarInfBigGun",
		"a deployed Mortar must expose only its trajectory turret"
	)
	var turret = active_turrets[0]
	var emission: Dictionary = turret.peek_emission()
	var forward: Vector3 = emission["direction"]
	forward.y = 0.0
	var bullet = CombatBulletScript.new(
		turret.bullet_config, turret.warhead_config,
		turret.projectile_visual_scene, turret.impact_visual_scenes
	)
	var target_position := Vector3(emission["position"]) \
		+ forward.normalized() * bullet.maximum_range_world() * 0.75
	var fired: Array = []
	mortar.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
	)
	_expect(mortar.command_attack(target_position), "a deployed Mortar must accept an in-range target")
	for frame in 600:
		mortar._process(1.0 / 60.0)
		if not fired.is_empty():
			break
	var final_emission: Dictionary = turret.peek_emission()
	var final_direction: Vector3 = final_emission["direction"]
	var desired_direction: Vector3 = turret._desired_firing_direction(target_position)
	_expect(
		not fired.is_empty(),
		(
			"the deployed Mortar must fire after completing its aim "
			+ "(joint %.2f°, muzzle %.2f°, desired %.2f°, aimed=%s, range=%s)"
		) % [
			turret.current_pitch_degrees(),
			rad_to_deg(atan2(
				final_direction.y, Vector2(final_direction.x, final_direction.z).length()
			)),
			rad_to_deg(atan2(
				desired_direction.y, Vector2(desired_direction.x, desired_direction.z).length()
			)),
			turret.is_aimed_at(target_position),
			turret.target_range(target_position),
		]
	)
	if not fired.is_empty():
		var direction: Vector3 = fired[0].direction()
		var launch_pitch := rad_to_deg(atan2(
			direction.y, Vector2(direction.x, direction.z).length()
		))
		_expect(
			launch_pitch > 45.0,
			"the deployed Mortar projectile must use the high arc, got %.2f degrees" \
				% launch_pitch
		)
	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	mortar.free()


func _test_trajectory_moving_target_miss() -> void:
	var rules = root.get_node("Rules")
	var ground := PhysicsGround.new()
	root.add_child(ground)
	var target := Doubles.FakeCombatTarget.new(&"Heavy")
	target.position = Vector3(0.0, 3.0, -20.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	var explosions: Array[Vector3] = []
	projectile.explosion_requested.connect(
		func(_type: StringName, _effects: Array, position: Vector3) -> void:
			explosions.append(position)
	)
	_expect(
		projectile.launch(
			_bullets.runtime_bullet(&"InkVine_B"),
			Bullets.emission(Vector3(0.0, 2.0, 0.0), Vector3.FORWARD),
			target,
			null,
			float(rules.general_rules().field(&"bullet_gravity", 1.0))
		),
		"the Ink Vine shell must launch toward the original target position"
	)
	target.position = Vector3(8.0, 3.0, -20.0)
	await physics_frame

	for frame in 200:
		projectile.advance(0.01)
		if projectile.global_position.z <= -20.0:
			break
	_expect(
		projectile.state == CombatProjectileScript.State.FLYING,
		"a missed Ink Vine shell must keep flying beyond the old airborne aim point"
	)
	_expect(
		explosions.is_empty(),
		"a missed Ink Vine shell must not request an explosion in the air"
	)
	for frame in 200:
		projectile.advance(0.01)
		if projectile.is_finished():
			break
	_expect(
		projectile.finish_reason == &"impact_ground",
		"the missed Ink Vine shell must burst when its continued arc contacts ground"
	)
	_expect(
		not explosions.is_empty() and absf(explosions.front().y) <= 0.001,
		"the Ink Vine explosion must be emitted on the ground contact"
	)
	projectile.free()
	ground.free()


func _test_projectile_world_collision() -> void:
	var blocker := Doubles.PhysicsCombatTarget.new(Vector3(0.0, 0.0, -4.0), 0.75)
	var target := Doubles.PhysicsCombatTarget.new(Vector3(0.0, 0.0, -8.0), 0.75)
	root.add_child(blocker)
	root.add_child(target)
	await physics_frame

	var shell = CombatProjectileScript.new()
	root.add_child(shell)
	shell.launch(
		_bullets.runtime_bullet(&"StraightBomb"),
		Bullets.emission(Vector3.ZERO, Vector3.FORWARD),
		target
	)
	shell.advance(0.5)
	_expect(shell.finish_reason == &"impact_target", "a direct shell must stop at the first combat collider")
	_expect(blocker.damage_taken > 0.0, "the first entity on the ray must receive the shell payload")
	_expect(is_zero_approx(target.damage_taken), "an intercepted non-piercing shell must not reach its intended target")
	shell.free()

	blocker.damage_taken = 0.0
	target.damage_taken = 0.0
	var wave = CombatProjectileScript.new()
	root.add_child(wave)
	wave.launch(
		_bullets.runtime_bullet(&"Sound_B"),
		Bullets.emission(Vector3.ZERO, Vector3.FORWARD),
		target
	)
	wave.advance(0.5)
	_expect(blocker.damage_taken > 0.0, "the Sonic wave must damage the first intersected entity")
	_expect(target.damage_taken > 0.0, "the Sonic wave must continue through to the entity behind it")
	_expect(wave.traveled_distance >= 8.0, "piercing must not end the wave at the first collision")
	wave.free()
	blocker.free()
	target.free()


func _test_continuous_stream_piercing() -> void:
	var blocker := Doubles.PhysicsCombatTarget.new(Vector3(0.0, 0.0, -4.0), 0.75)
	var target := Doubles.PhysicsCombatTarget.new(Vector3(0.0, 0.0, -8.0), 0.75)
	root.add_child(blocker)
	root.add_child(target)
	await physics_frame

	var flame = CombatProjectileScript.new()
	root.add_child(flame)
	flame.launch(
		_bullets.runtime_bullet(&"Flame_B"),
		Bullets.emission(Vector3.ZERO, Vector3.FORWARD),
		target
	)
	flame.advance(0.5)
	_expect(blocker.damage_taken > 0.0, "a flame stream must burn the first unit in its path")
	_expect(
		target.damage_taken > 0.0,
		"a flame stream must keep burning through to the unit standing behind it"
	)
	flame.free()

	blocker.damage_taken = 0.0
	target.damage_taken = 0.0
	blocker.add_to_group("wall_buildings")
	var flame_at_wall = CombatProjectileScript.new()
	root.add_child(flame_at_wall)
	flame_at_wall.launch(
		_bullets.runtime_bullet(&"Flame_B"),
		Bullets.emission(Vector3.ZERO, Vector3.FORWARD),
		target
	)
	flame_at_wall.advance(0.5)
	_expect(blocker.damage_taken > 0.0, "a flame stream must still burn a wall it reaches")
	_expect(
		is_zero_approx(target.damage_taken),
		"a wall, unlike an ordinary unit or building, must stop a flame stream"
	)
	flame_at_wall.free()
	blocker.free()
	target.free()


func _test_continuous_stream_damage_split() -> void:
	var flame = _bullets.runtime_bullet(&"Flame_B")
	var full_burst_damage: float = flame.damage_against(&"Building")

	var pulse_count := 17
	var pulse = ShotPayloadScript.new(
		_bullets.runtime_bullet(&"Flame_B"), 1.0 / pulse_count
	)
	_expect(
		is_equal_approx(pulse.damage_against(&"Building") * pulse_count, full_burst_damage),
		"summing every evenly scaled pulse must recover exactly one full stream hit"
	)
	_expect(
		pulse.damage_against(&"Building") < full_burst_damage,
		"an individual pulse must deal less than the whole stream's total damage"
	)


func _test_turret_fx_ownership() -> void:
	var turret = CombatTurretScript.new()
	_expect(turret.configure(&"ATInfGun"), "the lifetime fixture must configure")
	var turret_ref: WeakRef = weakref(turret)
	turret = null
	_expect(
		turret_ref.get_ref() == null,
		"the FX module must not keep its RefCounted turret owner alive"
	)






func _test_turret_reload() -> void:
	var _rules = root.get_node("Rules")
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATInfGun"),
		"ATInfGun must resolve Turret -> LMG_B -> LMG_W"
	)
	var first_shot: Array = turret.try_fire()
	_expect(first_shot.size() == 1, "a normal turret must emit one bullet")
	_expect(is_equal_approx(turret.reload_ticks_remaining, 30.0), "ATInfGun ReloadCount must be 30 ticks")
	_expect(turret.try_fire().is_empty(), "a turret must not fire again during reload")
	turret.advance_ticks(29.0)
	_expect(not turret.is_ready(), "the turret must remain locked one tick before reload completes")
	turret.advance_ticks(1.0)
	_expect(turret.is_ready(), "the turret must become ready on the final reload tick")

	var burst_turret = CombatTurretScript.new()
	_expect(
		burst_turret.configure(&"ATOrnithopterGun"),
		"the Ornithopter turret must resolve through the rules catalog"
	)
	_expect(
		burst_turret.try_fire().size() == 10,
		"TurretBulletCount=10 must emit a ten-bullet burst"
	)


func _test_continuous_turret_burst_reload() -> void:
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"HKFlamerGun"),
		"HKFlamerGun must resolve Turret -> Flame_B -> Flame_W"
	)
	_expect(
		turret.is_continuous_bullet(),
		"HKFlamerGun's Flame_B bullet must be marked continuous"
	)
	_expect(
		not turret.continuous_burst_active(),
		"a fresh turret must not start inside a burst window"
	)

	turret.begin_continuous_burst()
	_expect(
		is_equal_approx(turret.continuous_burst_ticks_remaining, 30.0),
		"the burst window must be sized to ReloadCount (30 ticks)"
	)
	turret.advance_ticks(29.0)
	_expect(
		turret.continuous_burst_active(),
		"the burst window must still be open one tick before it elapses"
	)
	_expect(
		turret.is_ready(),
		"a turret mid-burst must not have started its post-burst reload yet"
	)

	turret.advance_ticks(1.0)
	_expect(
		not turret.continuous_burst_active(),
		"the burst window must close once its ReloadCount ticks elapse"
	)
	_expect(
		not turret.is_ready(),
		"closing the burst window must start a real ReloadCount cooldown"
	)
	_expect(
		is_equal_approx(turret.reload_ticks_remaining, 30.0),
		"the post-burst cooldown must last the same ReloadCount as the burst"
	)

	turret.advance_ticks(29.0)
	_expect(not turret.is_ready(), "the cooldown must remain locked one tick early")
	turret.advance_ticks(1.0)
	_expect(turret.is_ready(), "the turret must become ready once the cooldown elapses")


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


func _test_compound_turret() -> void:
	var _rules = root.get_node("Rules")
	var model := ATAPCModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATAPCBase"),
		"ATAPCBase must resolve its ATAPCGun joint"
	)
	_expect(turret.bind_model(model, 0), "the APC's ::0 pivot must bind")
	_expect(turret.joint_count() == 2, "TurretNextJoint must produce a two-joint chain")
	_expect(turret.muzzle_count() == 1, "the nested >>0 marker must be the muzzle")
	_expect(not turret.is_fixed(), "the APC turret must expose moving axes")

	var emission := turret.peek_emission()
	_expect(not emission.is_empty(), "a bound turret must expose a world-space emission")
	_expect(
		String((emission.get("node") as Node).get_meta("original_name", "")).contains(">>0"),
		"the emission node must retain the original >>0 marker"
	)
	var target: Vector3 = emission["position"] + Vector3.RIGHT * 10000.0
	turret.aim_at(target, 0.05)
	_expect(
		is_equal_approx(turret.current_yaw_degrees(), 2.5),
		"one 20 Hz aim update must turn by TurretYRotationAngle"
	)
	turret.aim_at(target, 10.0)
	_expect(
		absf(turret.current_yaw_degrees() - 90.0) < 1.0,
		"an unrestricted base must eventually face a target to its right"
	)

	var down_target: Vector3 = turret.peek_emission()["position"] + Vector3.DOWN * 100.0
	turret.aim_at(down_target, 10.0)
	_expect(
		absf(turret.current_pitch_degrees() - 5.0) < 0.1,
		"the gun joint must stop at TurretMaxXRotation"
	)
	model.free()


func _test_fixed_turret() -> void:
	var _rules = root.get_node("Rules")
	var model := ATInfantryModelScene.instantiate() as Node3D
	root.add_child(model)
	Fx.free_muzzle_effects(root)
	Fx.free_impact_effects(root)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATInfGun"),
		"ATInfGun must remain a configured fixed weapon"
	)
	_expect(
		turret.muzzle_flash_id == &"Smuzz2" and turret.muzzle_flash_scene != null,
		"ATInfGun must retain its rules TurretMuzzleFlash for models without an embedded flash"
	)
	_expect(
		turret.impact_visual_scenes.has(&"Mghit"),
		"LMG_B must resolve its rules ExplosionType=mghit through ArtIni"
	)
	_expect(turret.bind_model(model, 0), "the infantry weapon marker must bind")
	_expect(turret.is_fixed(), "a turret without X/Y rotation speeds must be fixed")
	_expect(turret.requires_hull_turn(), "a fixed weapon must require owner-body alignment")
	var emission := turret.peek_emission()
	var side_target: Vector3 = emission["position"] + Vector3.RIGHT * 100.0
	_expect(not turret.aim_at(side_target, 10.0), "a fixed weapon must not rotate to a side target")
	_expect(is_zero_approx(turret.current_yaw_degrees()), "a fixed weapon's yaw must stay at rest")
	_expect(is_zero_approx(turret.current_pitch_degrees()), "a fixed weapon's pitch must stay at rest")

	var target_position: Vector3 = Vector3(emission["position"]) \
		+ Vector3(emission["direction"]) * 5.0
	var projectiles: Array = turret.try_fire_at(FireRequestScript.at(target_position, model, root))
	_expect(projectiles.size() == 1, "ATInfGun must emit its conceptual LMG_B shot")
	_expect(
		root.get_node_or_null("MuzzleFlash_Smuzz2") == null
		and Fx.muzzle_effects(root, &"shot_light").is_empty(),
		"AT Infantry Fire_0 must use only its embedded muzzle flash"
	)
	var impacts := Fx.impact_effects(root, &"Mghit")
	_expect(
		impacts.size() == 1
		and impacts[0].global_position.is_equal_approx(target_position),
		"AT Infantry must spawn the rules-backed Mghit at its hit position"
	)
	for projectile in projectiles:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	Fx.free_muzzle_effects(root)
	Fx.free_impact_effects(root)
	model.free()


func _test_single_axis_turret() -> void:
	var _rules = root.get_node("Rules")
	var model := ORLaserTankModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ORLaserTankBase"),
		"ORLaserTankBase must resolve its laser bullet"
	)
	_expect(turret.bind_model(model, 0), "the Laser Tank's ::0 pivot must bind")
	_expect(not turret.is_fixed(), "a Y-only turret must not be classified as fixed")
	_expect(not turret.requires_hull_turn(), "a Y-only turret can align without turning its hull")
	var emission := turret.peek_emission()
	var close_direction := Vector3(emission["direction"])
	close_direction.y = 0.0
	close_direction = close_direction.normalized()
	var close_target := model.global_position + close_direction
	for unused in 30:
		if turret.aim_at(close_target, 0.05):
			break
	_expect(
		turret.is_aimed_at(close_target),
		"the Laser Tank must acquire a close target from its pivot despite its offset muzzle"
	)
	var close_projectiles: Array = turret.try_fire_at(FireRequestScript.at(close_target, model, root))
	_expect(
		close_projectiles.size() == 1,
		"the Laser Tank must fire inside the false offset-muzzle dead zone"
	)
	for projectile in close_projectiles:
		if is_instance_valid(projectile):
			projectile.free()
	Fx.free_muzzle_effects(root)
	for unused in 30:
		if turret.recenter(0.05):
			break
	emission = turret.peek_emission()
	var side_target: Vector3 = emission["position"] + Vector3.RIGHT * 10000.0
	turret.aim_at(side_target, 0.05)
	_expect(
		is_equal_approx(turret.current_yaw_degrees(), 16.0),
		"the Laser Tank must turn by its 16-degree Y step"
	)
	_expect(is_zero_approx(turret.current_pitch_degrees()), "a Y-only turret must keep pitch at rest")
	model.free()


func _test_multi_barrel_turret() -> void:
	var _rules = root.get_node("Rules")
	var model := ATMinotaurusModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	turret.configure(&"ATMinotaurusBase")
	_expect(turret.bind_model(model, 0), "the Minotaurus turret root must bind")
	_expect(turret.muzzle_count() == 4, "all four descendant >> markers must be collected")
	_expect(
		turret.rear_muzzle_count() == 4,
		"all four rear #muzzle markers must pair with their sibling projectile markers"
	)
	for emission in turret.emission_points():
		_expect(
			emission.has("rear_position")
			and Vector3(emission["direction"]).dot(
				Vector3(emission["rear_direction"])
			) < -0.999,
			"a paired #muzzle emitter must point backward from its barrel"
		)
	var observed: Array[int] = []
	for index in 5:
		observed.append(int(turret.next_emission().get("index", -1)))
	_expect(observed == [0, 1, 2, 3, 0], "muzzles must cycle in marker order and wrap")
	model.free()


func _test_parallel_trajectory_salvo() -> void:
	var _rules = root.get_node("Rules")
	var model := ATMinotaurusModelScene.instantiate() as Node3D
	root.add_child(model)
	var turret = CombatTurretScript.new()
	turret.configure(&"ATMinotaurusBase")
	_expect(turret.bind_model(model, 0), "the Minotaurus turret root must bind")
	var first_emission := turret.peek_emission()
	var level_forward := Vector3(first_emission["direction"])
	level_forward.y = 0.0
	level_forward = level_forward.normalized()
	var target_position := model.global_position + level_forward * 10.0
	target_position.y = Vector3(first_emission["position"]).y
	var aimed := false
	for frame in 120:
		aimed = turret.aim_at(target_position, 1.0 / 60.0)
		if aimed:
			break
	_expect(aimed, "the complete barrel group must acquire the central target")

	var emissions: Array[Dictionary] = []
	var projectiles: Array = []
	for shot in 4:
		emissions.append(turret.peek_emission())
		var barrel_request := FireRequestScript.at(target_position, model, root)
		barrel_request.begin_reload_after_shot = false
		var fired: Array = turret.try_fire_at(barrel_request)
		if not fired.is_empty():
			projectiles.append(fired.front())
	_expect(
		projectiles.size() == 4,
		"all four side-by-side barrels must accept the same rigid aim pose"
	)
	if projectiles.size() == 4:
		var first_direction := Vector3(projectiles[0].direction())
		first_direction.y = 0.0
		first_direction = first_direction.normalized()
		var visible_lateral_separation := false
		for index in range(1, projectiles.size()):
			var shot_direction := Vector3(projectiles[index].direction())
			shot_direction.y = 0.0
			shot_direction = shot_direction.normalized()
			_expect(
				first_direction.dot(shot_direction) > 0.99999,
				"trajectory shells must not steer horizontally toward one point"
			)
			var muzzle_delta := (
				Vector3(emissions[index]["position"])
				- Vector3(emissions[0]["position"])
			)
			muzzle_delta.y = 0.0
			var impact_delta := (
				Vector3(projectiles[index].trajectory_impact_position())
				- Vector3(projectiles[0].trajectory_impact_position())
			)
			impact_delta.y = 0.0
			var muzzle_lateral := muzzle_delta - first_direction * muzzle_delta.dot(first_direction)
			var impact_lateral := impact_delta - first_direction * impact_delta.dot(first_direction)
			visible_lateral_separation = visible_lateral_separation \
				or muzzle_lateral.length() > 0.01
			_expect(
				muzzle_lateral.distance_to(impact_lateral) <= 0.001,
				"each shell must preserve its muzzle's lateral offset through impact"
			)
		_expect(
			visible_lateral_separation,
			"the authored Minotaurus muzzle spacing must create a lateral impact pattern"
		)
	for projectile in projectiles:
		projectile.free()
	Fx.free_muzzle_effects(root)
	model.free()


func _test_limited_turret_hull_turn() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATMinotaurus"
	root.add_child(unit)
	unit.replace_visual_scene(ATMinotaurusModelScene)
	var turret = unit.combat_turrets[0]
	var emission: Dictionary = turret.peek_emission()
	var initial_hull_yaw: float = unit.global_rotation.y
	var initial_forward: Vector3 = unit.facing_direction()
	var target := Doubles.FakeCombatTarget.new(&"None")
	target.position = unit.global_position - initial_forward * 10.0
	target.position.y = Vector3(emission["position"]).y
	_expect(
		turret.requires_hull_turn_for(target.position),
		"a rear target must be outside the Minotaurus +/-45 degree turret sector"
	)

	var fired: Array = []
	unit.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		fired.append_array(projectiles)
	)
	_expect(unit.command_attack(target), "the Minotaurus must accept an in-range rear target")
	for frame in 360:
		unit._process(1.0 / 60.0)
		if not fired.is_empty():
			break
	var hull_turn := absf(angle_difference(initial_hull_yaw, unit.global_rotation.y))
	_expect(
		hull_turn > deg_to_rad(90.0),
		"the Minotaurus hull must keep turning after its turret reaches the sector limit"
	)
	_expect(
		absf(turret.current_yaw_degrees()) <= 45.01,
		"supplemental hull rotation must not push the turret beyond its authored limits"
	)
	_expect(not fired.is_empty(), "the Minotaurus must fire after hull-assisted aiming")
	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	unit.free()


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


func _test_launcher_fire_sequences() -> void:
	var definitions := [
		[&"HKMissile", HKMissileModelScene],
		[&"ORAPC", ORAPCModelScene],
		[&"HKDevastator", HKDevastatorModelScene],
	]
	for definition in definitions:
		var launcher = UnitScene.instantiate()
		launcher.config_id = definition[0]
		root.add_child(launcher)
		launcher.replace_visual_scene(definition[1])
		for turret in launcher.combat_turrets:
			var binding: Dictionary = launcher.fire_animation_binding(turret.weapon_index())
			var player := binding["player"] as AnimationPlayer
			var animation_name := StringName(binding["name"])
			var animation := player.get_animation(animation_name)
			var shot_times: Array[Dictionary] = launcher.combat()._authored_fire_shot_times(
				player, animation, turret, animation_name
			)
			var source_times: Array[Dictionary] = launcher.combat()._xbf_fire_shot_times(
				animation_name, animation, turret
			)
			var configured_count := int(turret.firing_config.burst_shot_count)
			# A launcher's burst is authored, not read off the model: a rig may
			# carry more tubes than the salvo fires (HKMissile has twelve >>N
			# muzzles but launches six rockets), so the burst only has to be a
			# positive count the muzzles can serve, not one shot per tube.
			_expect(
				configured_count > 0 and configured_count <= turret.muzzle_count(),
				"%s weapon %d must configure a burst its muzzles can fire" % [
					definition[0], turret.weapon_index()
				]
			)
			_expect(
				shot_times.size() == configured_count,
				"%s weapon %d must schedule every configured burst shot" % [
					definition[0], turret.weapon_index()
				]
			)
			if not source_times.is_empty():
				_expect(
					shot_times == source_times,
					"%s weapon %d must prefer its complete XBF projectile schedule" % [
						definition[0], turret.weapon_index()
					]
				)
			elif shot_times.size() >= 2:
				_expect(
					is_equal_approx(
						float(shot_times[1]["time"]) - float(shot_times[0]["time"]),
						float(turret.firing_config.burst_interval_ticks) \
							/ UnitScript.RULE_COMBAT_TICKS_PER_SECOND
					),
					"%s weapon %d must use its configured burst interval" % [
						definition[0], turret.weapon_index()
					]
				)
			_expect(
				float(shot_times.back()["time"]) <= animation.length,
				"%s weapon %d must complete its burst inside Fire_0" % [
					definition[0], turret.weapon_index()
				]
			)
			for shot: Dictionary in shot_times:
				var muzzle := int(shot.get("muzzle", -1))
				_expect(
					muzzle == -1 or (muzzle >= 0 and muzzle < turret.muzzle_count()),
					"%s weapon %d must only assign a shot to a real muzzle index" % [
						definition[0], turret.weapon_index()
					]
				)
		launcher.free()


func _test_continuous_flame_sequences() -> void:
	var definitions := [
		[&"HKFlamer", HKFlamerModelScene, [17]],
		[&"HKFlame", HKFlameModelScene, [4, 5]],
	]
	for definition: Array in definitions:
		var unit = UnitScene.instantiate()
		unit.config_id = definition[0]
		root.add_child(unit)
		unit.replace_visual_scene(definition[1])
		var expected_counts: Array = definition[2]
		_expect(
			unit.combat_turrets.size() == expected_counts.size(),
			"%s must expose every expected continuous flame weapon" % definition[0]
		)
		for turret_index in mini(unit.combat_turrets.size(), expected_counts.size()):
			var turret = unit.combat_turrets[turret_index]
			var binding: Dictionary = unit.fire_animation_binding(turret.weapon_index())
			var player := binding.get("player") as AnimationPlayer
			var animation_name := StringName(binding.get("name", &""))
			var animation := player.get_animation(animation_name) if player != null else null
			var shot_times: Array[Dictionary] = unit.combat()._authored_fire_shot_times(
				player, animation, turret, animation_name
			) if animation != null else []
			_expect(
				shot_times.size() == int(expected_counts[turret_index]),
				"%s weapon %d must expand its continuous XBF event into %d pulses, found %d"
					% [
						definition[0], turret.weapon_index(),
						expected_counts[turret_index], shot_times.size(),
					]
			)
			for shot_index in range(1, shot_times.size()):
				_expect(
					is_equal_approx(
						float(shot_times[shot_index]["time"])
							- float(shot_times[shot_index - 1]["time"]),
						1.0 / UnitScript.BAKED_MODEL_FRAMES_PER_SECOND
					),
					"%s weapon %d continuous pulses must retain XBF frame cadence"
						% [definition[0], turret.weapon_index()]
				)
		unit.free()


func _test_xbf_fire_event_timing() -> void:
	var trooper = UnitScene.instantiate()
	trooper.config_id = &"ORAATrooper"
	root.add_child(trooper)
	trooper.replace_visual_scene(ORAATrooperModelScene)
	var player := trooper.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	var animation := player.get_animation(&"Fire_0")
	var turret = trooper.combat_turrets[0]
	var shot_times: Array[Dictionary] = trooper.combat()._authored_fire_shot_times(
		player, animation, turret, &"Fire_0"
	)
	_expect(
		shot_times.size() == 1
			and is_equal_approx(float(shot_times[0]["time"]), 15.0 / 20.0),
		"ORAATrooper must convert its absolute frame-301 type-10 event "
			+ "to frame 15 of the Fire_0 clip"
	)

	var emission: Dictionary = trooper.turret_emission_points()[0]
	var target: Vector3 = Vector3(emission["position"]) \
		+ Vector3(emission["direction"]).normalized() * 5.0
	var fired: Array = []
	trooper.weapon_fired.connect(func(
			projectiles: Array, _target: Variant, _weapon_index: int
		) -> void:
		fired.append_array(projectiles)
	)
	_expect(trooper.command_attack(target), "ORAATrooper must accept an in-range target")
	_expect(
		trooper.combat()._start_authored_fire_sequence(turret),
		"ORAATrooper must start its authored Fire_0 sequence"
	)
	trooper._process(0.59)
	_expect(
		fired.is_empty(),
		"ORAATrooper must not launch before the authored firing pose"
	)
	trooper._process(0.02)
	_expect(
		fired.size() == 1,
		"ORAATrooper must launch when Fire_0 reaches its type-10 event"
	)
	trooper.free()


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






func _test_kindjal_deployed_fire() -> void:
	var kindjal = UnitScene.instantiate()
	kindjal.config_id = &"ATKindjal"
	root.add_child(kindjal)
	kindjal.replace_visual_scene(ATKindjalModelScene)

	_expect(kindjal.deploy(), "a travel-mode Kindjal must accept the deploy command")
	kindjal.finish_deployment(true)
	_expect(kindjal.is_deployed(), "the deploy call must land the Kindjal in DEPLOYED")

	var active_turrets: Array = kindjal.combat()._active_turrets()
	_expect(
		active_turrets.size() == 1 and active_turrets[0].config.config_id == &"ATKindjalBigGun",
		"a deployed Kindjal must expose only its deployed turret"
	)
	_expect(
		active_turrets[0].requires_hull_turn(),
		"Kindjal's deployed gun has yaw_speed=0 (fixed) and must rely on hull-assist aiming"
	)

	var emission: Dictionary = active_turrets[0].peek_emission()
	var forward: Vector3 = Vector3(emission["direction"])
	forward.y = 0.0
	var target := Doubles.FakeCombatTarget.new(&"Heavy")
	target.position = kindjal.global_position + forward.normalized() * 20.0

	var fired_bullets: Array[StringName] = []
	var fired_projectiles: Array = []
	kindjal.weapon_fired.connect(func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
		fired_projectiles.append_array(projectiles)
		for projectile in projectiles:
			fired_bullets.append(projectile.bullet.id())
	)
	_expect(kindjal.command_attack(target), "a deployed Kindjal must accept an attack order")
	for frame in 300:
		kindjal._process(1.0 / 20.0)
		if not fired_bullets.is_empty():
			break
	_expect(not fired_bullets.is_empty(), "a deployed Kindjal must fire after completing its aim")
	_expect(
		fired_bullets.all(func(bullet_id: StringName) -> bool: return bullet_id == &"Kindjal_B"),
		"a deployed Kindjal must fire Kindjal_B and never Pistol_B (its travel-mode bullet)"
	)
	for projectile in fired_projectiles:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	kindjal.free()


func _test_deployed_fire_completion_preserves_hidden_flash() -> void:
	var cases := [
		[&"ATKindjal", ATKindjalModelScene],
		[&"ORMortar", ORMortarModelScene],
	]
	for deployed_case: Array in cases:
		var unit = UnitScene.instantiate()
		unit.config_id = StringName(deployed_case[0])
		root.add_child(unit)
		unit.replace_visual_scene(deployed_case[1] as PackedScene)
		var deploy_started: bool = unit.deploy()
		unit.finish_deployment(true)
		_expect(
			deploy_started and unit.is_deployed(),
			"%s must enter its deployed pose" % String(deployed_case[0])
		)
		var player := unit.get_node("VisualRoot").find_child(
			"AnimationPlayer", true, false
		) as AnimationPlayer
		var animation := player.get_animation(&"Deployed_Fire") \
			if player != null else null
		var flash: Node3D
		if animation != null:
			var animation_root := player.get_node(player.root_node)
			for track_index in animation.get_track_count():
				var path := String(animation.track_get_path(track_index))
				if not path.to_lower().contains("bigflash") \
				or not path.ends_with(":transform") \
				or animation.track_get_key_count(track_index) < 2:
					continue
				var first := animation.track_get_key_value(
					track_index, 0
				) as Transform3D
				var last := animation.track_get_key_value(
					track_index,
					animation.track_get_key_count(track_index) - 1
				) as Transform3D
				if first.basis.get_scale().length() \
				<= last.basis.get_scale().length() * 2.0:
					continue
				flash = animation_root.get_node_or_null(
					NodePath(path.get_slice(":", 0))
				) as Node3D
				break
		_expect(
			player != null and animation != null and flash != null,
			"%s Deployed_Fire must expose its shrinking bigflash track"
				% String(deployed_case[0])
		)
		if player == null or animation == null or flash == null:
			unit.free()
			continue
		player.play(&"Deployed_Fire")
		player.advance(animation.length)
		var hidden_end_scale := flash.scale
		unit.combat()._weapon_fire_sequences[1] = {
			"player": player,
			"turret": null,
			"blocking": true,
			"shots_emitted": 0,
		}
		unit.combat()._finish_fire_sequence_for(1)
		_expect(
			flash.scale.is_equal_approx(hidden_end_scale),
			(
				"%s fire completion must retain the hidden final bigflash pose "
				+ "until Deploy_Gun_Hold is evaluated"
			) % String(deployed_case[0])
		)
		unit.free()


func _test_kobra_deployed_hull_frozen() -> void:
	var kindjal = UnitScene.instantiate()
	kindjal.config_id = &"ATKindjal"
	root.add_child(kindjal)
	kindjal.replace_visual_scene(ATKindjalModelScene)
	_expect(kindjal.deploy(), "Kindjal must accept the deploy command")
	kindjal.finish_deployment(true)
	var kindjal_turret = kindjal.combat()._active_turrets()[0]
	_expect(
		kindjal_turret.requires_hull_turn(),
		"a deployed Kindjal's fixed gun must require hull-assist aiming"
	)
	kindjal.free()

	var kobra = UnitScene.instantiate()
	kobra.config_id = &"ORKobra"
	root.add_child(kobra)
	kobra.replace_visual_scene(ORKobraModelScene)
	_expect(kobra.deploy(), "a travel-mode Kobra must accept the deploy command")
	kobra.finish_deployment(true)
	_expect(kobra.is_deployed(), "the deploy call must land the Kobra in DEPLOYED")

	var active_turrets: Array = kobra.combat()._active_turrets()
	_expect(
		active_turrets.size() == 1 and active_turrets[0].config.config_id == &"ORKobraDeployedGun",
		"a deployed Kobra must expose only its deployed turret"
	)
	_expect(
		not active_turrets[0].requires_hull_turn(),
		"Kobra's deployed gun has real yaw travel and must never ask for a hull turn"
	)
	kobra.free()


func _test_kobra_deployed_range_acquisition() -> void:
	var kobra = UnitScene.instantiate()
	kobra.config_id = &"ORKobra"
	root.add_child(kobra)
	kobra.replace_visual_scene(ORKobraModelScene)
	_expect(kobra.deploy(), "Kobra must accept the deploy command")
	kobra.finish_deployment(true)
	var turret = kobra.combat()._active_turrets()[0]
	var emission: Dictionary = turret.peek_emission()
	var forward := Vector3(emission["direction"])
	forward.y = 0.0
	forward = forward.normalized()
	var target := Doubles.FakeCombatTarget.new(&"Heavy")
	var failed_distances: Array[float] = []
	for distance_tenths in range(10, 321):
		var distance := float(distance_tenths) * 0.1
		target.position = kobra.global_position + forward * distance
		turret.reset_aim()
		var aimed := false
		for frame in 100:
			aimed = turret.aim_at(target.position, 1.0 / 20.0)
			if aimed:
				break
		if (
			turret.target_range(target) == CombatTurretScript.TargetRange.IN_RANGE
			and not aimed
		):
			failed_distances.append(distance)
	_expect(
		failed_distances.is_empty(),
		"Kobra must acquire every in-range target; failed distances: %s"
			% [failed_distances]
	)
	# Exact attack-ground dead zone reported from the live demo: the Kobra's
	# long shared yaw/pitch pivot used to feed its current muzzle height back
	# into ballistic arc selection and never complete vertical acquisition.
	target.position = kobra.global_position + Vector3(
		6.15308, -0.00272, -5.34003
	)
	var fired_projectiles: Array = []
	kobra.weapon_fired.connect(func(
			projectiles: Array, _target: Variant, _weapon_index: int
		) -> void:
		fired_projectiles.append_array(projectiles)
	)
	_expect(
		kobra.command_attack(target.position),
		"Kobra must accept the reported attack-ground dead-zone order"
	)
	for frame in 300:
		kobra._process(1.0 / 20.0)
		if not fired_projectiles.is_empty():
			break
	_expect(
		not fired_projectiles.is_empty(),
		"Kobra must fire at the reported high/low arc transition"
	)
	for projectile in fired_projectiles:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	kobra.free()


func _test_sardaukar_not_combat_deployable() -> void:
	var sardaukar = UnitScene.instantiate()
	sardaukar.config_id = &"IMADVSardaukar"
	root.add_child(sardaukar)

	_expect(
		not sardaukar.combat()._is_combat_deployable(),
		"IMADVSardaukar must not be combat-deployable despite its knife/gun turret pair"
	)
	_expect(sardaukar.combat_turrets.size() == 2, "IMADVSardaukar must configure both its gun and knife turrets")
	for turret in sardaukar.combat_turrets:
		_expect(
			turret.is_active_while_deployed(true) and turret.is_active_while_deployed(false),
			"%s must be active in both deploy states (the Rules.txt gate is corrected at generation time)"
				% String(turret.config.config_id)
		)
	sardaukar.free()


func _test_kobra_travel_fire_variants() -> void:
	var kobra = UnitScene.instantiate()
	kobra.config_id = &"ORKobra"
	root.add_child(kobra)
	kobra.replace_visual_scene(ORKobraModelScene)
	_expect(not kobra.is_deployed(), "a fresh Kobra must start in travel mode")

	var travel_turret = kobra.combat()._active_turrets()[0]
	_expect(
		travel_turret.config.config_id == &"ORKobraUndeployedGun",
		"travel mode must expose only the travel turret"
	)

	var seen_names := {}
	for _sample in 60:
		var binding: Dictionary = kobra.fire_animation_binding(travel_turret.weapon_index())
		_expect(not binding.is_empty(), "a travel-mode Kobra must resolve a fire clip")
		if binding.is_empty():
			continue
		seen_names[String(binding.get("name", ""))] = true
	for clip_name in seen_names.keys():
		_expect(
			clip_name in ["Fire_0", "Fire_2"],
			"a travel-mode Kobra must only ever select Fire_0 or Fire_2, got %s" % clip_name
		)
	_expect(
		not seen_names.has("Deployed_Fire"),
		"a travel-mode Kobra must never select Deployed_Fire"
	)
	kobra.free()


func _test_kobra_travel_fire_pose_boundaries() -> void:
	var kobra = UnitScene.instantiate()
	kobra.config_id = &"ORKobra"
	root.add_child(kobra)
	kobra.replace_visual_scene(ORKobraModelScene)
	var player := kobra.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	var barrel := kobra.get_node("VisualRoot").find_child(
		"barrel", true, false
	) as Node3D
	var deployed_turret = kobra.combat_turrets[1]
	for animation_name in [&"Fire_0", &"Fire_2"]:
		# Reproduce the stale inactive-turret pose that used to be written by
		# _restore_combat_turret_poses immediately after play().
		deployed_turret.restore_aim_pose()
		kobra.play_animation_from_start(player, animation_name)
		_expect(
			absf(barrel.global_basis.z.normalized().y) < 0.1,
			"%s must apply its horizontal barrel pose before the next animation tick"
				% animation_name
		)
		kobra.play_animation_from_start(player, &"Stationary")
		_expect(
			absf(barrel.global_basis.z.normalized().y) < 0.1,
			"Stationary must not expose the inactive deployed turret pose after %s"
				% animation_name
		)
	kobra.free()


## DeviateHit is a marker-only rig (see ImpactDebris) shared by ORDeviator's
## Deviate_B and ORGasTurret's Gas_B -- both resolve through the same effect
## id, so this one case covers the ImpactDebris fix for both units.
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
