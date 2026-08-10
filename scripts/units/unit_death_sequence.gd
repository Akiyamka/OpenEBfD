class_name UnitDeathSequence
extends RefCounted

## Everything that happens between "health crossed zero" and the unit being
## freed: picking the death clip, handing the model to a corpse, inherited
## momentum, the rules-authored explosion and the sound layers around both.
##
## Holds the per-definition UnitDeathStrategy and nothing else — no model
## nodes, no tweens, no subscriptions. Neutralizing the model subtree stays on
## Unit.prepare_model_for_corpse(), which remains the single checklist for
## every field that caches a reference into it.

const InfantryDeathStrategyScript := preload("res://scripts/units/infantry_death_strategy.gd")
const VehicleDeathStrategyScript := preload("res://scripts/units/vehicle_death_strategy.gd")
const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")
const CombatImpactEffectScript := preload("res://scripts/combat/combat_impact_effect.gd")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")
const AuthoredDeathVoiceScript := preload("res://scripts/units/authored_death_voice.gd")

var _unit: CharacterBody3D
## Infantry and vehicles die differently enough (clip set, momentum, sound
## routing) that the difference is a strategy object rather than branches
## here; the choice follows the definition, which already reads
## unit_definition.infantry today. See unit_death_strategy.gd.
var _strategy: UnitDeathStrategy = null


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func dispose() -> void:
	_unit = null
	_strategy = null


func adopt_definition(unit_definition: Resource) -> void:
	if unit_definition == null:
		_strategy = null
		return
	_strategy = (
		InfantryDeathStrategyScript.new() if unit_definition.infantry
		else VehicleDeathStrategyScript.new()
	)


## Called on the killing blow instead of queue_free() directly. The unit is
## still freed the instant health crosses zero, exactly as before this
## feature — see the death-animation plan's "Core design decision" for why a
## `_dying` guard living through the animation was rejected (it would need
## mirroring across is_deploying()-style checks scattered through Unit,
## plus an explicit deselect UnitCommandController does not otherwise need).
## A corpse node is spawned in the unit's place only when an authored clip
## actually matches; otherwise this degrades byte-for-byte to today's
## behaviour so units without a death clip never regress.
##
## `previous_global_position` is passed in rather than read back off the unit:
## it is the facade's own per-physics-step bookkeeping, and this module is its
## consumer, not its owner.
func begin(cause: StringName, previous_global_position: Vector3) -> void:
	var candidates: Array[StringName] = (
		_strategy.death_animation_candidates(cause, _unit.is_deployed())
		if _strategy != null else []
	)
	var found: Dictionary = _unit.find_animation_clip(candidates)
	var player := found.get("player") as AnimationPlayer
	var clip := StringName(found.get("name", &""))
	var parent := _unit.get_parent()
	var visual_root: Node3D = _unit.visual_root
	var model := (
		visual_root.get_child(0) as Node3D
		if visual_root != null and visual_root.get_child_count() > 0 else null
	)
	var unit_definition: Resource = _unit.unit_definition
	if player == null or model == null or parent == null:
		# No corpse at all (no clip matched, or nothing to detach), but a
		# vehicle with a rules-authored explosion must still visually explode
		# — the death clip and the explosion FX are independent per the
		# original data (ExplosionType/ExplosionEffects vs Explode animation),
		# so losing one must not silently drop the other.
		var start_paths: Array[String] = (
			_strategy.death_start_sound_paths(_owner_faction_id(), _unit.config_id)
			if _strategy != null else []
		)
		DeathSoundPlayerScript.play_pool(parent, _unit.global_position, start_paths)
		spawn_explosion_effects(parent, _unit.global_position)
		_unit.queue_free()
		return

	# Resolved before the model is detached only for clarity of ordering — the
	# meta this reads travels with the subtree either way. See
	# AuthoredDeathVoice: the sounds belong to the clip that actually matched,
	# so this must follow find_animation_clip() rather than the death cause.
	var voice_schedule := AuthoredDeathVoiceScript.schedule(model, clip)

	var world_transform := visual_root.global_transform
	_unit.prepare_model_for_corpse(model)
	visual_root.remove_child(model)

	var launch_impulse: Vector3 = (
		_strategy.death_launch_impulse(cause) if _strategy != null else Vector3.ZERO
	)
	# Inherited momentum is a property of the death cause, not of body type
	# (death-animation plan, "Momentum policy"): Shot/Burn/Gassed clips are
	# authored in place and must drop whatever velocity the unit had, while a
	# flying unit's corpse must always fall regardless of what killed it.
	var carries_momentum: bool = (
		(unit_definition != null and unit_definition.can_fly)
		or not launch_impulse.is_zero_approx()
	)
	var momentum := Vector3.ZERO
	if carries_momentum:
		var physics_delta := _unit.get_physics_process_delta_time()
		var inherited_velocity := (
			(_unit.global_position - previous_global_position) / physics_delta
			if physics_delta > 0.0 else Vector3.ZERO
		)
		momentum = inherited_velocity + launch_impulse

	var owner_faction := _owner_faction_id()
	var start_paths: Array[String] = (
		_strategy.death_start_sound_paths(owner_faction, _unit.config_id)
		if _strategy != null else []
	)
	DeathCorpseScript.spawn(
		parent, model, world_transform, clip, voice_schedule, momentum,
		_unit.owner_player_id, start_paths,
	)
	spawn_explosion_effects(parent, world_transform.origin)
	_unit.queue_free()


## Spawns this unit's rules-authored death explosion (UnitDefinition's
## explosion_effect_ids, falling back to its single explosion_type_id —
## mirrors CombatBullet.explosion_effect_ids()) as a sibling of the dying
## unit, exactly like CombatProjectile._spawn_explosion_visuals(). Must never
## parent to the unit: it is freed the instant this call returns, which would
## take a child effect down with it. Infantry naturally get no effect here
## since their UnitDefinition carries no explosion ids at all — nothing
## unit-type-specific needed.
##
## Also plays the death strategy's VFX-timed sound layer
## (death_vfx_sound_paths(), vehicles' size-tier boom) right here rather than
## from DeathCorpse or attached to the CombatImpactEffect node itself: this
## is the one call site that already fires at "the explosion SFX is shown"
## for both branches of begin() (with a corpse and the early no-corpse return
## alike), so tying the sound to it directly is explicit rather than
## coincidental. It is deliberately NOT a child of the spawned
## CombatImpactEffect — that node's own Cleanup timer frees it after its
## (short, ~0.5s) visual lifetime, which would cut an explosion sample short;
## playing it as a parent-level fire-and-forget layer (DeathSoundPlayer.
## play_pool) instead lets it run to completion independent of the visual.
func spawn_explosion_effects(parent: Node, world_position: Vector3) -> void:
	var unit_definition: Resource = _unit.unit_definition
	if unit_definition == null or parent == null or not parent.is_inside_tree():
		return
	var vfx_sound_paths: Array[String] = (
		_strategy.death_vfx_sound_paths(_unit.config_id, unit_definition.can_fly) if _strategy != null else []
	)
	DeathSoundPlayerScript.play_pool(parent, world_position, vfx_sound_paths)
	for effect_id in explosion_effect_ids():
		var scene_path := String(unit_definition.explosion_scene_paths.get(effect_id, ""))
		if scene_path.is_empty():
			continue
		var scene := load(scene_path) as PackedScene
		if scene == null:
			continue
		var effect = CombatImpactEffectScript.new()
		parent.add_child(effect)
		if not effect.configure(effect_id, scene, world_position):
			effect.free()


## Mirrors CombatBullet.explosion_effect_ids(): an explicit effect list wins,
## falling back to the single ExplosionType id only when no effect list was
## authored, so a unit's death visual resolves its two Rules.txt fields the
## same way its own bullets already do.
func explosion_effect_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	var unit_definition: Resource = _unit.unit_definition
	if unit_definition == null:
		return result
	for value in unit_definition.explosion_effect_ids:
		var effect_id := StringName(value)
		if effect_id != &"" and effect_id not in result:
			result.append(effect_id)
	var primary_id: StringName = unit_definition.explosion_type_id
	if result.is_empty() and primary_id != &"":
		result.append(primary_id)
	return result


func _owner_faction_id() -> StringName:
	var roster_player = _unit.owner_player()
	if roster_player == null:
		return &""
	return roster_player.house_id
