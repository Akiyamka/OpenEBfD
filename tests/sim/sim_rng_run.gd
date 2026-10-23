extends "res://tests/support/suite.gd"

const SimRngScript := preload("res://scripts/sim/sim_rng.gd")


func _initialize() -> void:
	_run_case("independent keyed reference vectors", _vectors)
	_run_case("keys isolate outcomes and audit order commutes", _keyed_audit)
	_run_case("Q24 fraction and bounded retry retain the next index", _bounded)
	_run_case("audit capture and restore", _restore)
	_finish("Simulation RNG tests")


func _vectors() -> void:
	var first = SimRngScript.new(1)
	_expect(first.draw(1, 1, 0, 0, 0) == 0xd7c4b62b, "first reference vector")
	_expect(first.draw(1, 1, 0, 0, 1) == 0x3d12f3b1, "second reference vector")
	var negative = SimRngScript.new(-7)
	_expect(negative.draw(3, -2, 99, 1160, 4) == 0xc451121b, "signed reference vector")


func _keyed_audit() -> void:
	var a = SimRngScript.new(41)
	var b = SimRngScript.new(41)
	var first := a.draw(1, 17, -2, 8, 0)
	var second := a.draw(2, 17, -2, 8, 0)
	_expect(first != second, "different purposes must differ")
	_expect(first != a.draw(1, 18, -2, 8, 0), "different entities must differ")
	_expect(first != a.draw(1, 17, -2, 9, 0), "different ticks must differ")
	_expect(first != a.draw(1, 17, -2, 8, 1), "different ordinals must differ")
	var ordered = SimRngScript.new(41)
	ordered.draw(1, 17, -2, 8, 0)
	ordered.draw(2, 17, -2, 8, 0)
	_expect(b.draw(2, 17, -2, 8, 0) == second, "interleaving may not shift a keyed result")
	_expect(b.draw(1, 17, -2, 8, 0) == first, "reordered draw returns the same key")
	_expect(b.draw_count == ordered.draw_count, "same draw multiset has same count")
	_expect(b.draw_signature == ordered.draw_signature, "same draw multiset has same signature")
	b.draw(1, 17, -2, 8, 0)
	_expect(b.draw_count == ordered.draw_count + 1, "duplicate call increments count")
	_expect(b.draw_signature != ordered.draw_signature, "duplicate call changes signature")


func _bounded() -> void:
	var rng = SimRngScript.new(1)
	var fraction := rng.unit_fraction(1, 1, 0, 0, 0)
	_expect(fraction >= 0.0 and fraction < 1.0, "Q24 fraction lies in [0, 1)")
	_expect(is_equal_approx(fraction, float(0xd7c4b62b & 0xffffff) / 16777216.0), "Q24 uses low 24 bits")
	var index := 0
	while SimRngScript._sample(1, 1, 1, 0, 0, index) < 0x80000001:
		index += 1
		if index > 100:
			_expect(false, "test requires a rejected starting sample")
			return
	var before: int = rng.draw_count
	var outcome: Dictionary = rng.bounded(1, 1, 0, 0, index, 0x80000001)
	_expect(bool(outcome["ok"]), "bounded draw completes after rejection")
	_expect(int(outcome["next_index"]) > index + 1, "rejected tuple advances the next index")
	_expect(rng.draw_count == before + int(outcome["next_index"]) - index, "each retry is audited")
	var next_value := rng.draw(1, 1, 0, 0, int(outcome["next_index"]))
	_expect(next_value != SimRngScript._sample(1, 1, 1, 0, 0, index), "next event uses a new tuple")


func _restore() -> void:
	var source = SimRngScript.new(77)
	source.draw(3, 2, 1, 9, 0)
	var state: Dictionary = source.capture_audit()
	var restored = SimRngScript.new(77)
	_expect(restored.restore_audit(int(state["draw_count"]), int(state["draw_signature"])), "valid audit restores")
	_expect(restored.capture_audit() == state, "restored audit equals capture")
	_expect(not restored.restore_audit(-1, 0), "negative count is rejected")
