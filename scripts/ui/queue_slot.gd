class_name QueueSlot
extends Button
## One icon slot in the production grid.
## DISABLED hides unavailable technology options, BLOCKED shows a grey icon
## for an occupied queue, AVAILABLE the colored icon, PROGRESS blends both
## with a clockwise radial mask (see queue_slot.gdshader), READY shows the
## colored icon with a READY caption, and PLACING keeps the colored icon while
## showing the building-in-flight caption.

enum State {
	DISABLED, AVAILABLE, PROGRESS, READY, BLOCKED,
	PLACING, # A placement command is in flight; the controller caption is BUILDING.
}

const SLOT_SHADER := preload("res://scripts/ui/queue_slot.gdshader")
const ICON_MARGIN := 3

signal intent_pressed(button_index: int, quantity: int)

var icon_colored: Texture2D:
	set(value):
		icon_colored = value
		_apply()
var icon_grey: Texture2D:
	set(value):
		icon_grey = value
		_apply()
var state: State = State.DISABLED:
	set(value):
		state = value
		_apply()
## 0..100, only visible in PROGRESS state.
var progress: float = 0.0:
	set(value):
		progress = clampf(value, 0.0, 100.0)
		_apply()
var status_text := "":
	set(value):
		status_text = value
		_apply()
var quantity := 0:
	set(value):
		quantity = maxi(value, 0)
		_apply()

var _icon_rect: TextureRect
var _icon_material: ShaderMaterial
var _status: Label
var _quantity: Label


func _init() -> void:
	# Arrow keys belong to camera movement. Production slots are mouse-driven
	# and must not enter Godot's keyboard focus navigation after being clicked.
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	_icon_material = ShaderMaterial.new()
	_icon_material.shader = SLOT_SHADER

	_icon_rect = TextureRect.new()
	_icon_rect.material = _icon_material
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_rect.set_anchors_and_offsets_preset(
		Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, ICON_MARGIN
	)
	add_child(_icon_rect)

	_status = Label.new()
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_status)

	_quantity = Label.new()
	_quantity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quantity.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_quantity.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_quantity.set_anchors_and_offsets_preset(
		Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, ICON_MARGIN
	)
	add_child(_quantity)

	_apply()


func _get_tooltip(_at_position: Vector2) -> String:
	# The icon (and its name/cost tooltip) is hidden in DISABLED state, so the
	# tooltip must follow -- otherwise an invisible slot still reveals its
	# content on hover.
	return tooltip_text if _icon_rect != null and _icon_rect.visible else ""


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	if state == State.PLACING:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		intent_pressed.emit(MOUSE_BUTTON_LEFT, 10 if event.shift_pressed else 1)
		accept_event()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		intent_pressed.emit(MOUSE_BUTTON_RIGHT, 10 if event.shift_pressed else 1)
		accept_event()


func _apply() -> void:
	if _icon_rect == null:
		return

	# Disabled technology keeps its physical grid cell but exposes no icon.
	# This is what makes authored roster positions stable as tech unlocks.
	_icon_rect.visible = icon_colored != null and state != State.DISABLED
	_icon_rect.texture = icon_colored
	_quantity.text = str(quantity) if quantity > 0 else ""
	_quantity.visible = quantity > 0
	# With no grey variant, fall back to the colored icon on both sides of the mask.
	_icon_material.set_shader_parameter("grey_texture", icon_grey if icon_grey else icon_colored)

	disabled = state == State.DISABLED or state == State.BLOCKED or icon_colored == null
	match state:
		State.DISABLED, State.BLOCKED:
			_icon_material.set_shader_parameter("progress", 0.0)
			_status.text = ""
		State.AVAILABLE:
			_icon_material.set_shader_parameter("progress", 1.0)
			_status.text = ""
		State.PROGRESS:
			_icon_material.set_shader_parameter("progress", progress / 100.0)
			_status.text = status_text
		State.READY:
			_icon_material.set_shader_parameter("progress", 1.0)
			_status.text = status_text if not status_text.is_empty() else "READY"
		State.PLACING:
			_icon_material.set_shader_parameter("progress", 1.0)
			_status.text = status_text
