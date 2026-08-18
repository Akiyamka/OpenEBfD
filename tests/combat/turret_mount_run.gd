extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Fx := preload("res://tests/combat/support/combat_fx_probe.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATAPCModelScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const ATMinotaurusModelScene := preload(
	"res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn"
)
const ORLaserTankModelScene := preload(
	"res://assets/converted/models/OR_Lasertank_H0/OR_Lasertank_H0.scn"
)

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("turret emits bursts and reloads in rule ticks", _test_turret_reload)
	_run_case("turret FX ownership does not retain its turret", _test_turret_fx_ownership)
	_run_case(
		"continuous turrets burst then reload for equal ReloadCount windows",
		_test_continuous_turret_burst_reload
	)
	_run_case("compound turret binds authored pivots and muzzle", _test_compound_turret)
	_run_case("single-axis turret turns without changing pitch", _test_single_axis_turret)
	_run_case("fixed weapon keeps its authored direction", _test_fixed_turret)
	_run_case("multi-barrel turret cycles authored muzzles", _test_multi_barrel_turret)
	_run_case("trajectory barrels fire a parallel salvo", _test_parallel_trajectory_salvo)
	_run_case("limited turret turns its hull toward rear targets", _test_limited_turret_hull_turn)
	_finish("Turret mount tests")

## CombatTurret.advance_tick() moves reload/burst countdowns by exactly one
## combat tick (see its doc comment) -- this suite's fixed counts of 29/30
## ticks read clearer as a call count than as an unrolled loop at each site.
func _advance_ticks(turret: CombatTurretScript, count: int) -> void:
	for _tick in count:
		turret.advance_tick()

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
	_advance_ticks(turret, 29)
	_expect(not turret.is_ready(), "the turret must remain locked one tick before reload completes")
	_advance_ticks(turret, 1)
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

func _test_turret_fx_ownership() -> void:
	var turret = CombatTurretScript.new()
	_expect(turret.configure(&"ATInfGun"), "the lifetime fixture must configure")
	var turret_ref: WeakRef = weakref(turret)
	turret = null
	_expect(
		turret_ref.get_ref() == null,
		"the FX module must not keep its RefCounted turret owner alive"
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
	_advance_ticks(turret, 29)
	_expect(
		turret.continuous_burst_active(),
		"the burst window must still be open one tick before it elapses"
	)
	_expect(
		turret.is_ready(),
		"a turret mid-burst must not have started its post-burst reload yet"
	)

	_advance_ticks(turret, 1)
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

	_advance_ticks(turret, 29)
	_expect(not turret.is_ready(), "the cooldown must remain locked one tick early")
	_advance_ticks(turret, 1)
	_expect(turret.is_ready(), "the turret must become ready once the cooldown elapses")

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
