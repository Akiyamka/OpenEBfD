class_name BuildingConstructionSound
extends RefCounted

## Construction-only playback for authored building XBF event timelines.
## Type-9 events carry the original SFX *section* name, so resolving through
## SfxSectionCatalog retains the original sample pool, Volume and Limit rather
## than reducing construction to a generic build sound.

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")
const XbfSoundEventResolverScript := preload(
	"res://scripts/audio/xbf_sound_event_resolver.gd"
)
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")

const CONSTRUCT_CLIP := &"construct"
const FREMEN_CAMP_ID := &"FRCamp"
const FREMEN_TENT_SECTION := &"frementent"


## Starts the construction timeline. Timers are deliberately tied to the
## SceneTree rather than an AnimationPlayer track: XBF frames are preserved as
## model metadata and the visual clip can live under a state wrapper.
static func play(building: Node3D) -> void:
	if building == null or not building.is_inside_tree():
		return
	var schedule := schedule_for(building.config_id, building, CONSTRUCT_CLIP)
	if schedule.is_empty():
		return
	var speed_scale := _construct_speed_scale(building)
	for entry in schedule:
		var section := StringName(entry.get("section", &""))
		var delay := float(entry.get("time", 0.0)) / speed_scale
		if delay <= 0.0:
			_play(building, section)
		else:
			building.get_tree().create_timer(delay).timeout.connect(_play.bind(building, section))


## Public for focused tests and for tools which need the authored schedule
## without creating AudioStreamPlayers. GeneralSFX.txt explicitly assigns
## FremenTent to the Fremen Camp construction animation; use it as a fallback
## for variants whose XBF table lacks that event.
static func schedule_for(
		building_id: StringName, model_root: Node, clip: StringName = CONSTRUCT_CLIP
	) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in XbfSoundEventResolverScript.schedule(model_root, clip):
		if SfxSectionCatalogScript.has_section(StringName(event.get("section", &""))):
			result.append(event)
	if building_id == FREMEN_CAMP_ID and clip == CONSTRUCT_CLIP \
			and not _has_section(result, FREMEN_TENT_SECTION):
		# Some Fremen camp variants have no usable FX table. Do not duplicate the
		# real FRCamp model's authored FremenTent event when it is present.
		result.append({"section": FREMEN_TENT_SECTION, "time": 0.0})
	return result


static func _construct_speed_scale(building: Node) -> float:
	var found := AuthoredModelScript.find_clip(
		AuthoredModelScript.animation_players(building), [CONSTRUCT_CLIP]
	)
	var player := found.get("player") as AnimationPlayer
	return maxf(absf(player.speed_scale), 0.01) if player != null else 1.0


static func _has_section(schedule: Array[Dictionary], wanted: StringName) -> bool:
	for entry in schedule:
		if StringName(entry.get("section", &"")) == wanted:
			return true
	return false


## A SceneTreeTimer can outlive the placed building when a match fixture tears
## down before an authored construction event fires. Keep the bound value
## untyped until validity is checked: Godot otherwise rejects the invalid
## Object before this callback can make that normal teardown a no-op.
static func _play(building_reference: Variant, section: StringName) -> void:
	if section.is_empty() or not is_instance_valid(building_reference):
		return
	var building := building_reference as Node3D
	if building == null or not building.is_inside_tree():
		return
	var parent := building.get_parent()
	if parent == null:
		return
	SfxSectionCatalogScript.play_at(parent, building.global_position, section)
