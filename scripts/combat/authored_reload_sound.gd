extends RefCounted

## Resolves the reload sound a model authors *inside* one of its own clips: the
## bolt being racked between two shots of a Fire clip, or the gun being loaded
## as a Kindjal/Mortar folds out.
##
## Like the death voices (scripts/units/authored_death_voice.gd) and the mech
## footsteps (scripts/units/unit_movement_sounds.gd), this is an XBF FX event of
## **type 9**: one SFX section name pinned to one frame, baked losslessly onto
## the model root by converters/model_bake_builder.gd as `xbf_fx_events` /
## `xbf_animation_entries`. Six models author one:
##
##     AT_Sniper_H0    Fire_0        [213..289] frame 258 -> Atsniperreload
##     AT_Sniper_H0    Lay_Down_Fire [290..331] frame 309 -> Atsniperreload
##     HK_Trooper_H0   Fire_0        [195..248] frame 237 -> HKreload
##     OR_AATrooper_H0 Fire_0                   frame 338 -> ORkobrareload
##     HK_Inkvine_H0   Fire_0                   frame  50 -> HKinkvinereload
##     AT_Kindjal_H0   Deployed_Fire [386..436] frame 429 -> FRwarriorreload
##     AT_Kindjal_H0   Deploy_Gun    [322..384] frame 374 -> Atsniperreload
##     OR_Mortar_H0    Deploy_Gun               frame  54 -> ORkobrareload
##
## `RELOAD_SECTIONS` is an allowlist rather than a denylist, and that is the
## whole point of this script: a fire clip's *other* type-9 events are the
## weapon's own shot sound (ATSingleShotRifle, HKBazookaLaunch1, Catapult, ...),
## which CombatTurret already plays from the turret definition's baked
## `fire_sound_paths`. Playing every event in the clip would double the gunfire
## on nine units whose authored section resolves to the same WAV the turret
## already fires.
##
## Unlike AuthoredDeathVoice there is no per-family dedupe and no generic
## fallback spelling: two reload events in one clip would mean the gun was
## loaded twice, and every real reload section resolves directly once
## tools/generate_voice_feedback.py shadow-proofs the two Atreides ones.

const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")
const XbfSoundEventResolverScript := preload(
	"res://scripts/audio/xbf_sound_event_resolver.gd"
)

## Mirrors AuthoredFireController.BAKED_MODEL_FRAMES_PER_SECOND: XBF frames are
## authored at a fixed 20 fps and the bake preserves that rate, so the times
## returned here are directly comparable with that controller's `shot_times`.
## Every SFX section that is a weapon reload, keyed casefolded. Derived
## mechanically from assets/raw_original_content/SFX/*.txt: these are all the
## sections whose `Sounds=` list is one of the two reload samples
## (`kindjal_infantry_reload_1`, `hk_rocket_trooper_reload_1`), plus the two
## ImportedSfx.txt entries that name a `$`-prefixed localization stub which was
## never converted.
##
## `hkinkvinereload` and `hkmissiletankreload` are those two stubs: they are
## listed because they *are* reloads by name and origin, and dropped at the end
## of schedule() because no file anywhere gives them a playable sample. Keeping
## them here rather than omitting them is what makes "authored but silent"
## visible instead of looking like an oversight.
##
## `sniperriflereload` and `kindjalcannonreload` are the real English sections
## for the AT sniper rifle and Kindjal cannon; no shipped model names either one
## (the models reached for `atsniperreload`/`frwarriorreload` instead), but the
## list follows the SFX data rather than the model survey so that it stays
## correct if a model is ever re-baked.
const RELOAD_SECTIONS := {
	&"atsniperreload": true,
	&"frwarriorreload": true,
	&"sniperriflereload": true,
	&"kindjalcannonreload": true,
	&"hkreload": true,
	&"orkobrareload": true,
	&"hkinkvinereload": true,
	&"hkmissiletankreload": true,
}


## `[{"section": StringName, "time": float}, ...]` for `clip`, ordered by
## authored frame. `time` is seconds from the start of the clip on the clip's
## own 20 fps timeline, so a caller compares it against whatever clock it
## already advances the clip with.
##
## `model_root` may be any node above the baked XBF root (the unit's visual
## root, a building's model root, ...); the meta-bearing node is found by
## walking down from it.
static func schedule(model_root: Node, clip: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in XbfSoundEventResolverScript.schedule(model_root, clip):
		var section := StringName(event.get("section", &""))
		if not RELOAD_SECTIONS.has(section):
			continue
		# A reload whose section resolved to no converted WAV is silent, exactly
		# as the original data says -- HK_Inkvine's `HKinkvinereload` has no
		# definition outside ImportedSfx.txt's unconverted stub.
		if not SfxSectionCatalogScript.has_section(section):
			continue
		result.append({
			"section": section,
			"time": float(event.get("time", 0.0)),
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["time"]) < float(b["time"])
	)
	return result
