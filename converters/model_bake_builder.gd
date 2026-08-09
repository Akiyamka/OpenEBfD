class_name ModelBakeBuilder
extends RefCounted

const ModelXbfScript := preload("res://converters/xbf/model_xbf.gd")
const TextureImageUtilsScript := preload("res://converters/texture_image_utils.gd")

# Effect submeshes the original game toggles from gameplay code rather than
# from the baked animation: the leech parasite overlay and the energy shield
# (Unit shows it while `shields` > 0). They are baked hidden; gameplay code
# flips `visible` on the matching "Mesh" instance when the effect applies.
# Other FX (flashes, lightning, ...) are already driven by the animation
# tracks and must stay visible.
const EFFECT_NAME_MARKERS: PackedStringArray = ["leech", "shield"]
const COLLISION_OBJECT_NAME := "#~~0"
const MODEL_TEXTURE_DIR := "res://assets/raw_original_content/3DDATA/Textures"

var source_texture_dir := MODEL_TEXTURE_DIR
var texture_output_dir := ""
var fps := 20.0
var world_scale := 0.0625
# Unit/building muzzle meshes are hidden outside authored Fire clips. A
# standalone TurretMuzzleFlash XBF is itself the short-lived effect, so its
# `bigflash` geometry must retain the source visibility.
var bake_embedded_muzzle_flash_visibility := true
## Building # meshes referenced by XBF FX events are attachment markers, not
## model geometry. BuildingBakeBuilder enables this so their authored bank
## events become billboard effects in the packed state scenes.
var bake_attachment_bank_effects := false
var stationary_clip_loops := true

# Source frames between two animated-texture steps when the XBF carries no
# authored texture event for the object. Every FX record type 6 in the original
# content names an object and the exact TGA it switches to on a given frame, so
# the flipbook rate is normally read straight off that table (see
# _prepare_texture_events). Across all original Explosion/Buildings/Units/
# bullets XBFs those authored steps land 2 source frames apart in 1071 of 1494
# cases (1 frame in 353, everything else is a long-tail hold), so 2 frames is
# the authored default for the objects whose table entry is missing.
const TEXTURE_FX_SOURCE_FRAME_STEP := 2.0
# Record type in the FX event table meaning "this object now uses this texture".
const TEXTURE_EVENT_TYPE := 6
# Upper bound on a baked attachment emitter's particle budget. The authored
# burst-times-lifetime product stays far below it for every original bank; the
# clamp only guards against a mis-parsed record allocating an absurd buffer.
const MAX_ATTACHMENT_FX_PARTICLES := 256
# How far a fully-influenced particle wanders sideways over its lifetime, as a
# fraction of how far it travels along the plume. Raise for a looser, more
# dissipated plume.
const ATTACHMENT_FX_DRIFT_FRACTION := 0.25
const MIN_ANIMATION_AXIS_SCALE := 0.0001
# Normalized signed-volume threshold below which a mesh counts as authored
# inside-out (see _mesh_is_inside_out). Nearly flat or open meshes fall inside
# the +-threshold band and are never flipped.
const INSIDE_OUT_VOLUME_THRESHOLD := 0.001
const MIRRORED_CONTENT_NODE_NAME := "MirroredContent"
const LOCAL_Z_REFLECTION := Transform3D(
	Basis(Vector3.RIGHT, Vector3.UP, Vector3.FORWARD),
	Vector3.ZERO
)
const TEXTURE_PREFIX_MARKERS := "=@!%&"
const SUPPRESSED_MISSING_TEXTURES := {
	"at_wt_front64.tga": true,
}
## Per-texture pan direction/rate for _scrolling_texture_shader(), keyed by
## _texture_sequence_key(). Only needed where the shader's default
## (vec2(0.18, 0.0), i.e. along U) does not match how the source UVs are laid
## out on the geometry.
##
## The track belts are authored with U across the belt width and V along its
## travel direction (and with V already flipped on the rear plate, so one
## shared sign runs the whole belt the right way), hence the pan has to be on
## V, negative so the belt runs with the vehicle rather than against it. Its
## rate is per metre driven, not per second (see UnitShaderFx): the belt's V
## range of 2.0 covers ~1.37 world metres, so ~1.46 V per metre keeps the belt
## gripping the ground instead of slipping.
##
## HK_flame's fuel drum needs no entry: its U already wraps the drum's
## circumference, so the default pans it around the barrel axis.
const SCROLL_SPEED_OVERRIDES := {
	"at_st_tracks64.tga": Vector2(0.0, -1.46),
}
const HIDDEN_SOURCE_MESH_COMPONENTS := {
	"at_refinery_h0.xbf": {
		"at_refinery": {3: "broken_geometry", 10: "broken_geometry"},
	},
	# Ltmuzzle's authored `_laser` is a fixed-length beam. Runtime replaces it
	# with the resolved muzzle-to-impact segment while retaining the surrounding
	# coil and ring geometry as the weapon's authored muzzle accent.
	"ltmuzzle.xbf": {
		"?laser": {
			0: "procedural_laser_replacement",
			1: "procedural_laser_replacement",
		},
	},
	# See docs/quirks.md "OR Mortar ships a static duplicate gun barrel".
	"or_mortar_h0.xbf": {
		"mortorgun01": {0: "unrendered_duplicate"},
		"gunleg03": {0: "unrendered_duplicate"},
		"gunleg04": {0: "unrendered_duplicate"},
	},
}
## The deployed-mode fire clip is authored as "Fire 1" (weapon index 1 = the
## deployed turret) on every combat-deployable unit. Kindjal also ships an
## identical later "Deployed Fire"; both resolve to one canonical runtime name.
const CLIP_NAME_OVERRIDES := {
	"at_kindjal_h0.xbf": {"Fire_1": "Deployed_Fire"},
	"or_mortar_h0.xbf": {"Fire_1": "Deployed_Fire"},
	"or_kobra_h0.xbf": {"Fire_1": "Deployed_Fire"},
}
## Exclusive frame limits for source object-transform timelines whose
## unreferenced tail data is corrupt. Vertex animation and FX timelines keep
## their authored lengths; only object transforms beyond these limits are
## omitted.
const OBJECT_TRANSFORM_FRAME_LIMITS := {
	"hk_flamer_h0.xbf": 584,
}
## Objects whose stored static matrices are corrupt but whose animation
## timelines begin with a valid authored pose.
const STATIC_TRANSFORM_ANIMATION_FALLBACKS := {
	"hk_flamer_h0.xbf": {
		"!#box04": true,
		"!#box05": true,
		"!#box06": true,
		"!#box07": true,
		"gunbone": true,
		"!#box08": true,
		"!#box09": true,
		"!#box10": true,
		"!#box11": true,
	},
}
var missing_textures: PackedStringArray = []
var copied_textures: PackedStringArray = []
var _material_cache := {}
var _animated_texture_sequences := {}
var _animated_material_frames := {}
var _animated_material_frame_names := {}
var _scrolling_materials := {}
var _move_scrolling_materials := {}
var _pending_frame_tracks: Array[Dictionary] = []
var _texture_events_by_object := {}
var _animated_frame_shader_add: Shader
var _animated_frame_shader_mix: Shader
var _model_texture_shaders := {}
var _scrolling_texture_shaders := {}
var _shield_shader: Shader
var _has_shield_fx_marker := false
var _muzzle_flash_mesh_paths := PackedStringArray()
var _attachment_fx_paths := PackedStringArray()
var _attachment_fx_names := {}
var _source_file_name := ""
var _object_transform_frame_limit := 0


func build(xbf_path: String) -> PackedScene:
	_source_file_name = xbf_path.get_file().to_lower()
	_object_transform_frame_limit = int(
		OBJECT_TRANSFORM_FRAME_LIMITS.get(_source_file_name, 0)
	)
	missing_textures = PackedStringArray()
	copied_textures = PackedStringArray()
	_material_cache.clear()
	_animated_texture_sequences.clear()
	_animated_material_frames.clear()
	_animated_material_frame_names.clear()
	_scrolling_materials.clear()
	_move_scrolling_materials.clear()
	_pending_frame_tracks.clear()
	_texture_events_by_object.clear()
	_model_texture_shaders.clear()
	_scrolling_texture_shaders.clear()
	_has_shield_fx_marker = false
	_muzzle_flash_mesh_paths = PackedStringArray()
	_attachment_fx_paths = PackedStringArray()
	_attachment_fx_names.clear()

	var xbf = ModelXbfScript.load_file(xbf_path)
	if xbf == null:
		return null
	var animation_entries := _repaired_animation_entries(xbf.animation_entries)
	_prepare_animated_texture_sequences(xbf.fx_strings)
	_prepare_attachment_fx_names(xbf)
	_prepare_texture_events(xbf)

	var root := Node3D.new()
	root.name = _scene_name_from_path(xbf_path)
	root.scale = Vector3.ONE * world_scale
	# Keep the original FX definitions on the converted scene. Their event
	# frames determine burst particle counts, while bank parameter 06 supplies
	# particle size in source coordinates. Runtime effects can therefore use
	# authored data instead of unit-specific casing constants.
	var baked_fx_banks: Array = xbf.fx_banks.duplicate(true)
	for bank_value: Variant in baked_fx_banks:
		var bank := bank_value as Dictionary
		bank["world_particle_size"] = float(bank.get("particle_size", 0.0)) * world_scale
		# Source gravity is authored per squared 20 Hz update. Keep the signed
		# positive-down convention; runtime applies it along world DOWN.
		bank["world_gravity"] = float(bank.get("gravity", 0.0)) \
			* world_scale * 20.0 * 20.0
	root.set_meta("xbf_world_scale", world_scale)
	root.set_meta("xbf_fx_format_version", xbf.fx_format_version)
	root.set_meta("xbf_fx_bank_table_version", xbf.fx_bank_table_version)
	root.set_meta("xbf_fx_banks", baked_fx_banks)
	root.set_meta("xbf_fx_event_frame_count", xbf.fx_event_frame_count)
	root.set_meta("xbf_fx_event_object_count", xbf.fx_event_object_count)
	root.set_meta("xbf_fx_event_master", xbf.fx_event_master)
	root.set_meta("xbf_fx_event_counts", xbf.fx_event_counts)
	root.set_meta("xbf_fx_events", xbf.fx_events.duplicate(true))
	# The authored FX table stops well before the transform clip does on
	# one-shot effects: Explosion's last texture switch is source frame 18 of a
	# 50-frame Stationary, and the sphere it leaves behind is an additive-black,
	# invisible frame that merely keeps growing. Runtime effects use this to end
	# at the authored end instead of holding an invisible husk on screen.
	root.set_meta("xbf_fx_last_event_frame", _last_fx_event_frame(xbf))
	root.set_meta("xbf_fx_events_complete", xbf.fx_events_complete)
	# FX event frames are absolute in the source timeline. Store their clip
	# ranges under the same final names used by the baked AnimationLibrary.
	# Model-specific clip-name repairs therefore cover every authored FX bank
	# without leaking source-model quirks into runtime lookup.
	root.set_meta(
		"xbf_animation_entries",
		_baked_animation_entries(animation_entries)
	)
	# A small set of source files uses event payload variants that are not yet
	# decoded. Preserve the complete original block as well, so conversion is
	# lossless even when xbf_fx_events_complete is false.
	root.set_meta("xbf_fx_event_raw_data", xbf.fx_event_raw_data)

	var anim := Animation.new()
	anim.resource_name = "idle"
	anim.loop_mode = Animation.LOOP_LINEAR
	var max_frame := 1
	var clip_target_paths := _clip_target_paths(xbf.objects, animation_entries)

	var root_child_names := {}
	for object in xbf.objects:
		var child_name := _unique_sibling_node_name(
			String(object.name), root_child_names
		)
		var child := _build_object_node(
			object, xbf.textures, ".", anim, child_name
		)
		root.add_child(child)
		max_frame = maxi(max_frame, _object_animation_length(object))
	var attachment_fx: Array[Dictionary] = []
	if bake_attachment_bank_effects:
		attachment_fx = _build_attachment_bank_effects(root, xbf)
		max_frame = maxi(max_frame, xbf.fx_event_frame_count)

	# Build the library even when nothing produced a track: the FX table can
	# still declare a named entry (e.g. H3's "Explode", 50 frames) purely as a
	# duration/timing cue with no baked per-object motion, and dropping the
	# AnimationPlayer here would silently throw that duration away, collapsing
	# the state to ~1 frame downstream in BuildingBakeBuilder.
	if anim.get_track_count() > 0 or not _pending_frame_tracks.is_empty() \
	or not animation_entries.is_empty() or not attachment_fx.is_empty():
		anim.length = maxf(max_frame / fps, 1.0 / fps)
		_add_attachment_fx_tracks(anim, attachment_fx)
		_add_shader_fx_tracks(anim)
		var library := AnimationLibrary.new()
		for entry: Dictionary in animation_entries:
			var clip := _slice_animation(anim, entry, clip_target_paths)
			if clip != null:
				var clip_name := _clip_name(String(entry["name"]))
				# CLIP_NAME_OVERRIDES can make two distinct source entries
				# collide on one output name (e.g. Kindjal's authored
				# "Deployed Fire" and the renamed "Fire 1"). add_animation
				# refuses to overwrite, so the result would otherwise depend
				# on source entry order; remove any prior entry so the
				# override always wins deterministically.
				if library.has_animation(clip_name):
					library.remove_animation(clip_name)
				library.add_animation(clip_name, clip)
		_add_timeline_muzzle_flash_visibility(anim, animation_entries)
		library.add_animation("timeline", anim)
		var player := AnimationPlayer.new()
		player.name = "AnimationPlayer"
		player.add_animation_library("", library)
		player.autoplay = "Stationary" if library.has_animation("Stationary") else "timeline"
		root.add_child(player)

	_assign_scene_owner(root, root)

	var scene := PackedScene.new()
	var err := scene.pack(root)
	root.free()
	if err != OK:
		push_error("ModelBakeBuilder: could not pack model scene (%s)" % error_string(err))
		return null
	return scene


func _build_object_node(
		object: Dictionary,
		texture_names: PackedStringArray,
		node_path: String,
		anim: Animation,
		node_name: String,
		parent_parity := 1
	) -> Node3D:
	var node := Node3D.new()
	var raw_name := String(object.name)
	var uses_mirrored_content := _object_animation_is_consistently_mirrored(object)
	var parity := parent_parity * _object_parity(object, uses_mirrored_content)
	node.name = node_name
	node.set_meta("original_name", raw_name)
	if raw_name == COLLISION_OBJECT_NAME:
		node.set_meta("collision_mesh", true)
		# #~~0 is the root of the authored collision hierarchy. It commonly has
		# no vertices itself: its child objects contain the actual volume.
		node.set_meta("collision_points", _collision_points_from_hierarchy(object))
	node.transform = _to_godot_transform(_initial_object_transform(object))
	if uses_mirrored_content:
		# Godot's editor rejects a reflected Basis in a Transform3D animation
		# key even though Node3D and the renderer can represent it. Factor the
		# reflection out of every animated key and into a constant child node:
		# (T * F) * F == T. This preserves the source geometry exactly while
		# leaving the animation track with rotation-safe, positive determinants.
		node.transform *= LOCAL_Z_REFLECTION
	if _uses_static_transform_animation_fallback(object):
		# Match the animation-track representation exactly. Some otherwise
		# finite source matrices are too distorted to be valid rotation bases,
		# so merely selecting the first finite frame is not sufficient.
		node.transform = _sanitize_animation_transform(
			node.transform, Transform3D.IDENTITY
		)
	# Selection volumes and halo anchors are authored as vertex-only XBF
	# objects.  They have no triangles, so no MeshInstance3D is generated for
	# them; retain the data as metadata for gameplay visuals instead.
	if raw_name.to_lower().begins_with("slct"):
		node.set_meta("selection_bounds", _object_bounds(object.positions))
		# A few source models have no #~~0 root. Their SLCT object is still an
		# authored selection/collision volume, and is the runtime fallback.
		node.set_meta("collision_points", _collision_points(object.positions))
	# A few original models pad this marker with a trailing byte (for example
	# HK Engineer's "#^^0~").  The marker prefix is still unambiguous and
	# carries the same authored selection-halo attachment.
	elif raw_name.begins_with("#^^0"):
		node.set_meta("halo_anchor", true)
		node.set_meta("halo_anchor_bounds", _object_bounds(object.positions))
		# The marker's footprint is UI geometry: it stays constant while the
		# marker's authored position follows object animation. HK Missile
		# demonstrates why the static node transform is not a reliable size
		# source: its rest transform is identity, almost every animation frame
		# uses 0.451613 scale, and the terminal Stationary frame returns to
		# identity. Keep the first authored animated basis as the stable
		# footprint, independent of which frame is active when Unit becomes
		# ready.
		var reference_transform := _halo_anchor_reference_transform(object)
		var reference_node_transform := _to_godot_transform(reference_transform)
		if uses_mirrored_content:
			reference_node_transform *= LOCAL_Z_REFLECTION
		node.set_meta("halo_anchor_reference_basis", reference_node_transform.basis)
	var child_path: String = "%s/%s" % [node_path, node.name] if node_path != "." else node.name
	_add_animation_track(anim, child_path, object, uses_mirrored_content)

	var content_root := node
	var content_path := child_path
	if uses_mirrored_content:
		var mirrored_content := Node3D.new()
		mirrored_content.name = MIRRORED_CONTENT_NODE_NAME
		mirrored_content.transform = LOCAL_Z_REFLECTION
		node.add_child(mirrored_content)
		content_root = mirrored_content
		content_path = "%s/%s" % [child_path, MIRRORED_CONTENT_NODE_NAME]

	var flip_orientation := parity < 0 and _mesh_is_inside_out(object)
	var meshes := _build_object_mesh_components(object, texture_names, flip_orientation)
	for mesh_index in meshes.size():
		var mesh: ArrayMesh = meshes[mesh_index]
		if mesh.get_surface_count() == 0:
			continue
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "Mesh" if meshes.size() == 1 else "Mesh_%02d" % mesh_index
		mesh_instance.mesh = mesh
		# #~~0 is an authored collision volume, not visible model geometry.
		# Keep its mesh in the converted scene so Unit and Building can make
		# the matching physics shape at runtime.
		var is_muzzle_flash := _is_muzzle_flash_object(raw_name)
		var is_bank_attachment := _is_bank_attachment_object(raw_name)
		var hidden_source_quirk := _hidden_source_mesh_component_quirk(raw_name, mesh_index)
		mesh_instance.visible = not (
			_is_effect_object(raw_name)
			or (is_muzzle_flash and bake_embedded_muzzle_flash_visibility)
			or (is_bank_attachment and bake_attachment_bank_effects)
			or raw_name == COLLISION_OBJECT_NAME
			or not hidden_source_quirk.is_empty()
		)
		if not hidden_source_quirk.is_empty():
			mesh_instance.set_meta("source_asset_quirk", hidden_source_quirk)
		if raw_name == COLLISION_OBJECT_NAME:
			mesh_instance.set_meta("collision_mesh", true)
		content_root.add_child(mesh_instance)
		var mesh_path := "%s/%s" % [content_path, mesh_instance.name]
		if is_muzzle_flash and bake_embedded_muzzle_flash_visibility:
			_muzzle_flash_mesh_paths.append(mesh_path)
		# Vertex-animated objects deliberately remain a single component, so
		# each animation frame can still replace one complete ArrayMesh.
		_add_vertex_animation_track(anim, mesh_path, object, texture_names, flip_orientation)
		var atlas_frames := _mesh_animated_frame_count(mesh)
		if atlas_frames > 1:
			_pending_frame_tracks.append({
				"path": mesh_path,
				"frames": atlas_frames,
				"frame_names": _mesh_animated_frame_names(mesh),
				"object": raw_name,
			})
		if _mesh_has_scrolling_texture(mesh):
			# A scrolling UV phase has to keep advancing continuously while the
			# model is on screen; a baked animation track would snap back to 0
			# every time the (often sub-second) clip loops. So we only tag the
			# mesh here (as metadata - PackedScene.pack() does not persist
			# set_instance_shader_parameter overrides) and let the owning
			# Unit/Building drive fx_time every frame at runtime (mirrors
			# the energy-shield fx_time driver). Mirrored parts sharing one
			# scrolling texture (the two front spotlights, the two wind
			# blades) don't need an artificial direction flip here: their
			# source vertex positions are already authored as true mirror
			# images of each other, so one shared, uniform scroll direction
			# converges/diverges on its own from that geometry.
			mesh_instance.set_meta("scroll_fx", true)
		if _mesh_has_move_scrolling_texture(mesh):
			# Same runtime-driven fx_time as scroll_fx above, but the phase
			# comes from how far the vehicle has driven rather than from
			# elapsed time, so the track belt stops with the vehicle. Only
			# Unit drives this channel: buildings carrying the same track
			# texture (ATConYard, INMedicalWreck) stay static as before.
			mesh_instance.set_meta("scroll_fx_move", true)

	var child_names := _existing_child_names(content_root)
	for child_object: Dictionary in object.children:
		var child_name := _unique_sibling_node_name(
			String(child_object.name), child_names
		)
		var child := _build_object_node(
			child_object, texture_names, content_path, anim, child_name, parity
		)
		content_root.add_child(child)

	return node


func _halo_anchor_reference_transform(object: Dictionary) -> Transform3D:
	var object_animation: Dictionary = object.object_animation
	if object_animation.is_empty():
		return object.transform
	var frames: Dictionary = object_animation.get("frames", {})
	if frames.is_empty():
		return object.transform
	var frame_ids := frames.keys()
	frame_ids.sort()
	return frames[frame_ids[0]]


func _initial_object_transform(object: Dictionary) -> Transform3D:
	if not _uses_static_transform_animation_fallback(object):
		return object.transform
	var object_animation: Dictionary = object.object_animation
	var frames: Dictionary = object_animation.get("frames", {})
	if frames.is_empty():
		return object.transform
	var frame_ids := frames.keys()
	frame_ids.sort()
	for frame_id: int in frame_ids:
		if _object_transform_frame_limit > 0 \
		and frame_id >= _object_transform_frame_limit:
			break
		var frame := frames[frame_id] as Transform3D
		if frame.is_finite():
			return frame
	return object.transform


func _uses_static_transform_animation_fallback(object: Dictionary) -> bool:
	var fallback_names: Dictionary = STATIC_TRANSFORM_ANIMATION_FALLBACKS.get(
		_source_file_name, {}
	)
	return fallback_names.has(String(object.name))


## Sign of the object's own runtime transform: -1 when it mirrors its content.
## Consistently mirrored animations override the static basis because their
## keys replace it as soon as any clip plays.
func _object_parity(object: Dictionary, uses_mirrored_content: bool) -> int:
	if uses_mirrored_content:
		return -1
	return -1 \
		if _initial_object_transform(object).basis.determinant() < 0.0 \
		else 1


## Objects placed under a net-mirrored transform are frequently authored
## inside-out - vertex normals and winding both point into the volume - so the
## mirror turns them right side out (AT/OR ConYard treads, girderboxes,
## Imperial Barracks left legs). The source engine renders without back-face
## culling, so only their lighting was ever wrong. Godot flips culling for
## negative-determinant instances, which turns exactly these pre-compensated
## meshes inside out on screen, while correctly authored mirrored meshes
## (e.g. AT ConYard girderbox06) need no help. Detect the pre-compensated ones
## by normalized signed volume so the bake can restore true outward
## orientation. Callers must only apply this inside mirrored subtrees: an
## unrestricted sweep also flags concave debris meshes.
func _mesh_is_inside_out(object: Dictionary) -> bool:
	var positions: PackedVector3Array = object.positions
	var indices: PackedInt32Array = object.triangle_indices
	var triangle_textures: PackedInt32Array = object.triangle_textures
	if positions.is_empty():
		return false
	var rendered_triangles := 0
	for texture_index in triangle_textures:
		if texture_index != -1:
			rendered_triangles += 1
	if rendered_triangles < 4:
		return false
	var diagonal := _object_bounds(positions).size.length()
	if diagonal <= 0.0:
		return false

	var centroid := Vector3.ZERO
	for position in positions:
		centroid += position
	centroid /= positions.size()

	var volume := 0.0
	for i in triangle_textures.size():
		if triangle_textures[i] == -1:
			continue
		var a := positions[indices[i * 3]] - centroid
		var b := positions[indices[i * 3 + 1]] - centroid
		var c := positions[indices[i * 3 + 2]] - centroid
		volume += a.dot(b.cross(c)) / 6.0
	return volume / (diagonal ** 3) < -INSIDE_OUT_VOLUME_THRESHOLD


func _hidden_source_mesh_component_quirk(object_name: String, mesh_index: int) -> String:
	var source_quirks: Dictionary = HIDDEN_SOURCE_MESH_COMPONENTS.get(_source_file_name, {})
	var hidden_components: Dictionary = source_quirks.get(object_name.to_lower(), {})
	return String(hidden_components.get(mesh_index, ""))


func _build_object_mesh_components(object: Dictionary, texture_names: PackedStringArray, flip_orientation := false) -> Array[ArrayMesh]:
	# A number of building H0 files collapse otherwise independent authored
	# parts into one XBF object. AT Refinery's shell is the prominent case: 25
	# disconnected pieces became one 16-surface MeshInstance. Keep animated
	# vertex layouts intact, but restore static disconnected parts as separate
	# meshes while retaining every material surface within its own part.
	var unsplit: Array[ArrayMesh] = [_build_object_mesh(object, texture_names, PackedVector3Array(), PackedInt32Array(), flip_orientation)]
	var raw_name := String(object.name)
	if (
		not (object.vertex_animation as Dictionary).is_empty()
		or raw_name.begins_with("#")
		or _is_muzzle_flash_object(raw_name)
		or _is_effect_object(raw_name)
	):
		return unsplit

	var components: Array[PackedInt32Array] = _triangle_components(object.triangle_indices)
	if components.size() <= 1:
		return unsplit

	var meshes: Array[ArrayMesh] = []
	for triangle_ids: PackedInt32Array in components:
		meshes.append(_build_object_mesh(object, texture_names, PackedVector3Array(), triangle_ids, flip_orientation))
	return meshes


func _triangle_components(indices: PackedInt32Array) -> Array[PackedInt32Array]:
	var triangle_count := indices.size() / 3
	if triangle_count <= 1:
		var trivial: Array[PackedInt32Array] = []
		if triangle_count == 1:
			trivial.append(PackedInt32Array([0]))
		return trivial

	var triangles_by_vertex := {}
	for triangle_index in triangle_count:
		for corner in 3:
			var vertex_index := indices[triangle_index * 3 + corner]
			var adjacent: PackedInt32Array = triangles_by_vertex.get(vertex_index, PackedInt32Array())
			adjacent.append(triangle_index)
			triangles_by_vertex[vertex_index] = adjacent

	var visited := PackedByteArray()
	visited.resize(triangle_count)
	var components: Array[PackedInt32Array] = []
	for seed in triangle_count:
		if visited[seed] != 0:
			continue
		var component := PackedInt32Array()
		var pending := PackedInt32Array([seed])
		visited[seed] = 1
		while not pending.is_empty():
			var triangle_index := pending[pending.size() - 1]
			pending.resize(pending.size() - 1)
			component.append(triangle_index)
			for corner in 3:
				var vertex_index := indices[triangle_index * 3 + corner]
				for neighbor: int in triangles_by_vertex[vertex_index]:
					if visited[neighbor] == 0:
						visited[neighbor] = 1
						pending.append(neighbor)
		components.append(component)
	return components


func _object_bounds(positions: PackedVector3Array) -> AABB:
	if positions.is_empty():
		return AABB()
	var bounds := AABB(positions[0], Vector3.ZERO)
	for point in positions:
		bounds = bounds.expand(point)
	return bounds


func _collision_points(positions: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for point in positions:
		result.append(Vector3(point.x, point.y, -point.z))
	return result


func _collision_points_from_hierarchy(root_object: Dictionary) -> PackedVector3Array:
	var result := _collision_points(root_object.positions)
	for child: Dictionary in root_object.children:
		_append_collision_points(child, Transform3D.IDENTITY, result)
	return result


func _append_collision_points(object: Dictionary, parent_transform: Transform3D, result: PackedVector3Array) -> void:
	var transform: Transform3D = parent_transform * object.transform
	for point in object.positions:
		var transformed: Vector3 = transform * point
		result.append(Vector3(transformed.x, transformed.y, -transformed.z))
	for child: Dictionary in object.children:
		_append_collision_points(child, transform, result)


func _assign_scene_owner(node: Node, scene_root: Node) -> void:
	for child in node.get_children():
		child.owner = scene_root
		_assign_scene_owner(child, scene_root)


func _build_object_mesh(
		object: Dictionary,
		texture_names: PackedStringArray,
		animated_positions := PackedVector3Array(),
		triangle_ids := PackedInt32Array(),
		flip_orientation := false
	) -> ArrayMesh:
	var surfaces := {}
	var positions: PackedVector3Array = animated_positions if not animated_positions.is_empty() else object.positions
	var normals: PackedVector3Array = object.normals
	var indices: PackedInt32Array = object.triangle_indices
	var triangle_textures: PackedInt32Array = object.triangle_textures
	var uvs: PackedVector2Array = object.triangle_uvs

	var selected_triangles := triangle_ids
	if selected_triangles.is_empty():
		selected_triangles.resize(triangle_textures.size())
		for triangle_index in triangle_textures.size():
			selected_triangles[triangle_index] = triangle_index
	for i in selected_triangles:
		var texture_index := triangle_textures[i]
		if texture_index == -1:
			continue
		if not surfaces.has(texture_index):
			surfaces[texture_index] = {
				"positions": PackedVector3Array(),
				"normals": PackedVector3Array(),
				"uvs": PackedVector2Array(),
				"indices": PackedInt32Array(),
				"corner_lookup": {},
			}
		var surface: Dictionary = surfaces[texture_index]
		for corner in 3:
			var vertex_index := indices[i * 3 + corner]
			var uv: Vector2 = uvs[i * 3 + corner]
			# Deduplicate corners sharing the same source vertex and UV so the
			# surface is indexed. The key must not depend on position, so the
			# layout stays identical across vertex animation frames.
			var corner_key := [vertex_index, uv]
			var lookup: Dictionary = surface.corner_lookup
			var packed_index: int = lookup.get(corner_key, -1)
			if packed_index == -1:
				packed_index = surface.positions.size()
				lookup[corner_key] = packed_index
				var position: Vector3 = positions[vertex_index]
				position.z = -position.z
				var normal: Vector3 = normals[vertex_index]
				normal.z = -normal.z
				surface.positions.append(position)
				surface.normals.append(normal.normalized())
				surface.uvs.append(uv)
			surface.indices.append(packed_index)

	var mesh := ArrayMesh.new()
	var texture_indices := surfaces.keys()
	texture_indices.sort()
	for texture_index: int in texture_indices:
		var surface: Dictionary = surfaces[texture_index]
		if flip_orientation:
			_flip_surface_orientation(surface)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surface.positions
		arrays[Mesh.ARRAY_NORMAL] = surface.normals
		arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
		arrays[Mesh.ARRAY_INDEX] = surface.indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var surface_index := mesh.get_surface_count() - 1
		var texture_name := texture_names[texture_index] if texture_index < texture_names.size() else ""
		mesh.surface_set_name(surface_index, texture_name)
		mesh.surface_set_material(surface_index, _model_material(texture_name))
	return mesh


func _flip_surface_orientation(surface: Dictionary) -> void:
	var indices: PackedInt32Array = surface.indices
	for i in range(0, indices.size(), 3):
		var swap := indices[i + 1]
		indices[i + 1] = indices[i + 2]
		indices[i + 2] = swap
	var normals: PackedVector3Array = surface.normals
	for i in normals.size():
		normals[i] = -normals[i]


func _model_material(texture_name: String) -> Material:
	if _material_cache.has(texture_name):
		return _material_cache[texture_name]

	var texture_path := _ensure_model_texture(texture_name)
	var texture: Texture2D = null
	var additive := _is_additive_texture(texture_name)
	var animated_frames := _animated_texture_frames(texture_name, additive)
	var team_colored := _uses_team_color(texture_name)
	if not animated_frames.is_empty():
		var animated_texture := _load_animated_texture_atlas(animated_frames)
		if animated_texture != null:
			var animated_material := ShaderMaterial.new()
			animated_material.shader = _animated_frame_shader(additive)
			animated_material.set_shader_parameter("albedo_atlas", animated_texture)
			animated_material.set_shader_parameter("frame_count", float(animated_frames.size()))
			animated_material.set_shader_parameter("use_team_color", team_colored)
			_animated_material_frames[animated_material] = animated_frames.size()
			_animated_material_frame_names[animated_material] = animated_frames
			_material_cache[texture_name] = animated_material
			return animated_material
	if not texture_path.is_empty():
		texture = _load_png_texture(texture_path)
	if _is_animated_shield_texture(texture_name) and texture != null:
		var shield_material := ShaderMaterial.new()
		shield_material.shader = _animated_shield_shader()
		shield_material.set_shader_parameter("albedo_tex", texture)
		shield_material.set_shader_parameter("use_team_color", team_colored)
		# Not added to _scrolling_materials: Unit already drives the
		# shield's fx_time by name match (and only while shields are up), so
		# tagging it here too would double-write the same parameter.
		_material_cache[texture_name] = shield_material
		return shield_material
	if _is_scrolling_texture(texture_name) and texture != null:
		var scrolling_material := ShaderMaterial.new()
		scrolling_material.shader = _scrolling_texture_shader(additive)
		scrolling_material.set_shader_parameter("albedo_tex", texture)
		scrolling_material.set_shader_parameter("use_team_color", team_colored)
		var scroll_speed: Variant = SCROLL_SPEED_OVERRIDES.get(
			_texture_sequence_key(texture_name)
		)
		if scroll_speed != null:
			scrolling_material.set_shader_parameter("scroll_speed", scroll_speed)
		if _is_move_scrolling_texture(texture_name):
			_move_scrolling_materials[scrolling_material] = true
		else:
			_scrolling_materials[scrolling_material] = true
		_material_cache[texture_name] = scrolling_material
		return scrolling_material
	if team_colored and texture != null:
		var team_material := ShaderMaterial.new()
		team_material.shader = _model_texture_shader(additive, _uses_alpha_channel(texture_name), _texture_has_alpha(texture))
		team_material.set_shader_parameter("albedo_tex", texture)
		team_material.set_shader_parameter("use_team_color", true)
		_material_cache[texture_name] = team_material
		return team_material

	var material := StandardMaterial3D.new()
	material.roughness = 0.85
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if additive:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	elif _uses_alpha_channel(texture_name) and _texture_has_alpha(texture):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	elif _texture_has_alpha(texture):
		# Magenta colour key is a 1-bit mask in the original TGA loader.
		# Alpha scissor keeps these textures in the opaque pass.
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = 0.5

	if texture != null:
		material.albedo_texture = texture
	else:
		material.albedo_color = Color.from_hsv(float(texture_name.hash() % 360) / 360.0, 0.45, 0.85)
	_material_cache[texture_name] = material
	return material


func _prepare_animated_texture_sequences(fx_strings: Array[Dictionary]) -> void:
	var groups := {}
	var group_bases := {}
	for record: Dictionary in fx_strings:
		var value := String(record.get("value", ""))
		if value.contains("{SHIELD}"):
			_has_shield_fx_marker = true
		var file_name := value.get_file()
		if not file_name.to_lower().ends_with(".tga"):
			continue
		for digit_range: Vector2i in _digit_ranges(file_name):
			var prefix := file_name.substr(0, digit_range.x)
			var suffix := file_name.substr(digit_range.y)
			if prefix.is_empty() or suffix.is_empty():
				continue
			var key := "%s#%s" % [_texture_sequence_key(prefix), _texture_sequence_key(suffix)]
			if not groups.has(key):
				groups[key] = {}
				group_bases[key] = "%s%s" % [prefix, suffix]
			var frame_number := int(file_name.substr(digit_range.x, digit_range.y - digit_range.x))
			groups[key][frame_number] = file_name

	for key in groups.keys():
		var group: Dictionary = groups[key]
		var frame_numbers: Array = group.keys()
		frame_numbers.sort()
		if frame_numbers.size() < 1:
			continue
		var first_frame := int(frame_numbers[0])
		var last_frame := int(frame_numbers[-1])
		if last_frame - first_frame + 1 != frame_numbers.size():
			continue

		var frames := PackedStringArray()
		if first_frame == 1:
			var base_name := String(group_bases[key])
			if _fx_texture_name_exists(base_name, fx_strings):
				frames.append(base_name)
		for frame_number in frame_numbers:
			frames.append(String(group[frame_number]))
		if frames.size() < 2:
			continue
		for frame_name in frames:
			_animated_texture_sequences[_texture_sequence_key(String(frame_name))] = frames


func _digit_ranges(value: String) -> Array[Vector2i]:
	var ranges: Array[Vector2i] = []
	var index := 0
	while index < value.length():
		var code := value.unicode_at(index)
		if code < 48 or code > 57:
			index += 1
			continue
		var start := index
		while index < value.length():
			code = value.unicode_at(index)
			if code < 48 or code > 57:
				break
			index += 1
		ranges.append(Vector2i(start, index))
	return ranges


func _fx_texture_name_exists(texture_name: String, fx_strings: Array[Dictionary]) -> bool:
	var expected := _texture_sequence_key(texture_name)
	for record: Dictionary in fx_strings:
		if _texture_sequence_key(String(record.get("value", "")).get_file()) == expected:
			return true
	return false


## The "%" marker is the usual declaration that a texture is one frame of a
## sequence, but the standalone muzzle flashes do not carry it: gplasglow's
## mesh references a bare "!Gbang1.tga" and devmuzzle's a bare "!bang0.tga",
## while each model's own type-6 events step that object through the full
## "!Gbang0..9"/"!bang0..9" run, one frame per source frame. Without a second
## way in, those bake as a single frozen frame of a ten-frame blast -- a dense
## mid-explosion still that reads as a solid blob rather than a flash. So an
## unmarked texture is also accepted when this model's own texture events
## actually walk its sequence, which is the same ground truth
## _authored_frame_keys() already resolves the resulting track against.
##
## `event_driven` keeps that second way in to additive ("!") textures, which is
## where the frozen-frame flipbooks live: blast and flash sheets whose meshes
## exist only to show the sequence. Ordinary model surfaces stay on the marker
## alone. The unmarked leech-infestation overlay ("@Leeched_128.tga" plus
## "@Leeched1/2_128.tga", stepped by four events on every leechable unit) is
## the case this deliberately excludes -- it is a lit surface on the hull, and
## the atlas shader would turn it unshaded and depth-write-free.
func _animated_texture_frames(
	texture_name: String, event_driven := false
	) -> PackedStringArray:
	var frames: PackedStringArray = _animated_texture_sequences.get(
		_texture_sequence_key(texture_name.get_file()), PackedStringArray()
	)
	if frames.is_empty() or _is_animated_texture(texture_name):
		return frames
	if not event_driven or not _texture_events_step_sequence(frames):
		return PackedStringArray()
	return frames


## True when some object's authored texture events name more than one frame of
## `frames`. A single event is a one-off texture assignment, not a flipbook,
## and must not turn a static texture into an animated atlas.
func _texture_events_step_sequence(frames: PackedStringArray) -> bool:
	var frame_keys := {}
	for frame_name in frames:
		frame_keys[_texture_sequence_key(frame_name.get_file())] = true
	for events_value: Variant in _texture_events_by_object.values():
		var stepped := {}
		for event: Dictionary in events_value as Array:
			var key := _texture_sequence_key(String(event["texture"]).get_file())
			if frame_keys.has(key):
				stepped[key] = true
		if stepped.size() > 1:
			return true
	return false


func _load_animated_texture_atlas(frame_names: PackedStringArray) -> Texture2D:
	var images: Array[Image] = []
	for frame_name in frame_names:
		var frame_path := _ensure_model_texture(frame_name)
		if frame_path.is_empty():
			return null
		var image := _load_png_image(frame_path)
		if image == null:
			return null
		if not images.is_empty() and image.get_size() != images[0].get_size():
			push_warning("ModelBakeBuilder: animated texture frame %s has mismatched size" % frame_name)
			return null
		images.append(image)
	if images.is_empty():
		return null

	var width := images[0].get_width()
	var height := images[0].get_height()
	var atlas := Image.create_empty(width, height * images.size(), false, Image.FORMAT_RGBA8)
	for i in images.size():
		atlas.blit_rect(images[i], Rect2i(Vector2i.ZERO, images[i].get_size()), Vector2i(0, i * height))
	return ImageTexture.create_from_image(atlas)


func _animated_frame_shader(additive: bool) -> Shader:
	if additive and _animated_frame_shader_add != null:
		return _animated_frame_shader_add
	if not additive and _animated_frame_shader_mix != null:
		return _animated_frame_shader_mix

	var shader := Shader.new()
	# The frame index comes from an AnimationPlayer track instead of TIME:
	# TIME in a shader forces the editor 3D viewport to redraw continuously,
	# which starves the GPU while the editor is open next to a running game.
	shader.code = """
shader_type spatial;
render_mode %s unshaded, cull_disabled, depth_draw_never;

instance uniform float fx_frame : instance_index(1) = 0.0;
instance uniform vec4 team_color : instance_index(0) = vec4(0.12, 0.44, 1.0, 1.0);
uniform sampler2D albedo_atlas : source_color;
uniform bool use_team_color = false;
uniform float frame_count = 1.0;
uniform float alpha_floor = 0.32;
uniform float alpha_softness = 0.16;

vec3 apply_team_color(vec3 rgb) {
	if (!use_team_color) {
		return rgb;
	}
	float blue_dominance = rgb.b - max(rgb.r, rgb.g);
	float mask = smoothstep(0.08, 0.35, blue_dominance) * smoothstep(0.10, 0.35, rgb.b);
	float shade = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, team_color.rgb * shade, mask * team_color.a);
}

void fragment() {
	float frame = mod(floor(fx_frame + 0.5), frame_count);
	vec2 atlas_uv = vec2(UV.x, (UV.y + frame) / frame_count);
	vec4 color = texture(albedo_atlas, atlas_uv);
	float alpha = smoothstep(alpha_floor, alpha_floor + alpha_softness, color.a);
	if (alpha <= 0.01) {
		discard;
	}
	ALBEDO = apply_team_color(color.rgb) * alpha;
	ALPHA = alpha;
}
""" % ("blend_add," if additive else "")
	if additive:
		_animated_frame_shader_add = shader
	else:
		_animated_frame_shader_mix = shader
	return shader


func _animated_shield_shader() -> Shader:
	if _shield_shader != null:
		return _shield_shader
	_shield_shader = Shader.new()
	# fx_time is driven by Unit while the shield is up (a continuous phase
	# cannot come from sliced animation tracks — it would snap on clip loops),
	# and must not be TIME: TIME in a shader forces the editor 3D viewport to
	# redraw continuously (see the animated-frame shader above).
	_shield_shader.code = """
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;

instance uniform float fx_time : instance_index(1) = 0.0;
instance uniform vec4 team_color : instance_index(0) = vec4(0.12, 0.44, 1.0, 1.0);
uniform sampler2D albedo_tex : source_color;
uniform bool use_team_color = false;
uniform float scroll_speed = 0.225;
uniform float secondary_scroll_speed = -0.11;
uniform float pulse_speed = 1.3;
uniform float pulse_amount = 0.25;

vec3 apply_team_color(vec3 rgb) {
	if (!use_team_color) {
		return rgb;
	}
	float blue_dominance = rgb.b - max(rgb.r, rgb.g);
	float mask = smoothstep(0.08, 0.35, blue_dominance) * smoothstep(0.10, 0.35, rgb.b);
	float shade = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, team_color.rgb * shade, mask * team_color.a);
}

void fragment() {
	vec2 uv_a = UV + vec2(0.0, fx_time * scroll_speed);
	vec2 uv_b = UV.yx + vec2(fx_time * secondary_scroll_speed, 0.0);
	vec4 primary = texture(albedo_tex, uv_a);
	vec4 secondary = texture(albedo_tex, uv_b);
	vec3 color = max(primary.rgb, secondary.rgb * 0.65);
	float alpha = max(primary.a, secondary.a * 0.7);
	float pulse = 1.0 + sin(fx_time * pulse_speed) * pulse_amount;
	ALBEDO = apply_team_color(color) * pulse;
	ALPHA = alpha;
}
"""
	return _shield_shader


func _model_texture_shader(additive: bool, alpha_blend: bool, has_alpha: bool) -> Shader:
	var key := "%s:%s:%s" % [additive, alpha_blend, has_alpha]
	if _model_texture_shaders.has(key):
		return _model_texture_shaders[key]

	var render_modes := PackedStringArray()
	if additive:
		render_modes.append("blend_add")
		render_modes.append("unshaded")
		render_modes.append("cull_disabled")
		render_modes.append("depth_draw_never")
	elif alpha_blend:
		render_modes.append("blend_mix")
		render_modes.append("cull_disabled")
	elif has_alpha:
		render_modes.append("cull_disabled")

	var render_line := ""
	if not render_modes.is_empty():
		render_line = "render_mode %s;\n" % ", ".join(render_modes)

	var fragment_alpha := ""
	if additive or alpha_blend:
		fragment_alpha = "\tif (color.a <= 0.01) {\n\t\tdiscard;\n\t}\n\tALBEDO = apply_team_color(color.rgb) * color.a;\n\tALPHA = color.a;\n"
	else:
		var discard_threshold := 0.5 if has_alpha else 0.01
		fragment_alpha = "\tif (color.a <= %.2f) {\n\t\tdiscard;\n\t}\n\tALBEDO = apply_team_color(color.rgb);\n" % discard_threshold

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
%s
instance uniform vec4 team_color : instance_index(0) = vec4(0.12, 0.44, 1.0, 1.0);
uniform sampler2D albedo_tex : source_color;
uniform bool use_team_color = false;

vec3 apply_team_color(vec3 rgb) {
	if (!use_team_color) {
		return rgb;
	}
	float blue_dominance = rgb.b - max(rgb.r, rgb.g);
	float mask = smoothstep(0.08, 0.35, blue_dominance) * smoothstep(0.10, 0.35, rgb.b);
	float shade = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, team_color.rgb * shade, mask * team_color.a);
}

void fragment() {
	vec4 color = texture(albedo_tex, UV);
%s}
""" % [render_line, fragment_alpha]
	_model_texture_shaders[key] = shader
	return shader


func _scrolling_texture_shader(additive: bool) -> Shader:
	if _scrolling_texture_shaders.has(additive):
		return _scrolling_texture_shaders[additive]

	var shader := Shader.new()
	var render_mode := "blend_add, unshaded, cull_disabled, depth_draw_never" if additive else "blend_mix, cull_disabled"
	shader.code = """
shader_type spatial;
render_mode %s;

instance uniform float fx_time : instance_index(1) = 0.0;
instance uniform vec4 team_color : instance_index(0) = vec4(0.12, 0.44, 1.0, 1.0);
uniform sampler2D albedo_tex : source_color;
uniform bool use_team_color = false;
uniform vec2 scroll_speed = vec2(0.18, 0.0);

vec3 apply_team_color(vec3 rgb) {
	if (!use_team_color) {
		return rgb;
	}
	float blue_dominance = rgb.b - max(rgb.r, rgb.g);
	float mask = smoothstep(0.08, 0.35, blue_dominance) * smoothstep(0.10, 0.35, rgb.b);
	float shade = max(max(rgb.r, rgb.g), rgb.b);
	return mix(rgb, team_color.rgb * shade, mask * team_color.a);
}

void fragment() {
	vec4 color = texture(albedo_tex, UV + scroll_speed * fx_time);
	if (color.a <= 0.01) {
		discard;
	}
	ALBEDO = apply_team_color(color.rgb) * color.a;
	ALPHA = color.a;
}
""" % render_mode
	_scrolling_texture_shaders[additive] = shader
	return shader


func _ensure_model_texture(texture_name: String) -> String:
	if texture_name.is_empty():
		return ""

	var clean_file := texture_name.get_file()
	if clean_file.get_extension().is_empty():
		clean_file += ".tga"

	var output_path := ""
	if not texture_output_dir.is_empty():
		output_path = texture_output_dir.path_join(clean_file)
		if ResourceLoader.exists(output_path) or FileAccess.file_exists(ProjectSettings.globalize_path(output_path)):
			return output_path

	if source_texture_dir.is_empty():
		missing_textures.append(texture_name)
		return ""

	var source_path := source_texture_dir.path_join(clean_file)
	if not ResourceLoader.exists(source_path) and not FileAccess.file_exists(source_path):
		source_path = _find_source_texture_case_insensitive(clean_file)
	if not FileAccess.file_exists(source_path):
		if not _is_suppressed_missing_texture(texture_name):
			missing_textures.append(texture_name)
		return ""
	if texture_output_dir.is_empty():
		return source_path

	var output_abs := ProjectSettings.globalize_path(output_path)
	var err := DirAccess.make_dir_recursive_absolute(output_abs.get_base_dir())
	if err != OK:
		push_error("ModelBakeBuilder: could not create %s (%s)" % [output_abs.get_base_dir(), error_string(err)])
		return ""
	err = DirAccess.copy_absolute(source_path, output_abs)
	if err != OK:
		push_error("ModelBakeBuilder: could not copy %s to %s (%s)" % [source_path, output_abs, error_string(err)])
		return ""
	copied_textures.append(output_path)
	return output_path


func _find_source_texture_case_insensitive(clean_file: String) -> String:
	if source_texture_dir.is_empty():
		return ""

	var expected := clean_file.to_lower()
	var dir := DirAccess.open(source_texture_dir)
	if dir == null:
		return ""

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.to_lower() == expected:
			dir.list_dir_end()
			return source_texture_dir.path_join(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	return ""


func _load_png_texture(path: String) -> Texture2D:
	var image := _load_png_image(path)
	if image == null:
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _load_png_image(path: String) -> Image:
	var image: Image = TextureImageUtilsScript.load_image_with_magenta_alpha(path)
	if image == null:
		push_warning("ModelBakeBuilder: could not load texture image %s" % path)
	return image


func _is_additive_texture(texture_name: String) -> bool:
	return _texture_has_prefix(texture_name, "!")


func _uses_team_color(texture_name: String) -> bool:
	return _texture_has_prefix(texture_name, "=")


func _uses_alpha_channel(texture_name: String) -> bool:
	return _texture_has_prefix(texture_name, "@")


func _is_animated_texture(texture_name: String) -> bool:
	return _texture_has_prefix(texture_name, "%")


func _is_scrolling_texture(texture_name: String) -> bool:
	var file_name := texture_name.get_file().to_lower()
	# The construction yards' tread-belt texture has no "%" marker, but its
	# UVs need to scroll continuously to show the belt running. (Despite the
	# name it is not used by the Buzzsaw unit at all - only by the AT/HK/OR
	# ConYards.)
	if file_name == "hk_buzzsawtread_64.tga":
		return true
	# HK_flame's fuel drum ("cyl01"): the reference game pans this texture to
	# make the drum look like it is spinning. No "%" marker in the source data.
	if file_name == "hk_flametank_64.tga":
		return true
	if _is_move_scrolling_texture(texture_name):
		return true
	# The windtrap's "front2" texture ("AT_WT_Front2_64.tga",
	# "%HK_WT_Front2_128.tga", "or_wt_front2_128.tga", ...) is what the
	# spotlight beam meshes use and is meant to scroll, but only AT/OR carry
	# no "%" marker on it in the source data (HK's copy happens to have one).
	# The base building shell also references a *different*, unmarked
	# "front" texture without the "2" (e.g. "AT_WT_Front64.tga",
	# "hk_wt_front128.tga") that must stay static, so match specifically on
	# "front2" rather than "front".
	if file_name.contains("front2"):
		return true
	if not _is_animated_texture(texture_name):
		return false
	# "spotlight.tga" carries the "%" marker but is a static light-cone
	# cutout, not a panning texture - "%" on a lone (non-sequence) file
	# is evidently reused for more than one purpose in the source data,
	# so this one is excluded rather than assumed to scroll.
	if file_name.contains("spotlight"):
		return false
	# Same reuse of the "%" marker on muzzle-flash cutouts ("!%flash01.tga" and
	# "!%flash02.tga" on HKGunTurret/AT_Kindjal/AT_Sniper/HK_Engineer/
	# HK_airgun/OR_Mortar, "!%FireFlash0.tga", "!%@Flash2.tga"). A flash is a
	# still cutout the model reveals for a few frames -- the unmarked flash
	# cutouts in the same role ("!5flash03.tga", "!FFlash2.tga") bake as plain
	# additive materials and are what these must match. Panning them makes the
	# texture visibly crawl across the flash while the gun fires, most obvious
	# on HKGunTurret, whose Fire clip scales the flash up ~60x. Beams and
	# coils ("!%lascoil.tga", "!%LTRing.tga", "!%SonicMuzzle.tga",
	# "!%Bluelightning_128.tga") are deliberately not matched here: those are
	# panning effects.
	if file_name.contains("flash"):
		return false
	return true


## Vehicle track belts ("AT_ST_tracks64.tga" and its 32/underscored variants).
## Also unmarked in the source data, but unlike every other panning texture
## their phase must only advance while the vehicle is actually driving, so they
## get their own runtime driver (see Unit's UnitShaderFx) instead of the
## time-based one. Buildings that carry the same texture (ATConYard,
## INMedicalWreck) have no such driver, so their belts stay static as before.
func _is_move_scrolling_texture(texture_name: String) -> bool:
	return texture_name.get_file().to_lower().begins_with("at_st_tracks")


func _is_suppressed_missing_texture(texture_name: String) -> bool:
	return bool(SUPPRESSED_MISSING_TEXTURES.get(_texture_sequence_key(texture_name), false))


func _texture_has_prefix(texture_name: String, marker: String) -> bool:
	return _texture_prefixes(texture_name).contains(marker)


func _texture_prefixes(texture_name: String) -> String:
	var file_name := texture_name.get_file()
	var prefixes := ""
	for i in file_name.length():
		var marker := file_name.substr(i, 1)
		if not TEXTURE_PREFIX_MARKERS.contains(marker):
			break
		prefixes += marker
	return prefixes


func _texture_sequence_key(texture_name: String) -> String:
	var file_name := texture_name.get_file()
	var index := 0
	while index < file_name.length() and TEXTURE_PREFIX_MARKERS.contains(file_name.substr(index, 1)):
		index += 1
	return file_name.substr(index).to_lower()


func _texture_has_alpha(texture: Texture2D) -> bool:
	if texture == null:
		return false
	var image := texture.get_image()
	if image == null:
		return true
	return image.detect_alpha() != Image.ALPHA_NONE


func _is_effect_object(object_name: String) -> bool:
	var lower := object_name.to_lower()
	for marker in EFFECT_NAME_MARKERS:
		if lower.contains(marker):
			return true
	return false


func _is_muzzle_flash_object(object_name: String) -> bool:
	var lower := object_name.to_lower()
	# HK_Trooper_H0 ships with the misspelled `flah~?` object instead of the
	# usual bigflash name. It has the same tiny idle scale and expands only in
	# Fire_0, so treat it as authored embedded muzzle-flash geometry too.
	return lower.contains("bigflash") \
		or (_source_file_name == "hk_trooper_h0.xbf" and lower.begins_with("flah"))


func _prepare_attachment_fx_names(xbf) -> void:
	var bank_ids := {}
	for bank: Dictionary in xbf.fx_banks:
		bank_ids[String(bank.get("id", ""))] = true
	for event: Dictionary in xbf.fx_events:
		var attachment := String(event.get("attachment", ""))
		if attachment.begins_with("#") \
		and bank_ids.has(String(event.get("bank_id", ""))):
			_attachment_fx_names[attachment.to_lower()] = true


func _is_bank_attachment_object(object_name: String) -> bool:
	return _attachment_fx_names.has(object_name.to_lower())


func _build_attachment_bank_effects(root: Node3D, xbf) -> Array[Dictionary]:
	var banks_by_id := {}
	for bank: Dictionary in xbf.fx_banks:
		banks_by_id[String(bank.get("id", ""))] = bank
	var grouped_events := {}
	for event: Dictionary in xbf.fx_events:
		var attachment := String(event.get("attachment", ""))
		if not attachment.begins_with("#"):
			continue
		var bank_id := String(event.get("bank_id", ""))
		if not banks_by_id.has(bank_id):
			continue
		var key := "%s\n%s" % [attachment, bank_id]
		if not grouped_events.has(key):
			grouped_events[key] = []
		(grouped_events[key] as Array).append(event)

	var result: Array[Dictionary] = []
	for key: String in grouped_events:
		var separator := key.find("\n")
		var attachment := key.substr(0, separator)
		var bank_id := key.substr(separator + 1)
		var marker := _find_original_node(root, attachment)
		if marker == null:
			continue
		var bank := banks_by_id[bank_id] as Dictionary
		var meshes := _attachment_fx_mesh_frames(bank)
		if meshes.is_empty():
			continue
		var emitter := _build_attachment_fx_emitter(bank) if _fx_bank_emits(bank) else null
		var visual: GeometryInstance3D = emitter
		if visual == null:
			var billboard := MeshInstance3D.new()
			billboard.mesh = meshes[0]
			visual = billboard
		visual.name = _unique_sibling_node_name("AttachmentFX", _existing_child_names(marker))
		visual.visible = false
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		visual.set_meta("xbf_fx_attachment", attachment)
		visual.set_meta("xbf_fx_bank_id", bank_id)
		visual.set_meta("xbf_fx_texture", String(bank.get("texture", "")))
		visual.set_meta("xbf_fx_particle_size", float(bank.get("particle_size", 0.0)))
		visual.set_meta(
			"xbf_fx_world_particle_size",
			float(bank.get("particle_size", 0.0)) * world_scale
		)
		marker.add_child(visual)
		var path := String(root.get_path_to(visual))
		_attachment_fx_paths.append(path)
		result.append({
			"path": path,
			# An emitter drives its own flipbook through the particle material,
			# so it must not also get a per-frame :mesh track.
			"meshes": meshes if emitter == null else ([] as Array[QuadMesh]),
			"events": grouped_events[key],
			"lifetime": emitter.lifetime if emitter != null else 0.0,
		})
	return result


## An FX bank is a particle emitter whenever it authors motion: an initial speed
## or a gravity (a negative gravity is the buoyancy that makes fire and smoke
## rise). The banks with neither - the landing lights and warning flashes, whose
## particles would be pinned to the marker anyway - really are the single
## billboard the marker holds, and stay one.
func _fx_bank_emits(bank: Dictionary) -> bool:
	var words := bank.get("parameter_words", PackedInt32Array()) as PackedInt32Array
	if words.size() < 16:
		return false
	var speeds := bank.get("float_parameters_4_6", PackedFloat32Array()) as PackedFloat32Array
	var speed := float(speeds[0]) if speeds.size() > 0 else 0.0
	return not is_zero_approx(speed) \
		or not is_zero_approx(float(bank.get("gravity", 0.0)))


## Rebuilds a motion bank as the particle stream it is in the original data.
## Baking it as one static billboard instead (the previous behaviour) left a
## damaged building with a single motionless fire sprite where the source emits
## a whole rising column, which is why building damage FX read as barely there.
func _build_attachment_fx_emitter(bank: Dictionary) -> GPUParticles3D:
	var frame_names := _attachment_fx_frame_names(bank)
	var atlas := _load_animated_texture_atlas(frame_names) if frame_names.size() > 1 else null
	if atlas == null:
		var texture_path := _ensure_model_texture(frame_names[0]) if not frame_names.is_empty() else ""
		if texture_path.is_empty():
			return null
		atlas = _load_png_texture(texture_path)
		if atlas == null:
			return null
	var words := bank.get("parameter_words", PackedInt32Array()) as PackedInt32Array
	var speeds := bank.get("float_parameters_4_6", PackedFloat32Array()) as PackedFloat32Array
	var lifetime_frames := maxi(int(words[2]), 1)
	var burst := maxi(int(words[1]), 1)
	# Parameter 10 is the source update interval between bursts; parameter 03 is
	# the emission cone half-angle in degrees.
	var interval := maxi(int(words[10]), 1)
	var spread := clampf(float(words[3]), 0.0, 180.0)
	var source_speed := float(speeds[0]) if speeds.size() > 0 else 0.0
	var world_size := maxf(
		float(bank.get("particle_size", 0.0)) * world_scale, 0.01 * world_scale
	)

	var particles := GPUParticles3D.new()
	particles.lifetime = lifetime_frames / fps
	particles.amount = clampi(
		int(ceil(float(burst) * float(lifetime_frames) / float(interval))),
		1, MAX_ATTACHMENT_FX_PARTICLES
	)
	particles.local_coords = false
	# Additive blending is order-independent, so the per-frame depth sort a
	# view-depth order costs would buy nothing here.
	particles.draw_order = GPUParticles3D.DRAW_ORDER_INDEX
	# Simulate at the rate the effect was authored for. The default 30 Hz spends
	# half again as much on a stream whose motion is defined per 20 Hz update.
	particles.fixed_fps = int(fps)
	# The authored start/stop events drive this; see _add_attachment_fx_tracks.
	# Idle stacks in particular only puff for part of their loop, and a bank
	# left emitting forever is both wrong and pure cost on every hidden state.
	particles.emitting = false

	var process := ParticleProcessMaterial.new()
	# The speed's sign is a source-axis convention, not a world direction: AT
	# Refinery's stacks author their smoke positive and OR Refinery's author the
	# same rising plume negative, and every one of these markers rests on an
	# identity basis. Emission is along the marker's own up axis either way.
	process.direction = Vector3.UP
	process.spread = spread
	var world_speed := absf(source_speed) * world_scale * fps
	process.initial_velocity_min = world_speed
	process.initial_velocity_max = world_speed
	# Source gravity is per squared update and positive-down, so a buoyant smoke
	# bank authors it negative.
	process.gravity = Vector3.DOWN * (
		float(bank.get("gravity", 0.0)) * world_scale * fps * fps
	)
	process.color = _fx_bank_tint(bank)
	process.alpha_curve = _fx_bank_alpha_curve()
	particles.process_material = process
	_apply_attachment_fx_drift(process, particles.lifetime, world_speed)

	var alpha_keyed := _uses_alpha_channel(String(bank.get("texture", "")))
	if alpha_keyed:
		atlas = _luminance_keyed_texture(atlas)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# `@` marks the banks the original renders as ordinary smoke rather than as
	# light: `@!%Engine` and `!@sm` carry it, `!fire`, `!%Flash` and `!Dlight` do
	# not. Blending those additively turns OR Refinery's dirty-green exhaust into
	# a glow, so `@` selects alpha blending and `!` alone stays additive.
	material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX if alpha_keyed \
		else BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = atlas
	if frame_names.size() > 1:
		material.particles_anim_h_frames = 1
		material.particles_anim_v_frames = frame_names.size()
		material.particles_anim_loop = true
		# anim_speed counts full sequence loops per particle lifetime, and the
		# authored flipbook step is TEXTURE_FX_SOURCE_FRAME_STEP source frames.
		var loops := (float(lifetime_frames) / TEXTURE_FX_SOURCE_FRAME_STEP) \
			/ float(frame_names.size())
		process.anim_speed_min = loops
		process.anim_speed_max = loops

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * world_size
	quad.material = material
	particles.draw_pass_1 = quad
	# The marker sits inside the model root's 1/16 scale, but a billboarded
	# particle quad is sized in world units. Undo the inherited scale so the
	# authored source size lands at the same world size as the static banks.
	particles.scale = Vector3.ONE / world_scale
	# Default visibility bounds are a fixed 8-unit box, which for these streams
	# is both too large to cull well and, for a long-lived plume, too small.
	# Size it from the authored ballistic reach instead.
	var reach := world_speed * particles.lifetime \
		+ 0.5 * process.gravity.length() * particles.lifetime * particles.lifetime \
		+ quad.size.x
	particles.visibility_aabb = AABB(Vector3.ONE * -reach, Vector3.ONE * 2.0 * reach)
	return particles


## Lets a rising plume wander instead of climbing as a rigid column. Each
## particle picks its own share of a noise field, so neighbours emitted a frame
## apart drift different ways. The banks author no such term, so the strength is
## chosen rather than decoded: a fully-influenced particle wanders sideways by
## ATTACHMENT_FX_DRIFT_FRACTION of the distance it travels along the plume.
##
## Measuring against the travel rather than the particle's own size is what
## keeps this proportional across banks. Damage fire is authored as 4-unit
## sprites that barely move, so a size-relative drift would fling it across the
## whole building, while a stack puff a sixteenth that size has to cross several
## of its own widths before the column visibly loosens.
func _apply_attachment_fx_drift(
		process: ParticleProcessMaterial,
		lifetime: float,
		world_speed: float
	) -> void:
	var travel := world_speed * lifetime \
		+ 0.5 * process.gravity.length() * lifetime * lifetime
	if lifetime <= 0.0 or travel <= 0.0:
		return
	process.turbulence_enabled = true
	# Turbulence reads as an acceleration, so the distance it accumulates over a
	# lifetime goes with the square of the time.
	process.turbulence_noise_strength = \
		2.0 * ATTACHMENT_FX_DRIFT_FRACTION * travel / (lifetime * lifetime)
	# Roughly one noise period across the plume, so a particle follows a single
	# smooth arc instead of jittering along its path.
	process.turbulence_noise_scale = clampf(1.0 / travel, 0.5, 9.0)
	process.turbulence_noise_speed = Vector3.ONE * 0.2
	# The per-particle share of the field. Spanning the full range is what makes
	# some of the plume hold its line while the rest peels off.
	process.turbulence_influence_min = 0.0
	process.turbulence_influence_max = 1.0


## The `@` FX sprites are 24-bit, drawn as light-on-black for additive output,
## so alpha blending them straight would paste a black square over the scene.
## Their brightness is the coverage mask: it becomes alpha, and the residual hue
## is normalized back to full value so the bank's own tint decides the colour.
func _luminance_keyed_texture(source: Texture2D) -> Texture2D:
	var image := source.get_image()
	if image == null or image.is_empty():
		return source
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			var coverage := maxf(pixel.r, maxf(pixel.g, pixel.b))
			if coverage <= 0.0:
				image.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
				continue
			image.set_pixel(x, y, Color(
				pixel.r / coverage, pixel.g / coverage, pixel.b / coverage, coverage
			))
	return ImageTexture.create_from_image(image)


## A particle thins out towards the end of its life in the original: a stack's
## plume is dense at the mouth and dissipated by the top. The banks themselves
## author no alpha ramp (their per-update colour deltas are all zero), so this
## is engine behaviour rather than decoded data - see docs/open_questions.md.
func _fx_bank_alpha_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	var curve_texture := CurveTexture.new()
	curve_texture.curve = curve
	return curve_texture


func _fx_bank_tint(bank: Dictionary) -> Color:
	var colors := bank.get("int_parameters_7_11", PackedInt32Array()) as PackedInt32Array
	if colors.size() < 3:
		return Color.WHITE
	return Color(
		clampf(float(colors[0]) / 255.0, 0.0, 1.0),
		clampf(float(colors[1]) / 255.0, 0.0, 1.0),
		clampf(float(colors[2]) / 255.0, 0.0, 1.0),
		_fx_bank_frame_opacity(bank, 0)
	)


func _attachment_fx_mesh_frames(bank: Dictionary) -> Array[QuadMesh]:
	var frame_names := _attachment_fx_frame_names(bank)
	var result: Array[QuadMesh] = []
	# StandardMaterial3D's billboard transform faces the camera in world space
	# and does not retain the converted model root's scale like an ordinary
	# mesh. Bake the XBF particle size into world units here; otherwise a source
	# size such as 12 renders as a 12-world-unit flare instead of 0.75 at 1/16.
	var world_size := maxf(
		float(bank.get("particle_size", 0.0)) * world_scale,
		0.01 * world_scale
	)
	var colors := bank.get("int_parameters_7_11", PackedInt32Array()) as PackedInt32Array
	var tint := Color.WHITE
	if colors.size() >= 3:
		tint = Color(
			clampf(float(colors[0]) / 255.0, 0.0, 1.0),
			clampf(float(colors[1]) / 255.0, 0.0, 1.0),
			clampf(float(colors[2]) / 255.0, 0.0, 1.0),
		)
	for frame_index in frame_names.size():
		var texture_path := _ensure_model_texture(frame_names[frame_index])
		if texture_path.is_empty():
			return []
		var texture := _load_png_texture(texture_path)
		if texture == null:
			return []
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		material.albedo_texture = texture
		material.albedo_color = Color(
			tint.r, tint.g, tint.b, _fx_bank_frame_opacity(bank, frame_index)
		)
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * world_size
		quad.material = material
		result.append(quad)
	return result


func _attachment_fx_frame_names(bank: Dictionary) -> PackedStringArray:
	var texture_name := String(bank.get("texture", ""))
	var discovered := _animated_texture_frames(texture_name)
	var frame_count := maxi(int(bank.get("texture_frame_count", 1)), 1)
	if not discovered.is_empty():
		if discovered.size() > frame_count:
			discovered.resize(frame_count)
		return discovered
	var result := PackedStringArray()
	if not texture_name.get_extension().is_empty():
		result.append(texture_name)
		return result
	for frame_index in frame_count:
		result.append(texture_name + str(frame_index) + ".tga")
	return result


func _fx_bank_frame_opacity(bank: Dictionary, frame_index: int) -> float:
	var trailing := bank.get("trailing_words", PackedInt32Array()) as PackedInt32Array
	if trailing.size() < 2:
		return 1.0
	return clampf(
		float(trailing[0] + trailing[1] * frame_index) / 255.0,
		0.0, 1.0
	)


func _find_original_node(node: Node, original_name: String) -> Node3D:
	if node is Node3D and String(node.get_meta("original_name", "")).nocasecmp_to(original_name) == 0:
		return node as Node3D
	for child in node.get_children():
		var found := _find_original_node(child, original_name)
		if found != null:
			return found
	return null


func _add_attachment_fx_tracks(anim: Animation, effects: Array[Dictionary]) -> void:
	for effect: Dictionary in effects:
		var path := String(effect["path"])
		var lifetime := float(effect.get("lifetime", 0.0))
		var visibility_track := anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(visibility_track, NodePath("%s:visible" % path))
		anim.track_set_interpolation_type(visibility_track, Animation.INTERPOLATION_NEAREST)
		anim.value_track_set_update_mode(visibility_track, Animation.UPDATE_DISCRETE)
		anim.track_insert_key(visibility_track, 0.0, false)
		# An emitter's start/stop pair gates emission, not visibility: the source
		# banks are intermittent (AT Refinery's #smoke02 runs source frames 5-70
		# and 90-100 of a 201-frame loop), and cutting a stopped stream's
		# existing particles instead of letting them live out their lifetime
		# would pop the whole plume out of existence. The node itself stays
		# visible until the last particle can have expired, so a hidden or
		# stopped bank still costs nothing.
		if lifetime <= 0.0:
			for event: Dictionary in effect["events"]:
				var action := String(event.get("action", ""))
				if action != "start" and action != "stop":
					continue
				anim.track_insert_key(
					visibility_track,
					float(event.get("frame", 0)) / fps,
					action == "start"
				)
		else:
			var emission_track := anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(emission_track, NodePath("%s:emitting" % path))
			anim.track_set_interpolation_type(emission_track, Animation.INTERPOLATION_NEAREST)
			anim.value_track_set_update_mode(emission_track, Animation.UPDATE_DISCRETE)
			anim.track_insert_key(emission_track, 0.0, false)
			var switches := _sorted_bank_switches(effect["events"])
			for switch: Dictionary in switches:
				anim.track_insert_key(
					emission_track, float(switch["time"]), bool(switch["started"])
				)
			for interval: Vector2 in _visible_intervals(switches, lifetime, anim.length):
				anim.track_insert_key(visibility_track, interval.x, true)
				if interval.y < anim.length:
					anim.track_insert_key(visibility_track, interval.y, false)

		var meshes := effect["meshes"] as Array[QuadMesh]
		if meshes.size() <= 1:
			continue
		var mesh_track := anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(mesh_track, NodePath("%s:mesh" % path))
		anim.track_set_interpolation_type(mesh_track, Animation.INTERPOLATION_NEAREST)
		anim.value_track_set_update_mode(mesh_track, Animation.UPDATE_DISCRETE)
		var step := TEXTURE_FX_SOURCE_FRAME_STEP / fps
		var key_count := int(ceilf(anim.length / step))
		for frame_index in key_count + 1:
			anim.track_insert_key(
				mesh_track,
				frame_index * step,
				meshes[frame_index % meshes.size()]
			)


func _sorted_bank_switches(events: Array) -> Array[Dictionary]:
	var switches: Array[Dictionary] = []
	for event: Dictionary in events:
		var action := String(event.get("action", ""))
		if action != "start" and action != "stop":
			continue
		switches.append({
			"time": float(event.get("frame", 0)) / fps,
			"started": action == "start",
		})
	switches.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return float(a["time"]) < float(b["time"])
	)
	return switches


## Spans over which an emitter can still hold a live particle: every emitting
## window extended by one particle lifetime, merged where a restart lands inside
## the previous window's tail. Without the merge a re-start would be followed by
## the earlier window's delayed hide and blank the plume mid-loop.
func _visible_intervals(
		switches: Array[Dictionary],
		lifetime: float,
		length: float
	) -> Array[Vector2]:
	var intervals: Array[Vector2] = []
	var open := -1.0
	for switch: Dictionary in switches:
		var time := float(switch["time"])
		if bool(switch["started"]):
			if open < 0.0:
				open = time
		elif open >= 0.0:
			intervals.append(Vector2(open, minf(time + lifetime, length)))
			open = -1.0
	if open >= 0.0:
		intervals.append(Vector2(open, length))

	var merged: Array[Vector2] = []
	for interval: Vector2 in intervals:
		if not merged.is_empty() and interval.x <= merged[-1].y:
			merged[-1] = Vector2(merged[-1].x, maxf(merged[-1].y, interval.y))
			continue
		merged.append(interval)
	return merged


func _is_animated_shield_texture(texture_name: String) -> bool:
	return _is_animated_texture(texture_name) and _has_shield_fx_marker and texture_name.get_file().to_lower().contains("shield")


func _add_animation_track(
		anim: Animation,
		node_path: String,
		object: Dictionary,
		uses_mirrored_content: bool
	) -> void:
	var object_animation: Dictionary = object.object_animation
	if object_animation.is_empty():
		return

	var frames := _dense_object_animation_frames(object_animation)
	if frames.is_empty():
		return

	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, NodePath("%s:transform" % node_path))
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	# XBF clips include the final authored pose, followed by an implicit snap
	# back to their first pose at the loop boundary. Godot enables interpolation
	# across that boundary by default, which turns the snap into a visible
	# one-frame rewind whenever the two poses differ (CU_Select, building lights,
	# and similar tracks). Hold the final key until the loop wraps instead.
	anim.track_set_interpolation_loop_wrap(track, false)

	var frame_ids := frames.keys()
	frame_ids.sort()
	var fallback_transform := _to_godot_transform(
		_initial_object_transform(object)
	)
	if uses_mirrored_content:
		fallback_transform *= LOCAL_Z_REFLECTION
	fallback_transform = _sanitize_animation_transform(
		fallback_transform, Transform3D.IDENTITY
	)
	for frame_id: int in frame_ids:
		var transform := _to_godot_transform(frames[frame_id])
		if uses_mirrored_content:
			transform *= LOCAL_Z_REFLECTION
		# A few original XBF files contain corrupt, unreferenced tail frames.
		# HK_Flamer_H0 is one: named clips end at frame 583, while several
		# object timelines continue through frame 591 with Inf matrix values.
		# Never serialize those values into a Godot animation. Holding the last
		# valid pose also gives a deterministic result if a malformed frame is
		# ever referenced by a clip.
		transform = _sanitize_animation_transform(transform, fallback_transform)
		anim.track_insert_key(track, frame_id / fps, transform)
		fallback_transform = transform


func _object_animation_is_consistently_mirrored(object: Dictionary) -> bool:
	var object_animation: Dictionary = object.object_animation
	if object_animation.is_empty():
		return false
	var frames := _dense_object_animation_frames(object_animation)
	var found_mirrored_frame := false
	for frame: Transform3D in frames.values():
		var determinant := frame.basis.determinant()
		if determinant > MIN_ANIMATION_AXIS_SCALE:
			return false
		if determinant < -MIN_ANIMATION_AXIS_SCALE:
			found_mirrored_frame = true
	return found_mirrored_frame


func _dense_object_animation_frames(object_animation: Dictionary) -> Dictionary:
	var source_frames: Dictionary = object_animation.frames
	if source_frames.is_empty():
		return {}

	var length := int(object_animation.get("length", 1))
	if length <= 0:
		length = 1
	if _object_transform_frame_limit > 0:
		length = mini(length, _object_transform_frame_limit)

	var frame_ids := source_frames.keys()
	frame_ids.sort()
	var first_frame := int(frame_ids[0])
	var last_frame := int(frame_ids[-1])
	var dense := {}

	for frame in length:
		if source_frames.has(frame):
			dense[frame] = source_frames[frame]
		elif frame < first_frame:
			dense[frame] = source_frames[first_frame]
		elif frame > last_frame:
			dense[frame] = source_frames[last_frame]
		else:
			var previous_frame := first_frame
			var next_frame := last_frame
			for frame_id: int in frame_ids:
				if frame_id < frame:
					previous_frame = frame_id
				elif frame_id > frame:
					next_frame = frame_id
					break
			var span := maxf(1.0, float(next_frame - previous_frame))
			var weight := float(frame - previous_frame) / span
			dense[frame] = _lerp_transform(source_frames[previous_frame], source_frames[next_frame], weight)
	return dense


func _lerp_transform(a: Transform3D, b: Transform3D, weight: float) -> Transform3D:
	return Transform3D(
		a.basis.x.lerp(b.basis.x, weight),
		a.basis.y.lerp(b.basis.y, weight),
		a.basis.z.lerp(b.basis.z, weight),
		a.origin.lerp(b.origin, weight)
	)


func _sanitize_animation_transform(
	transform: Transform3D,
	fallback: Transform3D
	) -> Transform3D:
	if not fallback.is_finite():
		fallback = Transform3D.IDENTITY
	if not transform.is_finite():
		return fallback

	var source_determinant := transform.basis.determinant()
	var x := transform.basis.x
	var y := transform.basis.y
	var z := transform.basis.z
	var x_scale := maxf(x.length(), MIN_ANIMATION_AXIS_SCALE)
	var y_scale := maxf(y.length(), MIN_ANIMATION_AXIS_SCALE)
	var z_scale := maxf(z.length(), MIN_ANIMATION_AXIS_SCALE)

	var nx := x.normalized() if x.length() >= MIN_ANIMATION_AXIS_SCALE else Vector3.RIGHT
	var ny := y.normalized() if y.length() >= MIN_ANIMATION_AXIS_SCALE else Vector3.UP
	ny = ny - nx * nx.dot(ny)
	if ny.length() < MIN_ANIMATION_AXIS_SCALE:
		ny = _perpendicular_axis(nx)
	else:
		ny = ny.normalized()

	var nz := z.normalized() if z.length() >= MIN_ANIMATION_AXIS_SCALE else nx.cross(ny)
	nz = nz - nx * nx.dot(nz) - ny * ny.dot(nz)
	if nz.length() < MIN_ANIMATION_AXIS_SCALE:
		nz = nx.cross(ny).normalized()
	else:
		nz = nz.normalized()

	# Handedness normally remains unchanged. Consistently mirrored animation
	# tracks have already had their reflection factored into MirroredContent;
	# this fallback still preserves parity for an unusual mixed-parity track.
	var sanitized_determinant := Basis(nx, ny, nz).determinant()
	if source_determinant * sanitized_determinant < 0.0:
		nz = -nz

	transform.basis = Basis(nx * x_scale, ny * y_scale, nz * z_scale)
	return transform if transform.is_finite() else fallback


func _perpendicular_axis(axis: Vector3) -> Vector3:
	var reference := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return (reference - axis * axis.dot(reference)).normalized()


func _add_vertex_animation_track(anim: Animation, mesh_path: String, object: Dictionary, texture_names: PackedStringArray, flip_orientation := false) -> void:
	var vertex_animation: Dictionary = object.vertex_animation
	if vertex_animation.is_empty():
		return

	var frames: Dictionary = vertex_animation.frames
	if frames.is_empty():
		return

	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, NodePath("%s:mesh" % mesh_path))
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
	anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)

	var frame_ids := frames.keys()
	frame_ids.sort()
	var mesh_cache := {}
	for frame_id: int in frame_ids:
		var positions: PackedVector3Array = frames[frame_id]
		if positions.size() != (object.positions as PackedVector3Array).size():
			continue
		# Identical poses share one baked mesh instead of duplicating it per frame.
		var mesh: ArrayMesh = mesh_cache.get(positions)
		if mesh == null:
			mesh = _build_object_mesh(object, texture_names, positions, PackedInt32Array(), flip_orientation)
			mesh_cache[positions] = mesh
		anim.track_insert_key(track, frame_id / fps, mesh)


func _mesh_animated_frame_count(mesh: ArrayMesh) -> int:
	var frames := 0
	for surface_index in mesh.get_surface_count():
		frames = maxi(frames, int(_animated_material_frames.get(mesh.surface_get_material(surface_index), 0)))
	return frames


func _mesh_animated_frame_names(mesh: ArrayMesh) -> PackedStringArray:
	var best := PackedStringArray()
	for surface_index in mesh.get_surface_count():
		var names: PackedStringArray = _animated_material_frame_names.get(
			mesh.surface_get_material(surface_index), PackedStringArray()
		)
		if names.size() > best.size():
			best = names
	return best


func _mesh_has_scrolling_texture(mesh: ArrayMesh) -> bool:
	for surface_index in mesh.get_surface_count():
		if _scrolling_materials.has(mesh.surface_get_material(surface_index)):
			return true
	return false


func _mesh_has_move_scrolling_texture(mesh: ArrayMesh) -> bool:
	for surface_index in mesh.get_surface_count():
		if _move_scrolling_materials.has(mesh.surface_get_material(surface_index)):
			return true
	return false


func _last_fx_event_frame(xbf) -> int:
	var last := -1
	for event: Dictionary in xbf.fx_events:
		last = maxi(last, int(event.get("frame", 0)))
	return last


## Collects the authored "object N now uses texture T" records, keyed by the
## source object name. They are the only ground truth for how fast an
## animated-texture sequence advances: an explosion's ?firesphere steps through
## !%Rbang0..9 on source frames 8..16 and then simply stops, because the tail of
## its sequence is authored black and additive-invisible. A fixed guessed rate
## instead keeps a fireball at full brightness for the whole (much longer)
## transform clip, which reads as both slow motion and an oversized explosion.
func _prepare_texture_events(xbf) -> void:
	for event: Dictionary in xbf.fx_events:
		if int(event.get("type", 0)) != TEXTURE_EVENT_TYPE:
			continue
		var strings: Array = event.get("strings", [])
		if strings.size() < 2:
			continue
		var key := String(strings[0]).to_lower()
		if not _texture_events_by_object.has(key):
			_texture_events_by_object[key] = []
		(_texture_events_by_object[key] as Array).append({
			"frame": int(event.get("frame", 0)),
			"texture": String(strings[1]),
		})


func _add_shader_fx_tracks(anim: Animation) -> void:
	for entry: Dictionary in _pending_frame_tracks:
		var frame_count := int(entry["frames"])
		var track := anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(track, NodePath("%s:instance_shader_parameters/fx_frame" % String(entry["path"])))
		anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
		anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		var authored: Array = _authored_frame_keys(entry)
		if authored.is_empty():
			authored = _sibling_frame_keys(entry)
		if not authored.is_empty():
			for key: Dictionary in authored:
				anim.track_insert_key(
					track, minf(float(key["frame"]) / fps, anim.length), float(key["index"])
				)
			continue
		var step := TEXTURE_FX_SOURCE_FRAME_STEP / fps
		var key_count := int(ceilf(anim.length / step))
		for i in key_count + 1:
			anim.track_insert_key(track, i * step, float(i % frame_count))


## Duplicated FX geometry (Explosion's ?firesphere01 next to ?firesphere) shares
## one texture sequence but appears only once in the event table. Reusing the
## timeline authored for the sibling that does own the sequence keeps the copy
## in step; leaving it on its own would strand it on the opening, brightest
## frame of an additive sequence whose whole fade-out lives in later frames.
func _sibling_frame_keys(entry: Dictionary) -> Array:
	var frame_names: PackedStringArray = entry.get("frame_names", PackedStringArray())
	if frame_names.is_empty():
		return []
	for other: Dictionary in _pending_frame_tracks:
		if other["path"] == entry["path"]:
			continue
		if other.get("frame_names", PackedStringArray()) != frame_names:
			continue
		var keys := _authored_frame_keys(other)
		if not keys.is_empty():
			return keys
	return []


## Resolves an object's authored texture events into atlas frame indices. Every
## named TGA must be part of the atlas this mesh was baked with; a sequence the
## events step outside of is not one this track can drive, so the caller falls
## back to the authored default rate rather than baking wrong frames.
func _authored_frame_keys(entry: Dictionary) -> Array:
	var events: Array = _texture_events_by_object.get(
		String(entry.get("object", "")).to_lower(), []
	)
	if events.is_empty():
		return []
	var frame_names: PackedStringArray = entry.get("frame_names", PackedStringArray())
	var index_by_name := {}
	for index in frame_names.size():
		index_by_name[_texture_sequence_key(frame_names[index])] = index
	var keys := []
	for event: Dictionary in events:
		var name_key := _texture_sequence_key(String(event["texture"]).get_file())
		if not index_by_name.has(name_key):
			return []
		keys.append({"frame": int(event["frame"]), "index": int(index_by_name[name_key])})
	return keys


func _add_timeline_muzzle_flash_visibility(anim: Animation, animation_entries: Array[Dictionary]) -> void:
	for mesh_path in _muzzle_flash_mesh_paths:
		var track := anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(track, NodePath("%s:visible" % mesh_path))
		anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
		anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		anim.track_insert_key(track, 0.0, false)
		for entry: Dictionary in animation_entries:
			if not _clip_shows_muzzle_flash(String(entry.get("name", ""))):
				continue
			var start_time := int(entry.get("start_frame", 0)) / fps
			var end_time := (int(entry.get("end_frame", 0)) + 1) / fps
			if not _muzzle_flash_active_in_range(anim, mesh_path, start_time, end_time):
				continue
			anim.track_insert_key(track, start_time, true)
			anim.track_insert_key(track, minf(end_time, anim.length), false)


func _slice_animation(source: Animation, entry: Dictionary, target_paths := {}) -> Animation:
	var start_frame := int(entry.get("start_frame", 0))
	var end_frame := int(entry.get("end_frame", 0))
	if end_frame < start_frame:
		return null

	var start_time := start_frame / fps
	var end_time := end_frame / fps
	var clip := Animation.new()
	clip.resource_name = _clip_name(String(entry["name"]))
	clip.length = maxf((end_frame - start_frame + 1) / fps, 1.0 / fps)
	var should_loop := _is_looping_clip(clip.resource_name) \
		and (stationary_clip_loops or clip.resource_name != &"Stationary")
	clip.loop_mode = Animation.LOOP_LINEAR if should_loop else Animation.LOOP_NONE
	var target_object_id := int(entry.get("target_object_id", entry.get("zero2", 0)))

	for source_track in source.get_track_count():
		if not _clip_uses_track(source.track_get_path(source_track), target_object_id, target_paths):
			continue
		var track := clip.add_track(source.track_get_type(source_track))
		clip.track_set_path(track, source.track_get_path(source_track))
		clip.track_set_interpolation_type(track, source.track_get_interpolation_type(source_track))
		clip.track_set_interpolation_loop_wrap(
			track, source.track_get_interpolation_loop_wrap(source_track)
		)
		if source.track_get_type(source_track) == Animation.TYPE_VALUE:
			clip.value_track_set_update_mode(track, source.value_track_get_update_mode(source_track))

		var inserted_keys := 0
		for key_index in source.track_get_key_count(source_track):
			var key_time := source.track_get_key_time(source_track, key_index)
			if key_time < start_time or key_time > end_time:
				continue
			clip.track_insert_key(
				track,
				key_time - start_time,
				source.track_get_key_value(source_track, key_index),
				source.track_get_key_transition(source_track, key_index)
			)
			inserted_keys += 1
		# Some authored object tracks end immediately before a later clip
		# begins. IM Sardaukar's #^^0 ends at frame 629 while Stationary starts
		# at 630. Leaving the sliced transform track empty makes AnimationPlayer
		# apply Transform3D.IDENTITY, dropping the halo to ground level. Hold the
		# source track's last available pose at the start of such clips.
		if inserted_keys == 0 \
		and source.track_get_type(source_track) == Animation.TYPE_VALUE \
		and String(source.track_get_path(source_track)).ends_with(":transform"):
			var held_transform: Variant = source.value_track_interpolate(
				source_track, start_time
			)
			if held_transform is Transform3D:
				clip.track_insert_key(track, 0.0, held_transform)
	_seed_clip_attachment_fx_tracks(clip, source, start_time)
	_add_clip_muzzle_flash_visibility(clip, String(entry.get("name", "")), source, start_time, end_time)
	return clip


func _seed_clip_attachment_fx_tracks(
		clip: Animation, source: Animation, start_time: float
	) -> void:
	for path in _attachment_fx_paths:
		for property_name in ["visible", "mesh"]:
			var track_path := NodePath("%s:%s" % [path, property_name])
			var source_track := source.find_track(track_path, Animation.TYPE_VALUE)
			if source_track < 0:
				continue
			var value: Variant = source.value_track_interpolate(source_track, start_time)
			if value == null:
				continue
			var clip_track := clip.find_track(track_path, Animation.TYPE_VALUE)
			if clip_track < 0:
				clip_track = clip.add_track(Animation.TYPE_VALUE)
				clip.track_set_path(clip_track, track_path)
				clip.track_set_interpolation_type(clip_track, Animation.INTERPOLATION_NEAREST)
				clip.value_track_set_update_mode(clip_track, Animation.UPDATE_DISCRETE)
			clip.track_insert_key(clip_track, 0.0, value)


func _clip_target_paths(objects: Array[Dictionary], animation_entries: Array[Dictionary]) -> Dictionary:
	var referenced_ids := {}
	for entry: Dictionary in animation_entries:
		var target_id := int(entry.get("target_object_id", entry.get("zero2", 0)))
		if target_id > 0:
			referenced_ids[target_id] = true

	var paths := {}
	_collect_clip_target_paths(objects, ".", referenced_ids, paths)
	return paths


## Refinery pads are normally top-level objects, but OR/HK place them below
## the shared ~~0 shell. Mirror the node-path construction in
## _build_object_node() so an FX entry's target id filters the right branch in
## either layout.
func _collect_clip_target_paths(
		objects: Array[Dictionary], parent_path: String, referenced_ids: Dictionary, paths: Dictionary
	) -> void:
	var sibling_names := {}
	for object: Dictionary in objects:
		var node_name := _unique_sibling_node_name(String(object.name), sibling_names)
		var node_path := "%s/%s" % [parent_path, node_name] if parent_path != "." else node_name
		var target_id := _top_level_target_id(String(object.name))
		if target_id > 0 and referenced_ids.has(target_id):
			paths[target_id] = node_path

		var content_path := node_path
		if _object_animation_is_consistently_mirrored(object):
			content_path = "%s/%s" % [node_path, MIRRORED_CONTENT_NODE_NAME]
		_collect_clip_target_paths(object.children, content_path, referenced_ids, paths)


func _top_level_target_id(object_name: String) -> int:
	if not object_name.begins_with("~~"):
		return 0
	var end := 2
	while end < object_name.length():
		var code := object_name.unicode_at(end)
		if code < 48 or code > 57:
			break
		end += 1
	return int(object_name.substr(2, end - 2)) if end > 2 else 0


func _clip_uses_track(track_path: NodePath, target_object_id: int, target_paths: Dictionary) -> bool:
	if target_paths.is_empty():
		return true
	var node_path := String(track_path).get_slice(":", 0)
	if target_object_id > 0 and target_paths.has(target_object_id):
		return _path_is_within(node_path, String(target_paths[target_object_id]))
	if target_object_id == 0:
		for target_path: String in target_paths.values():
			if _path_is_within(node_path, target_path):
				return false
	return true


func _path_is_within(node_path: String, root_path: String) -> bool:
	return node_path == root_path or node_path.begins_with(root_path + "/")


func _add_clip_muzzle_flash_visibility(clip: Animation, clip_name: String, source: Animation, start_time: float, end_time: float) -> void:
	for mesh_path in _muzzle_flash_mesh_paths:
		var visible := _clip_shows_muzzle_flash(clip_name) and _muzzle_flash_active_in_range(source, mesh_path, start_time, end_time)
		var track := clip.add_track(Animation.TYPE_VALUE)
		clip.track_set_path(track, NodePath("%s:visible" % mesh_path))
		clip.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
		clip.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		clip.track_insert_key(track, 0.0, visible)


func _clip_shows_muzzle_flash(clip_name: String) -> bool:
	return clip_name.to_lower().contains("fire")


func _muzzle_flash_active_in_range(source: Animation, mesh_path: String, start_time: float, end_time: float) -> bool:
	# A single muzzle flash (for example AT Sniper) is event-driven and can
	# keep the same tiny authored transform through the whole timeline. Models
	# with several guns (AT Kindjal) scale only the firing gun's flash up, so use
	# that relative change to avoid enabling both flashes in every Fire clip.
	if _muzzle_flash_mesh_paths.size() <= 1:
		return true

	var transform_path := NodePath("%s:transform" % String(mesh_path).get_base_dir())
	var transform_track := source.find_track(transform_path, Animation.TYPE_VALUE)
	if transform_track < 0:
		return true

	var minimum_scale := INF
	var range_maximum_scale := 0.0
	for key_index in source.track_get_key_count(transform_track):
		var value: Variant = source.track_get_key_value(transform_track, key_index)
		if typeof(value) != TYPE_TRANSFORM3D:
			continue
		var transform := value as Transform3D
		var scale_length := transform.basis.get_scale().length()
		minimum_scale = minf(minimum_scale, scale_length)
		var key_time := source.track_get_key_time(transform_track, key_index)
		if key_time >= start_time and key_time <= end_time:
			range_maximum_scale = maxf(range_maximum_scale, scale_length)
	if not is_finite(minimum_scale) or minimum_scale <= 0.0 or range_maximum_scale <= 0.0:
		return true
	return range_maximum_scale > minimum_scale * 2.0


func _clip_name(value: String) -> String:
	var name := value.strip_edges().replace(" ", "_")
	var overrides: Dictionary = CLIP_NAME_OVERRIDES.get(_source_file_name, {})
	return overrides.get(name, name)


## Every shipped AT_MGT state and LOD labels frames 200..240 as "Idle 0",
## although that interval is nested inside Fire 0 (193..275) and contains the
## complete machine-gun recoil sequence (194..230). Keep ModelXbf lossless and
## repair only the baked clip by reusing the file's own Stationary range.
func _repaired_animation_entries(source_entries: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for source_entry: Dictionary in source_entries:
		result.append(source_entry.duplicate(true))
	if not _source_file_name.begins_with("at_mgt_"):
		return result

	var stationary := {}
	for entry: Dictionary in result:
		if String(entry.get("name", "")) == "Stationary":
			stationary = entry
			break
	if stationary.is_empty():
		return result

	for entry: Dictionary in result:
		if String(entry.get("name", "")) != "Idle 0":
			continue
		entry["source_start_frame"] = entry.get("start_frame", 0)
		entry["source_end_frame"] = entry.get("end_frame", 0)
		entry["start_frame"] = stationary.get("start_frame", 0)
		entry["end_frame"] = stationary.get("end_frame", 0)
	return result


## Produces the animation-range metadata consumed by runtime FX playback.
## Preserve the source label for diagnostics, but expose the repaired baked
## name as `name`, matching AnimationLibrary exactly. Apply the same
## last-entry-wins collision rule used while adding clips above.
func _baked_animation_entries(source_entries: Array) -> Array:
	var result: Array = []
	var index_by_name := {}
	for source_value: Variant in source_entries:
		var source_entry := source_value as Dictionary
		var baked_entry := source_entry.duplicate(true)
		var source_name := String(source_entry.get("name", ""))
		var baked_name := _clip_name(source_name)
		baked_entry["source_name"] = source_name
		baked_entry["name"] = baked_name
		if index_by_name.has(baked_name):
			result[int(index_by_name[baked_name])] = baked_entry
		else:
			index_by_name[baked_name] = result.size()
			result.append(baked_entry)
	return result


func _is_looping_clip(value: String) -> bool:
	# Idle variants are deliberately one-shot: Unit chooses another random
	# variant when one finishes. Stationary remains the fallback for models
	# without authored Idle* clips.
	return value in ["Stationary", "Move", "Crawl", "Crouch"]


func _object_animation_length(object: Dictionary) -> int:
	var length := 1
	var object_animation: Dictionary = object.object_animation
	if not object_animation.is_empty():
		length = maxi(length, int(object_animation.get("length", 1)))
	var vertex_animation: Dictionary = object.vertex_animation
	if not vertex_animation.is_empty():
		length = maxi(length, int(vertex_animation.get("length", 1)))
	for child: Dictionary in object.children:
		length = maxi(length, _object_animation_length(child))
	return length


func _to_godot_transform(source: Transform3D) -> Transform3D:
	var transform := source
	transform.basis.x = Vector3(source.basis.x.x, source.basis.x.y, -source.basis.x.z)
	transform.basis.y = Vector3(source.basis.y.x, source.basis.y.y, -source.basis.y.z)
	transform.basis.z = Vector3(-source.basis.z.x, -source.basis.z.y, source.basis.z.z)
	transform.origin = Vector3(source.origin.x, source.origin.y, -source.origin.z)
	return transform


func _safe_node_name(value: String) -> String:
	if value.is_empty():
		return "Object"
	var result := ""
	for i in value.length():
		var code := value.unicode_at(i)
		var is_digit := code >= 48 and code <= 57
		var is_upper := code >= 65 and code <= 90
		var is_lower := code >= 97 and code <= 122
		result += value.substr(i, 1) if is_digit or is_upper or is_lower or code == 95 else "_"
	result = result.strip_edges()
	while result.contains("__"):
		result = result.replace("__", "_")
	if result.is_empty() or (result.unicode_at(0) >= 48 and result.unicode_at(0) <= 57):
		result = "Object_%s" % result
	return result


func _existing_child_names(parent: Node) -> Dictionary:
	var result := {}
	for child in parent.get_children():
		result[String(child.name)] = true
	return result


## XBF permits same-named sibling objects. Resolve collisions before creating
## animation tracks: Node.add_child() auto-renames too late, after both tracks
## have already been pointed at the first sibling's path.
func _unique_sibling_node_name(raw_name: String, used_names: Dictionary) -> String:
	var base_name := _safe_node_name(raw_name)
	var candidate := base_name
	var suffix := 2
	while used_names.has(candidate):
		candidate = "%s_%d" % [base_name, suffix]
		suffix += 1
	used_names[candidate] = true
	return candidate


func _scene_name_from_path(path: String) -> String:
	return path.get_file().get_basename().replace(" ", "_")
