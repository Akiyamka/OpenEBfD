class_name XbfSoundEventResolver
extends RefCounted

## Reads type-9 (SFX-section) events from one authored XBF clip.  The model
## bake stores frames globally, while AnimationPlayer clips start at zero; this
## resolver is the single place that turns the former into the latter.

const BAKED_MODEL_FRAMES_PER_SECOND := 20.0
const XBF_SOUND_EVENT_TYPE := 9


## `[{'section': StringName, 'time': float}, ...]`, in authored-frame order.
## An incomplete FX table intentionally produces no schedule: its missing tail
## is indistinguishable from a clip which genuinely contains no sound.
static func schedule(model_root: Node, clip: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if model_root == null or clip == &"":
		return result
	var fx_root := _find_fx_root(model_root)
	if fx_root == null or not bool(fx_root.get_meta("xbf_fx_events_complete", false)):
		return result

	var entries := fx_root.get_meta("xbf_animation_entries", []) as Array
	var clip_entry := _find_entry(entries, clip)
	if clip_entry.is_empty():
		return result
	var clip_start := int(clip_entry.get("start_frame", -1))
	var clip_end := int(clip_entry.get("end_frame", -1))
	if clip_start < 0 or clip_end < clip_start:
		return result

	for event_value: Variant in fx_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		if int(event.get("type", -1)) != XBF_SOUND_EVENT_TYPE:
			continue
		var frame := int(event.get("frame", -1))
		if frame < clip_start or frame > clip_end:
			continue
		# Shipped ranges can overlap.  The narrowest range containing the event
		# is its authored owner, rather than every wider neighbouring clip.
		if _has_tighter_entry(entries, frame, clip_end - clip_start):
			continue
		var section := _section_id(event)
		if section == &"":
			continue
		result.append({
			"section": section,
			"time": float(frame - clip_start) / BAKED_MODEL_FRAMES_PER_SECOND,
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["time"]) < float(b["time"])
	)
	return result


static func _find_fx_root(node: Node) -> Node:
	if node.has_meta("xbf_animation_entries") and node.has_meta("xbf_fx_events"):
		return node
	for child in node.get_children():
		var found := _find_fx_root(child)
		if found != null:
			return found
	return null


static func _find_entry(entries: Array, clip: StringName) -> Dictionary:
	var wanted := _normalized(String(clip))
	for entry_value: Variant in entries:
		var entry := entry_value as Dictionary
		if _normalized(String(entry.get("name", ""))).nocasecmp_to(wanted) == 0:
			return entry
	return {}


static func _has_tighter_entry(entries: Array, frame: int, width: int) -> bool:
	for entry_value: Variant in entries:
		var entry := entry_value as Dictionary
		var start_frame := int(entry.get("start_frame", -1))
		var end_frame := int(entry.get("end_frame", -1))
		if start_frame < 0 or end_frame < start_frame:
			continue
		if frame >= start_frame and frame <= end_frame and end_frame - start_frame < width:
			return true
	return false


static func _section_id(event: Dictionary) -> StringName:
	var strings := event.get("strings", []) as Array
	if strings.is_empty():
		return &""
	return StringName(String(strings[0]).strip_edges().to_lower())


static func _normalized(name: String) -> String:
	return name.strip_edges().replace(" ", "_")
