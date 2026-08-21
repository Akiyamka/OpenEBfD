extends SceneTree
## Integration coverage for Unit._begin_death_sequence(): killing a real unit
## through take_damage() must still free it the same frame (today's
## contract, unchanged), while handing a corpse carrying its model subtree to
## a sibling of the unit's own parent when — and only when — the death
## strategy actually proposes a clip the model owns.

const UnitScene := preload("res://scenes/units/unit.tscn")
const OrApcModelScene := preload("res://assets/converted/models/Or_apc_H0/Or_apc_H0.scn")
const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")
const CombatImpactEffectScript := preload("res://scripts/combat/combat_impact_effect.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	await _run_case("a shot infantry unit is freed immediately and leaves exactly one corpse", _test_infantry_death)
	await _run_case("an exploded vehicle is freed immediately and leaves an Explode corpse", _test_vehicle_death)
	await _run_case("an unmatched death cause frees the unit with no corpse at all", _test_no_matching_clip)
	await _run_case("a vehicle with no Explode clip still spawns its death explosion", _test_vehicle_death_no_clip)
	await _run_case("a unit mid-fire-sequence is freed without casting a freed overlay player", _test_death_mid_fire_sequence)
	await _run_case("a unit killed mid-own-fire-animation keeps its corpse on the death clip, not a replayed idle", _test_death_mid_own_fire_animation)
	await _run_case("a dying unit retains no reference into the corpse it just handed its model to", _test_dying_unit_leaves_no_reference_into_its_corpse)
	if _failures > 0:
		printerr("Death animation tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Death animation tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _corpses_in(world: Node3D) -> Array:
	var result: Array = []
	for child in world.get_children():
		if child is DeathCorpseScript:
			result.append(child)
	return result


func _explosion_effects_in(world: Node3D) -> Array:
	var result: Array = []
	for child in world.get_children():
		if child is CombatImpactEffectScript:
			result.append(child)
	return result


func _test_infantry_death() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	world.add_child(unit)
	await process_frame

	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"Shot")

	_expect(unit.is_queued_for_deletion(), "the killing blow must free the unit in the same frame, exactly as before this feature")
	var corpses := _corpses_in(world)
	_expect(corpses.size() == 1, "exactly one corpse must be spawned, got %d" % corpses.size())
	if not corpses.is_empty():
		var corpse := corpses[0] as Node3D
		_expect(corpse.get_child_count() > 0, "the corpse must carry the detached model subtree")
		var player := corpse.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_expect(
			player != null and String(player.current_animation).begins_with("Shot_"),
			"the corpse must be playing one of the Shot_ variants, got %s" % (player.current_animation if player != null else "<no player>")
		)
	# ATInfantry's UnitDefinition carries no explosion_effect_ids and no
	# explosion_type_id (infantry never had a Rules.txt ExplosionType), so no
	# CombatImpactEffect must be spawned — this must fall out naturally from
	# the empty list, not from any infantry-specific check in the spawn code.
	_expect(
		_explosion_effects_in(world).is_empty(),
		"infantry must not gain a death explosion effect it never had"
	)
	world.queue_free()
	await process_frame


func _test_vehicle_death() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var vehicle := UnitScene.instantiate() as Unit
	vehicle.config_id = &"ORAPC"
	var visual_root := vehicle.get_node("VisualRoot") as Node3D
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	visual_root.add_child(OrApcModelScene.instantiate())
	world.add_child(vehicle)
	await process_frame

	vehicle.take_damage(vehicle.max_health + vehicle.max_shields + 10.0, &"")

	_expect(vehicle.is_queued_for_deletion(), "the killing blow must free the vehicle in the same frame")
	var corpses := _corpses_in(world)
	_expect(corpses.size() == 1, "exactly one corpse must be spawned for the vehicle, got %d" % corpses.size())
	if not corpses.is_empty():
		var corpse := corpses[0] as Node3D
		var player := corpse.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_expect(
			player != null and player.current_animation == &"Explode",
			"a vehicle corpse must always play Explode regardless of damage type"
		)
	# ORAPC's UnitDefinition carries explosion_effect_ids = [&"Explosion"], so
	# the death sequence must spawn the same CombatImpactEffect a bullet
	# impact would (see CombatProjectile._spawn_explosion_visuals) — parented
	# as a sibling of the unit, since the unit itself is freed this frame.
	var explosion_effects := _explosion_effects_in(world)
	_expect(
		explosion_effects.size() == 1,
		"exactly one death explosion effect must be spawned for the vehicle, got %d" % explosion_effects.size()
	)
	if not explosion_effects.is_empty():
		var effect := explosion_effects[0] as CombatImpactEffectScript
		_expect(
			effect.effect_id == &"Explosion",
			"the vehicle's death explosion must use its rules-authored effect id, got %s" % effect.effect_id
		)
	world.queue_free()
	await process_frame


func _test_no_matching_clip() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	world.add_child(unit)
	await process_frame

	# An empty/unrecognized cause while not deployed proposes no candidates at
	# all (InfantryDeathStrategy.CANDIDATES has no "" entry), so this must
	# degrade byte-for-byte to today's behaviour: freed immediately, no corpse.
	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"")

	_expect(unit.is_queued_for_deletion(), "the unit must still be freed even with no matching death clip")
	# Slice C5's no-clip hole: this branch calls request_despawn() straight
	# from UnitDeathSequence's early return, never through
	# prepare_model_for_corpse() -- before C5 neither set anything at all, so
	# is_simulation_halted() staying false here would mean sim_tick() kept
	# running for a unit that queue_free() had already, invisibly, condemned
	# for the rest of this frame's remaining ticks.
	_expect(
		unit.is_simulation_halted(),
		"a unit with no matching death clip must still halt its simulation"
	)
	_expect(_corpses_in(world).is_empty(), "no corpse may be spawned when no clip matches")
	world.queue_free()
	await process_frame


## A vehicle with no model at all under VisualRoot (the degenerate case
## _begin_death_sequence's `model == null` branch exists for) must still
## degrade to queue_free() with no corpse — exactly like
## _test_no_matching_clip — but, per work item 3, must NOT also lose its
## rules-authored explosion visual: the ExplosionType/ExplosionEffects data
## and the Explode clip are independent in the original data, so a unit that
## can't produce a corpse must still explode.
func _test_vehicle_death_no_clip() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var vehicle := UnitScene.instantiate() as Unit
	vehicle.config_id = &"ORAPC"
	var visual_root := vehicle.get_node("VisualRoot") as Node3D
	for child in visual_root.get_children():
		visual_root.remove_child(child)
		child.free()
	world.add_child(vehicle)
	await process_frame

	vehicle.take_damage(vehicle.max_health + vehicle.max_shields + 10.0, &"")

	_expect(vehicle.is_queued_for_deletion(), "the vehicle must still be freed even with no matching death clip")
	_expect(_corpses_in(world).is_empty(), "no corpse may be spawned when no clip matches")
	var explosion_effects := _explosion_effects_in(world)
	_expect(
		explosion_effects.size() == 1,
		"a vehicle with no Explode clip must still spawn its death explosion, got %d" % explosion_effects.size()
	)
	world.queue_free()
	await process_frame


## Regression for _prepare_model_for_corpse() freeing a weapon-fire overlay
## AnimationPlayer that _weapon_fire_sequences still references: the killing
## blow must not try to cast that freed player when _exit_tree() cancels
## in-flight fire sequences. Reproduces the real crash by injecting a fake
## fire-while-moving sequence the same way tests/combat/unit_fire_movement_run.gd pokes
## _weapon_fire_sequences directly, since driving a real Mongoose to a
## mid-overlay-fire frame needs a full attack simulation this file otherwise
## has no use for.
func _test_death_mid_fire_sequence() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	world.add_child(unit)
	await process_frame

	var overlay := AnimationPlayer.new()
	unit.add_child(overlay)
	unit.combat()._fire_overlay.adopt_overlay(0, overlay)
	unit.combat()._weapon_fire_sequences[0] = {
		"turret": null,
		"target": {},
		"player": overlay,
		"animation": &"",
		"duration": 1.0,
		"elapsed": 0.0,
		"shot_times": [],
		"next_shot": 0,
		"shots_emitted": 0,
		"blocking": false,
	}

	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"Shot")

	_expect(unit.is_queued_for_deletion(), "a unit killed mid-fire-sequence must still be freed")
	_expect(not is_instance_valid(overlay), "the fire overlay handed to the corpse prep must have been freed")
	_expect(
		unit.combat()._weapon_fire_sequences.is_empty(),
		"the fire sequence referencing the freed overlay must be cleared, not left dangling"
	)
	# The actual free (and thus _exit_tree()'s _cancel_all_fire_sequences(false))
	# is deferred until here — this is the frame where the reported crash
	# ("Trying to cast a freed object", unit.gd _cancel_all_fire_sequences)
	# used to happen.
	await process_frame

	world.queue_free()
	await process_frame


## Regression for the real user-reported bug: a unit killed WHILE its own
## firing animation is playing left its corpse frozen on an IDLE pose,
## never freed. Root cause (unit.gd _prepare_model_for_corpse /
## _begin_death_sequence): handing the model subtree to the corpse does not
## stop the dying Unit's own processing for the rest of this frame, and the
## Unit never severed its own _animation_players reference to the model it
## just gave away. A still-pending tick this same frame — here, the dying
## unit's own attack order noticing its target is gone and calling
## stop_at_current_position() -> _set_movement_animation(false), exactly the
## kind of call a blocking fire sequence is normally mid-flight for — walks
## straight into the corpse's AnimationPlayer and replays IDLE over the
## Shot_ clip DeathCorpse is already playing. Replacing a playing animation
## only ever emits animation_changed, never animation_finished, so
## DeathCorpse._animation_done never flips and the corpse waits forever.
## The blocking fire-sequence dict entry here isn't itself what
## _set_movement_animation reads (that entry is cleared by
## _prepare_model_for_corpse's own _cancel_all_fire_sequences(false) before
## this tick even runs) — it reproduces the reported precondition ("own
## firing animation playing") so this case fails exactly the way the bug
## report described, not some easier-to-satisfy proxy for it.
func _test_death_mid_own_fire_animation() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	world.add_child(unit)
	await process_frame

	# The unit is still shooting at `target` when it dies, exactly like the
	# reported ATInfantry repro: a live blocking fire sequence bound to one
	# of the unit's own (real, model-owned) AnimationPlayers.
	var target := Node3D.new()
	world.add_child(target)
	unit.combat()._attack_order.begin(target)
	var fire_player := unit.animation_players()[0]
	unit.combat()._weapon_fire_sequences[0] = {
		"turret": null,
		"target": {"is_ground": false, "ref": weakref(target)},
		"player": fire_player,
		"animation": &"Fire",
		"duration": 1.0,
		"elapsed": 0.1,
		"shot_times": [],
		"next_shot": 0,
		"shots_emitted": 0,
		"blocking": true,
	}

	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"Shot")

	_expect(unit.is_queued_for_deletion(), "the killing blow must still free the unit")
	var corpses := _corpses_in(world)
	_expect(corpses.size() == 1, "exactly one corpse must be spawned, got %d" % corpses.size())
	if corpses.is_empty():
		world.queue_free()
		await process_frame
		return
	var corpse := corpses[0] as Node3D
	var player := corpse.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(
		player != null and String(player.current_animation).begins_with("Shot_"),
		"the corpse must start on a Shot_ death clip, got %s" % (player.current_animation if player != null else "<no player>")
	)

	# The unit's own attack target is gone (matches whatever ends a real
	# attack order — target destroyed, retreated out of the match, etc.),
	# so the still-in-tree-this-frame dying unit's own _process() notices on
	# its next tick and cancels its order.
	target.queue_free()
	await process_frame

	_expect(
		player != null and String(player.current_animation).begins_with("Shot_") and player.is_playing(),
		"a unit killed mid-own-fire-animation must keep its corpse playing the death clip after one more tick, not replay idle over it, got %s (playing=%s)" % [
			(player.current_animation if player != null else "<no player>"),
			(player.is_playing() if player != null else false),
		]
	)

	var freed := false
	for i in range(300):
		if not is_instance_valid(corpse):
			freed = true
			break
		await process_frame
	_expect(freed, "the corpse must eventually free itself once its death clip finishes, instead of waiting forever for an animation_finished a replayed idle would never emit")

	world.queue_free()
	await process_frame


## Generic invariant, not tied to either past bug by name: after a death
## handoff, a Unit's own state (walked by reflection, exactly like a future
## reviewer with no memory of cdc79b6/2b745b2 might check) must retain no
## reference to anything now belonging to the corpse, and must no longer be
## ticking. Reproduces both historical preconditions at once —
## cdc79b6's "fire sequence still names an overlay player that gets freed"
## and 2b745b2's "a blocking fire sequence bound to the unit's own
## model-owned player, with a live attack order" — plus
## _deployment_animation_player, the third such field this audit found that
## neither past fix had touched. The point is that _find_dangling_references
## does not need to know any of that: it would flag a dangling/live
## reference in ANY script variable, so a future fourth site is caught the
## same way without this test needing to change.
func _test_dying_unit_leaves_no_reference_into_its_corpse() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var unit := UnitScene.instantiate() as Unit
	world.add_child(unit)
	await process_frame

	var overlay := AnimationPlayer.new()
	unit.add_child(overlay)
	unit.combat()._fire_overlay.adopt_overlay(0, overlay)

	var target := Node3D.new()
	world.add_child(target)
	unit.combat()._attack_order.begin(target)
	var fire_player := unit.animation_players()[0]
	unit.combat()._weapon_fire_sequences[0] = {
		"turret": null,
		"target": {"is_ground": false, "ref": weakref(target)},
		"player": fire_player,
		"animation": &"Fire",
		"duration": 1.0,
		"elapsed": 0.1,
		"shot_times": [],
		"next_shot": 0,
		"shots_emitted": 0,
		"blocking": true,
	}
	# Exercises the third site this audit found: nothing but the death
	# handoff itself ever clears the deploy machine's cached transition
	# player. Planted through the production path that caches it, so the setup
	# cannot drift away from what deploying actually does.
	var planted_clip := StringName(fire_player.get_animation_list()[0])
	unit._deploy.start_transition([planted_clip] as Array[StringName])
	_expect(
		unit._deploy.transition_player() == fire_player,
		"the deploy transition must cache the model player this test plants"
	)

	unit.take_damage(unit.max_health + unit.max_shields + 10.0, &"Shot")

	_expect(unit.is_queued_for_deletion(), "the killing blow must still free the unit")
	var corpses := _corpses_in(world)
	_expect(corpses.size() == 1, "exactly one corpse must be spawned, got %d" % corpses.size())
	if corpses.is_empty():
		world.queue_free()
		await process_frame
		return
	var corpse := corpses[0] as Node3D

	var bad_properties := _find_dangling_references(unit, corpse)
	_expect(
		bad_properties.is_empty(),
		"a unit must retain no reference to a freed object or to a node under its own corpse after death, but found: %s" % [bad_properties]
	)
	var bad_connections := _find_connections_to_unit_or_modules(unit, corpse)
	_expect(
		bad_connections.is_empty(),
		"a corpse must retain no signal connection into its former Unit or modules, but found: %s" % [bad_connections]
	)
	_expect(not unit.is_processing(), "a unit must stop _process() the instant it hands off its model")
	_expect(unit.is_simulation_halted(), "a unit must stop simulating the instant it hands off its model")

	var player := corpse.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for i in range(5):
		if not is_instance_valid(corpse):
			break
		await process_frame
		if not is_instance_valid(corpse):
			break
		_expect(
			player != null and String(player.current_animation).begins_with("Shot_") and player.is_playing(),
			"the corpse must stay on its death clip across several frames, got %s (playing=%s)" % [
				(player.current_animation if player != null else "<no player>"),
				(player.is_playing() if player != null else false),
			]
		)

	var freed := false
	for i in range(300):
		if not is_instance_valid(corpse):
			freed = true
			break
		await process_frame
	_expect(freed, "the corpse must eventually free itself")

	world.queue_free()
	await process_frame


## True if `value` — or anything nested inside it, recursing into Arrays and
## Dictionaries (covering fields like _weapon_fire_sequences/_weapon_fire_overlays)
## — is either a reference to a freed Object (cdc79b6's class: a dangling
## pointer left after something it named was destroyed out from under it) or
## a live reference to a Node that is now `corpse` itself or one of its
## descendants (2b745b2's class: a pointer into a subtree that has since
## been handed to someone else).
func _value_dangles(value: Variant, corpse: Node, visited: Dictionary = {}) -> bool:
	if typeof(value) == TYPE_OBJECT:
		if not is_instance_valid(value):
			return true
		if value is Node and (value == corpse or corpse.is_ancestor_of(value as Node)):
			return true
		# RefCounted subsystem modules hide their fields from Unit's property list.
		# Follow script variables explicitly, while avoiding owner/module cycles.
		if not value is Node and value.get_script() != null:
			var instance_id: int = value.get_instance_id()
			if visited.has(instance_id):
				return false
			visited[instance_id] = true
			for property_info: Dictionary in value.get_property_list():
				var usage := int(property_info.get("usage", 0))
				if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
					continue
				var property_name := String(property_info.get("name", ""))
				if _value_dangles(value.get(property_name), corpse, visited):
					return true
		return false
	if value is Array:
		for item in value:
			if _value_dangles(item, corpse, visited):
				return true
		return false
	if value is Dictionary:
		for key in value:
			if _value_dangles(key, corpse, visited) or _value_dangles(value[key], corpse, visited):
				return true
		return false
	return false


## Walks every script-declared variable on `unit` (not editor/engine
## properties) via reflection and returns the names of any that dangle per
## _value_dangles(). Deliberately does not know about any specific field —
## a future field that caches a reference into a handed-off subtree is
## caught the same way a past one would have been.
func _find_dangling_references(unit: Unit, corpse: Node) -> Array[String]:
	var bad: Array[String] = []
	for property_info: Dictionary in unit.get_property_list():
		var usage := int(property_info.get("usage", 0))
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var property_name := String(property_info.get("name", ""))
		if _value_dangles(unit.get(property_name), corpse):
			bad.append(property_name)
	return bad


func _find_connections_to_unit_or_modules(unit: Unit, corpse: Node) -> Array[String]:
	var receiver_ids: Dictionary = {}
	_collect_script_object_ids(unit, receiver_ids)
	var bad: Array[String] = []
	var nodes: Array[Node] = [corpse]
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		nodes.append_array(node.get_children())
		for signal_info: Dictionary in node.get_signal_list():
			var signal_name := StringName(signal_info.get("name", &""))
			for connection: Dictionary in node.get_signal_connection_list(signal_name):
				var callback: Callable = connection.get("callable", Callable())
				var receiver: Object = callback.get_object()
				if receiver != null and receiver_ids.has(receiver.get_instance_id()):
					bad.append("%s.%s -> %s" % [node.get_path(), signal_name, callback])
	return bad


func _collect_script_object_ids(value: Variant, visited: Dictionary) -> void:
	if value is Array:
		for item in value:
			_collect_script_object_ids(item, visited)
		return
	if value is Dictionary:
		for key in value:
			_collect_script_object_ids(key, visited)
			_collect_script_object_ids(value[key], visited)
		return
	if typeof(value) != TYPE_OBJECT or not is_instance_valid(value):
		return
	if value is Node and not value is Unit:
		return
	if value.get_script() == null:
		return
	var instance_id: int = value.get_instance_id()
	if visited.has(instance_id):
		return
	visited[instance_id] = true
	for property_info: Dictionary in value.get_property_list():
		var usage := int(property_info.get("usage", 0))
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		_collect_script_object_ids(value.get(String(property_info.get("name", ""))), visited)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
