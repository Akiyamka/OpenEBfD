extends "res://tests/support/suite.gd"

const ReleasedOracle := preload("res://tests/combat/support/released_cargo_oracle.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const ATBarracksScene := preload("res://scenes/buildings/at_barracks.tscn")
const ATWallScene := preload("res://assets/converted/buildings/ATWall/ATWall.scn")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const ResolverScript := preload("res://scripts/combat/combat_impact_resolver.gd")
const SplashScript := preload("res://scripts/combat/splash_unit_collision.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const RegistryScript := preload("res://scripts/sim/entity_registry.gd")
const OracleScript := preload("res://tests/combat/support/splash_physics_oracle.gd")
const BulletsScript := preload("res://tests/combat/support/combat_bullets.gd")
const DoublesScript := preload("res://tests/combat/support/combat_doubles.gd")

class PartialMatch extends Node3D:
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func current_tick() -> int:
		return 0

class PartialSpatialMatch extends Node3D:
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func current_tick() -> int:
		return 0
	func entity_index() -> RefCounted:
		return RefCounted.new()
	func entity_state() -> RefCounted:
		return RefCounted.new()

class KillOnDamageTarget extends DoublesScript.PhysicsCombatTarget:
	var victim: Node
	func take_damage(amount: float, death_cause: StringName = &"") -> void:
		victim.health = 0.0
		super.take_damage(amount, death_cause)

class AirCubeUnit extends UnitScript:
	func combat_is_airborne() -> bool:
		return true

class ErrorLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		errors.append(str(code) + str(rationale))

class OneCargoPage extends RefCounted:
	var cargo: CollisionObject3D
	var calls := 0
	func _init(value: CollisionObject3D) -> void:
		cargo = value
	func shape_hits(_query: PhysicsShapeQueryParameters3D, _limit: int) -> Array[Dictionary]:
		calls += 1
		var result: Array[Dictionary] = []
		if calls == 1:
			result.append({"rid": cargo.get_rid(), "collider": cargo})
		return result

class InvalidPage extends RefCounted:
	var collider: Object
	func _init(value: Object) -> void:
		collider = value
	func shape_hits(_query: PhysicsShapeQueryParameters3D, _limit: int) -> Array[Dictionary]:
		return [{"rid": RID(), "collider": collider}]

class ExhaustedPage extends RefCounted:
	var collider: Object
	var rids: Array[RID] = []
	var next_rid := 0
	func _init(value: Object) -> void:
		collider = value
		for _i in 4097:
			rids.append(PhysicsServer3D.body_create())
	func dispose() -> void:
		for rid in rids:
			PhysicsServer3D.free_rid(rid)
		rids.clear()
	func shape_hits(_query: PhysicsShapeQueryParameters3D, limit: int) -> Array[Dictionary]:
		var page: Array[Dictionary] = []
		for _i in mini(limit, rids.size() - next_rid):
			page.append({"rid": rids[next_rid], "collider": collider})
			next_rid += 1
		return page

class PagedPage extends RefCounted:
	var unit: Object
	var building: Object
	var rids: Array[RID] = []
	var calls := 0
	func _init(value_unit: Object, value_building: Object) -> void:
		unit = value_unit
		building = value_building
		for _i in 257:
			rids.append(PhysicsServer3D.body_create())
	func dispose() -> void:
		for rid in rids:
			PhysicsServer3D.free_rid(rid)
		rids.clear()
	func shape_hits(_query: PhysicsShapeQueryParameters3D, _limit: int) -> Array[Dictionary]:
		calls += 1
		var page: Array[Dictionary] = []
		if calls == 1:
			for i in 256:
				page.append({"rid": rids[i], "collider": unit})
		elif calls == 2:
			page.append({"rid": rids[256], "collider": building})
		return page

class DuplicateRidPage extends RefCounted:
	var building: Object
	var rids: Array[RID] = []
	var calls := 0
	func _init(value: Object) -> void:
		building = value
		for _i in 2:
			rids.append(PhysicsServer3D.body_create())
	func dispose() -> void:
		for rid in rids:
			PhysicsServer3D.free_rid(rid)
		rids.clear()
	func shape_hits(_query: PhysicsShapeQueryParameters3D, _limit: int) -> Array[Dictionary]:
		calls += 1
		var page: Array[Dictionary] = []
		if calls == 1:
			page.append({"rid": rids[0], "collider": building})
			page.append({"rid": rids[1], "collider": building})
		return page

class OrderedPage extends RefCounted:
	var colliders: Array[Node]
	var rids: Array[RID] = []
	var calls := 0
	func _init(values: Array[Node]) -> void:
		colliders = values
		for _i in colliders.size():
			rids.append(PhysicsServer3D.body_create())
	func dispose() -> void:
		for rid in rids:
			PhysicsServer3D.free_rid(rid)
		rids.clear()
	func shape_hits(_query: PhysicsShapeQueryParameters3D, limit: int) -> Array[Dictionary]:
		var page: Array[Dictionary] = []
		var start := calls * limit
		calls += 1
		for i in range(start, mini(start + limit, colliders.size())):
			page.append({"rid": rids[i], "collider": colliders[i]})
		return page

class DistanceSpyResolver extends ResolverScript:
	var calls := 0
	func _surface_distance(_target: Object, _world_position: Vector3) -> float:
		calls += 1
		return INF

var _bullets := BulletsScript.new()


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case("released cargo uses own basis", _test_released_cargo_basis)
	await _run_async_case("settled old oracle and stored splash", _test_stored_splash)
	await _run_async_case("authored Building stays on static physics", _test_real_building)
	await _run_async_case("foreign Match Unit is excluded", _test_foreign_match)
	await _run_async_case("dead registered Unit is rechecked", _test_dead_registered)
	await _run_async_case("4096 physical RIDs fail closed", _test_exhausted_page)
	await _run_async_case("partial Match fails closed", _test_partial_match)
	await _run_async_case("partial Match missing only spatial service fails closed", _test_partial_spatial_match)
	await _run_async_case("resolver distance override gates hull work", _test_distance_override)
	await _run_async_case("cube corner needs exact sphere", _test_cube_corner)
	await _run_async_case("grid-line APC needs full radius padding", _test_grid_edge)
	await _run_async_case("domain filter skips helper hull work", _test_domain_filter)
	await _run_async_case("released Unit is excluded from Match splash", _test_unadmitted)
	await _run_async_case("splash results follow stable entity IDs", _test_stable_order)
	await _run_async_case("Match splash damage rules and deduplication", _test_damage_rules)
	await _run_async_case("splash cap counts only damage-eligible entities", _test_cap)
	await _run_async_case("carried flag disagreement fails closed", _test_carried_union)
	await _run_async_case("canonical cargo uses stored splash hull", _test_canonical_carried)
	_finish("Splash unit collision")


func _test_released_cargo_basis() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var carrier = ATAPCScene.instantiate()
	var cargo = ATAPCScene.instantiate()
	carrier.owner_player_id = 1
	cargo.owner_player_id = 2
	match_instance.get_node("Units").add_child(carrier)
	match_instance.get_node("Units").add_child(cargo)
	carrier.set_process(false)
	cargo.set_process(false)
	carrier.set("_simulation_halted", true)
	cargo.set("_simulation_halted", true)
	carrier.set_simulation_position(Vector3(500.0, 40.0, 500.0))
	cargo.set_simulation_position(Vector3(510.0, 40.0, 500.0))
	match_instance.advance_ticks(1)
	carrier.transport_attach_cargo(cargo, Vector3.ZERO)
	_expect(cargo.is_carried(), "release fixture begins with attached cargo")
	cargo.transport_mark_released(Vector3(510.0, 40.0, 500.0), Vector3.FORWARD)
	var dropped: Dictionary = ReleasedOracle.measure(cargo, carrier)
	_expect(dropped["separated"] and dropped["public_agrees"] and dropped["basis_own"]
		and dropped["aim_own"] and not dropped["basis_stale"],
		"dropped cargo aim and hull follow own basis after former carrier rotates")
	carrier.transport_attach_cargo(cargo, Vector3.ZERO)
	_expect(cargo.is_carried(), "destroyed-release fixture reattaches cargo")
	cargo.transport_mark_destroyed_release()
	var destroyed: Dictionary = ReleasedOracle.measure(cargo, carrier)
	_expect(destroyed["separated"] and destroyed["public_agrees"] and destroyed["basis_own"]
		and destroyed["aim_own"] and not destroyed["basis_stale"],
		"destroyed-carrier release returns aim and hull to cargo basis")
	carrier.transport_attach_cargo(cargo, Vector3.ZERO)
	_expect(cargo.is_carried(), "own-death fixture reattaches live cargo")
	cargo.force_transport_death()
	var dead: Dictionary = ReleasedOracle.measure(cargo, carrier)
	_expect(cargo.health <= 0.0 and not cargo.is_carried() and not cargo.is_in_group(&"sim_carried_units")
		and dead["separated"] and dead["public_agrees"] and dead["basis_own"]
		and dead["aim_own"] and not dead["basis_stale"],
		"cargo own death restores own basis for aim and hull")
	match_instance.free()


func _test_stored_splash() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	var building = DoublesScript.PhysicsCombatTarget.new(Vector3(501.0, 0.8, 500.0))
	match_instance.add_child(building)
	unit.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var centre := Vector3(500.0, 0.8, 500.0)
	var far := Vector3(530.0, 0.8, 500.0)
	var server_position: Vector3 = PhysicsServer3D.body_get_state(unit.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM).origin
	_expect(server_position.distance_to(unit.global_position) < 0.01, "settled server transform agrees with Unit")
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit), "old oracle positively hits settled Unit")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), far, 4.0, unit), "old oracle misses distant Unit")
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, building), "old oracle positively hits settled Building")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), far, 4.0, building), "old oracle misses distant Building")
	var bullet = _bullets.runtime_bullet(&"Mortar_B")
	var resolver = ResolverScript.new()
	unit.max_health = 1000000.0
	unit.health = 1000000.0
	var probes_before: int = unit.projectile_hull_diagnostics()["probes"]
	var copies_before: int = unit.projectile_hull_diagnostics()["copies"]
	var hits: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(hits.size() == 2 and hits.any(func(item: Dictionary) -> bool: return item["target"] == unit), "stored hull gives one Match Unit hit")
	_expect(building.damage_taken > 0.0, "static Building is hit through physics")
	_expect(unit.health < 1000000.0, "public resolve damages Unit")
	_expect(unit.projectile_hull_diagnostics()["probes"] - probes_before == 1, "one exact hull probe")
	_expect(unit.projectile_hull_diagnostics()["copies"] == copies_before,
		"splash resolve does not deep-copy authored hulls")
	var source_hits: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre, null, unit)
	_expect(not source_hits.any(func(item: Dictionary) -> bool: return item["target"] == unit),
		"incidental source is excluded")
	var selected_source: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre, unit, unit)
	_expect(not selected_source.is_empty() and selected_source[0]["target"] == unit \
		and selected_source[0]["direct"], "explicit selected source remains direct result one")
	var old_centre := centre
	unit.set_simulation_position(Vector3(530.0, 0.0, 500.0))
	_expect(OracleScript.hits(match_instance.get_world_3d(), old_centre, 4.0, unit), "old oracle remains stale before physics step")
	var leaving: Dictionary = SplashScript.collect(match_instance, match_instance,
		match_instance.entity_index(), match_instance.entity_state(), match_instance.unit_spatial_index(),
		old_centre, 4.0, bullet, null, null, Callable(resolver, "_surface_distance"),
		CombatRulesScript.COLLISION_MASK)
	_expect(leaving["ok"] and not leaving["entries"].any(func(item: Dictionary) -> bool:
		return item["target"] == unit), "helper IDs leave blast with stored position")
	var moved: Array[Dictionary] = resolver.resolve(bullet, match_instance, old_centre)
	_expect(not moved.any(func(item: Dictionary) -> bool: return item["target"] == unit), "stored position leaves blast before physics step")
	var pager := PagedPage.new(unit, building)
	resolver._collision_query_adapter = pager
	var building_damage_before: float = building.damage_taken
	var paged: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(pager.calls == 3, "physics pages continue beyond first 256 RIDs")
	_expect(paged.size() == 1 and paged[0]["target"] == building \
		and building.damage_taken > building_damage_before, "later Building receives splash")
	pager.dispose()
	var direct_health: float = unit.health
	resolver._collision_query_adapter = InvalidPage.new(building)
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	var invalid: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre, unit)
	OS.remove_logger(logger)
	_expect(invalid.is_empty() and unit.health == direct_health, "invalid physics page aborts before direct damage")
	_expect(logger.errors.size() == 1, "invalid physics page logs once")
	resolver._collision_query_adapter = null
	unit.set_simulation_position(Vector3(530.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	_expect(not OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"old oracle misses settled distant Unit before store-only entry")
	match_instance.entity_state().set_position(unit.entity_id, Vector3(500.0, 0.0, 500.0))
	var collected: Dictionary = SplashScript.collect(match_instance, match_instance,
		match_instance.entity_index(), match_instance.entity_state(), match_instance.unit_spatial_index(),
		centre, 4.0, bullet, null, null, Callable(resolver, "_surface_distance"),
		CombatRulesScript.COLLISION_MASK)
	_expect(collected["ok"] and collected["entries"].any(func(item: Dictionary) -> bool:
		return item["target"] == unit), "store-only entry appears in helper IDs")
	var entered: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(entered.any(func(item: Dictionary) -> bool: return item["target"] == unit),
		"store-only entry damages through stored hull while Node stays distant")
	var flight_config: Resource = _bullets.bullet_config(&"StraightBomb").duplicate(true)
	flight_config.blast_radius = 64.0
	flight_config.speed = 100.0
	var flight_bullet = CombatBulletScript.new(flight_config,
		_bullets.warhead_config(flight_config.warhead_id))
	unit.health = 1000000.0
	var shot = CombatProjectileScript.new()
	match_instance.add_child(shot)
	var delivered_hits: Array[Dictionary] = []
	shot.impact_resolved.connect(func(results: Array[Dictionary], _at: Vector3) -> void:
		delivered_hits.append_array(results))
	var splash_aim := centre + Vector3(3.0, 0.0, 0.0)
	var shot_from := splash_aim + Vector3(0.0, 0.0, -1.0)
	_expect(unit.projectile_hull_contact(shot_from, splash_aim,
		match_instance.entity_state().position(unit.entity_id), 0.0).is_empty(),
		"arrival flight path clears the Unit direct hull")
	_expect(shot.launch(flight_bullet, BulletsScript.emission(shot_from, Vector3.BACK), splash_aim),
		"real flying splash projectile launches before arrival tick")
	_expect(unit.health == 1000000.0, "flying splash leaves stored Unit unharmed before tick")
	match_instance.set("_unit_navigation_system", null)
	match_instance.advance_ticks(1)
	_expect(shot.finish_reason == &"impact_ground" and delivered_hits.any(
		func(item: Dictionary) -> bool: return item["target"] == unit and not item["direct"])
		and unit.health < 1000000.0,
		"real Match tick delivers flying splash to stored Unit before physics step")
	match_instance.free()


func _test_real_building() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var building = ATBarracksScene.instantiate()
	building.owner_player_id = 2
	building.position = Vector3(500, 0, 500)
	match_instance.get_node("Buildings").add_child(building)
	building.set_process(false)
	match_instance.advance_ticks(1)
	await physics_frame
	await physics_frame
	var centre: Vector3 = building.combat_aim_position()
	var outside := centre + Vector3(30, 0, 0)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, building),
		"old physics positively hits authored Barracks")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), outside, 4.0, building),
		"old physics misses distant authored Barracks")
	building.max_health = 1000000.0
	building.health = 1000000.0
	building.shields = 0.0
	var hits: Array[Dictionary] = ResolverScript.new().resolve(
		_bullets.runtime_bullet(&"Mortar_B"), match_instance, centre)
	_expect(hits.size() == 1 and hits[0]["target"] == building and building.health < 1000000.0,
		"authored Barracks is damaged through static physics")
	building.free()
	await physics_frame
	await physics_frame
	var wall = ATWallScene.instantiate()
	wall.owner_player_id = 2
	match_instance.get_node("Buildings").add_child(wall)
	wall.global_position += centre - wall.combat_aim_position()
	wall.set_process(false)
	await physics_frame
	await physics_frame
	_expect(wall.is_in_group(&"wall_buildings")
		and OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, wall),
		"old physics positively hits authored wall")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), outside, 4.0, wall),
		"old physics misses distant authored wall")
	wall.max_health = 1000000.0
	wall.health = 1000000.0
	wall.shields = 0.0
	hits = ResolverScript.new().resolve(_bullets.runtime_bullet(&"Mortar_B"), match_instance, centre)
	_expect(hits.size() == 1 and hits[0]["target"] == wall and wall.health < 1000000.0,
		"authored wall is damaged through static physics")
	match_instance.free()


func _test_foreign_match() -> void:
	var match_a = MatchFixtureScene.instantiate()
	root.add_child(match_a)
	match_a.set_process(false)
	var match_b = MatchFixtureScene.instantiate()
	root.add_child(match_b)
	match_b.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_a.is_ancestor_of(mound) or match_b.is_ancestor_of(mound):
			mound.free()
	match_a.terrain.spice_layer = null
	match_b.terrain.spice_layer = null
	for match_instance in [match_a, match_b]:
		for existing in match_instance.get_node("Units").get_children():
			existing.free()
	var foreign = ATAPCScene.instantiate()
	foreign.owner_player_id = 2
	match_a.get_node("Units").add_child(foreign)
	match_a.advance_ticks(1)
	match_b.advance_ticks(1)
	foreign.set("_simulation_halted", true)
	foreign.set_process(false)
	foreign.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var centre := Vector3(500.0, 0.8, 500.0)
	_expect(OracleScript.hits(match_b.get_world_3d(), centre, 4.0, foreign),
		"old physics positively sees foreign Match Unit")
	_expect(not OracleScript.hits(match_b.get_world_3d(), Vector3(530.0, 0.8, 500.0), 4.0, foreign),
		"old physics misses distant foreign Match Unit")
	_expect(match_b.entity_index().id_for(foreign) == 0
		and match_a.entity_index().id_for(foreign) > 0, "foreign Unit belongs only to Match A")
	foreign.max_health = 1000000.0
	foreign.health = 1000000.0
	var hits: Array[Dictionary] = ResolverScript.new().resolve(
		_bullets.runtime_bullet(&"Mortar_B"), match_b, centre)
	_expect(not hits.any(func(item: Dictionary) -> bool: return item["target"] == foreign)
		and foreign.health == 1000000.0, "Match B splash excludes foreign Unit")
	var foreign_building = ATBarracksScene.instantiate()
	foreign_building.owner_player_id = 2
	foreign_building.position = Vector3(500.0, 0.0, 500.0)
	match_a.get_node("Buildings").add_child(foreign_building)
	foreign_building.set_process(false)
	await physics_frame
	await physics_frame
	var building_centre: Vector3 = foreign_building.combat_aim_position()
	_expect(OracleScript.hits(match_b.get_world_3d(), building_centre, 4.0, foreign_building),
		"old physics positively sees foreign Match Building")
	_expect(not OracleScript.hits(match_b.get_world_3d(), building_centre + Vector3(30, 0, 0),
		4.0, foreign_building), "old physics misses distant foreign Match Building")
	_expect(match_a.entity_index().id_for(foreign_building) > 0
		and match_b.entity_index().id_for(foreign_building) == 0,
		"foreign Building belongs only to Match A")
	foreign_building.max_health = 1000000.0
	foreign_building.health = 1000000.0
	foreign_building.shields = 0.0
	hits = ResolverScript.new().resolve(_bullets.runtime_bullet(&"Mortar_B"),
		match_b, building_centre)
	_expect(not hits.any(func(item: Dictionary) -> bool: return item["target"] == foreign_building)
		and foreign_building.health == 1000000.0,
		"Match B splash excludes foreign Building despite settled physics hit")
	match_b.free()
	match_a.free()


func _test_dead_registered() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var centre := Vector3(500.0, 0.8, 500.0)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"old physics positively sees dead-control APC collider")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), centre + Vector3(30, 0, 0),
		4.0, unit), "old physics misses distant dead-control APC")
	var index = match_instance.entity_index()
	var state = match_instance.entity_state()
	var bullet = _bullets.runtime_bullet(&"Mortar_B")
	var resolver = ResolverScript.new()
	unit.max_health = 1000000.0
	unit.health = 0.0
	_expect(index.registry().is_alive(unit.entity_id) and unit.is_in_group(&"sim_units")
		and not CombatTargetScript.is_alive(unit) and bullet.can_hit(unit),
		"dead APC remains registry-live and domain-eligible before release")
	var probes_before: int = unit.projectile_hull_diagnostics()["probes"]
	var collected: Dictionary = SplashScript.collect(match_instance, match_instance,
		index, state, match_instance.unit_spatial_index(), centre, 4.0,
		bullet, null, null, Callable(resolver, "_surface_distance"), CombatRulesScript.COLLISION_MASK)
	_expect(collected["ok"] and not collected["entries"].any(
		func(item: Dictionary) -> bool: return item["target"] == unit),
		"dead registered APC is absent from helper candidates")
	_expect(unit.projectile_hull_diagnostics()["probes"] == probes_before,
		"dead registered APC takes no exact hull probe")
	var dead_hits: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(not dead_hits.any(func(item: Dictionary) -> bool: return item["target"] == unit)
		and index.registry().is_alive(unit.entity_id),
		"dead registered APC receives no splash before release")
	unit.health = 1000000.0
	var killer = KillOnDamageTarget.new(centre)
	killer.victim = unit
	match_instance.add_child(killer)
	await physics_frame
	await physics_frame
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, killer),
		"old physics positively hits direct kill-trigger Building")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), centre + Vector3(30, 0, 0),
		4.0, killer), "old physics misses distant kill-trigger Building")
	probes_before = unit.projectile_hull_diagnostics()["probes"]
	var delivered: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre, killer)
	_expect(unit.projectile_hull_diagnostics()["probes"] - probes_before == 1
		and unit.health == 0.0 and index.registry().is_alive(unit.entity_id),
		"direct target kills already-collected APC before splash delivery")
	_expect(delivered.size() == 1 and delivered[0]["target"] == killer
		and not delivered.any(func(item: Dictionary) -> bool: return item["target"] == unit),
		"delivery rechecks liveness after direct target mutation")
	match_instance.free()


func _test_exhausted_page() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var target = DoublesScript.PhysicsCombatTarget.new(Vector3(500.0, 0.8, 500.0))
	match_instance.add_child(target)
	await physics_frame
	await physics_frame
	var centre := Vector3(500.0, 0.8, 500.0)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, target),
		"old physics positively hits exhaustion-control Building")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), Vector3(530.0, 0.8, 500.0), 4.0, target),
		"old physics misses distant exhaustion-control Building")
	var pager := ExhaustedPage.new(target)
	_expect(pager.rids.size() == 4097 and pager.rids[0].is_valid()
		and pager.rids[4096].is_valid(), "exhaustion adapter owns 4097 valid RIDs")
	var resolver = ResolverScript.new()
	resolver._collision_query_adapter = pager
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	var hits: Array[Dictionary] = resolver.resolve(
		_bullets.runtime_bullet(&"Mortar_B"), match_instance, centre, target)
	OS.remove_logger(logger)
	_expect(hits.is_empty() and target.damage_taken == 0.0,
		"4096-RID exhaustion aborts before direct and splash damage")
	_expect(logger.errors.size() == 1 and logger.errors[0].contains("exhausted physics RID page"),
		"4096-RID exhaustion logs one actionable error")
	pager.dispose()
	match_instance.free()


func _test_partial_match() -> void:
	var partial := PartialMatch.new()
	root.add_child(partial)
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	var resolver = ResolverScript.new()
	var result: Array[Dictionary] = resolver.resolve(_bullets.runtime_bullet(&"Mortar_B"), partial, Vector3.ZERO)
	OS.remove_logger(logger)
	_expect(result.is_empty(), "partial Match has no splash results")
	_expect(logger.errors.size() == 1 and logger.errors[0].contains("needs entity_index"),
		"partial Match emits only the actionable service error")
	var direct = DoublesScript.PhysicsCombatTarget.new(Vector3.ZERO)
	partial.add_child(direct)
	var direct_result: Array[Dictionary] = resolver.resolve(
		_bullets.runtime_bullet(&"HEAT_B"), partial, Vector3.ZERO, direct)
	_expect(direct_result.size() == 1 and direct.damage_taken > 0.0,
		"radius-zero direct path ignores missing splash services")
	partial.free()


func _test_partial_spatial_match() -> void:
	var partial := PartialSpatialMatch.new()
	root.add_child(partial)
	_expect(partial.has_method("entity_index") and partial.has_method("entity_state")
		and not partial.has_method("unit_spatial_index"),
		"partial fixture lacks only the spatial service")
	var direct = DoublesScript.PhysicsCombatTarget.new(Vector3.ZERO)
	partial.add_child(direct)
	var resolver = ResolverScript.new()
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	var result: Array[Dictionary] = resolver.resolve(
		_bullets.runtime_bullet(&"Mortar_B"), partial, Vector3.ZERO, direct)
	OS.remove_logger(logger)
	_expect(result.is_empty() and direct.damage_taken == 0.0,
		"missing spatial service aborts before direct mutation")
	_expect(logger.errors.size() == 1 and logger.errors[0].contains("needs entity_index"),
		"missing spatial service emits one actionable error")
	var direct_result: Array[Dictionary] = resolver.resolve(
		_bullets.runtime_bullet(&"HEAT_B"), partial, Vector3.ZERO, direct)
	_expect(direct_result.size() == 1 and direct.damage_taken > 0.0,
		"radius-zero direct hit ignores absent spatial service")
	partial.free()


func _test_distance_override() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var spy := DistanceSpyResolver.new()
	var probes_before: int = unit.projectile_hull_diagnostics()["probes"]
	var result: Array[Dictionary] = spy.resolve(_bullets.runtime_bullet(&"Mortar_B"),
		match_instance, Vector3(500.0, 0.8, 500.0))
	_expect(spy.calls == 1, "helper calls resolver distance override once")
	_expect(unit.projectile_hull_diagnostics()["probes"] == probes_before, "failed distance gate skips hull probe")
	_expect(result.is_empty(), "failed distance gate returns no Unit hit")
	match_instance.free()


func _test_cube_corner() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var cube = UnitScript.new()
	cube.config_id = &"ATAPC"
	cube.owner_player_id = 2
	cube.add_to_group(&"units")
	var visual := Node3D.new()
	visual.name = "VisualRoot"
	cube.add_child(visual)
	var source := Node3D.new()
	source.name = "CubeSource"
	source.set_meta("original_name", "slctCube")
	var points := PackedVector3Array()
	for x in [-0.1, 0.1]:
		for y in [-0.1, 0.1]:
			for z in [-0.1, 0.1]:
				points.append(Vector3(x, y, z))
	source.set_meta("collision_points", points)
	visual.add_child(source)
	match_instance.get_node("Units").add_child(cube)
	match_instance.advance_ticks(1)
	cube.set("_simulation_halted", true)
	cube.set_process(false)
	cube.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var centre := Vector3(500.5, 0.5, 500.5)
	var radius := 0.6
	var independent_distance := sqrt(3.0) * 0.4
	_expect(independent_distance > radius, "independent cube corner lies outside sphere")
	_expect(match_instance.unit_spatial_index().rectangle_candidates(
		Vector2(centre.x - radius, centre.z - radius),
		Vector2(centre.x + radius, centre.z + radius)).has(cube.entity_id),
		"broadphase contains near-miss cube")
	var contact: Dictionary = cube.projectile_hull_contact(
		centre - Vector3.UP * radius, centre + Vector3.UP * radius,
		Vector3(500.0, 0.0, 500.0), radius)
	_expect(contact.is_empty(), "independent exact hull misses cube corner")
	var resolver = ResolverScript.new()
	var bullet_config: Resource = _bullets.bullet_config(&"Mortar_B").duplicate(true)
	bullet_config.blast_radius = 9.6
	var bullet = CombatBulletScript.new(bullet_config,
		_bullets.warhead_config(bullet_config.warhead_id))
	var results: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(not results.any(func(item: Dictionary) -> bool: return item["target"] == cube),
		"cube corner receives no splash damage")
	var collision: CollisionShape3D = cube.get_node("AuthoredCollision")
	_expect(collision.shape is ConvexPolygonShape3D,
		"authored cube installs a convex physics shape")
	var minimum := Vector3.INF
	var maximum := -Vector3.INF
	for point: Vector3 in source.get_meta("collision_points"):
		var world_point: Vector3 = source.global_transform * point
		minimum = minimum.min(world_point)
		maximum = maximum.max(world_point)
	var middle := (minimum + maximum) * 0.5
	var cases := {
		"face": Vector3(maximum.x + 0.55, middle.y, middle.z),
		"edge": Vector3(maximum.x + 0.37, maximum.y + 0.37, middle.z),
		"vertex": maximum + Vector3(0.25, 0.25, 0.25),
		"inside": middle,
		"outside": maximum + Vector3(0.4, 0.4, 0.4),
	}
	_expect(OracleScript.hits(match_instance.get_world_3d(), middle, radius, cube),
		"old physics positively hits settled authored cube")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), middle + Vector3(30, 0, 0), radius, cube),
		"old physics misses distant authored cube")
	for label: String in cases:
		var point: Vector3 = cases[label]
		var nearest := Vector3(clampf(point.x, minimum.x, maximum.x),
			clampf(point.y, minimum.y, maximum.y), clampf(point.z, minimum.z, maximum.z))
		var expected_hit := point.distance_to(nearest) <= radius
		_expect(expected_hit == (label != "outside"),
			"independent authored cube distance identifies " + label)
		_expect(OracleScript.hits(match_instance.get_world_3d(), point, radius, cube) == expected_hit,
			"settled old physics agrees with authored " + label)
		var gate_pass: bool = resolver._surface_distance(cube, point) <= radius + 0.0001
		var eligible_hit: bool = expected_hit and gate_pass
		var probes_before: int = cube.projectile_hull_diagnostics()["probes"]
		var collected: Dictionary = SplashScript.collect(match_instance, match_instance,
			match_instance.entity_index(), match_instance.entity_state(), match_instance.unit_spatial_index(),
			point, radius, bullet, null, null, Callable(resolver, "_surface_distance"),
			CombatRulesScript.COLLISION_MASK)
		var helper_hit: bool = collected["ok"] and collected["entries"].any(
			func(item: Dictionary) -> bool: return item["target"] == cube)
		_expect(helper_hit == eligible_hit, "helper candidate agrees with authored " + label)
		_expect(cube.projectile_hull_diagnostics()["probes"] - probes_before == int(gate_pass),
			"gate-passing authored " + label + " takes one exact probe")
		cube.max_health = 1000000.0
		cube.health = 1000000.0
		var copies_before: int = cube.projectile_hull_diagnostics()["copies"]
		var delivered: Array[Dictionary] = resolver.resolve(bullet, match_instance, point)
		_expect(delivered.any(func(item: Dictionary) -> bool: return item["target"] == cube) == eligible_hit
			and (cube.health < 1000000.0) == eligible_hit,
			"public splash damage agrees with authored " + label)
		_expect(cube.projectile_hull_diagnostics()["copies"] == copies_before,
			"public authored " + label + " splash never deep-copies hulls")
	match_instance.free()


func _test_grid_edge() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(501.9, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var centre := Vector3(497.9, 0.8, 500.0)
	var bullet = _bullets.runtime_bullet(&"Mortar_B")
	var resolver = ResolverScript.new()
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"old physics positively hits grid-line APC")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), Vector3(530, 0.8, 500), 4.0, unit),
		"old physics misses outside grid-line APC")
	var ids: PackedInt32Array = match_instance.unit_spatial_index().rectangle_candidates(
		Vector2(centre.x - 4.0, centre.z - 4.0), Vector2(centre.x + 4.0, centre.z + 4.0))
	_expect(ids.has(unit.entity_id), "full-radius rectangle admits grid-line APC")
	var collected: Dictionary = SplashScript.collect(match_instance, match_instance,
		match_instance.entity_index(), match_instance.entity_state(), match_instance.unit_spatial_index(),
		centre, 4.0, bullet, null, null, Callable(resolver, "_surface_distance"),
		CombatRulesScript.COLLISION_MASK)
	_expect(collected["ok"] and collected["entries"].any(func(item: Dictionary) -> bool:
		return item["target"] == unit), "helper keeps grid-line APC after full padding")
	unit.max_health = 1000000.0
	unit.health = 1000000.0
	var hits: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(hits.any(func(item: Dictionary) -> bool: return item["target"] == unit)
		and unit.health < 1000000.0, "grid-line APC takes splash damage")
	match_instance.free()


func _test_domain_filter() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(500, 0, 500))
	await physics_frame
	await physics_frame
	var centre := Vector3(500, 0.8, 500)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"old physics positively hits domain-control APC")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), Vector3(530, 0.8, 500), 4.0, unit),
		"old physics misses outside domain-control APC")
	var config: Resource = _bullets.bullet_config(&"Mortar_B").duplicate(true)
	config.anti_ground = false
	config.anti_aircraft = true
	var bullet = CombatBulletScript.new(config, _bullets.warhead_config(config.warhead_id))
	var resolver = ResolverScript.new()
	_expect(match_instance.unit_spatial_index().rectangle_candidates(Vector2(496, 496),
		Vector2(504, 504)).has(unit.entity_id), "raw rectangle contains rejected APC")
	var before: int = unit.projectile_hull_diagnostics()["probes"]
	var collected: Dictionary = SplashScript.collect(match_instance, match_instance,
		match_instance.entity_index(), match_instance.entity_state(), match_instance.unit_spatial_index(),
		centre, 4.0, bullet, null, null, Callable(resolver, "_surface_distance"),
		CombatRulesScript.COLLISION_MASK)
	_expect(collected["ok"] and not collected["entries"].any(func(item: Dictionary) -> bool:
		return item["target"] == unit), "domain-rejected APC absent from helper output")
	_expect(unit.projectile_hull_diagnostics()["probes"] == before,
		"domain-rejected APC takes no exact hull probe")
	unit.max_health = 1000000.0
	unit.health = 1000000.0
	var hits: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(hits.is_empty() and unit.health == 1000000.0, "domain-rejected APC takes no damage")
	var aircraft = AirCubeUnit.new()
	aircraft.config_id = &"ATAPC"
	aircraft.owner_player_id = 2
	aircraft.add_to_group(&"units")
	var visual := Node3D.new()
	visual.name = "VisualRoot"
	aircraft.add_child(visual)
	var source := Node3D.new()
	source.name = "CubeSource"
	source.set_meta("original_name", "slctCube")
	var points := PackedVector3Array()
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				points.append(Vector3(x, y, z))
	source.set_meta("collision_points", points)
	visual.add_child(source)
	match_instance.get_node("Units").add_child(aircraft)
	match_instance.advance_ticks(1)
	aircraft.set("_simulation_halted", true)
	aircraft.set_process(false)
	aircraft.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	_expect(aircraft.combat_is_airborne()
		and OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, aircraft),
		"old physics positively hits airborne domain-control cube")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), Vector3(530.0, 0.8, 500.0),
		4.0, aircraft), "old physics misses distant airborne cube")
	var ground_config: Resource = _bullets.bullet_config(&"Mortar_B").duplicate(true)
	ground_config.anti_aircraft = false
	ground_config.anti_ground = true
	var ground_bullet = CombatBulletScript.new(ground_config,
		_bullets.warhead_config(ground_config.warhead_id))
	_expect(match_instance.unit_spatial_index().rectangle_candidates(Vector2(496, 496),
		Vector2(504, 504)).has(aircraft.entity_id), "raw rectangle contains rejected aircraft")
	var air_probes_before: int = aircraft.projectile_hull_diagnostics()["probes"]
	var ground_collected: Dictionary = SplashScript.collect(match_instance, match_instance,
		match_instance.entity_index(), match_instance.entity_state(), match_instance.unit_spatial_index(),
		centre, 4.0, ground_bullet, null, null, Callable(resolver, "_surface_distance"),
		CombatRulesScript.COLLISION_MASK)
	_expect(ground_collected["ok"] and not ground_collected["entries"].any(
		func(item: Dictionary) -> bool: return item["target"] == aircraft),
		"domain-rejected aircraft absent from helper output")
	_expect(aircraft.projectile_hull_diagnostics()["probes"] == air_probes_before,
		"domain-rejected aircraft takes no exact hull probe")
	aircraft.max_health = 1000000.0
	aircraft.health = 1000000.0
	var ground_hits: Array[Dictionary] = resolver.resolve(ground_bullet, match_instance, centre)
	_expect(not ground_hits.any(func(item: Dictionary) -> bool: return item["target"] == aircraft)
		and aircraft.health == 1000000.0, "domain-rejected aircraft takes no damage")
	match_instance.free()


func _test_unadmitted() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	match_instance.advance_ticks(1)
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.global_position = Vector3(500, 0, 500)
	await physics_frame
	await physics_frame
	var centre := Vector3(500, 0.8, 500)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"old physics positively sees soon-to-be-released APC")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), Vector3(530, 0.8, 500), 4.0, unit),
		"old physics misses outside released-control APC")
	unit.max_health = 1000000.0
	unit.health = 1000000.0
	_expect(not unit.is_in_group(&"sim_units"), "physical APC has not entered simulation yet")
	var preadmission: Array[Dictionary] = ResolverScript.new().resolve(
		_bullets.runtime_bullet(&"Mortar_B"), match_instance, centre)
	_expect(not preadmission.any(func(item: Dictionary) -> bool: return item["target"] == unit)
		and unit.health == 1000000.0, "unadmitted physical APC cannot enter Match splash")
	match_instance.entity_index().request_release(unit.entity_id)
	_expect(not match_instance.entity_index().registry().is_alive(unit.entity_id),
		"released APC has no live registry entry")
	var hits: Array[Dictionary] = ResolverScript.new().resolve(
		_bullets.runtime_bullet(&"Mortar_B"), match_instance, centre)
	_expect(not hits.any(func(item: Dictionary) -> bool: return item["target"] == unit),
		"released APC cannot enter by physical splash")
	match_instance.free()


func _test_stable_order() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var units: Array[Node] = []
	for i in 2:
		var unit = ATAPCScene.instantiate()
		unit.owner_player_id = 2
		match_instance.get_node("Units").add_child(unit)
		units.append(unit)
	var building = DoublesScript.PhysicsCombatTarget.new(Vector3(500, 0.8, 500))
	match_instance.add_child(building)
	match_instance.advance_ticks(1)
	for i in 2:
		units[i].set("_simulation_halted", true)
		units[i].set_process(false)
		units[i].set_simulation_position(Vector3(500.0 + i * 0.5, 0, 500))
	await physics_frame
	await physics_frame
	var centre := Vector3(500, 0.8, 500)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, units[0])
		and OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, units[1])
		and OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, building),
		"old physics positively hits ordered Units and Building")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), Vector3(530, 0.8, 500),
		4.0, units[0]) and not OracleScript.hits(match_instance.get_world_3d(),
		Vector3(530, 0.8, 500), 4.0, building), "old physics misses outside order controls")
	var hits: Array[Dictionary] = ResolverScript.new().resolve(
		_bullets.runtime_bullet(&"Mortar_B"), match_instance, centre)
	_expect(hits.size() == 3 and hits[0]["target"] == units[0]
		and hits[1]["target"] == units[1] and hits[2]["target"] == building,
		"stable ID order places admitted Units before unindexed Building")
	match_instance.free()


func _test_cap() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var colliders: Array[Node] = []
	for _i in 256:
		var decoy = DoublesScript.PhysicsCombatTarget.new(Vector3(530, 0.8, 500))
		match_instance.add_child(decoy)
		colliders.append(decoy)
	var target = DoublesScript.PhysicsCombatTarget.new(Vector3(500, 0.8, 500))
	match_instance.add_child(target)
	colliders.append(target)
	await physics_frame
	await physics_frame
	var centre := Vector3(500, 0.8, 500)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, target),
		"old physics positively hits post-decoy Building")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, colliders[0])
		and not OracleScript.hits(match_instance.get_world_3d(), Vector3(530, 0.8, 500),
		4.0, target), "old physics misses decoy and outside Building")
	var pager := OrderedPage.new(colliders)
	var resolver = ResolverScript.new()
	resolver._collision_query_adapter = pager
	var hits: Array[Dictionary] = resolver.resolve(_bullets.runtime_bullet(&"Mortar_B"),
		match_instance, centre)
	_expect(pager.calls == 3 and hits.size() == 1 and hits[0]["target"] == target
		and target.damage_taken > 0.0, "256 gate-fail decoys do not consume eligible cap")
	pager.dispose()
	match_instance.free()
	await physics_frame
	await physics_frame

	match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var eligible: Array[Node] = []
	for _i in 257:
		var building = DoublesScript.PhysicsCombatTarget.new(centre)
		match_instance.add_child(building)
		match_instance.entity_index().register(building, RegistryScript.Kind.BUILDING)
		eligible.append(building)
	await physics_frame
	await physics_frame
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, eligible[0])
		and OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, eligible[-1]),
		"old physics positively hits first and last eligible Buildings")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), Vector3(530, 0.8, 500),
		4.0, eligible[0]), "old physics misses outside eligible Building")
	var reversed: Array[Node] = eligible.duplicate()
	reversed.reverse()
	pager = OrderedPage.new(reversed)
	resolver = ResolverScript.new()
	resolver._collision_query_adapter = pager
	hits = resolver.resolve(_bullets.runtime_bullet(&"Mortar_B"), match_instance, centre)
	_expect(hits.size() == 256 and hits[0]["target"] == eligible[0]
		and hits[-1]["target"] == eligible[255] and eligible[-1].damage_taken == 0.0,
		"257 eligible Buildings cap at first 256 stable IDs")
	pager.dispose()
	match_instance.free()


func _test_damage_rules() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	for existing in match_instance.get_node("Units").get_children():
		existing.free()
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 1
	match_instance.get_node("Units").add_child(unit)
	var building = DoublesScript.PhysicsCombatTarget.new(Vector3(530, 0.8, 500))
	match_instance.add_child(building)
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(500, 0, 500))
	await physics_frame
	await physics_frame
	var centre := Vector3(500, 0.8, 500)
	var building_centre := Vector3(530, 0.8, 500)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit)
		and OracleScript.hits(match_instance.get_world_3d(), building_centre, 4.0, building),
		"old physics positively hits damage-rule Unit and Building")
	_expect(not OracleScript.hits(match_instance.get_world_3d(), building_centre, 4.0, unit)
		and not OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, building),
		"old physics misses outside damage-rule controls")
	var bullet = _bullets.runtime_bullet(&"Mortar_B")
	var resolver = ResolverScript.new()
	var source = DoublesScript.CombatSource.new()
	unit.max_health = 1000000.0
	unit.health = 1000000.0
	var allied: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre, null, source)
	var full_damage: float = bullet.damage_against(unit.combat_armour_type())
	_expect(allied.size() == 1 and absf(float(allied[0]["damage"]) - full_damage * 0.5) < 0.01,
		"allied incidental splash uses FriendlyDamageAmount half damage")
	unit.health = 1000000.0
	var direct: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre, unit, source)
	_expect(direct.size() == 1 and direct[0]["direct"]
		and absf(float(direct[0]["damage"]) - full_damage) < 0.01,
		"deliberate allied direct target takes full damage once")
	var barrel = _bullets.runtime_bullet(&"BarrelBomb")
	var falloff_centre := Vector3(503.0, 0.8, 500)
	var independent_distance: float = maxf(unit.combat_aim_position().distance_to(falloff_centre)
		- unit.combat_hit_radius(), 0.0)
	_expect(independent_distance > 0.0 and independent_distance < barrel.blast_radius_world(),
		"BarrelBomb Match falloff has interior nonzero surface distance")
	unit.health = 1000000.0
	var falloff: Array[Dictionary] = resolver.resolve(barrel, match_instance, falloff_centre)
	var expected_falloff: float = barrel.damage_against(unit.combat_armour_type()) \
		* (1.0 - independent_distance / barrel.blast_radius_world())
	_expect(falloff.size() == 1 and absf(float(falloff[0]["damage"]) - expected_falloff) < 0.02,
		"Match BarrelBomb falloff uses independent surface distance")
	var pager := DuplicateRidPage.new(building)
	resolver._collision_query_adapter = pager
	building.damage_taken = 0.0
	var duplicated: Array[Dictionary] = resolver.resolve(bullet, match_instance, building_centre)
	_expect(duplicated.size() == 1 and duplicated[0]["target"] == building
		and absf(building.damage_taken - float(duplicated[0]["damage"])) < 0.01,
		"two Building RIDs damage one entity once")
	pager.dispose()
	match_instance.free()


func _test_carried_union() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var centre := Vector3(500.0, 0.8, 500.0)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"old physics positively sees carried-control collider")
	var resolver = ResolverScript.new()
	var bullet_config: Resource = _bullets.bullet_config(&"Mortar_B").duplicate(true)
	bullet_config.anti_aircraft = true
	bullet_config.anti_ground = true
	var bullet = CombatBulletScript.new(bullet_config,
		_bullets.warhead_config(bullet_config.warhead_id))
	unit.max_health = 1000000.0
	unit.health = 1000000.0
	match_instance.entity_state().set_combat_line_carried(unit.entity_id, true)
	var probes_before: int = unit.projectile_hull_diagnostics()["probes"]
	var mismatch_logger := ErrorLogger.new()
	OS.add_logger(mismatch_logger)
	var store_carried: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	OS.remove_logger(mismatch_logger)
	_expect(not unit.is_carried() and store_carried.is_empty() and unit.health == 1000000.0
		and mismatch_logger.errors.size() == 1, "store-carried mismatch logs and delivers no hit")
	_expect(unit.projectile_hull_diagnostics()["probes"] == probes_before,
		"store-carried mismatch avoids exact normal hull")
	var carrier = ATAPCScene.instantiate()
	carrier.owner_player_id = 1
	match_instance.get_node("Units").add_child(carrier)
	carrier.set("_simulation_halted", true)
	carrier.set_process(false)
	carrier.set_meta("combat_ignore", true)
	carrier.set_simulation_position(Vector3(498.5, 0.0, 500.0))
	carrier.transport_attach_cargo(unit, Vector3.ZERO)
	_expect(unit.simulation_position().distance_to(carrier.simulation_position()) < 0.001,
		"canonical cargo stores real carrier root at attach")
	carrier.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	match_instance.advance_ticks(1)
	_expect(unit.simulation_position().distance_to(carrier.simulation_position()) < 0.001,
		"canonical cargo follows real carrier movement tick")
	match_instance.entity_state().set_combat_line_carried(unit.entity_id, false)
	unit.health = 1000000.0
	await physics_frame
	await physics_frame
	probes_before = unit.projectile_hull_diagnostics()["probes"]
	mismatch_logger = ErrorLogger.new()
	OS.add_logger(mismatch_logger)
	var node_carried: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	OS.remove_logger(mismatch_logger)
	_expect(unit.is_carried() and node_carried.is_empty() and unit.health == 1000000.0
		and mismatch_logger.errors.size() == 1, "node-carried mismatch logs and delivers no hit")
	_expect(unit.projectile_hull_diagnostics()["probes"] == probes_before,
		"node-carried mismatch avoids exact normal hull")
	match_instance.entity_state().set_combat_line_carried(unit.entity_id, true)
	unit.global_position = Vector3(530.0, 0.0, 500.0)
	await physics_frame
	await physics_frame
	_expect(not OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"old physics misses carried collider outside blast")
	unit.health = 1000000.0
	var pickup_inside: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(pickup_inside.size() == 1 and unit.health < 1000000.0,
		"stored hull inside damages with rendered collider outside")
	unit.global_position = Vector3(500.0, 0.0, 500.0)
	match_instance.entity_state().set_position(unit.entity_id, Vector3(530.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"old physics positively hits carried collider with pickup outside")
	unit.health = 1000000.0
	var pickup_outside: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(pickup_outside.is_empty() and unit.health == 1000000.0,
		"carried collider in with pickup out fails distance gate")
	match_instance.free()


func _test_canonical_carried() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.set_process(false)
	unit.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	var centre := Vector3(500.0, 0.8, 500.0)
	var outside := Vector3(530.0, 0.8, 500.0)
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit)
		and not OracleScript.hits(match_instance.get_world_3d(), outside, 4.0, unit),
		"old physics positively sees canonical cargo at pickup before transport")
	var carrier := Node3D.new()
	match_instance.add_child(carrier)
	carrier.global_position = unit.global_position
	unit.transport_mark_carried(carrier)
	var state = match_instance.entity_state()
	_expect(unit.is_carried() and state.combat_line_carried(unit.entity_id),
		"canonical transport sets both carried flags")
	var config: Resource = _bullets.bullet_config(&"Mortar_B").duplicate(true)
	config.anti_aircraft = true
	config.anti_ground = true
	var bullet = CombatBulletScript.new(config, _bullets.warhead_config(config.warhead_id))
	var resolver = ResolverScript.new()
	unit.max_health = 1000000.0
	unit.global_position = Vector3(530.0, 0.0, 500.0)
	await physics_frame
	await physics_frame
	_expect(not OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit)
		and OracleScript.hits(match_instance.get_world_3d(), outside, 4.0, unit),
		"old physics positively locates canonical cargo collider outside blast")
	_expect(unit.is_carried() and state.combat_line_carried(unit.entity_id)
		and state.position(unit.entity_id).distance_to(Vector3(500.0, 0.0, 500.0)) < 0.01,
		"collider-out arm retains both carried flags and pickup inside")
	unit.health = 1000000.0
	var probes_before: int = unit.projectile_hull_diagnostics()["probes"]
	var collider_out: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(collider_out.size() == 1 and unit.health < 1000000.0,
		"carried tick hull inside damages with rendered collider outside")
	_expect(unit.projectile_hull_diagnostics()["probes"] > probes_before,
		"carried tick hull receives an exact probe")
	unit.global_position = Vector3(500.0, 0.0, 500.0)
	state.set_position(unit.entity_id, Vector3(530.0, 0.0, 500.0))
	await physics_frame
	await physics_frame
	_expect(OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit)
		and not OracleScript.hits(match_instance.get_world_3d(), outside, 4.0, unit),
		"old physics positively locates canonical cargo collider inside blast")
	_expect(unit.is_carried() and state.combat_line_carried(unit.entity_id),
		"collider-in arm retains both carried flags")
	unit.health = 1000000.0
	probes_before = unit.projectile_hull_diagnostics()["probes"]
	var pickup_out: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(pickup_out.is_empty() and unit.health == 1000000.0,
		"canonical carried collider in and pickup out takes no damage")
	_expect(unit.projectile_hull_diagnostics()["probes"] == probes_before,
		"canonical pickup-out cargo takes no normal hull probe")
	state.set_position(unit.entity_id, Vector3(500.0, 0.0, 500.0))
	_expect(unit.is_carried() and state.combat_line_carried(unit.entity_id)
		and OracleScript.hits(match_instance.get_world_3d(), centre, 4.0, unit),
		"canonical both-in cargo retains flags and settled collider")
	unit.health = 1000000.0
	probes_before = unit.projectile_hull_diagnostics()["probes"]
	var both_in: Array[Dictionary] = resolver.resolve(bullet, match_instance, centre)
	_expect(both_in.size() == 1 and both_in[0]["target"] == unit
		and unit.health < 1000000.0,
		"canonical carried collider and pickup both in take physics damage")
	_expect(unit.projectile_hull_diagnostics()["probes"] > probes_before,
		"canonical both-in cargo uses exact hull probe")
	state.set_position(unit.entity_id, Vector3(530.0, 0.0, 500.0))
	var adapter := OneCargoPage.new(unit)
	var render_only: Dictionary = SplashScript.collect(match_instance, match_instance,
		match_instance.entity_index(), state, match_instance.unit_spatial_index(), centre, 4.0,
		bullet, null, null, func(_entity, _centre): return 0.0,
		CombatRulesScript.COLLISION_MASK, adapter)
	_expect(adapter.calls == 2 and render_only["ok"] and render_only["entries"].is_empty(),
		"physical carried RID cannot admit a rendered-only splash even with an eligible distance")
	match_instance.free()
