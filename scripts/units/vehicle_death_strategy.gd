class_name VehicleDeathStrategy
extends UnitDeathStrategy

## Death policy for every non-infantry unit (ground vehicles, mechs,
## aircraft): converted vehicle models carry exactly one death clip,
## `Explode`, regardless of the incoming damage type.

const ExplosionTierPools := preload("res://scripts/audio/explosion_tier_pools.gd")

const CANDIDATES: Array[StringName] = [&"Explode"]

## Every aircraft uses the medium pool. Ground units use the large pool unless
## they already have an explicit small explosion assignment. The original
## binary's per-unit tier has no source-data equivalent, so keep the small
## exceptions explicit and derive all other tiers from UnitDefinition.can_fly.
const SMALL_TIER_UNITS := {
	&"ATTrike": &"small",
	&"ATAPC": &"small",
	&"ORDustScout": &"small",
}


func death_animation_candidates(_cause: StringName, _deployed: bool) -> Array[StringName]:
	return CANDIDATES.duplicate()


## The size-tier boom, timed by the caller to `_spawn_death_explosion_effects`
## firing rather than corpse/clip start.
func death_vfx_sound_paths(config_id: StringName, can_fly: bool = false) -> Array[String]:
	var tier: StringName = SMALL_TIER_UNITS.get(
		config_id, &"medium" if can_fly else &"large"
	)
	return ExplosionTierPools.pool_for_tier(tier)


## Every Harkonnen vehicle gets an extra explosion_vehicle_* layer, every
## Ordos vehicle gets an extra explosionordos* layer, both unconditional and
## on top of whatever the size tier resolved to above. Driven by house_id
## (via `faction`, e.g. "Harkonnen"/"Ordos") rather than a hardcoded per-unit
## list, since this is true of every vehicle in those houses, not a handful
## of named exceptions. Atreides and every other faction get no extra layer.
func death_start_sound_paths(faction: StringName, _config_id: StringName) -> Array[String]:
	match faction:
		&"Harkonnen":
			return ExplosionTierPools.HARKONNEN_START.duplicate()
		&"Ordos":
			return ExplosionTierPools.ORDOS_START.duplicate()
		_:
			return []


## Always zero: the Explode clip is too short for added motion to read, and
## momentum for a flying unit's corpse comes from Unit inheriting velocity
## unconditionally for can_fly units, not from an impulse here (see
## Unit._begin_death_sequence).
func death_launch_impulse(_cause: StringName) -> Vector3:
	return Vector3.ZERO
