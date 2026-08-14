class_name SelectionTargetAbilityController
extends RefCounted
## Generic state holder for selection-targeted abilities.
##
## It owns hotkeys, active-mode cancellation and UI synchronization.  The
## adapter supplies definitions, validation, 3D cursor semantics and execute;
## no ability-specific condition leaks into UnitCommandController.

signal mode_changed(ability_id: StringName)
signal status_changed(status: String)

var _ability_bar
var _selection: Array[Node] = []
var _active_ability: StringName = &""
var _handlers: Array = []


func configure(ability_bar = null, handlers: Array = []) -> void:
	_ability_bar = ability_bar
	_handlers = handlers.duplicate()
	if _ability_bar != null and _ability_bar.has_signal("ability_pressed"):
		if not _ability_bar.ability_pressed.is_connected(_on_ability_pressed):
			_ability_bar.ability_pressed.connect(_on_ability_pressed)
	_refresh_bar()


func refresh() -> void:
	# Cargo state changes without a selection change, so refresh the narrow view
	# each frame.  No ability handler is allowed to mutate state from here.
	if not _contains_available(_active_ability):
		cancel()
	_refresh_bar()


func selection_changed(selection: Array[Node]) -> void:
	_selection = selection.duplicate()
	if not _active_ability.is_empty():
		cancel()
	_refresh_bar()


func active_ability() -> StringName:
	return _active_ability


func is_active() -> bool:
	return not _active_ability.is_empty()


func handle_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE:
		if is_active():
			cancel()
			return true
	var requested := _ability_for_key(event)
	if requested.is_empty():
		return false
	if not _contains_available(requested):
		return false
	if requested == _active_ability:
		cancel()
	else:
		_activate(requested)
	return true


func cancel() -> void:
	if _active_ability.is_empty():
		return
	_active_ability = &""
	if _ability_bar != null:
		_ability_bar.call("set_active_ability", _active_ability)
	mode_changed.emit(_active_ability)


func cursor_for(target, world_position := Vector3.INF) -> int:
	var handler = _handler_for(_active_ability)
	return int(handler.call("cursor_for", _active_ability, _selection, target, world_position)) \
		if handler != null else 0


func execute(target, world_position := Vector3.INF) -> bool:
	if _active_ability.is_empty():
		return false
	var handler = _handler_for(_active_ability)
	if handler == null:
		return false
	var result: Dictionary = handler.call("execute", _active_ability, _selection, target, world_position)
	if bool(result.get("ok", false)):
		status_changed.emit(String(result.get("message", "")))
		cancel()
		return true
	status_changed.emit(String(result.get("message", "Ability target is invalid")))
	return false


func _on_ability_pressed(ability_id: StringName) -> void:
	if ability_id == _active_ability:
		cancel()
	elif _contains_available(ability_id):
		_activate(ability_id)


func _activate(ability_id: StringName) -> void:
	_active_ability = ability_id
	if _ability_bar != null:
		_ability_bar.call("set_active_ability", ability_id)
	mode_changed.emit(ability_id)


func _refresh_bar() -> void:
	if _ability_bar == null:
		return
	_ability_bar.call("set_abilities", _definitions())
	_ability_bar.call("set_active_ability", _active_ability)


func _contains_available(ability_id: StringName) -> bool:
	if ability_id.is_empty():
		return true
	for definition: Dictionary in _definitions():
		if StringName(definition.get("id", &"")) == ability_id \
		and bool(definition.get("enabled", true)):
			return true
	return false


func _ability_for_key(event: InputEventKey) -> StringName:
	for definition: Dictionary in _definitions():
		var keycode := int(definition.get("keycode", KEY_NONE))
		if keycode != KEY_NONE and (
			event.keycode == keycode
			or event.physical_keycode == keycode
			or event.key_label == keycode
		):
			return StringName(definition.get("id", &""))
	return &""


func _definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for handler in _handlers:
		if handler == null or not handler.has_method("definitions"):
			continue
		for definition in handler.call("definitions", _selection):
			if definition is Dictionary:
				result.append(definition)
	return result


func _handler_for(ability_id: StringName):
	for handler in _handlers:
		if handler == null or not handler.has_method("definitions"):
			continue
		for definition in handler.call("definitions", _selection):
			if definition is Dictionary and StringName(definition.get("id", &"")) == ability_id:
				return handler
	return null
