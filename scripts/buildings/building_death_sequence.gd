class_name BuildingDeathSequence
extends RefCounted

## Everything that happens between "a building's health crossed zero" and the
## building being freed: finding its authored Destroy clip, handing the model
## to a corpse, and the rules-authored explosion and sound around it. Mirrors
## UnitDeathSequence, simplified for buildings: no per-cause strategy object
## (a building has exactly one death clip candidate and one sound pool, no
## branching by damage type), no momentum/launch impulse (buildings never
## move), no voice schedule (AuthoredDeathVoice is infantry-specific).
##
## Holds the building reference and nothing else — no model nodes, no
## tweens, no subscriptions. Neutralizing the model subtree stays on
## Building.prepare_model_for_corpse(), which remains the single checklist
## for every field that caches a reference into it.

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")
const DeathCorpseScript := preload("res://scripts/effects/death_corpse.gd")
const CombatImpactEffectScript := preload("res://scripts/combat/combat_impact_effect.gd")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")
const ExplosionTierPoolsScript := preload("res://scripts/audio/explosion_tier_pools.gd")

## The one death clip candidate every converted Great House building carries
## under States/Destroy — see docs/quirks.md:1108-1129 for why Ordos's
## ConYard/Palace and the Guild Palace never shipped one (no source H3 model).
const DEATH_CLIP := &"Explode"

var _building: Node3D


func configure(building: Node3D) -> void:
	_building = building


func dispose() -> void:
	_building = null


## Called on the killing blow instead of queue_free() directly. The building
## is still freed the instant health crosses zero, exactly as before this
## feature. A corpse node is spawned in the building's place only when
## States/Destroy actually carries the Explode clip; otherwise this degrades
## byte-for-byte to today's behaviour (immediate queue_free()) except that a
## rules-authored explosion still plays — the death clip and the explosion FX
## are independent per the original data (ExplosionType/ExplosionEffects vs
## the Explode animation), so lacking one must not silently drop the other.
func begin() -> void:
	var destroy_node := _building.get_node_or_null("States/Destroy") as Node3D
	var players := AuthoredModelScript.animation_players(destroy_node)
	var found := AuthoredModelScript.find_clip(players, [DEATH_CLIP])
	var clip := StringName(found.get("name", &""))
	var parent := _building.get_parent()
	var states_node := (destroy_node.get_parent() as Node3D) if destroy_node != null else null

	if clip == &"" or states_node == null or parent == null:
		spawn_explosion_effects(parent, _building.global_position)
		_building.queue_free()
		return

	var world_transform := states_node.global_transform
	_building.prepare_model_for_corpse(destroy_node)
	states_node.remove_child(destroy_node)
	# States/Destroy is authored exactly like every other States child (Idle,
	# Damage1, ...): Building.play_state()'s visibility toggle hides every
	# child but the active one, and Destroy is never the active state through
	# any normal path, so it carries visible = false from the moment the
	# scene loads. Handing it to the corpse without correcting that leaves
	# the whole detached subtree invisible -- confirmed: every descendant
	# mesh/light under it is individually visible = true, only the node
	# itself was ever false. Nothing else ever flips this back for Destroy
	# specifically, unlike Idle/DamageN which play_state() visits normally.
	destroy_node.visible = true

	DeathCorpseScript.spawn(
		parent, destroy_node, world_transform, clip, [], Vector3.ZERO,
		_building.owner_player_id, [],
	)
	spawn_explosion_effects(parent, world_transform.origin)
	_building.queue_free()


## Spawns this building's rules-authored death explosion (BuildingDefinition's
## explosion_effect_ids, falling back to its single explosion_type_id —
## mirrors UnitDeathSequence.spawn_explosion_effects()/explosion_effect_ids())
## as a sibling of the dying building, and plays a random sample from the
## building-tier sound pool alongside it. Must never parent to the building:
## it is freed the instant this call returns, which would take a child effect
## down with it.
func spawn_explosion_effects(parent: Node, world_position: Vector3) -> void:
	var building_definition: Resource = _building.building_definition
	if building_definition == null or parent == null or not parent.is_inside_tree():
		return
	DeathSoundPlayerScript.play_pool(parent, world_position, ExplosionTierPoolsScript.BUILDING)
	for effect_id in explosion_effect_ids():
		var scene_path := String(building_definition.explosion_scene_paths.get(effect_id, ""))
		if scene_path.is_empty():
			continue
		var scene := load(scene_path) as PackedScene
		if scene == null:
			continue
		var effect = CombatImpactEffectScript.new()
		parent.add_child(effect)
		if not effect.configure(effect_id, scene, world_position):
			effect.free()


## Mirrors UnitDeathSequence.explosion_effect_ids(): an explicit effect list
## wins, falling back to the single ExplosionType id only when no effect list
## was authored, so a building's death visual resolves its two Rules.txt
## fields the same way a unit's or bullet's already does.
func explosion_effect_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	var building_definition: Resource = _building.building_definition
	if building_definition == null:
		return result
	for value in building_definition.explosion_effect_ids:
		var effect_id := StringName(value)
		if effect_id != &"" and effect_id not in result:
			result.append(effect_id)
	var primary_id: StringName = building_definition.explosion_type_id
	if result.is_empty() and primary_id != &"":
		result.append(primary_id)
	return result
