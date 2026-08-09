extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const HKTrooperModelScene := preload(
	"res://assets/converted/models/HK_Trooper_H0/HK_Trooper_H0.scn"
)
const HKGunTurretScene := preload(
	"res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn"
)
const HKStarportScene := preload(
	"res://assets/converted/buildings/HKStarport/HKStarport.scn"
)

var _bullets := Bullets.new()


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
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
	_finish("Building geometry tests")


func _run_case(case_name: String, test: Callable) -> void:
	var children_before := _root_children_snapshot()
	super._run_case(case_name, test)
	_free_case_children(children_before)


func _run_async_case(case_name: String, test: Callable) -> void:
	var children_before := _root_children_snapshot()
	await super._run_async_case(case_name, test)
	_free_case_children(children_before)


func _root_children_snapshot() -> Array[Node]:
	var children: Array[Node] = []
	for child in root.get_children():
		children.append(child)
	return children


func _free_case_children(children_before: Array[Node]) -> void:
	for child in root.get_children():
		if not children_before.has(child):
			child.free()


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
