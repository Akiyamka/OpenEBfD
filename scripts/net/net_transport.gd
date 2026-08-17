class_name NetTransport
extends RefCounted

## Thin, engine-agnostic contract shared by every command-frame transport:
## WebSocket (the only one shipping in v0.4), the in-memory loopback used by
## headless tests (`loopback_transport.gd`), and — maybe never — ENet. See
## `docs/architecture/network-multiplayer.md`, "WebSocket behind a transport
## interface". A concrete transport extends this and overrides every method
## below; the bodies here are not usable defaults, they exist only to fail
## loudly — `push_error` naming the method, plus a safe empty value so a
## caller that does not check the error still cannot crash or silently
## believe the call succeeded — when a subclass forgets to override one.
##
## Deliberately named open/close/send/poll/state/last_error rather than
## connect/disconnect: `connect`/`disconnect` already exist on every `Object`
## (signal wiring), and shadowing them is a bug waiting to happen.
##
## Named `NetTransport` rather than the shorter `Transport`: this codebase
## already uses "transport" for a carryall carrying a unit
## (`AdvancedCarryallTransport`, `unit_locomotion.gd`), and `class_name` is a
## single shared global namespace — a bare `Transport` meaning "network
## socket" would collide with that existing meaning.

enum State {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
	FAILED,
}


## Begins connecting to `address`. Address syntax is transport-defined (a
## `ws://` URL for WebSocket; ignored entirely by the loopback transport —
## see `loopback_transport.gd`). Must not block: state() reports CONNECTING
## until the attempt resolves to CONNECTED or FAILED.
func open(_address: String) -> void:
	_report_not_overridden("open")


## Closes the connection and releases transport-owned resources, moving
## state() to DISCONNECTED. Idempotent: calling it again once already
## disconnected must not be an error.
func close() -> void:
	_report_not_overridden("close")


## Queues `payload` for delivery to whoever is on the other end of this
## transport. Must not block. A transport that is not CONNECTED treats this
## as a no-op and records the reason in last_error() instead of raising.
func send(_payload: PackedByteArray) -> void:
	_report_not_overridden("send")


## Returns every payload received since the last call to poll(), oldest
## first, and drains them: each payload is returned by exactly one poll()
## call, so an immediate second call returns an empty array until more
## arrives.
func poll() -> Array[PackedByteArray]:
	_report_not_overridden("poll")
	return []


## Current connection state.
func state() -> State:
	_report_not_overridden("state")
	return State.DISCONNECTED


## Human-readable detail for the most recent failure, drop or rejected call,
## or an empty string if nothing has gone wrong. Implementations may
## overwrite rather than accumulate; callers should not rely on history.
func last_error() -> String:
	_report_not_overridden("last_error")
	return ""


func _report_not_overridden(method_name: String) -> void:
	push_error("NetTransport.%s() was not overridden by the concrete transport" % method_name)
