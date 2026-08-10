class_name CombatGroundDecal
extends Node3D

const TerrainProbeScript := preload("res://scripts/world/terrain_probe.gd")
const GameSettingsCatalogScript := preload(
	"res://scripts/rules/game_settings_catalog.gd"
)
const GameSettingsScript := preload("res://scripts/rules/game_settings.gd")
const CraterShader := preload("res://scripts/combat/combat_ground_decal.gdshader")

## Persistent crater decal placed on terrain after an ExplosionType with a
## positive DamageToTile value. The original @craters texture is a 2x2 atlas.
## A transparent PlaneMesh is used because the project targets Godot's
## Compatibility renderer, where the Decal node is unavailable.

const CRATER_ATLAS_PATH := \
	"res://assets/raw_original_content/3DDATA/Textures/@craters.tga"
const RULE_TILE_WORLD_SPAN := 2.0
const BASE_DAMAGE_TO_TILE := 30.0
const MIN_DIAMETER := 1.0
const MAX_DIAMETER := 4.0
const MAXIMUM_OVERLAPPING_DECALS := 7
const SURFACE_OFFSET := 0.03
const TERRAIN_COLLISION_MASK := 1
const RAY_HEIGHT := 2.0
const RAY_DEPTH := 32.0

static var _next_sequence := 0
static var _game_settings_catalog := GameSettingsCatalogScript.new()
static var _crater_material: ShaderMaterial


func configure(tile_damage: float, impact_position: Vector3) -> bool:
	if tile_damage <= 0.0 or not is_inside_tree():
		return false
	var maximum_decal_count := _maximum_decal_count()
	if maximum_decal_count <= 0:
		return false
	var atlas := load(CRATER_ATLAS_PATH) as Texture2D
	if atlas == null:
		return false

	var sequence := _next_sequence
	_next_sequence += 1
	var variant := sequence % 4
	name = "GroundCrater_%d" % sequence
	set_meta("combat_ground_decal", true)
	set_meta("damage_to_tile", tile_damage)
	set_meta("crater_variant", variant)
	set_meta("decal_sequence", sequence)
	set_meta("overlap_fade_steps", 0)
	top_level = true

	var placement := _terrain_placement(impact_position)
	var surface_position: Vector3 = placement["position"]
	var surface_normal: Vector3 = placement["normal"]
	global_transform = Transform3D(
		Basis(Quaternion(Vector3.UP, surface_normal)),
		surface_position + surface_normal * SURFACE_OFFSET
	)
	rotate_object_local(Vector3.UP, fmod(float(sequence) * 2.399963, TAU))

	var diameter := clampf(
		RULE_TILE_WORLD_SPAN * sqrt(tile_damage / BASE_DAMAGE_TO_TILE),
		MIN_DIAMETER,
		MAX_DIAMETER
	)
	set_meta("decal_radius", diameter * 0.5)
	var plane := PlaneMesh.new()
	plane.size = Vector2(diameter, diameter)
	plane.material = _material_for_atlas(atlas)

	var decal := MeshInstance3D.new()
	decal.name = "Decal"
	decal.mesh = plane
	decal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	decal.set_instance_shader_parameter(
		&"crater_uv_offset",
		Vector2(float(variant % 2), float(variant >> 1)) * 0.5
	)
	decal.set_instance_shader_parameter(&"decal_opacity", 1.0)
	add_child(decal)

	_fade_older_overlapping_decals()
	_enforce_parent_budget(maximum_decal_count)
	return true


func _material_for_atlas(atlas: Texture2D) -> ShaderMaterial:
	if _crater_material == null:
		_crater_material = ShaderMaterial.new()
		_crater_material.shader = CraterShader
		_crater_material.set_shader_parameter(&"crater_atlas", atlas)
	return _crater_material


func _terrain_placement(impact_position: Vector3) -> Dictionary:
	var fallback := {
		"position": impact_position,
		"normal": Vector3.UP,
	}
	if get_world_3d() == null:
		return fallback
	var hit := TerrainProbeScript.cast(
		get_world_3d(),
		impact_position + Vector3.UP * RAY_HEIGHT,
		impact_position + Vector3.DOWN * RAY_DEPTH,
		TERRAIN_COLLISION_MASK
	)
	if hit.is_empty():
		return fallback
	var normal := Vector3(hit.get("normal", Vector3.UP)).normalized()
	if normal.is_zero_approx():
		normal = Vector3.UP
	return {
		"position": Vector3(hit["position"]),
		"normal": normal,
	}


func _maximum_decal_count() -> int:
	var settings: Resource = _game_settings_catalog.settings()
	if settings == null:
		return GameSettingsScript.DEFAULT_MAXIMUM_GROUND_DECALS
	return maxi(int(settings.maximum_ground_decals), 0)


func _fade_older_overlapping_decals() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var radius := float(get_meta("decal_radius", 0.0))
	var sequence := int(get_meta("decal_sequence", 0))
	for child in parent.get_children():
		if (
			child == self
			or not child is Node3D
			or not child.has_meta("combat_ground_decal")
			or int(child.get_meta("decal_sequence", 0)) >= sequence
		):
			continue
		var other_radius := float(child.get_meta("decal_radius", 0.0))
		if other_radius <= 0.0:
			continue
		var maximum_distance := radius + other_radius
		if global_position.distance_squared_to(child.global_position) \
		> maximum_distance * maximum_distance:
			continue
		var fade_steps := int(child.get_meta("overlap_fade_steps", 0)) + 1
		if fade_steps >= MAXIMUM_OVERLAPPING_DECALS:
			child.free()
			continue
		child.set_meta("overlap_fade_steps", fade_steps)
		_set_decal_opacity(
			child as Node3D,
			1.0 - float(fade_steps) / float(MAXIMUM_OVERLAPPING_DECALS)
		)


func _set_decal_opacity(decal: Node3D, opacity: float) -> void:
	var mesh_instance := decal.get_node_or_null("Decal") as MeshInstance3D
	if mesh_instance == null or not mesh_instance.mesh is PlaneMesh:
		return
	mesh_instance.set_instance_shader_parameter(
		&"decal_opacity", clampf(opacity, 0.0, 1.0)
	)


func _enforce_parent_budget(maximum_decal_count: int) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var decals: Array[Node] = []
	for child in parent.get_children():
		if child.has_meta("combat_ground_decal"):
			decals.append(child)
	if decals.size() <= maximum_decal_count:
		return
	var oldest: Node = decals.front()
	for candidate in decals:
		if int(candidate.get_meta("decal_sequence", 0)) \
		< int(oldest.get_meta("decal_sequence", 0)):
			oldest = candidate
	oldest.free()
