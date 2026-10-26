extends SceneTree

const SimRngScript := preload("res://scripts/sim/sim_rng.gd")
const BuildingSurvivorsScript := preload("res://scripts/buildings/building_survivors.gd")

func _initialize() -> void:
	var pairs := 10000
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pairs="):
			pairs = int(arg.trim_prefix("--pairs="))
	if pairs <= 0:
		printerr("FAIL: pairs must be positive")
		quit(1)
		return
	var keyed_times: Array[float] = []
	var native_times: Array[float] = []
	var sink := Vector3.ZERO
	for repeat in 3:
		var rng = SimRngScript.new(73)
		var started := Time.get_ticks_usec()
		for ordinal in pairs:
			sink += BuildingSurvivorsScript._scatter_offset(rng, Vector3(4, 0, 5), 3,
				ordinal, repeat + 1)
		keyed_times.append(float(Time.get_ticks_usec() - started) / float(pairs))
		if rng.draw_count != 2 * pairs:
			printerr("FAIL: helper audited %d draws, expected %d" % [rng.draw_count, 2 * pairs])
			quit(1)
			return
		started = Time.get_ticks_usec()
		for ordinal in pairs:
			sink += Vector3(randf_range(-4.0, 4.0), 0.7, randf_range(-5.0, 5.0))
		native_times.append(float(Time.get_ticks_usec() - started) / float(pairs))
	keyed_times.sort()
	native_times.sort()
	if not sink.is_finite():
		printerr("FAIL: offset sink is nonfinite")
		quit(1)
		return
	print("json: " + JSON.stringify({"ok": true, "pairs": pairs, "draws_per_repeat": 2 * pairs,
		"keyed_median_usec": keyed_times[1], "native_median_usec": native_times[1],
		"keyed_repeats_usec": keyed_times, "native_repeats_usec": native_times,
		"sink": sink}))
	quit(0)
