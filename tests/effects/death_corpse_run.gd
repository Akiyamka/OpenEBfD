extends SceneTree
## Standalone tests for DeathCorpse.spawn(): a stand-in model with a fake
## AnimationPlayer stands in for the real converted model subtree Unit hands
## off, since nothing here needs the actual death-animation content, only the
## contract DeathCorpse offers around it.

const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")
const SoundEventScript := preload("res://scripts/audio/sound_event.gd")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	await _run_case("plays the resolved clip with LOOP_NONE", _test_plays_clip)
	await _run_case("freezes immediately with zero momentum", _test_freeze_zero_momentum)
	await _run_case("simulates with non-zero momentum", _test_simulate_nonzero_momentum)
	await _run_case("takes its own collision layer/mask", _test_collision_layer_mask)
	await _run_case("never joins the units group", _test_not_in_units_group)
	await _run_case("frees once the death clip finishes", _test_frees_on_animation_finished)
	await _run_case("collision shape is fit from the model's own mesh AABB, not a constant", _test_collision_shape_fits_model)
	await _run_case("two sound layers both play, and both hold the corpse open", _test_two_sound_layers_both_played)
	await _run_case("a single sound layer behaves as before", _test_single_sound_layer)
	await _run_case("an unresolvable sound layer never blocks cleanup", _test_unresolvable_sound_layer_frees_promptly)
	await _run_case("a delayed layer starts at its authored offset and holds the corpse open until then", _test_delayed_sound_layer)
	await _run_case("death sound is tuned to be audible at this game's real camera distances, not Godot's point-blank defaults", _test_death_sound_attenuation_tuned)
	await _run_case("a superseded one-shot fades out and frees instead of being cut with a click", _test_fade_out_and_free)
	await _run_case("'%'-marked debris launches from its authored husk position and flies apart, holding the corpse open until it lands", _test_debris_scatter_lands_and_holds_corpse_open)
	await _run_case("debris is left untouched when scatter_debris is not requested", _test_no_scatter_without_the_flag)
	await _run_case("a model with no '%'-marked children is a scatter no-op", _test_scatter_with_no_debris_pieces)
	if _failures > 0:
		printerr("DeathCorpse tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("DeathCorpse tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	await test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


## Builds a throwaway Node3D with one AnimationPlayer that owns `clip`, the
## same shape Unit._collect_animation_players() would find inside a real
## converted model. `mesh_size`, when non-zero, adds a MeshInstance3D with a
## BoxMesh of that size so tests can assert the corpse's collider is derived
## from actual model geometry rather than a fixed constant.
func _make_model(clip: StringName, mesh_size := Vector3.ZERO) -> Dictionary:
	var model := Node3D.new()
	var player := AnimationPlayer.new()
	model.add_child(player)
	var animation := Animation.new()
	animation.length = 1.0
	animation.loop_mode = Animation.LOOP_LINEAR
	var library := AnimationLibrary.new()
	library.add_animation(clip, animation)
	player.add_animation_library(&"", library)
	if not mesh_size.is_zero_approx():
		var mesh_instance := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = mesh_size
		mesh_instance.mesh = box
		model.add_child(mesh_instance)
	return {"model": model, "player": player, "animation": animation}


## Typed empty list for the "no sound at all" cases: DeathCorpse.spawn() takes
## a typed Array[Dictionary], which an inline `[]` literal cannot satisfy.
func _no_sounds() -> Array[Dictionary]:
	var schedule: Array[Dictionary] = []
	return schedule


## The voice schedule AuthoredDeathVoice hands over: one entry per resolved
## layer, `delay` being seconds into the death clip the model authored it at.
func _voice(entries: Array) -> Array[Dictionary]:
	var schedule: Array[Dictionary] = []
	for entry in entries:
		schedule.append({
			"event_id": StringName(entry[0]),
			"delay": float(entry[1]),
		})
	return schedule


func _sound_players(corpse: Node) -> Array[Node]:
	var players: Array[Node] = []
	for child in corpse.get_children():
		if child.get_script() == DeathSoundPlayerScript:
			players.append(child)
	return players


func _test_plays_clip() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var _corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", _no_sounds(), Vector3.ZERO, 1
	)
	var player: AnimationPlayer = fixture["player"]
	_expect(player.current_animation == &"Shot_1", "the resolved clip must be playing")
	_expect(
		(fixture["animation"] as Animation).loop_mode == Animation.LOOP_NONE,
		"a death clip must never loop, regardless of how it was authored"
	)
	world.queue_free()
	await process_frame


func _test_freeze_zero_momentum() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", _no_sounds(), Vector3.ZERO, 1
	)
	_expect(corpse.freeze, "an in-place death (zero momentum) must spawn frozen, never simulated")
	world.queue_free()
	await process_frame


func _test_simulate_nonzero_momentum() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Blow_Up_1")
	var momentum := Vector3(1.0, 6.0, 0.5)
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Blow_Up_1", _no_sounds(), momentum, 1
	)
	_expect(not corpse.freeze, "a thrown corpse must simulate physics, not spawn frozen")
	_expect(
		corpse.linear_velocity.is_equal_approx(momentum),
		"linear_velocity must start at the handed-off momentum"
	)
	world.queue_free()
	await process_frame


func _test_collision_layer_mask() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", _no_sounds(), Vector3.ZERO, 1
	)
	_expect(corpse.collision_layer == 4, "a corpse must sit on its own free bit (layer 4)")
	_expect(corpse.collision_mask == 1, "a corpse must only ever collide with terrain (mask 1)")
	world.queue_free()
	await process_frame


func _test_not_in_units_group() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", _no_sounds(), Vector3.ZERO, 1
	)
	_expect(
		not corpse.is_in_group("units"),
		"a corpse must never join the units group: selection and match_snapshot both filter by it"
	)
	world.queue_free()
	await process_frame


func _test_frees_on_animation_finished() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Shot_1", _no_sounds(), Vector3.ZERO, 1
	)
	_expect(not corpse.is_queued_for_deletion(), "a corpse must outlive its own spawn call")
	var player: AnimationPlayer = fixture["player"]
	player.animation_finished.emit(&"Shot_1")
	_expect(
		corpse.is_queued_for_deletion(),
		"a corpse with no sound to wait for must free the instant its death clip finishes"
	)
	world.queue_free()
	await process_frame


func _test_collision_shape_fits_model() -> void:
	var world := Node3D.new()
	root.add_child(world)

	var small_fixture := _make_model(&"Shot_1", Vector3(0.6, 1.8, 0.6))
	var small_corpse := DeathCorpseScript.spawn(
		world, small_fixture["model"], Transform3D.IDENTITY, &"Shot_1", _no_sounds(), Vector3.ZERO, 1
	)
	var large_fixture := _make_model(&"Explode", Vector3(3.0, 2.5, 5.0))
	var large_corpse := DeathCorpseScript.spawn(
		world, large_fixture["model"], Transform3D.IDENTITY, &"Explode", _no_sounds(), Vector3.ZERO, 1
	)

	var small_shape := (small_corpse.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	var large_shape := (large_corpse.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	_expect(small_shape != null and large_shape != null, "both corpses must have a box collision shape")
	if small_shape != null and large_shape != null:
		_expect(
			small_shape.size.is_equal_approx(Vector3(0.6, 1.8, 0.6)),
			"an infantry-sized model must produce a matching collider, got %s" % small_shape.size
		)
		_expect(
			large_shape.size.is_equal_approx(Vector3(3.0, 2.5, 5.0)),
			"a vehicle-sized model must produce a matching collider, got %s" % large_shape.size
		)
		_expect(
			not small_shape.size.is_equal_approx(large_shape.size),
			"two differently sized models must not collapse to the same collider"
		)

	world.queue_free()
	await process_frame


## Regression for the reported "vehicle death plays no sound" bug: at
## Godot's stock AudioStreamPlayer3D defaults (unit_size=10, unbounded
## max_distance), the inverse-distance falloff at this game's real camera
## distances (RTSCameraConfig puts the camera 17.5-300 world units from a
## dying unit across its zoom range — see death_sound_player.gd's derivation)
## is quiet enough to read as silence, not merely "a bit quiet". This checks
## the actual node both infantry and vehicle deaths share (DeathSoundPlayer)
## carries the widened tuning, so nothing can silently regress it back to
## the point-blank stock defaults. Not gated behind DeathCorpse's manifest
## lookup: both death paths construct exactly this class, so testing the
## class directly covers both without needing a real resolvable sound id.
func _test_death_sound_attenuation_tuned() -> void:
	var player := DeathSoundPlayerScript.new()
	_expect(
		player.unit_size > 10.0,
		"unit_size must be widened well past Godot's stock 10.0, or the sound is inaudible at normal play zoom, got %s" % player.unit_size
	)
	_expect(
		player.max_distance > 300.0,
		"max_distance must reach past the camera's farthest real distance (~300 units at max_zoom) so the sound never hard-cuts mid-falloff, got %s" % player.max_distance
	)
	_expect(
		player.attenuation_model == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE,
		"attenuation model must stay inverse-distance (a real, if gentler, distance cue), not disabled or squared, got %s" % player.attenuation_model
	)

	# playing an event must not reset the tuning back to class/script defaults.
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(player)
	await process_frame
	var event := SoundEventScript.new()
	event.sample_paths = ["res://assets/converted/audio/sfx/explosion_vehicle_2.wav"]
	event.volume = 80
	player.play_event(event)
	_expect(
		player.unit_size > 10.0 and player.max_distance > 300.0,
		"play_event() must not disturb the attenuation tuning set at construction"
	)
	world.queue_free()
	await process_frame


## The "one fire-sound voice per weapon" rule (CombatTurret.fire_sound_exclusive)
## rests on two things this class must provide: play_pool() handing back the
## player it started, so the caller can retire it later, and fade_out_and_free()
## ramping that player down instead of stopping it dead. A burst weapon calls
## the second one on every shot but the last, so it also has to be safe to call
## twice and safe to call on a player whose sample already ended.
func _test_fade_out_and_free() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var paths := ["res://assets/converted/audio/sfx/explosion_vehicle_2.wav"]
	var player: DeathSoundPlayer = DeathSoundPlayerScript.play_pool(
		world, Vector3.ZERO, paths, 80.0
	)
	_expect(
		player != null and player.playing,
		"play_pool() must return the started player so a single-voice caller can retire it"
	)
	var loud_db := player.volume_db
	player.fade_out_and_free()
	# Idempotent: a second retire must not restart the ramp from the original
	# gain, which would make the sample briefly loud again.
	player.fade_out_and_free()
	await process_frame
	await process_frame
	_expect(
		not is_instance_valid(player) or player.volume_db < loud_db,
		"a retired one-shot must ramp its gain down rather than jump-cut, got %s from %s" % [
			player.volume_db if is_instance_valid(player) else "freed", loud_db
		]
	)
	# The ramp is short (DeathSoundPlayer.FADE_OUT_SECONDS); give it real time
	# to run out and confirm the node then frees itself rather than lingering.
	await create_timer(DeathSoundPlayerScript.FADE_OUT_SECONDS + 0.2).timeout
	_expect(
		not is_instance_valid(player),
		"a retired one-shot must free itself once its fade finishes"
	)

	# The common case for a slow weapon: nothing is left playing by the time the
	# next shot retires it. That must free cleanly, not error on a tween.
	var idle := DeathSoundPlayerScript.new()
	world.add_child(idle)
	await process_frame
	idle.fade_out_and_free()
	await process_frame
	_expect(
		not is_instance_valid(idle),
		"retiring a player that never started must free it outright"
	)

	_expect(
		DeathSoundPlayerScript.play_pool(world, Vector3.ZERO, [], 100.0) == null,
		"play_pool() must return null when it had nothing to play"
	)
	world.queue_free()
	await process_frame


## A death clip can author more than one voice layer (TL_Contaminator's Burnt_1
## screams `burn_dying_*` and its own `contaminator_die_*`, see
## AuthoredDeathVoice), so the corpse must spawn one player per layer and
## outlive *all* of them — a second sound must not be cut off just because the
## first one, or the death clip, ended early.
func _test_two_sound_layers_both_played() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Explode")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Explode",
		_voice([[&"hkmedium1", 0.0], [&"medium", 0.0]]), Vector3.ZERO, 1
	)
	var players := _sound_players(corpse)
	_expect(players.size() == 2, "two resolved sound ids must spawn two players, got %d" % players.size())
	(fixture["player"] as AnimationPlayer).animation_finished.emit(&"Explode")
	_expect(not corpse.is_queued_for_deletion(), "the corpse must wait for its sounds, not just its clip")
	if players.size() == 2:
		players[0].sound_finished.emit()
		_expect(
			not corpse.is_queued_for_deletion(),
			"one finished layer must not free the corpse while the other is still playing"
		)
		players[1].sound_finished.emit()
	_expect(corpse.is_queued_for_deletion(), "the corpse must free once every layer has finished")
	world.queue_free()
	await process_frame


func _test_single_sound_layer() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Explode")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Explode",
		_voice([[&"medium", 0.0]]), Vector3.ZERO, 1
	)
	var players := _sound_players(corpse)
	_expect(players.size() == 1, "one resolved sound id must spawn exactly one player, got %d" % players.size())
	(fixture["player"] as AnimationPlayer).animation_finished.emit(&"Explode")
	_expect(not corpse.is_queued_for_deletion(), "the corpse must outlive its clip while its sound plays")
	if players.size() == 1:
		players[0].sound_finished.emit()
	_expect(corpse.is_queued_for_deletion(), "the corpse must free once its single sound finishes")
	world.queue_free()
	await process_frame


## An id the SFX-hook generator never produced must degrade to silence for that
## layer alone: it spawns no player and, crucially, never keeps the corpse
## alive waiting for a sound that will never start.
func _test_unresolvable_sound_layer_frees_promptly() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Explode")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Explode",
		_voice([[&"no_such_death_event", 0.0], [&"medium", 0.0]]), Vector3.ZERO, 1
	)
	var players := _sound_players(corpse)
	_expect(
		players.size() == 1,
		"an unresolvable id must spawn no player, leaving only the good layer's, got %d" % players.size()
	)
	(fixture["player"] as AnimationPlayer).animation_finished.emit(&"Explode")
	if players.size() == 1:
		players[0].sound_finished.emit()
	_expect(
		corpse.is_queued_for_deletion(),
		"a bad layer must never block the corpse from freeing once the real one finished"
	)
	world.queue_free()
	await process_frame


## Models author the scream partway into the clip (TL_Contaminator's Burnt_1
## puts `contaminator_die_*` 31 frames in), so a layer with a delay must not
## play at t=0 — and must still hold the corpse open across the wait, or a
## short clip would free the corpse before its own scream ever started.
func _test_delayed_sound_layer() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Burnt_1")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Burnt_1",
		_voice([[&"burningsmall", 0.0], [&"contaminatordying", 0.15]]), Vector3.ZERO, 1
	)
	_expect(
		_sound_players(corpse).size() == 1,
		"only the undelayed layer may have started, got %d players" % _sound_players(corpse).size()
	)
	(fixture["player"] as AnimationPlayer).animation_finished.emit(&"Burnt_1")
	_sound_players(corpse)[0].sound_finished.emit()
	_expect(
		not corpse.is_queued_for_deletion(),
		"the corpse must outlive both its clip and its first layer while a delayed layer is still pending"
	)
	await create_timer(0.3).timeout
	var players := _sound_players(corpse)
	_expect(
		players.size() == 2,
		"the delayed layer must have started once its offset elapsed, got %d players" % players.size()
	)
	if players.size() == 2:
		players[1].sound_finished.emit()
		_expect(
			corpse.is_queued_for_deletion(),
			"the corpse must free once the delayed layer finishes too"
		)
	world.queue_free()
	await process_frame


## A stand-in for one of ATHanger's MeshNN% nodes: a Node3D carrying the '%'
## original_name marker DeathCorpse._collect_debris_pieces() looks for, at a
## `transform` matching where the converter would bake it in the burnt husk.
func _make_debris_piece(piece_name: String, piece_transform: Transform3D) -> Node3D:
	var piece := Node3D.new()
	piece.name = piece_name
	piece.set_meta("original_name", "%s%%" % piece_name)
	piece.transform = piece_transform
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	mesh_instance.mesh = box
	piece.add_child(mesh_instance)
	return piece


func _test_debris_scatter_lands_and_holds_corpse_open() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Explode")
	var model: Node3D = fixture["model"]
	# piece_a sits low and off to one side, piece_b sits higher near the
	# other side — mirrors a husk's pieces spanning the building's height,
	# so DEBRIS_LANDING_HEIGHT_JITTER's "falls toward the lowest piece" claim
	# is actually exercised for piece_b.
	var piece_a := _make_debris_piece("Mesh01", Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, 0.0)))
	var piece_b := _make_debris_piece("Mesh02", Transform3D(Basis.IDENTITY, Vector3(-5.0, 8.0, 3.0)))
	model.add_child(piece_a)
	model.add_child(piece_b)
	var launch_a := piece_a.transform
	var launch_b := piece_b.transform

	# A resolvable, never-finished sound layer holds the corpse open
	# independent of scatter, so this can inspect the landed positions
	# without racing the corpse freeing (and freeing its children with it)
	# the instant the last piece lands.
	var corpse := DeathCorpseScript.spawn(
		world, model, Transform3D.IDENTITY, &"Explode", _voice([[&"medium", 0.0]]), Vector3.ZERO, 1, [], true
	)
	_expect(corpse._pending_scatter == 2, "both '%%' pieces must be counted as pending, got %d" % corpse._pending_scatter)
	_expect(
		piece_a.transform.is_equal_approx(launch_a) and piece_b.transform.is_equal_approx(launch_b),
		"the husk must render exactly as authored the instant the building dies — nothing may jump before its own tween starts"
	)

	(fixture["player"] as AnimationPlayer).animation_finished.emit(&"Explode")
	_expect(
		not corpse.is_queued_for_deletion(),
		"the corpse must outlive its death clip while debris is still mid-flight"
	)

	await create_timer(
		DeathCorpseScript.DEBRIS_MAX_FLIGHT_SECONDS + DeathCorpseScript.DEBRIS_MAX_STAGGER_SECONDS + 0.1
	).timeout
	_expect(corpse._pending_scatter == 0, "every piece must have landed by now, got %d still pending" % corpse._pending_scatter)
	_expect(
		not piece_a.transform.origin.is_equal_approx(launch_a.origin)
			and not piece_b.transform.origin.is_equal_approx(launch_b.origin),
		"pieces must fly away from where the husk placed them, not stay put"
	)
	_expect(
		piece_b.transform.origin.y < launch_b.origin.y,
		"a piece launched from higher up the husk than the rest must fall toward the ground line, got y=%.2f from y=%.2f" % [
			piece_b.transform.origin.y, launch_b.origin.y
		]
	)
	_expect(
		not corpse.is_queued_for_deletion(),
		"the sound layer must still hold the corpse open even though scatter itself has finished"
	)
	_sound_players(corpse)[0].sound_finished.emit()
	_expect(corpse.is_queued_for_deletion(), "the corpse must free once both scatter and sound have finished")
	world.queue_free()
	await process_frame


func _test_no_scatter_without_the_flag() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Shot_1")
	var model: Node3D = fixture["model"]
	var piece := _make_debris_piece("Mesh01", Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, 0.0)))
	model.add_child(piece)
	var original := piece.transform

	# scatter_debris omitted — Unit's call site never passes it, unlike
	# BuildingDeathSequence's.
	var corpse := DeathCorpseScript.spawn(
		world, model, Transform3D.IDENTITY, &"Shot_1", _no_sounds(), Vector3.ZERO, 1
	)
	_expect(corpse._pending_scatter == 0, "scatter must be entirely opt-in")
	_expect(piece.transform.is_equal_approx(original), "a '%' piece must be left untouched when scatter isn't requested")
	(fixture["player"] as AnimationPlayer).animation_finished.emit(&"Shot_1")
	_expect(corpse.is_queued_for_deletion(), "with no scatter pending, the corpse must free on the clip finishing as before")
	world.queue_free()
	await process_frame


func _test_scatter_with_no_debris_pieces() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var fixture := _make_model(&"Explode")
	var corpse := DeathCorpseScript.spawn(
		world, fixture["model"], Transform3D.IDENTITY, &"Explode", _no_sounds(), Vector3.ZERO, 1, [], true
	)
	_expect(corpse._pending_scatter == 0, "a model with no '%' children must never block on scatter")
	(fixture["player"] as AnimationPlayer).animation_finished.emit(&"Explode")
	_expect(corpse.is_queued_for_deletion(), "scatter_debris=true with nothing to scatter must free normally")
	world.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
