extends "res://tests/support/suite.gd"
const SimMathScript := preload("res://scripts/sim/sim_math.gd")
const TAU_VALUE := 2.0 * PI

func _initialize() -> void:
	_run_case("axes, signed zero and half turns", _axes)
	_run_case("independently generated interpolation goldens", _goldens)
	_run_case("integer table accuracy over 200000 float32 headings", _sweep)
	_finish("SimMath tests")

func _axes() -> void:
	_expect(SimMathScript.bearing_units(0.0, 0.0) == 0, "zero bearing")
	_expect(SimMathScript.bearing_units(1.0, 0.0) == 0, "+X")
	_expect(SimMathScript.bearing_units(0.0, 1.0) == SimMathScript.QUARTER, "+Z")
	_expect(SimMathScript.bearing_units(0.0, -1.0) == -SimMathScript.QUARTER, "-Z")
	_expect(SimMathScript.bearing_units(-1.0, 0.0) == SimMathScript.HALF, "-X +zero")
	_expect(SimMathScript.bearing_units(-1.0, -0.0) == SimMathScript.HALF, "-X -zero")
	_expect(SimMathScript.signed_delta_units(0, -SimMathScript.HALF) == SimMathScript.HALF, "raw negative half")
	_expect(SimMathScript.signed_delta_units(0, SimMathScript.HALF) == -SimMathScript.HALF, "raw positive half")
	for angle in [0, SimMathScript.QUARTER, SimMathScript.HALF, -SimMathScript.QUARTER]:
		var pair := SimMathScript.sin_cos_units(angle)
		var legacy := Vector2(cos(float(angle) * TAU_VALUE / SimMathScript.TURN), sin(float(angle) * TAU_VALUE / SimMathScript.TURN))
		_expect(pair.distance_to(legacy) < 1e-7, "axis sine/cosine %d" % angle)

func _goldens() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/sim/sim_math_goldens.json"))
	for row in data["bearings"]:
		_expect(absi(SimMathScript.bearing_units(float(row[0]), float(row[1])) - int(row[2])) <= 1,
			"independent non-axis bearing %s" % str(row))
	for row in data["pairs"]:
		_expect(absi(SimMathScript._sine_q30(int(row[0]) + SimMathScript.QUARTER) - int(row[1])) <= 1 and
			absi(SimMathScript._sine_q30(int(row[0])) - int(row[2])) <= 1,
			"independent non-axis sine/cosine %s" % str(row))

func _sweep() -> void:
	var max_bearing := 0.0
	var max_direction := 0.0
	for i in 200000:
		var x := float((i * 1103515245 + 12345) % 2000001 - 1000000) / 1000000.0
		var z := float((i * 214013 + 2531011) % 2000001 - 1000000) / 1000000.0
		var vector := Vector2(x, z)
		if vector.length_squared() < 1e-10:
			continue
		var units: int = SimMathScript.bearing_units(vector.x, vector.y)
		var legacy := atan2(vector.y, vector.x)
		var got := float(units) * TAU_VALUE / SimMathScript.TURN
		max_bearing = maxf(max_bearing, absf(wrapf(got - legacy, -PI, PI)))
		var pair := SimMathScript.sin_cos_units(units)
		max_direction = maxf(max_direction, absf(pair.angle_to(Vector2(cos(legacy), sin(legacy)))) if pair.length_squared() > 0.0 else PI)
	print("SimMath sweep: max bearing %.9f rad, max direction %.9f rad" % [max_bearing, absf(max_direction)])
	_expect(max_bearing <= 1e-5, "bearing sweep tolerance")
	_expect(absf(max_direction) <= 1e-5, "direction sweep tolerance")
