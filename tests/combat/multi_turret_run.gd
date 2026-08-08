extends SceneTree

## A unit that carries more than one weapon has to use all of them. The cases
## here cover the three ways that used to fail on the Devastator, which pairs a
## plasma gun bolted straight to the hull with a missile turret that has a
## +/-190 degree servo of its own: the servo turret always bearing meant the
## hull never turned for the gun, the longest arm reaching first meant the unit
## stopped before its shorter one could join, and an order the gun could not
## take part in left it idle rather than hunting.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const HKDevastatorModelScene := preload(
	"res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn"
)
const IMAdvSardaukarModelScene := preload(
	"res://assets/converted/models/IM_ADVSardaukar_H0/IM_ADVSardaukar_H0.scn"
)

var _assertions := 0
var _failures := 0
var _current_case := ""


class FakeCombatTarget extends RefCounted:
	var armour_type: StringName
	var airborne := false
	var position := Vector3.ZERO
	var owner_player_id := 2

	func _init(target_armour: StringName, target_airborne := false) -> void:
		armour_type = target_armour
		airborne = target_airborne

	func combat_armour_type() -> StringName:
		return armour_type

	func combat_is_airborne() -> bool:
		return airborne

	func combat_aim_position() -> Vector3:
		return position

	func combat_is_alive() -> bool:
		return true

	func combat_hit_radius() -> float:
		return 0.25

	func is_enemy_of(player_id: int) -> bool:
		return owner_player_id != player_id

	func combat_owner_player_id() -> int:
		return owner_player_id

	func take_damage(_amount: float, _death_cause: StringName = &"") -> void:
		pass


class PhysicsCombatTarget extends StaticBody3D:
	var owner_player_id := 2

	func _init(world_position: Vector3, radius := 0.5) -> void:
		position = world_position
		collision_layer = 2
		collision_mask = 0
		var collision := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		collision.shape = sphere
		add_child(collision)

	func combat_armour_type() -> StringName:
		return &"None"

	func combat_is_airborne() -> bool:
		return false

	func combat_aim_position() -> Vector3:
		return global_position

	func combat_is_alive() -> bool:
		return true

	func combat_hit_radius() -> float:
		return 0.5

	func is_enemy_of(player_id: int) -> bool:
		return owner_player_id != player_id

	func combat_owner_player_id() -> int:
		return owner_player_id

	func take_damage(_amount: float, _death_cause: StringName = &"") -> void:
		pass


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case(
		"a hull-mounted weapon fires alongside its unit's own turret",
		_test_devastator_combined_salvo
	)
	_run_case(
		"attack pursuit closes to the shortest-ranged weapon that can engage",
		_test_pursuit_range_uses_shortest_usable_weapon
	)
	_run_case(
		"a weapon the order is not for keeps hunting on its own",
		_test_idle_turret_engages_during_attack_order
	)
	if _failures > 0:
		printerr(
			"Multi-turret tests: %d failures after %d assertions"
				% [_failures, _assertions]
		)
		quit(1)
		return
	print("Multi-turret tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	test.call()
	# A runtime error aborts the case function where it stands, which would
	# otherwise read as a silent pass.
	if _assertions == assertions_before:
		_failures += 1
		printerr("FAIL: %s: the case ended before asserting anything" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


## The Devastator carries one weapon of each kind: a plasma gun bolted to the
## hull (TurretYRotationAngle 0) and a missile turret with a +/-190 degree
## servo. The missile turret can always bear on its own, which must not become
## the reason the hull never turns and the plasma never fires.
func _test_devastator_combined_salvo() -> void:
	var devastator = UnitScene.instantiate()
	devastator.config_id = &"HKDevastator"
	root.add_child(devastator)
	devastator.replace_visual_scene(HKDevastatorModelScene)
	var gun = devastator.combat_turrets[0]
	var missile = devastator.combat_turrets[1]
	_expect(
		gun.requires_hull_turn(),
		"the Devastator plasma gun must aim only by turning the whole unit"
	)
	_expect(
		not missile.requires_hull_turn(),
		"the Devastator missile turret must carry a yaw servo of its own"
	)

	var forward: Vector3 = devastator.facing_direction()
	forward.y = 0.0
	forward = forward.normalized()
	var target := FakeCombatTarget.new(&"None")
	target.position = devastator.global_position \
		+ forward.rotated(Vector3.UP, deg_to_rad(60.0)) * 12.0
	target.position.y = Vector3(gun.peek_emission()["position"]).y
	_expect(
		not missile.requires_hull_turn_for(target.position),
		"the missile servo must already cover a target 60 degrees off the bow"
	)

	var fired_weapons: Dictionary = {}
	var fired: Array = []
	devastator.weapon_fired.connect(func(
		projectiles: Array, _target: Variant, weapon_index: int
		) -> void:
		fired_weapons[weapon_index] = true
		fired.append_array(projectiles)
	)
	_expect(
		devastator.command_attack(target),
		"the Devastator must accept a target both weapons can reach"
	)
	for frame in 900:
		devastator._process(1.0 / 60.0)
		devastator._physics_process(1.0 / 60.0)
		if fired_weapons.has(0) and fired_weapons.has(1):
			break
	_expect(fired_weapons.has(1), "the missile turret must engage the commanded target")
	_expect(
		fired_weapons.has(0),
		"the hull-mounted plasma gun must engage the same target instead of idling"
	)
	var bearing := _horizontal_angle_between(
		devastator.facing_direction(), target.position - devastator.global_position
	)
	_expect(
		absf(bearing) < deg_to_rad(5.0),
		"the hull must have turned onto the target so its fixed gun can bear"
	)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	_free_muzzle_effects()
	devastator.free()


## Stopping the moment the longest arm reaches leaves the shorter one idle, so
## the approach is measured by the shortest range -- but only across weapons the
## order can actually use, and never by a melee weapon.
func _test_pursuit_range_uses_shortest_usable_weapon() -> void:
	var devastator = UnitScene.instantiate()
	devastator.config_id = &"HKDevastator"
	root.add_child(devastator)
	devastator.replace_visual_scene(HKDevastatorModelScene)
	var gun = devastator.combat_turrets[0]
	var missile = devastator.combat_turrets[1]
	_expect(
		missile.maximum_range_world() < gun.maximum_range_world(),
		"the Devastator missiles must be the shorter ranged of its two weapons"
	)

	var forward: Vector3 = devastator.facing_direction()
	forward.y = 0.0
	forward = forward.normalized()
	var stand_off: float = (
		gun.maximum_range_world() + missile.maximum_range_world()
	) * 0.5
	var target = PhysicsCombatTarget.new(
		devastator.global_position + forward * stand_off
	)
	root.add_child(target)
	_expect(
		gun.target_range(target) == CombatTurretScript.TargetRange.IN_RANGE
		and missile.target_range(target) == CombatTurretScript.TargetRange.TOO_FAR,
		"the regression must begin where only the longer ranged weapon reaches"
	)
	_expect(
		devastator.combat()._pursuit_attack_turret(target) == missile,
		"the shortest ranged weapon that can engage must set the approach distance"
	)

	var fired_weapons: Dictionary = {}
	var fired: Array = []
	devastator.weapon_fired.connect(func(
		projectiles: Array, _target: Variant, weapon_index: int
		) -> void:
		fired_weapons[weapon_index] = true
		fired.append_array(projectiles)
	)
	_expect(devastator.command_attack(target), "the Devastator must accept the target")
	for frame in 1800:
		devastator._process(1.0 / 60.0)
		devastator._physics_process(1.0 / 60.0)
		if fired_weapons.has(0) and fired_weapons.has(1):
			break
	_expect(
		missile.target_range(target) == CombatTurretScript.TargetRange.IN_RANGE,
		"the Devastator must keep closing until its missiles reach as well"
	)
	_expect(
		fired_weapons.has(0) and fired_weapons.has(1),
		"both weapons must fire once the unit has closed"
	)

	var sardaukar = UnitScene.instantiate()
	sardaukar.config_id = &"IMADVSardaukar"
	root.add_child(sardaukar)
	sardaukar.replace_visual_scene(IMAdvSardaukarModelScene)
	var rifle = sardaukar.combat_turrets[0]
	var knife = sardaukar.combat_turrets[1]
	var knife_victim = PhysicsCombatTarget.new(
		sardaukar.global_position + forward * (rifle.maximum_range_world() * 0.9)
	)
	root.add_child(knife_victim)
	_expect(
		knife.maximum_range_world() < rifle.maximum_range_world(),
		"the Sardaukar knife must be the shorter ranged of his two weapons"
	)
	_expect(
		sardaukar.combat()._pursuit_attack_turret(knife_victim) == rifle,
		"a melee weapon must never march its owner out of rifle range"
	)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	_free_muzzle_effects()
	knife_victim.free()
	sardaukar.free()
	target.free()
	devastator.free()


## An order on an aircraft is not an order for the anti-ground gun to stand
## down: it hunts for itself, and takes the hull with it while nothing about the
## order needs it.
func _test_idle_turret_engages_during_attack_order() -> void:
	var devastator = UnitScene.instantiate()
	devastator.config_id = &"HKDevastator"
	root.add_child(devastator)
	devastator.replace_visual_scene(HKDevastatorModelScene)
	var gun = devastator.combat_turrets[0]
	var missile = devastator.combat_turrets[1]

	var forward: Vector3 = devastator.facing_direction()
	forward.y = 0.0
	forward = forward.normalized()
	var aircraft := FakeCombatTarget.new(&"None", true)
	aircraft.position = devastator.global_position \
		+ forward.rotated(Vector3.UP, deg_to_rad(90.0)) * 10.0
	aircraft.position.y = devastator.global_position.y + 8.0
	_expect(
		not gun.can_target(aircraft),
		"DevPlasma_B is anti-ground only and must not be offered an aircraft"
	)
	_expect(missile.can_target(aircraft), "DevRocket_B must accept an aircraft")

	var ground_enemy = PhysicsCombatTarget.new(
		devastator.global_position + forward.rotated(Vector3.UP, deg_to_rad(-30.0)) * 10.0
	)
	root.add_child(ground_enemy)
	ground_enemy.add_to_group(&"units")

	var fired_targets: Dictionary = {}
	var fired: Array = []
	devastator.weapon_fired.connect(func(
		projectiles: Array, weapon_target: Variant, weapon_index: int
		) -> void:
		fired_targets[weapon_index] = weapon_target
		fired.append_array(projectiles)
	)
	_expect(devastator.command_attack(aircraft), "the Devastator must accept the aircraft")
	for frame in 1200:
		devastator._process(1.0 / 60.0)
		devastator._physics_process(1.0 / 60.0)
		if fired_targets.has(0) and fired_targets.has(1):
			break
	_expect(
		fired_targets.get(1) == aircraft,
		"the missile turret must shoot the commanded aircraft"
	)
	_expect(
		fired_targets.get(0) == ground_enemy,
		"the grounded plasma gun must pick its own target instead of standing down"
	)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	_free_muzzle_effects()
	ground_enemy.free()
	devastator.free()



func _horizontal_angle_between(a: Vector3, b: Vector3) -> float:
	var a_horizontal := Vector2(a.x, a.z)
	var b_horizontal := Vector2(b.x, b.z)
	if a_horizontal.is_zero_approx() or b_horizontal.is_zero_approx():
		return 0.0
	return absf(angle_difference(a_horizontal.angle(), b_horizontal.angle()))


func _free_muzzle_effects() -> void:
	for child in root.get_children():
		if child.has_meta("combat_muzzle_fx"):
			child.free()


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
