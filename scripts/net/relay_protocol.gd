class_name RelayProtocol
extends RefCounted

## WebSocket close codes the relay (res://scripts/net/relay/relay_server.gd)
## sends, and their human-readable descriptions -- shared by the relay and by
## any client transport that needs to interpret them
## (res://scripts/net/websocket_transport.gd). Pulled out of relay_server.gd
## so a client never has to preload the *server* script just to learn the
## protocol it speaks; relay_server.gd preloads this file instead of
## declaring these constants itself.
##
## The specific numbers were chosen for one empirically-verified reason, not
## picked by feel: **not every WebSocket close code Godot 4.7's WebSocketPeer
## is asked to send actually arrives.** Verified empirically (a throwaway
## probe tried every code 1000-1015, 2999-4999 through a real
## accept_stream()/close()/poll() round trip and read back what the client
## observed): codes 1000-1003 and 1007-1011 -- the set RFC 6455 originally
## defined -- round-trip exactly as sent, and so does everything in the
## registered 3000-4999 range. Every other code tested, including the
## later-IANA-registered 1012-1015 (one of which, 1013 "Try Again Later", is
## exactly the code the relay used to send for "room full"), arrives at the
## client as 1002 "Protocol error" no matter what reason string went with it
## -- Godot's WSL implementation silently substitutes it, and the caller has
## no way to tell "the server rejected me for reason X" from "something
## violated the WebSocket protocol" if it picks a code from that gap. The
## lesson generalizes: the relay only ever sends 1003 (a real RFC 6455 code,
## "received data of a type it cannot accept" -- exactly true for the
## text-frame case) or a code in the 4000-4999 private-use range, and a
## WebSocket client transport must treat close code as the authoritative way
## to tell these rejection reasons apart, not the close reason string alone
## (the reason string round-trips correctly for every code tested here, but
## nothing upstream of the relay can control what an intermediary between it
## and a browser client might do to it, whereas the close *code* is a fixed
## 2-byte field the WebSocket protocol itself carries).

const CLOSE_NO_ROOM_CODE := 4000
const CLOSE_INVALID_ROOM_CODE := 4001
const CLOSE_ROOM_FULL := 4002
const CLOSE_PROTOCOL_ERROR := 1003

## RFC 6455's own "normal closure" code. Not a rejection -- included here
## only so a client transport can recognize a clean, mutually-agreed close
## without having to hardcode the literal 1000 itself.
const CLOSE_NORMAL := 1000


## Human-readable description for a close code this protocol defines, meant
## for a client transport's last_error(). Falls back to a generic message
## naming the numeric code for anything else, so a caller never gets an empty
## string back for a code it did not expect.
static func describe_close_code(code: int) -> String:
	match code:
		CLOSE_NO_ROOM_CODE:
			return "rejected: no room code in the connection URL"
		CLOSE_INVALID_ROOM_CODE:
			return "rejected: invalid room code"
		CLOSE_ROOM_FULL:
			return "rejected: room is full"
		CLOSE_PROTOCOL_ERROR:
			return "rejected: protocol error (binary frames only)"
		CLOSE_NORMAL:
			return "closed normally"
		_:
			return "connection closed with code %d" % code
