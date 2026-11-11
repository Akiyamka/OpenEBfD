extends RefCounted


static func measure(cargo: Unit, carrier: Unit) -> Dictionary:
	# Rotate the former carrier after release so a stale reference has a distinct basis.
	carrier.global_basis = Basis(Vector3.UP, PI * 0.5)
	cargo.global_basis = Basis.IDENTITY
	var own_basis := cargo.global_basis
	var stale_basis := carrier.global_basis
	var root_position: Vector3 = cargo.simulation_position()
	var centre: Vector3 = cargo.combat_geometry().get("_aim_centre")
	var collision = cargo.get("_authored_collision")
	var separated := false
	var public_agrees := true
	for xi in 37:
		var from := root_position + Vector3(-1.8 + xi * 0.1, 0.8, -5.0)
		var to := from + Vector3(0.0, 0.0, 10.0)
		var own: Dictionary = collision.projectile_contact(from, to, root_position, 0.0, own_basis, false)
		var stale: Dictionary = collision.projectile_contact(from, to, root_position, 0.0, stale_basis, false)
		if own.is_empty() == stale.is_empty():
			continue
		separated = true
		public_agrees = cargo.projectile_hull_contact(from, to, root_position, 0.0).is_empty() == own.is_empty()
		break
	return {"separated": separated, "public_agrees": public_agrees,
		"basis_own": cargo.combat_geometry().combat_basis().x.distance_to(own_basis.x) < 0.001,
		"basis_stale": cargo.combat_geometry().combat_basis().x.distance_to(stale_basis.x) < 0.001,
		"aim_own": cargo.combat_aim_position().distance_to(root_position + own_basis * centre) < 0.001,
		"aim_stale": cargo.combat_aim_position().distance_to(root_position + stale_basis * centre) < 0.001}
