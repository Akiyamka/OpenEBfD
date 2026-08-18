extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")

const CombatTurretScript := preload("res://scripts/combat/combat_turret.gd")
const CombatLingerEffectScript := preload("res://scripts/combat/combat_linger_effect.gd")
const CombatBullets := preload("res://tests/combat/support/combat_bullets.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const BuildingDefinitionCatalogScript := preload(
	"res://scripts/buildings/building_definition_catalog.gd"
)
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SpiceMoundScene := preload("res://scenes/world/spice_mound.tscn")
const HarvesterControllerScript := preload("res://scripts/units/harvester_controller.gd")
const HarvesterScene := preload("res://scenes/units/harvester.tscn")
const ATRefineryScene := preload("res://assets/converted/buildings/ATRefinery/ATRefinery.scn")
const HKConYardScene := preload("res://assets/converted/buildings/HKConYard/HKConYard.scn")
const ATMongooseModelScene := preload(
	"res://assets/converted/models/AT_mongoose_H0/AT_mongoose_H0.scn"
)
const ATMinotaurusModelScene := preload(
	"res://assets/converted/models/AT_minotaurus_H0/AT_minotaurus_H0.scn"
)
const HKDevastatorModelScene := preload(
	"res://assets/converted/models/HK_devastator_H0/HK_devastator_H0.scn"
)

## Regression test for a startup-ordering bug: Match._enter_tree() used to
## compute the building-panel roster via Rules.buildable_building_ids_for_house(),
## but the Rules autoload only loads its catalog in its own _ready() --
## _enter_tree() fires for the whole tree before any _ready() does, so that
## roster always read an empty catalog and the panel showed nothing buildable
## even with a Construction Yard and Windtrap already on the map. The fix
## moved the roster computation into Match._ready() instead.

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case("units and buildings use authored collision meshes", _test_authored_collision_meshes)
	await _run_case("ground vehicles follow terrain elevation and slope", _test_units_follow_terrain)
	await _run_case("units turn at their rules rates", _test_unit_turn_rates)
	await _run_case("entity forward directions share one world-space contract", _test_entity_orientation_contract)
	await _run_case("units switch between stationary and movement animations", _test_unit_movement_animations)
	await _run_case("mechs follow authored gait speeds", _test_mech_gait_speeds)
	await _run_case("mechs use authored locomotion transitions", _test_mech_locomotion_transitions)
	await _run_case("test match roster is non-empty after boot", _test_match_roster_populated)
	await _run_case(
		"the match loop advances the simulation clock at the tick rate, not the frame rate",
		_test_match_loop_drives_the_clock
	)
	await _run_case(
		"a real unit's turret reload advances from the match loop alone",
		_test_match_loop_drives_unit_turret_reload
	)
	await _run_case(
		"a real linger effect's delivered ticks advance from the match loop alone",
		_test_match_loop_drives_unit_linger_effect
	)
	await _run_case(
		"a real spice mound's maturity countdown advances from the match loop alone",
		_test_match_loop_drives_spice_mound_maturity
	)
	await _run_case(
		"a real spice layer's spread countdown advances from the match loop alone",
		_test_match_loop_drives_spice_layer
	)
	await _run_case("roster controls leave arrow keys to the camera", _test_roster_controls_ignore_keyboard_focus)
	await _run_case("F3 toggles every navigation debug layer", _test_unified_debug_shortcut)
	await _run_case("rules art configs resolve every test panel icon", _test_match_panel_icons)
	await _run_case("rules sidebar type selects the panel tab", _test_rules_sidebar_tabs)
	await _run_case("a dying building's corpse does not break sidebar house-page refresh", _test_dying_building_survives_sidebar_refresh)
	await _run_case("upgrade panel only lists buildings with an upgrade defined", _test_upgrade_panel_matches_controller)
	await _run_case("upgrade slot appears after its building is placed later", _test_upgrade_availability_polls)
	await _run_case("unit slots follow prerequisite buildings and their upgrades", _test_unit_roster_availability)
	await _run_case("shared units prefer their owner's native production building", _test_shared_unit_native_producer)
	await _run_case("completed units emerge from primary building toward rally point", _test_unit_production_rally_and_primary)
	await _run_case("real match units execute forced friendly attack orders", _test_real_forced_friendly_attack)
	await _run_case("real harvester completes a refinery unload trip", _test_real_harvester_unload_trip)
	await _run_case("occupy matrices match converted model orientation", _test_occupy_rows_are_mirrored)

	if _failures > 0:
		printerr("Match integration tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Match integration tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_authored_collision_meshes() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame
	var navigation := match_instance.get_node_or_null("UnitNavigationSystem")

	for unit_name in [&"ScoutA", &"OrdosAPC", &"NIABTank"]:
		var unit := match_instance.get_node("Units/%s" % unit_name)
		_expect(unit._collision_sources().size() > 0, "%s must expose an authored collision volume" % unit_name)
		var rule_size := float(unit.unit_definition.size)
		var rule_radius := maxf(0.35, rule_size * 0.42)
		var navigation_radius := float(unit.navigation_collision_radius(rule_radius))
		_expect(
			navigation_radius > rule_radius * 1.2,
			"%s navigation radius must reflect its authored body width (%.2f, rules-only %.2f)" % [unit_name, navigation_radius, rule_radius]
		)
		var registered_radius := float(navigation.agent_debug(unit).get("radius", 0.0)) if navigation != null else 0.0
		_expect(
			is_equal_approx(registered_radius, navigation_radius),
			"%s navigation agent must use authored radius %.2f (got %.2f)" % [unit_name, navigation_radius, registered_radius]
		)
		_expect(
			_authored_collision_shapes(unit).size() > 0,
			"%s must create a collision shape from its authored volume" % unit_name
		)
		for collision in _authored_collision_shapes(unit):
			_expect(
				collision.shape is ConvexPolygonShape3D,
				"%s must not use a hand-authored box or capsule collision" % unit_name
			)

	for building_name in [&"ATConYard", &"ATSmWindtrap"]:
		var building := match_instance.get_node("Buildings/%s" % building_name)
		var body := building.get_node_or_null("SelectionCollision") as StaticBody3D
		var halo := building.get_node_or_null("SelectionHalo") as Node3D
		var halo_anchor: Node3D = building._halo_anchor_node(building)
		_expect(body != null, "%s must have a selection collision body" % building_name)
		_expect(halo != null and halo_anchor != null, "%s must expose its authored halo attachment" % building_name)
		if halo != null and halo_anchor != null:
			var expected_halo_position: Vector3 = building.to_local(halo_anchor.global_position)
			_expect(
				halo.position.is_equal_approx(expected_halo_position),
				"%s halo must follow its authored attachment after footprint alignment (expected %s, got %s)" % [
					building_name, expected_halo_position, halo.position,
				]
			)
		_expect(
			body != null and _authored_collision_shapes(body).size() > 0,
			"%s must create collision from its authored volume" % building_name
		)
		for collision in _authored_collision_shapes(body):
			_expect(
				collision.shape is ConvexPolygonShape3D,
				"%s must not fall back to a generated box collision" % building_name
			)

	match_instance.queue_free()


func _test_units_follow_terrain() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame
	await physics_frame
	await physics_frame

	for unit_name in [&"ScoutA", &"OrdosAPC", &"NIABTank"]:
		var unit := match_instance.get_node("Units/%s" % unit_name) as Unit
		_expect(unit.collision_mask == 0, "%s must not physically collide with terrain triangles" % unit_name)
		var terrain_hit := _terrain_hit_below(unit)
		_expect(not terrain_hit.is_empty(), "%s must have terrain beneath it" % unit_name)
		if not terrain_hit.is_empty():
			var terrain_position: Vector3 = terrain_hit["position"]
			var terrain_normal: Vector3 = terrain_hit["normal"]
			_expect(
				is_equal_approx(unit.global_position.y, terrain_position.y),
				"%s must sit on the terrain instead of hovering at its spawn height" % unit_name
			)
			unit.call("_advance_visual_slope_alignment", 1.0)
			var visual_up := unit.visual_root.global_transform.basis.y.normalized()
			if unit_name == &"ScoutA":
				_expect(not unit.aligns_visual_to_terrain_slope(), "infantry must stay upright on slopes")
				_expect(visual_up.dot(Vector3.UP) > 0.999, "infantry visuals must remain upright")
			else:
				_expect(unit.aligns_visual_to_terrain_slope(), "%s must align its visual to slopes" % unit_name)
				_expect(
					visual_up.dot(terrain_normal.normalized()) > 0.999,
					"%s visual up axis must follow the terrain normal" % unit_name
				)

	var vehicle := match_instance.get_node("Units/OrdosAPC") as Unit
	var synthetic_normal := Vector3(0.35, 1.0, -0.2).normalized()
	vehicle.call("_set_visual_slope_target", synthetic_normal)
	vehicle.call("_advance_visual_slope_alignment", 1.0)
	_expect(
		vehicle.visual_root.global_transform.basis.y.normalized().dot(synthetic_normal) > 0.999,
		"a ground vehicle must pitch and roll toward a non-flat terrain normal"
	)

	var infantry := match_instance.get_node("Units/ScoutA") as Unit
	infantry.setup(&"ATMongoose")
	_expect(not infantry.aligns_visual_to_terrain_slope(), "Mech=true walkers must not tilt their complete visual")
	infantry.setup(&"INTLWalker")
	_expect(not infantry.aligns_visual_to_terrain_slope(), "the legacy Tleilaxu walker must remain upright")

	match_instance.queue_free()


func _terrain_hit_below(unit: CharacterBody3D) -> Dictionary:
	if unit == null:
		return {}
	var position := unit.global_position
	var query := PhysicsRayQueryParameters3D.create(
		position + Vector3.UP * 200.0,
		position - Vector3.UP * 200.0,
		1
	)
	query.exclude = [unit.get_rid()]
	return get_root().get_world_3d().direct_space_state.intersect_ray(query)


func _test_unit_turn_rates() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame

	var expected_rates := {
		&"ScoutA": 0.2,
		&"OrdosAPC": 0.05,
		&"NIABTank": 0.3,
	}
	for unit_name in expected_rates:
		var unit := match_instance.get_node("Units/%s" % unit_name) as Unit
		var expected_rate: float = expected_rates[unit_name]
		_expect(
			is_equal_approx(unit.turn_rate, expected_rate),
			"%s must load turn_rate %.3f from its unit rules (got %.3f)" % [unit_name, expected_rate, unit.turn_rate]
		)
		unit.rotation = Vector3.ZERO
		unit.call("_turn_toward", Vector3.RIGHT, 1.0 / Unit.RULE_MOVEMENT_UPDATES_PER_SECOND)
		_expect(
			is_equal_approx(absf(unit.rotation.y), expected_rate),
			"%s must turn by %.3f radians in one rules movement update (got %.3f)" % [unit_name, expected_rate, absf(unit.rotation.y)]
		)

	var omnidirectional := match_instance.get_node("Units/OrdosAPC") as Unit
	_expect(omnidirectional.can_move_any_direction, "ORAPC must load CanMoveAnyDirection=true from its rules")
	omnidirectional.rotation = Vector3.ZERO
	var omnidirectional_start := omnidirectional.global_position
	omnidirectional.navigation_step(Vector3.RIGHT * omnidirectional.move_speed, 1.0 / Unit.RULE_MOVEMENT_UPDATES_PER_SECOND)
	_expect(
		omnidirectional.global_position.x > omnidirectional_start.x,
		"an omnidirectional unit must translate while it is still turning"
	)
	_expect(
		not is_equal_approx(omnidirectional.rotation.y, -PI / 2.0),
		"the omnidirectional unit must still obey its turn-rate limit while translating"
	)

	var sequential := match_instance.get_node("Units/ScoutA") as Unit
	sequential.setup(&"IMTANK")
	_expect(not sequential.can_move_any_direction, "a null CanMoveAnyDirection rule must load as false")
	sequential.rotation = Vector3.ZERO
	var sequential_start := sequential.global_position
	var tick_delta := 1.0 / Unit.RULE_MOVEMENT_UPDATES_PER_SECOND
	sequential.navigation_step(Vector3.RIGHT * sequential.move_speed, tick_delta)
	_expect(
		is_equal_approx(sequential.global_position.x, sequential_start.x)
			and is_equal_approx(sequential.global_position.z, sequential_start.z),
		"a sequential unit must stay in place while turning toward its movement direction"
	)
	_expect(sequential.velocity.is_zero_approx(), "a sequential unit must expose zero velocity while turning in place")
	for _update in 9:
		sequential.navigation_step(Vector3.RIGHT * sequential.move_speed, tick_delta)
	_expect(
		sequential.global_position.x > sequential_start.x,
		"a sequential unit must begin translating after it finishes turning"
	)

	match_instance.queue_free()


func _test_entity_orientation_contract() -> void:
	var building := Building.new()
	var unit := Unit.new()
	for yaw in [0.0, PI / 2.0, PI, -PI / 2.0]:
		building.rotation = Vector3(0.0, yaw, 0.0)
		unit.face_direction(building.exit_direction())
		_expect(
			unit.facing_direction().dot(building.exit_direction()) > 0.999,
			"a unit must face a building's exit at yaw %.3f without knowing either asset's local axis" % yaw
		)
	building.free()
	unit.free()


func _test_unit_movement_animations() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame
	await physics_frame
	await physics_frame

	for unit_name in [&"ScoutA", &"OrdosAPC", &"NIABTank"]:
		var unit := match_instance.get_node("Units/%s" % unit_name) as Unit
		var player := _unit_animation_player(unit)
		_expect(player != null, "%s must expose a model AnimationPlayer" % unit_name)
		_expect(player != null and _is_unit_idle(player), "%s must start with an idle animation" % unit_name)
		if player != null and _idle_animation_count(player) > 0:
			_expect(player.current_animation == &"Stationary", "%s idle sequence must start with Stationary" % unit_name)
			if player.has_animation(&"Idle_0") and player.has_animation(&"Idle_1"):
				_expect(
					unit._idle_animations.weight_of(&"Idle_0") > unit._idle_animations.weight_of(&"Idle_1"),
					"%s higher-numbered Idle* clips must have lower selection weight" % unit_name
				)
			var stationary_plays := 0
			while player.current_animation == &"Stationary" and stationary_plays < 16:
				stationary_plays += 1
				player.animation_finished.emit(&"Stationary")
			_expect(stationary_plays >= 5 and stationary_plays <= 15, "%s must play Stationary 5-15 times" % unit_name)
			_expect(String(player.current_animation).begins_with("Idle"), "%s must play a random Idle* after Stationary" % unit_name)
			player.animation_finished.emit(player.current_animation)
			_expect(player.current_animation == &"Stationary", "%s must restart with Stationary after Idle*" % unit_name)
		unit.move_to(unit.global_position + Vector3(3.0, 0.0, 0.0))
		for _frame in 20:
			await physics_frame
			if unit.velocity.length_squared() > 0.01:
				break
		_expect(player != null and player.current_animation == &"Move", "%s must play Move while travelling" % unit_name)
		_expect(
			player != null and is_equal_approx(player.speed_scale, unit.velocity.length() / unit.move_speed),
			"%s Move animation speed must match its physical velocity" % unit_name
		)
		unit.stop_at_current_position()
		_expect(player != null and _is_unit_idle(player), "%s must return to an idle animation when stopped" % unit_name)
		_expect(player != null and is_equal_approx(player.speed_scale, 1.0), "%s must reset its animation speed when stopped" % unit_name)

	match_instance.queue_free()


func _test_mech_gait_speeds() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame

	var unit := match_instance.get_node("Units/ScoutA") as Unit
	unit.setup(&"ATMongoose")
	unit.replace_visual_scene(ATMongooseModelScene)
	var configured_speed := float(unit.unit_definition.speed)
	var configured_mech_speed := float(unit.unit_definition.mech_speed)
	_expect(
		is_equal_approx(unit.move_speed, configured_speed),
		"Mongoose must load its editable Speed rule"
	)
	_expect(
		is_equal_approx(unit.mech_speed, configured_mech_speed),
		"Mongoose must load its editable MechSpeed rule"
	)
	var authored_average := unit._locomotion.authored_average_speed()
	var cadence := unit._locomotion.gait_cadence()
	_expect(
		is_equal_approx(authored_average, 2.66),
		"Mongoose must average its authored 1.0/3.5/0.8 Move speed events"
	)
	_expect(
		is_equal_approx(authored_average * cadence, unit.mech_speed),
		"MechSpeed must calibrate the authored profile's average through cadence"
	)

	unit._locomotion.seek_gait_phase(0.0)
	_expect(
		is_equal_approx(unit.navigation_move_speed(), 1.0 * cadence),
		"Mongoose Move must begin with its authored 1.0 speed"
	)
	unit._locomotion.seek_gait_phase(0.20)
	_expect(
		is_equal_approx(unit.navigation_move_speed(), 3.5 * cadence),
		"Mongoose must switch to its authored fast phase at frame 6"
	)
	unit._locomotion.seek_gait_phase(0.60)
	_expect(
		is_equal_approx(unit.navigation_move_speed(), 0.8 * cadence),
		"Mongoose must switch to its authored slow phase at frame 14"
	)
	_expect(
		unit.navigation_move_speed() < unit.move_speed,
		"a mech gait must never use the ordinary Speed rule"
	)

	unit.velocity = Vector3.RIGHT * unit.navigation_move_speed()
	_expect(
		is_equal_approx(unit._locomotion.movement_animation_speed_scale(), cadence),
		"the physical XBF speed and Move playback must share one cadence"
	)

	unit.setup(&"HKDevastator")
	unit.replace_visual_scene(HKDevastatorModelScene)
	var forward := unit.facing_direction()
	unit.set_navigation_destination(unit.global_position + forward * 10.0)
	unit._locomotion.seek_gait_phase(0.0)
	_expect(
		is_zero_approx(unit.navigation_move_speed()),
		"Devastator must begin Move with its authored zero-speed phase"
	)
	unit.navigation_step(Vector3.ZERO, 0.1)
	var devastator_player := _unit_animation_player(unit)
	_expect(
		devastator_player != null
		and devastator_player.current_animation == &"Move_Start"
		and is_zero_approx(unit._locomotion.gait_phase()),
		"Devastator must finish Move_Start before beginning its zero-speed Move phase"
	)
	if devastator_player != null:
		devastator_player.animation_finished.emit(&"Move_Start")
	unit.navigation_step(Vector3.ZERO, 0.1)
	_expect(
		unit._locomotion.gait_phase() > 0.0
		and devastator_player != null
		and devastator_player.current_animation == &"Move",
		"an authored zero-speed Move phase must advance instead of resetting to idle"
	)

	var navigation = unit.get("_navigation_system")
	if navigation != null:
		navigation.unregister_unit(unit)
		navigation.register_unit(unit)
	var navigation_arrival := float(navigation.arrival_tolerance(unit)) \
		if navigation != null else unit.arrival_radius
	_expect(
		navigation_arrival > unit.arrival_radius,
		"Devastator's large body must use a wider navigation arrival tolerance"
	)
	var parked_distance := lerpf(unit.arrival_radius, navigation_arrival, 0.5)
	unit.set_navigation_destination(unit.global_position + unit.facing_direction() * parked_distance)
	unit._locomotion.seek_gait_phase(0.0)
	unit.navigation_step(Vector3.ZERO, 0.1)
	_expect(
		devastator_player != null and devastator_player.current_animation == &"Move_Stop",
		"Devastator must stop its gait when navigation considers the destination reached"
	)

	unit.setup(&"IMTANK")
	_expect(
		is_equal_approx(unit.navigation_move_speed(), unit.move_speed),
		"non-mechs must retain their ordinary constant movement speed"
	)
	match_instance.queue_free()


func _test_mech_locomotion_transitions() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame

	var unit := match_instance.get_node("Units/ScoutA") as Unit
	var mech_models := [
		[&"ATMongoose", ATMongooseModelScene],
		[&"ATMinotaurus", ATMinotaurusModelScene],
		[&"HKDevastator", HKDevastatorModelScene],
	]
	for model_case: Array in mech_models:
		unit.setup(model_case[0])
		unit.replace_visual_scene(model_case[1])
		var model_player := _unit_animation_player(unit)
		_expect(model_player != null, "%s must expose locomotion animations" % model_case[0])
		if model_player == null:
			continue
		for clip_name in [&"Move_Start", &"Move_Stop", &"Turn_Left", &"Turn_Right"]:
			_expect(
				model_player.has_animation(clip_name),
				"%s must retain its authored %s clip" % [model_case[0], clip_name]
			)

	unit.setup(&"ATMongoose")
	unit.replace_visual_scene(ATMongooseModelScene)
	var player := _unit_animation_player(unit)
	var tick_delta := 1.0 / Unit.RULE_MOVEMENT_UPDATES_PER_SECOND
	var forward := Vector3.FORWARD
	unit.face_direction(forward)
	unit.set_navigation_destination(unit.global_position + forward * 10.0)
	var start_position := unit.global_position
	unit.navigation_step(forward * unit.navigation_move_speed(), tick_delta)
	_expect(
		player != null and player.current_animation == &"Move_Start",
		"a stationary mech must play Move_Start before Move"
	)
	_expect(
		Vector2(unit.global_position.x, unit.global_position.z).is_equal_approx(
			Vector2(start_position.x, start_position.z)
		),
		"a mech must remain in place while Move_Start is playing"
	)

	if player != null:
		player.animation_finished.emit(&"Move_Start")
	_expect(
		player != null and player.current_animation == &"Move",
		"Move_Start completion must enter the looping Move animation"
	)
	unit.navigation_step(forward * unit.navigation_move_speed(), tick_delta)
	_expect(
		unit.global_position.distance_to(start_position) > 0.0,
		"a mech must translate after Move_Start has completed"
	)

	unit.stop_at_current_position()
	_expect(
		player != null and player.current_animation == &"Move_Stop",
		"a moving mech must play Move_Stop when its order ends"
	)
	if player != null:
		player.animation_finished.emit(&"Move_Stop")
	_expect(
		player != null and _is_unit_idle(player),
		"Move_Stop completion must return the mech to Stationary"
	)

	unit.rotation = Vector3.ZERO
	unit.set_navigation_destination(unit.global_position + Vector3.RIGHT * 10.0)
	unit.navigation_step(Vector3.RIGHT * unit.navigation_move_speed(), tick_delta)
	_expect(
		player != null and player.current_animation == &"Turn_Right",
		"a clockwise in-place turn must use Turn_Right"
	)

	unit.rotation = Vector3.ZERO
	unit.set_navigation_destination(unit.global_position + Vector3.LEFT * 10.0)
	unit.navigation_step(Vector3.LEFT * unit.navigation_move_speed(), tick_delta)
	_expect(
		player != null and player.current_animation == &"Turn_Left",
		"a counter-clockwise in-place turn must use Turn_Left"
	)

	unit.face_direction(Vector3.LEFT)
	unit.navigation_step(Vector3.LEFT * unit.navigation_move_speed(), tick_delta)
	_expect(
		player != null and player.current_animation == &"Move_Start",
		"finishing an in-place turn must transition through Move_Start"
	)

	match_instance.queue_free()


func _unit_animation_player(unit: Unit) -> AnimationPlayer:
	if unit == null:
		return null
	var players := unit.get_node("VisualRoot").find_children("*", "AnimationPlayer", true, false)
	for node in players:
		var player := node as AnimationPlayer
		if player.has_animation(&"Move") and player.has_animation(&"Stationary"):
			return player
	return null


func _projectile_has_visible_mesh(projectile: Node) -> bool:
	if projectile == null:
		return false
	var visual := projectile.get_node_or_null("Visual")
	return visual is MeshInstance3D \
		or (visual != null and not visual.find_children("*", "MeshInstance3D", true, false).is_empty())


func _is_unit_idle(player: AnimationPlayer) -> bool:
	if player == null:
		return false
	if _idle_animation_count(player) > 0:
		return player.current_animation == &"Stationary" or String(player.current_animation).begins_with("Idle")
	return player.current_animation == &"Stationary"


func _idle_animation_count(player: AnimationPlayer) -> int:
	var idle_variants := 0
	for animation_name in player.get_animation_list():
		if String(animation_name).begins_with("Idle"):
			idle_variants += 1
	return idle_variants


func _authored_collision_shapes(node: Node) -> Array[CollisionShape3D]:
	var result: Array[CollisionShape3D] = []
	if node == null:
		return result
	for child in node.get_children():
		if child is CollisionShape3D:
			result.append(child)
	return result


func _test_match_roster_populated() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	_expect(
		not match_instance._building_option_ids.is_empty(),
		"the local player's building roster must not be empty when a Construction Yard already exists"
	)
	_expect(
		match_instance._building_option_ids.has(&"ATBarracks"),
		"ATBarracks must be available given the fixture's starting ATConYard + ATSmWindtrap"
	)

	var side_panel = match_instance.get_node("HUD/SidePanel")
	_expect(
		side_panel._building_option_ids.has(&"ATBarracks"),
		"the roster must reach the side panel's building grid, not just Match's own state"
	)

	match_instance.queue_free()


## The one case that proves the wiring rather than the parts. Every other test
## of tick-driven behaviour calls a controller's advance_tick() directly, so
## all of them would still pass if Match._process() never reached
## _advance_simulation_tick() at all -- the systems would simply stop running
## in a real match while the suite stayed green. This boots the real match
## scene and lets its own loop run.
##
## Two bounds, because a positive tick count on its own only proves that
## something moves, not that it moves at the right rate. Driving the clock
## once per frame instead -- the obvious way to get this wrong -- is caught by
## both: it produces one tick per frame against a loop that runs frames far
## faster than 25 Hz, and roughly 60 ticks a second against a wall-clock bound
## of 25.
func _test_match_loop_drives_the_clock() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	# Scene instantiation lands in the first frame's delta, which is far larger
	# than any later one and would otherwise be charged to the sampling window
	# as ticks without contributing its milliseconds. Let the loop settle into
	# ordinary frames before anything is sampled.
	for _warmup in 5:
		await process_frame
	var started_msec := Time.get_ticks_msec()
	var started_tick: int = match_instance.current_tick()

	# Long enough for several ticks even if every frame runs at the 60 fps cap,
	# with a frame cap so a stalled loop fails the assertions below instead of
	# hanging the suite.
	var frames := 0
	while Time.get_ticks_msec() - started_msec < 200 and frames < 400:
		await process_frame
		frames += 1

	var elapsed_msec := Time.get_ticks_msec() - started_msec
	var advanced: int = match_instance.current_tick() - started_tick
	# Two ticks of slack: one for the sub-tick remainder the driver was already
	# carrying when sampling started, and one for the frame boundary, since
	# process_frame and the node's own _process do not fire at the same instant.
	var upper_bound := roundi(
		float(elapsed_msec) * float(MatchClockScript.TICKS_PER_SECOND) / 1000.0
	) + 2
	_expect(
		advanced >= 3,
		"%d ms of the real match loop must advance the clock at least 3 ticks, got %d" \
			% [elapsed_msec, advanced]
	)
	_expect(
		advanced <= upper_bound,
		"the clock must advance at the tick rate, not once per frame: %d ticks in %d ms exceeds the %d the rate allows" \
			% [advanced, elapsed_msec, upper_bound]
	)
	# The same property without a clock in it: this loop runs frames well above
	# 25 Hz, so ticks must come out strictly rarer than frames.
	_expect(
		advanced < frames,
		"the clock must advance less often than once per frame: %d ticks over %d frames" \
			% [advanced, frames]
	)

	match_instance.queue_free()


## The per-entity counterpart to _test_match_loop_drives_the_clock above.
## Every other assertion of turret reload counting down (turret_mount_run.gd,
## unit_attack_order_run.gd, and the fire-sequence cases in this file) calls
## CombatTurret.advance_tick() directly or fires through the real fire
## sequence -- all of it would keep passing even if Unit.sim_tick() were never
## reached from Match._advance_simulation_tick(), because nothing here calls
## sim_tick() itself. Forgetting to add a new per-entity system to that
## central loop (see its doc comment) is exactly the failure mode this test
## exists to catch, so it boots the real match scene and lets its own loop
## run, the same way _test_match_loop_drives_the_clock does.
##
## ScoutA (scenes/units/unit.tscn) authors config_id="ATInfantry" with its
## AT_inf_H0 model already instanced as a VisualRoot child, so its ATInfGun
## turret is configured and bound by _ready() with no setup() call needed.
## reload_ticks_remaining starts driven into a known state far above what a
## short real-time window can exhaust, so the window's tick count can be read
## straight off the counter's drop with no clamping to zero in the way.
func _test_match_loop_drives_unit_turret_reload() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var attacker := match_instance.get_node("Units/ScoutA") as Unit
	_expect(
		not attacker.combat_turrets.is_empty(),
		"ScoutA must boot with its ATInfGun turret already configured and bound"
	)
	var turret = attacker.combat_turrets[0]
	turret.reload_ticks_remaining = 1000
	var started_msec := Time.get_ticks_msec()
	var started_tick: int = match_instance.current_tick()
	var started_reload: int = turret.reload_ticks_remaining

	var frames := 0
	while Time.get_ticks_msec() - started_msec < 200 and frames < 400:
		await process_frame
		frames += 1

	var advanced_ticks: int = match_instance.current_tick() - started_tick
	var advanced_reload: int = started_reload - turret.reload_ticks_remaining
	_expect(
		advanced_ticks >= 3,
		"%d ms of the real match loop must advance the clock at least 3 ticks, got %d" \
			% [Time.get_ticks_msec() - started_msec, advanced_ticks]
	)
	# Both counters are advanced from the same due-tick loop within the same
	# frame (see match.gd::_advance_simulation_tick()), so -- as long as 1000
	# ticks is nowhere near exhausted, which this bounded window guarantees --
	# the drop is exact, not just approximate.
	_expect(
		advanced_reload == advanced_ticks,
		"a real unit's turret reload must advance by exactly one tick per simulation tick from the match loop alone: reload dropped by %d against %d clock ticks" \
			% [advanced_reload, advanced_ticks]
	)

	match_instance.queue_free()


## The linger-effect counterpart to _test_match_loop_drives_unit_turret_reload
## above -- same failure mode, same shape. Every other lingering-damage
## assertion (bullet_rules_run.gd's _test_lingering_gas_damage) drives the
## effect with direct sim_tick() calls, so it would keep passing even if
## CombatLingerEffect were never reached from
## Match._advance_simulation_tick()'s "sim_linger_effects" loop, because
## nothing here calls sim_tick() itself either. Forgetting to add a spawned
## system to that central loop (see its doc comment, and the ordering
## paragraph explaining why linger effects resolve after units and buildings)
## is exactly the failure mode this test exists to catch, so it boots the
## real match scene, configures a real CombatLingerEffect against a real unit
## from that scene, and lets the match loop's own ticking discover and drive
## it -- the same way the turret case discovers Unit.sim_tick().
##
## remaining_ticks starts driven into a known state far above what a short
## real-time window can exhaust, the same reason turret_reload above sets
## reload_ticks_remaining = 1000, so the window's tick count can be read
## straight off delivered_ticks with no clamping in the way. The target's
## health is likewise pushed far above what 50 authored GasInf_B linger ticks
## could ever deliver, so the countdown is never cut short by
## CombatLingerEffect.sim_tick()'s "target died" early-out.
func _test_match_loop_drives_unit_linger_effect() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var target := match_instance.get_node("Units/ScoutA") as Unit
	target.max_health = 100000.0
	target.health = target.max_health
	target.max_shields = 0.0
	target.shields = 0.0

	var gas = CombatBullets.new().runtime_bullet(&"GasInf_B")
	var effect := CombatLingerEffectScript.new()
	match_instance.add_child(effect)
	_expect(
		effect.configure(gas, target, target.global_position),
		"GasInf_B must create a target-bound lingering payload against a real match unit"
	)
	effect.remaining_ticks = 1000

	var started_msec := Time.get_ticks_msec()
	var started_tick: int = match_instance.current_tick()
	var started_delivered: int = effect.delivered_ticks

	var frames := 0
	while Time.get_ticks_msec() - started_msec < 200 and frames < 400:
		await process_frame
		frames += 1

	var advanced_ticks: int = match_instance.current_tick() - started_tick
	var advanced_delivered: int = effect.delivered_ticks - started_delivered
	_expect(
		advanced_ticks >= 3,
		"%d ms of the real match loop must advance the clock at least 3 ticks, got %d" \
			% [Time.get_ticks_msec() - started_msec, advanced_ticks]
	)
	# Same reasoning as the turret reload case above: both counters are
	# advanced from the same due-tick loop within the same frame (see
	# match.gd::_advance_simulation_tick()), so -- as long as 1000 ticks is
	# nowhere near exhausted, which this bounded window guarantees -- the
	# drop is exact, not just approximate.
	_expect(
		advanced_delivered == advanced_ticks,
		"a real linger effect must deliver exactly one damage tick per simulation tick from the match loop alone: delivered_ticks advanced by %d against %d clock ticks" \
			% [advanced_delivered, advanced_ticks]
	)

	effect.queue_free()
	match_instance.queue_free()


func _test_match_loop_drives_spice_mound_maturity() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	# The fixture scene (tests/fixtures/match_fixture.tscn) carries no spice
	# mound of its own -- nothing else in this suite needs one -- so this is
	# the one place a real mound has to be wired into a real match, and this
	# case adds it directly rather than skip the only coverage of that wiring.
	var mound := SpiceMoundScene.instantiate()
	mound.configure(Vector2i(0, 0), Vector2(4.0, 4.0))
	match_instance.add_child(mound)
	# _ready() (just run by add_child above) already armed the countdown from
	# the default rules catalog, drawing an unseeded randf() in the process
	# (see spice_mound.gd's maturity_duration_ticks() -- left alone
	# deliberately, that's phase 4's determinism gate, not this slice's).
	# Overwrite it with a fixed, generous countdown, the same way the
	# linger-effect case above overwrites remaining_ticks: this case is only
	# about whether the match loop drains the countdown at all, not about the
	# authored duration.
	mound.maturity_ticks_remaining = 1000

	var started_msec := Time.get_ticks_msec()
	var started_tick: int = match_instance.current_tick()
	var started_remaining: int = mound.maturity_ticks_remaining

	var frames := 0
	while Time.get_ticks_msec() - started_msec < 200 and frames < 400:
		await process_frame
		frames += 1

	var advanced_ticks: int = match_instance.current_tick() - started_tick
	var advanced_countdown: int = started_remaining - mound.maturity_ticks_remaining
	_expect(
		advanced_ticks >= 3,
		"%d ms of the real match loop must advance the clock at least 3 ticks, got %d" \
			% [Time.get_ticks_msec() - started_msec, advanced_ticks]
	)
	# Same reasoning as the linger-effect case above: both counters are
	# advanced from the same due-tick loop within the same frame (see
	# match.gd::_advance_simulation_tick()), so -- as long as 1000 ticks is
	# nowhere near exhausted, which this bounded window guarantees -- the
	# drop is exact, not just approximate. Nothing in this test body calls
	# sim_tick() or touches the countdown itself after the override above;
	# only the match's own _process() loop does from here on, which is
	# exactly the wiring this case exists to prove.
	_expect(
		advanced_countdown == advanced_ticks,
		"a real spice mound must drop its maturity countdown by exactly one simulation tick per clock tick from the match loop alone: countdown dropped by %d against %d clock ticks" \
			% [advanced_countdown, advanced_ticks]
	)

	mound.queue_free()
	match_instance.queue_free()


## The spice layer is the only step in Match._advance_simulation_tick() that is
## not a group loop -- it is called directly through terrain.spice_layer -- so
## it is also the only one a typo in that call chain could silently drop while
## every spice unit test in tests/maps/run.gd stayed green, since those drive
## MapSpiceLayer.sim_tick() themselves. Same shape and same reason as the
## turret, linger and mound wiring cases above: boot the real match, touch
## nothing, and require the countdown to move on its own.
##
## The job is placed straight into the spread's _active rather than started
## through start(): a real bloom needs a matured mound, and waiting minutes of
## simulated time for one is not what this case is measuring.
func _test_match_loop_drives_spice_layer() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var spice_layer: Variant = match_instance.terrain.spice_layer
	_expect(spice_layer != null, "the match fixture's terrain must expose a loaded spice layer")
	if spice_layer == null:
		match_instance.queue_free()
		return

	# Far above what a 200 ms window can exhaust, so the countdown never
	# reaches zero and releases a ring -- the drop is then a clean read of how
	# many ticks the layer was advanced.
	var source_cell := Vector2i(1, 1)
	spice_layer.spread()._active[source_cell] = {
		"source_cell": source_cell,
		"stage": 0,
		"stage_count": 1,
		"cells": [],
		"interval_ticks": 100000,
		"ticks_remaining": 100000,
	}
	var started_msec := Time.get_ticks_msec()
	var started_tick: int = match_instance.current_tick()

	var frames := 0
	while Time.get_ticks_msec() - started_msec < 200 and frames < 400:
		await process_frame
		frames += 1

	var advanced_ticks: int = match_instance.current_tick() - started_tick
	var job: Dictionary = spice_layer.spread()._active.get(source_cell, {})
	var advanced_countdown: int = 100000 - int(job.get("ticks_remaining", 100000))
	_expect(
		advanced_ticks >= 3,
		"%d ms of the real match loop must advance the clock at least 3 ticks, got %d" \
			% [Time.get_ticks_msec() - started_msec, advanced_ticks]
	)
	_expect(
		advanced_countdown == advanced_ticks,
		"a spread job must lose exactly one tick per simulation tick from the match loop alone: countdown dropped by %d against %d clock ticks" \
			% [advanced_countdown, advanced_ticks]
	)

	spice_layer.spread().cancel(source_cell)
	match_instance.queue_free()


func _test_roster_controls_ignore_keyboard_focus() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	for index in SidePanel.QUEUE_GRID_COLUMNS * SidePanel.QUEUE_GRID_ROWS:
		var slot := side_panel.get_slot(index) as QueueSlot
		_expect(slot != null, "roster slot %d must exist" % index)
		_expect(
			slot != null and slot.focus_mode == Control.FOCUS_NONE,
			"roster slot %d must not participate in arrow-key focus navigation" % index
		)
	for tab: PanelTab in side_panel._tabs:
		_expect(
			tab.focus_mode == Control.FOCUS_NONE,
			"roster tab %s must not participate in arrow-key focus navigation" % tab.name
		)

	match_instance.queue_free()


func _test_unified_debug_shortcut() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var grid_debug = match_instance.get_node("NavigationGridDebug")
	var navigation = match_instance.get_node("UnitNavigationSystem")
	var route_debug = navigation.get_node("NavigationDebug")
	var unit = match_instance.get_node("Units/ScoutA")
	var halo = unit.get_node("SelectionHalo")
	_expect(
		not match_instance.debug_layers_enabled()
		and not grid_debug.is_enabled()
		and not navigation.debug_enabled()
		and not route_debug.is_enabled()
		and not halo.is_movement_debug_visible(),
		"all navigation debug layers must start disabled"
	)

	var f3_event := InputEventKey.new()
	f3_event.keycode = KEY_F3
	f3_event.pressed = true
	_expect(match_instance._handle_debug_shortcut(f3_event), "F3 must own the unified debug shortcut")
	_expect(
		grid_debug.visible
		and navigation.debug_enabled()
		and route_debug.visible
		and halo.is_movement_debug_visible(),
		"F3 must enable the grid, route markers, and final steering arrows together"
	)

	var n_event := InputEventKey.new()
	n_event.keycode = KEY_N
	n_event.pressed = true
	_expect(
		not match_instance._handle_debug_shortcut(n_event)
		and match_instance.debug_layers_enabled(),
		"N must no longer control any navigation debug layer"
	)
	_expect(match_instance._handle_debug_shortcut(f3_event), "a second F3 press must be accepted")
	_expect(
		not grid_debug.visible
		and not navigation.debug_enabled()
		and not route_debug.visible
		and not halo.is_movement_debug_visible(),
		"a second F3 press must disable every navigation debug layer together"
	)

	match_instance.queue_free()


func _test_match_panel_icons() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	var option_ids: Array[StringName] = side_panel._building_option_ids.duplicate()
	for upgrade_id in side_panel._upgrade_option_ids:
		if not option_ids.has(upgrade_id):
			option_ids.append(upgrade_id)
	for option_id in option_ids:
		var icon_data: Array[Texture2D] = side_panel._building_icon_data(option_id)
		_expect(
			icon_data.size() == 2 and icon_data[0] != null and icon_data[1] != null,
			"Rules art config must resolve colored and grey icons for %s" % String(option_id)
		)

	match_instance.queue_free()


func _test_rules_sidebar_tabs() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	_expect(
		side_panel._art_tab_for_entity(&"ATBarracks", SidePanel.Tab.INFANTRY) == SidePanel.Tab.BUILDINGS,
		"Buildings sidebar type must select the Buildings tab"
	)
	_expect(
		side_panel._art_tab_for_entity(&"ATInfantry", SidePanel.Tab.VEHICLES) == SidePanel.Tab.INFANTRY,
		"Infantry sidebar type must select the Infantry tab"
	)
	_expect(
		side_panel._art_tab_for_entity(&"ATAPC", SidePanel.Tab.INFANTRY) == SidePanel.Tab.VEHICLES,
		"Units sidebar type must select the Vehicles tab"
	)

	match_instance.queue_free()


## Regression test: a building's DeathCorpse (BuildingDeathSequence.begin(),
## scripts/buildings/building_death_sequence.gd) is spawned as a sibling
## under the same "Buildings" node Match._refresh_sidebar_house_pages()
## walks every _process() tick. Before that method learned to skip children
## outside the "buildings" group, a corpse landing there (e.g. the local
## player's own Construction Yard corpse) crashed on
## `String(building.get("config_id"))` -- RigidBody3D has no such property.
## Caught via manual testing, not a hypothetical case -- and the crash is a
## non-fatal GDScript runtime error, so it does NOT propagate as an
## exception: it silently aborts the rest of _refresh_sidebar_house_pages()
## for that tick and the game keeps running with no obvious symptom. A test
## that only checks "did calling this throw" would still pass even with the
## bug present (confirmed: it did, before this test was rewritten). The
## actual, observable damage is that anything later in Buildings' child order
## than the corpse never gets processed that tick -- proven here by placing
## a freshly captured foreign Construction Yard after the corpse and
## asserting its house page still registers.
func _test_dying_building_survives_sidebar_refresh() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame

	var con_yard := match_instance.get_node("Buildings/ATConYard") as Building
	con_yard.take_damage(con_yard.max_health + con_yard.max_shields + 10.0, &"")
	_expect(con_yard.is_queued_for_deletion(), "the killing blow must free the Construction Yard")

	var buildings_root := match_instance.get_node("Buildings")
	var corpse: Node3D = null
	for child in buildings_root.get_children():
		if child != con_yard and not (child is Building):
			corpse = child as Node3D
	_expect(corpse != null, "the dying Construction Yard must leave a corpse sibling under Buildings")
	if corpse != null:
		_expect(
			not corpse.is_in_group("buildings"),
			"a building's corpse must never join the \"buildings\" group, or anything that walks"
			+ " Buildings' children by group would try to read config_id/house_id off it and crash"
		)

	# Simulates capturing an enemy Construction Yard the same tick: added
	# after the corpse in Buildings' child order, so it only gets processed
	# if the loop in _refresh_sidebar_house_pages() actually reaches past
	# the corpse instead of aborting on it.
	var captured_yard := HKConYardScene.instantiate() as Building
	captured_yard.owner_player_id = match_instance.LOCAL_PLAYER_ID
	buildings_root.add_child(captured_yard)
	await process_frame

	match_instance._refresh_sidebar_house_pages()

	_expect(
		&"Harkonnen" in match_instance._sidebar_house_pages,
		"a captured foreign Construction Yard placed after a corpse must still register its"
		+ " sidebar house page -- if this fails, the corpse silently swallowed everything after it"
	)

	match_instance.queue_free()


## Regression test: BuildingUpgradeController.setup() filters its incoming
## roster down to buildings with upgrade_cost/upgrade_tech_level both set
## (see _has_upgrade_definition()), but match.gd used to hand the panel the
## raw unfiltered roster instead of the controller's filtered result. A slot
## with no matching upgrade_option_state_changed signal defaults to QueueSlot's
## normal AVAILABLE look, so every building without a real upgrade still
## rendered as one.
func _test_upgrade_panel_matches_controller() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var upgrade_controller = match_instance.get_node("BuildingUpgradeController")
	var controller_ids: Array[StringName] = upgrade_controller.upgrade_option_ids()
	var side_panel = match_instance.get_node("HUD/SidePanel")

	_expect(
		not controller_ids.has(&"ATSmWindtrap"),
		"ATSmWindtrap has no upgrade_cost/upgrade_tech_level in Rules.txt and must not be an upgrade option"
	)
	_expect(
		controller_ids.has(&"ATBarracks"),
		"ATBarracks has both upgrade_cost and upgrade_tech_level and must be an upgrade option"
	)
	_expect(
		controller_ids.has(&"ATConYard"),
		"ATConYard is deployed rather than built but its global upgrade must still be an upgrade option"
	)
	_expect(
		side_panel._upgrade_option_ids == controller_ids,
		"the panel's upgrade grid must exactly match the controller's filtered roster, not the raw building roster"
	)

	match_instance.queue_free()


## Regression test: BuildingController.process() polls _is_building_available()
## every frame and diffs it against a cached dict so the BUILDINGS grid
## reacts to buildings appearing/disappearing elsewhere on the map, but
## BuildingUpgradeController had no equivalent poll -- its option states were
## only computed once at setup() and on queue events, so an upgrade slot for
## a building type the player didn't yet own at boot (e.g. ATBarracks, before
## any Barracks is built) stayed hidden forever even after that building was
## placed. _poll_upgrade_availability() fixes this the same way
## BuildingController already does it.
func _test_upgrade_availability_polls() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	side_panel._set_active_tab(3) # Tab.UPGRADES
	await process_frame

	var slot_before = side_panel._slot_for(SidePanel.OptionKind.UPGRADE, &"ATBarracks")
	_expect(
		slot_before != null and not slot_before.visible,
		"ATBarracks upgrade must start hidden -- the fixture has no Barracks yet"
	)

	var barracks_scene := load("res://assets/converted/buildings/ATBarracks/ATBarracks.scn") as PackedScene
	var barracks := barracks_scene.instantiate()
	match_instance.get_node("Buildings").add_child(barracks)
	barracks.call("setup", &"ATBarracks")
	barracks.call("set_owner_player_id", 1)

	for i in 5:
		await process_frame

	var slot_after = side_panel._slot_for(SidePanel.OptionKind.UPGRADE, &"ATBarracks")
	_expect(
		slot_after != null and slot_after.visible,
		"ATBarracks upgrade must become visible once a Barracks is placed, without any manual refresh call"
	)

	# Once purchased, the slot should disappear rather than linger with an
	# "OWNED" label -- there is nothing left to do with a finished
	# global-type upgrade.
	var players = get_root().get_node_or_null("/root/Players")
	var player = players.player(1)
	player.grant_upgrade(&"ATBarracks")

	for i in 5:
		await process_frame

	var slot_purchased = side_panel._slot_for(SidePanel.OptionKind.UPGRADE, &"ATBarracks")
	_expect(
		slot_purchased != null and not slot_purchased.visible,
		"a purchased upgrade's slot must be hidden, not left visible with an OWNED label"
	)

	match_instance.queue_free()


## Units share the building grid (docs/mechanics/production.md sections 3 and
## 5): a unit's slot must appear only once its primary production building is
## owned, and units flagged upgraded_primary_required must additionally wait
## for that building's upgrade.
func _test_unit_roster_availability() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var side_panel = match_instance.get_node("HUD/SidePanel")
	_expect(
		match_instance._unit_option_ids.has(&"ATInfantry"),
		"the local player's unit roster must include ATInfantry"
	)
	_expect(
		match_instance._unit_option_ids.has(&"Harvester"),
		"the shared house-less Harvester must be in the unit roster"
	)
	_expect(
		side_panel._building_option_ids.has(&"ATInfantry"),
		"the unit roster must reach the side panel grid"
	)

	# Tab.INFANTRY is the panel's boot default, so both slots are live.
	var infantry_slot = side_panel._slot_for(SidePanel.OptionKind.BUILDING, &"ATInfantry")
	var kindjal_slot = side_panel._slot_for(SidePanel.OptionKind.BUILDING, &"ATKindjal")
	_expect(
		infantry_slot != null and infantry_slot.visible and infantry_slot.disabled,
		"ATInfantry must retain its fixed empty slot before a Barracks exists"
	)
	_expect(
		kindjal_slot != null and kindjal_slot.visible and kindjal_slot.disabled,
		"ATKindjal must retain its fixed empty slot without a Barracks"
	)

	var barracks_scene := load("res://assets/converted/buildings/ATBarracks/ATBarracks.scn") as PackedScene
	var barracks := barracks_scene.instantiate()
	match_instance.get_node("Buildings").add_child(barracks)
	barracks.call("setup", &"ATBarracks")
	barracks.call("set_owner_player_id", 1)
	barracks.call("begin_construction")

	for i in 5:
		await process_frame

	infantry_slot = side_panel._slot_for(SidePanel.OptionKind.BUILDING, &"ATInfantry")
	kindjal_slot = side_panel._slot_for(SidePanel.OptionKind.BUILDING, &"ATKindjal")
	_expect(
		infantry_slot != null and infantry_slot.visible and infantry_slot.disabled,
		"ATInfantry must retain its slot while the owned Barracks is being built"
	)
	_expect(
		kindjal_slot != null and kindjal_slot.visible and kindjal_slot.disabled,
		"ATKindjal must retain its slot behind an unupgraded Barracks"
	)
	var roster = match_instance.get_node("UnitRosterController") as UnitRosterController
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 0,
		"a direct unit intent must not bypass an unfinished production building"
	)

	barracks.call("finish_construction")
	for i in 5:
		await process_frame

	infantry_slot = side_panel._slot_for(SidePanel.OptionKind.BUILDING, &"ATInfantry")
	_expect(
		infantry_slot != null and infantry_slot.visible,
		"ATInfantry must become visible after the Barracks construction animation completes"
	)

	barracks.call("set_upgrade_level", 1)

	for i in 5:
		await process_frame

	kindjal_slot = side_panel._slot_for(SidePanel.OptionKind.BUILDING, &"ATKindjal")
	_expect(
		kindjal_slot != null and kindjal_slot.visible,
		"ATKindjal must become visible once the Barracks is upgraded"
	)

	match_instance.queue_free()


func _test_unit_production_rally_and_primary() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var buildings := match_instance.get_node("Buildings") as Node3D
	var barracks_scene := load("res://assets/converted/buildings/ATBarracks/ATBarracks.scn") as PackedScene
	var first_barracks := barracks_scene.instantiate() as Building
	var primary_barracks := barracks_scene.instantiate() as Building
	buildings.add_child(first_barracks)
	buildings.add_child(primary_barracks)
	first_barracks.global_position = Vector3(80.0, 8.0, 40.0)
	primary_barracks.global_position = Vector3(120.0, 8.0, 40.0)
	primary_barracks.global_rotation.y = PI / 2.0
	first_barracks.setup(&"ATBarracks")
	primary_barracks.setup(&"ATBarracks")
	first_barracks.set_owner_player_id(1)
	primary_barracks.set_owner_player_id(1)
	await process_frame
	_expect(
		primary_barracks.building_definition.ai_manufacturing,
		"a building with AiManufacturing must support an explicit rally point"
	)

	_expect(
		first_barracks.rally_point_position().z > first_barracks.global_position.z,
		"a building's default rally point must be directly in front of it"
	)
	var default_rally_line := first_barracks.get_node("RallyPointLine") as MeshInstance3D
	var default_rally_marker := first_barracks.get_node("RallyPointMarker") as Node3D
	first_barracks.set_selected(true)
	_expect(
		default_rally_line.mesh == null and not default_rally_line.visible \
		and not default_rally_marker.visible,
		"a selected building must not draw its automatic default rally point or marker"
	)
	first_barracks.set_selected(false)
	var rally_point := Vector3(120.0, 8.0, 28.0)
	primary_barracks.set_rally_point(rally_point)
	var rally_line := primary_barracks.get_node("RallyPointLine") as MeshInstance3D
	var rally_marker := primary_barracks.get_node("RallyPointMarker") as Node3D
	_expect(
		rally_line.mesh != null and not rally_line.visible and not rally_marker.visible,
		"an explicit rally point visual must stay hidden while its building is unselected"
	)
	primary_barracks.set_selected(true)
	_expect(
		rally_line.visible and rally_marker.visible,
		"selecting a building must reveal its rally point line and place-flag model"
	)
	_expect(
		rally_marker.global_position.is_equal_approx(rally_point),
		"the place-flag model must stand at the explicit rally point"
	)
	primary_barracks.set_selected(false)
	_expect(
		not rally_line.visible and not rally_marker.visible,
		"deselecting a building must hide its rally point line and marker"
	)
	var players = get_root().get_node("Players")
	players.designate_primary_building(primary_barracks, 1, "ATBarracks")

	var roster = match_instance.get_node("UnitRosterController") as UnitRosterController
	var units := match_instance.get_node("Units") as Node3D
	var units_before := units.get_children().duplicate()
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT, 10)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 12,
		"left click must add units, while shift+left click adds ten more"
	)
	var infantry_queue: BuildingQueue = roster._production_queues.get(&"ATBarracks")
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT)
	_expect(
		infantry_queue != null and infantry_queue.current_order().manually_paused,
		"right click must pause the active unit production order"
	)
	# process(delta) no longer drives simulation; advance_tick() does, one
	# MatchClock.SECONDS_PER_TICK period per call. 2 simulated seconds is
	# roundi(2.0 / SECONDS_PER_TICK) ticks at the fixed 25 Hz rate.
	for _i in roundi(2.0 / MatchClockScript.SECONDS_PER_TICK):
		roster.advance_tick()
	_expect(
		units.get_children().size() == units_before.size(),
		"a paused unit order must not complete"
	)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 11 and infantry_queue.current_order().manually_paused,
		"a second right click must remove one queued unit without resuming production"
	)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT, 10)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 1 and infantry_queue.current_order().manually_paused,
		"shift+right click must remove ten queued units without resuming production"
	)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 1 and not infantry_queue.current_order().manually_paused,
		"left click on a paused unit order must resume it without adding another unit"
	)
	# Same 2-second-to-ticks conversion as above.
	for _i in roundi(2.0 / MatchClockScript.SECONDS_PER_TICK):
		roster.advance_tick()

	var produced: Unit
	for candidate in units.get_children():
		if not units_before.has(candidate) and candidate is Unit:
			produced = candidate as Unit
			break
	_expect(produced != null, "a completed unit order must spawn a unit")
	_expect(
		produced != null and produced.global_position.is_equal_approx(primary_barracks.production_spawn_position()),
		"a completed unit must emerge at the front edge of the designated primary production building"
	)
	var produced_forward := -produced.global_transform.basis.z if produced != null else Vector3.ZERO
	produced_forward.y = 0.0
	produced_forward = produced_forward.normalized()
	var building_forward := primary_barracks.global_transform.basis.z
	building_forward.y = 0.0
	building_forward = building_forward.normalized()
	_expect(
		produced != null and produced_forward.dot(building_forward) > 0.999,
		"a completed unit's front must face out through its production building's front"
	)
	_expect(
		produced != null and produced.target_position.is_equal_approx(rally_point),
		"a produced unit must immediately receive the primary building's rally point"
	)

	# The navigation system registers the fresh unit deferred; the rally order
	# from the spawn frame must survive that handoff instead of being reset to
	# the unit's own position.
	#
	# The tolerance is derived, not chosen. This rally point sits about half a
	# cell inside its own cell, and that cell is rejected as a stopping place:
	# the unit's body disc overlaps the solid cliff row beneath it by roughly
	# five centimetres (see GroundSlotAllocator.body_fits(), and
	# approach_anchor() for how the replacement cell is picked). A rejected
	# cell can only be escaped by a whole cell, so one cell pitch is the floor
	# -- 1.125 m, with NAV_SIZE 256 over this map's 288 world units. Up to
	# another pitch goes on top, because claim_anchor() resolves same-ring ties
	# toward the ordering unit rather than toward the point, deliberately: that
	# tie-break is also what decides which side of a building a unit approaches
	# from, so the cell it returns can be a further member of the right ring.
	# Two pitches is the honest bound. Nothing under 1.5 m is reachable here by
	# any cell-selection rule, so the old threshold only ever pinned this map's
	# geometry, not the behaviour named below.
	const RALLY_CELL_PITCH := 288.0 / 256.0
	const RALLY_TOLERANCE := RALLY_CELL_PITCH * 2.0
	await process_frame
	var navigation = match_instance.get_node("UnitNavigationSystem")
	var agent: Dictionary = navigation.agent_debug(produced)
	var destination: Vector3 = agent.get("destination", Vector3.INF)
	destination.y = rally_point.y
	var rally_distance := destination.distance_to(rally_point)
	_expect(
		not agent.is_empty() and rally_distance < RALLY_TOLERANCE,
		"the rally order must survive the deferred navigation registration (%.2f m from the rally point, tolerance %.2f)" \
			% [rally_distance, RALLY_TOLERANCE]
	)
	# What the case above actually distinguishes, stated as its own assertion
	# so a loosened tolerance cannot quietly stop distinguishing it: a lost
	# rally order leaves the destination at the unit's own spawn position,
	# which is metres away at the barracks, not one cell away.
	_expect(
		not agent.is_empty()
		and rally_distance < produced.global_position.distance_to(rally_point) * 0.25,
		"a surviving rally order must aim far nearer the rally point than the unit's own spawn position"
	)
	_expect(
		not agent.is_empty() and bool(agent["route_ready"]),
		"a produced unit must have its route toward the rally point ready"
	)

	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_LEFT)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT)
	roster.handle_unit_intent(&"ATInfantry", MOUSE_BUTTON_RIGHT, 10)
	_expect(
		roster._unit_queue_size(&"ATBarracks") == 0,
		"shift+right click must not reduce the unit queue below zero"
	)

	match_instance.queue_free()


func _test_shared_unit_native_producer() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame

	var buildings := match_instance.get_node("Buildings") as Node3D
	var harkonnen_factory_scene := load(
		"res://assets/converted/buildings/HKFactory/HKFactory.scn"
	) as PackedScene
	var atreides_factory_scene := load(
		"res://assets/converted/buildings/ATFactory/ATFactory.scn"
	) as PackedScene
	var harkonnen_factory := harkonnen_factory_scene.instantiate() as Building
	var atreides_factory := atreides_factory_scene.instantiate() as Building
	buildings.add_child(harkonnen_factory)
	buildings.add_child(atreides_factory)
	harkonnen_factory.setup(&"HKFactory")
	atreides_factory.setup(&"ATFactory")
	harkonnen_factory.set_owner_player_id(1)
	atreides_factory.set_owner_player_id(1)
	await process_frame

	var roster = match_instance.get_node("UnitRosterController") as UnitRosterController
	var harvester_definition: Resource = roster._unit_scene_catalog.definition_for(&"Harvester")
	_expect(
		roster._production_building_id(harvester_definition) == &"ATFactory",
		"an Atreides player must prefer ATFactory over an owned captured HKFactory"
	)

	match_instance.queue_free()


func _test_real_forced_friendly_attack() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await physics_frame
	await physics_frame

	var attacker := match_instance.get_node("Units/ScoutA") as Unit
	var target := match_instance.get_node("Units/OrdosAPC") as Unit
	attacker.setup(&"ATMongoose")
	attacker.replace_visual_scene(ATMongooseModelScene)
	target.set_owner_player_id(attacker.owner_player_id)
	attacker.stop_at_current_position()
	target.stop_at_current_position()

	var emission: Dictionary = attacker.turret_emission_points()[0]
	var forward: Vector3 = emission["direction"]
	forward.y = 0.0
	var side := forward.normalized().rotated(Vector3.UP, PI * 0.5)
	target.global_position = attacker.global_position + side * 8.0
	target.call("_snap_to_terrain")

	var fired_projectiles: Array = []
	var fired_animation_names: Array[StringName] = []
	var mongoose_target_durability := target.health + target.shields
	attacker.weapon_fired.connect(func(projectiles: Array, fired_target: Variant, weapon_index: int) -> void:
		if fired_target == target:
			fired_projectiles.append_array(projectiles)
			var fire_state: Dictionary = attacker.combat()._weapon_fire_sequences.get(
				weapon_index, {}
			)
			var player := fire_state.get("player") as AnimationPlayer
			fired_animation_names.append(player.current_animation if player != null else &"")
	)
	_expect(
		attacker.command_attack(target),
		"the navigation-managed Mongoose must accept a real allied unit target"
	)
	for _frame in 240:
		await process_frame
		if not fired_projectiles.is_empty():
			break
	_expect(
		absf(attacker.combat_turrets[0].current_yaw_degrees()) > 1.0,
		"the automatically processed Mongoose must turn its turret toward an in-range ally"
	)
	_expect(
		not fired_projectiles.is_empty(),
		"the automatically processed Mongoose must fire after aiming at an in-range ally"
	)
	_expect(
		fired_animation_names == [&"Fire_0"],
		"the real Mongoose missile must launch during its authored Fire_0 clip"
	)
	_expect(
		attacker.combat_turrets[0].reload_ticks_remaining > 0.0
		and attacker.combat_turrets[0].reload_ticks_remaining < 30.0,
		"the real Mongoose must advance ReloadCount during Fire_0"
	)
	_expect(
		not fired_projectiles.is_empty() \
			and is_instance_valid(fired_projectiles[0]) \
			and _projectile_has_visible_mesh(fired_projectiles[0]),
		"the Mongoose missile must be visible while it travels"
	)
	for _frame in 120:
		await process_frame
		if target.health + target.shields < mongoose_target_durability:
			break
	_expect(
		target.health + target.shields < mongoose_target_durability,
		"the Mongoose missile must damage its explicitly selected allied target"
	)

	for projectile in fired_projectiles:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	fired_projectiles.clear()
	fired_animation_names.clear()
	attacker.cancel_attack_order()
	attacker.setup(&"ATMinotaurus")
	attacker.replace_visual_scene(ATMinotaurusModelScene)
	# Keep the real target alive until all four authored barrel events occur;
	# otherwise a normal ORAPC can die from the leading shells of the same salvo.
	target.max_health = 10000.0
	target.health = target.max_health
	target.max_shields = 0.0
	target.shields = 0.0
	emission = attacker.turret_emission_points()[0]
	forward = emission["direction"]
	forward.y = 0.0
	var minotaurus_initial_hull_yaw := attacker.global_rotation.y
	var minotaurus_initial_position := attacker.global_position
	target.global_position = attacker.global_position + Vector3.RIGHT * 35.0
	target.call("_snap_to_terrain")
	var minotaurus_target_health := target.health
	_expect(
		attacker.combat_turrets[0].target_range(target)
			== CombatTurretScript.TargetRange.TOO_FAR,
		"the real Minotaurus pursuit regression must begin beyond maximum range"
	)
	_expect(
		attacker.command_attack(target),
		"the navigation-managed Minotaurus must accept a real allied unit target"
	)
	for _frame in 600:
		await process_frame
		if not fired_projectiles.is_empty():
			break
	_expect(
		absf(angle_difference(minotaurus_initial_hull_yaw, attacker.global_rotation.y))
			> deg_to_rad(30.0),
		"the automatically processed Minotaurus must turn its hull toward a distant side target"
	)
	_expect(
		attacker.global_position.distance_to(minotaurus_initial_position) > 0.5,
		"the automatically processed Minotaurus must close distance before firing"
	)
	_expect(
		absf(attacker.combat_turrets[0].current_yaw_degrees()) <= 45.01,
		"the Minotaurus turret must remain inside its authored sector while the hull turns"
	)
	_expect(
		not fired_projectiles.is_empty(),
		"the automatically processed Minotaurus must fire after aiming at an in-range ally"
	)
	_expect(
		not fired_projectiles.is_empty() \
			and is_instance_valid(fired_projectiles[0]) \
			and _projectile_has_visible_mesh(fired_projectiles[0]),
		"the Minotaurus shell must be visible while it travels"
	)
	for _frame in 120:
		await process_frame
		if fired_projectiles.size() >= 4:
			break
	_expect(
		fired_projectiles.size() == 4,
		"the real Minotaurus must emit four sequential shells in one salvo"
	)
	_expect(
		fired_animation_names == [&"Fire_0", &"Fire_0", &"Fire_0", &"Fire_0"],
		"the real Minotaurus salvo must use one Fire_0 animation for all four shells"
	)
	_expect(
		attacker.combat_turrets[0].reload_ticks_remaining > 0.0
		and attacker.combat_turrets[0].reload_ticks_remaining < 120.0,
		"the real Minotaurus must advance ReloadCount during its salvo"
	)
	for _frame in 60:
		await process_frame
		if not attacker._fire_sequence_active:
			break
	_expect(
		not attacker._fire_sequence_active
		and attacker.combat_turrets[0].reload_ticks_remaining > 0.0
		and attacker.combat_turrets[0].reload_ticks_remaining < 120.0,
		"the real Minotaurus must retain only the unelapsed ReloadCount after Fire_0"
	)
	for _frame in 240:
		await process_frame
		if target.health < minotaurus_target_health:
			break
	_expect(
		target.health < minotaurus_target_health,
		"the Minotaurus shell must damage its explicitly selected allied target"
	)
	for projectile in fired_projectiles:
		if is_instance_valid(projectile) and not projectile.is_queued_for_deletion():
			projectile.free()
	match_instance.queue_free()
	await process_frame


func _test_real_harvester_unload_trip() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	for child in match_instance.get_node("Buildings").get_children():
		child.free()
	for child in match_instance.get_node("Units").get_children():
		child.free()

	var refinery := ATRefineryScene.instantiate() as Building
	refinery.position = Vector3(24.0, 8.0, 12.0)
	refinery.owner_player_id = 1
	match_instance.get_node("Buildings").add_child(refinery)
	var harvester := HarvesterScene.instantiate() as Unit
	harvester.owner_player_id = 1
	match_instance.get_node("Units").add_child(harvester)
	get_root().add_child(match_instance)
	await physics_frame
	await physics_frame

	var navigation = match_instance.get_node("UnitNavigationSystem")
	navigation.set_physics_process(false)
	harvester.set_process(false)
	harvester.set_physics_process(false)
	navigation.call("_refresh_building_blockers")
	var front := refinery.refinery_front_position()
	harvester.global_position = front + refinery.exit_direction() * 6.0
	harvester.spice = 100.0
	harvester.stop_at_current_position()
	var player = get_root().get_node("Players").player(1)
	var money_before := int(player.money)
	_expect(
		harvester.command_unload(
			refinery, match_instance.terrain.navigation_grid, match_instance.terrain.spice_layer
		),
		"the real harvester must accept its real owned refinery"
	)
	_expect(
		harvester.target_position.distance_to(front) > navigation.arrival_tolerance(harvester),
		"navigation must be allowed to assign a collision-safe approach point outside the exact building front"
	)

	var visited_phases := {}
	for _tick in 800:
		visited_phases[harvester._harvester.unload_phase()] = true
		navigation.call("_navigation_tick", 0.05)
		harvester._harvester.advance_unload_order(0.05)
		if not harvester._harvester.has_unload_order():
			break

	for required_phase in [
		HarvesterControllerScript.UnloadPhase.PARK,
		HarvesterControllerScript.UnloadPhase.START,
		HarvesterControllerScript.UnloadPhase.HOLD,
		HarvesterControllerScript.UnloadPhase.END,
	]:
		_expect(visited_phases.has(required_phase), "the real unload trip must visit phase %d" % required_phase)
	_expect(not visited_phases.has(HarvesterControllerScript.UnloadPhase.RETURN_FRONT), "an automatic cycle must not insert a refinery-front waypoint before the field")
	_expect(not harvester._harvester.has_unload_order() and harvester._harvester.has_harvest_order(), "the real unload trip must hand off directly to harvesting")
	_expect(match_instance.terrain.spice_layer.spice_at(harvester._harvester.harvest_target_cell()) > 0, "the direct post-unload target must be a non-empty spice cell")
	_expect(is_zero_approx(harvester.spice), "the real unload trip must empty the harvester")
	_expect(player.money == money_before + 100, "the real unload trip must credit all cargo to the player")

	match_instance.queue_free()


## The model converter negates Z (left-handed source -> Godot), which puts
## every building's low skirt/apron on its +Z side, while the footprint code
## lays occupy row 0 toward -Z. import_rules.gd therefore Z-mirrors the
## occupy matrix during native-resource generation (rows stored back-to-front
## relative to Rules.txt).
## This pins the mirror against the real converted data: a reimport that
## drops it would silently turn every footprint 180 degrees away from its
## model again.
func _test_occupy_rows_are_mirrored() -> void:
	var catalog := BuildingDefinitionCatalogScript.new()
	var con_yard: Resource = catalog.definition(&"ATConYard")
	_expect(con_yard != null, "ATConYard native definition must exist")
	if con_yard == null:
		return

	var occupy_rows: Array = con_yard.occupy_rows
	_expect(occupy_rows.size() == 10, "ATConYard must keep its 10-row occupy matrix")
	if occupy_rows.size() != 10:
		return
	_expect(
		String(occupy_rows[0]) != "sssss" and String(occupy_rows[9]) == "sssss",
		"ATConYard's skirt rows must be mirrored to the matrix end (+Z, the converted model's apron side)"
	)

	var hk_palace: Resource = catalog.definition(&"HKPalace")
	_expect(hk_palace != null, "HKPalace native definition must exist")
	if hk_palace == null:
		return
	var hk_rows: Array = hk_palace.occupy_rows
	_expect(
		hk_rows.size() == 7 and String(hk_rows[0]) == "nnnnbbbbn" and String(hk_rows[6]) == "nnnnnbbnn",
		"HKPalace's footprint must mirror both source axes with its converted model"
	)
