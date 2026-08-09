extends SceneTree
const ModelXbfScript := preload("res://converters/xbf/model_xbf.gd")
func _init() -> void:
	for f in OS.get_cmdline_user_args():
		var x = ModelXbfScript.load_file(f)
		print("=== ", f)
		var used := {}
		for e in x.fx_events:
			if String(e.get("attachment","")).begins_with("#"):
				var k := String(e.get("bank_id",""))
				if not used.has(k): used[k] = []
				used[k].append("%s:%s@%d" % [e.get("attachment",""), e.get("action",""), int(e["frame"])])
		for b in x.fx_banks:
			var id := String(b["id"])
			if not used.has(id): continue
			var w = b["parameter_words"]
			print("  tex=%s frames=%d life=%d burst=%d spread=%d speed=%.3f grav=%.3f size=%.1f w10=%d w11=%d w12=%.3f w13=%.4f" % [b["texture"], int(w[15]), int(w[2]), int(w[1]), int(w[3]), b["float_parameters_4_6"][0], b["gravity"], b["particle_size"], int(w[10]), int(w[11]), b["float_parameters_12_14"][0], b["float_parameters_12_14"][1]])
		print("    trail floats:")
		for b in x.fx_banks:
			if not used.has(String(b["id"])): continue
			var t = b["trailing_words"] as PackedInt32Array
			var bytes := PackedByteArray(); bytes.resize(4); bytes.encode_s32(0, t[7])
			print("      tex=%s trail=%s asfloat[7]=%.5f" % [b["texture"], t, bytes.decode_float(0)])
		for k in used: print("  events ", k, " ", ", ".join(PackedStringArray(used[k])))
	quit(0)
