class_name SelectionHalo
extends Node3D

const HALO_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/!Halo.tga")
const HEALTH_TEXTURES := [
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health0.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health1.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health2.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health3.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health4.tga"),
	preload("res://assets/raw_original_content/3DDATA/Textures/@!Health5.tga"),
]
const EMPTY_SHIELD_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!EmptyShield.tga")
const SHIELD_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!Shield.tga")
const EMPTY_SPICE_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!EmptySpice.tga")
const SPICE_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!Spice.tga")
const EMPTY_HARVESTER_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!EmptyHarv.tga")
const HARVESTER_TEXTURE := preload("res://assets/raw_original_content/3DDATA/Textures/@!Harv.tga")
const HALO_SHADER := preload("res://scripts/ui/selection_halo.gdshader")
const ADDITIVE_SHADER := preload("res://scripts/ui/selection_halo_outline.gdshader")
const OUTLINE_ROTATION_SPEED := 0.5
const MOVEMENT_DIRECTION_COLOR := Color(1.0, 0.08, 0.82, 0.95)

var _entity: Node3D
var _is_selected := false
var _is_hovered := false
var _layers := {}
var _movement_arrow: MeshInstance3D
var _movement_arrow_mesh: ImmediateMesh
var _movement_arrow_material: StandardMaterial3D
var _movement_direction := Vector3.ZERO
var _movement_debug_visible := false
var _indicator_radius := 1.0
var _position_anchor: Node3D
## The unit-local position configure() was given -- the authored resting spot
## of this halo, with no interpolation offset in it. Only the no-anchor
## fallback in _process() below reads it; see set_visual_offset().
var _rest_position := Vector3.ZERO
## Slice B4's per-frame view-interpolation offset, in the same unit-local
## space as `position`, pushed by Unit._advance_visual_interpolation(). Only
## consumed on the fallback path -- see set_visual_offset().
var _visual_offset := Vector3.ZERO


func configure(
	entity: Node3D,
	radius: float,
	local_position: Vector3,
	position_anchor: Node3D = null,
) -> void:
	_entity = entity
	_position_anchor = position_anchor
	_indicator_radius = maxf(radius, 0.1)
	_rest_position = local_position
	position = local_position
	var diameter := maxf(radius * 2.0, 0.1)
	_layers[&"outline"] = _add_layer(&"Outline", HALO_TEXTURE, diameter, 0.000, false, ADDITIVE_SHADER)
	_layers[&"health"] = _add_layer(&"Health", HEALTH_TEXTURES[5], diameter, 0.002, true)
	_layers[&"empty_shield"] = _add_layer(&"EmptyShield", EMPTY_SHIELD_TEXTURE, diameter, 0.004, false, ADDITIVE_SHADER)
	_layers[&"shield"] = _add_layer(&"Shield", SHIELD_TEXTURE, diameter, 0.006, true)
	# Spice and carryall/harvester status use separate authored rings. This
	# gameplay HUD uses @!Harv for the harvester's bunker fill.
	_layers[&"empty_spice"] = _add_layer(&"EmptySpice", EMPTY_SPICE_TEXTURE, diameter, 0.008, false, ADDITIVE_SHADER)
	_layers[&"spice"] = _add_layer(&"Spice", SPICE_TEXTURE, diameter, 0.010, true)
	_layers[&"empty_transport"] = _add_layer(&"EmptyTransport", EMPTY_HARVESTER_TEXTURE, diameter, 0.012, false, ADDITIVE_SHADER)
	_layers[&"transport"] = _add_layer(&"Transport", HARVESTER_TEXTURE, diameter, 0.014, true)
	_add_movement_arrow()
	_refresh()


func set_selected(value: bool) -> void:
	_is_selected = value
	if value:
		_rebuild_movement_arrow()
	_refresh_visibility()


func set_hovered(value: bool) -> void:
	_is_hovered = value
	_refresh_visibility()


## World-space final steering direction supplied to Unit.navigation_step. The
## halo cancels its parent's yaw below, so these local vertices stay aligned
## with world axes and visibly expose 180-degree steering flip-flops.
func set_movement_direction(value: Vector3) -> void:
	var horizontal := Vector3(value.x, 0.0, value.z)
	var direction := horizontal.normalized() if not horizontal.is_zero_approx() else Vector3.ZERO
	if direction.is_equal_approx(_movement_direction):
		return
	_movement_direction = direction
	# Every unit receives steering updates, but mesh allocation is useful only
	# for selected units. A later selection rebuilds from the stored direction.
	if _is_selected:
		_rebuild_movement_arrow()
	_refresh_visibility()


## Slice B4: the offset Unit._advance_visual_interpolation() has just applied
## to `visual_root` this frame, in unit-local space.
##
## The halo was deliberately **not** re-parented under `visual_root` to make it
## follow the interpolated model, for two reasons. `visual_root` carries the
## slope-alignment tilt (UnitTerrainAlignment.advance_slope_alignment()), which
## would tip a ground decal off the ground; and the horizontality rule in
## _process() below, `rotation.y = -_entity.rotation.y`, is written against
## Unit being this node's parent and would cancel the wrong yaw under any
## other one.
##
## It does not need re-parenting anyway on the ordinary path: `_position_anchor`
## is the authored #^^0 attachment *inside* the model, so
## `_entity.to_local(_position_anchor.to_global(...))` below already re-derives
## the interpolated position every frame at no cost. 90 of this project's 99
## unit scenes have that anchor. The remaining 9 -- the two worms, the storm
## unit, the Death Hand and the five story/hero characters, whose source XBF
## carries no #^^0 at all -- fall through to a fixed local position instead,
## and would otherwise be the one thing on a unit that does not follow its own
## interpolated model. This is what carries the offset to them explicitly.
func set_visual_offset(value: Vector3) -> void:
	_visual_offset = value


func set_movement_debug_visible(value: bool) -> void:
	_movement_debug_visible = value
	_refresh_visibility()


func is_movement_debug_visible() -> bool:
	return _movement_debug_visible


func _process(delta: float) -> void:
	if _entity == null:
		return
	# #^^0 is an authored attachment, not merely a spawn-time hint. Some units
	# move it during animation (Kobra raises it while deploying), so follow its
	# position every frame while keeping the indicator itself horizontal.
	if is_instance_valid(_position_anchor):
		position = _entity.to_local(_position_anchor.to_global(Vector3.ZERO))
	else:
		# No authored #^^0 on this model: nothing above re-derives the halo's
		# position from inside the interpolated subtree, so apply slice B4's
		# offset by hand. See set_visual_offset() for why re-parenting under
		# visual_root was rejected instead.
		position = _rest_position + _visual_offset
	# Units rotate while moving, but the original indicators retain their north
	# orientation.  The parent only rotates around Y, so cancel just that axis.
	rotation.y = -_entity.rotation.y
	# Only the decorative outline spins; the status indicators remain readable.
	var outline: MeshInstance3D = _layers[&"outline"]
	outline.rotation.y = fposmod(outline.rotation.y + OUTLINE_ROTATION_SPEED * delta, TAU)
	_refresh()


func _refresh() -> void:
	if _entity == null:
		return
	var health_fraction := _fraction(&"health", &"max_health")
	var health_index := mini(floori(health_fraction * 6.0), HEALTH_TEXTURES.size() - 1)
	_set_layer(&"health", HEALTH_TEXTURES[health_index], health_fraction, true)

	var has_shields := _number(&"max_shields") > 0.0
	_layers[&"empty_shield"].visible = has_shields
	_layers[&"shield"].visible = has_shields
	_set_layer(&"shield", SHIELD_TEXTURE, _fraction(&"shields", &"max_shields"), true)

	var has_spice_capacity := _number(&"max_spice") > 0.0
	# The unit bunker is the @!Harv ring requested by the gameplay UI, so do not
	# draw a second @!Spice cargo ring over it.
	_layers[&"empty_spice"].visible = false
	_layers[&"spice"].visible = false

	var has_transport_capacity := _number(&"max_passengers") > 0.0
	var shows_harvester_ring := has_spice_capacity or has_transport_capacity
	_layers[&"empty_transport"].visible = shows_harvester_ring
	_layers[&"transport"].visible = shows_harvester_ring
	var harvester_fill := _fraction(&"spice", &"max_spice") \
		if has_spice_capacity else _fraction(&"passengers", &"max_passengers")
	_set_layer(&"transport", HARVESTER_TEXTURE, harvester_fill, true)
	_refresh_visibility()


func _refresh_visibility() -> void:
	visible = _is_selected or _is_hovered
	if _movement_arrow != null:
		_movement_arrow.visible = _movement_debug_visible \
			and _is_selected and not _movement_direction.is_zero_approx()


func _fraction(current: StringName, maximum: StringName) -> float:
	var max_value := _number(maximum)
	return clampf(_number(current) / max_value, 0.0, 1.0) if max_value > 0.0 else 0.0


func _number(property: StringName) -> float:
	if _entity == null or not property in _entity:
		return 0.0
	return float(_entity.get(property))


func _add_layer(
	layer_name: StringName,
	texture: Texture2D,
	diameter: float,
	height: float,
	masked := false,
	shader: Shader = HALO_SHADER,
) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(diameter, diameter)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"indicator_texture", texture)
	material.set_shader_parameter(&"apply_radial_mask", masked)
	var layer := MeshInstance3D.new()
	layer.name = String(layer_name)
	layer.mesh = mesh
	layer.material_override = material
	layer.position.y = height
	add_child(layer)
	return layer


func _add_movement_arrow() -> void:
	_movement_arrow = MeshInstance3D.new()
	_movement_arrow.name = "MovementDirection"
	_movement_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_movement_arrow.extra_cull_margin = 2.0
	_movement_arrow.position.y = 0.03
	add_child(_movement_arrow)
	_movement_arrow_mesh = ImmediateMesh.new()
	_movement_arrow_material = StandardMaterial3D.new()
	_movement_arrow_material.albedo_color = MOVEMENT_DIRECTION_COLOR
	_movement_arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_movement_arrow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_movement_arrow_material.no_depth_test = true
	_movement_arrow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_movement_arrow_material.render_priority = 20
	_rebuild_movement_arrow()


func _rebuild_movement_arrow() -> void:
	if _movement_arrow == null:
		return
	_movement_arrow_mesh.clear_surfaces()
	if _movement_direction.is_zero_approx():
		_movement_arrow.mesh = null
		return
	_movement_arrow_mesh.surface_begin(
		Mesh.PRIMITIVE_TRIANGLES, _movement_arrow_material
	)
	var direction := _movement_direction
	var lateral := Vector3(-direction.z, 0.0, direction.x)
	var start_distance := maxf(_indicator_radius * 0.65, 0.3)
	var arrow_length := maxf(_indicator_radius * 2.5, 1.5)
	var head_length := minf(arrow_length * 0.4, maxf(_indicator_radius * 0.8, 0.5))
	var shaft_half_width := maxf(_indicator_radius * 0.10, 0.08)
	var head_half_width := maxf(_indicator_radius * 0.32, 0.24)
	var start := direction * start_distance
	var tip := direction * (start_distance + arrow_length)
	var neck := tip - direction * head_length
	var shaft_left := lateral * shaft_half_width
	var head_left := lateral * head_half_width
	_add_arrow_triangle(
		_movement_arrow_mesh, start - shaft_left, neck - shaft_left, neck + shaft_left
	)
	_add_arrow_triangle(
		_movement_arrow_mesh, start - shaft_left, neck + shaft_left, start + shaft_left
	)
	_add_arrow_triangle(_movement_arrow_mesh, neck - head_left, tip, neck + head_left)
	_movement_arrow_mesh.surface_end()
	_movement_arrow.mesh = _movement_arrow_mesh


func _add_arrow_triangle(mesh: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3) -> void:
	mesh.surface_add_vertex(a)
	mesh.surface_add_vertex(b)
	mesh.surface_add_vertex(c)


func _set_layer(layer_id: StringName, texture: Texture2D, fill: float, masked: bool) -> void:
	var layer: MeshInstance3D = _layers[layer_id]
	var material := layer.material_override as ShaderMaterial
	material.set_shader_parameter(&"indicator_texture", texture)
	material.set_shader_parameter(&"fill", fill)
	material.set_shader_parameter(&"apply_radial_mask", masked)
