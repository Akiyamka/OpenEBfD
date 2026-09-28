class_name RecordingTransport
extends NetTransport

## Test-only sink that records sent frames while retaining NullTransport's
## lifecycle, so Match can open it without a test-specific path.

var _state := State.DISCONNECTED
var _last_error := ""
var sent_frames: Array[PackedByteArray] = []


func open(_address: String) -> void:
	_state = State.CONNECTED


func close() -> void:
	_state = State.DISCONNECTED


func send(payload: PackedByteArray) -> void:
	if _state != State.CONNECTED:
		_last_error = "cannot send: recording transport is not connected"
		return
	sent_frames.append(payload)


func poll() -> Array[PackedByteArray]:
	return []


func state() -> State:
	return _state


func last_error() -> String:
	return _last_error
