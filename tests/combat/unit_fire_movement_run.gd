extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Assertions := preload("res://tests/combat/support/combat_assertions.gd")
const SimTickPumpScript := preload("res://tests/combat/support/sim_tick_pump.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATAPCModelScene := preload("res://assets/converted/models/AT_APC_H0/AT_APC_H0.scn")
const ATInfantryModelScene := preload("res://assets/converted/models/AT_inf_H0/AT_inf_H0.scn")
const ATMongooseModelScene := preload(
	"res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn"
)
const ATMinotaurusModelScene := preload(
	"res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn"
)
const HKDevastatorModelScene := preload(
	"res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn"
)
const HKFlameModelScene := preload(
	"res://assets/converted/models/HK_flame_H0/HK_flame_H0.scn"
)

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await physics_frame
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
	_run_case(
		"a turret holds its simulated aim on a rendered frame with no tick",
		_test_turret_holds_angle_with_no_tick_this_frame
	)
	_run_case("idle unit turrets scan their forward sector", _test_idle_unit_turret_scan)
	_run_case("unit model replacement rebinds its turret", _test_unit_turret_rebind)
	_finish("Unit fire movement tests")

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
	# Unit._process() no longer advances turret reload or locomotion -- Match's
	# central loop does, through Unit.sim_tick() (see _advance_locomotion_tick()
	# for the locomotion half). This suite has no Match, so the pump stands in
	# for that half of a real frame; without it neither the pursuit movement
	# nor the autonomous-reacquisition assertion at the end of this case would
	# ever happen.
	var mongoose_pump := SimTickPumpScript.new()
	for frame in 180:
		mongoose_pump.advance(mongoose, 1.0 / 60.0)
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
		mongoose_pump.advance(mongoose, 1.0 / 60.0)
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
	# A bare mongoose_pump.advance() here is not guaranteed to contain a due
	# tick -- pending_ticks() only fires once its own remainder crosses one
	# whole SECONDS_PER_TICK, and the 180-iteration loop above can leave that
	# remainder anywhere. This regression wants exactly one simulation step
	# right after the animation-frame stomp above, so call it directly rather
	# than through a pump call that might land on a tick-less frame.
	mongoose.sim_tick_combat()
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
	# "sim_units" too: CombatTargetAcquisition.target_for() reads that group,
	# not "units", as of slice C6a (scripts/combat/combat_target_acquisition.gd).
	autonomous_target.add_to_group(&"units")
	autonomous_target.add_to_group(&"sim_units")
	for frame in 600:
		mongoose_pump.advance(mongoose, 1.0 / 60.0)
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
		# Unit._process() no longer advances target acquisition, attack
		# orders or fire sequences -- B3c moved that onto
		# Unit.sim_tick_combat(), Match's second pass over the "units" group.
		# No Match here, so drive it by hand.
		infantry.sim_tick_combat()
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
		# "sim_units" too -- see the identical comment above.
		target.add_to_group(&"units")
		target.add_to_group(&"sim_units")
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
		# See _test_blocking_fire_move_cancel's identical comment above.
		flame.sim_tick_combat()
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
		# See _test_blocking_fire_move_cancel's identical comment above.
		blind_flame.sim_tick_combat()
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
	# This regression pins the turn-step math to specific delta values (a
	# whole 1/20 rule update, then thirds of it below) that have nothing to
	# do with the simulation tick rate -- see combat_turret.gd's
	# AIM_UPDATES_PER_SECOND, a Rules.txt authoring cadence, not a clock.
	# Call the simulation function directly with those deltas rather than
	# through Unit.sim_tick_combat(), which is fixed to one 25 Hz tick.
	unit.combat().advance(1.0 / 20.0)
	var attack_yaw := absf(turret.current_yaw_degrees())
	var expected_yaw := 5.0 + rad_to_deg(unit.turn_rate)
	_expect(
		is_equal_approx(attack_yaw, expected_yaw),
		(
			"one rule update must combine the Minotaurus turret's 5-degree rate "
			+ "with its %.3f-degree hull rate"
		) % rad_to_deg(unit.turn_rate)
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
	# Same reasoning as the 1/20 call above: a precise-delta step-math
	# regression, called directly rather than through the fixed-tick
	# Unit.sim_tick_combat().
	unit.combat().advance(1.0 / 60.0)
	var returning_yaw := absf(turret.current_yaw_degrees())
	_expect(
		returning_yaw < attack_yaw and returning_yaw > 0.0,
		"the first movement frame must begin returning the turret instead of snapping or caching it"
	)
	_expect(
		absf(returning_yaw - (attack_yaw - expected_yaw / 3.0)) < 0.01,
		"recentring must use the Minotaurus combined turret and hull turn rate"
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
	# Same reasoning as the two calls above.
	unit.combat().advance(1.0 / 60.0)
	var reacquired_direction: Vector3 = turret.peek_emission()["direction"]
	_expect(
		rad_to_deg(Assertions.horizontal_angle_between(returning_direction, reacquired_direction))
			<= expected_yaw / 3.0 + 0.1,
		"a repeated attack order must resume from the visible pose without restoring a cached yaw"
	)


## The property B3c's sim/view split exists for, proved directly rather than
## inferred from a green suite: the combat-owned aim angle only changes on a
## simulation tick (Unit.sim_tick_combat()), but the pivot that renders it has
## to be repainted every rendered frame regardless, via _process()'s
## restore_combat_turret_poses() call, because a looping authored
## Stationary/Move track keys that same pivot back to its own rest pose every
## frame it plays (see CombatTurret.aim_at()'s own comment). Every other
## regression in this file drives sim_tick_combat() and _process() together
## each step, so none of them would notice _process() failing to reapply the
## pose on a frame where no tick ran -- this isolates that one frame.
func _test_turret_holds_angle_with_no_tick_this_frame() -> void:
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
	# The only simulation tick this test ever runs. Everything from here on
	# drives _process() alone, with no further sim_tick_combat(), to isolate
	# the view half from the simulation half it is being tested against.
	unit.sim_tick_combat()
	var aimed_yaw: float = turret.current_yaw_degrees()
	_expect(
		absf(aimed_yaw) > 0.01,
		"test setup must actually turn the turret, or the regression below proves nothing"
	)
	var aimed_direction: Vector3 = turret.peek_emission()["direction"]

	var player := unit.get_node("VisualRoot").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	_expect(
		player != null,
		"the Minotaurus model must expose an AnimationPlayer for this regression to mean anything"
	)
	if player != null:
		# Reproduce a looping authored Stationary/Move track keying the
		# turret pivot back to its own rest pose, exactly as it does every
		# rendered frame it plays.
		player.advance(1.0 / 60.0)
		var stomped_direction: Vector3 = turret.peek_emission()["direction"]
		_expect(
			rad_to_deg(Assertions.horizontal_angle_between(stomped_direction, aimed_direction)) > 1.0,
			"the animation must actually overwrite the pivot, or this regression proves nothing"
		)
	# No sim_tick_combat() this frame -- exactly a rendered frame with no due
	# tick, which is the case a green suite driving both together every step
	# would never exercise.
	unit._process(1.0 / 60.0)
	_expect(
		is_equal_approx(turret.current_yaw_degrees(), aimed_yaw),
		"the stored aim angle is simulation state and must not change on a tick-less frame"
	)
	var held_direction: Vector3 = turret.peek_emission()["direction"]
	_expect(
		rad_to_deg(Assertions.horizontal_angle_between(held_direction, aimed_direction)) < 0.1,
		"a rendered frame with no tick must reapply the last simulated aim, not leave the "
			+ "animation's rest pose showing"
	)
	unit.free()


func _test_idle_unit_turret_scan() -> void:
	var unit = UnitScene.instantiate()
	unit.config_id = &"ATMinotaurus"
	root.add_child(unit)
	unit.replace_visual_scene(ATMinotaurusModelScene)
	var turret = unit.combat_turrets[0]
	turret._idle_scan_rng.seed = 1
	turret._idle_scan_active = false
	# Idle-scan timing is tested with deliberately large, exact deltas (three
	# then five-ish seconds) that have nothing to do with the tick rate --
	# call the simulation function directly rather than through the
	# fixed-tick Unit.sim_tick_combat(), same as _test_turret_recenter_after_move.
	unit.combat().advance(2.0)
	_expect(
		is_zero_approx(turret.current_yaw_degrees()),
		"an idle turret must wait at least three seconds before its first scan turn"
	)
	unit.combat().advance(4.0)
	var yaw: float = turret.current_yaw_degrees()
	_expect(
		absf(yaw) > 0.01 and absf(yaw) <= 70.01,
		"an idle unit turret must choose a point within 70 degrees of its forward direction"
	)
	_expect(
		turret._idle_scan_seconds_until_target >= 3.0
			and turret._idle_scan_seconds_until_target <= 5.0,
		"each idle unit scan target must remain in place for three to five seconds"
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
