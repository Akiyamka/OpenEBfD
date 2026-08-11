extends SceneTree
## Integration coverage for Building._begin_death_sequence(): killing a real
## building through take_damage() must still free it the same frame (today's
## contract, unchanged), while handing a corpse carrying its detached
## States/Destroy model to a sibling of the building's own parent when — and
## only when — that model actually carries the Explode clip. Mirrors
## tests/units/death_animation_run.gd's shape for the building side.

const ATConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const ORConYardScene := preload("res://assets/converted/buildings/ORConYard/ORConYard.scn")
const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")
const CombatImpactEffectScript := preload("res://scripts/combat/combat_impact_effect.gd")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")
const ExplosionTierPoolsScript := preload("res://scripts/audio/explosion_tier_pools.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	await _run_case(
		"a building with a Destroy/Explode clip spawns a DeathCorpse sibling and frees itself",
		_test_building_with_destroy_clip
	)
	await _run_case(
		"a building without a Destroy clip still explodes and plays sound, then frees without erroring",
		_test_building_without_destroy_clip
	)
	await _run_case(
		"survivors still spawn before the building disappears",
		_test_survivors_spawn_before_building_frees
	)
	await _run_case(
		"the death sound comes from the new ExplosionTierPools.BUILDING pool",
		_test_sound_from_building_pool
	)
	if _failures > 0:
		printerr("Building death tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Building death tests: %d assertions passed" % _assertions)
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


func _sound_players_in(world: Node3D) -> Array:
	var result: Array = []
	for child in world.get_children():
		if child is DeathSoundPlayerScript:
			result.append(child)
	return result


func _survivors_in(world: Node3D) -> Array:
	var result: Array = []
	for child in world.get_children():
		if child.is_in_group("units"):
			result.append(child)
	return result


func _configure_player(player_id: int, house_id: StringName) -> void:
	var players := root.get_node("Players")
	players.create_player(player_id, "Test %s" % String(house_id), Color.WHITE, house_id)


func _test_building_with_destroy_clip() -> void:
	_configure_player(1, &"Atreides")
	var world := Node3D.new()
	root.add_child(world)
	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = 1
	world.add_child(building)
	await process_frame

	building.take_damage(building.max_health + building.max_shields + 10.0, &"")

	_expect(building.is_queued_for_deletion(), "the killing blow must free the building in the same frame")
	var corpses := _corpses_in(world)
	_expect(corpses.size() == 1, "exactly one corpse must be spawned for ATConYard, got %d" % corpses.size())
	if not corpses.is_empty():
		var corpse := corpses[0] as Node3D
		_expect(corpse.get_child_count() > 0, "the corpse must carry the detached States/Destroy model")
		var player := corpse.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_expect(
			player != null and player.current_animation == &"Explode",
			"the corpse must play the authored Explode clip, got %s" % (player.current_animation if player != null else "<no player>")
		)
		# Mirrors DeathCorpse's own "never joins the units group" invariant for
		# the unit side: this corpse lands as a sibling under the same parent
		# real buildings live under, and code that walks that parent's children
		# by group (Match._refresh_sidebar_house_pages()) must never mistake it
		# for a live building and try to read config_id/house_id off it.
		_expect(
			not corpse.is_in_group("buildings"),
			"a building's DeathCorpse must never join the \"buildings\" group"
		)
	var explosion_effects := _explosion_effects_in(world)
	_expect(
		explosion_effects.size() == 1,
		"ATConYard's rules-authored BigExplosion must still spawn, got %d" % explosion_effects.size()
	)
	if not explosion_effects.is_empty():
		var effect := explosion_effects[0] as CombatImpactEffectScript
		_expect(
			effect.effect_id == &"BigExplosion",
			"the building's death explosion must use its rules-authored effect id, got %s" % effect.effect_id
		)
	world.queue_free()
	await process_frame


func _test_building_without_destroy_clip() -> void:
	_configure_player(2, &"Ordos")
	var world := Node3D.new()
	root.add_child(world)
	# ORConYard never shipped an H3 (destroy) source model (docs/quirks.md:
	# "Destroy (H3) debris motion is procedural"), so States/Destroy is absent
	# from its converted scene — the real-world case the no-corpse branch
	# exists for, not a stand-in.
	var building := ORConYardScene.instantiate() as Building
	building.owner_player_id = 2
	world.add_child(building)
	await process_frame

	_expect(
		building.get_node_or_null("States/Destroy") == null,
		"this case only proves the fallback if ORConYard really lacks States/Destroy"
	)

	building.take_damage(building.max_health + building.max_shields + 10.0, &"")

	_expect(building.is_queued_for_deletion(), "the building must still be freed even with no matching death clip")
	_expect(_corpses_in(world).is_empty(), "no corpse may be spawned when ORConYard has no Destroy model")
	var explosion_effects := _explosion_effects_in(world)
	_expect(
		explosion_effects.size() == 1,
		"a building with no Destroy clip must still spawn its rules-authored explosion, got %d" % explosion_effects.size()
	)
	var sound_players := _sound_players_in(world)
	_expect(
		sound_players.size() == 1,
		"a building with no Destroy clip must still play its death sound, got %d" % sound_players.size()
	)
	world.queue_free()
	await process_frame


func _test_survivors_spawn_before_building_frees() -> void:
	_configure_player(3, &"Atreides")
	var world := Node3D.new()
	root.add_child(world)
	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = 3
	world.add_child(building)
	await process_frame

	building.take_damage(building.max_health + building.max_shields + 10.0, &"")

	_expect(building.is_queued_for_deletion(), "the killing blow must still free the building")
	var survivors := _survivors_in(world)
	_expect(
		survivors.size() == int(building.building_definition.survivor_count),
		"ATConYard must spawn its full NumInfantryWhenGone survivor count, got %d" % survivors.size()
	)
	for survivor in survivors:
		_expect(
			is_instance_valid(survivor) and not survivor.is_queued_for_deletion(),
			"survivors must remain alive after the building's own death sequence runs"
		)
	world.queue_free()
	await process_frame


func _test_sound_from_building_pool() -> void:
	_configure_player(4, &"Atreides")
	var world := Node3D.new()
	root.add_child(world)
	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = 4
	world.add_child(building)
	await process_frame

	building.take_damage(building.max_health + building.max_shields + 10.0, &"")

	var sound_players := _sound_players_in(world)
	_expect(sound_players.size() == 1, "exactly one death sound layer must play, got %d" % sound_players.size())
	if not sound_players.is_empty():
		var player := sound_players[0] as AudioStreamPlayer3D
		var stream := player.stream
		var stream_path := stream.resource_path if stream != null else ""
		_expect(
			stream_path in ExplosionTierPoolsScript.BUILDING,
			"the building death sound must come from ExplosionTierPools.BUILDING, got %s" % stream_path
		)
	world.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
