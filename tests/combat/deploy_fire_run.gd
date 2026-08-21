extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ORMortarModelScene := preload(
	"res://assets/converted/models/OR_Mortar_H0/OR_Mortar_H0.scn"
)
const ATKindjalModelScene := preload(
	"res://assets/converted/models/AT_Kindjal_H0/AT_Kindjal_H0.scn"
)
const ORKobraModelScene := preload(
	"res://assets/converted/models/OR_Kobra_H0/OR_Kobra_H0.scn"
)

var _bullets := Bullets.new()


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case(
		"the undeployed Kobra's shell leaves its muzzle",
		_test_undeployed_kobra_shell_leaves_the_muzzle
	)
	_run_case(
		"a deployed Mortar launches its projectile on the high ballistic arc",
		_test_deployed_mortar_high_arc
	)
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
	_finish("Deploy fire tests")

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
		# Unit._process() no longer advances target acquisition, attack
		# orders or fire sequences -- B3c moved that onto
		# Unit.sim_tick_combat(), Match's second pass over the "units" group.
		# No Match here, so drive it by hand.
		mortar.sim_tick_combat()
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
		# See _test_deployed_mortar_high_arc's identical comment above.
		kindjal.sim_tick_combat()
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
	var deployed_turret = active_turrets[0]
	_expect(
		is_equal_approx(
			rad_to_deg(deployed_turret._yaw_turn_speed(deployed_turret._yaw_config())),
			4.0
		),
		"a deployed Kobra must use only its authored 4-degree turret rate"
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
		# See _test_deployed_mortar_high_arc's identical comment above.
		kobra.sim_tick_combat()
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
