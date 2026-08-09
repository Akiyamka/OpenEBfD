extends RefCounted


static func horizontal_angle_between(a: Vector3, b: Vector3) -> float:
	var a_horizontal := Vector2(a.x, a.z)
	var b_horizontal := Vector2(b.x, b.z)
	if a_horizontal.is_zero_approx() or b_horizontal.is_zero_approx():
		return 0.0
	return absf(angle_difference(a_horizontal.angle(), b_horizontal.angle()))
