extends "res://scripts/match/match.gd"

const RecordingTransportScript := preload("res://tests/net/support/recording_transport.gd")

var recording_transport := RecordingTransportScript.new()


func _create_net_transport() -> NetTransport:
	return recording_transport


func _restore_saved_startup_state() -> void:
	pass
