extends SceneTree

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const PlayerRosterScript := preload("res://scripts/players/player_roster.gd")
const BuildingOrderScript := preload("res://scripts/buildings/building_order.gd")
const TechnologyTreeScript := preload("res://scripts/buildings/technology_tree.gd")
const BuildingDefinitionScript := preload("res://scripts/buildings/building_definition.gd")
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")
const ModelXbfScript := preload("res://converters/xbf/model_xbf.gd")
const ModelBakeBuilderScript := preload("res://converters/model_bake_builder.gd")
const BuildingBakeBuilderScript := preload("res://converters/building_bake_builder.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


class BuildingStub extends Node:
	var owner_player_id: int
	var config_id: StringName
	var upgrade_level: int

	func _init(new_config_id: StringName, new_owner_player_id: int, new_upgrade_level := 0) -> void:
		config_id = new_config_id
		owner_player_id = new_owner_player_id
		upgrade_level = new_upgrade_level


func _initialize() -> void:
	_run_case("PlayerData money, energy, and signals", _test_player_data_resources)
	_run_case("PlayerRoster reset lifecycle", _test_player_roster_reset_lifecycle)
	_run_case("PlayerRoster rebind and removal", _test_player_roster_rebind_and_removal)
	_run_case("PlayerRoster relations", _test_player_roster_relations)
	_run_case("BuildingOrder progress state", _test_building_order_progress)
	_run_case("TechnologyTree house and subhouse", _test_technology_tree_houses)
	_run_case("TechnologyTree building requirements", _test_technology_tree_building_requirements)
	_run_case("TechnologyTree unit requirements", _test_technology_tree_unit_requirements)
	_run_case("XBF vertex animation fixed-point scale", _test_xbf_vertex_animation_scale)
	_run_case("XBF padded halo anchor", _test_padded_halo_anchor)
	_run_case("XBF animated halo anchors", _test_animated_halo_anchors)
	_run_case("XBF animation table variants", _test_xbf_animation_table_variants)
	_run_case("XBF animation transforms remain finite", _test_xbf_animation_transforms_are_finite)
	_run_case("AT Pillbox idle excludes its source fire range", _test_at_pillbox_idle_repair)
	_run_case("XBF mech Move timelines retain authored speeds", _test_xbf_mech_motion_events)
	_run_case(
		"XBF duplicate sibling animations keep independent paths",
		_test_duplicate_object_animation_paths
	)
	_run_case("XBF loop boundaries preserve authored snaps", _test_xbf_loop_boundaries)
	_run_case("XBF FX banks retain parameters and event frames", _test_xbf_fx_banks)
	_run_case("building markers bake authored attachment FX banks", _test_building_attachment_effects)
	_run_case("aircraft smoke banks form expanding trails", _test_aircraft_smoke_trails)
	_run_case("static flying models receive flight state clips", _test_static_flight_clips)
	_run_case(
		"animated FX textures follow their authored event frames",
		_test_authored_texture_event_frames
	)
	_run_case("building transition clips retain authored action names", _test_building_transition_clips)
	_run_case("XBF mirrored object animations use rotation-safe tracks", _test_mirrored_object_animation_handedness)
	_run_case("XBF mirrored inside-out meshes are re-oriented", _test_mirrored_mesh_orientation)
	_run_case("AT Refinery independent pads and mesh components", _test_at_refinery_partitioning)
	_run_case(
		"Ltmuzzle hides its fixed beam but retains the authored muzzle geometry",
		_test_ltmuzzle_procedural_beam_replacement
	)
	_run_case("Muzzle flash clip visibility", _test_muzzle_flash_clip_visibility)
	_run_case(
		"muzzle flash cutouts bake static while beam textures keep scrolling",
		_test_muzzle_flash_textures_do_not_scroll
	)
	_run_case(
		"unmarked additive blast sheets bake as event-driven flipbooks",
		_test_event_driven_texture_flipbooks
	)
	_run_case(
		"unmarked drum and track textures pan on their own channels",
		_test_unmarked_vehicle_scrolling_textures
	)
	_run_case(
		"ATSonicTank beam01 pans its authored sonic texture",
		_test_at_sonic_tank_beam_texture_scroll
	)
	_run_case(
		"combat-deploy clip rename normalizes Fire_1 to Deployed_Fire",
		_test_combat_deploy_clip_rename
	)

	if _failures > 0:
		printerr("Characterization tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return

	print("Characterization tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var completed: Variant = test.call()
	if completed != true:
		_failures += 1
		printerr("FAIL: %s: case aborted before normal completion" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_player_data_resources() -> bool:
	var player = PlayerDataScript.new()
	var events: Array[Array] = []
	player.resources_changed.connect(
		func(player_id: int, money: int, energy: int) -> void:
			events.append([player_id, money, energy])
	)
	player.configure(7, "Tester", Color.WHITE, &"Atreides", [&"Fremen", &"Fremen", &""], 3, 100, -5)

	_expect(player.player_id == 7, "configure must assign the player id")
	_expect(player.money == 100, "configure must assign starting money")
	_expect(player.energy == -5, "energy currently permits a negative balance")
	_expect(player.subhouse_ids == [&"Fremen"], "configure must remove empty and duplicate subhouses")
	_expect(not player.is_neutral, "a regular player must not be neutral")

	events.clear()
	player.add_money(-150)
	player.add_money(40)
	player.money = 40
	_expect(player.money == 40, "money must clamp at zero before later additions")
	_expect(not player.spend_money(-1), "negative spending must be rejected")
	_expect(not player.spend_money(50), "spending above the balance must be rejected")
	_expect(player.spend_money(15), "affordable spending must succeed")
	player.add_energy(-3)

	_expect(player.money == 25, "successful spending must reduce money")
	_expect(player.energy == -8, "add_energy must apply signed deltas")
	_expect(events.size() == 4, "only effective resource changes must emit signals")
	if events.size() == 4:
		_expect(events[0] == [7, 0, -5], "money clamping must emit the clamped balance")
		_expect(events[1] == [7, 40, -5], "adding money must emit the new balance")
		_expect(events[2] == [7, 25, -5], "spending must emit the new balance")
		_expect(events[3] == [7, 25, -8], "energy changes must emit both current resources")
	return true


func _test_player_roster_reset_lifecycle() -> bool:
	var roster = PlayerRosterScript.new()
	roster.reset_for_match()
	_expect(roster.player_count() == 0, "a reset match must contain no regular players")
	_expect(roster.player_count(true) == 1, "a reset match must contain exactly one neutral player")
	_expect(roster.neutral_player() != null, "the neutral player must exist after reset")

	var changed_ids: Array[int] = []
	roster.player_changed.connect(func(player_id: int) -> void: changed_ids.append(player_id))
	var old_player = roster.create_player(1, "Old", Color.WHITE, &"Atreides", [], 1, 50, 0)
	roster.local_player_id = 1
	roster.set_relation(1, 2, PlayerDataScript.Relation.ALLY)

	changed_ids.clear()
	roster.reset_for_match()
	changed_ids.clear()
	old_player.add_money(1)
	_expect(changed_ids.is_empty(), "players removed by reset must no longer notify the roster")
	_expect(roster.local_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID, "reset must select neutral locally")
	_expect(roster.player_count() == 0, "reset must remove prior regular players")
	_expect(roster.player_count(true) == 1, "reset must recreate only one neutral player")
	_expect(
		roster.relation_between(1, 2) == PlayerDataScript.Relation.NEUTRAL,
		"reset must clear explicit relations"
	)
	roster.free()
	return true


func _test_player_roster_rebind_and_removal() -> bool:
	var roster = PlayerRosterScript.new()
	roster.reset_for_match()
	var changed_ids: Array[int] = []
	roster.player_changed.connect(func(player_id: int) -> void: changed_ids.append(player_id))

	var replaced_player = roster.create_player(1, "First", Color.WHITE)
	var current_player = roster.create_player(1, "Replacement", Color.WHITE)
	changed_ids.clear()
	replaced_player.add_money(5)
	_expect(changed_ids.is_empty(), "replaced players must be disconnected")
	current_player.add_money(5)
	_expect(changed_ids == [1], "the replacement player must notify exactly once")

	roster.add_player(current_player)
	changed_ids.clear()
	current_player.add_money(5)
	_expect(changed_ids == [1], "rebinding the same resource must not duplicate its signal")

	roster.create_player(2, "Other", Color.WHITE)
	roster.local_player_id = 1
	roster.set_relation(1, 2, PlayerDataScript.Relation.ALLY)
	roster.remove_player(1)
	changed_ids.clear()
	current_player.add_money(5)
	_expect(changed_ids.is_empty(), "removed players must be disconnected")
	_expect(roster.local_player_id == PlayerDataScript.NEUTRAL_PLAYER_ID, "removing local player must select neutral")
	_expect(not roster.has_player(1), "removed players must leave the roster")
	_expect(
		roster.relation_between(1, 2) == PlayerDataScript.Relation.NEUTRAL,
		"removal must clear that player's explicit relations"
	)
	roster.free()
	return true


func _test_player_roster_relations() -> bool:
	var roster = PlayerRosterScript.new()
	roster.reset_for_match()
	roster.create_player(1, "One", Color.WHITE, &"Atreides", [], 9)
	roster.create_player(2, "Two", Color.WHITE, &"Atreides", [], 9)
	roster.create_player(3, "Three", Color.WHITE, &"Ordos", [], 8)

	_expect(roster.are_allied(1, 1), "a player must be allied with itself")
	_expect(roster.are_allied(1, 2), "players on the same non-neutral team must default to allies")
	_expect(roster.are_enemies(1, 3), "players on different teams must default to enemies")
	_expect(
		roster.relation_between(1, PlayerDataScript.NEUTRAL_PLAYER_ID) == PlayerDataScript.Relation.NEUTRAL,
		"relations with neutral must be neutral"
	)

	roster.set_relation(3, 1, PlayerDataScript.Relation.NEUTRAL)
	_expect(
		roster.relation_between(1, 3) == PlayerDataScript.Relation.NEUTRAL,
		"explicit relations must be symmetric"
	)
	roster.clear_relation(1, 3)
	_expect(roster.are_enemies(3, 1), "clearing an explicit relation must restore the default")
	_expect(roster.shared_vision_player_ids(1) == [1, 2], "shared vision must include self and allies in id order")
	roster.free()
	return true


func _test_building_order_progress() -> bool:
	var order = BuildingOrderScript.new()
	_expect(not order.ready, "a new order must not be ready")
	_expect(not order.manually_paused, "a new order must not be paused")
	_expect(is_equal_approx(order.progress_percent(), 100.0), "an empty order currently reports complete")

	order.cost = 100
	order.paid_cost = 25
	_expect(is_equal_approx(order.progress_percent(), 25.0), "paid cost must define paid-order progress")
	order.manually_paused = true
	_expect(is_equal_approx(order.progress_percent(), 25.0), "pausing must preserve progress")
	order.paid_cost = 150
	_expect(is_equal_approx(order.progress_percent(), 100.0), "paid-order progress must clamp to 100")

	order.cost = 0
	order.build_time_ticks = 120
	order.elapsed_ticks = 30
	order.manually_paused = false
	_expect(is_equal_approx(order.progress_percent(), 25.0), "elapsed ticks must define free-order progress")
	order.ready = true
	order.elapsed_ticks = 0
	_expect(is_equal_approx(order.progress_percent(), 100.0), "ready state must always report complete")
	return true


func _test_technology_tree_houses() -> bool:
	var tree = TechnologyTreeScript.new()
	var player = PlayerDataScript.new()
	player.configure(1, "Atreides", Color.WHITE, &"Atreides", [&"Fremen"], 1)
	var no_buildings: Array[Node] = []

	_expect(not tree.is_available(null, player, no_buildings), "null config must be unavailable")
	_expect(not tree.is_available(_config(&"building"), null, no_buildings), "null player must be unavailable")
	_expect(tree.is_available(_config(&"building"), player, no_buildings), "a config without house must be available")
	_expect(
		tree.is_available(_config(&"building", &"Atreides"), player, no_buildings),
		"the player's primary house must be accepted"
	)
	_expect(
		tree.is_available(_config(&"building", &"Fremen"), player, no_buildings),
		"the player's subhouses must be accepted"
	)
	_expect(
		not tree.is_available(_config(&"building", &"Ix"), player, no_buildings),
		"an unrelated house must be rejected"
	)
	return true


func _test_technology_tree_building_requirements() -> bool:
	var tree = TechnologyTreeScript.new()
	var player = PlayerDataScript.new()
	player.configure(1, "Builder", Color.WHITE, &"Atreides")
	var primary := BuildingStub.new(&"ConYard", 1)
	var secondary := BuildingStub.new(&"Windtrap", 1)
	var enemy_primary := BuildingStub.new(&"ConYard", 2, 1)
	var buildings: Array[Node] = [primary, secondary]

	var config = _config(&"building", &"Atreides", [&"ConYard"], [&"Windtrap"])
	_expect(tree.is_available(config, player, buildings), "owned primary and secondary requirements must pass")
	_expect(
		not tree.is_available(config, player, [secondary]),
		"a missing primary requirement must fail"
	)
	_expect(
		not tree.is_available(config, player, [primary]),
		"a missing secondary requirement must fail"
	)
	_expect(
		not tree.is_available(config, player, [enemy_primary, secondary]),
		"another player's buildings must not satisfy requirements"
	)

	config = _config(&"building", &"Atreides", [&"ConYard"], [], true)
	_expect(not tree.is_available(config, player, buildings), "an upgraded requirement must reject level zero")
	primary.upgrade_level = 1
	_expect(tree.is_available(config, player, buildings), "an upgraded matching building must pass")

	config = _config(&"building", &"Atreides", [&"ConYard"], [&"Windtrap"], false, 4)
	_expect(
		tree.is_available(config, player, buildings),
		"max_tech_level defaulting to unlimited must not gate an entry"
	)
	_expect(
		not tree.is_available(config, player, buildings, 3),
		"a map tech level below the entry's tech_level must reject it"
	)
	_expect(
		tree.is_available(config, player, buildings, 4),
		"a map tech level at or above the entry's tech_level must accept it"
	)

	primary.free()
	secondary.free()
	enemy_primary.free()
	return true


func _test_technology_tree_unit_requirements() -> bool:
	var tree = TechnologyTreeScript.new()
	var player = PlayerDataScript.new()
	player.configure(1, "Trainer", Color.WHITE, &"Atreides")
	var barracks := BuildingStub.new(&"Barracks", 1)
	var windtrap := BuildingStub.new(&"Windtrap", 1)
	var buildings: Array[Node] = [barracks, windtrap]
	var config = _config(&"unit", &"Atreides", [&"Barracks", &"Factory"], [&"Windtrap"])

	_expect(tree.is_available(config, player, buildings), "unit lists must use primary_buildings/secondary_buildings")
	barracks.config_id = &"Unrelated"
	_expect(not tree.is_available(config, player, buildings), "unit primary requirements must be enforced")

	barracks.free()
	windtrap.free()
	return true


func _test_xbf_vertex_animation_scale() -> bool:
	var cases := [
		["res://assets/raw_original_content/3DDATA/Units/AT_Scout_H0.XBF", "scout", 6, 19],
		["res://assets/raw_original_content/3DDATA/Units/AT_Sniper_H0.XBF", "sniper", 6, 20],
		["res://assets/raw_original_content/3DDATA/Units/AT_inf_H0.xbf", "LtINF", 9, 25],
	]
	for model_case: Array in cases:
		var xbf = ModelXbfScript.load_file(String(model_case[0]))
		_expect(xbf != null, "%s must parse" % String(model_case[0]).get_file())
		if xbf == null:
			continue
		_expect(xbf.animation_entries.size() == int(model_case[3]), "%s must expose all named animation clips" % String(model_case[0]).get_file())
		var object := _find_xbf_object(xbf.objects, String(model_case[1]))
		_expect(not object.is_empty(), "%s must contain its animated body" % String(model_case[0]).get_file())
		if object.is_empty():
			continue
		var animation: Dictionary = object.vertex_animation
		_expect(int(animation.get("kind", -1)) == int(model_case[2]), "%s must retain its fixed-point kind" % String(model_case[0]).get_file())
		var frames: Dictionary = animation.get("frames", {})
		var frame_ids := frames.keys()
		frame_ids.sort()
		_expect(not frame_ids.is_empty(), "%s must contain decoded vertex frames" % String(model_case[0]).get_file())
		if frame_ids.is_empty():
			continue
		var static_bounds := _points_bounds(object.positions as PackedVector3Array)
		var animated_bounds := _points_bounds(frames[frame_ids[0]] as PackedVector3Array)
		var relative_error := animated_bounds.size.distance_to(static_bounds.size) / maxf(static_bounds.size.length(), 0.0001)
		_expect(relative_error < 0.02, "%s animated body must preserve the authored scale" % String(model_case[0]).get_file())
	return true


func _test_padded_halo_anchor() -> bool:
	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(
		"res://assets/raw_original_content/3DDATA/Units/HK_Engineer_H0.xbf"
	)
	_expect(scene != null, "HK Engineer model must build")
	if scene == null:
		return true
	var root := scene.instantiate() as Node3D
	var anchor := _find_node_with_meta(root, "halo_anchor")
	_expect(anchor != null, "HK Engineer's padded #^^0 marker must become a halo anchor")
	if anchor != null:
		var bounds: AABB = anchor.get_meta("halo_anchor_bounds")
		_expect(bounds.size.x > 100.0, "HK Engineer halo anchor must retain its authored bounds")
	root.free()
	return true


func _test_animated_halo_anchors() -> bool:
	var kobra_scene := _build_model_scene(
		"res://assets/raw_original_content/3DDATA/Units/OR_Kobra_H0.XBF"
	)
	_expect(kobra_scene != null, "Kobra model must build")
	if kobra_scene != null:
		var model := kobra_scene.instantiate() as Node3D
		var anchor := _find_node_with_meta(model, "halo_anchor")
		var player := model.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var deploy := player.get_animation(&"Deploy_Gun") if player != null else null
		var track := _anchor_transform_track(model, anchor, deploy)
		_expect(
			track >= 0,
			"Kobra Deploy_Gun must retain the authored #^^0 transform track"
		)
		if track >= 0:
			var travel_transform: Transform3D = deploy.value_track_interpolate(
				track, 0.0
			)
			var deployed_transform: Transform3D = deploy.value_track_interpolate(
				track, 1.5
			)
			_expect(
				deployed_transform.origin.y > travel_transform.origin.y + 50.0,
				"Kobra #^^0 track must raise the halo while the gun deploys"
			)
		model.free()

	var missile_scene := _build_model_scene(
		"res://assets/raw_original_content/3DDATA/Units/HK_missile_H0.xbf"
	)
	_expect(missile_scene != null, "HK Missile model must build")
	if missile_scene != null:
		var model := missile_scene.instantiate() as Node3D
		var anchor := _find_node_with_meta(model, "halo_anchor")
		var player := model.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var stationary := player.get_animation(&"Stationary") if player != null else null
		var track := _anchor_transform_track(model, anchor, stationary)
		_expect(
			track >= 0,
			"HK Missile Stationary must retain the authored #^^0 transform track"
		)
		if anchor != null:
			var reference_basis: Basis = anchor.get_meta(
				"halo_anchor_reference_basis", Basis.IDENTITY
			)
			_expect(
				is_equal_approx(reference_basis.x.length(), 0.451613),
				"HK Missile halo footprint must use its animated 0.451613 scale"
			)
			var source_bounds: AABB = anchor.get_meta("halo_anchor_bounds")
			var expected_radius := 1.50636
			var reference_radius := (
				source_bounds.size.x
				* reference_basis.x.length()
				* model.scale.x
				* 0.5
			)
			_expect(
				absf(reference_radius - expected_radius) < 0.01,
				"HK Missile halo radius must be %.5f, got %.5f"
					% [expected_radius, reference_radius]
			)
			if track >= 0:
				var terminal_transform: Transform3D = stationary.value_track_interpolate(
					track, stationary.length - 1.0 / 20.0
				)
				_expect(
					is_equal_approx(terminal_transform.basis.x.length(), 1.0)
					and not is_equal_approx(
						reference_basis.x.length(),
						terminal_transform.basis.x.length()
					),
					"HK Missile footprint must ignore its terminal identity key"
				)
		model.free()

	var sardaukar_scene := _build_model_scene(
		"res://assets/raw_original_content/3DDATA/Units/IM_Sardaukar_H0.xbf"
	)
	_expect(sardaukar_scene != null, "IM Sardaukar model must build")
	if sardaukar_scene != null:
		var model := sardaukar_scene.instantiate() as Node3D
		var anchor := _find_node_with_meta(model, "halo_anchor")
		var player := model.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var stationary := player.get_animation(&"Stationary") if player != null else null
		var track := _anchor_transform_track(model, anchor, stationary)
		_expect(
			track >= 0 and stationary.track_get_key_count(track) == 1,
			"IM Sardaukar Stationary must hold the final authored #^^0 pose"
		)
		if track >= 0 and stationary.track_get_key_count(track) == 1:
			var held_transform: Transform3D = stationary.track_get_key_value(
				track, 0
			)
			_expect(
				held_transform.origin.y > 40.0,
				"IM Sardaukar Stationary halo must remain above the unit"
			)
		model.free()
	return true


func _build_model_scene(path: String) -> PackedScene:
	var builder = ModelBakeBuilderScript.new()
	return builder.build(path)


func _anchor_transform_track(
	model: Node3D, anchor: Node3D, animation: Animation
) -> int:
	if anchor == null or animation == null:
		return -1
	var path := NodePath("%s:transform" % String(model.get_path_to(anchor)))
	return animation.find_track(path, Animation.TYPE_VALUE)


func _find_node_with_meta(node: Node, key: String) -> Node3D:
	if node is Node3D and node.has_meta(key):
		return node as Node3D
	for child in node.get_children():
		var found := _find_node_with_meta(child, key)
		if found != null:
			return found
	return null


func _find_xbf_object(objects: Array[Dictionary], expected_name: String) -> Dictionary:
	for object: Dictionary in objects:
		if String(object.name) == expected_name:
			return object
		var child := _find_xbf_object(object.children, expected_name)
		if not child.is_empty():
			return child
	return {}


func _points_bounds(points: PackedVector3Array) -> AABB:
	if points.is_empty():
		return AABB()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point: Vector3 in points:
		bounds = bounds.expand(point)
	return bounds


func _test_duplicate_object_animation_paths() -> bool:
	var path := "res://assets/raw_original_content/3DDATA/Buildings/AT_Palace_H0.XbF"
	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(path)
	_expect(scene != null, "AT Palace idle model must build")
	if scene == null:
		return true
	var root := scene.instantiate() as Node3D
	var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var timeline := player.get_animation(&"timeline") if player != null else null
	_expect(timeline != null, "AT Palace idle model must retain its source timeline")
	if timeline == null:
		root.free()
		return true

	for source_suffix in ["Spotlight02", "Spotlight03"]:
		var nodes: Array[Node3D] = []
		_collect_nodes_with_original_suffix(root, source_suffix, nodes)
		_expect(
			nodes.size() == 2,
			"AT Palace must retain both source objects named %s" % source_suffix
		)
		var converted_names := {}
		for node in nodes:
			converted_names[String(node.name)] = true
			var track_path := NodePath(
				"%s:transform" % String(root.get_path_to(node))
			)
			var track := timeline.find_track(track_path, Animation.TYPE_VALUE)
			_expect(
				track >= 0,
				"%s must have its own transform track at %s"
					% [node.name, track_path]
			)
			if track >= 0:
				var first_key := timeline.track_get_key_value(track, 0) as Transform3D
				_expect(
					first_key.origin.distance_to(node.transform.origin) < 0.001,
					"%s track must start at its own authored transform" % node.name
				)
		_expect(
			converted_names.size() == nodes.size(),
			"duplicate %s siblings must receive stable unique node names"
				% source_suffix
		)
	root.free()
	return true


func _collect_nodes_with_original_suffix(
		node: Node, suffix: String, result: Array[Node3D]
	) -> void:
	if node is Node3D and String(node.get_meta("original_name", "")).ends_with(suffix):
		result.append(node as Node3D)
	for child in node.get_children():
		_collect_nodes_with_original_suffix(child, suffix, result)


func _test_xbf_loop_boundaries() -> bool:
	var paths := [
		"res://assets/raw_original_content/UI0001/CURSORS/CU_Select_H0.xbf",
		"res://assets/raw_original_content/3DDATA/Buildings/at_factory_H0.xbf",
		"res://assets/raw_original_content/3DDATA/Buildings/at_hanger_H0.xbf",
		"res://assets/raw_original_content/3DDATA/Buildings/AT_conyard_H0.XbF",
	]
	for path: String in paths:
		var builder = ModelBakeBuilderScript.new()
		var scene: PackedScene = builder.build(path)
		_expect(scene != null, "%s must build" % path.get_file())
		if scene == null:
			continue
		var root := scene.instantiate()
		var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		_expect(player != null, "%s must expose animation tracks" % path.get_file())
		if player == null:
			root.free()
			continue
		var transform_tracks := 0
		for animation_name in player.get_animation_list():
			var animation := player.get_animation(animation_name)
			for track in animation.get_track_count():
				if not String(animation.track_get_path(track)).ends_with(":transform"):
					continue
				transform_tracks += 1
				_expect(
					not animation.track_get_interpolation_loop_wrap(track),
					"%s/%s track %s must snap at the loop boundary"
						% [path.get_file(), animation_name, animation.track_get_path(track)]
				)
		_expect(transform_tracks > 0, "%s must contain transform tracks" % path.get_file())
		root.free()

	var building_builder = BuildingBakeBuilderScript.new()
	var building_scene: PackedScene = building_builder.build(&"ATFactory")
	_expect(building_scene != null, "ATFactory wrapper must build")
	if building_scene != null:
		var building_root := building_scene.instantiate()
		var state_player := building_root.get_node_or_null("StatePlayer") as AnimationPlayer
		var idle := state_player.get_animation(&"idle") if state_player != null else null
		_expect(idle != null, "ATFactory wrapper must expose its idle animation")
		if idle != null:
			var copied_transform_tracks := 0
			for track in idle.get_track_count():
				if not String(idle.track_get_path(track)).ends_with(":transform"):
					continue
				copied_transform_tracks += 1
				_expect(
					not idle.track_get_interpolation_loop_wrap(track),
					"ATFactory wrapper track %s must retain the snap boundary"
						% idle.track_get_path(track)
				)
			_expect(copied_transform_tracks > 0, "ATFactory idle must copy transform tracks")
		building_root.free()
	return true


func _test_xbf_animation_table_variants() -> bool:
	var cases := [
		["AT_Sniper_H0.XBF", 20],
		["G_harvester_h0.XbF", 13],
		["AT_General_H0.XBF", 22],
		["GU_Maker_H0.xbf", 5],
		["HK_ltinf_H0.xbf", 22],
		["IN_SurfaceWorm_H0.xbf", 13],
	]
	for model_case: Array in cases:
		var file_name := String(model_case[0])
		var path := "res://assets/raw_original_content/3DDATA/Units".path_join(file_name)
		var xbf = ModelXbfScript.load_file(path)
		_expect(xbf != null, "%s must parse" % file_name)
		if xbf == null:
			continue
		_expect(xbf.animation_entries.size() == int(model_case[1]), "%s must expose its complete animation table" % file_name)
		var names: Array[String] = []
		for entry: Dictionary in xbf.animation_entries:
			names.append(String(entry.get("name", "")))
		_expect(names.has("Stationary"), "%s must expose Stationary" % file_name)
	return true


func _test_xbf_animation_transforms_are_finite() -> bool:
	var path := "res://assets/raw_original_content/3DDATA/Units/HK_Flamer_H0.xbf"
	var scene: PackedScene = ModelBakeBuilderScript.new().build(path)
	_expect(scene != null, "HK_Flamer_H0 must build")
	if scene == null:
		return true

	var root := scene.instantiate()
	var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(player != null, "HK_Flamer_H0 must expose animation tracks")
	if player != null:
		var timeline := player.get_animation(&"timeline")
		for node_path in [
			"_0root_/_Fire/_box04",
			"_0root_/_Fire/_box05",
			"_0root_/_Fire/_box06",
			"_0root_/_Fire/_box07",
			"_0root_/_Fire/gunbone",
			"_0root_/_Fire/_box08",
			"_0root_/_Fire/_box09",
			"_0root_/_Fire/_box10",
			"_0root_/_Fire/_box11",
		]:
			var node := root.get_node(node_path) as Node3D
			var track := timeline.find_track(
				NodePath("%s:transform" % node_path), Animation.TYPE_VALUE
			)
			var first_transform := timeline.track_get_key_value(
				track, 0
			) as Transform3D
			_expect(
				node.transform.is_finite()
					and node.transform.is_equal_approx(first_transform),
				"%s must use its first valid animation frame as its static pose"
					% node_path
			)
		for animation_name in player.get_animation_list():
			var animation := player.get_animation(animation_name)
			for track_index in animation.get_track_count():
				var is_transform_track := String(
					animation.track_get_path(track_index)
				).ends_with(":transform")
				if animation_name == &"timeline" and is_transform_track:
					var final_key := animation.track_get_key_count(track_index) - 1
					_expect(
						final_key < 0
						or animation.track_get_key_time(track_index, final_key)
							<= 583.0 / 20.0,
						"HK_Flamer_H0 timeline transform tracks must exclude "
							+ "the corrupt unreferenced frames after 583"
					)
				for key_index in animation.track_get_key_count(track_index):
					var value: Variant = animation.track_get_key_value(
						track_index, key_index
					)
					if value is Transform3D:
						_expect(
							(value as Transform3D).is_finite(),
							"%s track %s key %d must be finite"
								% [
									animation_name,
									animation.track_get_path(track_index),
									key_index,
								]
						)
	root.free()
	return true


func _test_at_pillbox_idle_repair() -> bool:
	var path := "res://assets/raw_original_content/3DDATA/Buildings/AT_MGT_H0.xbf"
	var xbf = ModelXbfScript.load_file(path)
	_expect(xbf != null, "AT_MGT_H0 must parse")
	if xbf == null:
		return true

	var source_stationary := _xbf_animation_entry(xbf.animation_entries, "Stationary")
	var source_idle := _xbf_animation_entry(xbf.animation_entries, "Idle 0")
	var source_fire := _xbf_animation_entry(xbf.animation_entries, "Fire 0")
	_expect(
		int(source_idle.get("start_frame", -1)) == 200
		and int(source_idle.get("end_frame", -1)) == 240,
		"AT_MGT_H0 must retain its original mislabeled Idle 0 range"
	)
	_expect(
		int(source_fire.get("start_frame", -1)) == 193
		and int(source_fire.get("end_frame", -1)) == 275,
		"AT_MGT_H0 must retain its original Fire 0 range"
	)

	var scene: PackedScene = ModelBakeBuilderScript.new().build(path)
	_expect(scene != null, "AT_MGT_H0 must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(player != null, "AT_MGT_H0 must contain an AnimationPlayer")
	if player != null:
		var idle := player.get_animation(&"Idle_0")
		var stationary := player.get_animation(&"Stationary")
		var fire := player.get_animation(&"Fire_0")
		_expect(
			idle != null and stationary != null
			and is_equal_approx(idle.length, stationary.length),
			"AT_MGT Idle_0 must reuse the authored Stationary duration"
		)
		_expect(
			not _animation_has_varying_transform(idle),
			"AT_MGT Idle_0 must not retain the machine-gun recoil"
		)
		_expect(
			_animation_has_varying_transform(fire),
			"AT_MGT Fire_0 must retain the machine-gun recoil"
		)

	var baked_idle := _xbf_animation_entry(
		root.get_meta("xbf_animation_entries", []) as Array, "Idle_0"
	)
	_expect(
		int(baked_idle.get("start_frame", -1))
			== int(source_stationary.get("start_frame", -2))
		and int(baked_idle.get("end_frame", -1))
			== int(source_stationary.get("end_frame", -2)),
		"AT_MGT baked FX metadata must use the repaired stationary range"
	)
	_expect(
		int(baked_idle.get("source_start_frame", -1)) == 200
		and int(baked_idle.get("source_end_frame", -1)) == 240,
		"AT_MGT baked FX metadata must preserve the original idle range for diagnostics"
	)
	root.free()
	return true


func _animation_has_varying_transform(animation: Animation) -> bool:
	if animation == null:
		return false
	for track_index in animation.get_track_count():
		if animation.track_get_type(track_index) != Animation.TYPE_VALUE \
		or not String(animation.track_get_path(track_index)).ends_with(":transform") \
		or animation.track_get_key_count(track_index) < 2:
			continue
		var first_value: Variant = animation.track_get_key_value(track_index, 0)
		if not first_value is Transform3D:
			continue
		for key_index in range(1, animation.track_get_key_count(track_index)):
			var value: Variant = animation.track_get_key_value(track_index, key_index)
			if value is Transform3D \
			and not (value as Transform3D).is_equal_approx(first_value as Transform3D):
				return true
	return false


func _test_xbf_mech_motion_events() -> bool:
	var cases := [
		["HK_devastator_H0.xbf", [15, 25, 45, 60, 90], [0.0, 1.2, 0.0, 1.2, 0.0]],
		["AT_minotaurus_H0.xbf", [4, 8, 12, 16, 28, 32], [0.8, 2.0, 0.8, 2.0, 0.8, 2.0]],
		["AT_mongoose_H0.xbf", [3, 6, 14, 18, 27], [1.0, 3.5, 0.8, 3.5, 0.8]],
	]
	for model_case: Array in cases:
		var file_name := String(model_case[0])
		var path := "res://assets/raw_original_content/3DDATA/Units".path_join(file_name)
		var xbf = ModelXbfScript.load_file(path)
		_expect(xbf != null, "%s must parse for mech motion events" % file_name)
		if xbf == null:
			continue
		var move := _xbf_animation_entry(xbf.animation_entries, "Move")
		_expect(not move.is_empty(), "%s must expose its Move clip" % file_name)
		if move.is_empty():
			continue
		var frames: Array[int] = []
		var speeds: Array[float] = []
		for event: Dictionary in xbf.fx_events:
			var frame := int(event.get("frame", -1))
			if int(event.get("type", -1)) != 11 \
			or frame < int(move.start_frame) or frame > int(move.end_frame):
				continue
			frames.append(frame)
			speeds.append(float(event.get("value", -1.0)))
		_expect(frames == Array(model_case[1]), "%s must retain every authored gait frame" % file_name)
		var expected_speeds: Array = model_case[2]
		_expect(speeds.size() == expected_speeds.size(), "%s must retain every authored gait speed" % file_name)
		for index in mini(speeds.size(), expected_speeds.size()):
			_expect(
				is_equal_approx(speeds[index], float(expected_speeds[index])),
				"%s gait event %d must decode its 64-bit speed" % [file_name, index]
			)
	return true


func _test_xbf_fx_banks() -> bool:
	var cases := [
		[
			"AT_minotaurus_H0.xbf", 10.0,
			[170, 176, 184, 192], [171, 177, 185, 193], 4,
		],
		["AT_Trike_H0.xbf", 6.0, [106], [109], 2],
		["AT_inf_H0.xbf", 3.0, [215, 221, 229], [218, 223, 234], 7],
		["AT_Sniper_H0.XBF", 3.0, [232, 292], [233, 293], 1],
		["AT_APC_H0.xbf", 4.0, [111], [115], 3],
	]
	for model_case: Array in cases:
		var file_name := String(model_case[0])
		var path := "res://assets/raw_original_content/3DDATA/Units".path_join(file_name)
		var xbf = ModelXbfScript.load_file(path)
		_expect(xbf != null, "%s must parse for FX characterization" % file_name)
		if xbf == null:
			continue
		var shell_bank := _fx_bank_by_texture(xbf.fx_banks, "!%shel")
		_expect(not shell_bank.is_empty(), "%s must retain its !%%shel bank" % file_name)
		if shell_bank.is_empty():
			continue
		_expect(
			is_equal_approx(float(shell_bank.particle_size), float(model_case[1])),
			"%s must decode parameter 06 as source particle size" % file_name
		)
		_expect(
			int(shell_bank.texture_frame_count) == 10
			and (shell_bank.parameter_words as PackedInt32Array).size() == 16
			and (shell_bank.trailing_words as PackedInt32Array).size() == 8,
			"%s must preserve every typed and trailing FX-bank word" % file_name
		)
		_expect(xbf.fx_events_complete, "%s must expose its complete FX event table" % file_name)
		var bank_id := String(shell_bank.id)
		_expect(
			_fx_event_frames(xbf.fx_events, bank_id, "start") == model_case[2]
			and _fx_event_frames(xbf.fx_events, bank_id, "stop") == model_case[3],
			"%s must retain !%%shel start/stop frames" % file_name
		)
		var fire_entry := _xbf_animation_entry(xbf.animation_entries, "Fire 0")
		_expect(not fire_entry.is_empty(), "%s must retain Fire 0" % file_name)
		if not fire_entry.is_empty():
			_expect(
				_fx_emissions_during(
					xbf.fx_events, bank_id,
					int(fire_entry.start_frame), int(fire_entry.end_frame)
				) == int(model_case[4]),
				"%s must retain the authored Fire 0 casing count" % file_name
			)

	var mongoose_path := (
		"res://assets/raw_original_content/3DDATA/Units/AT_mongoose_H0.xbf"
	)
	var mongoose = ModelXbfScript.load_file(mongoose_path)
	_expect(
		mongoose != null and _fx_bank_by_texture(mongoose.fx_banks, "!%shel").is_empty(),
		"the Mongoose must not acquire a casing bank from its !cexp backblast"
	)

	var muzzle_cases := [
		["Muzzle1.xbf", 8.0, -0.3, [2], [5]],
		["Muzzle3.xbf", 10.0, -0.2, [3], [6]],
	]
	for muzzle_case: Array in muzzle_cases:
		var file_name := String(muzzle_case[0])
		var muzzle = ModelXbfScript.load_file(
			"res://assets/raw_original_content/3DDATA/Explosion".path_join(file_name)
		)
		_expect(muzzle != null, "%s must parse for muzzle smoke" % file_name)
		if muzzle == null:
			continue
		var smoke_bank := _fx_bank_by_texture(muzzle.fx_banks, "!%Bru")
		_expect(not smoke_bank.is_empty(), "%s must retain its !%%Bru bank" % file_name)
		if smoke_bank.is_empty():
			continue
		_expect(
			is_equal_approx(float(smoke_bank.particle_size), float(muzzle_case[1]))
			and is_equal_approx(float(smoke_bank.gravity), float(muzzle_case[2]))
			and int(smoke_bank.texture_frame_count) == 21,
			"%s must retain smoke size, signed gravity, and texture lifetime" % file_name
		)
		var smoke_bank_id := String(smoke_bank.id)
		_expect(
			_fx_event_frames(muzzle.fx_events, smoke_bank_id, "start") == muzzle_case[3]
			and _fx_event_frames(muzzle.fx_events, smoke_bank_id, "stop") == muzzle_case[4],
			"%s must retain its authored smoke emission interval" % file_name
		)

	var muzzle_builder = ModelBakeBuilderScript.new()
	var muzzle_scene: PackedScene = muzzle_builder.build(
		"res://assets/raw_original_content/3DDATA/Explosion/Muzzle1.xbf"
	)
	_expect(muzzle_scene != null, "Muzzle1 with FX metadata must build")
	if muzzle_scene != null:
		var muzzle_root := muzzle_scene.instantiate()
		var baked_smoke := _fx_bank_by_texture(
			muzzle_root.get_meta("xbf_fx_banks", []) as Array, "!%Bru"
		)
		_expect(
			not baked_smoke.is_empty()
			and is_equal_approx(float(baked_smoke.world_particle_size), 0.5)
			and is_equal_approx(float(baked_smoke.world_gravity), -7.5),
			"Muzzle1 must bake source smoke size and signed gravity into world units"
		)
		muzzle_root.free()

	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(
		"res://assets/raw_original_content/3DDATA/Units/AT_inf_H0.xbf"
	)
	_expect(scene != null, "the infantry model with FX metadata must build")
	if scene != null:
		var root := scene.instantiate()
		var baked_shell := _fx_bank_by_texture(
			root.get_meta("xbf_fx_banks", []) as Array, "!%shel"
		)
		_expect(
			not baked_shell.is_empty()
			and is_equal_approx(float(baked_shell.world_particle_size), 3.0 / 16.0),
			"the packed scene must retain source and world-space particle sizes"
		)
		var baked_events := root.get_meta("xbf_fx_events", []) as Array
		var baked_fire := _xbf_animation_entry(
			root.get_meta("xbf_animation_entries", []) as Array, "Fire_0"
		)
		_expect(
			bool(root.get_meta("xbf_fx_events_complete", false))
			and _fx_event_frames(
				baked_events, String(baked_shell.get("id", "")), "start"
			) == [215, 221, 229]
			and not (root.get_meta(
				"xbf_fx_event_raw_data", PackedByteArray()
			) as PackedByteArray).is_empty(),
			"the packed scene must retain the infantry FX event table"
		)
		_expect(
			not baked_fire.is_empty()
			and int(baked_fire.start_frame) == 207
			and int(baked_fire.end_frame) == 251,
			"the packed scene must retain source clip ranges for FX alignment"
		)
		root.free()
	return true


func _fx_bank_by_texture(banks: Array, texture: String) -> Dictionary:
	for bank_value: Variant in banks:
		var bank := bank_value as Dictionary
		if String(bank.get("texture", "")).nocasecmp_to(texture) == 0:
			return bank
	return {}


func _fx_event_frames(events: Array, bank_id: String, action: String) -> Array[int]:
	var result: Array[int] = []
	for event_value: Variant in events:
		var event := event_value as Dictionary
		if String(event.get("bank_id", "")) == bank_id \
		and String(event.get("action", "")) == action:
			result.append(int(event.get("frame", -1)))
	return result


func _xbf_animation_entry(entries: Array, name: String) -> Dictionary:
	for entry_value: Variant in entries:
		var entry := entry_value as Dictionary
		if String(entry.get("name", "")) == name:
			return entry
	return {}


func _fx_emissions_during(
		events: Array, bank_id: String, start_frame: int, end_frame: int
	) -> int:
	var active_frames := {}
	var result := 0
	for event_value: Variant in events:
		var event := event_value as Dictionary
		var frame := int(event.get("frame", -1))
		if String(event.get("bank_id", "")) != bank_id \
		or frame < start_frame or frame > end_frame:
			continue
		var attachment := String(event.get("attachment", ""))
		if String(event.get("action", "")) == "start":
			active_frames[attachment] = frame
		elif String(event.get("action", "")) == "stop" \
		and active_frames.has(attachment):
			# Start/stop are control frames. Particles occupy the intervening
			# frames; a one-frame pulse still emits one particle.
			result += maxi(frame - int(active_frames[attachment]) - 1, 1)
			active_frames.erase(attachment)
	return result


## The FX event table names the exact TGA each object switches to on each source
## frame. Explosion's ?firesphere runs !%Rbang0..9 across source frames 8..16 and
## then stops on an additive-black frame; a guessed flipbook rate instead held a
## bright fireball for the whole 50-frame transform clip, which is what made
## explosions look both slow and oversized.
func _test_authored_texture_event_frames() -> bool:
	var source := "res://assets/raw_original_content/3DDATA/Explosion/explosion.XBF"
	var builder = ModelBakeBuilderScript.new()
	builder.stationary_clip_loops = false
	var scene: PackedScene = builder.build(source)
	_expect(scene != null, "Explosion must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	_expect(
		int(root.get_meta("xbf_fx_last_event_frame", -1)) == 18,
		"the baked scene must record the last authored FX frame"
	)
	var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var timeline := player.get_animation(&"timeline") if player != null else null
	var sphere := _find_original_node_exact(root, "?firesphere")
	var mesh := _plain_mesh_descendant(sphere) if sphere != null else null
	var track := timeline.find_track(
		NodePath("%s:instance_shader_parameters/fx_frame" % String(root.get_path_to(mesh))),
		Animation.TYPE_VALUE
	) if timeline != null and mesh != null else -1
	_expect(track >= 0, "?firesphere must carry an animated-texture frame track")
	if track >= 0:
		# Source frames 0, 8, 9, ... 16 of !%Rbang0..9 at the 20 Hz update rate.
		var expected_times: Array[float] = [
			0.0, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8
		]
		var matches := timeline.track_get_key_count(track) == expected_times.size()
		for key_index in timeline.track_get_key_count(track):
			if key_index >= expected_times.size():
				break
			matches = matches \
				and is_equal_approx(
					snappedf(timeline.track_get_key_time(track, key_index), 0.001),
					expected_times[key_index]
				) \
				and int(timeline.track_get_key_value(track, key_index)) == key_index
		_expect(matches, "the sequence must step on the authored source frames at 20 Hz")
	root.free()
	return true


func _test_building_attachment_effects() -> bool:
	var source_path := (
		"res://assets/raw_original_content/3DDATA/Buildings/at_helipad_H0.XbF"
	)
	var xbf = ModelXbfScript.load_file(source_path)
	_expect(
		xbf != null and xbf.attachment_names.has("#light01"),
		"the XBF parser must classify #lightNN objects as attachment markers"
	)

	var builder = ModelBakeBuilderScript.new()
	builder.bake_attachment_bank_effects = true
	var scene: PackedScene = builder.build(source_path)
	_expect(scene != null, "AT Helipad H0 must build with attachment-bank effects")
	if scene == null:
		return true
	var root := scene.instantiate()
	var marker := _find_original_node_exact(root, "#light01")
	_expect(marker != null, "AT Helipad must retain its #light01 transform anchor")
	if marker == null:
		root.free()
		return true
	var source_mesh := _plain_mesh_descendant(marker)
	var effect := _attachment_fx_child(marker)
	_expect(
		source_mesh == null or not source_mesh.visible,
		"the authored #light01 cube must be hidden"
	)
	_expect(effect != null, "#light01 must receive its authored FX-bank visual")
	if effect != null:
		_expect(
			String(effect.get_meta("xbf_fx_texture", "")) == "!Dlight"
			and is_equal_approx(float(effect.get_meta("xbf_fx_particle_size", 0.0)), 12.0),
			"the light visual must retain the source Dlight texture and bank size"
		)
		var quad := effect.mesh as QuadMesh
		var material := quad.material as StandardMaterial3D if quad != null else null
		_expect(
			material != null
			and material.billboard_mode == BaseMaterial3D.BILLBOARD_ENABLED
			and material.blend_mode == BaseMaterial3D.BLEND_MODE_ADD,
			"the replacement light must be an additive billboard"
		)
		_expect(
			quad != null and quad.size.is_equal_approx(Vector2.ONE * 0.75)
			and is_equal_approx(
				float(effect.get_meta("xbf_fx_world_particle_size", 0.0)), 0.75
			),
			"the billboard size must be converted from XBF units into world units"
		)
		var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var timeline := player.get_animation(&"timeline") if player != null else null
		var track_path := NodePath("%s:visible" % String(root.get_path_to(effect)))
		var track := timeline.find_track(track_path, Animation.TYPE_VALUE) \
			if timeline != null else -1
		_expect(track >= 0, "the light billboard must have an authored visibility track")
		if track >= 0:
			var times: Array[float] = []
			var values: Array[bool] = []
			for key_index in timeline.track_get_key_count(track):
				times.append(timeline.track_get_key_time(track, key_index))
				values.append(bool(timeline.track_get_key_value(track, key_index)))
			_expect(
				times == [0.0, 1.0, 2.0, 3.0, 4.0]
				and values == [false, true, false, true, false],
				"#light01 must blink on the XBF start/stop frames"
			)
	root.free()

	var partial = ModelXbfScript.load_file(
		"res://assets/raw_original_content/3DDATA/Buildings/HK_Factory_H0.xbf"
	)
	var retained_partial_light := false
	if partial != null:
		for event: Dictionary in partial.fx_events:
			if String(event.get("attachment", "")) == "#light01":
				retained_partial_light = true
				break
	_expect(
		partial != null and not partial.fx_events_complete
		and retained_partial_light,
		"valid light events before an undecoded payload must remain available"
	)
	var smoke_builder = ModelBakeBuilderScript.new()
	smoke_builder.bake_attachment_bank_effects = true
	var smoke_scene: PackedScene = smoke_builder.build(
		"res://assets/raw_original_content/3DDATA/Buildings/hk_hanger_H0.xbf"
	)
	_expect(smoke_scene != null, "HK Hanger H0 must build non-light attachment effects")
	if smoke_scene != null:
		var smoke_root := smoke_scene.instantiate()
		var smoke_marker := _find_original_node_exact(smoke_root, "#smoke01")
		var smoke_fx := _attachment_fx_emitter(smoke_marker) if smoke_marker != null else null
		_expect(
			smoke_fx != null
			and not String(smoke_fx.get_meta("xbf_fx_texture", "")).is_empty(),
			"#smoke01 must receive its authored smoke bank"
		)
		var smoke_process := smoke_fx.process_material as ParticleProcessMaterial \
			if smoke_fx != null else null
		_expect(
			smoke_fx != null and smoke_fx.amount > 1 and smoke_fx.lifetime > 0.0
			and smoke_process != null and smoke_process.gravity.y > 0.0,
			"the smoke bank must emit a rising stream, not one motionless sprite"
		)
		var smoke_source := _plain_mesh_descendant(smoke_marker) \
			if smoke_marker != null else null
		_expect(
			smoke_source == null or not smoke_source.visible,
			"the authored #smoke01 marker geometry must be hidden"
		)
		smoke_root.free()

	# An idle stack is authored as intermittent puffs, so emission is gated by
	# the start/stop pair while visibility remains permanently enabled. This lets
	# every stopped puff finish even across animation loops and clip changes.
	var refinery_builder = ModelBakeBuilderScript.new()
	refinery_builder.bake_attachment_bank_effects = true
	var refinery_scene: PackedScene = refinery_builder.build(
		"res://assets/raw_original_content/3DDATA/Buildings/AT_REFINERY_H1.XBF"
	)
	_expect(refinery_scene != null, "AT Refinery H1 must build its smoke banks")
	if refinery_scene != null:
		var refinery_root := refinery_scene.instantiate()
		var stack := _find_original_node_exact(refinery_root, "#smoke02")
		var stack_fx := _attachment_fx_emitter(stack) if stack != null else null
		var refinery_player := refinery_root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var refinery_timeline := refinery_player.get_animation(&"timeline") \
			if refinery_player != null else null
		var stack_path := String(refinery_root.get_path_to(stack_fx)) \
			if stack_fx != null else ""
		var emitting_track := refinery_timeline.find_track(
			NodePath("%s:emitting" % stack_path), Animation.TYPE_VALUE
		) if refinery_timeline != null and stack_fx != null else -1
		var visible_track := refinery_timeline.find_track(
			NodePath("%s:visible" % stack_path), Animation.TYPE_VALUE
		) if refinery_timeline != null and stack_fx != null else -1
		_expect(
			emitting_track >= 0 and visible_track < 0 and stack_fx.visible,
			"#smoke02 must gate only emission and keep its particle tail visible"
		)
		if emitting_track >= 0:
			var emitting_values: Array[bool] = []
			for key_index in refinery_timeline.track_get_key_count(emitting_track):
				emitting_values.append(
					bool(refinery_timeline.track_get_key_value(emitting_track, key_index))
				)
			_expect(
				emitting_values == [false, true, false, true, false],
				"#smoke02 must puff on its authored start/stop frames"
			)
		refinery_root.free()

	var starport_source := (
		"res://assets/raw_original_content/3DDATA/Buildings/AT_StarPort_H0.XbF"
	)
	var starport_xbf = ModelXbfScript.load_file(starport_source)
	_expect(
		starport_xbf != null
		and starport_xbf.attachment_names.has("#centrelight")
		and starport_xbf.attachment_names.has("#Landinglight01")
		and starport_xbf.attachment_names.has("#runwaylight10"),
		"compound Starport light names must be classified as attachments"
	)
	var starport_builder = ModelBakeBuilderScript.new()
	starport_builder.bake_attachment_bank_effects = true
	var starport_scene: PackedScene = starport_builder.build(starport_source)
	_expect(starport_scene != null, "AT Starport H0 must build its named light effects")
	if starport_scene != null:
		var starport_root := starport_scene.instantiate()
		var centre := _find_original_node_exact(starport_root, "#centrelight")
		var runway := _find_original_node_exact(starport_root, "#runwaylight10")
		var centre_fx := _attachment_fx_child(centre) if centre != null else null
		var runway_fx := _attachment_fx_child(runway) if runway != null else null
		_expect(
			centre_fx != null
			and String(centre_fx.get_meta("xbf_fx_texture", "")) == "!%RFlash",
			"AT Starport centre/landing markers must receive their red flash bank"
		)
		_expect(
			runway_fx != null
			and String(runway_fx.get_meta("xbf_fx_texture", "")) == "=!%GFlash",
			"AT Starport runway markers must receive their green flash bank"
		)
		starport_root.free()
	return true


func _test_aircraft_smoke_trails() -> bool:
	var sources := [
		"G_Carryall_H0.XbF",
		"AT_Carryall_H0.xbf",
		"HK_Carryall_H0.xbf",
		"OR_Carryall_H0.xbf",
		"AT_Ornithopter_H0.xbf",
	]
	for source_file: String in sources:
		var builder = ModelBakeBuilderScript.new()
		builder.bake_attachment_bank_effects = true
		var scene: PackedScene = builder.build(
			"res://assets/raw_original_content/3DDATA/Units/%s" % source_file
		)
		_expect(scene != null, "%s must build its smoke trail" % source_file)
		if scene == null:
			continue
		var root := scene.instantiate()
		var marker := _find_original_node_exact(root, "#smoke01")
		var smoke_fx: GPUParticles3D = null
		if marker != null:
			for child in marker.get_children():
				var candidate := child as GPUParticles3D
				var candidate_process := candidate.process_material as ParticleProcessMaterial \
					if candidate != null else null
				if candidate_process != null and candidate_process.scale_curve != null:
					smoke_fx = candidate
					break
		var process := smoke_fx.process_material as ParticleProcessMaterial \
			if smoke_fx != null else null
		var scale_texture := process.scale_curve as CurveTexture \
			if process != null else null
		var alpha_texture := process.alpha_curve as CurveTexture \
			if process != null else null
		var quad := smoke_fx.draw_pass_1 as QuadMesh if smoke_fx != null else null
		var material := quad.material as StandardMaterial3D if quad != null else null
		var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var smoke_path := String(root.get_path_to(smoke_fx)) \
			if smoke_fx != null else ""
		var continuously_emits := player != null and smoke_fx != null
		var emitter_never_hidden := smoke_fx != null and smoke_fx.visible
		var continuous_clips: Array[StringName] = [
			&"Move", &"Fly", &"FlyToHover", &"Hover", &"HoverToFly",
		]
		if not source_file.contains("Ornithopter"):
			continuous_clips.append(&"Land")
		for clip_name in continuous_clips:
			var clip := player.get_animation(clip_name) if player != null else null
			var emission_track := clip.find_track(
				NodePath("%s:emitting" % smoke_path), Animation.TYPE_VALUE
			) if clip != null else -1
			var visibility_track := clip.find_track(
				NodePath("%s:visible" % smoke_path), Animation.TYPE_VALUE
			) if clip != null else -1
			continuously_emits = continuously_emits \
				and emission_track >= 0 and clip.track_get_key_count(emission_track) == 1 \
				and is_zero_approx(clip.track_get_key_time(emission_track, 0)) \
				and bool(clip.track_get_key_value(emission_track, 0))
			emitter_never_hidden = emitter_never_hidden and visibility_track < 0
		_expect(
			smoke_fx != null and smoke_fx.amount == 60 and smoke_fx.lifetime >= 0.8
			and not smoke_fx.local_coords,
			"%s smoke must be dense, long-lived and remain behind in world space" \
				% source_file
		)
		_expect(
			scale_texture != null and scale_texture.curve != null
			and is_equal_approx(scale_texture.curve.sample(0.0), 1.0)
			and quad != null
			and is_equal_approx(
				quad.size.x / float(smoke_fx.get_meta(
					"xbf_fx_world_particle_size", 1.0
				)), 5.56
			)
			and is_equal_approx(
				5.56 * scale_texture.curve.sample(0.85), 12.0
			),
			"%s smoke must expand substantially over its lifetime" % source_file
		)
		_expect(
			alpha_texture != null and alpha_texture.curve != null
			and is_zero_approx(alpha_texture.curve.sample(0.0))
			and is_zero_approx(alpha_texture.curve.sample(1.0))
			and material != null
			and material.blend_mode == BaseMaterial3D.BLEND_MODE_MIX,
			"%s smoke must ease in and dissolve with alpha blending" % source_file
		)
		_expect(
			continuously_emits and emitter_never_hidden,
			"%s must keep emitting in flight without hiding live smoke tails" % source_file
		)
		root.free()
	return true


func _test_static_flight_clips() -> bool:
	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(
		"res://assets/raw_original_content/3DDATA/Units/IM_DropShip_H0.XBF"
	)
	_expect(scene != null, "IMDropShip must build from its static XBF")
	if scene == null:
		return true
	var root := scene.instantiate()
	var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_expect(player != null, "static IMDropShip must receive an AnimationPlayer")
	if player != null:
		for clip_name in [&"Fly", &"Hover"]:
			var clip := player.get_animation(clip_name)
			_expect(
				clip != null and clip.length > 0.0
				and clip.loop_mode == Animation.LOOP_LINEAR,
				"IMDropShip %s must be a non-empty looping state" % clip_name
			)
		for clip_name in [&"FlyToHover", &"HoverToFly"]:
			var clip := player.get_animation(clip_name)
			_expect(
				clip != null and clip.length > 0.0
				and clip.loop_mode == Animation.LOOP_NONE,
				"IMDropShip %s must be a non-empty one-shot transition" % clip_name
			)
	root.free()
	return true


func _find_original_node_exact(node: Node, original_name: String) -> Node3D:
	if node is Node3D and String(node.get_meta("original_name", "")) == original_name:
		return node as Node3D
	for child in node.get_children():
		var found := _find_original_node_exact(child, original_name)
		if found != null:
			return found
	return null


func _test_ltmuzzle_procedural_beam_replacement() -> bool:
	var builder = ModelBakeBuilderScript.new()
	builder.bake_embedded_muzzle_flash_visibility = false
	builder.stationary_clip_loops = false
	var scene: PackedScene = builder.build(
		"res://assets/raw_original_content/3DDATA/Explosion/LTMuzzle.xbf"
	)
	_expect(scene != null, "the original LTMuzzle XBF must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	var fixed_laser := _find_original_node_exact(root, "?laser")
	var laser_meshes := fixed_laser.find_children(
		"*", "MeshInstance3D", true, false
	) if fixed_laser != null else []
	_expect(fixed_laser != null, "Ltmuzzle must retain the _laser transform node")
	var all_laser_meshes_hidden := not laser_meshes.is_empty()
	for laser_mesh in laser_meshes:
		all_laser_meshes_hidden = (
			all_laser_meshes_hidden
			and not (laser_mesh as MeshInstance3D).visible
			and laser_mesh.get_meta("source_asset_quirk", "") \
				== "procedural_laser_replacement"
		)
	_expect(
		laser_meshes.size() == 2 and all_laser_meshes_hidden,
		"the converter must hide and document every fixed-length _laser mesh"
	)
	for retained_name in ["?lasercoil", "?smring", "?midring", "?lring"]:
		var retained := _find_original_node_exact(root, retained_name)
		var retained_mesh := _plain_mesh_descendant(retained) \
			if retained != null else null
		_expect(
			retained != null and retained_mesh != null and retained_mesh.visible,
			"%s must remain visible in the authored muzzle accent" % retained_name
		)
	root.free()
	return true


func _attachment_fx_child(marker: Node) -> MeshInstance3D:
	for child in marker.get_children():
		if child is MeshInstance3D and child.has_meta("xbf_fx_bank_id"):
			return child as MeshInstance3D
	return null


## Motion banks (smoke, fire, exhaust) bake as the particle stream they are in
## the source data instead of a single billboard, so they are not MeshInstance3D.
func _attachment_fx_emitter(marker: Node) -> GPUParticles3D:
	for child in marker.get_children():
		if child is GPUParticles3D and child.has_meta("xbf_fx_bank_id"):
			return child as GPUParticles3D
	return null


func _plain_mesh_descendant(node: Node) -> MeshInstance3D:
	for child in node.get_children():
		if child is MeshInstance3D and not child.has_meta("xbf_fx_bank_id"):
			return child as MeshInstance3D
		var found := _plain_mesh_descendant(child)
		if found != null:
			return found
	return null


func _test_building_transition_clips() -> bool:
	var builder = BuildingBakeBuilderScript.new()
	var scene: PackedScene = builder.build(&"ATConYard")
	_expect(scene != null, "ATConYard wrapper must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	var player := root.get_node_or_null("StatePlayer") as AnimationPlayer
	_expect(player != null, "ATConYard wrapper must expose its state player")
	if player != null:
		var names := Array(player.get_animation_list())
		_expect(names.has(&"construct"), "HC Construct must be exported as construct")
		_expect(names.has(&"deconstruct"), "HC Deconstruct must be exported as deconstruct")
		_expect(names.has(&"sell"), "HC Sell must be exported as sell")
		_expect(not names.has(&"build"), "the obsolete build transition name must not be exported")
		var source_player := root.get_node_or_null("States/Build/AnimationPlayer") as AnimationPlayer
		_expect(source_player != null, "the HC source player must remain available")
		if source_player != null:
			for action_case in [
				[&"construct", &"Construct"],
				[&"deconstruct", &"Deconstruct"],
				[&"sell", &"Sell"],
			]:
				var exported := player.get_animation(action_case[0])
				var authored := source_player.get_animation(action_case[1])
				_expect(
					exported != null and authored != null
						and is_equal_approx(exported.length, authored.length),
					"%s must retain the authored %s duration" % action_case
				)
	root.free()
	return true


func _test_mirrored_object_animation_handedness() -> bool:
	var path := "res://assets/raw_original_content/3DDATA/Buildings/AT_Conyard_HC.XBF"
	var xbf = ModelXbfScript.load_file(path)
	_expect(xbf != null, "AT ConYard construction model must parse")
	if xbf == null:
		return true

	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(path)
	_expect(scene != null, "AT ConYard construction model must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	var player := root.get_node("AnimationPlayer") as AnimationPlayer
	var construct := player.get_animation(&"Construct") if player != null else null
	_expect(construct != null, "AT ConYard must expose its Construct clip")
	if construct == null:
		root.free()
		return true
	for track_index in construct.get_track_count():
		if construct.track_get_type(track_index) != Animation.TYPE_VALUE:
			continue
		var track_path := String(construct.track_get_path(track_index))
		if not track_path.ends_with(":transform"):
			continue
		var rotation_safe := true
		for key_index in construct.track_get_key_count(track_index):
			var key_transform := construct.track_get_key_value(track_index, key_index) as Transform3D
			if key_transform.basis.determinant() <= 0.0:
				rotation_safe = false
				break
		_expect(rotation_safe, "%s must contain only rotation-safe Transform3D keys" % track_path)

	for object_name in [&"clonetread01", &"clonetread02"]:
		var object := _find_xbf_object(xbf.objects, String(object_name))
		_expect(not object.is_empty(), "%s must exist in the source model" % object_name)
		if object.is_empty():
			continue
		var track := _animation_track_containing(construct, String(object_name))
		_expect(track >= 0, "%s must retain its transform track" % object_name)
		if track < 0:
			continue

		var source_center := _points_bounds(object.positions as PackedVector3Array).get_center()
		var converted_center := Vector3(source_center.x, source_center.y, -source_center.z)
		var track_node_path := String(construct.track_get_path(track)).trim_suffix(":transform")
		var mirrored_content := root.get_node_or_null("%s/MirroredContent" % track_node_path) as Node3D
		_expect(mirrored_content != null, "%s must factor its reflection into static content" % object_name)
		if mirrored_content == null:
			continue
		var source_frames: Dictionary = object.object_animation.frames
		for frame_id in [0, 77, 92, 191]:
			var source_transform := _source_to_godot_transform(source_frames[frame_id])
			var converted_transform: Transform3D = construct.track_get_key_value(track, frame_id)
			_expect(
				converted_transform.basis.determinant() > 0.0,
				"%s frame %d animation key must be rotation-safe" % [object_name, frame_id]
			)
			var effective_transform := converted_transform * mirrored_content.transform
			_expect(
				effective_transform.basis.determinant() < 0.0,
				"%s frame %d effective transform must remain mirrored" % [object_name, frame_id]
			)
			_expect(
				(effective_transform * converted_center).distance_to(
					source_transform * converted_center
				) < 0.001,
				"%s frame %d must preserve its authored Z placement" % [object_name, frame_id]
			)

	root.free()
	return true


## clonetread01/02 are authored inside-out for their always-mirrored placement
## and must be re-oriented at bake; girderbox06 is equally mirrored but
## authored outward and must keep its authored orientation.
func _test_mirrored_mesh_orientation() -> bool:
	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build("res://assets/raw_original_content/3DDATA/Buildings/AT_Conyard_HC.XBF")
	_expect(scene != null, "AT ConYard construction model must build")
	if scene == null:
		return true
	var root := scene.instantiate()
	for object_name in ["clonetread01", "clonetread02", "girderbox06"]:
		var node := root.find_child(object_name, true, false) as Node3D
		_expect(node != null, "%s must exist in the converted scene" % object_name)
		if node == null:
			continue
		var content: Node = node.get_node_or_null("MirroredContent")
		if content == null:
			content = node
		var checked := 0
		# Flat split-off components are direction-neutral around their own
		# centroid, so outwardness is judged once per object as a magnitude-
		# weighted sum instead of per triangle.
		var outward_sum := 0.0
		for child in content.get_children():
			if child is MeshInstance3D:
				var mesh := (child as MeshInstance3D).mesh as ArrayMesh
				if mesh != null:
					outward_sum += _expect_outward_mesh(mesh, object_name)
					checked += 1
		_expect(checked > 0, "%s must carry mesh geometry" % object_name)
		_expect(outward_sum > 0.0, "%s normals must point outward (weighted sum %f)" % [object_name, outward_sum])
	root.free()
	return true


func _expect_outward_mesh(mesh: ArrayMesh, object_name: String) -> float:
	var centroid := Vector3.ZERO
	var vertex_count := 0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
			centroid += vertex
			vertex_count += 1
	if vertex_count == 0:
		return 0.0
	centroid /= vertex_count
	var outward_sum := 0.0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var triangle_count := indices.size() / 3
		var winding_front := 0
		for i in range(0, indices.size(), 3):
			var v0 := vertices[indices[i]]
			var v1 := vertices[indices[i + 1]]
			var v2 := vertices[indices[i + 2]]
			var normal_sum := normals[indices[i]] + normals[indices[i + 1]] + normals[indices[i + 2]]
			outward_sum += ((v0 + v1 + v2) / 3.0 - centroid).dot(normal_sum)
			# Godot treats clockwise-wound faces as front, so a front face's
			# right-handed winding normal points against the shading normal.
			if (v1 - v0).cross(v2 - v0).dot(normal_sum) < 0.0:
				winding_front += 1
		_expect(
			winding_front == triangle_count,
			"%s surface %d winding must face outward (%d/%d)" % [object_name, surface_index, winding_front, triangle_count]
		)
	return outward_sum


func _animation_track_containing(animation: Animation, object_name: String) -> int:
	for track_index in animation.get_track_count():
		var path := String(animation.track_get_path(track_index))
		if path.contains(object_name) and path.ends_with(":transform"):
			return track_index
	return -1


func _source_to_godot_transform(source: Transform3D) -> Transform3D:
	var transform := source
	transform.basis.x = Vector3(source.basis.x.x, source.basis.x.y, -source.basis.x.z)
	transform.basis.y = Vector3(source.basis.y.x, source.basis.y.y, -source.basis.y.z)
	transform.basis.z = Vector3(-source.basis.z.x, -source.basis.z.y, source.basis.z.z)
	transform.origin = Vector3(source.origin.x, source.origin.y, -source.origin.z)
	return transform


func _test_at_refinery_partitioning() -> bool:
	var path := "res://assets/raw_original_content/3DDATA/Buildings/at_refinery_h0.xbf"
	var xbf = ModelXbfScript.load_file(path)
	_expect(xbf != null, "AT Refinery H0 must parse")
	if xbf == null:
		return true
	var target_ids: Array[int] = []
	for entry: Dictionary in xbf.animation_entries:
		target_ids.append(int(entry.get("target_object_id", 0)))
	_expect(target_ids == [0, 3, 4], "AT Refinery clips must retain their Stationary/left-pad/right-pad targets")

	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(path)
	_expect(scene != null, "AT Refinery H0 must build")
	if scene == null:
		return true
	var root: Node = scene.instantiate()
	var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(player != null, "AT Refinery must contain an AnimationPlayer")
	if player != null:
		var stationary_paths := _transform_track_paths(player.get_animation(&"Stationary"))
		var left_pad_paths := _transform_track_paths(player.get_animation(&"Refinery_Pad_1"))
		var right_pad_paths := _transform_track_paths(player.get_animation(&"Refinery_Pad_2"))
		_expect(stationary_paths.all(func(value: String) -> bool: return not value.contains("SmallPad")), "Stationary must not move either SmallPad")
		_expect(left_pad_paths.size() == 1 and left_pad_paths[0].contains("_3SmallPad01"), "Refinery Pad 1 must move only the left SmallPad")
		_expect(right_pad_paths.size() == 1 and right_pad_paths[0].contains("_4SmallPad02"), "Refinery Pad 2 must move only the right SmallPad")

	var shell := root.find_child("at_refinery", true, false)
	var shell_meshes: Array[MeshInstance3D] = []
	if shell != null:
		for child in shell.get_children():
			if child is MeshInstance3D:
				shell_meshes.append(child as MeshInstance3D)
	_expect(shell_meshes.size() > 1, "the disconnected idle shell must not remain one giant MeshInstance")
	var triangle_count := 0
	var maximum_surfaces := 0
	for mesh_instance in shell_meshes:
		maximum_surfaces = maxi(maximum_surfaces, mesh_instance.mesh.get_surface_count())
		for surface_index in mesh_instance.mesh.get_surface_count():
			var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
			triangle_count += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	_expect(triangle_count == 373, "splitting the idle shell must preserve all 373 authored triangles")
	_expect(maximum_surfaces < 16, "build/material groups must no longer collapse into one 16-surface idle mesh")
	var broken_mesh_03 := shell.get_node_or_null("Mesh_03") as MeshInstance3D if shell != null else null
	var broken_mesh_10 := shell.get_node_or_null("Mesh_10") as MeshInstance3D if shell != null else null
	_expect(broken_mesh_03 != null and not broken_mesh_03.visible, "the shipped broken AT Refinery Mesh_03 must stay hidden")
	_expect(broken_mesh_10 != null and not broken_mesh_10.visible, "the shipped broken AT Refinery Mesh_10 must stay hidden")
	_expect(
		broken_mesh_03 != null and broken_mesh_03.get_meta("source_asset_quirk", "") == "broken_geometry",
		"hidden Mesh_03 must document why it is suppressed in the converted scene"
	)
	_expect(
		broken_mesh_10 != null and broken_mesh_10.get_meta("source_asset_quirk", "") == "broken_geometry",
		"hidden Mesh_10 must document why it is suppressed in the converted scene"
	)
	root.free()
	return true


func _transform_track_paths(animation: Animation) -> Array[String]:
	var paths: Array[String] = []
	if animation == null:
		return paths
	for track_index in animation.get_track_count():
		if animation.track_get_type(track_index) != Animation.TYPE_VALUE:
			continue
		var path := String(animation.track_get_path(track_index))
		if path.ends_with(":transform"):
			paths.append(path)
	return paths


func _test_muzzle_flash_clip_visibility() -> bool:
	var cases := [
		["res://assets/raw_original_content/3DDATA/Units/AT_Kindjal_H0.xbf", 2, 1],
		["res://assets/raw_original_content/3DDATA/Units/AT_Sniper_H0.XBF", 1, 1],
		["res://assets/raw_original_content/3DDATA/Units/HK_Trooper_H0.xbf", 1, 1],
	]
	for model_case: Array in cases:
		var builder = ModelBakeBuilderScript.new()
		var scene: PackedScene = builder.build(String(model_case[0]))
		_expect(scene != null, "%s must build" % String(model_case[0]).get_file())
		if scene == null:
			continue
		var root: Node = scene.instantiate()
		var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_expect(player != null, "%s must contain an AnimationPlayer" % String(model_case[0]).get_file())
		if player != null:
			var stationary_values := _muzzle_flash_visibility_values(player.get_animation(&"Stationary"))
			var fire_values := _muzzle_flash_visibility_values(player.get_animation(&"Fire_0"))
			_expect(stationary_values.size() == int(model_case[1]), "%s must track every muzzle flash in Stationary" % String(model_case[0]).get_file())
			_expect(stationary_values.all(func(value: bool) -> bool: return not value), "%s must hide muzzle flashes in Stationary" % String(model_case[0]).get_file())
			_expect(fire_values.count(true) == int(model_case[2]), "%s Fire_0 must show only its active muzzle flash geometry" % String(model_case[0]).get_file())
		root.free()
	return true


## Regression test for a reported bug: the "%" marker means "animated frame
## sequence" in the source data, but it is also carried by lone muzzle-flash
## cutouts ("!%flash01.tga", "!%FireFlash0.tga"). Those fell through
## _is_scrolling_texture() and got the panning shader, so the flash texture
## visibly crawled across the geometry while the gun fired -- worst on
## HKGunTurret, whose Fire clip scales the flash up ~60x. The unmarked flash
## cutouts in the same role ("!5flash03.tga") already bake as plain additive
## materials, which is what these must match. Beams and coils that legitimately
## pan ("!%lascoil.tga", "!%LTRing.tga") must keep scrolling.
func _test_muzzle_flash_textures_do_not_scroll() -> bool:
	var static_cases := [
		"res://assets/raw_original_content/3DDATA/Buildings/HK_GunTurret_H0.XBF",
		"res://assets/raw_original_content/3DDATA/Units/AT_Kindjal_H0.xbf",
		"res://assets/raw_original_content/3DDATA/Units/OR_Mortar_H0.xbf",
	]
	for source_path: String in static_cases:
		var builder = ModelBakeBuilderScript.new()
		var scene: PackedScene = builder.build(source_path)
		_expect(scene != null, "%s must build" % source_path.get_file())
		if scene == null:
			continue
		var root: Node = scene.instantiate()
		var flash_surfaces := 0
		for scrolling in _scrolling_surface_textures(root):
			if String(scrolling).to_lower().contains("flash"):
				flash_surfaces += 1
		_expect(
			_surface_textures_containing(root, "flash") > 0,
			"%s must carry muzzle flash surfaces at all" % source_path.get_file()
		)
		_expect(
			flash_surfaces == 0,
			"%s must bake its muzzle flash cutouts as static, not scrolling"
				% source_path.get_file()
		)
		root.free()

	var beam_builder = ModelBakeBuilderScript.new()
	var beam_scene: PackedScene = beam_builder.build(
		"res://assets/raw_original_content/3DDATA/Explosion/LTMuzzle.xbf"
	)
	_expect(beam_scene != null, "LTMuzzle.xbf must build")
	if beam_scene != null:
		var beam_root: Node = beam_scene.instantiate()
		_expect(
			not _scrolling_surface_textures(beam_root).is_empty(),
			"LTMuzzle's laser coil and rings must keep their panning shader"
		)
		beam_root.free()
	return true


## Regression test for a reported bug: the ORPopUpTurret's muzzle flash read as
## a solid blob rather than a flash. Its gplasglow model references a bare
## "!Gbang1.tga" -- no "%" sequence marker -- while its own type-6 events step
## that object through "!Gbang0..9", one per source frame. Only the marker was
## ever consulted, so the ten-frame blast baked as a single frozen mid-blast
## still. The marker-free sequence must be picked up from those events instead.
## The unmarked leech-infestation overlay is the deliberate counter-case: it is
## a lit hull surface, not an additive blast sheet, and must stay as it was.
func _test_event_driven_texture_flipbooks() -> bool:
	var flipbook_cases := [
		["res://assets/raw_original_content/3DDATA/Explosion/gplasglow.XBF", 10],
		["res://assets/raw_original_content/3DDATA/Explosion/devmuzzle.XBF", 10],
		["res://assets/raw_original_content/3DDATA/bullets/shellhit.xbf", 10],
	]
	for model_case: Array in flipbook_cases:
		var source_path := String(model_case[0])
		var builder = ModelBakeBuilderScript.new()
		var scene: PackedScene = builder.build(source_path)
		_expect(scene != null, "%s must build" % source_path.get_file())
		if scene == null:
			continue
		var root: Node = scene.instantiate()
		_expect(
			_atlas_frame_counts(root) == [int(model_case[1])],
			"%s must bake one %d-frame texture atlas, got %s"
				% [source_path.get_file(), int(model_case[1]), _atlas_frame_counts(root)]
		)
		var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var stepped: Array = []
		if player != null and player.has_animation(&"Stationary"):
			stepped = _frame_track_values(player.get_animation(&"Stationary"))
		_expect(
			stepped == range(int(model_case[1])),
			"%s Stationary must step every atlas frame in order, got %s"
				% [source_path.get_file(), stepped]
		)
		root.free()

	var leech_builder = ModelBakeBuilderScript.new()
	var leech_scene: PackedScene = leech_builder.build(
		"res://assets/raw_original_content/3DDATA/Units/AT_Trike_H0.xbf"
	)
	_expect(leech_scene != null, "AT_Trike_H0.xbf must build")
	if leech_scene != null:
		var leech_root: Node = leech_scene.instantiate()
		_expect(
			_atlas_frame_counts(leech_root).is_empty(),
			"the unmarked leech overlay must stay off the frame atlas shader"
		)
		leech_root.free()
	return true


func _atlas_frame_counts(root: Node) -> Array:
	var result: Array = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh as ArrayMesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var material := mesh.surface_get_material(surface) as ShaderMaterial
			if material == null:
				continue
			var frame_count: Variant = material.get_shader_parameter("frame_count")
			if frame_count != null:
				result.append(int(frame_count))
	return result


func _frame_track_values(animation: Animation) -> Array:
	var result: Array = []
	for track in animation.get_track_count():
		if not String(animation.track_get_path(track)).ends_with("fx_frame"):
			continue
		for key in animation.track_get_key_count(track):
			result.append(int(animation.track_get_key_value(track, key)))
	return result


## Regression test for a reported bug: HK_flame's fuel drum ("cyl01") stood
## still, while the reference game pans its texture to sell a spinning drum,
## and the vehicle track belts never moved at all. Neither texture carries the
## "%" marker, so both fell through to a plain StandardMaterial3D. The drum
## pans on the always-on fx_time channel; the belts pan on the movement-driven
## one, so they stop when the vehicle does. A building carrying the same track
## texture has no such driver and must keep its belts static.
func _test_unmarked_vehicle_scrolling_textures() -> bool:
	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(
		"res://assets/raw_original_content/3DDATA/Units/HK_flame_H0.xbf"
	)
	_expect(scene != null, "HK_flame_H0.xbf must build")
	if scene == null:
		return true
	var root: Node = scene.instantiate()

	var scrolling := _scrolling_surface_textures(root)
	var move_scrolling := _move_scrolling_surface_textures(root)
	_expect(
		_textures_containing(scrolling, "flametank") > 0,
		"HK_flame's fuel drum must pan continuously"
	)
	_expect(
		_textures_containing(scrolling, "patch_high") == 0
			and _textures_containing(scrolling, "spotlight") == 0,
		"HK_flame's hull and spotlight must stay static"
	)
	_expect(
		_surface_textures_containing(root, "tracks") > 0,
		"HK_flame must carry track surfaces at all"
	)
	_expect(
		_textures_containing(move_scrolling, "tracks")
			== _surface_textures_containing(root, "tracks"),
		"every HK_flame track belt must pan on the movement-driven channel"
	)
	_expect(
		_textures_containing(scrolling, "tracks") == 0,
		"HK_flame's track belts must not pan on the always-on channel"
	)
	root.free()

	var yard_builder = ModelBakeBuilderScript.new()
	var yard_scene: PackedScene = yard_builder.build(
		"res://assets/raw_original_content/3DDATA/Buildings/AT_conyard_H0.XbF"
	)
	_expect(yard_scene != null, "AT_conyard_H0.XbF must build")
	if yard_scene != null:
		var yard_root: Node = yard_scene.instantiate()
		_expect(
			_textures_containing(_scrolling_surface_textures(yard_root), "buzzsawtread") > 0,
			"the construction yard's tread belt must keep panning continuously"
		)
		_expect(
			_textures_containing(_scrolling_surface_textures(yard_root), "tracks") == 0,
			"the construction yard's track texture must stay off the always-on channel"
		)
		yard_root.free()
	return true


## ATSonicTank's beam01 uses unmarked !bhalo0.TGA as a continuously panning
## sonic beam while visibility remains controlled by authored clips.
func _test_at_sonic_tank_beam_texture_scroll() -> bool:
	var builder = ModelBakeBuilderScript.new()
	var scene: PackedScene = builder.build(
		"res://assets/raw_original_content/3DDATA/Units/AT_SonicTank_H0.xbf"
	)
	_expect(scene != null, "AT_SonicTank_H0.xbf must build")
	if scene == null:
		return true
	var root: Node = scene.instantiate()
	var beam_root := root.find_child("beam01", true, false) as Node3D
	var beam := beam_root.get_child(0) as MeshInstance3D if beam_root != null else null
	_expect(beam != null, "AT_SonicTank beam01 must retain its mesh")
	_expect(
		beam != null and beam.has_meta("scroll_fx"),
		"ATSonikTank beam01 must drive %s continuously" % (
			beam.mesh.surface_get_name(0) if beam != null else "its texture"
		)
	)
	root.free()
	return true


func _textures_containing(textures: Array[String], needle: String) -> int:
	var count := 0
	for texture_name in textures:
		if texture_name.to_lower().contains(needle):
			count += 1
	return count


func _move_scrolling_surface_textures(root: Node) -> Array[String]:
	var result: Array[String] = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if not mesh_instance.has_meta("scroll_fx_move"):
			continue
		var mesh := mesh_instance.mesh as ArrayMesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			result.append(mesh.surface_get_name(surface))
	return result


func _scrolling_surface_textures(root: Node) -> Array[String]:
	var result: Array[String] = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if not mesh_instance.has_meta("scroll_fx"):
			continue
		var mesh := mesh_instance.mesh as ArrayMesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			result.append(mesh.surface_get_name(surface))
	return result


func _surface_textures_containing(root: Node, needle: String) -> int:
	var count := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh as ArrayMesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			if mesh.surface_get_name(surface).to_lower().contains(needle):
				count += 1
	return count


## Guards converters/model_bake_builder.gd's CLIP_NAME_OVERRIDES against a
## future re-convert: the deployed-mode fire clip is authored as "Fire 1" on
## every combat-deployable unit (weapon index 1 = the deployed turret), and
## must bake as the single canonical Deployed_Fire instead.
func _test_combat_deploy_clip_rename() -> bool:
	var cases := [
		[
			"res://assets/raw_original_content/3DDATA/Units/AT_Kindjal_H0.xbf",
			true,
			"Deployed Fire",
		],
		[
			"res://assets/raw_original_content/3DDATA/Units/OR_Mortar_H0.xbf",
			false,
			"Fire 1",
		],
		[
			"res://assets/raw_original_content/3DDATA/Units/OR_Kobra_H0.XBF",
			false,
			"Fire 1",
		],
	]
	for model_case: Array in cases:
		var source_path := String(model_case[0])
		var builder = ModelBakeBuilderScript.new()
		var scene: PackedScene = builder.build(source_path)
		_expect(scene != null, "%s must build" % source_path.get_file())
		if scene == null:
			continue
		var root: Node = scene.instantiate()
		var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_expect(player != null, "%s must contain an AnimationPlayer" % source_path.get_file())
		if player != null:
			var clips := player.get_animation_list()
			var fx_entries := root.get_meta(
				"xbf_animation_entries", []
			) as Array
			var deployed_fx_entry := _xbf_animation_entry(
				fx_entries, "Deployed_Fire"
			)
			_expect(
				&"Deploy_Gun" in clips,
				"%s must expose Deploy_Gun" % source_path.get_file()
			)
			_expect(
				&"Deploy_Gun_Hold" in clips,
				"%s must expose Deploy_Gun_Hold" % source_path.get_file()
			)
			_expect(
				&"Undeploy_Gun" in clips,
				"%s must expose Undeploy_Gun" % source_path.get_file()
			)
			_expect(
				&"Deployed_Fire" in clips,
				"%s must expose the renamed Deployed_Fire clip" % source_path.get_file()
			)
			_expect(
				not (&"Fire_1" in clips),
				"%s must not still expose Fire_1 after the deployed-fire rename" % source_path.get_file()
			)
			_expect(
				not deployed_fx_entry.is_empty()
				and String(deployed_fx_entry.get("source_name", ""))
					== String(model_case[2]),
				"%s FX ranges must follow the Fire_1 to Deployed_Fire repair"
					% source_path.get_file()
			)
			_expect(
				_xbf_animation_entry(fx_entries, "Fire_1").is_empty(),
				"%s must not retain the broken Fire_1 name in baked FX metadata"
					% source_path.get_file()
			)
			var all_fx_names_are_baked := true
			for entry_value: Variant in fx_entries:
				var entry := entry_value as Dictionary
				if StringName(String(entry.get("name", ""))) not in clips:
					all_fx_names_are_baked = false
					break
			_expect(
				all_fx_names_are_baked,
				"%s every FX clip range must name a real baked animation"
					% source_path.get_file()
			)
			_expect(
				&"Fire_0" in clips,
				"%s must keep its travel-mode Fire_0" % source_path.get_file()
			)
			if bool(model_case[1]):
				_expect(
					&"Deployed_Idle_0" in clips,
					"%s must expose its authored Deployed_Idle_0" % source_path.get_file()
				)
		root.free()
	return true


func _muzzle_flash_visibility_values(animation: Animation) -> Array[bool]:
	var result: Array[bool] = []
	if animation == null:
		return result
	for track_index in animation.get_track_count():
		var track_path := String(animation.track_get_path(track_index))
		var lower_path := track_path.to_lower()
		if (lower_path.contains("bigflash") or lower_path.contains("flah_")) \
		and track_path.ends_with(":visible"):
			result.append(bool(animation.track_get_key_value(track_index, 0)))
	return result


func _config(
		entity_type: StringName,
		house: StringName = &"",
		primary: Array = [],
		secondary: Array = [],
		upgraded_primary_required := false,
		tech_level := 0
):
	var config = BuildingDefinitionScript.new() if entity_type == &"building" else UnitDefinitionScript.new()
	config.house_id = house
	config.upgraded_primary_required = upgraded_primary_required
	config.tech_level = tech_level
	var typed_primary: Array[StringName] = []
	var typed_secondary: Array[StringName] = []
	typed_primary.assign(primary)
	typed_secondary.assign(secondary)
	if entity_type == &"building":
		config.primary_building_ids = typed_primary
		config.secondary_building_ids = typed_secondary
	else:
		config.primary_building_ids = typed_primary
		config.secondary_building_ids = typed_secondary
	return config
