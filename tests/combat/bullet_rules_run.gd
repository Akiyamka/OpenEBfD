extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatImpactResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")
const CombatLingerEffectScript := preload("res://scripts/combat/combat_linger_effect.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const UnitScript := preload("res://scripts/units/unit.gd")

var _bullets := Bullets.new()


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("warhead matrix scales bullet damage by target armour", _test_armour_matrix)
	_run_case("bullet targeting distinguishes ground and aircraft", _test_target_domains)
	_run_case("bullet rules expose physical delivery parameters", _test_bullet_delivery_rules)
	_run_case("impact effects use typed acceptance and fallback damage", _test_impact_effect_contract)
	_run_case("lingering gas delivers every authored damage tick", _test_lingering_gas_damage)
	_run_case("simultaneous projectiles retain independent damage scales", _test_projectile_damage_scale_isolation)
	await _run_async_case("impact resolution applies splash falloff and friendly fire", _test_impact_resolution)
	_run_case("units and buildings expose rules-backed combat armour", _test_combat_targets)
	_run_case("shields absorb resolved combat damage before health", _test_shield_absorption)
	_finish("Bullet rules tests")

func _test_armour_matrix() -> void:
	var bullet = CombatBulletScript.new(_bullets.bullet_config(&"LMG_B"), _bullets.warhead_config(&"LMG_W"))
	_expect(bullet.is_hitscan(), "LMG_B's negative conceptual speed must make it hitscan")
	_expect(is_equal_approx(bullet.base_damage(), 219.0), "LMG_B must retain its rules damage")
	_expect(
		is_equal_approx(bullet.damage_against(&"None"), 219.0),
		"LMG_W must deal 100% damage to None armour"
	)
	_expect(
		is_equal_approx(bullet.damage_against(&"Heavy"), 87.6),
		"LMG_W must deal 40% damage to Heavy armour"
	)
	_expect(bullet.warhead.id() == &"LMG_W", "the runtime Warhead must retain its rules id")
	var copied_matrix: Dictionary = bullet.warhead.armour_damage_matrix()
	copied_matrix["Heavy"] = 0.0
	_expect(
		is_equal_approx(bullet.warhead.damage_percent_for(&"Heavy"), 40.0),
		"callers must receive a copy rather than mutate the immutable armour matrix"
	)
	_expect(
		is_zero_approx(bullet.warhead.damage_percent_for(&"UnknownArmour")),
		"a missing warhead/armour pair must resolve to zero"
	)
	_expect(
		is_zero_approx(bullet.damage_against(&"Invulnerable")),
		"the zero matrix pair must deal no damage"
	)

	var heavy_target := Doubles.FakeCombatTarget.new(&"Heavy")
	var resolver = CombatImpactResolverScript.new()
	var results: Array[Dictionary] = resolver.resolve(
		bullet, null, Vector3.ZERO, heavy_target
	)
	_expect(
		results.size() == 1 and is_equal_approx(float(results[0]["damage"]), 87.6),
		"the impact resolver must report resolved post-armour damage"
	)
	_expect(
		is_equal_approx(heavy_target.damage_taken, 87.6),
		"impact must deliver the same resolved damage to the target"
	)

	var leech = CombatBulletScript.new(_bullets.bullet_config(&"Leech_B"), null)
	_expect(
		is_equal_approx(leech.damage_against(&"Heavy"), 100.0),
		"a special-effect bullet without a warhead must retain its direct fallback damage"
	)

func _test_target_domains() -> void:
	var lmg = CombatBulletScript.new(_bullets.bullet_config(&"LMG_B"), _bullets.warhead_config(&"LMG_W"))
	var aircraft := Doubles.FakeCombatTarget.new(&"Aircraft", true)
	_expect(not lmg.can_hit(aircraft), "a bullet without AntiAircraft must reject aircraft")
	_expect(lmg.can_hit_ground(), "an ordinary ground weapon must accept attack-ground")
	_expect(
		CombatImpactResolverScript.new().resolve(lmg, null, Vector3.ZERO, aircraft).is_empty(),
		"a rejected aircraft impact must resolve no target"
	)

	var adp_config: Resource = _bullets.bullet_config(&"ATHEATADP_B")
	var adp = CombatBulletScript.new(
		adp_config,
		_bullets.warhead_config(adp_config.warhead_id)
	)
	_expect(adp.can_hit(aircraft), "ATHEATADP_B must accept aircraft")
	_expect(
		not adp.can_hit(Doubles.FakeCombatTarget.new(&"Heavy")),
		"ATHEATADP_B's explicit AntiGround=false must reject ground targets"
	)
	_expect(not adp.can_hit_ground(), "an air-only weapon must reject attack-ground coordinates")
	var rejected_projectile = CombatProjectileScript.new()
	root.add_child(rejected_projectile)
	_expect(
		not rejected_projectile.launch(
			lmg, Bullets.emission(Vector3.ZERO, Vector3.FORWARD), aircraft
		),
		"a projectile must reject an incompatible target before entering flight"
	)
	rejected_projectile.free()

func _test_bullet_delivery_rules() -> void:
	var lmg = _bullets.runtime_bullet(&"LMG_B")
	_expect(is_equal_approx(lmg.maximum_range(), 5.0), "LMG_B must retain its five-tile rule range")
	_expect(
		is_equal_approx(lmg.maximum_range_world(), 10.0),
		"five source range tiles must convert to ten world units"
	)
	_expect(lmg.is_hitscan(), "negative Speed, rather than IsLaser, must define hitscan")
	_expect(not lmg.is_laser(), "an ordinary conceptual firearm must not become a laser")

	var adp = _bullets.runtime_bullet(&"HEATADP_B")
	_expect(adp.is_homing(), "HEATADP_B must expose its Homing flag")
	_expect(is_equal_approx(adp.homing_delay_ticks(), 5.0), "HomingDelay must remain in rule ticks")
	_expect(is_equal_approx(adp.turn_rate(), 0.9), "TurnRate must remain radians per update")
	_expect(not adp.can_reach(Vector3.ZERO, Vector3.FORWARD * 19.9), "MinRange=10 tiles must reject a nearer launch")
	_expect(adp.can_reach(Vector3.ZERO, Vector3.FORWARD * 20.0), "the exact minimum range must be accepted")
	_expect(adp.can_reach(Vector3.ZERO, Vector3.FORWARD * 30.0), "the exact maximum range must be accepted")
	_expect(not adp.can_reach(Vector3.ZERO, Vector3.FORWARD * 30.1), "a target beyond MaxRange must be rejected")

	var sonic = _bullets.runtime_bullet(&"Sound_B")
	var flame = _bullets.runtime_bullet(&"Flame_B")
	_expect(sonic.is_continuous() and sonic.is_piercing(), "the Sonic wave must retain continuous piercing delivery")
	_expect(flame.is_continuous() and not flame.is_piercing(), "Continuous alone must not make flame pass through walls")
	var mortar = _bullets.runtime_bullet(&"Mortar_B")
	_expect(is_equal_approx(mortar.blast_radius_world(), 4.0), "BlastRadius=64 must convert from XBF to four world units")
	_expect(is_equal_approx(mortar.friendly_damage_amount(), 50.0), "friendly splash amount must remain a percentage")
	_expect(mortar.explosion_type() == &"ShellHit", "the bullet must retain its explosion presentation id")
	_expect(mortar.explosion_effects() == ["ShellHit"], "all normalized explosion effects must stay available")
	_expect(
		is_equal_approx(mortar.damage_to_tile(), 30.0),
		"ShellHit must retain its original DamageToTile crater strength"
	)
	var kobra_shell = _bullets.runtime_bullet(&"KobraHowitzer_B")
	_expect(
		kobra_shell.has_missile_trail()
		and kobra_shell.missile_trail_style() == 6
		and is_equal_approx(kobra_shell.missile_trail_size(), 2.0)
		and kobra_shell.missile_trail_length() == 8
		and is_equal_approx(kobra_shell.missile_trail_delta(), 0.7),
		"KobraHowitzer_B must expose its complete authored trail dimensions"
	)
	_expect(_bullets.runtime_bullet(&"Leech_B").effect_flags().has("leech"), "special delivery flags must remain owned by Bullet")
	_expect(
		_bullets.runtime_bullet(&"BarrelBomb").reduces_damage_with_distance(),
		"omitted ReduceDamageWithDistance must keep the source default falloff"
	)
	_expect(
		not mortar.reduces_damage_with_distance(),
		"an explicit ReduceDamageWithDistance=False must disable falloff"
	)

func _test_impact_effect_contract() -> void:
	var leech = _bullets.runtime_bullet(&"Leech_B")
	var resolver = CombatImpactResolverScript.new()
	var vehicle := Doubles.FakeCombatTarget.new(&"Heavy")
	vehicle.accepted_effects.append(&"leech")
	var accepted: Array[Dictionary] = resolver.resolve(
		leech, null, Vector3.ZERO, vehicle, Doubles.CombatSource.new()
	)
	_expect(accepted.size() == 1, "an effect-capable direct target must resolve")
	_expect(&"leech" in accepted[0]["effects"], "the target must acknowledge its typed effect")
	_expect(
		is_zero_approx(vehicle.damage_taken),
		"an accepted infection must suppress the no-warhead fallback damage"
	)
	_expect(
		vehicle.received_effect_contexts.size() == 1
		and is_equal_approx(float(vehicle.received_effect_contexts[0]["effect_health"]), 200.0)
		and is_equal_approx(float(vehicle.received_effect_contexts[0]["effect_damage_per_tick"]), 2.0),
		"the resolver must pass infection parameters to the typed effect receiver"
	)

	var rejected := Doubles.FakeCombatTarget.new(&"Heavy")
	var fallback: Array[Dictionary] = resolver.resolve(
		leech, null, Vector3.ZERO, rejected, Doubles.CombatSource.new()
	)
	_expect(fallback.size() == 1 and fallback[0]["effects"].is_empty(), "a rejected effect must be reported")
	_expect(
		is_equal_approx(rejected.damage_taken, 100.0),
		"Leech_B Damage must be used when the target cannot receive infection"
	)

func _test_lingering_gas_damage() -> void:
	var gas = _bullets.runtime_bullet(&"GasInf_B")
	var impact_target := Doubles.FakeCombatTarget.new(&"BPV")
	var projectile = CombatProjectileScript.new()
	root.add_child(projectile)
	projectile.bullet = gas
	projectile._resolve_impact(impact_target, Vector3.ZERO)
	var spawned_linger: Node = null
	for child in root.get_children():
		if child.get_meta("combat_linger_effect", &"") == &"GasInf_B":
			spawned_linger = child
			break
	_expect(
		spawned_linger != null
		and is_equal_approx(impact_target.damage_taken, 200.0),
		"a GasInf_B impact must apply its direct payload and spawn the lingering effect"
	)
	if spawned_linger != null:
		spawned_linger.free()
	projectile.free()

	var target := Doubles.FakeCombatTarget.new(&"BPV")
	var effect = CombatLingerEffectScript.new()
	root.add_child(effect)
	_expect(
		effect.configure(gas, target, Vector3.ZERO),
		"GasInf_B must create a target-bound lingering payload"
	)
	effect.set_physics_process(false)
	for tick in 49:
		effect._physics_process(
			1.0 / CombatLingerEffectScript.RULE_COMBAT_TICKS_PER_SECOND
		)
	_expect(
		effect.delivered_ticks == 49
		and is_equal_approx(target.damage_taken, 392.0)
		and not effect.is_queued_for_deletion(),
		"49 gas ticks must deliver 10 damage through Flame_W's 80% BPV multiplier"
	)
	effect._physics_process(
		1.0 / CombatLingerEffectScript.RULE_COMBAT_TICKS_PER_SECOND
	)
	_expect(
		effect.delivered_ticks == 50
		and is_equal_approx(target.damage_taken, 400.0)
		and effect.is_queued_for_deletion(),
		"GasInf_B must stop after all 50 authored linger ticks"
	)

func _test_projectile_damage_scale_isolation() -> void:
	var turret = CombatTurretScript.new()
	_expect(
		turret.configure(&"ATInfGun"),
		"the isolation fixture must configure one real turret"
	)
	var first_shot: Array = turret.try_fire(false, false, 0.25)
	var second_shot: Array = turret.try_fire(false, false, 1.75)
	_expect(
		first_shot.size() == 1 and second_shot.size() == 1,
		"one configured turret must emit both scaled shots"
	)
	var first_payload = first_shot[0]
	var second_payload = second_shot[0]
	_expect(
		first_payload != second_payload
		and is_equal_approx(first_payload.damage_scale, 0.25)
		and is_equal_approx(second_payload.damage_scale, 1.75),
		"each turret shot must receive its own mutable payload"
	)
	var first_target := Doubles.PhysicsCombatTarget.new(Vector3.ZERO)
	var second_target := Doubles.PhysicsCombatTarget.new(Vector3.ZERO)
	root.add_child(first_target)
	root.add_child(second_target)
	var resolver = CombatImpactResolverScript.new()
	resolver.resolve(first_payload, first_target, Vector3.ZERO, first_target)
	resolver.resolve(second_payload, second_target, Vector3.ZERO, second_target)
	_expect(
		is_equal_approx(first_target.damage_taken, first_payload.damage_against(&"None"))
		and is_equal_approx(second_target.damage_taken, second_payload.damage_against(&"None"))
		and second_target.damage_taken > first_target.damage_taken,
		"each payload scale must survive through actual impact damage"
	)
	first_target.free()
	second_target.free()

func _test_impact_resolution() -> void:
	var source := Doubles.CombatSource.new()
	var direct := Doubles.PhysicsCombatTarget.new(Vector3.ZERO)
	var ally := Doubles.PhysicsCombatTarget.new(Vector3(2.0, 0.0, 0.0))
	ally.owner_player_id = source.owner_player_id
	var enemy := Doubles.PhysicsCombatTarget.new(Vector3(3.5, 0.0, 0.0))
	var outside := Doubles.PhysicsCombatTarget.new(Vector3(5.0, 0.0, 0.0))
	root.add_child(direct)
	root.add_child(ally)
	root.add_child(enemy)
	root.add_child(outside)
	await physics_frame

	var resolver = CombatImpactResolverScript.new()
	var mortar = _bullets.runtime_bullet(&"Mortar_B")
	var results: Array[Dictionary] = resolver.resolve(
		mortar, direct, Vector3.ZERO, direct, source
	)
	_expect(results.size() == 3, "the direct target and two colliders inside four world units must resolve")
	_expect(
		is_equal_approx(direct.damage_taken, mortar.damage_against(&"None")),
		"a direct target must receive full post-armour damage exactly once"
	)
	_expect(
		is_equal_approx(ally.damage_taken, mortar.damage_against(&"None") * 0.5),
		"FriendlyDamageAmount=50 must halve allied splash"
	)
	_expect(
		is_equal_approx(enemy.damage_taken, mortar.damage_against(&"None")),
		"explicitly disabled distance reduction must keep enemy splash at full damage"
	)
	_expect(is_zero_approx(outside.damage_taken), "a collider outside BlastRadius must remain untouched")

	var shooter := Doubles.PhysicsCombatTarget.new(Vector3(0.01, 0.0, 0.0))
	shooter.owner_player_id = source.owner_player_id
	root.add_child(shooter)
	await physics_frame
	resolver.resolve(mortar, shooter, Vector3.ZERO, direct, shooter)
	_expect(
		is_zero_approx(shooter.damage_taken),
		"a shooter standing point-blank against an obstacle must never catch its own splash"
	)
	shooter.free()

	ally.damage_taken = 0.0
	var heat = _bullets.runtime_bullet(&"HEAT_B")
	var direct_friendly_results: Array[Dictionary] = resolver.resolve(
		heat, ally, ally.global_position, ally, source
	)
	_expect(
		is_equal_approx(ally.damage_taken, heat.damage_against(&"None")),
		"an explicitly selected allied direct target must receive full weapon damage"
	)
	_expect(
		direct_friendly_results.size() == 1 \
			and is_equal_approx(float(direct_friendly_results[0]["friendly_multiplier"]), 1.0),
		"FriendlyDamageAmount must not suppress a deliberate direct hit"
	)

	# The same body struck en route -- a squadmate stepping onto the flight path
	# of a round meant for something else -- is incidental, and takes the
	# FriendlyDamageAmount share rather than the full round.
	ally.damage_taken = 0.0
	resolver.resolve(heat, ally, ally.global_position, ally, source, 1.0, false)
	_expect(
		is_zero_approx(ally.damage_taken),
		"HEAT_B's FriendlyDamageAmount=0 must zero an incidental hit on a squadmate"
	)
	ally.damage_taken = 0.0
	var incidental_results: Array[Dictionary] = resolver.resolve(
		mortar, ally, ally.global_position, ally, source, 1.0, false
	)
	_expect(
		incidental_results.size() >= 1 \
			and is_equal_approx(float(incidental_results[0]["friendly_multiplier"]), 0.5),
		"Mortar_B's FriendlyDamageAmount=50 must halve an incidental squadmate hit"
	)
	enemy.damage_taken = 0.0
	resolver.resolve(mortar, enemy, enemy.global_position, enemy, source, 1.0, false)
	_expect(
		is_equal_approx(enemy.damage_taken, mortar.damage_against(&"None")),
		"an enemy body struck en route must still take the full round"
	)

	direct.damage_taken = 0.0
	ally.damage_taken = 0.0
	enemy.damage_taken = 0.0
	outside.damage_taken = 0.0
	var barrel_bomb = _bullets.runtime_bullet(&"BarrelBomb")
	resolver.resolve(barrel_bomb, direct, Vector3.ZERO, null, null)
	var enemy_surface_distance: float = enemy.global_position.length() - enemy.hit_radius
	var expected_falloff: float = (
		1.0 - enemy_surface_distance / float(barrel_bomb.blast_radius_world())
	)
	_expect(
		is_equal_approx(
			enemy.damage_taken,
			barrel_bomb.damage_against(&"None") * expected_falloff
		),
		"default radial damage must fall linearly from collider surface to blast edge"
	)

	direct.free()
	ally.free()
	enemy.free()
	outside.free()

func _test_combat_targets() -> void:
	var rules = root.get_node("Rules")
	_expect(
		StringName(String(rules.unit(&"ATInfantry").field(&"armour_type", ""))) == &"None",
		"unit armour must remain available to combat"
	)
	_expect(
		StringName(String(rules.building(&"ATConYard").field(&"armour_type", ""))) == &"CY",
		"Construction Yard armour must be exported from Rules.txt"
	)
	_expect(
		StringName(String(rules.building(&"ATBarracks").field(&"armour_type", ""))) == &"Building",
		"ordinary building armour must be exported from Rules.txt"
	)
	for config in rules.all(&"building"):
		_expect(
			not String(config.field(&"armour_type", "")).is_empty(),
			"every building must expose an armour type (%s)" % String(config.id)
		)

func _test_shield_absorption() -> void:
	var unit = UnitScript.new()
	unit.max_health = 500.0
	unit.max_shields = 100.0
	unit.health = 500.0
	unit.shields = 100.0
	unit.take_damage(60.0)
	_expect(is_equal_approx(unit.shields, 40.0), "shields must absorb incoming damage first")
	_expect(is_equal_approx(unit.health, 500.0), "fully absorbed damage must not reach health")
	unit.take_damage(100.0)
	_expect(is_zero_approx(unit.shields), "a larger hit must deplete the remaining shield")
	_expect(is_equal_approx(unit.health, 440.0), "only spillover damage must reduce health")
	unit.free()
