class_name BuildingOptionState
extends RefCounted

enum State {
	AVAILABLE, DISABLED, BLOCKED, PROGRESS, READY,
	PLACING, # A placement command is in flight; the panel caption is BUILDING.
}

var building_id: StringName
var state: State
var progress: float
var status_text: String
var tooltip: String
## Unit production uses this for the number of items in its queue. Other
## option types leave it at zero and therefore show no count badge.
var quantity: int


static func availability_state(available: bool, blocked: bool) -> State:
	if not available:
		return State.DISABLED
	return State.BLOCKED if blocked else State.AVAILABLE


func _init(
		option_building_id: StringName,
		option_state: State,
		option_progress := 0.0,
		option_status_text := "",
		option_tooltip := "",
		option_quantity := 0
) -> void:
	building_id = option_building_id
	state = option_state
	progress = clampf(option_progress, 0.0, 100.0)
	status_text = option_status_text
	tooltip = option_tooltip
	quantity = maxi(option_quantity, 0)
