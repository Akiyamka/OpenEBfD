extends SceneTree

const NullTransportScript := preload("res://scripts/net/null_transport.gd")
const NetTransportScript := preload("res://scripts/net/net_transport.gd")
const RelayProtocolScript := preload("res://scripts/net/relay_protocol.gd")

var _assertions := 0
var _failures := 0


func _initialize() -> void:
	var transport := NullTransportScript.new()
	_expect(transport.state() == NetTransportScript.State.DISCONNECTED, "a new null transport starts disconnected")
	transport.send(PackedByteArray([1]))
	_expect(transport.state() == NetTransportScript.State.DISCONNECTED, "send before open leaves state disconnected")
	var first_error := transport.last_error()
	_expect(not first_error.is_empty(), "send before open records an error")
	transport.open("")
	_expect(transport.state() == NetTransportScript.State.CONNECTED, "open connects synchronously")
	transport.send(PackedByteArray([1]))
	_expect(transport.state() == NetTransportScript.State.CONNECTED, "a connected send stays connected")
	_expect(transport.poll().is_empty(), "a connected send is discarded and never polled")
	_expect(transport.last_error() == first_error, "a successful send does not clear the prior error")
	var oversized := PackedByteArray()
	oversized.resize(RelayProtocolScript.MAX_INBOUND_FRAME_BYTES + 1)
	transport.send(oversized)
	_expect(transport.state() == NetTransportScript.State.CONNECTED, "an oversized sink payload does not fail the transport")
	transport.close()
	_expect(transport.state() == NetTransportScript.State.DISCONNECTED, "close disconnects")
	transport.close()
	_expect(transport.state() == NetTransportScript.State.DISCONNECTED, "close is idempotent")
	transport.send(PackedByteArray([2]))
	_expect(transport.state() == NetTransportScript.State.DISCONNECTED, "send after close leaves state disconnected")
	_expect(not transport.last_error().is_empty(), "send after close records an error")
	_finish()


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures += 1
		printerr("FAIL: %s" % message)


func _finish() -> void:
	if _failures > 0:
		printerr("Null transport tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Null transport tests: %d assertions passed" % _assertions)
	quit(0)
