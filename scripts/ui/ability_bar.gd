class_name AbilityBar
extends Control
## Small, selection-driven strip for map-targeted unit abilities.
##
## Composition supplies the currently available definitions instead of this
## view querying selected units itself.  Each definition is a Dictionary with
## `id` (StringName), `slot` (`pickup` or `drop`), and optional `enabled`,
## `label`, and `tooltip` fields.  Omitting a slot is allowed when the id is
## `pickup` or `drop`; the explicit slot keeps UI placement independent from
## command/controller names.

signal ability_pressed(ability_id: StringName)

const PICKUP_SLOT := &"pickup"
const DROP_SLOT := &"drop"

@onready var _buttons_by_slot: Dictionary = {
	PICKUP_SLOT: %PickupButton,
	DROP_SLOT: %DropButton,
}

var _definitions_by_slot: Dictionary = {}
var active_ability: StringName = &"":
	set(value):
		active_ability = value
		_apply_active_ability()


func _ready() -> void:
	for slot: StringName in _buttons_by_slot:
		var button: Button = _buttons_by_slot[slot]
		button.pressed.connect(_on_ability_button_pressed.bind(slot))
	_apply_definitions()
	_apply_active_ability()


## Replaces the complete available-ability set.  An absent slot is hidden;
## disabled abilities stay visible so input feedback may still explain why the
## selected action cannot presently be used.
func set_abilities(definitions: Array) -> void:
	_definitions_by_slot.clear()
	for definition in definitions:
		if not definition is Dictionary:
			continue
		var slot := _slot_for_definition(definition)
		if slot.is_empty():
			continue
		_definitions_by_slot[slot] = definition.duplicate()
	if not _contains_ability(active_ability):
		active_ability = &""
	_apply_definitions()
	_apply_active_ability()


func set_active_ability(ability_id: StringName) -> void:
	active_ability = ability_id


func _slot_for_definition(definition: Dictionary) -> StringName:
	var requested_slot := StringName(String(definition.get("slot", definition.get("id", &""))).to_lower())
	return requested_slot if requested_slot in _buttons_by_slot else &""


func _contains_ability(ability_id: StringName) -> bool:
	if ability_id.is_empty():
		return true
	for definition: Dictionary in _definitions_by_slot.values():
		if StringName(definition.get("id", &"")) == ability_id:
			return true
	return false


func _apply_definitions() -> void:
	if not is_node_ready():
		return
	for slot: StringName in _buttons_by_slot:
		var button: Button = _buttons_by_slot[slot]
		var definition: Dictionary = _definitions_by_slot.get(slot, {})
		button.visible = not definition.is_empty()
		if definition.is_empty():
			continue
		button.disabled = not bool(definition.get("enabled", true))
		button.text = String(definition.get("label", _default_label(slot)))
		button.tooltip_text = String(definition.get("tooltip", _default_tooltip(slot)))
	visible = not _definitions_by_slot.is_empty()


func _apply_active_ability() -> void:
	if not is_node_ready():
		return
	for slot: StringName in _buttons_by_slot:
		var button: Button = _buttons_by_slot[slot]
		var definition: Dictionary = _definitions_by_slot.get(slot, {})
		button.button_pressed = (
			not definition.is_empty()
			and StringName(definition.get("id", &"")) == active_ability
		)


func _on_ability_button_pressed(slot: StringName) -> void:
	var definition: Dictionary = _definitions_by_slot.get(slot, {})
	if definition.is_empty() or not bool(definition.get("enabled", true)):
		return
	var ability_id := StringName(definition.get("id", &""))
	if ability_id.is_empty():
		return
	ability_pressed.emit(ability_id)


func _default_label(slot: StringName) -> String:
	return "F" if slot == PICKUP_SLOT else "C"


func _default_tooltip(slot: StringName) -> String:
	return "Pick Up (F)" if slot == PICKUP_SLOT else "Drop Cargo (C)"
