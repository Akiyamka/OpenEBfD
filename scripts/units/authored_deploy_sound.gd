extends RefCounted

## Selects only the fold-out/fold-back sounds from a combat-deploy model's
## type-9 timeline.  Reloads remain AuthoredReloadSound's responsibility.

const XbfSoundEventResolverScript := preload(
	"res://scripts/audio/xbf_sound_event_resolver.gd"
)
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")

const TRANSITION_SECTIONS := {
	&"ATKindjal": {
		&"Deploy_Gun": [&"kindjaldeploy"],
		&"Undeploy_Gun": [&"kindjalundeploy"],
	},
	&"ORMortar": {
		&"Deploy_Gun": [&"mortardeploy"],
		&"Undeploy_Gun": [&"mortarundeploy"],
	},
}
const KOBRA_ID := &"ORKobra"
const KOBRA_SECTION := &"klunkair.wav"


## Schedules the unit's own transition sounds.  Kindjal and Mortar retain
## their exact XBF frames; Kobra has no FX event/undeploy sample, so its one
## original KobraDeploy.wav starts at frame zero in either direction.
static func schedule(unit_id: StringName, model_root: Node, clip: StringName) -> Array[Dictionary]:
	if unit_id == KOBRA_ID and (clip == &"Deploy_Gun" or clip == &"Undeploy_Gun"):
		return _available([{ "section": KOBRA_SECTION, "time": 0.0 }])
	var wanted: Array = TRANSITION_SECTIONS.get(unit_id, {}).get(clip, [])
	if wanted.is_empty():
		return []
	var result: Array[Dictionary] = []
	for event in XbfSoundEventResolverScript.schedule(model_root, clip):
		if StringName(event.get("section", &"")) in wanted:
			result.append(event)
	return _available(result)


static func _available(authored_events: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event_value in authored_events:
		var event := event_value as Dictionary
		if SfxSectionCatalogScript.has_section(StringName(event.get("section", &""))):
			result.append(event)
	return result
