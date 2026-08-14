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

	var pickup_trace := await _wait_for_state(carrier, &"carrying", PICKUP_TIMEOUT_FRAMES)
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
	var drop_trace := await _wait_for_state(carrier, &"idle", DROP_TIMEOUT_FRAMES)
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


func _wait_for_state(carrier: Unit, desired: StringName, maximum_frames: int) -> Dictionary:
	var states: Array[StringName] = []
	for _frame in maximum_frames:
		await physics_frame
		var state := carrier.transport_state_name()
		if states.is_empty() or states.back() != state:
			states.append(state)
		if state == desired:
			return {"reached": true, "states": states}
	return {"reached": false, "states": states}


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
