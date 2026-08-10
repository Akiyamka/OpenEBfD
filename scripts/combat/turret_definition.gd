class_name TurretDefinition
extends Resource

@export var config_id: StringName
@export var bullet_id: StringName
@export var next_joint_id: StringName
@export var reload_count: float
@export var muzzle_flash_id: StringName
@export_file("*.scn", "*.tscn") var muzzle_flash_scene_path: String
## Positional shot sound(s), resolved and baked in at convert time from the
## original SFX event whose section name matches this turret's config_id (or a
## documented manual alias for turrets with no such section). One is picked at
## random per shot via DeathSoundPlayer.play_pool(). Empty when no source
## sound could be identified. See docs/quirks.md.
@export var fire_sound_paths: Array[String] = []
## Authored SFX `Volume` (0-100) for the resolved fire sound event, applied as
## linear gain by DeathSoundPlayer.play_pool(). The original engine mixed
## every sample down from its own per-event volume; playing all of them back
## at an unscaled 100 clips or sounds harsh on samples authored hot and quiet
## (e.g. ornithopter_rocket_2.wav peaks at ~99% of full scale but is authored
## at Volume=60). Defaults to 100 (unscaled) when the source omitted it.
@export var fire_sound_volume: float = 100.0
## Whether this weapon owns a single fire-sound "voice": each shot retires the
## previous shot's still-playing sample (a short fade, see
## DeathSoundPlayer.fade_out_and_free) instead of layering on top of it, so only
## the last shot of a burst is heard in full.
##
## Weapons fire faster than their own sample is long — a 2s sample on a barrel
## that fires every 0.4s stacks five copies of the same mono file, which not
## only muddies the burst but sums almost coherently into clipping. Defaulted on
## because it is a no-op for anything slower than its sample: the previous
## player has already finished and freed itself, so there is nothing to retire.
## Opt out per turret (via TURRET_FIRE_SOUND_NON_EXCLUSIVE in
## tools/generate_unit_definitions.py, so a regeneration keeps it) for a weapon
## whose sample is deliberately meant to pile up.
@export var fire_sound_exclusive: bool = true
## All turret angles are normalized by the legacy converter to radians. Speeds
## are radians per 20 Hz rules update; limits and tolerances are radians.
@export var yaw_speed: float
@export var minimum_yaw: float = NAN
@export var maximum_yaw: float = NAN
@export var pitch_speed: float
@export var minimum_pitch: float = NAN
@export var maximum_pitch: float = NAN
@export var acceptable_yaw: float = deg_to_rad(1.0)
@export var acceptable_pitch: float = deg_to_rad(1.0)
@export var bullet_count: int = 1
## Zero leaves projectile timing to the authored fire animation.
@export var burst_shot_count: int = 0
## Rule ticks between launcher shots. Zero fires the configured burst together.
@export var burst_interval_ticks: float = 0.0
@export var disabled_when_deployed: bool
@export var disabled_when_undeployed: bool
