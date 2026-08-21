extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const FrameTickDriverScript := preload("res://scripts/match/frame_tick_driver.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const SimTickPumpScript := preload("res://tests/combat/support/sim_tick_pump.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Assertions := preload("res://tests/combat/support/combat_assertions.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATAPCModelScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const ATMongooseModelScene := preload("res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn")
const ATMinotaurusModelScene := preload("res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn")
const HKInkVineModelScene := preload("res://assets/converted/models/HK_Inkvine_H0/HK_Inkvine_H0.scn")


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
	await physics_frame
	_run_case("unit attack orders validate targets, fire, and pursue", _test_unit_attack_order)
	_run_case("Ink Vine repeats fire while its attack order remains active", _test_ink_vine_refire)
	_run_case("attack pursuit backs rejected firing positions toward the unit", _test_rejected_attack_perch)
	_run_case("pursuit enters a stable firing range", _test_far_attack_pursuit)
	await _run_async_case(
		"an obstructed in-range order repositions instead of shooting the obstacle",
		_test_obstructed_attack_order
	)
	await _run_async_case(
		"a squadmate on the muzzle line holds the shot and moves the unit off it",
		_test_friendly_on_the_line_holds_fire
	)
	await _run_async_case(
		"a squadmate arriving mid-clip cancels the shot at the muzzle",
		_test_friendly_arriving_mid_clip_cancels_the_shot
	)
	await _run_async_case(
		"the muzzle gate checks the line the round actually flies",
		_test_friendly_on_the_flown_line_holds_fire
	)
	_run_case(
		"an intermittently blocked line still reaches the reposition",
		_test_flickering_block_still_repositions
	)
	_finish("Unit attack order tests")

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
		# Unit._process() no longer advances target acquisition, attack
		# orders or fire sequences -- B3c moved that onto
		# Unit.sim_tick_combat(), Match's second pass over the "units" group.
		# No Match here, so drive it by hand.
		unit.sim_tick_combat()
		if not fired_batches.is_empty():
			break
	_expect(fired_batches.size() == 1, "an aimed in-range order must fire the compatible weapon")
	if not fired_batches.is_empty():
		_expect(fired_batches[0]["target"] == target, "the fired batch must retain the ordered target")
		_expect(fired_batches[0]["weapon_index"] == 0, "the primary APC weapon must execute the order")

	unit.cancel_attack_order()
	var far_ground := Vector3(emission["position"]) + direction * 30.0
	_expect(unit.command_attack(far_ground), "attack-ground validity must not depend on current range")
	# Attack pursuit is simulation state advanced by Unit.sim_tick_combat()
	# (B3c), not by _process() -- one tick is enough to prove partial
	# progress toward the far perch.
	unit.sim_tick_combat()
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
	var mongoose_pump := SimTickPumpScript.new()
	for frame in 240:
		mongoose_pump.advance(mongoose, 1.0 / 60.0)
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
	# begin_reload() and this weapon's first shot event now both land inside
	# the same simulation tick (Mongoose's Fire_0 shot event is authored
	# within its first baked frame, and B3c moved fire-sequence progression
	# onto the tick, which advances the clip by exactly one baked frame per
	# tick -- see FIRE_ANIMATION_SPEED_SCALE), so reload_ticks_remaining reads
	# a freshly-set 30.0 at the exact instant of the shot, before
	# CombatTurret.advance_tick() gets another chance to decrement it. That is
	# not "reload deferred" (see the un-concurrent ATInfantry case below, where
	# reload stays at exactly 0.0 through the whole clip instead) -- it is
	# simply that no tick has elapsed yet since the countdown began this same
	# tick. One more simulation tick, still well inside the clip, is enough to
	# observe the countdown actually running.
	mongoose.sim_tick()
	_expect(
		mongoose.combat_turrets[0].reload_ticks_remaining > 0.0
		and mongoose.combat_turrets[0].reload_ticks_remaining < 30.0,
		"Mongoose ReloadCount must advance alongside Fire_0"
	)
	var mongoose_refire_elapsed := 0.0
	for frame in 60:
		mongoose_pump.advance(mongoose, 1.0 / 60.0)
		mongoose_refire_elapsed += 1.0 / 60.0
	_expect(
		mongoose_fired.size() == 1,
		"the Mongoose must not fire again while its first Fire_0 animation is active"
	)
	for frame in 60:
		mongoose_pump.advance(mongoose, 1.0 / 60.0)
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
	var infantry_pump := SimTickPumpScript.new()
	for frame in 240:
		infantry_pump.advance(infantry, 1.0 / 60.0)
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
		infantry_pump.advance(infantry, 1.0 / 60.0)
		infantry_refire_elapsed += 1.0 / 60.0
		if not infantry._fire_sequence_active:
			break
	_expect(
		is_equal_approx(infantry.combat_turrets[0].reload_ticks_remaining, 30.0),
		"infantry ReloadCount must begin after its full-body Fire_0 action"
	)
	for frame in 120:
		infantry_pump.advance(infantry, 1.0 / 60.0)
		infantry_refire_elapsed += 1.0 / 60.0
		if infantry_fired.size() >= 2:
			break
	# infantry_refire_elapsed is measured by counting rendered frames
	# (1/60s each) across two loops, each of which breaks the instant it
	# observes a state change (clip finished, second shot fired) -- but B3c
	# moved both the clip's own progress and the reload countdown onto the
	# 25 Hz simulation tick, so each of those two state changes can now only
	# actually happen on a tick boundary (0.04s apart) rather than smoothly
	# within whichever 1/60s frame used to observe it continuously. The old
	# tolerance (1/30s, about three quarters of one tick) covered one
	# frame-granularity observation; two tick-granularity transitions are
	# summed here, so the bound is two ticks now, not one frame -- measured at
	# 0.05s against the old 0.0333s bound.
	_expect(
		infantry_fired.size() == 2
		and absf(
			infantry_refire_elapsed
			- (45.0 + 30.0) / UnitScript.RULE_COMBAT_TICKS_PER_SECOND
		) <= 2.0 * MatchClockScript.SECONDS_PER_TICK,
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
	var minotaurus_pump := SimTickPumpScript.new()
	for frame in 240:
		minotaurus_pump.advance(minotaurus, 1.0 / 60.0)
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
	# Same reasoning as the identical Mongoose comment above: begin_reload()
	# and this weapon's first shot event land on the same simulation tick, so
	# reload_ticks_remaining reads a freshly-set 120.0 at the exact instant of
	# the shot. One more tick, still well inside the four-shot clip, is
	# enough to observe the countdown actually running.
	minotaurus.sim_tick()
	_expect(
		minotaurus.combat_turrets[0].reload_ticks_remaining > 0.0
		and minotaurus.combat_turrets[0].reload_ticks_remaining < 120.0,
		"Minotaurus ReloadCount must advance during its four-shot Fire_0 animation"
	)
	for frame in 120:
		minotaurus_pump.advance(minotaurus, 1.0 / 60.0)
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
	var ink_vine_pump := SimTickPumpScript.new()
	for frame in 1200:
		ink_vine_pump.advance(ink_vine, 1.0 / 60.0)
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
	# UnitAttackOrder.advance_pursuit()'s own repath gate (0.25s) is what this
	# regression exercises, not tick timing -- call the simulation function
	# directly with a delta safely past that interval, the same way
	# _test_flickering_block_still_repositions below calls
	# hold_firing_position() directly rather than through a tick loop.
	for attempt in 3:
		ink_vine.combat().advance(0.3)
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
		attacker.sim_tick()
		# See _test_unit_attack_order's identical comment above.
		attacker.sim_tick_combat()
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
		# See _test_unit_attack_order's identical comment above.
		attacker.sim_tick_combat()
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
		# See _test_unit_attack_order's identical comment above.
		attacker.sim_tick_combat()
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



## CombatLineOfFire deliberately pierces units, so nothing used to stop a rear
## rank from firing through its own front rank -- and CombatImpactResolver then
## billed the front rank the warhead's FriendlyDamageAmount share. The blocked
## unit now holds the shot and, if the line stays blocked, walks off it.
func _test_friendly_on_the_line_holds_fire() -> void:
	var attacker = UnitScene.instantiate()
	attacker.config_id = &"ATAPC"
	root.add_child(attacker)
	attacker.replace_visual_scene(ATAPCModelScene)
	attacker.owner_player_id = 1
	var target = UnitScene.instantiate()
	target.config_id = &"ATAPC"
	root.add_child(target)
	target.replace_visual_scene(ATAPCModelScene)
	target.owner_player_id = 2
	var turret = attacker.combat_turrets[0]
	var forward: Vector3 = Vector3(turret.peek_emission()["direction"])
	forward.y = 0.0
	forward = forward.normalized()
	target.global_position = attacker.global_position + forward * 8.0
	var midpoint: Vector3 = attacker.global_position + forward * 4.0
	await physics_frame

	_expect(
		turret.target_range(target) == CombatTurretScript.TargetRange.IN_RANGE,
		"the friendly-fire regression must begin with the target inside weapon range"
	)
	_expect(
		not turret.friendly_blocks_fire(target, attacker),
		"an open muzzle line must not be reported as friendly-blocked"
	)

	var squadmate := Doubles.PhysicsCombatTarget.new(midpoint, 2.5)
	squadmate.owner_player_id = attacker.owner_player_id
	root.add_child(squadmate)
	await physics_frame
	_expect(
		turret.has_line_of_fire(target, attacker),
		"a squadmate must not count as an obstruction: the shell would still arrive"
	)
	_expect(
		turret.friendly_blocks_fire(target, attacker),
		"a squadmate on the muzzle line must be reported as friendly-blocking"
	)

	var enemy_blocker := Doubles.PhysicsCombatTarget.new(midpoint, 2.5)
	enemy_blocker.owner_player_id = target.owner_player_id
	squadmate.get_parent().remove_child(squadmate)
	root.add_child(enemy_blocker)
	await physics_frame
	_expect(
		not turret.friendly_blocks_fire(target, attacker),
		"an enemy body on the line is a target, not a reason to hold the shot"
	)
	enemy_blocker.get_parent().remove_child(enemy_blocker)
	root.add_child(squadmate)
	await physics_frame

	var fired: Array = []
	attacker.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
	)
	_expect(attacker.command_attack(target), "a blocked line must still accept the order")
	# Pinned in place so the reposition below cannot silently walk the unit off
	# the line and turn this into a test of movement rather than of holding fire.
	var home: Vector3 = attacker.global_position
	for frame in 240:
		attacker._process(1.0 / 60.0)
		# See _test_unit_attack_order's identical comment above.
		attacker.sim_tick_combat()
		attacker.global_position = home
	_expect(fired.is_empty(), "a unit must not put its shot through a squadmate")
	_expect(
		attacker.has_attack_order(),
		"holding the shot must not drop the order -- the blocker is transient"
	)
	_expect(
		Vector2(
			attacker.target_position.x - home.x, attacker.target_position.z - home.z
		).length() > 0.0,
		"a line that stays blocked must send the unit to a clear firing position"
	)

	squadmate.free()
	await physics_frame
	_expect(
		not turret.friendly_blocks_fire(target, attacker),
		"removing the squadmate must clear the friendly block"
	)
	for frame in 240:
		attacker._process(1.0 / 60.0)
		# See _test_unit_attack_order's identical comment above.
		attacker.sim_tick_combat()
		if not fired.is_empty():
			break
	_expect(
		not fired.is_empty(),
		"the held shot must resume once the squadmate is off the line"
	)

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	enemy_blocker.free()
	attacker.free()
	target.free()


## Deciding to engage and actually launching the round are separated by the
## whole authored Fire clip -- a second or more, during which a squadmate can
## walk into a line that was clear when the sequence started. Measured on ten
## HKTroopers ordered onto a flank target, 14 of 30 rounds left the muzzle that
## way. The muzzle asks the question again for itself.
func _test_friendly_arriving_mid_clip_cancels_the_shot() -> void:
	var attacker = UnitScene.instantiate()
	attacker.config_id = &"ATAPC"
	root.add_child(attacker)
	attacker.replace_visual_scene(ATAPCModelScene)
	attacker.owner_player_id = 1
	var target = UnitScene.instantiate()
	target.config_id = &"ATAPC"
	root.add_child(target)
	target.replace_visual_scene(ATAPCModelScene)
	target.owner_player_id = 2
	var turret = attacker.combat_turrets[0]
	var forward: Vector3 = Vector3(turret.peek_emission()["direction"])
	forward.y = 0.0
	forward = forward.normalized()
	target.global_position = attacker.global_position + forward * 8.0
	var midpoint: Vector3 = attacker.global_position + forward * 4.0
	await physics_frame

	var fired: Array = []
	attacker.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
	)
	var home: Vector3 = attacker.global_position
	# ATAPC's LMG_B Fire_0 has exactly one shot event, authored at baked frame
	# 1 (elapsed 0.05s -- see AuthoredFireController/FIRE_ANIMATION_SPEED_SCALE):
	# checked directly, its shot_times is [{"time": 0.05, ...}]. One
	# simulation tick's own fire-sequence advance (SECONDS_PER_TICK *
	# FIRE_ANIMATION_SPEED_SCALE = 0.04 * 1.25 = 0.05, by the same design that
	# makes one tick exactly one baked frame) already reaches that shot
	# exactly, so a tick-quantized Unit.sim_tick_combat() call cannot ever
	# observe "the clip started but has not yet reached its shot" for this
	# weapon -- both happen inside the very first tick, deterministically,
	# every run. That collapsed window is specific to firing on a tick clock;
	# it was not collapsed when fire-sequence progress ran on the render frame
	# (B3c moved it), because a single frame's smaller advance (delta *
	# FIRE_ANIMATION_SPEED_SCALE at 1/60s ~= 0.021) undershot 0.05 and left a
	# real intermediate frame to observe. Locomotion (pursuit) still has to
	# run on the tick -- Unit.sim_tick() integrates global_position, and nothing
	# here needs frame-granular movement -- so only the combat half is driven
	# at frame granularity here, directly through UnitCombat.advance(), the
	# same "call the simulation function directly for a precise-delta
	# regression" idiom _test_rejected_attack_perch uses above.
	var tick_driver := FrameTickDriverScript.new()
	var advance_pursuit_and_combat := func(delta: float) -> void:
		for _tick in tick_driver.pending_ticks(delta):
			attacker.sim_tick()
		attacker.combat().advance(delta)
		attacker._process(delta)
	_expect(attacker.command_attack(target), "a clear line must accept the order")
	# Run until the clip is under way but before its shot event, so the engage
	# decision is already made and only the muzzle can still refuse.
	var sequence_started := false
	for frame in 240:
		advance_pursuit_and_combat.call(1.0 / 60.0)
		attacker.global_position = home
		if attacker._fire_sequence_active:
			sequence_started = true
			break
		if not fired.is_empty():
			break
	_expect(
		sequence_started and fired.is_empty(),
		"the clip must start before its shot event for this regression to mean anything"
	)

	var squadmate := Doubles.PhysicsCombatTarget.new(midpoint, 2.5)
	squadmate.owner_player_id = attacker.owner_player_id
	root.add_child(squadmate)
	await physics_frame
	_expect(
		turret.friendly_blocks_fire(target, attacker),
		"the arriving squadmate must land on the muzzle line"
	)
	for frame in 240:
		advance_pursuit_and_combat.call(1.0 / 60.0)
		attacker.global_position = home
	_expect(
		fired.is_empty(),
		"a squadmate that arrives mid-clip must still cancel the round at the muzzle"
	)

	squadmate.free()
	await physics_frame
	for frame in 480:
		advance_pursuit_and_combat.call(1.0 / 60.0)
		attacker.global_position = home
		if not fired.is_empty():
			break
	_expect(not fired.is_empty(), "the shot must resume once the line clears again")

	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	attacker.free()
	target.free()


## A round does not fly the ideal muzzle-to-target line: it leaves along the
## muzzle's current heading (see parallel_impact_position), which an authored
## Fire clip poses degrees off the ordered bearing. Checking only the ideal
## line let a stationary rear rank fire through a squadmate standing on the
## muzzle's actual heading while the ideal line passed cleanly beside it. The
## gate must ask along the flown line.
func _test_friendly_on_the_flown_line_holds_fire() -> void:
	var attacker = UnitScene.instantiate()
	attacker.config_id = &"ATAPC"
	root.add_child(attacker)
	attacker.replace_visual_scene(ATAPCModelScene)
	attacker.owner_player_id = 1
	var turret = attacker.combat_turrets[0]
	var muzzle: Vector3 = Vector3(turret.peek_emission()["position"])
	var heading: Vector3 = Vector3(turret.peek_emission()["direction"])
	heading.y = 0.0
	heading = heading.normalized()
	# The ordered point sits well off the muzzle's current heading; the muzzle
	# has not been servo-aimed onto it (an authored clip fires regardless). The
	# squadmate stands on the heading, 2.0 laterally off the ideal line -- a
	# body its 0.9 radius keeps well clear of, so only the flown line crosses it.
	var ground: Vector3 = attacker.global_position \
		+ heading.rotated(Vector3.UP, deg_to_rad(30.0)) * 8.0
	var on_heading := muzzle + heading * 4.0
	on_heading.y = muzzle.y * 0.5
	var squadmate := Doubles.PhysicsCombatTarget.new(on_heading, 0.9)
	squadmate.owner_player_id = attacker.owner_player_id
	root.add_child(squadmate)
	await physics_frame

	_expect(
		turret.friendly_blocks_fire(ground, attacker),
		"a squadmate on the muzzle's actual heading must read as friendly-blocking"
	)
	var held: Array = turret.try_fire_at(FireRequestScript.authored(ground, attacker))
	_expect(
		held.is_empty(),
		"the muzzle gate must hold a shot whose flown line crosses the squadmate"
	)

	squadmate.get_parent().remove_child(squadmate)
	await physics_frame
	turret.reload_ticks_remaining = 0.0
	var released: Array = turret.try_fire_at(FireRequestScript.authored(ground, attacker))
	_expect(
		not released.is_empty(),
		"clearing the flown line must release the same shot"
	)

	for projectile in released:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	squadmate.free()
	attacker.free()


## The reposition used to require the line to stay blocked for a whole
## uninterrupted second. In a real crowd it never does: ten soldiers shuffling
## shoulder to shoulder clear and re-block the same line several times a second,
## which pinned the counter at zero and left everyone standing in a formation
## built for the previous target.
func _test_flickering_block_still_repositions() -> void:
	var attacker = UnitScene.instantiate()
	attacker.config_id = &"ATAPC"
	root.add_child(attacker)
	attacker.replace_visual_scene(ATAPCModelScene)
	attacker.owner_player_id = 1
	var turret = attacker.combat_turrets[0]
	var forward: Vector3 = Vector3(turret.peek_emission()["direction"])
	forward.y = 0.0
	forward = forward.normalized()
	var ground: Vector3 = attacker.global_position + forward * 8.0
	_expect(attacker.command_attack(ground), "the attack-ground order must be accepted")
	var order = attacker.combat()._attack_order
	var home: Vector3 = attacker.global_position

	var delta := 1.0 / 60.0
	for frame in 600:
		# Blocked on two frames out of three: never a full second in a row, but
		# unmistakably a line this unit cannot shoot along.
		order.hold_firing_position(frame % 3 != 0, ground, turret, delta)
		attacker.global_position = home
		if attacker.has_active_move_order():
			break
	_expect(
		attacker.has_active_move_order(),
		"an intermittently blocked line must still send the unit to a clear slot"
	)

	attacker.free()
