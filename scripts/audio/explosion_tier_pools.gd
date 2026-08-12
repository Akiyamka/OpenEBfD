class_name ExplosionTierPools
extends RefCounted

## Direct WAV pools for the vehicle death-explosion "size tier" system,
## bypassing the SoundEvent/GeneratedVoiceManifest machinery entirely.
##
## Why bypass the manifest: an earlier design (commit 105928f) tried to
## recover a *personal* per-unit death hook from the converted SFX text files
## (HarkonnenSFX.txt's `[hkmedium1]`/`[hksmall1]`/etc, commented as renamed
## from per-unit labels like `HarkAssaultTankDie`). Live-testing that design
## against the reference build falsified it outright: `HKAssault` actually
## played `explosion_large_3.wav` + `explosion_medium_5.wav` in the reference
## game, neither of which is in its supposed personal hook's sample list, and
## `HKBuzzsaw` played a sample that is not even in ITS OWN supposed hook.
## Conclusion (see docs/quirks.md): the original engine's per-unit death
## sample selection is hardcoded in the shipped binary and left no trace in
## any available asset — it is not recoverable, so this file replaces that
## whole indirection with a simple, user-specified three-tier size pool
## (small/medium/large), referencing converted WAV files directly.
##
## `explosion_medium_1.wav` is deliberately excluded from MEDIUM: it was
## renamed to `explosion_fire.wav` at convert time (see
## converters/convert_audio_bag.gd's RENAMED_ENTRIES) because that sample is
## actually the (not yet implemented) Inkvine special-ability sound, not a
## generic medium explosion.

const SFX_DIR := "res://assets/converted/audio/sfx/"

const SMALL: Array[String] = [
	SFX_DIR + "explosion_small_1.wav",
	SFX_DIR + "explosion_small_2.wav",
	SFX_DIR + "explosion_small_3.wav",
	SFX_DIR + "explosion_small_4.wav",
	SFX_DIR + "explosion_small_5.wav",
]
const MEDIUM: Array[String] = [
	SFX_DIR + "explosion_medium_2.wav",
	SFX_DIR + "explosion_medium_3.wav",
	SFX_DIR + "explosion_medium_4.wav",
	SFX_DIR + "explosion_medium_5.wav",
]
const LARGE: Array[String] = [
	SFX_DIR + "explosion_large_1.wav",
	SFX_DIR + "explosion_large_2.wav",
	SFX_DIR + "explosion_large_3.wav",
	SFX_DIR + "explosion_large_4.wav",
	SFX_DIR + "explosion_large_5.wav",
]

## The faction "start of death animation" extra layer: user-confirmed, every
## Harkonnen vehicle and every Ordos vehicle gets one of these on top of its
## size-tier boom, unconditionally. Atreides and every other faction get no
## extra layer.
const HARKONNEN_START: Array[String] = [
	SFX_DIR + "explosion_vehicle_1.wav",
	SFX_DIR + "explosion_vehicle_2.wav",
]
const ORDOS_START: Array[String] = [
	SFX_DIR + "explosionordos01.wav",
	SFX_DIR + "explosionordos02.wav",
	SFX_DIR + "explosionordos03.wav",
	SFX_DIR + "explosionordos04.wav",
	SFX_DIR + "explosionordos05.wav",
	SFX_DIR + "explosionordos06.wav",
]

## Building-death "size tier": the reference game's [Building(EvenLarger)]/
## [LargeBuildingBang] sample set (GeneralSFX.txt/AtreidesSFX.txt), used
## unconditionally for every building death — buildings have no faction-
## specific extra layer the way Harkonnen/Ordos vehicles do.
const BUILDING: Array[String] = [
	SFX_DIR + "bigxplosion01.wav",
	SFX_DIR + "bigxplosion02.wav",
	SFX_DIR + "bigxplosion04.wav",
	SFX_DIR + "bigxplosion09.wav",
	SFX_DIR + "bigxplosion17.wav",
]


static func pool_for_tier(tier: StringName) -> Array[String]:
	match tier:
		&"small":
			return SMALL.duplicate()
		&"large":
			return LARGE.duplicate()
		_:
			return MEDIUM.duplicate()
