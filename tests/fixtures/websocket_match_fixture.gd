extends "res://scripts/match/match.gd"

var local_player_id_for_test := 1
var net_room_url_for_test := ""
var transport_override: NetTransport = null
var net_transport: NetTransport = null


func _resolve_local_player_id() -> int:
	return local_player_id_for_test


func _resolve_net_room_url() -> String:
	return net_room_url_for_test


func _create_net_transport() -> NetTransport:
	net_transport = transport_override if transport_override != null else super._create_net_transport()
	return net_transport


func _restore_saved_startup_state() -> void:
	pass
