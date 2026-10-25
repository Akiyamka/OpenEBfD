extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const SimRngScript := preload("res://scripts/sim/sim_rng.gd")
const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const SimTickPumpScript := preload("res://tests/combat/support/sim_tick_pump.gd")
const FrameTickDriverScript := preload("res://scripts/match/frame_tick_driver.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const Assertions := preload("res://tests/combat/support/combat_assertions.gd")
const HKGunTurretScene := preload("res://assets/converted/buildings/HKGunTurret/HKGunTurret.scn")
const HKFlameTurretScene := preload("res://assets/converted/buildings/HKFlameTurret/HKFlameTurret.scn")
const ATWallScene := preload("res://assets/converted/buildings/ATWall/ATWall.scn")
const PopupScene := preload("res://assets/converted/buildings/ORPopUpTurret/ORPopUpTurret.scn")

class NullCallLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		if "null value" in str(code) or "null value" in str(rationale) \
			or "Nil" in str(code) or "Nil" in str(rationale):
			errors.append(str(code) + " " + str(rationale))

func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await physics_frame
	_run_case("frame-only building combat leaves simulation state unchanged", _test_frame_isolation)
	_run_case("building combat advances without rendered frames", _test_frameless_engagement)
	_run_case("building acquisition observes its seventh-tick boundary", _test_acquisition_cadence)
	_run_case("authored fire starts at zero age", _test_sequence_start_age)
	_run_case("popup starts and completes on fixed tick boundaries", _test_popup_tick_boundary)
	_run_case("disposed building combat tick has no null call", _test_disposed_tick)
	_run_case("disposed building combat view has no null call", _test_disposed_view)
	await _run_async_case("non-popup aim holds across a real frame", _test_real_frame_repaint)
	await _run_async_case("popup animation owns transition pivot", _test_popup_frame_ownership)
	await _run_async_case("active Fire clip preserves yaw and animates descendants", _test_fire_frame_repaint)
	_run_case(
		"building state replacement rebinds its turret without losing its aim",
		_test_building_turret_rebind
	)
	_run_case("all seven defensive buildings automatically acquire and fire", _test_defensive_building_auto_fire)
	_run_case("idle building turrets scan their forward sector", _test_idle_building_turret_scan)
	await _run_async_case(
		"HKFlameTurret direct force-fire hits a friendly unit below its muzzle",
		_test_hkflame_turret_direct_friendly_fire
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
	_finish("Defensive building tests")

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
	var turret = building.combat_turrets[0]
	var target_position := Vector3(idle_emission["position"]) + Vector3.RIGHT * 50.0
	turret.aim_at(target_position, 1.0)
	var yaw_before: float = turret.current_yaw_degrees()
	var direction_before: Vector3 = turret.peek_emission()["direction"]
	_expect(absf(yaw_before) > 0.1, "the fixture must aim the turret away from its rest pose")
	building.play_state(&"damage1")
	var damage_emission: Dictionary = building.next_turret_emission()
	_expect(not damage_emission.is_empty(), "the damage state must retain a muzzle")
	_expect(
		String((damage_emission.get("node") as Node).get_path()).contains("/Damage1/"),
		"state changes must rebind the turret to the visible Damage1 copy"
	)
	_expect(
		is_equal_approx(turret.current_yaw_degrees(), yaw_before),
		"replacing a damage-state model must retain the turret's logical yaw"
	)
	_expect(
		Vector3(damage_emission["direction"]).is_equal_approx(direction_before),
		"replacing a damage-state model must retain the visible turret direction"
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
		# "sim_units" too: CombatTargetAcquisition.target_for() reads that
		# group, not "units", as of slice C6a.
		target.add_to_group(&"sim_units")
		root.add_child(target)
		var fired: Array = []
		building.weapon_fired.connect(
			func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
				fired.append_array(projectiles)
		)
		# B3b moved shot committal from Building._process() onto
		# Building.sim_tick(); a bare _process() loop with no Match in the tree
		# would advance aim forever without ever advancing the fire controller's
		# own "elapsed" -- see SimTickPumpScript's doc comment.
		var building_pump := SimTickPumpScript.new()
		for frame in 900:
			building_pump.advance(building, 1.0 / 60.0)
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


func _test_idle_building_turret_scan() -> void:
	var building = HKGunTurretScene.instantiate()
	root.add_child(building)
	var turret = building.combat_turrets[0]
	turret.set_idle_scan_source(SimRngScript.new(2), 0)
	turret._idle_scan_active = false
	for _tick in 50:
		building.sim_tick()
	_expect(
		is_zero_approx(turret.current_yaw_degrees()),
		"an idle building turret must wait at least three seconds before its first scan turn"
	)
	for _tick in 100:
		building.sim_tick()
		if absf(turret.current_yaw_degrees()) > 0.01:
			break
	var yaw: float = turret.current_yaw_degrees()
	_expect(
		absf(yaw) > 0.01 and absf(yaw) <= 70.01,
		"an idle building turret must choose a point within 70 degrees of its forward direction"
	)
	_expect(
		turret._idle_scan_seconds_until_target >= 3.0
			and turret._idle_scan_seconds_until_target <= 5.0,
		"each idle building scan target must remain in place for three to five seconds"
	)
	building.free()


## A Flame Turret only yaws. Its source muzzle sits above a ground unit, so a
## direct target must supply the projectile's downward component; otherwise
## only attack-ground at the same position can cause friendly splash damage.
func _test_hkflame_turret_direct_friendly_fire() -> void:
	var building := HKFlameTurretScene.instantiate() as Building
	building.owner_player_id = 1
	root.add_child(building)
	await process_frame
	var emission: Dictionary = building.combat_turrets[0].peek_emission()
	var direction := Vector3(emission["direction"])
	direction.y = 0.0
	var target := Doubles.PhysicsCombatTarget.new(
		building.global_position + direction.normalized() * 5.0,
		0.5
	)
	target.owner_player_id = building.owner_player_id
	target.add_to_group(&"units")
	# "sim_units" too -- see the comment near this file's first Doubles.PhysicsCombatTarget above.
	target.add_to_group(&"sim_units")
	root.add_child(target)
	# CombatProjectile no longer advances itself from _physics_process() (B3a
	# moved flight onto Match._advance_simulation_tick()'s "sim_projectiles"
	# loop); this suite has no Match, so nothing drives that loop, and the
	# flame stream would sit at the muzzle forever. Collect what the turret
	# fires and step it by hand each frame, the same way every other fixture
	# in this file that owns a projectile does.
	var fired: Array = []
	building.weapon_fired.connect(
		func(projectiles: Array, _target: Variant, _weapon_index: int) -> void:
			fired.append_array(projectiles)
	)
	_expect(
		building.command_attack(target),
		"HKFlameTurret must accept a forced attack on a friendly unit"
	)
	# B3b moved shot committal from Building._process() onto
	# Building.sim_tick(); this scene has no Match, so nothing calls sim_tick()
	# for us the way it would in a real match -- pump it by hand, before each
	# frame's automatic _process(), the same "ticks before this frame's
	# Building._process()" ordering SimTickPumpScript documents (production
	# reaches it because Match sits earlier in the tree, so Match._process()
	# always runs first).
	var tick_driver := FrameTickDriverScript.new()
	for frame in 360:
		for _tick in tick_driver.pending_ticks(1.0 / 60.0):
			building.sim_tick()
		await physics_frame
		for projectile in fired:
			if is_instance_valid(projectile):
				projectile.advance(1.0 / 60.0)
		if target.damage_taken > 0.0:
			break
	_expect(
		target.damage_taken > 0.0,
		"HKFlameTurret direct fire must damage a friendly unit below its muzzle"
	)
	for projectile in fired:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	building.free()
	target.free()


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
	for tick in 60:
		building.sim_tick()
		if absf(turret.current_yaw_degrees()) >= 35.0:
			break
	await process_frame
	await process_frame
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
	# "sim_units" too -- see the comment near this file's first Doubles.PhysicsCombatTarget above.
	target.add_to_group(&"sim_units")
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
	# B3b moved shot committal from Building._process() onto
	# Building.sim_tick() -- see the identical comment in
	# _test_defensive_building_auto_fire() above.
	var building_pump := SimTickPumpScript.new()
	for frame in 900:
		building_pump.advance(building, 1.0 / 60.0)
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
		# "sim_units" too -- see the comment near this file's first Doubles.PhysicsCombatTarget above.
		target.add_to_group(&"sim_units")
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
		for tick in 900:
			building.sim_tick()
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
		# B3b moved the popup deploy/undeploy transition's own completion
		# countdown from Building._process() onto Building.sim_tick(); this
		# scene has no Match, so nothing calls sim_tick() for us -- pump it by
		# hand, before each frame's automatic _process(), same ordering as
		# _test_hkflame_turret_direct_friendly_fire() above.
		var tick_driver := FrameTickDriverScript.new()
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
			for _tick in tick_driver.pending_ticks(1.0 / 60.0):
				building.sim_tick()
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
			for _tick in tick_driver.pending_ticks(1.0 / 60.0):
				building.sim_tick()
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
	# "sim_units" too -- see the comment near this file's first Doubles.PhysicsCombatTarget above.
	target.add_to_group(&"sim_units")
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
	# B3b moved shot committal from Building._process() onto
	# Building.sim_tick() -- see the identical comment in
	# _test_defensive_building_auto_fire() above.
	var building_pump := SimTickPumpScript.new()
	for frame in 120:
		building_pump.advance(building, 1.0 / 60.0)
	_expect(
		fired.is_empty() and building.has_attack_order(),
		"the immobile building must retain, but not fire at, its distant target"
	)
	target.global_position = Vector3(emission["position"]) + direction * 5.0
	for frame in 600:
		building_pump.advance(building, 1.0 / 60.0)
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
	# "sim_units" too -- see the comment near this file's first Doubles.PhysicsCombatTarget above.
	covered.add_to_group(&"sim_units")
	root.add_child(covered)
	var exposed := Doubles.PhysicsCombatTarget.new(muzzle + side * 8.0)
	exposed.owner_player_id = 2
	exposed.add_to_group(&"units")
	# "sim_units" too -- see the comment near this file's first Doubles.PhysicsCombatTarget above.
	exposed.add_to_group(&"sim_units")
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
	var building_pump := SimTickPumpScript.new()
	for frame in 600:
		building_pump.advance(building, 1.0 / 60.0)
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
		building_pump.advance(building, 1.0 / 60.0)
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



func _lateral_point(turret, distance := 8.0) -> Vector3:
	var emission: Dictionary = turret.peek_emission()
	var direction: Vector3 = emission["direction"]
	return Vector3(emission["position"]) + direction.rotated(Vector3.UP, PI * 0.5).normalized() * distance


func _test_frame_isolation() -> void:
	var building := HKGunTurretScene.instantiate() as Building
	root.add_child(building)
	var turret = building.combat_turrets[0]
	turret.set_idle_scan_source(SimRngScript.new(2), 0)
	_expect(building.command_attack(_lateral_point(turret)), "lateral frame-only order must be accepted")
	var yaw: float = turret.current_yaw
	var state: int = building._popup_turret_state
	var sequence_count: int = building._authored_fire_controller._sequences.size()
	var fired: Array = []
	building.weapon_fired.connect(func(projectiles: Array, _target: Variant, _index: int) -> void:
		fired.append_array(projectiles))
	for delta in [2.0, 4.0, 2.0]:
		building._process(delta)
	_expect(is_equal_approx(turret.current_yaw, yaw), "frames alone must not turn logical yaw")
	_expect(building._popup_turret_state == state, "frames alone must not change popup state")
	_expect(building._authored_fire_controller._sequences.size() == sequence_count,
		"frames alone must not start authored fire")
	_expect(fired.is_empty(), "frames alone must not fire a shot")
	building.free()

	building = HKGunTurretScene.instantiate() as Building
	building.owner_player_id = 1
	root.add_child(building)
	turret = building.combat_turrets[0]
	building.sim_tick()
	var acquisition = building._building_combat._target_acquisition
	var cooldown: float = acquisition._cooldowns.get(turret.weapon_index(), -1.0)
	_expect(is_equal_approx(cooldown, 0.25), "idle fixture must prime acquisition cooldown")
	var enemy := Doubles.PhysicsCombatTarget.new(_lateral_point(turret))
	enemy.owner_player_id = 2
	enemy.add_to_group(&"sim_units")
	root.add_child(enemy)
	for delta in [2.0, 4.0]:
		building._process(delta)
	_expect(is_equal_approx(float(acquisition._cooldowns.get(turret.weapon_index(), -1.0)), cooldown),
		"frames alone must not drain acquisition cooldown")
	_expect(acquisition._targets.is_empty(), "frames alone must not acquire a new enemy")
	enemy.free()
	building.free()


func _test_frameless_engagement() -> void:
	var building := HKGunTurretScene.instantiate() as Building
	root.add_child(building)
	var turret = building.combat_turrets[0]
	var fired: Array = []
	building.weapon_fired.connect(func(projectiles: Array, _target: Variant, _index: int) -> void:
		fired.append_array(projectiles))
	_expect(building.command_attack(_lateral_point(turret)), "frameless lateral order must be accepted")
	for tick in 180:
		building.sim_tick()
		if not fired.is_empty():
			break
	_expect(absf(turret.current_yaw_degrees()) > 20.0, "ticks alone must turn the turret")
	_expect(not fired.is_empty(), "ticks alone must start and commit authored fire")
	for projectile in fired:
		if is_instance_valid(projectile):
			projectile.free()
	building.free()


func _test_acquisition_cadence() -> void:
	var building := HKGunTurretScene.instantiate() as Building
	building.owner_player_id = 1
	root.add_child(building)
	var turret = building.combat_turrets[0]
	building.sim_tick()
	var acquisition = building._building_combat._target_acquisition
	_expect(is_equal_approx(float(acquisition._cooldowns.get(turret.weapon_index(), -1.0)), 0.25),
		"first no-target tick must set a quarter-second cooldown")
	var enemy := Doubles.PhysicsCombatTarget.new(_lateral_point(turret))
	enemy.owner_player_id = 2
	enemy.add_to_group(&"sim_units")
	root.add_child(enemy)
	for tick in 6:
		building.sim_tick()
		_expect(acquisition._targets.is_empty(), "six further ticks must not acquire")
	building.sim_tick()
	_expect(not acquisition._targets.is_empty(), "seventh further tick must acquire enemy")
	enemy.free()
	building.free()


func _test_sequence_start_age() -> void:
	var building := HKGunTurretScene.instantiate() as Building
	root.add_child(building)
	var turret = building.combat_turrets[0]
	_expect(building.command_attack(_lateral_point(turret)), "sequence fixture needs a lateral order")
	for tick in 100:
		building.sim_tick()
		if not building._authored_fire_controller._sequences.is_empty():
			break
	var sequences: Dictionary = building._authored_fire_controller._sequences
	_expect(not sequences.is_empty(), "engagement must start authored sequence")
	if not sequences.is_empty():
		var state: Dictionary = sequences.values()[0]
		_expect(is_zero_approx(float(state["elapsed"])), "new authored sequence must have zero age")
		building.sim_tick()
		_expect(float(state["elapsed"]) > 0.0, "next tick must advance sequence age")
	building.free()


func _test_popup_tick_boundary() -> void:
	var building := PopupScene.instantiate() as Building
	root.add_child(building)
	var turret = building.combat_turrets[0]
	_expect(building.command_attack(_lateral_point(turret)), "popup fixture needs an order")
	for frame in 4:
		building._process(2.0)
	_expect(building._popup_turret_state == 0, "frames alone cannot start popup deployment")
	building.sim_tick()
	var combat = building._building_combat
	_expect(building._popup_turret_state == 1, "first engagement tick starts deployment")
	_expect(is_zero_approx(combat._transition_elapsed), "deployment starts at zero elapsed")
	var ticks: int = ceili(combat._transition_duration / 0.04)
	for tick in ticks - 1:
		building.sim_tick()
		_expect(building._popup_turret_state == 1, "popup must wait for completion tick")
	building.sim_tick()
	_expect(building._popup_turret_state == 2, "popup completes on fixed tick boundary")
	building.free()


func _disposed_call(view: bool) -> void:
	var building := HKGunTurretScene.instantiate() as Building
	root.add_child(building)
	var combat = building._building_combat
	combat.dispose()
	var logger := NullCallLogger.new()
	OS.add_logger(logger)
	var reached := {"value": false}
	if view:
		_disposed_view_callback(combat, reached)
	else:
		_disposed_tick_callback(combat, reached)
	OS.remove_logger(logger)
	_expect(reached["value"], "disposed entry must be reached")
	_expect(logger.errors.is_empty(), "disposed entry must not produce a null-call script error")
	building.free()


func _disposed_tick_callback(combat, reached: Dictionary) -> void:
	reached["value"] = true
	combat.sim_tick()


func _disposed_view_callback(combat, reached: Dictionary) -> void:
	reached["value"] = true
	combat.repaint_view()


func _test_disposed_tick() -> void:
	_disposed_call(false)


func _test_disposed_view() -> void:
	_disposed_call(true)


func _test_real_frame_repaint() -> void:
	var building := HKGunTurretScene.instantiate() as Building
	root.add_child(building)
	await process_frame
	var state_player := building.get_node("StatePlayer") as AnimationPlayer
	_expect(state_player != null and state_player.is_playing(),
		"real-frame fixture needs a playing StatePlayer")
	var turret = building.combat_turrets[0]
	_expect(building.command_attack(_lateral_point(turret)), "real-frame case needs lateral order")
	for tick in 40:
		building.sim_tick()
		if absf(turret.current_yaw_degrees()) > 20.0:
			break
	var yaw: float = turret.current_yaw
	var tick_emission: Dictionary = turret.peek_emission()
	_expect(absf(rad_to_deg(yaw)) > 20.0, "real-frame fixture needs substantial yaw")
	await process_frame
	await process_frame
	_expect(is_equal_approx(turret.current_yaw, yaw), "render frames cannot advance logical yaw")
	var pivot: Node3D = turret._yaw_pivot
	var rest: Transform3D = turret._pivot_rest_transforms[pivot]
	var expected := Transform3D(rest.basis * Basis(Vector3.UP, yaw), rest.origin)
	_expect(pivot.transform.is_equal_approx(expected), "view repaint must hold tick-painted pivot")
	var frame_emission: Dictionary = turret.peek_emission()
	_expect(Vector3(frame_emission["direction"]).is_equal_approx(tick_emission["direction"]),
		"visible emission must retain the last tick's direction")
	building.free()


func _popup_track_transform(player: AnimationPlayer, pivot: Node3D) -> Transform3D:
	var animation := player.get_animation(player.current_animation)
	for track in animation.get_track_count():
		if str(animation.track_get_path(track)).ends_with("%s:transform" % pivot.name):
			return animation.value_track_interpolate(track, player.current_animation_position)
	return Transform3D.IDENTITY


func _test_popup_frame_ownership() -> void:
	var building := PopupScene.instantiate() as Building
	root.add_child(building)
	await process_frame
	var turret = building.combat_turrets[0]
	var pivot: Node3D = turret._yaw_pivot
	var player := building._active_model_animation_player(&"Deploy_Gun")
	_expect(building.command_attack(_lateral_point(turret)), "popup pose case needs lateral order")
	building.sim_tick()
	_expect(building._popup_turret_state == 1 and player.current_animation == &"Deploy_Gun",
		"popup must be deploying with its clip playing")
	await process_frame
	await process_frame
	var expected := _popup_track_transform(player, pivot)
	_expect(expected.origin.distance_to(turret._pivot_rest_transforms[pivot].origin) > 0.1,
		"deploy track must have non-rest position")
	_expect(pivot.transform.is_equal_approx(expected), "deploy pivot must match complete keyed transform")
	for tick in 20:
		building.sim_tick()
		if building._popup_turret_state == 2:
			break
	_expect(building._popup_turret_state == 2, "popup must reach deployed state")
	for tick in 20:
		building.sim_tick()
		if absf(turret.current_yaw_degrees()) > 10.0:
			break
	var deployed_yaw: float = turret.current_yaw
	_expect(absf(rad_to_deg(deployed_yaw)) > 10.0, "deployed case needs nonzero yaw")
	await process_frame
	await process_frame
	var deployed_rest: Transform3D = turret._pivot_rest_transforms[pivot]
	var deployed_pose := Transform3D(deployed_rest.basis * Basis(Vector3.UP, deployed_yaw),
		deployed_rest.origin)
	_expect(pivot.transform.is_equal_approx(deployed_pose), "deployed popup must hold tick yaw")
	building.cancel_attack_order()
	for tick in 80:
		building.sim_tick()
		if building._popup_turret_state == 3:
			break
	_expect(building._popup_turret_state == 3 and player.current_animation == &"Undeploy_Gun",
		"popup must begin undeploy clip")
	await process_frame
	await process_frame
	player.advance(0.55)
	await process_frame
	await process_frame
	expected = _popup_track_transform(player, pivot)
	_expect(expected.origin.distance_to(deployed_rest.origin) > 0.1,
		"undeploy track must be at a non-rest position")
	_expect(pivot.transform.is_equal_approx(expected), "undeploy pivot must match complete keyed transform")
	for tick in 25:
		building.sim_tick()
		if building._popup_turret_state == 0:
			break
	_expect(building._popup_turret_state == 0, "popup must reach retracted state")
	turret.current_yaw = 0.7
	await process_frame
	await process_frame
	var retracted_rest: Transform3D = turret._pivot_rest_transforms[pivot]
	_expect(pivot.transform.is_equal_approx(retracted_rest),
		"retracted popup must not paint hidden logical yaw")
	building.free()


func _test_fire_frame_repaint() -> void:
	var building := HKGunTurretScene.instantiate() as Building
	root.add_child(building)
	await process_frame
	var turret = building.combat_turrets[0]
	_expect(building.command_attack(_lateral_point(turret)), "Fire pose case needs lateral order")
	for tick in 100:
		building.sim_tick()
		if building._authored_fire_controller.is_active():
			break
	_expect(building._authored_fire_controller.is_active(), "Fire clip must be active")
	var yaw: float = turret.current_yaw
	var pivot: Node3D = turret._yaw_pivot
	var rest: Transform3D = turret._pivot_rest_transforms[pivot]
	_expect(absf(yaw) > 0.3, "Fire case needs substantial yaw")
	var descendant := building.state_root(building.current_state).find_child("*barrelR1*", true, false) as Node3D
	_expect(descendant != null, "Fire case needs an authored barrel descendant")
	var descendant_before: Transform3D = descendant.transform if descendant != null else Transform3D.IDENTITY
	await process_frame
	await process_frame
	var expected := Transform3D(rest.basis * Basis(Vector3.UP, yaw), rest.origin)
	_expect(pivot.transform.is_equal_approx(expected), "active Fire clip must preserve tick yaw")
	_expect(is_equal_approx(turret.current_yaw, yaw), "Fire frame cannot change logical yaw")
	var state: Dictionary = building._authored_fire_controller._sequences.values()[0]
	var player := state["player"] as AnimationPlayer
	_expect(player.is_playing(), "authored Fire clip must still be playing")
	if descendant != null:
		_expect(not descendant.transform.is_equal_approx(descendant_before),
			"authored Fire clip must still animate a descendant barrel")
	building.free()
