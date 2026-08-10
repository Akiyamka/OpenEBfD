extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const ShotPayloadScript := preload("res://scripts/combat/shot_payload.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const ORMortarModelScene := preload("res://assets/converted/models/OR_Mortar_H0/OR_Mortar_H0.scn")
const HKInkVineModelScene := preload("res://assets/converted/models/HK_Inkvine_H0/HK_Inkvine_H0.scn")

var _bullets := Bullets.new()

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
func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("hitscan resolves at launch without travel", _test_hitscan_projectile)
	_run_case("non-homing bullets keep the sampled aim point", _test_linear_projectile_no_lead)
	_run_case("coordinate shots preserve parallel muzzle headings", _test_parallel_coordinate_shots)
	_run_case("attack-ground missiles descend to the sampled point", _test_attack_ground_missile)
	_run_case("homing respects delay, turn rate and target lifetime", _test_homing_projectile)
	_run_case("homing missiles may outfly their firing range while chasing", _test_homing_flight_budget)
	_run_case("trajectory bullets follow a gravity arc", _test_trajectory_projectile)
	_run_case("elevated-only trajectory mounts prefer the high ballistic arc", _test_elevated_trajectory_mounts)
	await _run_async_case("trajectory misses continue until contact instead of bursting in air", _test_trajectory_moving_target_miss)
	await _run_async_case("projectiles collide and Sonic pierces in 3D", _test_projectile_world_collision)
	await _run_async_case("flame streams pierce units and buildings but stop at walls", _test_continuous_stream_piercing)
	_run_case("a continuous stream's pulses split one clip's total damage evenly", _test_continuous_stream_damage_split)
	_finish("Projectile flight tests")

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


func _test_attack_ground_missile() -> void:
	var launch_position := Vector3(0.0, 2.0, 0.0)
	var ground_position := Vector3(0.0, 0.0, -10.0)
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	var emission := Bullets.emission(launch_position, Vector3.FORWARD)
	emission["target_direction"] = launch_position.direction_to(ground_position)
	_expect(
		projectile.launch(
			_bullets.runtime_bullet(&"HEAT_B"), emission, ground_position
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


func _test_parallel_coordinate_shots() -> void:
	var target_position := Vector3(0.0, 0.0, -10.0)
	var projectiles: Array = []
	for launch_position in [Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0)]:
		var projectile = CombatProjectileScript.new()
		root.add_child(projectile)
		_expect(
			projectile.launch(
				_bullets.runtime_bullet(&"HEAT_B"),
				Bullets.emission(launch_position, Vector3.FORWARD),
				target_position
			),
			"each offset muzzle must accept the same attack-ground coordinate"
		)
		projectiles.append(projectile)
	_expect(
		projectiles.size() == 2
		and projectiles[0].direction().dot(projectiles[1].direction()) > 0.99999,
		"coordinate shots must leave parallel barrels in parallel instead of converging"
	)
	for projectile in projectiles:
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








