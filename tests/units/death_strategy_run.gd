extends SceneTree

const InfantryDeathStrategyScript := preload("res://scripts/units/infantry_death_strategy.gd")
const VehicleDeathStrategyScript := preload("res://scripts/units/vehicle_death_strategy.gd")
const ExplosionTierPools := preload("res://scripts/audio/explosion_tier_pools.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	_run_case("infantry candidates match cause, travel", _test_infantry_candidates_travel)
	_run_case("infantry candidates prepend deployed variants", _test_infantry_candidates_deployed)
	_run_case("infantry candidates for an unmapped cause", _test_infantry_candidates_unknown_cause)
	_run_case("vehicle candidates are always Explode", _test_vehicle_candidates)
	_run_case("infantry Crush proposes the authored Run_Over_1 clip", _test_infantry_candidates_crush)
	_run_case("infantry death_start_sound_paths: only HKFlamer gets the small pool", _test_infantry_start_sound_paths)
	_run_case("vehicle death_vfx_sound_paths: explicit small units stay small", _test_vehicle_vfx_sound_paths_small)
	_run_case("vehicle death_vfx_sound_paths: aircraft use medium", _test_vehicle_vfx_sound_paths_aircraft)
	_run_case("vehicle death_vfx_sound_paths: ground units use large", _test_vehicle_vfx_sound_paths_ground)
	_run_case("vehicle death_start_sound_paths: Harkonnen gets the vehicle_* layer", _test_vehicle_start_sound_paths_harkonnen)
	_run_case("vehicle death_start_sound_paths: Ordos gets the ordos* layer", _test_vehicle_start_sound_paths_ordos)
	_run_case("vehicle death_start_sound_paths: Atreides/other factions get no extra layer", _test_vehicle_start_sound_paths_none)
	_run_case("infantry launch impulse: Blow_Up only", _test_infantry_launch_impulse)
	_run_case("vehicle launch impulse is always zero", _test_vehicle_launch_impulse)
	if _failures > 0:
		printerr("Death strategy tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Death strategy tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_infantry_candidates_travel() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	for cause_case in [
		[&"Blow_Up", [&"Blow_Up_1", &"Blow_Up_2"]],
		[&"Burn", [&"Burnt_1"]],
		[&"Gassed", [&"Gassed_1"]],
		[&"Shot", [&"Shot_1", &"Shot_2"]],
	]:
		var cause: StringName = cause_case[0]
		var expected: Array = cause_case[1]
		var candidates := strategy.death_animation_candidates(cause, false)
		_expect(
			candidates.size() == expected.size(),
			"%s (travel) must propose exactly %d candidates, got %d" % [cause, expected.size(), candidates.size()]
		)
		for name in expected:
			_expect(
				candidates.has(name),
				"%s (travel) candidates must include %s" % [cause, name]
			)


func _test_infantry_candidates_deployed() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var candidates := strategy.death_animation_candidates(&"Shot", true)
	_expect(
		candidates.size() == 4,
		"deployed Shot death must propose both deployed-death variants plus both Shot variants"
	)
	for name in [&"Deployed_Death_1", &"Deployed_Death_2"]:
		_expect(candidates.has(name), "deployed candidates must include %s" % name)
	for name in [&"Shot_1", &"Shot_2"]:
		_expect(candidates.has(name), "deployed candidates must still include the cause's own %s" % name)
	var deployed_index := mini(candidates.find(&"Deployed_Death_1"), candidates.find(&"Deployed_Death_2"))
	var shot_index := mini(candidates.find(&"Shot_1"), candidates.find(&"Shot_2"))
	_expect(
		deployed_index < shot_index,
		"deployed-death variants must be preferred (listed first) over the cause's own clips"
	)


func _test_infantry_candidates_unknown_cause() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	_expect(
		strategy.death_animation_candidates(&"", false).is_empty(),
		"an unrecognized cause with no deployment must propose no candidates"
	)
	var deployed_only := strategy.death_animation_candidates(&"", true)
	_expect(
		deployed_only.size() == 2,
		"an unrecognized cause while deployed must still propose the deployed-death variants"
	)


func _test_vehicle_candidates() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for cause in [&"", &"Blow_Up", &"Shot", &"Explode"]:
		for deployed in [false, true]:
			var candidates := strategy.death_animation_candidates(cause, deployed)
			_expect(
				candidates.size() == 1 and candidates[0] == &"Explode",
				"vehicle candidates must always be exactly [Explode], got %s (cause=%s, deployed=%s)" % [candidates, cause, deployed]
			)


## Crush is dormant — nothing produces the cause yet — but the clip mapping
## must stay wired so landing the gameplay needs no change here. `Run_Over_1`
## is the clip every crushable infantry model authors its `crush_guy_*` scream
## on (see tests/units/authored_death_voice_run.gd).
func _test_infantry_candidates_crush() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var candidates := strategy.death_animation_candidates(&"Crush", false)
	_expect(
		candidates == [&"Run_Over_1"],
		"Crush must propose exactly [Run_Over_1], got %s" % [candidates]
	)


## HKFlamer always gets a `small`-tier direct-WAV pool from
## death_start_sound_paths, unconditional on cause/faction; every other
## infantry unit gets none — scoped to HKFlamer alone since no equivalent
## hook exists for any other infantry unit.
func _test_infantry_start_sound_paths() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	for faction: StringName in [&"", &"Harkonnen", &"Atreides"]:
		var paths := strategy.death_start_sound_paths(faction, &"HKFlamer")
		_expect(
			paths == ExplosionTierPools.SMALL,
			"HKFlamer must always get the small-tier pool regardless of faction (%s), got %s" % [faction, paths]
		)
	_expect(
		strategy.death_start_sound_paths(&"Harkonnen", &"HKTrooper").is_empty(),
		"an ordinary infantry unit must get no self-destruct sound layer"
	)


func _test_vehicle_vfx_sound_paths_small() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	var cases := {
		&"ATTrike": ExplosionTierPools.SMALL,
		&"ATAPC": ExplosionTierPools.SMALL,
		&"ORDustScout": ExplosionTierPools.SMALL,
	}
	for config_id: StringName in cases:
		var paths := strategy.death_vfx_sound_paths(config_id)
		_expect(
			paths == cases[config_id],
			"%s must keep its explicit small-tier pool, got %s" % [config_id, paths]
		)


func _test_vehicle_vfx_sound_paths_aircraft() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for config_id in [&"ATOrni", &"HKGunship", &"Carryall", &"Frigate"]:
		var paths := strategy.death_vfx_sound_paths(config_id, true)
		_expect(
			paths == ExplosionTierPools.MEDIUM,
			"%s must use the medium-tier pool when flying, got %s" % [config_id, paths]
		)


func _test_vehicle_vfx_sound_paths_ground() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for config_id in [&"HKAssault", &"ATMongoose", &"ORAPC", &"Harvester", &"GUNIABTank"]:
		var paths := strategy.death_vfx_sound_paths(config_id, false)
		_expect(
			paths == ExplosionTierPools.LARGE,
			"%s must use the large-tier pool when grounded, got %s" % [config_id, paths]
		)


## Every Harkonnen vehicle gets the explosion_vehicle_* pool, unconditionally
## (driven by house_id, not a per-unit list).
func _test_vehicle_start_sound_paths_harkonnen() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for config_id in [&"HKAssault", &"HKDevastator", &"HKMCV"]:
		var paths := strategy.death_start_sound_paths(&"Harkonnen", config_id)
		_expect(
			paths == ExplosionTierPools.HARKONNEN_START,
			"%s (Harkonnen) must get the explosion_vehicle_* pool, got %s" % [config_id, paths]
		)


## Every Ordos vehicle gets the explosionordos* pool, unconditionally.
func _test_vehicle_start_sound_paths_ordos() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for config_id in [&"ORKobra", &"ORDustScout", &"ORMCV"]:
		var paths := strategy.death_start_sound_paths(&"Ordos", config_id)
		_expect(
			paths == ExplosionTierPools.ORDOS_START,
			"%s (Ordos) must get the explosionordos* pool, got %s" % [config_id, paths]
		)


## Atreides and every other faction get no extra start-of-animation layer.
func _test_vehicle_start_sound_paths_none() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for faction: StringName in [&"Atreides", &"", &"Imperial", &"Guild", &"Tleilaxu"]:
		var paths := strategy.death_start_sound_paths(faction, &"ATMinotaurus")
		_expect(
			paths.is_empty(),
			"%s must get no extra start-of-animation layer, got %s" % [faction, paths]
		)


func _test_infantry_launch_impulse() -> void:
	var strategy := InfantryDeathStrategyScript.new()
	var blow_up_impulse := strategy.death_launch_impulse(&"Blow_Up")
	_expect(blow_up_impulse.y > 0.0, "Blow_Up must add a positive-Y launch impulse")
	for cause in [&"Shot", &"Burn", &"Gassed", &"Crush", &""]:
		_expect(
			strategy.death_launch_impulse(cause).is_zero_approx(),
			"%s must add no launch impulse; the clip is authored in place" % cause
		)


func _test_vehicle_launch_impulse() -> void:
	var strategy := VehicleDeathStrategyScript.new()
	for cause in [&"", &"Explode", &"Blow_Up"]:
		_expect(
			strategy.death_launch_impulse(cause).is_zero_approx(),
			"vehicle death must never add a launch impulse (%s)" % cause
		)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])
