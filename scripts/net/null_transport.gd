class_name NullTransport
extends NetTransport

## A single-player sink: every payload sent while connected is deliberately
## discarded, and poll() never yields a frame. This is the production
## transport for a Match with no peers. Unlike delivery-capable transports,
## it is intentionally exempt from TransportConformance's self-fanout and
## oversized-payload-moves-to-FAILED assertions: losing every frame is this
## transport's contract, rather than a size-dependent delivery failure.

var _state := State.DISCONNECTED
var _last_error := ""


func open(_address: String) -> void:
	_state = State.CONNECTED


func close() -> void:
	_state = State.DISCONNECTED


func send(_payload: PackedByteArray) -> void:
	if _state != State.CONNECTED:
		_last_error = "cannot send: null transport is not connected"


func poll() -> Array[PackedByteArray]:
	return []


func state() -> State:
	return _state


func last_error() -> String:
	return _last_error
