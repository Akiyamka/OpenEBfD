extends "res://tests/support/suite.gd"

const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const CarryallScene := preload("res://scenes/units/atadv_carryall.tscn")
const APCScene := preload("res://scenes/units/atapc.tscn")
const ReleasedOracle := preload("res://tests/combat/support/released_cargo_oracle.gd")
const SnapshotScript := preload("res://scripts/match/match_snapshot.gd")
const DesyncStateRingScript := preload("res://scripts/match/desync_state_ring.gd")


func _initialize() -> void:
	await process_frame
	await _run_async_case("carried tick root ignores banked view", _test_carried_tick_pose)
	await _run_async_case("interpolation reset and release", _test_lifecycle)
	await _run_async_case("direct and short Sonic plane tolerance", _test_tolerance)
	_finish("Carried target authority")


func _boot() -> Node:
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for mound in get_nodes_in_group(&"spice_mounds"):
		if match_instance.is_ancestor_of(mound):
			mound.free()
	match_instance.terrain.spice_layer = null
	match_instance.advance_ticks(1)
	return match_instance


func _pair(match_instance: Node) -> Array:
	var carrier := CarryallScene.instantiate() as Unit
	var cargo := APCScene.instantiate() as Unit
	carrier.name = "AP13Carrier"
	cargo.name = "AP13Cargo"
	carrier.owner_player_id = 1
	cargo.owner_player_id = 2
	match_instance.get_node("Units").add_child(carrier)
	match_instance.get_node("Units").add_child(cargo)
	carrier.set_process(false)
	cargo.set_process(false)
	carrier.set("_simulation_halted", true)
	cargo.set("_simulation_halted", true)
	carrier.set_simulation_position(Vector3(500.0, 0.0, 500.0))
	cargo.set_simulation_position(Vector3(510.0, 0.0, 500.0))
	match_instance.advance_ticks(1)
	return [carrier, cargo]


func _test_carried_tick_pose() -> void:
	var match_instance := _boot()
	var pair := _pair(match_instance)
	var carrier := pair[0] as Unit
	var cargo := pair[1] as Unit
	var offset := Vector3(0.0, -2.0, 0.0)
	var pickup := cargo.simulation_position()
	carrier.visual_root.position += Vector3(12.0, 0.0, 0.0)
	carrier.visual_root.basis = Basis(Vector3.FORWARD, 0.35) * carrier.visual_root.basis
	carrier.transport_attach_cargo(cargo, offset)
	var expected := carrier.simulation_position() + carrier.global_basis * offset
	_expect(cargo.get_parent().name == "CargoAnchor" and cargo.transform == Transform3D.IDENTITY,
		"cargo remains attached to presentation anchor")
	_expect(cargo.simulation_position().distance_to(expected) < 0.001 and pickup.distance_to(expected) > 5.0,
		"attach immediately writes independently computed tick root")
	_expect(cargo.global_position.distance_to(expected) > 6.0,
		"banked and offset rendered pose differs from tick root")
	await physics_frame
	await physics_frame
	await process_frame
	var rendered_ray := PhysicsRayQueryParameters3D.create(
		cargo.global_position + Vector3(0.0, 0.8, -5.0),
		cargo.global_position + Vector3(0.0, 0.8, 5.0), 3, [carrier.get_rid()])
	_expect(match_instance.get_world_3d().direct_space_state.intersect_ray(rendered_ray).get("collider") == cargo,
		"old physics ray positively sees displaced rendered collider")
	var yaw_reference := APCScene.instantiate() as Unit
	var tilted_reference := APCScene.instantiate() as Unit
	yaw_reference.owner_player_id = 1
	tilted_reference.owner_player_id = 1
	root.add_child(yaw_reference)
	root.add_child(tilted_reference)
	yaw_reference.global_transform = Transform3D(carrier.global_basis, expected)
	tilted_reference.global_transform = Transform3D(cargo.global_basis, expected)
	await physics_frame
	await physics_frame
	await process_frame
	var discriminating_from := Vector3.ZERO
	var discriminating_to := Vector3.ZERO
	for xi in 31:
		if discriminating_from != Vector3.ZERO:
			break
		for yi in 41:
			var offset_x := -1.5 + float(xi) * 0.1
			var offset_y := float(yi) * 0.05
			var from := expected + Vector3(offset_x, offset_y, -5.0)
			var to := expected + Vector3(offset_x, offset_y, 5.0)
			var yaw_ray := PhysicsRayQueryParameters3D.create(from, to, 3,
				[tilted_reference.get_rid(), cargo.get_rid(), carrier.get_rid()])
			var tilt_ray := PhysicsRayQueryParameters3D.create(from, to, 3,
				[yaw_reference.get_rid(), cargo.get_rid(), carrier.get_rid()])
			var yaw_hit: Dictionary = match_instance.get_world_3d().direct_space_state.intersect_ray(yaw_ray)
			var tilt_hit: Dictionary = match_instance.get_world_3d().direct_space_state.intersect_ray(tilt_ray)
			if yaw_hit.get("collider") == yaw_reference and tilt_hit.get("collider") != tilted_reference:
				discriminating_from = from
				discriminating_to = to
				break
	_expect(discriminating_from != Vector3.ZERO,
		"same-origin yaw and tilted physics references have a discriminating ray")
	if discriminating_from != Vector3.ZERO:
		_expect(not cargo.projectile_hull_contact(discriminating_from, discriminating_to, expected, 0.0).is_empty(),
			"carried exact hull follows carrier root yaw rather than rendered tilt")
	yaw_reference.free()
	tilted_reference.free()
	var stored_before := cargo.simulation_position()
	var aim_before := cargo.combat_aim_position()
	var hash_before: int = match_instance.match_checksum()
	var rendered_before := cargo.global_position
	carrier.visual_root.position += Vector3(12.0, 0.0, 0.0)
	carrier.visual_root.basis = Basis(Vector3.FORWARD, 0.2) * carrier.visual_root.basis
	await physics_frame
	await physics_frame
	await process_frame
	_expect(cargo.global_position.distance_to(rendered_before) > 6.0,
		"render perturbation positively moves attached physics collider")
	_expect(cargo.simulation_position().distance_to(stored_before) < 0.001
		and cargo.combat_aim_position().distance_to(aim_before) < 0.001
		and match_instance.match_checksum() == hash_before,
		"render-only frames leave stored root, aim and checksum unchanged")
	if discriminating_from != Vector3.ZERO:
		_expect(not cargo.projectile_hull_contact(discriminating_from, discriminating_to, expected, 0.0).is_empty(),
			"render-only frames leave exact tick hull unchanged")
	carrier.set_simulation_position(carrier.simulation_position() + Vector3(1.5, 0.0, 0.0))
	match_instance.advance_ticks(1)
	expected = carrier.simulation_position() + carrier.global_basis * offset
	_expect(cargo.simulation_position().distance_to(expected) < 0.001,
		"carried-only Match pass updates stored root after carrier motion")
	var indexed: PackedInt32Array = match_instance.unit_spatial_index().rectangle_candidates(
		Vector2(expected.x - 1.0, expected.z - 1.0), Vector2(expected.x + 1.0, expected.z + 1.0))
	_expect(indexed.has(cargo.entity_id), "AP26 indexes carried cargo at new tick root")
	var pickup_candidates: PackedInt32Array = match_instance.unit_spatial_index().rectangle_candidates(
		Vector2(pickup.x - 1.0, pickup.z - 1.0), Vector2(pickup.x + 1.0, pickup.z + 1.0))
	_expect(not pickup_candidates.has(cargo.entity_id), "AP26 no longer indexes cargo at pickup")
	_expect(cargo.global_position.distance_to(expected) > 6.0,
		"post-tick rendered pose remains distinct")
	match_instance.free()


func _test_lifecycle() -> void:
	var match_instance := _boot()
	var pair := _pair(match_instance)
	# Match's deferred opening placement must finish before this frame-stability probe.
	await process_frame
	var carrier := pair[0] as Unit
	var cargo := pair[1] as Unit
	var rest := cargo.visual_root.position
	cargo.visual_root.position += Vector3(1.0, 0.0, 0.0)
	carrier.transport_attach_cargo(cargo, Vector3(0.0, -2.0, 0.0))
	_expect(cargo.visual_root.position.distance_to(rest) < 0.001,
		"attach resets cargo visual interpolation offset")
	carrier.set_simulation_position(carrier.simulation_position() + Vector3(1.5, 0.0, 0.0))
	match_instance.advance_ticks(1)
	var stored := cargo.simulation_position()
	_expect(stored.distance_to(carrier.simulation_position() + carrier.global_basis * Vector3(0.0, -2.0, 0.0)) < 0.001,
		"moving cargo root follows carrier")
	_expect(cargo.is_in_group(&"sim_carried_units") and cargo.combat_is_airborne(),
		"carried group and airborne eligibility are active")
	var previous: Vector3 = match_instance.entity_state().previous_position(cargo.entity_id)
	_expect(previous.distance_to(stored) > 0.1 and previous.distance_to(stored) < 4.0,
		"measured cargo tick movement is nonzero and below interpolation jump limit")
	cargo._advance_visual_interpolation()
	_expect(cargo.visual_root.position.distance_to(rest) < 0.001,
		"carried cargo does not add its own interpolation offset")
	var moved_hash: int = match_instance.match_checksum()
	match_instance.entity_state().set_position(cargo.entity_id, Vector3(510.0, 0.0, 500.0))
	var pickup_hash: int = match_instance.match_checksum()
	match_instance.entity_state().set_position(cargo.entity_id, stored)
	_expect(moved_hash != pickup_hash and match_instance.match_checksum() == moved_hash,
		"stored cargo position changes the checksum")
	var ring := DesyncStateRingScript.new(4)
	var tick: int = match_instance.current_tick()
	ring.capture(tick, match_instance.entity_state(), match_instance.entity_index(),
		match_instance.get("_unit_navigation_system"), match_instance.sim_rng())
	var cargo_line := ""
	for line in ring.lines_for(tick):
		if line.begins_with("[desync-state] entity %d " % cargo.entity_id):
			cargo_line = line
	_expect(" pos=%s[" % str(stored) in cargo_line and " line_carried=1[01]" in cargo_line,
		"AN1 dump prints moving cargo tick root and carried flag")
	var snapshot := SnapshotScript.new("user://ap13_carried_target_test.json")
	var record: Dictionary = snapshot._capture_entity(cargo)
	var origin: Array = record["transform"]["origin"]
	_expect(origin.size() == 3 and absf(float(origin[0]) - stored.x) < 0.001,
		"carried snapshot transform uses stored tick root")
	var saved: Dictionary = snapshot.save(match_instance.get_node("Buildings"),
		match_instance.get_node("Units"), 1, 0, 0)
	var first_json: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("user://ap13_carried_target_test.json"))
	var schema_keys := ["buildings", "draw_count", "draw_signature", "rng_seed", "units", "version"]
	var observed_keys: Array = first_json.keys()
	observed_keys.sort()
	_expect(saved["ok"] and first_json["version"] == 2.0 and observed_keys == schema_keys,
		"F7 retains version-two keys while cargo is carried")
	var first_transform: Dictionary = {}
	for entry: Dictionary in first_json["units"]:
		if entry["name"] == "AP13Cargo":
			first_transform = entry["transform"]
	_expect(first_transform == record["transform"], "F7 JSON stores cargo tick transform")
	carrier.visual_root.position += Vector3(8.0, 2.0, 0.0)
	await process_frame
	var altered_record: Dictionary = snapshot._capture_entity(cargo)
	_expect(JSON.stringify(record["transform"]) == JSON.stringify(altered_record["transform"]),
		"carried snapshot transform ignores render-frame pose")
	snapshot.save(match_instance.get_node("Buildings"), match_instance.get_node("Units"), 1, 0, 0)
	var second_json: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string("user://ap13_carried_target_test.json"))
	var second_transform: Dictionary = {}
	for entry: Dictionary in second_json["units"]:
		if entry["name"] == "AP13Cargo":
			second_transform = entry["transform"]
	_expect(first_transform == second_transform, "F7 JSON cargo transform ignores render-frame count")
	snapshot.erase()
	var drop := Vector3(520.0, 0.0, 500.0)
	cargo.transport_mark_released(drop, Vector3.FORWARD)
	_expect(not cargo.is_in_group(&"sim_carried_units") and not cargo.is_carried(),
		"release clears carried group")
	_expect(cargo.simulation_position().distance_to(drop) < 0.001,
		"release restores ordered drop root")
	var drop_pose: Dictionary = ReleasedOracle.measure(cargo, carrier)
	_expect(drop_pose["separated"] and drop_pose["public_agrees"] and drop_pose["basis_own"]
		and drop_pose["aim_own"] and not drop_pose["basis_stale"],
		"dropped cargo aim and hull use own facing after former carrier turns")
	cargo.transport_mark_carried(carrier, Vector3.ZERO)
	_expect(cargo.is_in_group(&"sim_carried_units"), "reattach restores group before destruction")
	cargo.transport_mark_destroyed_release()
	var destroyed_pose: Dictionary = ReleasedOracle.measure(cargo, carrier)
	_expect(destroyed_pose["separated"] and destroyed_pose["public_agrees"] and destroyed_pose["basis_own"]
		and destroyed_pose["aim_own"] and not destroyed_pose["basis_stale"],
		"destroyed carrier release restores cargo own facing for aim and hull")
	_expect(not cargo.is_in_group(&"sim_carried_units") and not cargo.is_carried(),
		"destroyed-carrier release clears carried record and group")
	carrier.transport_attach_cargo(cargo, Vector3.ZERO)
	_expect(cargo.is_carried(), "own-death fixture reattaches live cargo")
	cargo.force_transport_death()
	var dead_pose: Dictionary = ReleasedOracle.measure(cargo, carrier)
	_expect(cargo.health <= 0.0 and not cargo.is_carried() and not cargo.is_in_group(&"sim_carried_units")
		and dead_pose["separated"] and dead_pose["public_agrees"] and dead_pose["basis_own"]
		and dead_pose["aim_own"] and not dead_pose["basis_stale"],
		"cargo own death clears carried record and restores its own aim and hull basis")
	match_instance.free()


func _test_tolerance() -> void:
	var match_instance := _boot()
	var pair := _pair(match_instance)
	var carrier := pair[0] as Unit
	var cargo := pair[1] as Unit
	carrier.transport_attach_cargo(cargo, Vector3.ZERO)
	match_instance.advance_ticks(1)
	var collision = cargo.get("_authored_collision")
	var hull: Dictionary = collision.get("_combat_line_hulls")[0]
	var faces: Array = hull["faces"]
	var planes: Array = hull["planes"]
	var chosen_face := PackedVector3Array()
	var chosen_plane := Plane()
	var best_area := 0.0
	for face: PackedVector3Array in faces:
		var area := (face[1] - face[0]).cross(face[2] - face[0]).length()
		if area <= best_area:
			continue
		for plane: Plane in planes:
			if absf(plane.distance_to(face[0])) < 0.0001 \
			and absf(plane.distance_to(face[1])) < 0.0001 \
			and absf(plane.distance_to(face[2])) < 0.0001:
				best_area = area
				chosen_face = face
				chosen_plane = plane
				break
	_expect(best_area > 0.01, "authored APC supplies a positive convex face control")
	if best_area <= 0.01:
		match_instance.free()
		return
	var centroid := (chosen_face[0] + chosen_face[1] + chosen_face[2]) / 3.0
	var tangent := (chosen_face[1] - chosen_face[0]).normalized()
	var pose := Transform3D(cargo.combat_geometry().combat_basis(), cargo.simulation_position())
	var direct_a := pose * (centroid - tangent * 0.01 + chosen_plane.normal * 0.000005)
	var direct_b := pose * (centroid + tangent * 0.01 + chosen_plane.normal * 0.000005)
	var direct_gap := chosen_plane.distance_to(centroid + chosen_plane.normal * 0.000005)
	_expect(direct_gap > 0.000001 and direct_gap <= 0.002,
		"direct face gap lies above old margin and within approved margin")
	var exact_direct: Dictionary = collision.projectile_contact(
		direct_a, direct_b, cargo.simulation_position(), 0.0,
		cargo.combat_geometry().combat_basis(), false)
	_expect(not exact_direct.is_empty(), "independent uncarried exact direct probe hits")
	_expect(not cargo.projectile_hull_contact(direct_a, direct_b, cargo.simulation_position(), 0.0).is_empty(),
		"carried direct prefilter preserves tolerance hit")
	var sonic_a := pose * (centroid - tangent * 0.01 + chosen_plane.normal * 0.01003)
	var sonic_b := pose * (centroid + tangent * 0.01 + chosen_plane.normal * 0.01003)
	var sonic_gap := chosen_plane.distance_to(centroid + chosen_plane.normal * 0.01003)
	_expect(sonic_gap > 0.010001 and sonic_gap <= 0.012,
		"short Sonic face gap lies above old margin and within radius plus approved margin")
	var exact_sonic: Dictionary = collision.projectile_contact(
		sonic_a, sonic_b, cargo.simulation_position(), 0.01,
		cargo.combat_geometry().combat_basis(), false)
	_expect(not exact_sonic.is_empty(), "independent uncarried exact short Sonic probe hits")
	_expect(not cargo.projectile_hull_contact(sonic_a, sonic_b, cargo.simulation_position(), 0.01).is_empty(),
		"carried short Sonic prefilter preserves tolerance hit")
	var negative_a := pose * (centroid - tangent * 0.01 + chosen_plane.normal * 0.05)
	var negative_b := pose * (centroid + tangent * 0.01 + chosen_plane.normal * 0.05)
	_expect(cargo.projectile_hull_contact(negative_a, negative_b, cargo.simulation_position(), 0.01).is_empty(),
		"separated negative control misses")
	match_instance.free()
