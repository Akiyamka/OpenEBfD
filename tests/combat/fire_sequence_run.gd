extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const HKMissileModelScene := preload(
	"res://assets/converted/models/HK_missile_H0/HK_missile_H0.scn"
)
const HKDevastatorModelScene := preload(
	"res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn"
)
const HKFlamerModelScene := preload(
	"res://assets/converted/models/HK_Flamer_H0/HK_Flamer_H0.scn"
)
const HKFlameModelScene := preload(
	"res://assets/converted/models/HK_flame_H0/HK_flame_H0.scn"
)
const ORAATrooperModelScene := preload(
	"res://assets/converted/models/OR_AATrooper_H0/OR_AATrooper_H0.scn"
)
const ORAPCModelScene := preload("res://assets/converted/models/Or_apc_H0/Or_apc_H0.scn")

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	_run_case("XBF fire events delay infantry projectiles", _test_xbf_fire_event_timing)
	_run_case("launcher fire clips schedule every projectile before reload", _test_launcher_fire_sequences)
	_run_case("continuous flame clips schedule every stream pulse", _test_continuous_flame_sequences)
	_finish("Fire sequence tests")

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
	# The shot-event timing this regression pins is exact (15/20 clip seconds
	# at the 25/20 Fire_0 playback speed = 0.6s), unrelated to the tick rate --
	# call the simulation function directly with those deltas rather than
	# through the fixed-tick Unit.sim_tick_combat().
	trooper.combat().advance(0.59)
	_expect(
		fired.is_empty(),
		"ORAATrooper must not launch before the authored firing pose"
	)
	trooper.combat().advance(0.02)
	_expect(
		fired.size() == 1,
		"ORAATrooper must launch when Fire_0 reaches its type-10 event"
	)
	trooper.free()

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
