extends "res://tests/support/suite.gd"

const CombatBulletScript := preload("res://scripts/combat/combat_bullet.gd")

func _initialize() -> void:
	_run_case("null config resolves to no death category", _test_null_config)
	_run_case("no flags set resolves to no death category", _test_no_flags)
	_run_case("gassed flag resolves to Gassed", _test_gassed)
	_run_case("blow_up flag resolves to Blow_Up", _test_blow_up)
	_run_case("burnt flag resolves to Burn", _test_burnt)
	_run_case("ignites flag resolves to Burn", _test_ignites)
	_run_case("shot flag resolves to Shot", _test_shot)
	_run_case("gassed takes precedence over every other flag", _test_gassed_precedence)
	_run_case("blow_up takes precedence over burn and shot", _test_blow_up_precedence)
	_run_case("burn takes precedence over shot", _test_burn_precedence)
	_finish("CombatBullet.death_category tests")


func _make_config(
		gassed := false, blow_up := false, burnt := false, ignites := false, shot := false
	) -> BulletDefinition:
	var config := BulletDefinition.new()
	config.gassed = gassed
	config.blow_up = blow_up
	config.burnt = burnt
	config.ignites = ignites
	config.shot = shot
	return config


func _test_null_config() -> void:
	var bullet := CombatBulletScript.new(null, null)
	_expect(bullet.death_category() == &"", "a bullet with no config must resolve to no death category")


func _test_no_flags() -> void:
	var bullet := CombatBulletScript.new(_make_config(), null)
	_expect(bullet.death_category() == &"", "a bullet with no death flags set must resolve to no death category")


func _test_gassed() -> void:
	var bullet := CombatBulletScript.new(_make_config(true), null)
	_expect(bullet.death_category() == &"Gassed", "the gassed flag must resolve to Gassed")


func _test_blow_up() -> void:
	var bullet := CombatBulletScript.new(_make_config(false, true), null)
	_expect(bullet.death_category() == &"Blow_Up", "the blow_up flag must resolve to Blow_Up")


func _test_burnt() -> void:
	var bullet := CombatBulletScript.new(_make_config(false, false, true), null)
	_expect(bullet.death_category() == &"Burn", "the burnt flag must resolve to Burn")


func _test_ignites() -> void:
	var bullet := CombatBulletScript.new(_make_config(false, false, false, true), null)
	_expect(bullet.death_category() == &"Burn", "the ignites flag must resolve to Burn")


func _test_shot() -> void:
	var bullet := CombatBulletScript.new(_make_config(false, false, false, false, true), null)
	_expect(bullet.death_category() == &"Shot", "the shot flag must resolve to Shot")


func _test_gassed_precedence() -> void:
	var bullet := CombatBulletScript.new(_make_config(true, true, true, true, true), null)
	_expect(bullet.death_category() == &"Gassed", "gassed must take precedence over every other flag")


func _test_blow_up_precedence() -> void:
	var bullet := CombatBulletScript.new(_make_config(false, true, true, true, true), null)
	_expect(bullet.death_category() == &"Blow_Up", "blow_up must take precedence over burn and shot")


func _test_burn_precedence() -> void:
	var bullet := CombatBulletScript.new(_make_config(false, false, true, false, true), null)
	_expect(bullet.death_category() == &"Burn", "burn must take precedence over shot")
