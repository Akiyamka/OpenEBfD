class_name UnitShaderFx
extends RefCounted

## Drives the two continuously-phased shader effects on a unit's model: the
## energy shield (visible only while shields hold) and the converter-tagged
## scrolling meshes. A continuous phase cannot come from animation tracks — it
## would snap on every clip loop — and TIME in the shader would keep the editor
## viewport redrawing, so the owner advances `fx_time` from _process().
##
## This module DOES cache model nodes, so it implements the attach/detach
## protocol: attach_model() after any model swap, detach_model() before the
## model is handed to a corpse. Both are idempotent — a dying unit runs the
## handoff and then still gets _exit_tree().

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")

var _unit: CharacterBody3D
var _shield_meshes: Array[MeshInstance3D] = []
var _shield_time := 0.0
var _scroll_fx_meshes: Array[MeshInstance3D] = []
var _scroll_fx_time := 0.0
var _move_scroll_meshes: Array[MeshInstance3D] = []
var _move_scroll_phase := 0.0


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


## Re-reads both mesh sets off the unit's current model. Safe to call on a
## model that has none: both sets simply end up empty.
func attach_model() -> void:
	_shield_meshes.clear()
	_scroll_fx_meshes.clear()
	_move_scroll_meshes.clear()
	if _unit == null:
		return
	var visual_root: Node3D = _unit.visual_root
	for mesh_instance in AuthoredModelScript.mesh_instances(visual_root):
		var parent := mesh_instance.get_parent()
		if parent != null and String(parent.name).to_lower().contains("shield"):
			_shield_meshes.append(mesh_instance)
	_scroll_fx_meshes = AuthoredModelScript.scroll_fx_meshes(visual_root)
	_move_scroll_meshes = AuthoredModelScript.move_scroll_fx_meshes(visual_root)


## Drops every reference into the model subtree after hiding what this module
## turned on, so the corpse inherits an unlit model and this object holds
## nothing under it.
func detach_model() -> void:
	for mesh_instance in _shield_meshes:
		if is_instance_valid(mesh_instance):
			mesh_instance.visible = false
	for mesh_instance in _scroll_fx_meshes:
		if is_instance_valid(mesh_instance):
			mesh_instance.visible = false
	_shield_meshes.clear()
	_scroll_fx_meshes.clear()
	# Only released, never hidden: a track belt is ordinary hull geometry, not
	# an effect this module turned on, so hiding it would strip the tracks off
	# the corpse.
	_move_scroll_meshes.clear()


func dispose() -> void:
	detach_model()
	_shield_time = 0.0
	_scroll_fx_time = 0.0
	_move_scroll_phase = 0.0
	_unit = null


func advance(delta: float, shields: float) -> void:
	if shields > 0.0 and not _shield_meshes.is_empty():
		_shield_time += delta
		for mesh_instance in _shield_meshes:
			mesh_instance.set_instance_shader_parameter("fx_time", _shield_time)
	if not _scroll_fx_meshes.is_empty():
		_scroll_fx_time += delta
		for mesh_instance in _scroll_fx_meshes:
			mesh_instance.set_instance_shader_parameter("fx_time", _scroll_fx_time)
	if not _move_scroll_meshes.is_empty():
		# Metres driven, not elapsed time: a track belt stands still while the
		# unit idles or turns in place, and speeds up with it. How much UV that
		# is worth per metre is the material's own scroll_speed, since it
		# depends on how densely the belt texture is tiled on that model.
		_move_scroll_phase += (_unit.velocity as Vector3).length() * delta
		for mesh_instance in _move_scroll_meshes:
			mesh_instance.set_instance_shader_parameter("fx_time", _move_scroll_phase)


## Called from the shields setter, so the shield skin appears and disappears
## with the value rather than on the next frame.
func refresh_shield_visibility(shields: float) -> void:
	for mesh_instance in _shield_meshes:
		mesh_instance.visible = shields > 0.0
