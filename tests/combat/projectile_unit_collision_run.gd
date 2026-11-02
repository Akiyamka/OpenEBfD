extends "res://tests/support/suite.gd"

const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ATAPCScene := preload("res://scenes/units/atapc.tscn")
const ATRocketTurretScene := preload("res://assets/converted/buildings/ATRocketTurret/ATRocketTurret.scn")
const ATWallScene := preload("res://assets/converted/buildings/ATWall/ATWall.scn")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const CombatProjectileScript := preload("res://scripts/combat/combat_projectile.gd")
const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")
const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const UnitScript := preload("res://scripts/units/unit.gd")
const Bullets := preload("res://tests/combat/support/combat_bullets.gd")
const Doubles := preload("res://tests/combat/support/combat_doubles.gd")
const MatchUnitSpatialIndexScript := preload("res://scripts/match/match_unit_spatial_index.gd")

class ReversedSpatial extends MatchUnitSpatialIndexScript:
	func padded_segment_candidates(from: Vector3, to: Vector3, padding: float) -> PackedInt32Array:
		var ids := super.padded_segment_candidates(from, to, padding)
		ids.reverse()
		return ids

class AirCubeUnit extends UnitScript:
	func combat_is_airborne() -> bool:
		return true

class RepeatedQueryPage extends RefCounted:
	var rid: RID
	var collider: Object
	func _init(value: RID, body: Object) -> void:
		rid = value
		collider = body
	func ray_hit(_query: PhysicsRayQueryParameters3D) -> Dictionary:
		return {"rid": rid, "collider": collider, "position": Vector3(500.0, 40.8, 500.0)}
	func shape_hits(_query: PhysicsShapeQueryParameters3D, _limit: int) -> Array[Dictionary]:
		return [{"rid": rid, "collider": collider}]

class SingleQueryPage extends RefCounted:
	var rid: RID
	var collider: Object
	var position: Vector3
	var calls := 0
	func _init(value: RID, body: Object, at: Vector3) -> void:
		rid = value
		collider = body
		position = at
	func ray_hit(_query: PhysicsRayQueryParameters3D) -> Dictionary:
		calls += 1
		return {"rid": rid, "collider": collider, "position": position} if calls == 1 else {}
	func shape_hits(_query: PhysicsShapeQueryParameters3D, _limit: int) -> Array[Dictionary]:
		return []

class InvalidQueryPage extends RefCounted:
	var collider: Object
	var calls := 0
	func _init(body: Object) -> void:
		collider = body
	func ray_hit(_query: PhysicsRayQueryParameters3D) -> Dictionary:
		calls += 1
		return {"rid": RID(), "collider": collider, "position": Vector3(500.0, 40.8, 500.0)} if calls == 1 else {}
	func shape_hits(_query: PhysicsShapeQueryParameters3D, _limit: int) -> Array[Dictionary]:
		calls += 1
		var page: Array[Dictionary] = []
		if calls == 1:
			page.append({"rid": RID(), "collider": collider})
		return page

class ExhaustedQueryPages extends RefCounted:
	var collider: Object
	var rids: Array[RID] = []
	var next_rid := 0
	func _init(body: Object) -> void:
		collider = body
		for _index in 4097:
			rids.append(PhysicsServer3D.body_create())
	func dispose() -> void:
		for rid in rids:
			PhysicsServer3D.free_rid(rid)
		rids.clear()
	func ray_hit(_query: PhysicsRayQueryParameters3D) -> Dictionary:
		return {}
	func shape_hits(_query: PhysicsShapeQueryParameters3D, limit: int) -> Array[Dictionary]:
		var page: Array[Dictionary] = []
		for _index in mini(limit, rids.size() - next_rid):
			page.append({"rid": rids[next_rid], "collider": collider})
			next_rid += 1
		return page

class PartialMatch extends Node3D:
	func _enter_tree() -> void:
		add_to_group(&"match_root")
	func current_tick() -> int:
		return 0

class ErrorLogger extends Logger:
	var errors: Array[String] = []
	func _log_error(_function, _file, _line, code, rationale, _editor_notify, _error_type, _script_backtraces) -> void:
		errors.append(str(code) + str(rationale))

var _bullets := Bullets.new()


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await process_frame
	await _run_async_case("stored hull entry beats stale broadphase", _test_stale_direct)
	await _run_async_case("start-inside direct impact begins at stored hull entry zero", _test_start_inside)
	await _run_async_case("rotated Unit root yaw controls direct and Sonic hulls", _test_rotated_yaw)
	await _run_async_case("root-parented homing rocket hits hull entry", _test_root_homing)
	await _run_async_case("Sonic uses the clamped capsule and centre order", _test_sonic_capsule)
	await _run_async_case("static cover blocks direct unit damage", _test_static_cover)
	await _run_async_case("ancestor Match and stored Unit position win", _test_two_match_store)
	await _run_async_case("incomplete physical pages apply no partial hits", _test_incomplete_pages)
	await _run_async_case("air-only Sonic filters ground Units", _test_air_only)
	await _run_async_case("equal-centre and entry ties use stable IDs", _test_reversed_ties)
	await _run_async_case("static wins an exact direct-entry tie", _test_static_tie)
	await _run_async_case("Sonic centre order beats physical entry", _test_sonic_centre_entry)
	await _run_async_case("64 eligible hits are capped after filtering", _test_eligible_cap)
	await _run_async_case("Sonic wall takes slot 64 and damage", _test_sonic_wall_slot)
	await _run_async_case("carried cargo uses current collider and pickup centre", _test_carried_cargo)
	await _run_async_case("foreign Match Units are pierced", _test_foreign_match_units)
	await _run_async_case("same-tick dead Unit is pierced", _test_same_tick_dead_unit)
	await _run_async_case("multiple physical RIDs deliver one entity hit", _test_multi_rid_entity)
	await _run_async_case("unadmitted Unit collider is pierced", _test_unadmitted_unit)
	await _run_async_case("missing authored hull invents no circle", _test_missing_hull)
	await _run_async_case("exact in-tree convex edge and endpoint gap", _test_exact_cube)
	await _run_async_case("partial Match expires without fallback", _test_partial_match)
	await _run_async_case("freed Match owner resumes standalone physics", _test_freed_match_owner)
	_finish("Projectile unit collision")


func _test_stale_direct() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=456"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = ATAPCScene.instantiate()
	unit.owner_player_id = 2
	match_instance.get_node("Units").add_child(unit)
	unit.set_simulation_position(Vector3(510.0, 40.0, 500.0))
	match_instance.advance_ticks(1)
	unit.set_simulation_position(Vector3(510.0, 40.0, 500.0))
	await physics_frame
	var from := Vector3(500.0, 40.8, 495.0)
	var to := Vector3(500.0, 40.8, 505.0)
	unit.set_simulation_position(Vector3(500.0, 40.0, 500.0))
	var ray := PhysicsRayQueryParameters3D.create(from, to, 3)
	var old_hit: Dictionary = match_instance.get_world_3d().direct_space_state.intersect_ray(ray)
	_expect(old_hit.is_empty() or old_hit.get("collider") != unit, "settled physics ray must miss the moved unit")
	var expected: Dictionary = unit.projectile_hull_contact(from, to, unit.simulation_position(), 0.0)
	_expect(expected.get("hit", false), "the authored hull must cross the direct line")
	var copies_before: int = unit.projectile_hull_diagnostics()["copies"]
	var queries_before: int = match_instance.unit_spatial_index().padded_query_count()
	var projectile = CombatProjectileScript.new()
	match_instance.add_child(projectile)
	var impacts: Array[Vector3] = []
	projectile.impacted.connect(func(_target: Object, _damage: float, at: Vector3) -> void: impacts.append(at))
	_expect(projectile.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "coordinate shot launches")
	projectile.advance(0.5)
	_expect(projectile.finish_reason == &"impact_target", "direct shot strikes stored hull")
	_expect(not impacts.is_empty() and impacts[0].distance_to(expected["position"]) < 0.02, "public impact is at authored hull entry")
	_expect(match_instance.unit_spatial_index().padded_query_count() > queries_before, "Match-owned padded query runs")
	_expect(unit.projectile_hull_diagnostics()["copies"] == copies_before, "hot path never copies hulls")
	projectile.free()
	await physics_frame
	unit.set_simulation_position(Vector3(510.0, 40.0, 500.0))
	var stale_hit: Dictionary = match_instance.get_world_3d().direct_space_state.intersect_ray(ray)
	_expect(stale_hit.get("collider") == unit, "old ray still sees the vacated collider")
	var reverse = CombatProjectileScript.new()
	match_instance.add_child(reverse)
	_expect(reverse.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "reverse coordinate shot launches")
	reverse.advance(0.5)
	_expect(reverse.finish_reason != &"impact_target", "stored hull vacated the line")
	reverse.free()
	match_instance.free()


func _test_start_inside() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = _cube_unit(Vector3(0.6, 0.6, 0.6), match_instance.get_node("Units"))
	unit.owner_player_id = 2
	unit.set_simulation_position(Vector3(520.0, 40.0, 500.0))
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	await physics_frame
	var from := Vector3(500.0, 40.0, 500.0)
	var to := Vector3(500.0, 40.0, 505.0)
	match_instance.entity_state().set_position(unit.entity_id, from)
	var old_ray := PhysicsRayQueryParameters3D.create(from, to, 3)
	_expect(match_instance.get_world_3d().direct_space_state.intersect_ray(old_ray).get("collider") != unit, "old body misses the stored start-inside hull")
	var contact: Dictionary = unit.projectile_hull_contact(from, to, from, 0.0)
	_expect(contact.get("hit", false) and is_zero_approx(float(contact.get("entry", INF))) and Vector3(contact.get("position", Vector3.INF)) == from, "stored direct hull entry is exactly zero")
	var shot = CombatProjectileScript.new()
	match_instance.add_child(shot)
	var impacts: Array[Vector3] = []
	shot.impacted.connect(func(_entity: Object, _damage: float, at: Vector3) -> void: impacts.append(at))
	var health_before: float = unit.health
	_expect(shot.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "start-inside coordinate shot launches")
	shot.advance(0.3)
	_expect(shot.finish_reason == &"impact_target" and not impacts.is_empty() and impacts[0] == from, "public direct impact stays at start-inside entry")
	_expect(unit.health < health_before, "start-inside shot damages stored Unit")
	match_instance.free()


func _test_rotated_yaw() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = _cube_unit(Vector3(2.0, 0.5, 0.2), match_instance.get_node("Units"))
	unit.owner_player_id = 2
	unit.set_simulation_position(Vector3(520.0, 40.0, 500.0))
	match_instance.advance_ticks(1)
	unit.set("_simulation_halted", true)
	unit.global_basis = Basis(Vector3.UP, PI * 0.5)
	await physics_frame
	var stored := Vector3(500.0, 40.0, 500.0)
	match_instance.entity_state().set_position(unit.entity_id, stored)
	unit.max_health = 10000.0
	unit.health = 10000.0
	var direct_from := Vector3(497.0, 40.0, 501.0)
	var direct_to := Vector3(503.0, 40.0, 501.0)
	var old_ray := PhysicsRayQueryParameters3D.create(direct_from, direct_to, 3)
	_expect(match_instance.get_world_3d().direct_space_state.intersect_ray(old_ray).get("collider") != unit, "old ray misses rotated Unit at stored position")
	_expect(unit.projectile_hull_contact(direct_from, direct_to, stored, 0.0).get("hit", false), "rotated direct hull oracle crosses long side")
	var direct = CombatProjectileScript.new()
	match_instance.add_child(direct)
	var direct_hits: Array[Object] = []
	direct.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: direct_hits.append(entity))
	_expect(direct.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(direct_from, Vector3.RIGHT), direct_to), "rotated direct shot launches")
	direct.advance(0.3)
	_expect(direct_hits == [unit], "public direct shot uses Unit root yaw")
	var sonic_from := Vector3(499.6, 40.0, 501.0)
	var sonic_to := Vector3(500.4, 40.0, 501.0)
	_expect(not _old_capsule_hits(unit, sonic_from, sonic_to, 0.4), "old Sonic body misses stored rotated hull")
	_expect(unit.projectile_hull_contact(sonic_from, sonic_to, stored, 0.4).get("hit", false), "rotated Sonic hull oracle crosses long side")
	var wave = CombatProjectileScript.new()
	match_instance.add_child(wave)
	var sonic_hits: Array[Object] = []
	wave.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: sonic_hits.append(entity))
	_expect(wave.launch(_bullets.runtime_bullet(&"Sound_B"), Bullets.emission(sonic_from, Vector3.RIGHT), Vector3(507.6, 40.0, 501.0)), "rotated Sonic wave launches")
	wave.advance(0.04)
	_expect(sonic_hits == [unit], "public Sonic wave uses Unit root yaw")
	match_instance.free()


func _test_sonic_capsule() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.match_seed_args_for_test = PackedStringArray(["--match-seed=457"])
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var targets: Array = []
	for x in [-1.0, 1.0]:
		var unit = ATAPCScene.instantiate()
		unit.owner_player_id = 2
		match_instance.get_node("Units").add_child(unit)
		unit.set_simulation_position(Vector3(500.0 + x, 40.0, 500.4))
		targets.append(unit)
	var far = ATAPCScene.instantiate()
	far.owner_player_id = 2
	match_instance.get_node("Units").add_child(far)
	far.set_simulation_position(Vector3(520.0, 40.0, 500.4))
	match_instance.advance_ticks(1)
	match_instance.set("_unit_navigation_system", null)
	for unit in targets:
		unit.global_basis = Basis.IDENTITY
		var offset: Vector3 = unit.combat_aim_position() - unit.simulation_position()
		unit.set_simulation_position(Vector3(500.0 + (float(targets.find(unit)) * 2.0 - 1.0) * 0.8 - offset.x, 40.0, 500.4))
		unit.set("_simulation_halted", true)
	await physics_frame
	var from := Vector3(500.0, 40.8, 500.0)
	var to := from + Vector3(0.0, 0.0, 0.8)
	far.global_basis = Basis.IDENTITY
	far.set("_simulation_halted", true)
	var far_offset: Vector3 = far.combat_aim_position() - far.simulation_position()
	var found_far_gap := false
	for step in 80:
		far.set_simulation_position(Vector3(501.0 + float(step) * 0.05 - far_offset.x, 40.0, 500.4))
		var small: Dictionary = far.projectile_hull_contact(from, to, far.simulation_position(), 0.4)
		var large: Dictionary = far.projectile_hull_contact(from - Vector3(0.0, 0.0, 2.1), to + Vector3(0.0, 0.0, 2.1), far.simulation_position(), 1.4)
		if not small.get("hit", false) and large.get("hit", false):
			found_far_gap = true
			break
	_expect(found_far_gap, "far hull occupies nominal-radius-only corridor")
	var shape := CapsuleShape3D.new()
	shape.radius = 1.4
	shape.height = 0.8
	_expect(is_equal_approx(shape.radius, 0.4), "Godot reads back effective radius 0.4")
	var expected_ids: Array[int] = []
	for unit in targets:
		var contact: Dictionary = unit.projectile_hull_contact(from, to, unit.simulation_position(), 0.4)
		_expect(contact.get("hit", false), "off-axis authored hull overlaps the midpoint sphere")
		expected_ids.append(unit.entity_id)
	var wave = CombatProjectileScript.new()
	match_instance.add_child(wave)
	var impacted_ids: Array[int] = []
	wave.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void:
		if entity != null and "entity_id" in entity:
			impacted_ids.append(int(entity.entity_id))
	)
	_expect(wave.launch(_bullets.runtime_bullet(&"Sound_B"), Bullets.emission(from, Vector3.BACK), from + Vector3(0.0, 0.0, 8.0)), "Sonic coordinate shot launches")
	wave.advance(0.04)
	_expect(impacted_ids == expected_ids, "Sonic delivers both equal-distance units by stable ID")
	_expect(wave.state == CombatProjectileScript.State.FLYING, "Sonic pierces both units")
	wave.free()
	match_instance.free()


func _test_static_cover() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var target = ATAPCScene.instantiate()
	target.owner_player_id = 2
	match_instance.get_node("Units").add_child(target)
	target.set_simulation_position(Vector3(500.0, 40.0, 502.0))
	match_instance.advance_ticks(1)
	target.set("_simulation_halted", true)
	var cover := StaticBody3D.new()
	cover.collision_layer = 2
	cover.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 4.0, 0.5)
	shape.shape = box
	cover.add_child(shape)
	cover.position = Vector3(500.0, 40.8, 497.0)
	match_instance.add_child(cover)
	await physics_frame
	var from := Vector3(500.0, 40.8, 495.0)
	var to := Vector3(500.0, 40.8, 505.0)
	var ray := PhysicsRayQueryParameters3D.create(from, to, 2)
	_expect(match_instance.get_world_3d().direct_space_state.intersect_ray(ray).get("collider") == cover, "cover is the first physics hit")
	var health_before: float = target.health
	var shot = CombatProjectileScript.new()
	match_instance.add_child(shot)
	_expect(shot.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "covered shot launches")
	shot.advance(0.5)
	_expect(target.health == health_before, "cover prevents Unit damage")
	shot.free()
	match_instance.free()


func _test_two_match_store() -> void:
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
	var target = ATAPCScene.instantiate()
	target.owner_player_id = 2
	match_b.get_node("Units").add_child(target)
	target.set_simulation_position(Vector3(510.0, 40.0, 500.0))
	match_b.advance_ticks(1)
	await physics_frame
	var from := Vector3(500.0, 40.8, 495.0)
	var to := Vector3(500.0, 40.8, 505.0)
	target.set_simulation_position(Vector3(500.0, 40.0, 500.0))
	target.global_position = Vector3(510.0, 40.0, 500.0)
	var expected: Dictionary = target.projectile_hull_contact(from, to, target.simulation_position(), 0.0)
	_expect(expected.get("hit", false), "B store hull crosses the direct line")
	var before_a: int = match_a.unit_spatial_index().padded_query_count()
	var before_b: int = match_b.unit_spatial_index().padded_query_count()
	var shot = CombatProjectileScript.new()
	match_b.add_child(shot)
	var impacts: Array[Vector3] = []
	shot.impacted.connect(func(_entity: Object, _damage: float, at: Vector3) -> void: impacts.append(at))
	_expect(shot.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "B-owned shot launches")
	shot.advance(0.5)
	_expect(shot.finish_reason == &"impact_target", "ancestor Match owns stored B target")
	_expect(not impacts.is_empty() and impacts[0].distance_to(expected["position"]) < 0.02, "B shot impacts at stored hull entry")
	_expect(match_b.unit_spatial_index().padded_query_count() > before_b and match_a.unit_spatial_index().padded_query_count() == before_a, "B owner query counter rises alone")
	match_b.free()
	match_a.free()


func _test_incomplete_pages() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var target = ATAPCScene.instantiate()
	target.owner_player_id = 2
	match_instance.get_node("Units").add_child(target)
	target.set_simulation_position(Vector3(500.0, 40.0, 500.4))
	match_instance.advance_ticks(1)
	target.set("_simulation_halted", true)
	for bullet_id in [&"StraightBomb", &"Sound_B"]:
		var sonic: bool = bullet_id == &"Sound_B"
		var from := Vector3(500.0, 40.8, 500.0 if sonic else 495.0)
		var to := Vector3(500.0, 40.8, 500.8 if sonic else 505.0)
		var radius := 0.4 if sonic else 0.0
		_expect(target.projectile_hull_contact(from, to, target.simulation_position(), radius).get("hit", false), "incomplete page fixture has a geometric Unit hit")
		var shot = CombatProjectileScript.new()
		match_instance.add_child(shot)
		var adapter := RepeatedQueryPage.new(target.get_rid(), target)
		shot.set("_collision_query_adapter", adapter)
		var logger := ErrorLogger.new()
		OS.add_logger(logger)
		var health_before: float = target.health
		_expect(shot.launch(_bullets.runtime_bullet(bullet_id), Bullets.emission(from, Vector3.BACK), to + Vector3(0.0, 0.0, 8.0) if sonic else to), "incomplete page shot launches")
		shot.advance(0.04 if sonic else 0.5)
		OS.remove_logger(logger)
		_expect(shot.finish_reason == &"incomplete_collision" and shot.global_position == from, "incomplete physical query expires at from")
		_expect(logger.errors.size() == 1 and logger.errors[0].contains("incomplete physical collision query"), "incomplete query logs one error")
		_expect(target.health == health_before, "incomplete query applies no partial damage")
		shot.free()
	for bullet_id in [&"StraightBomb", &"Sound_B"]:
		var sonic: bool = bullet_id == &"Sound_B"
		var from := Vector3(500.0, 40.8, 500.0 if sonic else 495.0)
		var to := Vector3(500.0, 40.8, 500.8 if sonic else 505.0)
		var shot = CombatProjectileScript.new()
		match_instance.add_child(shot)
		shot.set("_collision_query_adapter", InvalidQueryPage.new(target))
		var logger := ErrorLogger.new()
		OS.add_logger(logger)
		var health_before: float = target.health
		_expect(shot.launch(_bullets.runtime_bullet(bullet_id), Bullets.emission(from, Vector3.BACK), to + Vector3(0.0, 0.0, 8.0) if sonic else to), "invalid-RID shot launches")
		shot.advance(0.04 if sonic else 0.5)
		OS.remove_logger(logger)
		_expect(shot.finish_reason == &"incomplete_collision" and shot.global_position == from, "invalid RID expires at from")
		_expect(logger.errors.size() == 1 and logger.errors[0].contains("incomplete physical collision query"), "invalid RID logs one error")
		_expect(target.health == health_before, "invalid RID applies no partial damage")
		shot.free()
	var exhaust_from := Vector3(500.0, 40.8, 500.0)
	var exhaust_to := Vector3(500.0, 40.8, 500.8)
	var adapter := ExhaustedQueryPages.new(target)
	_expect(adapter.rids.size() == 4097 and adapter.rids[0].is_valid() and adapter.rids[4096].is_valid(), "exhaustion page has 4097 distinct valid RIDs")
	var exhausted = CombatProjectileScript.new()
	match_instance.add_child(exhausted)
	exhausted.set("_collision_query_adapter", adapter)
	var exhaust_logger := ErrorLogger.new()
	OS.add_logger(exhaust_logger)
	var exhaust_health: float = target.health
	_expect(exhausted.launch(_bullets.runtime_bullet(&"Sound_B"), Bullets.emission(exhaust_from, Vector3.BACK), exhaust_to + Vector3(0.0, 0.0, 8.0)), "exhaustion Sonic launches")
	exhausted.advance(0.04)
	OS.remove_logger(exhaust_logger)
	_expect(exhausted.finish_reason == &"incomplete_collision" and exhausted.global_position == exhaust_from, "4096-RID bound expires at from")
	_expect(exhaust_logger.errors.size() == 1 and exhaust_logger.errors[0].contains("incomplete physical collision query"), "4096-RID bound logs one error")
	_expect(target.health == exhaust_health, "4096-RID bound applies no partial damage")
	adapter.dispose()
	exhausted.free()
	match_instance.free()


func _test_air_only() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var parent: Node = match_instance.get_node("Units")
	var ground = _cube_unit(Vector3(0.1, 0.1, 0.1), parent)
	var air = _cube_unit(Vector3(0.1, 0.1, 0.1), parent, true)
	for unit in [ground, air]:
		unit.owner_player_id = 2
		unit.set_simulation_position(Vector3(500.0, 40.8, 500.4))
		unit.set("_simulation_halted", true)
	match_instance.advance_ticks(1)
	var config: Resource = _bullets.bullet_config(&"Sound_B").duplicate(true)
	config.anti_ground = false
	config.anti_aircraft = true
	var bullet = CombatBulletScript.new(config, _bullets.warhead_config(config.warhead_id))
	_expect(not bullet.can_hit(ground) and bullet.can_hit(air), "air-only bullet fixture separates ground and air")
	var from := Vector3(500.0, 40.8, 500.0)
	var to := Vector3(500.0, 40.8, 500.8)
	_expect(ground.projectile_hull_contact(from, to, ground.simulation_position(), 0.4).get("hit", false), "ground decoy crosses authored Sonic sphere")
	var wave = CombatProjectileScript.new()
	match_instance.add_child(wave)
	var impacted_ids: Array[int] = []
	wave.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void:
		if entity != null and "entity_id" in entity:
			impacted_ids.append(int(entity.entity_id))
	)
	_expect(wave.launch(bullet, Bullets.emission(from, Vector3.BACK), Vector3(500.0, 40.8, 508.0)), "air-only wave launches")
	var collisions: Array[Dictionary] = wave._collisions_between(from, to)
	var collision_ids: Array[int] = []
	for collision in collisions:
		var collider: Object = collision.get("collider")
		if collider != null and "entity_id" in collider:
			collision_ids.append(int(collider.entity_id))
	_expect(collision_ids == [air.entity_id], "air-only collision set excludes ground Unit")
	wave.advance(0.04)
	_expect(impacted_ids == [air.entity_id], "air-only wave delivers only airborne Unit")
	match_instance.free()


func _test_reversed_ties() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var parent: Node = match_instance.get_node("Units")
	var first = _cube_unit(Vector3(0.1, 0.1, 0.1), parent)
	var second = _cube_unit(Vector3(0.1, 0.1, 0.1), parent)
	for unit in [first, second]:
		unit.owner_player_id = 2
		unit.set_simulation_position(Vector3(500.0, 40.8, 500.4))
		unit.set("_simulation_halted", true)
	match_instance.advance_ticks(1)
	first.global_basis = Basis.IDENTITY
	second.global_basis = Basis.IDENTITY
	_expect(first.entity_id < second.entity_id, "tie fixture IDs are ordered independently of reversed input")
	var reversed := ReversedSpatial.new(match_instance, match_instance.entity_index(), match_instance.entity_state(), match_instance.admission_queue())
	var sonic_from := Vector3(500.0, 40.8, 500.0)
	var direct_from := Vector3(500.0, 40.8, 495.0)
	for sonic in [true, false]:
		var from: Vector3 = sonic_from if sonic else direct_from
		var to := Vector3(500.0, 40.8, 500.8 if sonic else 505.0)
		var shot = CombatProjectileScript.new()
		match_instance.add_child(shot)
		var ids: Array[int] = []
		shot.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void:
			if entity != null and "entity_id" in entity:
				ids.append(int(entity.entity_id))
		)
		_expect(shot.launch(_bullets.runtime_bullet(&"Sound_B" if sonic else &"StraightBomb"), Bullets.emission(from, Vector3.BACK), Vector3(500.0, 40.8, 508.0 if sonic else 505.0)), "tie shot launches")
		shot.set("_collision_spatial", reversed)
		var collisions: Array[Dictionary] = shot._collisions_between(from, to)
		var sorted_ids: Array[int] = []
		for collision in collisions:
			var collider: Object = collision.get("collider")
			if collider != null and "entity_id" in collider:
				sorted_ids.append(int(collider.entity_id))
		_expect(sorted_ids == [first.entity_id, second.entity_id], "Sonic equal-centre hits sort by stable ID" if sonic else "direct equal-entry Units sort by stable ID")
		shot.advance(0.04 if sonic else 0.5)
		_expect(ids == [first.entity_id, second.entity_id] if sonic else ids == [first.entity_id], "public Sonic tie delivery follows IDs" if sonic else "public direct tie selects smaller ID")
		shot.free()
	match_instance.free()


func _test_static_tie() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = _cube_unit(Vector3(0.2, 0.2, 0.2), match_instance.get_node("Units"))
	unit.owner_player_id = 2
	unit.set_simulation_position(Vector3(500.0, 40.8, 500.0))
	unit.set("_simulation_halted", true)
	match_instance.advance_ticks(1)
	var from := Vector3(500.0, 40.8, 495.0)
	var to := Vector3(500.0, 40.8, 505.0)
	var contact: Dictionary = unit.projectile_hull_contact(from, to, unit.simulation_position(), 0.0)
	_expect(contact.get("hit", false), "tie Unit has an authored hull entry")
	var cover := StaticBody3D.new()
	cover.collision_layer = 2
	match_instance.add_child(cover)
	var page := SingleQueryPage.new(cover.get_rid(), cover, contact["position"])
	var shot = CombatProjectileScript.new()
	match_instance.add_child(shot)
	shot.set("_collision_query_adapter", page)
	var health_before: float = unit.health
	_expect(shot.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "equal-entry shot launches")
	var collisions: Array[Dictionary] = shot._collisions_between(from, to)
	_expect(collisions.size() == 2 and collisions[0].get("collider") == cover and collisions[1].get("collider") == unit, "equal-entry static cover sorts before Unit")
	page.calls = 0
	shot.advance(0.5)
	_expect(unit.health == health_before and shot.finish_reason == &"impact_ground", "equal-entry cover prevents Unit damage")
	match_instance.free()


func _test_sonic_centre_entry() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = _cube_unit(Vector3(0.6, 0.6, 0.6), match_instance.get_node("Units"))
	unit.owner_player_id = 2
	unit.set_simulation_position(Vector3(499.5, 40.3, 499.9))
	unit.set("_simulation_halted", true)
	match_instance.advance_ticks(1)
	unit.global_basis = Basis.IDENTITY
	var physical := Doubles.PhysicsCombatTarget.new(Vector3(500.0, 40.8, 500.9), 0.3)
	match_instance.add_child(physical)
	await physics_frame
	var from := Vector3(500.0, 40.8, 500.0)
	var to := Vector3(500.0, 40.8, 500.8)
	_expect(unit.projectile_hull_contact(from, to, unit.simulation_position(), 0.4).get("hit", false), "near-centre Unit touches Sonic sphere")
	_expect(from.distance_squared_to(unit.combat_aim_position()) < from.distance_squared_to(physical.combat_aim_position()), "Unit aim centre precedes physical centre")
	var wave = CombatProjectileScript.new()
	match_instance.add_child(wave)
	var delivered: Array[Object] = []
	wave.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: delivered.append(entity))
	_expect(wave.launch(_bullets.runtime_bullet(&"Sound_B"), Bullets.emission(from, Vector3.BACK), Vector3(500.0, 40.8, 508.0)), "centre-order wave launches")
	var collisions: Array[Dictionary] = wave._collisions_between(from, to)
	_expect(collisions.size() >= 2 and collisions[0].get("collider") == unit and collisions[1].get("collider") == physical, "Sonic ranks by aim centre across geometric and physical hits")
	wave.advance(0.04)
	_expect(delivered.size() >= 2 and delivered[0] == unit and delivered[1] == physical, "public Sonic delivers near centre first")
	match_instance.free()


func _test_eligible_cap() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var parent: Node = match_instance.get_node("Units")
	var decoy = _cube_unit(Vector3(0.1, 0.1, 0.1), parent, true)
	decoy.owner_player_id = 2
	decoy.set_simulation_position(Vector3(500.0, 40.8, 500.4))
	decoy.set("_simulation_halted", true)
	var eligible: Array = []
	for _index in 65:
		var unit = _cube_unit(Vector3(0.1, 0.1, 0.1), parent)
		unit.owner_player_id = 2
		unit.set_simulation_position(Vector3(500.0, 40.8, 500.4))
		unit.set("_simulation_halted", true)
		eligible.append(unit)
	match_instance.advance_ticks(1)
	decoy.global_basis = Basis.IDENTITY
	for unit in eligible:
		unit.global_basis = Basis.IDENTITY
	var sound = _bullets.runtime_bullet(&"Sound_B")
	_expect(not sound.can_hit(decoy) and sound.can_hit(eligible[0]), "first candidate is ineligible while 65 later Units are eligible")
	var expected: Array[int] = []
	for index in 64:
		expected.append(int(eligible[index].entity_id))
	var from := Vector3(500.0, 40.8, 500.0)
	var sonic_to := Vector3(500.0, 40.8, 500.8)
	var wave = CombatProjectileScript.new()
	match_instance.add_child(wave)
	var delivered: Array[int] = []
	wave.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void:
		if entity != null and "entity_id" in entity:
			delivered.append(int(entity.entity_id))
	)
	_expect(wave.launch(sound, Bullets.emission(from, Vector3.BACK), Vector3(500.0, 40.8, 508.0)), "65-set Sonic shot launches")
	var collisions: Array[Dictionary] = wave._collisions_between(from, sonic_to)
	var ids: Array[int] = []
	for collision in collisions:
		var collider: Object = collision.get("collider")
		if collider != null and "entity_id" in collider:
			ids.append(int(collider.entity_id))
	_expect(ids == expected, "Sonic keeps exactly first 64 eligible IDs")
	wave.advance(0.04)
	_expect(delivered == expected, "public Sonic delivers first 64 eligible IDs")
	var direct = CombatProjectileScript.new()
	match_instance.add_child(direct)
	var direct_from := Vector3(500.0, 40.8, 495.0)
	_expect(direct.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(direct_from, Vector3.BACK), Vector3(500.0, 40.8, 505.0)), "65-set direct shot launches")
	var direct_hits: Array[Dictionary] = direct._collisions_between(direct_from, Vector3(500.0, 40.8, 505.0))
	_expect(direct_hits.size() == 64, "direct merged results cap after sorting at 64")
	match_instance.free()


func _test_sonic_wall_slot() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var parent: Node = match_instance.get_node("Units")
	var near_units: Array = []
	for _index in 63:
		var unit = _cube_unit(Vector3(0.6, 0.6, 0.6), parent)
		unit.owner_player_id = 2
		unit.set_simulation_position(Vector3(499.5, 40.3, 499.9))
		unit.set("_simulation_halted", true)
		near_units.append(unit)
	var wall = ATWallScene.instantiate()
	wall.owner_player_id = 2
	match_instance.get_node("Buildings").add_child(wall)
	var far = _cube_unit(Vector3(0.6, 0.6, 0.6), parent)
	far.owner_player_id = 2
	far.set_simulation_position(Vector3(499.5, 40.3, 500.6))
	far.set("_simulation_halted", true)
	match_instance.advance_ticks(1)
	for unit in near_units:
		unit.global_basis = Basis.IDENTITY
	far.global_basis = Basis.IDENTITY
	var from := Vector3(500.0, 40.8, 500.0)
	var to := Vector3(500.0, 40.8, 500.8)
	var desired_wall_aim := Vector3(500.0, 40.8, 501.5)
	wall.global_position += desired_wall_aim - wall.combat_aim_position()
	await physics_frame
	_expect(wall.is_in_group(&"wall_buildings"), "fixture is a real wall Building")
	var wall_aim: Vector3 = wall.combat_aim_position_from(from)
	_expect(from.distance_squared_to(near_units[0].combat_aim_position()) < from.distance_squared_to(wall_aim) and from.distance_squared_to(wall_aim) < from.distance_squared_to(far.combat_aim_position()), "wall aim rank lies between near and far Units")
	var wave = CombatProjectileScript.new()
	match_instance.add_child(wave)
	var delivered: Array[Object] = []
	wave.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: delivered.append(entity))
	var wall_health: float = wall.health
	var far_health: float = far.health
	_expect(wave.launch(_bullets.runtime_bullet(&"Sound_B"), Bullets.emission(from, Vector3.BACK), Vector3(500.0, 40.8, 508.0)), "wall-slot Sonic shot launches")
	var collisions: Array[Dictionary] = wave._collisions_between(from, to)
	_expect(collisions.size() == 64 and CombatTargetScript.entity_of(collisions[63].get("collider")) == wall, "Sonic wall occupies eligible slot 64")
	wave.advance(0.04)
	_expect(wall.health < wall_health, "Sonic damages real wall")
	_expect(delivered.size() == 64 and delivered[63] == wall and far not in delivered and far.health == far_health, "public Sonic excludes rank-65 Unit")
	match_instance.free()


func _test_carried_cargo() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var cargo = ATAPCScene.instantiate()
	cargo.owner_player_id = 2
	match_instance.get_node("Units").add_child(cargo)
	cargo.set_simulation_position(Vector3(510.0, 40.0, 500.4))
	match_instance.advance_ticks(1)
	var carrier := Node3D.new()
	match_instance.add_child(carrier)
	cargo.transport_mark_carried(carrier)
	cargo.global_position = Vector3(500.0, 40.0, 500.4)
	cargo.set("_simulation_halted", true)
	await physics_frame
	_expect(cargo.is_carried() and cargo.simulation_position().x > 509.0 and cargo.global_position.x < 501.0, "carried fixture separates pickup store from current collider")
	var direct_from := Vector3(500.0, 40.8, 495.0)
	var direct_to := Vector3(500.0, 40.8, 505.0)
	var ray := PhysicsRayQueryParameters3D.create(direct_from, direct_to, 3)
	var physics_hit: Dictionary = match_instance.get_world_3d().direct_space_state.intersect_ray(ray)
	_expect(physics_hit.get("collider") == cargo, "settled current cargo collider crosses direct shot")
	var direct = CombatProjectileScript.new()
	match_instance.add_child(direct)
	var direct_config: Resource = _bullets.bullet_config(&"StraightBomb").duplicate(true)
	direct_config.anti_aircraft = true
	direct_config.anti_ground = true
	var direct_bullet = CombatBulletScript.new(direct_config, _bullets.warhead_config(direct_config.warhead_id))
	var direct_impacts: Array[Vector3] = []
	direct.impacted.connect(func(_entity: Object, _damage: float, at: Vector3) -> void: direct_impacts.append(at))
	_expect(direct_bullet.can_hit(cargo), "carried direct bullet admits airborne cargo")
	_expect(direct.launch(direct_bullet, Bullets.emission(direct_from, Vector3.BACK), direct_to), "carried direct shot launches")
	direct.advance(0.5)
	_expect(not direct_impacts.is_empty() and direct_impacts[0].distance_to(physics_hit["position"]) < 0.02, "carried direct impact uses current physics entry")
	var sonic_from := Vector3(500.0, 40.8, 500.0)
	var sonic_to := Vector3(500.0, 40.8, 500.8)
	var expected_pickup: Vector3 = CombatTargetScript.position_of(cargo, sonic_from)
	_expect(expected_pickup.distance_to(cargo.simulation_position()) > 0.2, "pickup aim differs from stored origin")
	var wave = CombatProjectileScript.new()
	match_instance.add_child(wave)
	var sonic_config: Resource = _bullets.bullet_config(&"Sound_B").duplicate(true)
	sonic_config.anti_aircraft = true
	sonic_config.anti_ground = true
	var sonic_bullet = CombatBulletScript.new(sonic_config, _bullets.warhead_config(sonic_config.warhead_id))
	var sonic_impacts: Array[Vector3] = []
	wave.impacted.connect(func(_entity: Object, _damage: float, at: Vector3) -> void: sonic_impacts.append(at))
	_expect(sonic_bullet.can_hit(cargo), "carried Sonic bullet admits airborne cargo")
	_expect(wave.launch(sonic_bullet, Bullets.emission(sonic_from, Vector3.BACK), Vector3(500.0, 40.8, 508.0)), "carried Sonic shot launches")
	var collisions: Array[Dictionary] = wave._collisions_between(sonic_from, sonic_to)
	_expect(not collisions.is_empty() and CombatTargetScript.entity_of(collisions[0].get("collider")) == cargo, "carried Sonic retrieves current physics collider")
	wave.advance(0.04)
	_expect(not sonic_impacts.is_empty() and sonic_impacts[0].distance_to(expected_pickup) < 0.02, "carried Sonic impact uses pickup aim centre")
	match_instance.free()


func _test_foreign_match_units() -> void:
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
	var foreign = ATAPCScene.instantiate()
	foreign.owner_player_id = 2
	match_a.get_node("Units").add_child(foreign)
	foreign.set_simulation_position(Vector3(500.0, 40.0, 499.0))
	foreign.set("_simulation_halted", true)
	match_a.advance_ticks(1)
	match_b.advance_ticks(1)
	var building := Doubles.PhysicsCombatTarget.new(Vector3(500.0, 40.8, 503.0), 0.5)
	match_b.add_child(building)
	var carrier := Node3D.new()
	match_a.add_child(carrier)
	await physics_frame
	var from := Vector3(500.0, 40.8, 495.0)
	var to := Vector3(500.0, 40.8, 505.0)
	var ray := PhysicsRayQueryParameters3D.create(from, to, 3)
	_expect(match_b.get_world_3d().direct_space_state.intersect_ray(ray).get("collider") == foreign, "foreign Unit is first settled physics collider")
	_expect(match_b.entity_index().id_for(foreign) == 0 and match_a.entity_index().id_for(foreign) > 0, "foreign Unit has no B registry ID")
	var config: Resource = _bullets.bullet_config(&"StraightBomb").duplicate(true)
	config.anti_aircraft = true
	config.anti_ground = true
	var bullet = CombatBulletScript.new(config, _bullets.warhead_config(config.warhead_id))
	for carried in [false, true]:
		if carried:
			foreign.transport_mark_carried(carrier)
		_expect(bullet.can_hit(foreign) and bullet.can_hit(building), "dual bullet admits both foreign and B building")
		var shot = CombatProjectileScript.new()
		match_b.add_child(shot)
		var delivered: Array[Object] = []
		shot.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: delivered.append(entity))
		var damage_before: float = building.damage_taken
		_expect(shot.launch(bullet, Bullets.emission(from, Vector3.BACK), to), "B shot past foreign Unit launches")
		shot.advance(0.5)
		_expect(delivered == [building] and shot.finish_reason == &"impact_target", "foreign Unit is excluded before B building")
		_expect(building.damage_taken > damage_before, "B building takes shot past foreign Unit")
		shot.free()
	match_b.free()
	match_a.free()


func _test_same_tick_dead_unit() -> void:
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
	unit.set_simulation_position(Vector3(500.0, 40.0, 499.0))
	match_instance.advance_ticks(1)
	var building := Doubles.PhysicsCombatTarget.new(Vector3(500.0, 40.8, 503.0), 0.5)
	match_instance.add_child(building)
	await physics_frame
	var from := Vector3(500.0, 40.8, 495.0)
	var to := Vector3(500.0, 40.8, 505.0)
	var ray := PhysicsRayQueryParameters3D.create(from, to, 3)
	var entity_id: int = match_instance.entity_index().id_for(unit)
	_expect(entity_id > 0 and match_instance.get_world_3d().direct_space_state.intersect_ray(ray).get("collider") == unit, "live Unit is first settled collider")
	var config: Resource = _bullets.bullet_config(&"LMG_B").duplicate(true)
	config.damage = 5000.0
	config.anti_aircraft = true
	config.anti_ground = true
	var bullet = CombatBulletScript.new(config, _bullets.warhead_config(config.warhead_id))
	var tick_before: int = match_instance.current_tick()
	var first = CombatProjectileScript.new()
	match_instance.add_child(first)
	var first_delivery: Array[Object] = []
	first.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: first_delivery.append(entity))
	_expect(first.launch(bullet, Bullets.emission(from, Vector3.BACK), to), "first same-tick hitscan launches")
	_expect(first_delivery == [unit] and not unit.combat_is_alive(), "first same-tick shot kills Unit")
	_expect(match_instance.current_tick() == tick_before and match_instance.entity_index().id_for(unit) == entity_id and not match_instance.entity_index().registry().is_alive(entity_id), "dead Unit ID is released before next tick")
	_expect(match_instance.get_world_3d().direct_space_state.intersect_ray(ray).get("collider") == unit, "dead Unit still has settled collider")
	var second = CombatProjectileScript.new()
	match_instance.add_child(second)
	var second_delivery: Array[Object] = []
	second.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: second_delivery.append(entity))
	var building_damage: float = building.damage_taken
	_expect(second.launch(bullet, Bullets.emission(from, Vector3.BACK), to), "second same-tick hitscan launches")
	_expect(second_delivery == [building], "second shot reaches building behind dead Unit")
	_expect(building.damage_taken > building_damage, "B building takes second same-tick shot")
	_expect(match_instance.current_tick() == tick_before, "both shots remain on same Match tick")
	match_instance.free()


func _test_multi_rid_entity() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var target := Doubles.PhysicsCombatTarget.new(Vector3(500.0, 40.8, 500.0), 0.5)
	match_instance.add_child(target)
	var child_body := StaticBody3D.new()
	child_body.collision_layer = 2
	child_body.collision_mask = 0
	var child_shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	child_shape.shape = sphere
	child_body.add_child(child_shape)
	target.add_child(child_body)
	await physics_frame
	var from := Vector3(500.0, 40.8, 499.6)
	var to := Vector3(500.0, 40.8, 500.4)
	var shot = CombatProjectileScript.new()
	match_instance.add_child(shot)
	var delivered: Array[Object] = []
	shot.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: delivered.append(entity))
	_expect(shot.launch(_bullets.runtime_bullet(&"Sound_B"), Bullets.emission(from, Vector3.BACK), to), "multi-RID Sonic launches")
	shot.advance(0.04)
	_expect(delivered == [target], "multi-RID target receives exactly one Sonic hit")
	match_instance.free()


func _test_unadmitted_unit() -> void:
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
	unit.set_simulation_position(Vector3(500.0, 40.0, 499.0))
	var building := Doubles.PhysicsCombatTarget.new(Vector3(500.0, 40.8, 503.0), 0.5)
	match_instance.add_child(building)
	await physics_frame
	var from := Vector3(500.0, 40.8, 495.0)
	var to := Vector3(500.0, 40.8, 505.0)
	var ray := PhysicsRayQueryParameters3D.create(from, to, 3)
	_expect(match_instance.entity_index().id_for(unit) > 0 and not unit.is_in_group(&"sim_units") and match_instance.get_world_3d().direct_space_state.intersect_ray(ray).get("collider") == unit, "unadmitted Unit has settled first collider but no sim entry")
	var before = CombatProjectileScript.new()
	match_instance.add_child(before)
	var before_delivered: Array[Object] = []
	before.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: before_delivered.append(entity))
	_expect(before.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "pre-admission coordinate shot launches")
	before.advance(0.5)
	_expect(before_delivered == [building], "pre-admission shot pierces Unit collider for building")
	match_instance.advance_ticks(1)
	_expect(unit.is_in_group(&"sim_units"), "admission tick enters Unit into simulation")
	var after = CombatProjectileScript.new()
	match_instance.add_child(after)
	var after_delivered: Array[Object] = []
	after.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: after_delivered.append(entity))
	_expect(after.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "post-admission coordinate shot launches")
	after.advance(0.5)
	_expect(after_delivered == [unit], "post-admission shot hits stored Unit hull")
	match_instance.free()


func _test_missing_hull() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	var unit = UnitScript.new()
	unit.config_id = &"ATAPC"
	unit.owner_player_id = 2
	unit.add_to_group(&"units")
	var visual := Node3D.new()
	visual.name = "VisualRoot"
	unit.add_child(visual)
	var source := Node3D.new()
	source.name = "EmptySource"
	source.set_meta("original_name", "slctEmpty")
	source.set_meta("collision_points", PackedVector3Array([
		Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
	]))
	visual.add_child(source)
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	match_instance.get_node("Units").add_child(unit)
	OS.remove_logger(logger)
	_expect(logger.errors.size() == 1 and logger.errors[0].contains("yielded no convex firing-line hull"), "one install warning explains absent authored hull")
	unit.set_simulation_position(Vector3(500.0, 40.0, 500.0))
	match_instance.advance_ticks(1)
	var id: int = match_instance.entity_index().id_for(unit)
	_expect(id > 0 and unit.combat_line_bounds().is_empty(), "one source installs no authored hull")
	match_instance.entity_state().set_combat_line_bounds(id, 1.0, -1.0, 1.0)
	var from := Vector3(500.0, 40.8, 495.0)
	var to := Vector3(500.0, 40.8, 505.0)
	_expect(id in match_instance.unit_spatial_index().padded_segment_candidates(from, to, 0.0), "test-only bounds force hull-less candidate")
	var shot = CombatProjectileScript.new()
	match_instance.add_child(shot)
	var delivered: Array[Object] = []
	shot.impacted.connect(func(entity: Object, _damage: float, _at: Vector3) -> void: delivered.append(entity))
	OS.add_logger(logger)
	_expect(shot.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "hull-less coordinate shot launches")
	shot.advance(0.5)
	OS.remove_logger(logger)
	_expect(delivered.is_empty() and shot.finish_reason != &"impact_target", "hull-less Unit invents no circle hit")
	_expect(logger.errors.size() == 1, "hull-less shot emits no new collision error")
	match_instance.free()


func _test_root_homing() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 5:
		await process_frame
	var target = match_instance.get_node("Units/ScoutA")
	target.set_owner_player_id(2)
	target.stop_at_current_position()
	var turret = ATRocketTurretScene.instantiate()
	turret.owner_player_id = 1
	turret.position = target.global_position + Vector3(-8.0, 0.0, 0.0)
	match_instance.add_child(turret)
	turret.set_process(false)
	var fired: Array = []
	turret.weapon_fired.connect(func(projectiles: Array, _target: Variant, _index: int) -> void: fired.append_array(projectiles))
	_expect(turret.command_attack(target), "real turret accepts the enemy Unit")
	for _frame in 900:
		if not fired.is_empty():
			break
		await process_frame
	_expect(not fired.is_empty(), "real turret fires through the Match tick")
	if fired.is_empty():
		match_instance.free()
		return
	var rocket = fired[0]
	match_instance.set_process(false)
	match_instance.set("_unit_navigation_system", null)
	_expect(rocket.get_parent() == root, "ordinary null-parent fire parents under root")
	var from: Vector3 = rocket.global_position
	var direction: Vector3 = rocket.direction()
	target.set_simulation_position(from + direction * 0.8)
	target.set("_simulation_halted", true)
	var aim: Vector3 = target.combat_aim_position()
	var ray := PhysicsRayQueryParameters3D.create(from, from + direction * 1.12, 3)
	var old_hit: Dictionary = match_instance.get_world_3d().direct_space_state.intersect_ray(ray)
	_expect(old_hit.is_empty() or old_hit.get("collider") != target, "old broadphase misses moved target")
	var before: int = match_instance.unit_spatial_index().padded_query_count()
	var impacts: Array[Vector3] = []
	rocket.impacted.connect(func(_entity: Object, _damage: float, at: Vector3) -> void: impacts.append(at))
	match_instance.advance_ticks(1)
	_expect(match_instance.unit_spatial_index().padded_query_count() > before, "root-parented rocket queries Match index")
	_expect(not impacts.is_empty(), "homing rocket hits moved Unit")
	if not impacts.is_empty():
		var steered_to: Vector3 = from + rocket.direction() * 1.12
		var entry: Dictionary = target.projectile_hull_contact(from, steered_to, target.simulation_position(), 0.0)
		_expect(entry.get("hit", false) and impacts[0].distance_to(entry["position"]) < 0.02, "homing hit is at steered hull entry")
		_expect(impacts[0].distance_to(aim) > 0.2, "entry differs from intended-target fallback aim centre")
	match_instance.free()


func _cube_unit(half: Vector3, parent: Node = null, airborne := false) -> Node3D:
	var unit = AirCubeUnit.new() if airborne else UnitScript.new()
	unit.config_id = &"ATAPC"
	unit.add_to_group(&"units")
	var visual := Node3D.new()
	visual.name = "VisualRoot"
	unit.add_child(visual)
	var source := Node3D.new()
	source.name = "CubeSource"
	source.set_meta("original_name", "slctCube")
	var points := PackedVector3Array()
	for x in [-half.x, half.x]:
		for y in [-half.y, half.y]:
			for z in [-half.z, half.z]:
				points.append(Vector3(x, y, z))
	source.set_meta("collision_points", points)
	visual.add_child(source)
	(parent if parent != null else root).add_child(unit)
	unit.set_process(false)
	return unit


func _old_capsule_hits(unit: Node3D, from: Vector3, to: Vector3, radius: float) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = from.distance_to(to)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(Quaternion(Vector3.UP, (to - from).normalized())), (from + to) * 0.5)
	query.collision_mask = 3
	query.collide_with_bodies = true
	for hit in unit.get_world_3d().direct_space_state.intersect_shape(query, 64):
		if hit.get("collider") == unit:
			return true
	return false


func _test_exact_cube() -> void:
	var control := _cube_unit(Vector3.ONE)
	await physics_frame
	_expect(_old_capsule_hits(control, Vector3(0.0, 0.0, -2.5), Vector3(0.0, 0.0, 2.5), 0.4), "old capsule oracle sees cube centre")
	control.free()
	var slab := _cube_unit(Vector3(0.01, 0.1, 0.01))
	var a := Vector3(0.0, 0.0, 0.0)
	var b := Vector3(0.0, 0.0, 0.8)
	var slab_position := Vector3(0.3, 0.0, 0.8)
	slab.global_position = slab_position
	await physics_frame
	var expected_distance := sqrt(0.29 * 0.29 + 0.39 * 0.39)
	_expect(expected_distance > 0.4 and expected_distance < 0.5, "independent real-slab distance is inside 0.42–0.50")
	_expect(slab.combat_line_bounds().has("radius"), "cube is captured through in-tree authored source")
	_expect(slab.projectile_hull_contact(a, b, slab_position, 0.4).is_empty(), "first midpoint sphere misses tangent endpoint gap")
	_expect(slab.projectile_hull_contact(b, Vector3(0.0, 0.0, 1.6), slab_position, 0.4).is_empty(), "second midpoint sphere also misses endpoint gap")
	_expect(not _old_capsule_hits(slab, a, b, 0.4), "settled old shape also misses first gap tick")
	_expect(not _old_capsule_hits(slab, b, Vector3(0.0, 0.0, 1.6), 0.4), "settled old shape also misses second gap tick")
	_expect(slab.projectile_hull_contact(a, b, Vector3(0.3, 0.0, 0.4), 0.4).get("hit", false), "near slab inside midpoint sphere hits")
	slab.free()
	var cube := _cube_unit(Vector3(0.1, 0.1, 0.1))
	cube.global_position = Vector3(0.45, 0.45, 0.4)
	await physics_frame
	var cube_from := Vector3(0.0, 0.0, 0.0)
	var cube_to := Vector3(0.0, 0.0, 0.8)
	var corner_distance := sqrt(0.35 * 0.35 + 0.35 * 0.35)
	_expect(corner_distance > 0.4, "independent corner distance exceeds clamped radius")
	_expect(not _old_capsule_hits(cube, cube_from, cube_to, 0.4), "short corner near miss also misses old shape")
	_expect(cube.projectile_hull_contact(cube_from, cube_to, Vector3(0.45, 0.45, 0.4), 0.4).is_empty(), "short corner near miss rejects exact hull")
	var long_distance := sqrt(1.5 * 1.5 + 0.4 * 0.4)
	_expect(long_distance > 1.4, "independent long edge distance exceeds nominal radius")
	cube.global_position = Vector3(1.6, 0.5, 0.0)
	await physics_frame
	_expect(not _old_capsule_hits(cube, Vector3(0.0, 0.0, -2.5), Vector3(0.0, 0.0, 2.5), 1.4), "long edge near miss also misses old shape")
	_expect(cube.projectile_hull_contact(Vector3(0.0, 0.0, -2.5), Vector3(0.0, 0.0, 2.5), Vector3(1.6, 0.5, 0.0), 1.4).is_empty(), "long capsule rejects exact edge near miss")
	cube.free()
	var vertex := _cube_unit(Vector3.ONE)
	await physics_frame
	var vertex_from := Vector3(1.28, 1.28, 0.88)
	var vertex_to := Vector3(1.28, 1.28, 1.68)
	var vertex_distance := sqrt(3.0 * 0.28 * 0.28)
	_expect(vertex_distance > 0.4, "independent true-vertex distance exceeds radius")
	_expect(_old_capsule_hits(vertex, vertex_from, vertex_to, 0.4), "old capsule hits true-vertex halo")
	_expect(vertex.projectile_hull_contact(vertex_from, vertex_to, Vector3.ZERO, 0.4).is_empty(), "exact hull rejects old-hit true-vertex halo")
	var vertex_control_from := Vector3(1.1, 1.1, 0.7)
	var vertex_control_to := Vector3(1.1, 1.1, 1.5)
	_expect(_old_capsule_hits(vertex, vertex_control_from, vertex_control_to, 0.4), "old capsule hits closer vertex control")
	_expect(vertex.projectile_hull_contact(vertex_control_from, vertex_control_to, Vector3.ZERO, 0.4).get("hit", false), "exact hull hits closer vertex control")
	vertex.free()
	var edge := _cube_unit(Vector3.ONE)
	await physics_frame
	for d in [0.5, 0.9, 0.95, 1.1]:
		var edge_from := Vector3(1.0 + d, 1.0 + d, 0.5)
		var edge_to := edge_from + Vector3(0.0, 0.0, 5.0)
		var exact_distance := sqrt(2.0 * d * d + 0.9 * 0.9)
		var old_hit := _old_capsule_hits(edge, edge_from, edge_to, 1.4)
		var exact_hit: bool = edge.projectile_hull_contact(edge_from, edge_to, Vector3.ZERO, 1.4).get("hit", false)
		if d == 0.5:
			_expect(exact_distance < 1.4 and old_hit and exact_hit, "long-edge near control hits old and exact hull")
		elif d == 1.1:
			_expect(exact_distance > 1.4 and not old_hit and not exact_hit, "long-edge far control misses old and exact hull")
		else:
			_expect(exact_distance > 1.4 and old_hit, "old capsule hits long-edge halo at d=" + str(d))
			_expect(not exact_hit, "exact hull rejects old-hit long-edge halo at d=" + str(d))
	edge.free()


func _test_partial_match() -> void:
	var partial := PartialMatch.new()
	root.add_child(partial)
	var target := Doubles.PhysicsCombatTarget.new(Vector3(0.0, 40.0, 4.0), 0.6)
	partial.add_child(target)
	await physics_frame
	var shot = CombatProjectileScript.new()
	partial.add_child(shot)
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	var from := Vector3(0.0, 40.0, 0.0)
	var to := Vector3(0.0, 40.0, 8.0)
	_expect(shot.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "partial-context shot launches")
	shot.advance(0.4)
	OS.remove_logger(logger)
	_expect(shot.finish_reason == &"incomplete_collision" and shot.global_position == from, "partial context expires at start")
	_expect(logger.errors.size() == 1 and logger.errors[0].contains("incomplete Match collision context"), "one explicit context error")
	_expect(target.damage_taken == 0.0, "partial context applies no legacy physics damage")
	partial.free()


func _test_freed_match_owner() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	var from := Vector3(0.0, 40.0, 0.0)
	var to := Vector3(0.0, 40.0, 8.0)
	var shot = CombatProjectileScript.new()
	root.add_child(shot)
	_expect(shot.launch(_bullets.runtime_bullet(&"StraightBomb"), Bullets.emission(from, Vector3.BACK), to), "root-parented shot launches while one Match exists")
	_expect(shot.get("_match_owner") == match_instance, "shot initially resolves Match owner")
	match_instance.free()
	var target := Doubles.PhysicsCombatTarget.new(Vector3(0.0, 40.0, 4.0), 0.6)
	root.add_child(target)
	await physics_frame
	var logger := ErrorLogger.new()
	OS.add_logger(logger)
	shot.advance(0.4)
	OS.remove_logger(logger)
	_expect(shot.get("_match_owner") == null and shot.finish_reason == &"impact_target" and target.damage_taken > 0.0, "freed Match owner uses standalone physics")
	_expect(logger.errors.is_empty(), "freed owner fallback emits no context error")
	shot.free()
	target.free()
