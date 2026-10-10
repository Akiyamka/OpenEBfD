extends "res://tests/support/suite.gd"

const MatchScript := preload("res://scripts/match/match.gd")


func _initialize() -> void:
	_run_case("both network arguments are independently recognized", _test_both_args)
	_run_case("player two is selected without a room", _test_player_two_without_room)
	_run_case("invalid and absent player ids fall back safely", _test_invalid_player_ids)
	_run_case("an empty or absent room means no room", _test_empty_room)
	_run_case("unknown arguments leave recognized values intact", _test_unknown_args)
	_run_case("net player counts validate against the demo roster", _test_net_player_count)
	_run_case("known network arguments are shared by every parser", _test_known_net_arguments)
	_finish("Match network argument tests")


func _test_both_args() -> void:
	var args := PackedStringArray(["--local-player-id=2", "--net-room=ws://host/room"])
	_expect(MatchScript._parse_local_player_id(args) == 2, "the player parser must skip the room argument")
	_expect(
		MatchScript._parse_net_room_url(args) == "ws://host/room",
		"the room parser must skip the player argument"
	)


func _test_player_two_without_room() -> void:
	_expect(
		MatchScript._parse_local_player_id(PackedStringArray(["--local-player-id=2"])) == 2,
		"player two must be valid without a room URL"
	)


func _test_invalid_player_ids() -> void:
	for args in [
		PackedStringArray(["--local-player-id=1oops"]),
		PackedStringArray(["--local-player-id=0"]),
		PackedStringArray(["--local-player-id=3"]),
		PackedStringArray(),
	]:
		_expect(
			MatchScript._parse_local_player_id(args) == MatchScript.LOCAL_PLAYER_ID,
			"invalid or absent player ids must fall back to player one"
		)


func _test_empty_room() -> void:
	_expect(
		MatchScript._parse_net_room_url(PackedStringArray(["--net-room="])) == "",
		"an explicitly empty room must disable networking"
	)
	_expect(MatchScript._parse_net_room_url(PackedStringArray()) == "", "an absent room must disable networking")


func _test_unknown_args() -> void:
	_expect(
		MatchScript._parse_net_room_url(
			PackedStringArray(["--net-room=ws://host/room", "--totally-unknown=x"])
		) == "ws://host/room",
		"an unknown argument must not corrupt a valid room URL"
	)
	_expect(
		MatchScript._parse_local_player_id(
			PackedStringArray(["--local-player-id=2", "--totally-unknown=x"])
		) == 2,
		"an unknown argument must not corrupt a valid player id"
	)


func _test_net_player_count() -> void:
	_expect(MatchScript._parse_net_player_count(PackedStringArray()) == 0, "an absent player count must disable gathering")
	_expect(MatchScript._parse_net_player_count(PackedStringArray(["--net-players=2"])) == 2, "two players must be valid")
	_expect(MatchScript._parse_net_player_count(PackedStringArray(["--net-players=1"])) == 1, "one player must be valid")
	for value in ["0", "3", "2x", "", "-1"]:
		_expect(MatchScript._parse_net_player_count(PackedStringArray(["--net-players=" + value])) == 0, "invalid count %s must disable gathering" % value)


func _test_known_net_arguments() -> void:
	_expect(MatchScript._is_known_net_argument("--net-players=2"), "the count argument must be known")
	_expect(MatchScript._is_known_net_argument("--net-room=ws://h/r"), "the room argument must be known")
	_expect(MatchScript._is_known_net_argument("--local-player-id=2"), "the player argument must be known")
	_expect(not MatchScript._is_known_net_argument("--totally-unknown=x"), "unknown arguments must remain unknown")
	var args := PackedStringArray(["--net-players=2", "--net-room=ws://h/r", "--local-player-id=2"])
	_expect(MatchScript._parse_net_room_url(args) == "ws://h/r", "the room parser must skip a count argument")
	_expect(MatchScript._parse_local_player_id(args) == 2, "the player parser must skip a count argument")
