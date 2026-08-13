extends SceneTree
## Focused transport/targeting suite.  The state-machine tests use small
## protocol doubles to make timing/order deterministic; the final case binds
## real converted Units to prove actual CargoAnchor reparenting preserves the
## gameplay instance and its full inherited transform.

const AdvancedCarryallTransportScript := preload(
	"res://scripts/units/advanced_carryall_transport.gd"
)
const AdvancedCarryallAbilityScript := preload(
	"res://scripts/match/advanced_carryall_ability.gd"
)
const SelectionTargetAbilityControllerScript := preload(
	"res://scripts/match/selection_target_ability_controller.gd"
)
const CursorManagerScript := preload("res://scripts/ui/cursor_manager.gd")
const AbilityBarScene := preload("res://scenes/ui/ability_bar.tscn")
const ATADVCarryallScene := preload("res://scenes/units/atadv_carryall.tscn")
const HKADVCarryallScene := preload("res://scenes/units/hkadv_carryall.tscn")
const ORADVCarryallScene := preload("res://scenes/units/oradv_carryall.tscn")
const StuntATADVCarryallScene := preload("res://scenes/units/stunt_atadv_carryall.tscn")
const ATScoutScene := preload("res://scenes/units/at_trike.tscn")
const ATInfantryScene := preload("res://scenes/units/at_militia.tscn")

var _assertions := 0
var _failures := 0
var _current_case := ""


class FakeCargo extends Node3D:
	var owner_player_id := 1
	var eligible := true
	var reserved_by = null
	var locked := false
	var attached := false
	var released := false
	var forced_dead := false
	var invulnerable := false
	var cancelled := 0

	func can_be_picked_up_by(_carrier: Node3D) -> bool:
		return eligible and not attached

	func reserve_for_transport(carrier: Node3D) -> bool:
		if not can_be_picked_up_by(carrier) or reserved_by != null:
			return false
		reserved_by = carrier
		return true

	func is_reserved_for_transport(carrier: Node3D) -> bool:
		return reserved_by == carrier

	func transport_lock_for_docking(_carrier: Node3D) -> void:
		locked = true
		cancelled += 1

	func transport_unlock_after_abort(_carrier: Node3D) -> void:
		locked = false
		reserved_by = null

	func transport_bounds_half_height() -> float:
		return 1.0

	func transport_vertical_bounds() -> Vector2:
		return Vector2(-0.5, 1.0)

	func transport_mark_carried(_carrier: Node3D) -> void:
		attached = true
		reserved_by = null

	func transport_mark_released(_position: Vector3, _facing: Vector3) -> void:
		attached = false
		released = true

	func transport_mark_destroyed_release() -> void:
		attached = false

	func force_transport_death(_cause: StringName) -> void:
		forced_dead = true


class FakeCarrier extends Node3D:
	var pickup_finished := false
	var takeoff_finished := false
	var drop_allowed := true
	var attached: Node3D
	var attached_offset := Vector3.ZERO
	var phase_log: Array[StringName] = []
	var aborts := 0
	var docking_stops := 0

	func transport_move_toward(position: Vector3) -> void:
		global_position = position

	func transport_align_with(_target: Node3D) -> void:
		phase_log.append(&"align_pickup")

	func transport_align_with_point(_position: Vector3) -> void:
		phase_log.append(&"align_drop")

	func transport_track_pickup_landing(target: Node3D) -> void:
		global_position = Vector3(target.global_position.x, global_position.y, target.global_position.z)
		phase_log.append(&"track_pickup")

	func transport_stop_for_docking() -> void:
		docking_stops += 1

	func flight_begin_pickup_sequence(_position: Vector3) -> void:
		pickup_finished = false
		phase_log.append(&"land")

	func flight_pickup_transition_finished() -> bool:
		return pickup_finished

	func flight_advance_pickup(phase: int) -> void:
		pickup_finished = false
		phase_log.append(&"pickup_%d" % phase)

	func flight_complete_pickup_sequence() -> void:
		takeoff_finished = false
		phase_log.append(&"takeoff")

	func flight_transport_takeoff_finished() -> bool:
		return takeoff_finished

	func transport_can_drop_cargo_at(_cargo: Node3D, _position: Vector3) -> bool:
		return drop_allowed

	func transport_attach_cargo(cargo: Node3D, offset: Vector3) -> void:
		attached = cargo
		attached_offset = offset
		cargo.transport_mark_carried(self)

	func transport_detach_cargo(cargo: Node3D, _parent: Node, position: Vector3) -> void:
		attached = null
		cargo.transport_mark_released(position, Vector3.FORWARD)

	func transport_release_destroyed_cargo(cargo: Node3D, _parent: Node) -> void:
		attached = null
		cargo.transport_mark_destroyed_release()

	func transport_abort_docking_recover() -> void:
		aborts += 1
		takeoff_finished = false

	func transport_target_is_enemy(target: Node3D) -> bool:
		return int(target.owner_player_id) == 2

	func transport_bounds_half_height() -> float:
		return 1.0

	func transport_vertical_bounds() -> Vector2:
		return Vector2(-1.0, 0.5)


class FakeAbilityCarrier extends Node3D:
	var pickup_ok := false
	var drop_ok := false
	var pickup_targets: Array[Node3D] = []
	var drop_targets: Array[Vector3] = []

	func is_advanced_carryall() -> bool: return true
	func can_offer_transport_pickup() -> bool: return pickup_ok
	func can_offer_transport_drop() -> bool: return drop_ok
	func can_receive_commands() -> bool: return true
	func can_pickup(_target: Node3D) -> bool: return pickup_ok
	func can_drop_at(_position: Vector3) -> bool: return drop_ok
	func command_pickup(target: Node3D) -> bool:
		pickup_targets.append(target)
		return true
	func command_drop(position: Vector3) -> bool:
		drop_targets.append(position)
		return true


class FakeAbilityBar extends RefCounted:
	signal ability_pressed(ability_id: StringName)
	var definitions: Array = []
	var active: StringName = &""
	func set_abilities(value: Array) -> void: definitions = value
	func set_active_ability(value: StringName) -> void: active = value


class GenericTestAbility extends RefCounted:
	var executions := 0
	func definitions(_selection: Array[Node]) -> Array[Dictionary]:
		return [{"id": &"generic", "slot": &"pickup", "keycode": KEY_F, "enabled": true}]
	func cursor_for(_id: StringName, _selection: Array[Node], _target, _position: Vector3) -> int:
		return 32
	func execute(_id: StringName, _selection: Array[Node], _target, _position: Vector3) -> Dictionary:
		executions += 1
		return {"ok": true, "message": "generic done"}


func _initialize() -> void:
	await process_frame
	_run_case("pickup order is Land, Start, pause, attach, Pickup, End, Takeoff", _test_pickup_order)
	_run_case("enemy delay is 3.4 seconds and neutral remains 1 second", _test_relation_delays)
	_run_case("drop pauses before release and invalid drop does not start", _test_drop_validation)
	_run_case("abort and cargo death recover flight without a stuck transition", _test_recovery)
	_run_case("ability adapter shows F/C, cursors, and chooses deterministic nearest carrier", _test_ability_adapter)
	_run_case("generic target ability hotkeys, repeat, Esc, selection change and bar toggle", _test_target_ability_controller)
	await _test_ability_bar_scene()
	await _test_real_cargo_anchor()
	await _test_real_eligibility_and_variants()
	if _failures > 0:
		printerr("Advanced Carryall tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Advanced Carryall tests: %d assertions passed" % _assertions)
	quit(0)


func _test_pickup_order() -> void:
	var carrier := FakeCarrier.new()
	var cargo := FakeCargo.new()
	root.add_child(carrier)
	root.add_child(cargo)
	var transport = AdvancedCarryallTransportScript.new()
	transport.configure(carrier)
	_expect(transport.command_pickup(cargo), "eligible cargo must accept pickup")
	transport.advance(0.1)
	_expect(transport.state_name() == &"land_pickup", "arrival must start Land")
	_expect(transport.counts_as_ground_target(), "landing/docking carrier must become a ground target")
	cargo.global_position = Vector3(3, 0, -2)
	transport.advance(0.1)
	_expect(carrier.global_position.is_equal_approx(cargo.global_position),
		"Land must continue following a target that moves before docking lock")
	carrier.pickup_finished = true
	transport.advance(0.1)
	_expect(transport.state_name() == &"start_pickup" and cargo.locked,
		"Land completion must lock cargo and start StartPickup")
	_expect(carrier.docking_stops == 1, "entering docking must clear the old navigation route")
	carrier.pickup_finished = true
	transport.advance(0.1)
	_expect(transport.state_name() == &"hold_pickup", "StartPickup must finish before docking pause")
	transport.advance(0.99)
	_expect(not cargo.attached, "friendly cargo must not attach before one-second pause")
	transport.advance(0.02)
	_expect(cargo.attached and transport.state_name() == &"lift_pickup",
		"pause completion must attach cargo before Pickup lift")
	_expect(not transport.counts_as_ground_target(),
		"carrier and attached cargo become airborne when Pickup lift begins")
	_expect(is_equal_approx(carrier.attached_offset.y, -2.05),
		"transport computes lower-anchor offset from authored bottom/top bounds")
	carrier.pickup_finished = true
	transport.advance(0.1)
	_expect(transport.state_name() == &"end_pickup", "Pickup lift must end before EndPickup")
	carrier.pickup_finished = true
	transport.advance(0.1)
	_expect(transport.state_name() == &"takeoff_pickup", "EndPickup must be followed by locked Takeoff")
	carrier.takeoff_finished = true
	transport.advance(0.1)
	_expect(transport.state_name() == &"carrying", "carrier is usable only after cruise resumes")
	cargo.invulnerable = true
	transport.on_owner_death()
	_expect(cargo.forced_dead,
		"carrier destruction must use the cargo lifecycle death bypass even if cargo is invulnerable")
	carrier.free()
	cargo.free()


func _test_relation_delays() -> void:
	var carrier := FakeCarrier.new()
	var enemy := FakeCargo.new()
	enemy.owner_player_id = 2
	root.add_child(carrier)
	root.add_child(enemy)
	var transport = AdvancedCarryallTransportScript.new()
	transport.configure(carrier)
	transport.command_pickup(enemy)
	transport.advance(0.1)
	carrier.pickup_finished = true
	transport.advance(0.1)
	carrier.pickup_finished = true
	transport.advance(0.1)
	transport.advance(3.39)
	_expect(not enemy.attached, "enemy cargo must retain 60-tick penalty after its base second")
	transport.advance(0.02)
	_expect(enemy.attached, "enemy cargo must attach at 3.4 seconds total")
	carrier.free()
	enemy.free()
	var neutral_carrier := FakeCarrier.new()
	var neutral := FakeCargo.new()
	neutral.owner_player_id = 0
	root.add_child(neutral_carrier)
	root.add_child(neutral)
	var neutral_transport = AdvancedCarryallTransportScript.new()
	neutral_transport.configure(neutral_carrier)
	neutral_transport.command_pickup(neutral)
	neutral_transport.advance(0.1)
	neutral_carrier.pickup_finished = true; neutral_transport.advance(0.1)
	neutral_carrier.pickup_finished = true; neutral_transport.advance(0.1)
	neutral_transport.advance(0.99)
	_expect(not neutral.attached, "neutral cargo must retain the ordinary one-second docking pause")
	neutral_transport.advance(0.02)
	_expect(neutral.attached, "neutral cargo must not receive the enemy capture penalty")
	neutral_carrier.free()
	neutral.free()


func _test_drop_validation() -> void:
	var carrier := FakeCarrier.new()
	var cargo := FakeCargo.new()
	root.add_child(carrier)
	root.add_child(cargo)
	var transport = AdvancedCarryallTransportScript.new()
	transport.configure(carrier)
	# Drive one pickup to carrying quickly, retaining the same cargo instance.
	transport.command_pickup(cargo)
	transport.advance(0.1); carrier.pickup_finished = true; transport.advance(0.1)
	carrier.pickup_finished = true; transport.advance(0.1); transport.advance(1.01)
	carrier.pickup_finished = true; transport.advance(0.1)
	carrier.pickup_finished = true; transport.advance(0.1)
	carrier.takeoff_finished = true; transport.advance(0.1)
	_expect(transport.state_name() == &"carrying", "setup pickup must reach carrying state")
	carrier.drop_allowed = false
	_expect(not transport.command_drop(Vector3(5, 0, 0)), "invalid footprint must reject drop at click")
	carrier.drop_allowed = true
	_expect(transport.command_drop(Vector3(5, 0, 0)), "valid point must begin drop")
	transport.advance(0.1)
	_expect(transport.counts_as_ground_target(), "drop landing must expose the carrier as a ground target")
	carrier.pickup_finished = true; transport.advance(0.1)
	carrier.pickup_finished = true; transport.advance(0.1); transport.advance(0.99)
	_expect(cargo.attached, "cargo must remain attached during drop pause")
	transport.advance(0.02)
	_expect(cargo.released and transport.state_name() == &"lift_drop", "drop releases only after pause")
	_expect(not transport.counts_as_ground_target(), "carrier becomes airborne again when drop lift begins")
	carrier.free()
	cargo.free()


func _test_recovery() -> void:
	var carrier := FakeCarrier.new()
	var cargo := FakeCargo.new()
	root.add_child(carrier)
	root.add_child(cargo)
	var transport = AdvancedCarryallTransportScript.new()
	transport.configure(carrier)
	transport.command_pickup(cargo)
	transport.advance(0.1)
	cargo.eligible = false
	transport.advance(0.1)
	_expect(transport.state_name() == &"recover_takeoff", "invalid pending cargo after land must recover")
	carrier.takeoff_finished = true
	transport.advance(0.1)
	_expect(transport.state_name() == &"idle", "recovery must finish only at cruise")
	# Death while attached during lift must clear the slot and still drive the
	# carrier through recovery, instead of leaving a null cargo in a pickup phase.
	var carrier_two := FakeCarrier.new()
	var cargo_two := FakeCargo.new()
	root.add_child(carrier_two); root.add_child(cargo_two)
	var transport_two = AdvancedCarryallTransportScript.new()
	transport_two.configure(carrier_two)
	transport_two.command_pickup(cargo_two)
	transport_two.advance(0.1); carrier_two.pickup_finished = true; transport_two.advance(0.1)
	carrier_two.pickup_finished = true; transport_two.advance(0.1); transport_two.advance(1.01)
	_expect(transport_two.state_name() == &"lift_pickup", "setup must attach cargo before transition death")
	transport_two.cargo_destroyed(cargo_two)
	_expect(transport_two.state_name() == &"recover_takeoff" and carrier_two.aborts == 1,
		"cargo death in lift must recover the living carrier")
	carrier_two.takeoff_finished = true; transport_two.advance(0.1)
	_expect(transport_two.state_name() == &"idle", "post-death recovery must complete at cruise")
	carrier_two.free(); cargo_two.free()
	carrier.free()
	cargo.free()


func _test_ability_adapter() -> void:
	var adapter := AdvancedCarryallAbilityScript.new()
	var first := FakeAbilityCarrier.new()
	var second := FakeAbilityCarrier.new()
	var target := FakeCargo.new()
	first.pickup_ok = true; second.pickup_ok = true
	root.add_child(first); root.add_child(second); root.add_child(target)
	first.position = Vector3(10, 0, 0); second.position = Vector3(2, 0, 0)
	var definitions := adapter.definitions([first, second])
	_expect(definitions.size() == 1 and StringName(definitions[0].get("id", &"")) == &"pickup",
		"empty advanced selection must expose F only")
	_expect(bool(adapter.execute(&"pickup", [first, second], target).get("ok", false)),
		"adapter must route valid pickup")
	_expect(second.pickup_targets.size() == 1 and first.pickup_targets.is_empty(),
		"nearest carrier alone must receive group F order")
	_expect(adapter.cursor_for(&"pickup", [first, second], target) == CursorManagerScript.CursorType.DN5,
		"pickup uses the existing DN5/Pick Up 3D cursor")
	_expect(adapter.cursor_for(&"pickup", [first, second], null) == CursorManagerScript.CursorType.CANT_MOVE,
		"invalid pickup uses existing forbidden movement cursor")
	first.pickup_ok = false; second.pickup_ok = false
	first.drop_ok = true; second.drop_ok = true
	var drop_defs := adapter.definitions([first, second])
	_expect(drop_defs.size() == 1 and StringName(drop_defs[0].get("id", &"")) == &"drop",
		"loaded carrier selection exposes C only")
	_expect(adapter.cursor_for(&"drop", [first, second], null, Vector3.ZERO) == CursorManagerScript.CursorType.DEPLOY,
		"drop uses the existing Deploy 3D cursor")
	second.position = first.position
	adapter.execute(&"drop", [first, second], null, Vector3.ZERO)
	var expected := first if first.get_instance_id() < second.get_instance_id() else second
	_expect(expected.drop_targets.size() == 1, "equal-distance groups use stable instance-id tie break")
	first.free(); second.free(); target.free()


func _test_target_ability_controller() -> void:
	var bar := FakeAbilityBar.new()
	var handler := GenericTestAbility.new()
	var controller = SelectionTargetAbilityControllerScript.new()
	controller.configure(bar, [handler])
	controller.selection_changed([])
	var f := InputEventKey.new(); f.pressed = true; f.keycode = KEY_F
	_expect(controller.handle_key(f) and controller.is_active() and bar.active == &"generic",
		"definition-provided F hotkey must enter generic mode")
	_expect(controller.cursor_for(null, Vector3.ZERO) == 32, "cursor semantics belong to handler")
	_expect(controller.execute(null, Vector3.ZERO) and handler.executions == 1 and not controller.is_active(),
		"valid click must execute once and close mode")
	controller.handle_key(f)
	_expect(controller.is_active(), "second F after execute must enter mode again")
	controller.handle_key(f)
	_expect(not controller.is_active(), "repeated active hotkey must cancel")
	bar.ability_pressed.emit(&"generic")
	_expect(controller.is_active(), "ability-bar press must enter targeting mode")
	var esc := InputEventKey.new(); esc.pressed = true; esc.keycode = KEY_ESCAPE
	_expect(controller.handle_key(esc) and not controller.is_active(), "Esc must cancel targeting mode")
	controller.handle_key(f)
	var replacement := Node.new()
	controller.selection_changed([replacement])
	_expect(not controller.is_active(), "selection change must cancel target mode")
	replacement.free()


func _test_ability_bar_scene() -> void:
	_current_case = "AbilityBar scene uses compact text-only F/C controls"
	var bar: AbilityBar = AbilityBarScene.instantiate()
	root.add_child(bar)
	await process_frame
	bar.set_abilities([{"id": &"pickup", "label": "F", "enabled": true}])
	var pickup := bar.get_node("Buttons/PickupButton") as Button
	var drop := bar.get_node("Buttons/DropButton") as Button
	_expect(bar.visible and pickup.visible and not drop.visible,
		"F availability must reveal only the pickup button")
	_expect(pickup.custom_minimum_size == Vector2(48, 48) and pickup.text == "F",
		"pickup control must be the specified 48px black text button, not an icon")
	var pressed: Array[StringName] = []
	bar.ability_pressed.connect(func(id: StringName) -> void: pressed.append(id))
	pickup.pressed.emit()
	_expect(pressed == [&"pickup"], "actual AbilityBar button must forward ability id")
	bar.set_abilities([
		{"id": &"pickup", "label": "F", "enabled": true},
		{"id": &"drop", "label": "C", "enabled": true},
	])
	_expect(drop.visible and drop.text == "C", "mixed selection must display both F and C controls")
	bar.queue_free()


func _test_real_cargo_anchor() -> void:
	_current_case = "real CargoAnchor inherits carrier transform"
	var units := Node3D.new()
	root.add_child(units)
	var carrier: Unit = ATADVCarryallScene.instantiate()
	var cargo: Unit = ATScoutScene.instantiate()
	units.add_child(carrier); units.add_child(cargo)
	await process_frame
	carrier.global_position = Vector3(3, 8, 2)
	carrier.global_rotation = Vector3(0.6, 0.4, 0.25)
	var cargo_id := cargo.get_instance_id()
	var expected_anchor_y := carrier.transport_vertical_bounds().x - cargo.transport_vertical_bounds().y - 0.05
	carrier.transport_attach_cargo(cargo, Vector3(0, expected_anchor_y, 0))
	_expect(cargo.get_instance_id() == cargo_id and cargo.is_carried(), "cargo must remain the same carried Unit")
	_expect(cargo.get_parent().name == "CargoAnchor", "cargo must be a real descendant of lower anchor")
	_expect(not cargo.can_receive_commands() and not cargo.can_perform_combat(),
		"carried cargo must reject commands and autonomous combat")
	_expect(not cargo.deploy(), "carried cargo must not deploy")
	_expect(cargo.navigation_is_suspended(), "attach must unregister cargo navigation")
	_expect(cargo.transform.is_equal_approx(Transform3D.IDENTITY),
		"cargo preserves the anchor's full inherited transform with identity local transform")
	var before := cargo.global_transform
	carrier.global_position += Vector3(4, 2, -3)
	carrier.global_rotation += Vector3(0.1, 0.3, -0.1)
	_expect(not cargo.global_transform.is_equal_approx(before), "cargo transform must follow carrier translation and rotation")
	_expect(cargo.combat_is_airborne(), "attached cargo must be an air target")
	_expect(is_equal_approx((cargo.get_parent() as Node3D).position.y, expected_anchor_y),
		"authored vertical bounds place cargo directly below carrier without overlap")
	carrier.transport_detach_cargo(cargo, units, Vector3(8, 0, 5))
	_expect(not cargo.is_carried() and not cargo.navigation_is_suspended(),
		"safe detach restores cargo's normal navigation contract")
	units.free()


func _test_real_eligibility_and_variants() -> void:
	_current_case = "real eligibility and Advanced Carryall variants"
	var units := Node3D.new()
	root.add_child(units)
	var at: Unit = ATADVCarryallScene.instantiate()
	var hk: Unit = HKADVCarryallScene.instantiate()
	var ordos: Unit = ORADVCarryallScene.instantiate()
	var stunt: Unit = StuntATADVCarryallScene.instantiate()
	var vehicle: Unit = ATScoutScene.instantiate()
	var infantry: Unit = ATInfantryScene.instantiate()
	units.add_child(at); units.add_child(hk); units.add_child(ordos); units.add_child(stunt)
	units.add_child(vehicle); units.add_child(infantry)
	await process_frame
	_expect(at.is_advanced_carryall() and hk.is_advanced_carryall() and ordos.is_advanced_carryall(),
		"AT/HK/OR advanced variants must expose the capability")
	for carrier in [at, hk, ordos]:
		for clip_name in [&"Land", &"StartPickup", &"Pickup", &"EndPickup", &"Takeoff"]:
			_expect(carrier.flight_play_clip(clip_name, false) != null,
				"%s must expose authored %s transport animation" % [carrier.config_id, clip_name])
	_expect(not stunt.is_advanced_carryall(), "ground StuntATADVCarryall must be excluded")
	_expect(vehicle.can_be_picked_up_by(at), "ordinary mobile ground vehicle must be eligible")
	vehicle.move_speed = 0.0; vehicle.mech_speed = 0.0
	_expect(not vehicle.can_be_picked_up_by(at), "stationary ground units must be ineligible")
	vehicle.move_speed = maxf(vehicle.move_speed, 1.0)
	_expect(not infantry.can_be_picked_up_by(at), "infantry must be ineligible")
	_expect(not at.can_be_picked_up_by(hk), "aircraft must be ineligible cargo")
	_expect(vehicle.reserve_for_transport(at), "first carrier may reserve cargo")
	_expect(not vehicle.can_be_picked_up_by(hk), "reserved cargo must reject a second carrier")
	vehicle.transport_unlock_after_abort(at)
	_expect(vehicle.can_receive_commands() and not vehicle.is_carried(),
		"abort must restore cargo command eligibility")
	units.free()


func _run_case(name: String, callable: Callable) -> void:
	_current_case = name
	var before := _failures
	callable.call()
	if before == _failures:
		print("PASS: %s" % name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL [%s]: %s" % [_current_case, message])
