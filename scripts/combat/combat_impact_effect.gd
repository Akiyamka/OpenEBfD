class_name CombatImpactEffect
extends Node3D

const AuthoredFxBankScript := preload("res://scripts/combat/fx/authored_fx_bank.gd")
const ImpactDebrisScript := preload("res://scripts/combat/fx/impact_debris.gd")

## Short-lived rules-backed impact presentation. Most ExplosionType XBFs are
## directly renderable. ShellHit and MissileHit are authored particle-emitter
## rigs: their `#bing` cubes are invisible moving anchors. In the XBF event
## table, record types 3/4 start and stop an FX bank; they are not animation
## frame numbers. What those two rigs actually draw lives in ImpactDebris.

const RULE_UPDATES_PER_SECOND := 20.0
const DEFAULT_DURATION := 0.5

var effect_id: StringName = &""
var _authored_visual: Node3D
var _debris := ImpactDebrisScript.new()


func _init() -> void:
	set_process(false)
	_debris.configure(self)


func configure(
		configured_effect_id: StringName,
		visual_scene: PackedScene,
		world_position: Vector3
	) -> bool:
	if visual_scene == null or not is_inside_tree():
		return false
	var visual := visual_scene.instantiate() as Node3D
	if visual == null:
		return false

	effect_id = configured_effect_id
	name = "ImpactEffect_%s" % String(effect_id)
	set_meta("combat_impact_fx", effect_id)
	top_level = true
	global_position = world_position
	_authored_visual = visual
	_authored_visual.name = "Visual"
	add_child(_authored_visual)

	var lifetime := DEFAULT_DURATION
	if ImpactDebrisScript.has_rig(effect_id):
		# An emitter rig's own geometry is the invisible anchors the FX bank
		# rides on, so nothing of the authored model itself may be drawn.
		_hide_emitter_geometry(_authored_visual)
		lifetime = maxf(_play_authored_animation_once(), ImpactDebrisScript.lifetime(effect_id))
		_debris.build(effect_id, _authored_visual)
	else:
		lifetime = _play_authored_animation_once()

	var cleanup := Timer.new()
	cleanup.name = "Cleanup"
	cleanup.one_shot = true
	cleanup.wait_time = lifetime
	add_child(cleanup)
	cleanup.timeout.connect(queue_free)
	cleanup.start()
	return true


## Only runs while the rig has billboards riding animated markers; the debris
## turns this back on when it spawns one, and reports when the last is gone.
func _process(_delta: float) -> void:
	if not _debris.advance_followers():
		set_process(false)


func _play_authored_animation_once() -> float:
	var lifetime := DEFAULT_DURATION
	var player := _authored_visual.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if player == null:
		return lifetime
	var animation_name := &"Stationary" if player.has_animation(&"Stationary") \
		else &"timeline"
	if not player.has_animation(animation_name):
		return lifetime
	var animation := player.get_animation(animation_name)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
		lifetime = maxf(animation.length, 1.0 / RULE_UPDATES_PER_SECOND)
		lifetime = minf(lifetime, _authored_fx_duration(lifetime))
	player.play(animation_name)
	return lifetime


## An effect's transform clip routinely outlasts its authored FX table: after
## the last texture-switch record its geometry is textured with an additive
## black frame and only keeps expanding invisibly. Ending on the authored last
## frame keeps the visual (and the node) from lingering for seconds.
func _authored_fx_duration(fallback: float) -> float:
	if _authored_visual == null:
		return fallback
	var last_frame := int(_authored_visual.get_meta("xbf_fx_last_event_frame", -1))
	if last_frame < 0:
		return fallback
	return maxf(float(last_frame + 1) / RULE_UPDATES_PER_SECOND, 1.0 / RULE_UPDATES_PER_SECOND)


func _hide_emitter_geometry(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).visible = false
	for child in node.get_children():
		_hide_emitter_geometry(child)
