extends SceneTree

## Executable entry point for the relay server -- see relay_server.gd for the
## actual logic, which this script only starts, pumps and logs. Run as:
##
##   ./tools/godot-container godot --headless --path /workspace \
##     --script res://scripts/net/relay/relay_main.gd -- --port 8910
##
## Args after the `--` separator are read via OS.get_cmdline_user_args()
## (Godot does not try to interpret them itself). Recognized:
##
##   --port <int>            default 8910
##   --max-room-size <int>   default 4 (the v0.4 player cap)
##
## Unlike the converters under converters/, which are one-shot scripts that
## call quit() once their work is done, this one is a server: it never calls
## quit() on its own and keeps running, pumped once per engine frame through
## the SceneTree's own `process_frame` signal. Real time and engine polling
## are fine here -- this file, like relay_server.gd, is not part of the
## deterministic simulation in scripts/sim/, and the determinism rules in
## docs/architecture/network-multiplayer.md do not apply to it.

const RelayServerScript := preload("res://scripts/net/relay/relay_server.gd")

const DEFAULT_PORT := 8910
const DEFAULT_MAX_ROOM_SIZE := 4

var _server: RelayServerScript


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	_server = RelayServerScript.new()
	_server.max_room_size = args.max_room_size
	var err := _server.start(args.port)
	if err != OK:
		printerr("relay: could not listen on port %d (%s)" % [args.port, error_string(err)])
		quit(1)
		return
	print("relay: listening on port %d, max room size %d" % [args.port, args.max_room_size])
	process_frame.connect(_on_process_frame)


func _on_process_frame() -> void:
	_server.poll()
	for event in _server.drain_events():
		print("relay: %s" % event)


## Parses the flat `--flag value` argv slice Godot hands us after `--` into a
## small dict of defaults overridden by whatever was recognized. Unknown
## flags and a trailing flag with no value are both silently skipped rather
## than treated as errors: this is a small self-hosted tool, not a CLI
## surface that needs to reject typos loudly.
func _parse_args(cmdline_args: PackedStringArray) -> Dictionary:
	var result := {"port": DEFAULT_PORT, "max_room_size": DEFAULT_MAX_ROOM_SIZE}
	var i := 0
	while i < cmdline_args.size():
		var arg := cmdline_args[i]
		if arg == "--port" and i + 1 < cmdline_args.size():
			result.port = int(cmdline_args[i + 1])
			i += 2
		elif arg == "--max-room-size" and i + 1 < cmdline_args.size():
			result.max_room_size = int(cmdline_args[i + 1])
			i += 2
		else:
			i += 1
	return result
