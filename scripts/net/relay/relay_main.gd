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
##   --port <int>              default 8910
##   --max-room-size <int>     default 4 (the v0.4 player cap)
##   --max-connections <int>   default 128 (see RelayServer.max_connections)
##   --max-rooms <int>         default 16 (see RelayServer.max_rooms)
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
## These three mirror RelayServer's own field defaults (max_room_size,
## max_connections, max_rooms) by hand, same as DEFAULT_MAX_ROOM_SIZE always
## has -- there is no single source of truth to read from without
## instantiating a server before argument parsing runs, and these defaults
## rarely change; see RelayServer's doc comments on each field for why the
## specific numbers were chosen.
const DEFAULT_MAX_ROOM_SIZE := 4
const DEFAULT_MAX_CONNECTIONS := 128
const DEFAULT_MAX_ROOMS := 16

## How long the process may sleep between main-loop iterations, and with it
## how long a frame can sit in the relay before being forwarded: poll() runs
## once per iteration (see _on_process_frame), so this is the relay's own
## contribution to end-to-end latency, paid on every frame of every turn.
##
## The default is not fit for a server, which is why this file overrides it.
## Measured in the project's container with a standalone frame-period probe,
## alongside what each setting cost end to end in tools/measure_nagle.py's
## relay direction (median excess delay over the sender's own spacing):
##
##   as shipped (max_fps=60 from project.godot)   16.61 ms/iter   6.66 ms
##   max_fps raised, engine default sleep          6.88 ms/iter   3.78 ms
##   this setting                                  1.00 ms/iter   0.02 ms
##
## Both defaults come from the game, not from this server. project.godot sets
## run/max_fps=60 -- right for a game that renders, meaningless for a process
## that only pumps sockets, and it alone was costing up to 16.6 ms per
## forwarded frame, over a third of a 40 ms tick at 25 Hz. Clearing max_fps
## then exposes a second, lower floor: Godot sleeps
## low_processor_usage_mode_sleep_usec between iterations, 6900 by default.
## Note that it applies that sleep in a headless run even though
## OS.low_processor_usage_mode itself reads back false, so clearing the flag
## is not what removes it -- the sleep length has to be set directly, which is
## what this constant does.
##
## 1 ms rather than 0: an uncapped loop would spin a core at 100% for a
## process whose entire job is to wait for sockets, and the remaining
## sub-millisecond has no value next to a 40 ms tick. The 1 ms loop is close
## to free -- over ten idle seconds it burned 0.44 s of CPU against 0.33 s at
## the engine default, so roughly one extra percent of one core buys back
## 6.6 ms on every forwarded frame.
const POLL_SLEEP_USEC := 1000

var _server: RelayServerScript


func _initialize() -> void:
	# Both of these are game settings this server inherits and neither is
	# right for it; see POLL_SLEEP_USEC for the measurements. max_fps is
	# cleared rather than raised because the sleep below is what should pace
	# this loop -- leaving both in play would just mean two limits to keep in
	# agreement.
	Engine.max_fps = 0
	OS.low_processor_usage_mode_sleep_usec = POLL_SLEEP_USEC
	var args := _parse_args(OS.get_cmdline_user_args())
	_server = RelayServerScript.new()
	_server.max_room_size = args.max_room_size
	_server.max_connections = args.max_connections
	_server.max_rooms = args.max_rooms
	var err := _server.start(args.port)
	if err != OK:
		printerr("relay: could not listen on port %d (%s)" % [args.port, error_string(err)])
		quit(1)
		return
	# Every limit that can turn away a real connection gets named here, not
	# just the port -- an operator who never sees this line has no way to
	# know what a rejected friend's close code actually means without
	# re-reading this file's --help text.
	print(
		"relay: listening on port %d, max room size %d, max connections %d, max rooms %d"
		% [args.port, args.max_room_size, args.max_connections, args.max_rooms]
	)
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
	var result := {
		"port": DEFAULT_PORT,
		"max_room_size": DEFAULT_MAX_ROOM_SIZE,
		"max_connections": DEFAULT_MAX_CONNECTIONS,
		"max_rooms": DEFAULT_MAX_ROOMS,
	}
	var i := 0
	while i < cmdline_args.size():
		var arg := cmdline_args[i]
		if arg == "--port" and i + 1 < cmdline_args.size():
			result.port = int(cmdline_args[i + 1])
			i += 2
		elif arg == "--max-room-size" and i + 1 < cmdline_args.size():
			result.max_room_size = int(cmdline_args[i + 1])
			i += 2
		elif arg == "--max-connections" and i + 1 < cmdline_args.size():
			result.max_connections = int(cmdline_args[i + 1])
			i += 2
		elif arg == "--max-rooms" and i + 1 < cmdline_args.size():
			result.max_rooms = int(cmdline_args[i + 1])
			i += 2
		else:
			i += 1
	return result
