class_name SfxSectionCatalog
extends RefCounted

## Lookup for the original SFX sound-event sections, plus the `Limit` accounting
## the original engine applied to them.
##
## The voice/death hooks resolve at convert time into per-unit resources
## (`GeneratedVoiceManifest`), because the unit that owns them is known then.
## The sections this catalog serves cannot: a model's authored FX events (XBF
## event type 9) carry the section *name* as a string, and that name only
## surfaces at runtime from the baked model meta. So the whole section table is
## generated into `resources/audio/generated_sfx_manifest.gd` and looked up here
## by name, keyed casefolded because the source files spell the same section
## inconsistently between the model and the SFX text.

const GeneratedSfxManifest := preload("res://resources/audio/generated_sfx_manifest.gd")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")

## Number of instances of each section currently playing, keyed by casefolded
## section id. Static because `Limit` is documented in Sfx.txt as the maximum
## number of instances of an audio event type that can play SIMULTANEOUSLY --
## a global cap across every emitter, not a per-unit one. That global scope is
## what keeps a dozen walking Mongooses from stacking twelve copies of the same
## footstep sample; no separate throttle is needed on top of it.
static var _active_counts: Dictionary = {}

## ImportedSfx.txt shadows these two original Atreides definitions with `$`
## localization stubs, so the generated manifest deliberately cannot resolve
## them even though their converted sample is shipped. Keep this tiny source
## supplement here rather than editing generated audio data: both original
## sections use the same `kindjal_infantry_deploy_2` WAV, Volume=50 and the
## default Limit=5 (AtreidesSFX.txt).
const SOURCE_SECTION_SUPPLEMENTS := {
	# ImportedSfx.txt shadows these original building-construction sections with
	# untranslated `$` stubs. Their XBF type-9 events still name the originals,
	# so retain the source samples and per-house volumes here.
	&"atsmallconstruction": {
		"id": &"ATSmallConstruction",
		"paths": ["res://assets/converted/audio/sfx/mcv_f_scaffold_up_1.wav"],
		"controls": [&"random"], "volume": 60, "limit": 5, "priority": &"normal",
	},
	&"atmediumconstruction": {
		"id": &"ATMediumConstruction",
		"paths": ["res://assets/converted/audio/sfx/mcv_g_building_out_1.wav"],
		"controls": [&"random"], "volume": 60, "limit": 5, "priority": &"normal",
	},
	&"atlargeconstruction": {
		"id": &"ATLargeConstruction",
		"paths": ["res://assets/converted/audio/sfx/mcv_g_building_out_1.wav"],
		"controls": [&"random"], "volume": 60, "limit": 5, "priority": &"normal",
	},
	&"frementent": {
		"id": &"FremenTent",
		"paths": ["res://assets/converted/audio/sfx/fremen_tent_build_1.wav"],
		"controls": [&"random"], "volume": 80, "limit": 5, "priority": &"normal",
	},
	&"hksmallconstruction": {
		"id": &"HKSmallConstruction",
		"paths": ["res://assets/converted/audio/sfx/mcv_f_scaffold_up_1.wav"],
		"controls": [&"random"], "volume": 40, "limit": 5, "priority": &"normal",
	},
	&"hkmediumconstruction": {
		"id": &"HKMediumConstruction",
		"paths": ["res://assets/converted/audio/sfx/mcv_g_building_out_1.wav"],
		"controls": [&"random"], "volume": 40, "limit": 5, "priority": &"normal",
	},
	&"hklargeconstruction": {
		"id": &"HKLargeConstruction",
		"paths": ["res://assets/converted/audio/sfx/mcv_g_building_out_1.wav"],
		"controls": [&"random"], "volume": 40, "limit": 5, "priority": &"normal",
	},
	# The Barracks XBFs spell these without the SFX file's `S` infix. They are
	# aliases for the same house-specific construction-spark source sections.
	&"orconstructspark": {
		"id": &"ORConstructSpark",
		"paths": ["res://assets/converted/audio/sfx/constructionsparks.wav"],
		"controls": [&"random"], "volume": 40, "limit": 5, "priority": &"normal",
	},
	&"hkconstructspark": {
		"id": &"HKConstructSpark",
		"paths": ["res://assets/converted/audio/sfx/constructionsparks.wav"],
		"controls": [&"random"], "volume": 40, "limit": 5, "priority": &"normal",
	},
	&"kindjaldeploy": {
		"id": &"KindjalDeploy",
		"paths": ["res://assets/converted/audio/sfx/kindjal_infantry_deploy_2.wav"],
		"controls": [], "volume": 50, "limit": 5, "priority": &"normal",
	},
	&"kindjalundeploy": {
		"id": &"KindjalUnDeploy",
		"paths": ["res://assets/converted/audio/sfx/kindjal_infantry_deploy_2.wav"],
		"controls": [], "volume": 50, "limit": 5, "priority": &"normal",
	},
}


static func has_section(section_id: StringName) -> bool:
	var key := _key(section_id)
	return GeneratedSfxManifest.SECTIONS.has(key) or SOURCE_SECTION_SUPPLEMENTS.has(key)


## The generated section record, or an empty dictionary when the name is
## unknown. Sections that resolved to no converted WAV are absent from the
## manifest entirely rather than present-but-empty, so "unknown" and "silent"
## are the same answer here on purpose.
static func section(section_id: StringName) -> Dictionary:
	var key := _key(section_id)
	return GeneratedSfxManifest.SECTIONS.get(key, SOURCE_SECTION_SUPPLEMENTS.get(key, {}))


## Plays one sample of `section_id` positionally at `world_position`, honouring
## the section's `Control`, `Volume` and `Limit`. Returns the started player, or
## null when the section is unknown, the parent is not in the tree, or the
## section's `Limit` is already exhausted.
## Typed as AudioStreamPlayer3D, the DeathSoundPlayer base: this catalog sits
## low enough in the preload chain that the global `DeathSoundPlayer` class name
## is not resolvable yet when it is first compiled.
static func play_at(
	parent: Node, world_position: Vector3, section_id: StringName
) -> AudioStreamPlayer3D:
	var entry := section(section_id)
	if entry.is_empty():
		return null
	var paths: Array = entry.get("paths", [])
	if paths.is_empty():
		return null
	var key := _key(section_id)
	var limit := int(entry.get("limit", 0))
	if limit > 0 and int(_active_counts.get(key, 0)) >= limit:
		return null
	# Sfx.txt's `Control = random` picks any sample; without it the section
	# plays its first one. play_pool() randomises within the array it is given,
	# so the choice is made here and handed over as a single-element array.
	var sample_path: String = (
		paths.pick_random() if &"random" in Array(entry.get("controls", []))
		else paths.front()
	)
	var player := DeathSoundPlayerScript.play_pool(
		parent, world_position, [sample_path], float(entry.get("volume", 100))
	)
	if player == null:
		return null
	_active_counts[key] = int(_active_counts.get(key, 0)) + 1
	# `tree_exited`, not `finished`: play_pool() already frees the player when
	# the sample ends, and tree_exited additionally fires when the parent is
	# freed mid-sample, so a slot can never leak.
	player.tree_exited.connect(_release.bind(key))
	return player


## Drops all `Limit` bookkeeping. Tests only -- the counters are static, so a
## suite that leaves players alive would otherwise leak slots into the next one.
static func reset_active_counts() -> void:
	_active_counts.clear()


static func _release(key: StringName) -> void:
	var remaining := int(_active_counts.get(key, 0)) - 1
	if remaining > 0:
		_active_counts[key] = remaining
	else:
		_active_counts.erase(key)


static func _key(section_id: StringName) -> StringName:
	return StringName(String(section_id).strip_edges().to_lower())
