class_name CombatLingerEffect
extends Node3D

## A delivered bullet may leave a target-bound payload after the projectile
## itself has finished. Rules.txt currently uses this for GasInf_B:
## LingerDuration is measured in combat ticks and LingerDamage is delivered
## once per tick through the bullet's normal warhead/armour matrix.
##
## "Combat ticks" here is the same 25 Hz domain MatchClock and
## Match._advance_simulation_tick() run: CombatRules.TICKS_PER_SECOND (25.0)
## and MatchClock.TICKS_PER_SECOND (25) are the same rate -- checked by
## reading both constants side by side, not assumed. Because the rates
## already match, driving remaining_ticks from sim_tick() below is an
## integer-isation of the old float-seconds accumulator, not a rate
## conversion: no authored LingerDuration changes meaning.

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")

## Match._advance_simulation_tick() drives every live effect's sim_tick() by
## walking this group, the same way it walks "units" and "buildings" -- see
## configure() below for why the effect requests it itself.
const SIM_LINGER_GROUP := "sim_linger_effects"

var bullet
var remaining_ticks := 0
var delivered_ticks := 0

var _target_ref: WeakRef
var _visual: Node3D


func _init() -> void:
	# Mirrors the group-membership guard on the sim half (see configure()):
	# an unconfigured effect must not run either half.
	set_process(false)


func configure(
		bullet_payload,
		target: Object,
		world_position: Vector3
	) -> bool:
	if bullet_payload == null \
	or bullet_payload.config == null \
	or bullet_payload.linger_duration_ticks() <= 0.0 \
	or bullet_payload.linger_damage() <= 0.0:
		return false

	bullet = bullet_payload
	remaining_ticks = maxi(int(ceilf(bullet.linger_duration_ticks())), 0)
	if remaining_ticks <= 0:
		return false
	name = "Linger_%s" % String(bullet.id())
	set_meta("combat_linger_effect", bullet.id())
	top_level = true
	global_position = world_position
	if target != null and is_instance_valid(target):
		_target_ref = weakref(target)
		_follow_target()
	_create_visual()
	# The effect finds Match's central loop, not the other way around: it
	# requests the sim group itself, right here, at the one point it becomes
	# live. This mirrors how units and buildings already join their groups
	# (Building.gd calls add_to_group("buildings") in code; unit scenes
	# declare "units" in their .tscn) so that Match._advance_simulation_tick()
	# keeps listing *systems*, never entities -- spawning a linger effect
	# needs no matching registration call anywhere else.
	#
	# As of slice C6b this is a request, not a join: MatchLookupScript.
	# request_sim_entry() queues it on the running Match's SimAdmissionQueue,
	# which admits it on the *next* tick's drain (Match._advance_simulation_tick(),
	# first statement) -- never this same tick, and never synchronously with
	# this call. A CombatProjectile's impact can configure() a fresh linger
	# effect from inside this same tick's "sim_projectiles" loop; that effect
	# now provably will not receive its first sim_tick() until the tick after,
	# where before C6b the loop order (linger effects walked before
	# projectiles) was what made that true instead.
	MatchLookupScript.request_sim_entry(self, SIM_LINGER_GROUP)
	set_process(true)
	return true


## This effect's simulation half: one call is one combat tick. Called from
## Match._advance_simulation_tick() via the SIM_LINGER_GROUP membership
## joined in configure() above -- never call this directly. See that
## function's doc comment for why linger effects resolve after units and
## buildings: a unit's reload advances before the gas that may kill it lands,
## every tick, on every client.
func sim_tick() -> void:
	if remaining_ticks <= 0:
		_finish()
		return
	var target := _target()
	if target == null or not _target_is_alive(target):
		_finish()
		return
	_deliver_tick(target)
	remaining_ticks -= 1
	delivered_ticks += 1
	if remaining_ticks <= 0 or not _target_is_alive(target):
		_finish()


## This effect's view half: rides the node onto its target's aim position.
## Deliberately stays on _process (frame delta), not sim_tick() -- the effect
## is meant to visibly track a moving target, and pinning it to the 25 Hz sim
## tick would make it visibly lag before the view layer starts interpolating
## between sim ticks in phase 3.
func _process(_delta: float) -> void:
	_follow_target()


func _deliver_tick(target: Object) -> void:
	if not target.has_method("combat_armour_type") \
	or not target.has_method("take_damage"):
		return
	var armour_type := StringName(String(target.call("combat_armour_type")))
	var damage: float = bullet.linger_damage_against(armour_type)
	if damage > 0.0:
		target.call("take_damage", damage, bullet.death_category())


func _target() -> Object:
	return _target_ref.get_ref() if _target_ref != null else null


func _target_is_alive(target: Object) -> bool:
	return CombatTargetScript.is_alive(target)


func _follow_target() -> void:
	var target := _target()
	if target == null:
		return
	if target.has_method("combat_aim_position"):
		var position: Variant = target.call("combat_aim_position")
		if position is Vector3 and (position as Vector3).is_finite():
			global_position = position


func _create_visual() -> void:
	if bullet.visual_scene == null:
		return
	_visual = bullet.visual_scene.instantiate() as Node3D
	if _visual == null:
		return
	_visual.name = "Visual"
	add_child(_visual)
	var player := _visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null:
		return
	var animation_name := &"Stationary" if player.has_animation(&"Stationary") \
		else &"idle" if player.has_animation(&"idle") \
		else &"Move" if player.has_animation(&"Move") \
		else &""
	if animation_name != &"":
		player.play(animation_name)


func _finish() -> void:
	set_process(false)
	# queue_free() does not drop group membership until the frame ends, so
	# leave the group explicitly here -- otherwise a finished effect could
	# still be listed by Match._advance_simulation_tick()'s SIM_LINGER_GROUP
	# loop and take one more tick before the deferred free actually lands.
	remove_from_group(SIM_LINGER_GROUP)
	if is_inside_tree() and not is_queued_for_deletion():
		queue_free()
