extends SceneTree
## Scene-level Advanced Carryall lifecycle test.
##
## Unlike advanced_carryall_run.gd's deterministic FSM doubles, this fixture
## runs real converted unit scenes through SceneTree physics, the production
## navigation coordinator, authored flight clips and CargoAnchor reparenting.

const FixtureScene := preload("res://tests/fixtures/advanced_carryall_e2e.tscn")
const AdvancedCarryallAbilityScript := preload(
	"res://scripts/match/advanced_carryall_ability.gd"
)
const UnitNavigationSystemScript := preload(
	"res://scripts/units/navigation/unit_navigation_system.gd"
)
const MapNavigationGridScript := preload(
	"res://scripts/world/map/map_navigation_grid.gd"
)

const PICKUP_TIMEOUT_FRAMES := 1200
const DROP_TIMEOUT_FRAMES := 1200
const DROP_POSITION := Vector3(52.0, 0.0, 40.0)

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	await process_frame
	var fixture: Node3D = FixtureScene.instantiate()
	root.add_child(fixture)
	await process_frame

	var carrier: Unit = fixture.get_node("Units/Carryall") as Unit
	var cargo: Unit = fixture.get_node("Units/Cargo") as Unit
	var original_parent := cargo.get_parent()
	var cargo_instance_id := cargo.get_instance_id()
	var carrier_start := carrier.global_position
	var selected_carriers: Array[Node] = [carrier]
	var ability = AdvancedCarryallAbilityScript.new()

	var navigation = UnitNavigationSystemScript.new()
	navigation.name = "UnitNavigationSystem"
	fixture.add_child(navigation)
	_expect(navigation.setup(_make_grid()), "production navigation must initialize")
	_expect(carrier.is_navigation_managed() and cargo.is_navigation_managed(),
		"both real fixture units must be registered with production navigation")
	var pickup_result: Dictionary = ability.execute(&"pickup", selected_carriers, cargo)
	_expect(bool(pickup_result.get("ok", false)),
		"the production ability adapter must issue pickup to the real Advanced Carryall")

	var pickup_trace := await _wait_for_state(carrier, cargo, &"carrying", PICKUP_TIMEOUT_FRAMES)
	if not bool(pickup_trace.get("reached", false)):
		print("Pickup timeout: states=%s carrier=%s cargo=%s nav=%s" % [
			pickup_trace.get("states", []), carrier.global_position, cargo.global_position,
			navigation.agent_debug(carrier),
		])
	_expect(bool(pickup_trace.get("reached", false)),
		"pickup must complete through approach, landing, docking and takeoff")
	_expect((pickup_trace.get("states", []) as Array).has(&"land_pickup"),
		"pickup must enter the authored landing phase")
	_expect((pickup_trace.get("states", []) as Array).has(&"hold_pickup"),
		"pickup must enter the one-second friendly docking hold")
	var pickup_land := _first_sample(pickup_trace, &"land_pickup")
	var pickup_land_offset := Vector2(
		float(pickup_land.get("carrier_x", 0.0)) - float(pickup_land.get("cargo_x", 0.0)),
		float(pickup_land.get("carrier_z", 0.0)) - float(pickup_land.get("cargo_z", 0.0))
	)
	_expect(pickup_land_offset.length() > 1.0,
		"Carryall must begin Land on approach instead of directly above pickup cargo")
	var pickup_hold := _first_sample(pickup_trace, &"hold_pickup")
	var pickup_carrier_bounds: Vector2 = pickup_hold.get("carrier_bounds", Vector2.ZERO)
	var pickup_cargo_bounds: Vector2 = pickup_hold.get("cargo_bounds", Vector2.ZERO)
	var pickup_gap := (
		float(pickup_hold.get("carrier_y", 0.0)) + pickup_carrier_bounds.x
		- float(pickup_hold.get("cargo_y", 0.0)) - pickup_cargo_bounds.y
	)
	_expect(is_equal_approx(pickup_gap, 0.05),
		"pickup descent must stop when carrier bottom reaches cargo top (gap=%.4f)" % pickup_gap)
	_expect_constrained_pickup_alignment(pickup_trace)
	_expect_docking_then_takeoff(
		pickup_trace,
		[&"start_pickup", &"lift_pickup", &"end_pickup"],
		&"takeoff_pickup",
		"loaded pickup"
	)
	_expect(carrier.global_position.distance_to(carrier_start) > 1.0,
		"navigation must physically fly the carrier toward cargo")
	_expect(cargo.get_instance_id() == cargo_instance_id and cargo.is_carried(),
		"the original ground-unit instance must become carried")
	_expect(cargo.get_parent().name == "CargoAnchor" and cargo.transform.is_equal_approx(Transform3D.IDENTITY),
		"pickup must attach cargo below the real carrier scene")
	_expect(carrier.combat_is_airborne() and cargo.combat_is_airborne(),
		"carrier and attached cargo must both be airborne targets")
	_expect(not cargo.can_receive_commands() and not cargo.can_perform_combat(),
		"attached cargo must reject commands and autonomous combat")

	var cargo_before_drop_flight := cargo.global_position
	var drop_result: Dictionary = ability.execute(&"drop", selected_carriers, null, DROP_POSITION)
	_expect(bool(drop_result.get("ok", false)),
		"the production ability adapter must issue a legal drop order")
	var drop_trace := await _wait_for_state(carrier, cargo, &"idle", DROP_TIMEOUT_FRAMES)
	if not bool(drop_trace.get("reached", false)):
		print("Drop timeout: states=%s carrier=%s cargo=%s nav=%s" % [
			drop_trace.get("states", []), carrier.global_position, cargo.global_position,
			navigation.agent_debug(carrier),
		])
	_expect(bool(drop_trace.get("reached", false)),
		"drop must complete through approach, landing, release and takeoff")
	_expect((drop_trace.get("states", []) as Array).has(&"land_drop"),
		"drop must enter the authored landing phase")
	_expect((drop_trace.get("states", []) as Array).has(&"hold_drop"),
		"drop must enter its docking hold before release")
	var drop_land := _first_sample(drop_trace, &"land_drop")
	var drop_land_offset := Vector2(
		float(drop_land.get("carrier_x", 0.0)) - DROP_POSITION.x,
		float(drop_land.get("carrier_z", 0.0)) - DROP_POSITION.z
	)
	_expect(drop_land_offset.length() > 1.0,
		"Carryall must begin Land on approach instead of directly above the drop point")
	var drop_hold := _first_sample(drop_trace, &"hold_drop")
	var drop_cargo_bounds: Vector2 = drop_hold.get("cargo_bounds", Vector2.ZERO)
	var dropped_bottom := float(drop_hold.get("cargo_y", 0.0)) + drop_cargo_bounds.x
	_expect(is_equal_approx(dropped_bottom, DROP_POSITION.y),
		"drop descent must stop with the carried cargo's lower bound on terrain (bottom=%.4f)" \
		% dropped_bottom)
	_expect_docking_then_takeoff(
		drop_trace,
		[&"start_drop", &"lift_drop", &"end_drop"],
		&"takeoff_drop",
		"empty drop"
	)
	_expect(cargo.global_position.distance_to(cargo_before_drop_flight) > 1.0,
		"attached cargo must travel with the carrier to the drop point")
	_expect(cargo.get_instance_id() == cargo_instance_id and not cargo.is_carried(),
		"drop must release the same surviving ground-unit instance")
	_expect(cargo.get_parent() == original_parent,
		"drop must restore cargo to its original scene container")
	_expect(cargo.global_position.distance_to(DROP_POSITION) < 0.05,
		"released cargo must be placed at the ordered destination")
	_expect(not cargo.navigation_is_suspended() and cargo.can_receive_commands(),
		"released cargo must return to navigation and command eligibility")
	_expect(not carrier.has_transport_cargo() and carrier.combat_is_airborne(),
		"empty carrier must finish its takeoff and return to flight")

	fixture.free()
	if _failures > 0:
		printerr("Advanced Carryall E2E: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Advanced Carryall E2E: %d assertions passed" % _assertions)
	quit(0)


func _wait_for_state(
	carrier: Unit, cargo: Unit, desired: StringName, maximum_frames: int
) -> Dictionary:
	var states: Array[StringName] = []
	var samples: Array[Dictionary] = []
	for _frame in maximum_frames:
		await physics_frame
		var state := carrier.transport_state_name()
		samples.append({
			"state": state,
			"carrier_x": carrier.global_position.x,
			"carrier_y": carrier.global_position.y,
			"carrier_z": carrier.global_position.z,
			"carrier_yaw": carrier.global_rotation.y,
			"carrier_bounds": carrier.transport_vertical_bounds(),
			"cargo_x": cargo.global_position.x,
			"cargo_y": cargo.global_position.y,
			"cargo_z": cargo.global_position.z,
			"cargo_yaw": cargo.global_rotation.y,
			"cargo_bounds": cargo.transport_vertical_bounds(),
		})
		if states.is_empty() or states.back() != state:
			states.append(state)
		if state == desired:
			return {"reached": true, "states": states, "samples": samples}
	return {"reached": false, "states": states, "samples": samples}


func _first_sample(trace: Dictionary, state: StringName) -> Dictionary:
	for sample: Dictionary in trace.get("samples", []):
		if StringName(sample.get("state", &"")) == state:
			return sample
	return {}


func _expect_constrained_pickup_alignment(trace: Dictionary) -> void:
	var landing_samples: Array[Dictionary] = []
	for sample: Dictionary in trace.get("samples", []):
		if StringName(sample.get("state", &"")) == &"land_pickup":
			landing_samples.append(sample)
	var hold := _first_sample(trace, &"hold_pickup")
	if landing_samples.size() < 2 or hold.is_empty():
		_expect(false, "pickup trace must contain enough landing frames to verify constrained alignment")
		return
	var initial_error := absf(angle_difference(
		float(landing_samples[0].get("carrier_yaw", 0.0)),
		float(landing_samples[0].get("cargo_yaw", 0.0))
	))
	var next_error := absf(angle_difference(
		float(landing_samples[1].get("carrier_yaw", 0.0)),
		float(landing_samples[1].get("cargo_yaw", 0.0))
	))
	var hold_error := absf(angle_difference(
		float(hold.get("carrier_yaw", 0.0)),
		float(hold.get("cargo_yaw", 0.0))
	))
	_expect(initial_error > 0.1 and next_error < initial_error and next_error > 0.01,
		("pickup-axis alignment must start gradually instead of snapping in one frame "
		+ "(initial=%.4f next=%.4f)") % [initial_error, next_error])
	_expect(hold_error < 0.001,
		"pickup docking hold must start only after constrained alignment completes")


func _expect_docking_then_takeoff(
	trace: Dictionary,
	docking_states: Array[StringName],
	takeoff_state: StringName,
	label: String
) -> void:
	var docking_y := INF
	var docking_samples := 0
	var held_docking_height := true
	for state in docking_states:
		var state_samples := 0
		for sample: Dictionary in trace.get("samples", []):
			if StringName(sample.get("state", &"")) != state:
				continue
			var current_y := float(sample.get("carrier_y", 0.0))
			if docking_samples == 0:
				docking_y = current_y
			held_docking_height = held_docking_height \
				and is_equal_approx(current_y, docking_y)
			state_samples += 1
			docking_samples += 1
		_expect(state_samples > 1,
			"%s trace must contain the complete %s docking clip" % [label, state])
	_expect(held_docking_height,
		"%s must hold one fixed height throughout StartPickup, Pickup and EndPickup" % label)

	var previous_y := docking_y
	var takeoff_samples := 0
	var never_descended := true
	var last_y := docking_y
	for sample: Dictionary in trace.get("samples", []):
		if StringName(sample.get("state", &"")) != takeoff_state:
			continue
		var current_y := float(sample.get("carrier_y", 0.0))
		never_descended = never_descended and current_y + 0.0001 >= previous_y
		previous_y = current_y
		last_y = current_y
		takeoff_samples += 1
	_expect(takeoff_samples > 1 and last_y > docking_y + 0.01,
		"%s must perform its vertical ascent during %s" % [label, takeoff_state])
	_expect(never_descended, "%s Takeoff must never move downward" % label)


func _make_grid() -> MapNavigationGrid:
	var total := MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE
	var cpf := PackedInt32Array()
	var terrain := PackedInt32Array()
	var source_x := PackedInt32Array()
	var source_y := PackedInt32Array()
	var spice := PackedByteArray()
	var pass_mask := PackedInt32Array()
	var movement_cost := PackedFloat32Array()
	var buildable := PackedByteArray()
	for array in [cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable]:
		array.resize(total)
	terrain.fill(MapNavigationGridScript.TERRAIN_ROCK)
	pass_mask.fill(MapNavigationGridScript.PASS_GROUND | MapNavigationGridScript.PASS_AIR)
	movement_cost.fill(1.0)
	buildable.fill(1)
	var grid := MapNavigationGrid.new()
	grid.load_generated(
		"advanced_carryall_e2e",
		AABB(Vector3.ZERO, Vector3(256.0, 1.0, 256.0)),
		1.0,
		cpf,
		terrain,
		source_x,
		source_y,
		spice,
		pass_mask,
		movement_cost,
		buildable,
		{},
		{}
	)
	return grid


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
