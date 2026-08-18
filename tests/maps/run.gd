extends SceneTree

const BakedMapDataScript := preload("res://scripts/world/map/baked_map_data.gd")
const MapLoaderScript := preload("res://scripts/world/map/map_loader.gd")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")
const MapSpiceLayerScript := preload("res://scripts/world/map/map_spice_layer.gd")
const MapSpiceHazardScript := preload("res://scripts/world/map/map_spice_hazard.gd")
const SpiceMoundDefinitionScript := preload("res://scripts/world/map/spice_mound_definition.gd")
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")
const SpiceMoundScene := preload("res://scenes/world/spice_mound.tscn")
const TextureImageUtilsScript := preload("res://converters/texture_image_utils.gd")


class HazardUnit:
	extends Node3D
	var unit_definition: Resource
	var damage_taken := 0.0

	func take_damage(amount: float, _death_cause: StringName = &"") -> void:
		damage_taken += amount


var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 1000
var _temporary_paths: Array[String] = []


func _initialize() -> void:
	_run_case("magenta texture key becomes alpha cutout", _test_magenta_texture_key)
	_run_case("baked grid load and coordinate contract", _test_baked_grid_load_and_coordinates)
	_run_case("cell debug contract", _test_cell_debug_contract)
	_run_case("dynamic spice harvesting and replenishment", _test_dynamic_spice_harvesting_and_replenishment)
	_run_case("spice mound source-grid mapping", _test_spice_mound_source_grid_mapping)
	_run_case("spice mound runtime entity contract", _test_spice_mound_runtime_entity_contract)
	_run_case("spice mound maturity ticks convert 60 Hz rule ticks to 25 Hz sim ticks", _test_spice_mound_maturity_tick_conversion)
	_run_case("spice mound staged passable-sand spread", _test_spice_mound_staged_passable_sand_spread)
	_run_case("spice hazard preserves its total damage across the new pulse cadence", _test_spice_hazard_preserves_total_damage)
	_run_case("spice spread releases a ring on the interval tick, not before", _test_spice_spread_releases_a_ring_on_the_interval_tick)
	_run_case("malformed baked data is atomic", _test_malformed_baked_data_is_atomic)
	_run_case("grid reload semantics", _test_grid_reload_semantics)
	_run_case("map loader failed replacement is atomic", _test_map_loader_failed_replacement_is_atomic)
	_run_case("map loader initial failure stays empty", _test_map_loader_initial_failure_stays_empty)
	_run_case("map loader rejects wrong resource types atomically", _test_map_loader_wrong_resource_type_is_atomic)
	_cleanup_temporary_files()

	if _failures > 0:
		printerr("Map runtime tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Map runtime tests: %d assertions passed" % _assertions)
	quit(0)


func _test_magenta_texture_key(token: int) -> int:
	var image := Image.create(3, 1, false, Image.FORMAT_RGB8)
	image.set_pixel(0, 0, Color(0.8, 0.2, 0.1))
	image.set_pixel(1, 0, Color(1.0, 0.0, 1.0))
	image.set_pixel(2, 0, Color(0.9, 0.0, 1.0))
	_expect(TextureImageUtilsScript.apply_magenta_to_alpha(image), "a magenta key pixel must be detected")
	_expect(image.get_format() == Image.FORMAT_RGBA8, "key conversion must produce an alpha-capable image")
	_expect(is_zero_approx(image.get_pixel(1, 0).a), "the magenta key pixel must become transparent")
	_expect(image.get_pixel(1, 0).r < 0.9, "transparent RGB must bleed from an opaque neighbor instead of retaining magenta")
	_expect(is_equal_approx(image.get_pixel(2, 0).a, 1.0), "colors outside the key threshold must remain opaque")

	var opaque := Image.create(1, 1, false, Image.FORMAT_RGB8)
	opaque.set_pixel(0, 0, Color(0.2, 0.3, 0.4))
	_expect(not TextureImageUtilsScript.apply_magenta_to_alpha(opaque), "an ordinary opaque texture must not request alpha cutout")
	return token


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	var completed: Variant = test.call(token)
	if completed != token:
		_failures += 1
		printerr("FAIL: %s: case did not return its completion token" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_baked_grid_load_and_coordinates(token: int) -> int:
	var data = _valid_data("grid-contract", AABB(Vector3(10.0, 7.0, 20.0), Vector3(256.0, 3.0, 512.0)))
	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "consistent baked data must load")
	_expect(grid.is_loaded(), "a successful baked load must mark the grid loaded")
	_expect(grid.map_dir == "grid-contract" and grid.world_bounds == data.nav_world_bounds, "loaded grid must expose baked source and bounds")
	_expect(grid.world_to_grid(Vector3(10.0, 0.0, 20.0)) == Vector2i.ZERO, "minimum world edge must map to the first cell")
	_expect(grid.world_to_grid(Vector3(266.0, 0.0, 532.0)) == Vector2i(255, 255), "maximum world edge must map to the last cell")
	_expect(grid.world_to_grid(Vector3(-10.0, 0.0, 1000.0)) == Vector2i(0, 255), "world conversion must clamp outside bounds")
	_expect(grid.grid_to_world(Vector2i.ZERO) == Vector3(10.5, 7.0, 21.0), "centered grid conversion must return the cell center")
	_expect(grid.grid_to_world(Vector2i(255, 255), false) == Vector3(265.0, 7.0, 530.0), "uncentered last cell must return its minimum corner")
	return token


func _test_cell_debug_contract(token: int) -> int:
	var data = _valid_data("cell-debug")
	var cell := Vector2i(3, 4)
	var index := cell.y * MapNavigationGridScript.NAV_SIZE + cell.x
	data.nav_cpf_values[index] = 77
	data.nav_terrain_type[index] = MapNavigationGridScript.TERRAIN_ROCK
	data.nav_source_tile_x[index] = 12
	data.nav_source_tile_y[index] = 34
	data.nav_spice_value[index] = 9
	data.nav_pass_mask[index] = MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR
	data.nav_movement_cost[index] = 1.0
	data.nav_buildable[index] = 1
	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "debug fixture must load")
	var info: Dictionary = grid.cell_debug(cell)
	_expect(info.get("valid") == true and info.get("grid") == cell and info.get("world_center") == grid.grid_to_world(cell), "valid debug data must identify the requested cell and center")
	_expect(info.get("source_tile") == Vector2i(12, 34) and info.get("cpf_raw") == 77, "debug data must expose baked source tile and CPF value")
	_expect(info.get("terrain_type") == MapNavigationGridScript.TERRAIN_ROCK and info.get("terrain_name") == "rock", "debug data must expose terrain id and name")
	_expect(info.get("spice") == 9 and info.get("pass_mask") == MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR, "debug data must expose spice and passability")
	_expect(is_equal_approx(info.get("movement_cost"), 1.0) and info.get("buildable") == true, "debug data must expose movement cost and buildability")
	var outside: Dictionary = grid.cell_debug(Vector2i(-1, 256))
	_expect(outside == {"valid": false, "grid": Vector2i(-1, 256)}, "out-of-bounds debug data must contain only invalid grid identity")
	return token


func _test_dynamic_spice_harvesting_and_replenishment(token: int) -> int:
	var data = _valid_data("dynamic-spice")
	var cell := Vector2i(12, 34)
	data.nav_spice_value[cell.y * MapNavigationGridScript.NAV_SIZE + cell.x] = 200
	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "dynamic spice fixture must load its navigation grid")
	var layer = MapSpiceLayerScript.new()
	_expect(layer.load_baked(data, grid), "dynamic spice layer must load from baked initial state")
	_expect(layer.spice_at(cell) == 200, "the runtime layer must preserve initial baked spice density")
	_expect(layer.nearest_spice_cell(Vector2i.ZERO) == cell, "the runtime layer must locate the nearest available spice cell")
	_expect(layer.nearest_spice_cell(Vector2i.ZERO, 1, 8) == Vector2i(-1, -1), "bounded spice lookup must reject fields outside its radius")
	_expect(layer.nearest_spice_cell(cell + Vector2i(3, 0), 1, 3) == cell, "bounded spice lookup must include a field on its radius edge")
	var farther_cell := cell + Vector2i(4, 0)
	layer.set_spice(farther_cell, 100)
	var visible_filter := func(candidate: Vector2i) -> bool: return candidate != cell
	_expect(layer.nearest_spice_cell(Vector2i.ZERO, 1, -1, visible_filter) == farther_cell, "automatic spice lookup must support a future fog-of-war visibility filter")
	_expect(layer.take_spice(cell, 75) == 75 and layer.spice_at(cell) == 125, "harvesting must return and remove the requested available spice")
	_expect(data.nav_spice_value[cell.y * MapNavigationGridScript.NAV_SIZE + cell.x] == 200, "runtime harvesting must not mutate baked initial state")
	_expect(grid.cell_debug(cell).get("spice") == 125, "harvesting must keep navigation spice lookup synchronized")
	_expect(layer.take_spice(cell, 200) == 125 and layer.spice_at(cell) == 0, "harvesting must stop at an exhausted field")
	_expect(layer.add_spice(cell, 300) == 255 and layer.spice_at(cell) == 255, "regeneration must saturate the cell at byte density")
	_expect(layer.spice_mask_texture() != null, "the dynamic field must expose its visual mask texture")
	_expect(not layer.set_spice(Vector2i(-1, 0), 10), "runtime mutations outside the map must be rejected")
	_expect(layer.add_spice(Vector2i(-1, 0), 10) == 0, "regeneration outside the map must not report added spice")
	return token


func _test_spice_mound_source_grid_mapping(token: int) -> int:
	var data = _valid_data("spice-mounds")
	data.nav_report["source_spice_grid_size"] = Vector2i(128, 128)
	data.spice_mound_cells.append(Vector2i(4, 5))
	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "spice mound fixture must load its navigation grid")
	var layer = MapSpiceLayerScript.new()
	_expect(layer.load_baked(data, grid), "spice mound layer must load source cells")
	_expect(layer.has_spice_mound(Vector2i(8, 10)) and layer.has_spice_mound(Vector2i(9, 11)), "one 128-grid mound cell must cover its corresponding 2x2 navigation cells")
	_expect(not layer.has_spice_mound(Vector2i(10, 10)), "a mound mask must not leak into its neighboring source cell")
	_expect(layer.set_spice_mound(Vector2i(8, 10), false) and not layer.has_spice_mound(Vector2i(8, 10)) and not layer.has_spice_mound(Vector2i(9, 11)), "a consumed bloom must remove its complete source-grid footprint")

	var uneven_data = _valid_data("uneven-spice-mounds")
	uneven_data.nav_report["source_spice_grid_size"] = Vector2i(144, 144)
	uneven_data.spice_mound_cells.append(Vector2i(69, 58))
	var uneven_grid = MapNavigationGridScript.new()
	_expect(uneven_grid.load_baked(uneven_data), "an uneven source-grid fixture must load")
	var uneven_layer = MapSpiceLayerScript.new()
	_expect(uneven_layer.load_baked(uneven_data, uneven_grid), "an uneven source-grid mound must load")
	_expect(uneven_layer.has_spice_mound(Vector2i(122, 103)), "source-grid placement must preserve the authored cell when grid sizes do not divide evenly")
	_expect(not uneven_layer.has_spice_mound(Vector2i(120, 101)), "source-grid placement must not round-trip into the preceding cell")
	return token


func _test_spice_mound_runtime_entity_contract(token: int) -> int:
	var config = SpiceMoundDefinitionScript.new()
	config.maturity_minimum_ticks = 1000
	config.maturity_random_ticks = 500
	var mound = SpiceMoundScene.instantiate()
	mound.configure(Vector2i(4, 5), Vector2(2.0, 3.0), config, 0.5)

	var visual := mound.get_node("Visual") as Node3D
	var model_mesh := mound.get_node("Visual/_0Spicemound/Mesh") as MeshInstance3D
	var model_player := mound.get_node("Visual/AnimationPlayer") as AnimationPlayer
	var box := mound.get_node("CollisionShape3D").shape as BoxShape3D
	var dust := mound.get_node("SpreadDust") as GPUParticles3D
	var dust_material := dust.process_material as ParticleProcessMaterial
	var dust_quad := dust.draw_pass_1 as QuadMesh
	_expect(model_mesh.mesh.get_surface_count() == 1 and model_mesh.get_aabb().size.y > 0.0, "a mound must use the original three-dimensional XBF mesh")
	_expect(is_equal_approx(visual.scale.x * 32.0, 2.0) and is_equal_approx(visual.scale.z * 32.0, 3.0), "the original mound mesh must match its source-cell world footprint")
	_expect(box.size.x == 2.0 and box.size.z == 3.0, "a mound Area3D must own a collision region matching its mesh")
	_expect(dust.one_shot and not dust.emitting and not dust.visible and dust.lifetime == 10.0, "a mound must own a dormant ten-second geyser emitter")
	_expect(dust_material.direction == Vector3.UP and dust_material.gravity.y < 0.0, "hazard dust must launch upward and fall under downward gravity")
	_expect(mound.collision_layer == 0 and mound.collision_mask == 2, "a mound must detect unit bodies without becoming a solid navigation obstacle")
	# (1000 + 500*0.5) = 1250 rule ticks, * MATURITY_DURATION_MULTIPLIER(3) =
	# 3750 rule ticks at 60 Hz -> RuleTicks.to_sim_ticks(3750) =
	# roundi(3750 * 25 / 60) = roundi(1562.5) = 1563 simulation ticks, i.e.
	# 1563/25 = 62.52s -- the same "near one real minute" duration the old
	# real-seconds timer.wait_time assertion this replaces was pinning.
	_expect(mound.maturity_duration_ticks(0.5) == 1563, "the maturity multiplier must put the randomized Size plus Cost lifespan near one real minute")
	_expect(model_player.has_animation(&"timeline") and model_player.get_animation(&"timeline").track_get_key_count(0) == 31, "a mound must retain its original XBF growth animation")
	_expect(is_equal_approx(mound.growth_scale(), 0.001), "a new maturity cycle must start at the authored initial scale")
	mound.call("_set_maturity_progress", 0.5)
	_expect(is_equal_approx(mound.growth_scale(), 0.376259), "mound growth must follow the authored non-linear transform curve")

	var activation_count := [0]
	var early_activations: Array[bool] = []
	var activation_fractions: Array[float] = []
	mound.activated.connect(func(_entity, early: bool, maturity_fraction: float) -> void:
		activation_count[0] += 1
		early_activations.append(early)
		activation_fractions.append(maturity_fraction)
	)
	# activate()'s reported fraction now comes from maturity_progress(), which
	# reads the tick countdown -- the _set_maturity_progress() call above only
	# ever drove the visual transform growth_scale() reads (see sim_tick()'s
	# doc comment for why the two are separate now). Poke the countdown
	# directly to an exact 50%: 500 remaining of 1000 is an exact 0.5, which
	# sidesteps the rounding in the mound's own authored 1563-tick duration
	# already pinned above.
	mound._maturity_cycle_ticks = 1000
	mound.maturity_ticks_remaining = 500
	_expect(
		mound.activate(true)
			and activation_count[0] == 1
			and early_activations[0]
			and is_equal_approx(activation_fractions[0], 0.5),
		"contact activation must report the elapsed fraction of the current cycle"
	)
	# The successful activate() above already called restart_maturity_cycle(),
	# which reset the countdown to a fresh (1563-tick) cycle -- i.e. progress
	# 0.0, well under the 30% repeat-activation floor, with no extra poke
	# needed for this rejection to hold.
	_expect(
		not mound.activate(true) and activation_count[0] == 1,
		"a recurring mound must reject another contact activation before reaching thirty-percent maturity"
	)
	# 700 remaining of 1000 is an exact 0.3 -- exactly the repeat-activation
	# floor, so this also pins that the floor is inclusive.
	mound._maturity_cycle_ticks = 1000
	mound.maturity_ticks_remaining = 700
	_expect(
		mound.activate(true)
			and activation_count[0] == 2
			and is_equal_approx(activation_fractions[1], 0.3),
		"a recurring mound must allow contact activation at thirty-percent maturity"
	)
	_expect(not dust.emitting, "the mound must wait for the map layer to provide the complete spread area")
	var hazard_points := PackedVector3Array([Vector3.ZERO, Vector3(2.0, 0.25, 1.0)])
	mound.start_spread_hazard(hazard_points, 1.25)
	_expect(dust.emitting and dust.visible and dust_material.initial_velocity_max > 0.0, "the geyser must launch across the supplied spread radius from the mound")
	var uncompensated_velocity := sqrt(Vector2(2.0, 1.0).length() * 1.2) * 1.08
	_expect(dust_material.initial_velocity_max >= uncompensated_velocity * 1.65, "the geyser must use an extra launch boost for a faster opening burst")
	_expect(dust.amount == 48 and dust_quad.size.is_equal_approx(Vector2(1.25, 1.25) / 3.0), "hazard density and reduced particle size must scale from the spread grid")
	var scale_texture := dust_material.scale_curve as CurveTexture
	_expect(scale_texture != null and scale_texture.curve.min_value == 0.0 and scale_texture.curve.max_value == 3.0, "hazard clouds must grow from one-third size back to their original size")
	var damping_texture := dust_material.damping_curve as CurveTexture
	_expect(
		damping_texture != null
			and damping_texture.curve.sample(0.0) > damping_texture.curve.sample(0.4)
			and damping_texture.curve.sample(0.4) > damping_texture.curve.sample(1.0),
		"hazard clouds must decelerate sharply near the start and drift gently near the end"
	)
	_expect(
		damping_texture.curve.sample(0.62) <= 0.11
			and damping_texture.curve.sample(1.0) <= 0.03,
		"the extended geyser animation must ease into a very soft final drift"
	)
	mound.stop_spread_hazard()
	_expect(not dust.emitting and not dust.visible, "ending the ten-second hazard must hide its visual indicator immediately")
	_expect(is_equal_approx(mound.growth_scale(), 0.001), "early activation must immediately restart the authored growth animation")
	mound.call("_on_maturity_timeout")
	_expect(
		activation_count[0] == 3
			and not early_activations[2]
			and activation_fractions[2] == 1.0,
		"timer activation must report a complete cycle and begin the next one"
	)
	_expect(is_equal_approx(mound.growth_scale(), 0.001), "timer activation must restart the recurring authored growth animation")
	mound.free()
	return token


## Pins the 60 Hz -> 25 Hz conversion itself (RuleTicks.to_sim_ticks(), driven
## through SpiceMound.maturity_duration_ticks()): a mound must not mature one
## sim_tick() early, and must mature on the exact tick the conversion
## predicts -- not "eventually" or "close enough". The runtime-entity-contract
## case above already checks the converted duration's value; this one checks
## that sim_tick() actually counts down to it.
func _test_spice_mound_maturity_tick_conversion(token: int) -> int:
	var config = SpiceMoundDefinitionScript.new()
	config.maturity_minimum_ticks = 100
	config.maturity_random_ticks = 0
	var mound = SpiceMoundScene.instantiate()
	# maturity_random_ticks is 0, so the random fraction below can never
	# affect the result -- passing 0.0 explicitly keeps this case independent
	# of randf() (see spice_mound.gd's maturity_duration_ticks(), which
	# deliberately still calls randf() when no fraction is given; phase 4's
	# concern, not this slice's).
	mound.configure(Vector2i(0, 0), Vector2.ONE, config, 0.0)
	# 100 rule ticks * MATURITY_DURATION_MULTIPLIER(3) = 300 rule ticks at
	# RuleTicks.RULE_TICKS_PER_SECOND (60 Hz) -> to_sim_ticks(300) =
	# roundi(300 * 25 / 60) = roundi(125.0) = 125 simulation ticks exactly --
	# chosen so the conversion lands on a whole number and this case is not
	# also silently pinning roundi()'s tie-breaking rule.
	var expected_ticks := 125
	_expect(
		mound.maturity_duration_ticks(0.0) == expected_ticks,
		"the fixture's own converted duration must match the worked arithmetic before the tick-count assertions below mean anything"
	)
	var activation_count := [0]
	mound.activated.connect(func(_entity, _early: bool, _fraction: float) -> void:
		activation_count[0] += 1
	)
	for _i in expected_ticks - 1:
		mound.sim_tick()
	_expect(activation_count[0] == 0, "a mound must not mature one simulation tick before its converted duration elapses")
	mound.sim_tick()
	_expect(activation_count[0] == 1, "a mound must mature after exactly its converted number of simulation ticks")
	mound.free()
	return token


func _test_spice_mound_staged_passable_sand_spread(token: int) -> int:
	var data = _valid_data("spice-spread", AABB(Vector3.ZERO, Vector3(256.0, 1.0, 256.0)))
	data.nav_report["source_grid_size"] = Vector2i(256, 256)
	data.nav_report["source_spice_grid_size"] = Vector2i(256, 256)
	var center := Vector2i(20, 20)
	var wave_cells := [center, center + Vector2i.RIGHT, center + Vector2i(2, 0), center + Vector2i(3, 0)]
	for cell: Vector2i in wave_cells:
		data.nav_pass_mask[cell.y * MapNavigationGridScript.NAV_SIZE + cell.x] = MapNavigationGridScript.PASS_GROUND
	var passable_rock := center + Vector2i.DOWN
	var impassable_sand := center + Vector2i.LEFT
	var beyond_radius := center + Vector2i(4, 0)
	data.nav_terrain_type[passable_rock.y * MapNavigationGridScript.NAV_SIZE + passable_rock.x] = MapNavigationGridScript.TERRAIN_ROCK
	data.nav_pass_mask[passable_rock.y * MapNavigationGridScript.NAV_SIZE + passable_rock.x] = MapNavigationGridScript.PASS_GROUND
	data.nav_pass_mask[impassable_sand.y * MapNavigationGridScript.NAV_SIZE + impassable_sand.x] = MapNavigationGridScript.PASS_AIR
	data.nav_pass_mask[beyond_radius.y * MapNavigationGridScript.NAV_SIZE + beyond_radius.x] = MapNavigationGridScript.PASS_GROUND

	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "a staged spice-spread fixture must load its navigation grid")
	var layer = MapSpiceLayerScript.new()
	_expect(layer.load_baked(data, grid), "a staged spice-spread layer must load")
	var config = SpiceMoundDefinitionScript.new()
	config.blast_radius = 3.0
	config.spice_capacity = 800
	config.build_time_ticks = 6
	# BuildTime 6 * INTERVAL_MULTIPLIER(3) = 18 rule ticks at 60 Hz ->
	# RuleTicks.to_sim_ticks(18) = roundi(18 * 25 / 60) = roundi(7.5) = 8
	# simulation ticks, i.e. 0.32s against the 0.30s the old real-seconds
	# interval produced -- one rounding step inside an interval the multiplier
	# itself only approximates (see MapSpiceSpread.interval_ticks()).
	_expect(layer.spread().interval_ticks(config) == 8, "spice rings must advance three times slower than the Rules BuildTime interval")
	var job: Dictionary = layer.spread().create_job(center, config)
	_expect(job.get("stage_count") == 3 and (job.get("cells", []) as Array).size() == 4, "BlastRadius must produce one outward ring per tile and select only eligible cells")
	var early_job: Dictionary = layer.spread().create_job(center, config, 0.5)
	var early_spice_total := 0
	for entry: Dictionary in early_job.get("cells", []):
		early_spice_total += int(entry.get("amount", 0))
	_expect(early_spice_total == 400, "activation halfway through a mound cycle must spread half of its full spice capacity")
	# 250 ticks at MatchClock's 25 Hz is exactly ten seconds, and 250 / 5 is
	# exactly 50 pulses -- the whole schedule in whole numbers. The pulse rate
	# moved from four a second to five because 0.25s is 6.25 ticks and cannot
	# be expressed at all; _test_spice_hazard_preserves_total_damage() below
	# pins what that did and did not cost.
	_expect(
		MapSpiceHazardScript.HAZARD_DURATION_TICKS == 250
			and MapSpiceHazardScript.TICKS_PER_HAZARD_PULSE == 5
			and MapSpiceHazardScript.HAZARD_PULSE_COUNT == 50,
		"the damaging visual hazard must remain active for ten seconds at five checks per second"
	)
	_expect(is_equal_approx(layer.hazard().damage_per_second(), 10.0), "the hazard damage rate must use SpicePuff Damage from the rules catalog")

	var infantry := HazardUnit.new()
	infantry.unit_definition = UnitDefinitionScript.new()
	infantry.unit_definition.infantry = true
	infantry.position = grid.grid_to_world(center)
	var vehicle := HazardUnit.new()
	vehicle.unit_definition = UnitDefinitionScript.new()
	vehicle.unit_definition.infantry = false
	vehicle.position = grid.grid_to_world(center)
	var outside_infantry := HazardUnit.new()
	outside_infantry.unit_definition = infantry.unit_definition
	outside_infantry.position = grid.grid_to_world(beyond_radius)
	root.add_child(infantry)
	root.add_child(vehicle)
	root.add_child(outside_infantry)
	var hazard_cells := {center: true, center + Vector2i.RIGHT: true, center + Vector2i(2, 0): true, center + Vector2i(3, 0): true}
	_expect(layer.hazard().damage_infantry_in_cells(hazard_cells, 10.0, [infantry, vehicle, outside_infantry]) == 1, "a hazard tick must target only infantry inside the spice-spread cells")
	_expect(infantry.damage_taken == 10.0 and vehicle.damage_taken == 0.0 and outside_infantry.damage_taken == 0.0, "hazard damage must exclude vehicles and infantry outside BlastRadius")
	infantry.free()
	vehicle.free()
	outside_infantry.free()

	_expect(layer.spread().apply_stage(job, 1) == 2, "the first stage must populate only the center and first-radius ring")
	_expect(layer.spice_at(center) == 200 and layer.spice_at(center + Vector2i.RIGHT) == 200, "the first ring must receive its distributed mound capacity")
	_expect(layer.spice_at(center + Vector2i(2, 0)) == 0 and layer.spice_at(center + Vector2i(3, 0)) == 0, "outer rings must remain empty before their stages")
	_expect(layer.spread().apply_stage(job, 2) == 1 and layer.spice_at(center + Vector2i(2, 0)) == 200, "the second stage must extend the field to radius two")
	_expect(layer.spread().apply_stage(job, 3) == 1 and layer.spice_at(center + Vector2i(3, 0)) == 200, "the final stage must reach BlastRadius")
	_expect(layer.spice_at(passable_rock) == 0, "passable rock must not receive spice")
	_expect(layer.spice_at(impassable_sand) == 0, "impassable sand must not receive spice")
	_expect(layer.spice_at(beyond_radius) == 0, "passable sand beyond BlastRadius must not receive spice")
	_expect(grid.spice_value[(center.y * MapNavigationGridScript.NAV_SIZE) + center.x] == 200, "staged spread must keep navigation spice state synchronized")
	return token


## The whole justification for moving the hazard from four pulses a second to
## five is that nothing a player experiences changes: same ten seconds, same
## total damage, only finer helpings. That is an arithmetic claim, so it is
## pinned here rather than left as a comment in map_spice_hazard.gd.
func _test_spice_hazard_preserves_total_damage(token: int) -> int:
	var layer = MapSpiceLayerScript.new()
	var hazard = layer.hazard()
	var rate: float = hazard.damage_per_second()
	_expect(rate > 0.0, "the fixture must resolve a positive SpicePuff damage rate before the totals below mean anything")

	# One pulse covers TICKS_PER_HAZARD_PULSE(5) * SECONDS_PER_TICK(0.04) =
	# 0.2s of the authored per-second rate.
	_expect(
		is_equal_approx(hazard.pulse_damage(), rate * 0.2),
		"one hazard pulse must deliver exactly the per-second rate over the real time the pulse interval covers"
	)
	# 50 pulses * 0.2s == 10s. The pre-conversion schedule was 40 * 0.25s,
	# which is the same 10s: the cadence changed, the total did not.
	_expect(
		is_equal_approx(
			float(MapSpiceHazardScript.HAZARD_PULSE_COUNT) * hazard.pulse_damage(),
			rate * 10.0
		),
		"a full hazard must deliver exactly ten seconds of the authored rate, the same total the old four-per-second schedule did"
	)
	_expect(
		MapSpiceHazardScript.HAZARD_PULSE_COUNT * MapSpiceHazardScript.TICKS_PER_HAZARD_PULSE
			== MapSpiceHazardScript.HAZARD_DURATION_TICKS,
		"the pulse schedule must divide the hazard lifetime exactly, with no tick left over"
	)
	return token


## Pins that a ring lands on the interval tick and not one tick earlier.
##
## MapSpiceSpread.start() cannot run in this fixture: it bails out unless the
## layer has a mounds root, and that needs a terrain mesh a bare baked-data
## layer has none of. So the job goes straight into _active the way start()
## would have left it -- tests may reach into internals here (see AGENTS.md;
## only scripts/ is scanned for module boundaries).
func _test_spice_spread_releases_a_ring_on_the_interval_tick(token: int) -> int:
	var data = _valid_data("spice-ring-cadence", AABB(Vector3.ZERO, Vector3(256.0, 1.0, 256.0)))
	data.nav_report["source_grid_size"] = Vector2i(256, 256)
	data.nav_report["source_spice_grid_size"] = Vector2i(256, 256)
	var center := Vector2i(20, 20)
	# Sand is the default terrain type in _valid_data(), so marking these
	# cells ground-passable is what makes them the passable sand a bloom
	# spreads over -- same setup as the staged-spread case above.
	for offset in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i(2, 0), Vector2i(3, 0)]:
		var cell: Vector2i = center + offset
		data.nav_pass_mask[cell.y * MapNavigationGridScript.NAV_SIZE + cell.x] = \
			MapNavigationGridScript.PASS_GROUND

	var grid = MapNavigationGridScript.new()
	_expect(grid.load_baked(data), "the ring-cadence fixture must load its navigation grid")
	var layer = MapSpiceLayerScript.new()
	_expect(layer.load_baked(data, grid), "the ring-cadence fixture must load its spice layer")

	var config = SpiceMoundDefinitionScript.new()
	config.blast_radius = 3.0
	config.spice_capacity = 800
	config.build_time_ticks = 6
	var interval: int = layer.spread().interval_ticks(config)
	_expect(interval == 8, "the fixture's interval must be the 8 ticks the conversion above already pinned")

	var stages: Array[int] = []
	layer.spice_spread_stage.connect(
		func(_source: Vector2i, stage: int, _stage_count: int, _changed: int) -> void:
			stages.append(stage)
	)
	var job: Dictionary = layer.spread().create_job(center, config)
	job["interval_ticks"] = interval
	job["ticks_remaining"] = interval
	layer.spread()._active[center] = job

	for _tick in interval - 1:
		layer.sim_tick()
	_expect(stages.is_empty(), "no ring may land before the interval elapses")
	layer.sim_tick()
	_expect(stages == [1], "the first ring must land on exactly the interval tick")

	for _tick in interval:
		layer.sim_tick()
	_expect(stages == [1, 2], "the second ring must land one whole interval after the first")
	return token

func _test_malformed_baked_data_is_atomic(token: int) -> int:
	var grid = MapNavigationGridScript.new()
	var bad_bounds = _valid_data("bad-bounds", AABB(Vector3.ZERO, Vector3(0.0, 1.0, 16.0)))
	_expect(not grid.load_baked(bad_bounds), "zero-width navigation bounds must be rejected")
	_expect(not grid.is_loaded() and grid.cell_debug(Vector2i.ZERO).get("valid") == false, "an initial rejected load must not expose a partial grid")

	var valid = _valid_data("stable", AABB(Vector3(1.0, 2.0, 3.0), Vector3(16.0, 1.0, 16.0)))
	valid.nav_terrain_type[0] = MapNavigationGridScript.TERRAIN_ROCK
	_expect(grid.load_baked(valid), "a valid load after rejection must succeed")
	var original_bounds: AABB = grid.world_bounds
	var original_debug: Dictionary = grid.cell_debug(Vector2i.ZERO)

	var bad_terrain = _valid_data("bad-terrain", AABB(Vector3.ZERO, Vector3(32.0, 1.0, 32.0)))
	bad_terrain.nav_terrain_type.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE - 1)
	_expect(not grid.load_baked(bad_terrain), "short terrain arrays must be rejected")
	_expect(grid.is_loaded() and grid.world_bounds == original_bounds and grid.cell_debug(Vector2i.ZERO) == original_debug, "rejected array data must preserve the prior loaded grid")

	var bad_cpf = _valid_data("bad-cpf", AABB(Vector3.ZERO, Vector3(32.0, 1.0, 32.0)))
	bad_cpf.nav_cpf_values.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE - 1)
	_expect(not grid.load_baked(bad_cpf), "short CPF arrays must be rejected")
	_expect(grid.is_loaded() and grid.map_dir == "stable", "all rejected baked arrays must leave the prior grid intact")
	return token


func _test_grid_reload_semantics(token: int) -> int:
	var grid = MapNavigationGridScript.new()
	var first = _valid_data("first", AABB(Vector3.ZERO, Vector3(16.0, 1.0, 16.0)))
	var second = _valid_data("second", AABB(Vector3(20.0, 0.0, 30.0), Vector3(32.0, 1.0, 64.0)))
	_expect(grid.load_baked(first), "the first valid grid load must succeed")
	_expect(grid.load_baked(second), "a valid replacement grid load must succeed")
	_expect(grid.is_loaded() and grid.map_dir == "second" and grid.world_bounds == second.nav_world_bounds, "a successful replacement must atomically replace the loaded grid")
	return token


func _test_map_loader_failed_replacement_is_atomic(token: int) -> int:
	var valid_path := _save_temporary_data(_valid_data("loader-valid", AABB(Vector3(4.0, 5.0, 6.0), Vector3(16.0, 1.0, 16.0))), "valid")
	var malformed = _valid_data("loader-malformed", AABB(Vector3(40.0, 0.0, 60.0), Vector3(32.0, 1.0, 32.0)))
	malformed.nav_buildable.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE - 1)
	var malformed_path := _save_temporary_data(malformed, "malformed")
	var loader = MapLoaderScript.new()
	loader.sun_path = NodePath("NoSun")
	loader.environment_path = NodePath("NoEnvironment")
	loader.load_map(valid_path)
	_expect(loader.map_data != null and loader.navigation_grid != null and loader.navigation_grid.is_loaded(), "a valid resource must initialize all map loader state")
	var original_data = loader.map_data
	var original_grid = loader.navigation_grid
	var original_spice_layer = loader.spice_layer
	var original_aabb: AABB = loader.terrain_aabb
	loader.load_map(malformed_path)
	_expect(loader.map_data == original_data and loader.navigation_grid == original_grid and loader.spice_layer == original_spice_layer and loader.terrain_aabb == original_aabb, "a malformed replacement must preserve the last valid map state")
	loader.load_map("user://missing-map-contract-fixture.tres")
	_expect(loader.map_data == original_data and loader.navigation_grid == original_grid and loader.terrain_aabb == original_aabb, "a missing replacement must preserve the last valid map state")
	loader.free()
	return token


func _test_map_loader_initial_failure_stays_empty(token: int) -> int:
	var malformed = _valid_data("initial-malformed", AABB(Vector3.ZERO, Vector3(16.0, 1.0, 16.0)))
	malformed.nav_source_tile_y.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE - 1)
	var malformed_path := _save_temporary_data(malformed, "initial-malformed")
	var recovery_bounds := AABB(Vector3(8.0, 2.0, 12.0), Vector3(24.0, 1.0, 32.0))
	var recovery_path := _save_temporary_data(_valid_data("initial-recovery", recovery_bounds), "initial-recovery")
	var loader = MapLoaderScript.new()
	loader.load_map("user://missing-initial-map-contract-fixture.tres")
	_expect(loader.map_data == null and loader.navigation_grid == null and loader.terrain_aabb == AABB(), "an initial missing map must leave the loader empty")
	loader.load_map(malformed_path)
	_expect(loader.map_data == null and loader.navigation_grid == null and loader.terrain_aabb == AABB(), "an initial malformed map must leave the loader empty")
	loader.load_map(recovery_path)
	_expect(loader.map_data != null and loader.map_data.source_map_dir == "initial-recovery" and loader.navigation_grid != null and loader.navigation_grid.is_loaded() and loader.navigation_grid.world_bounds == recovery_bounds and loader.terrain_aabb == recovery_bounds, "a valid map after initial failures must atomically populate loader data, grid, and bounds")
	loader.free()
	return token


func _test_map_loader_wrong_resource_type_is_atomic(token: int) -> int:
	var wrong_resource_path := _save_temporary_resource(Resource.new(), "wrong-resource")
	var initial_valid_path := _save_temporary_data(_valid_data("wrong-resource-initial"), "wrong-resource-initial")
	var recovery_bounds := AABB(Vector3(32.0, 2.0, 48.0), Vector3(24.0, 1.0, 32.0))
	var recovery_path := _save_temporary_data(_valid_data("wrong-resource-recovery", recovery_bounds), "wrong-resource-recovery")
	var loader = MapLoaderScript.new()
	loader.load_map(wrong_resource_path)
	_expect(loader.map_data == null and loader.navigation_grid == null and loader.terrain_aabb == AABB(), "an initial wrong resource type must leave the loader empty")
	loader.load_map(initial_valid_path)
	_expect(loader.map_data != null and loader.map_data.source_map_dir == "wrong-resource-initial" and loader.navigation_grid != null and loader.navigation_grid.is_loaded(), "a valid map after an initial wrong resource type must initialize the loader")
	var original_data = loader.map_data
	var original_grid = loader.navigation_grid
	var original_aabb: AABB = loader.terrain_aabb
	loader.load_map(wrong_resource_path)
	_expect(loader.map_data == original_data and loader.navigation_grid == original_grid and loader.terrain_aabb == original_aabb, "a wrong resource replacement must preserve the last valid map state")
	loader.load_map(recovery_path)
	_expect(loader.map_data != null and loader.map_data.source_map_dir == "wrong-resource-recovery" and loader.navigation_grid != null and loader.navigation_grid.world_bounds == recovery_bounds and loader.terrain_aabb == recovery_bounds, "a valid replacement after a wrong resource type must recover atomically")
	loader.free()
	return token


func _valid_data(source_dir: String, bounds := AABB(Vector3.ZERO, Vector3(16.0, 1.0, 16.0))) -> BakedMapData:
	var data = BakedMapDataScript.new()
	var total := MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE
	data.source_map_dir = source_dir
	data.world_scale = 0.0625
	data.terrain_aabb = bounds
	data.nav_world_bounds = bounds
	data.nav_cpf_values.resize(total)
	data.nav_terrain_type.resize(total)
	data.nav_source_tile_x.resize(total)
	data.nav_source_tile_y.resize(total)
	data.nav_spice_value.resize(total)
	data.nav_pass_mask.resize(total)
	data.nav_movement_cost.resize(total)
	data.nav_buildable.resize(total)
	return data


func _save_temporary_data(data: BakedMapData, suffix: String) -> String:
	return _save_temporary_resource(data, suffix)


func _save_temporary_resource(resource: Resource, suffix: String) -> String:
	var path := "user://map-runtime-contract-%d-%s.tres" % [Time.get_ticks_usec(), suffix]
	var error := ResourceSaver.save(resource, path)
	_expect(error == OK, "temporary %s resource must save" % suffix)
	_temporary_paths.append(path)
	return path


func _cleanup_temporary_files() -> void:
	for path in _temporary_paths:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_temporary_paths.clear()


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
