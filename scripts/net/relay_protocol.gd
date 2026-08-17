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

## The server was already holding max_connections connections (in-handshake,
## room-seated or still-closing -- see RelayServer.connection_count()) when
## this one finished its WebSocket handshake. Distinct from CLOSE_ROOM_FULL:
## this is a whole-server capacity limit, not a per-room one, and a client
## needs to tell them apart to know whether retrying a different room code
## would help (it would not, here).
const CLOSE_SERVER_FULL := 4003
## This connection's room code names a room that does not exist yet, and the
## server was already hosting max_rooms rooms (see RelayServer.room_count()).
## A client joining a room that already exists is never rejected with this
## code, no matter how many rooms exist -- only *creating* a new one beyond
## the cap is.
const CLOSE_TOO_MANY_ROOMS := 4004

## RFC 6455's own "normal closure" code. Not a rejection -- included here
## only so a client transport can recognize a clean, mutually-agreed close
## without having to hardcode the literal 1000 itself.
const CLOSE_NORMAL := 1000

## RFC 6455's own "message too big" close code. Unlike every other close code
## above, this one is never chosen by relay_server.gd's own _reject() -- it is
## sent by the *engine* (WebSocketPeer), on both the relay side and a
## client's own side, the moment a frame larger than MAX_INBOUND_FRAME_BYTES
## is seen. See that constant's doc comment for how this was established
## experimentally. Included here, with its own describe_close_code() case,
## because after WebSocketTransport.send() rejects an oversized payload
## locally (see websocket_transport.gd), the *only* way this code can still
## reach a client is if the two ends disagree about the limit -- a relay
## and a client built against different versions of this protocol -- which is
## exactly the situation a legible description earns its keep for.
const CLOSE_MESSAGE_TOO_BIG := 1009

## Inbound WebSocket frame size limit, in bytes, shared by both ends of this
## protocol: the relay enforces it against the socket it owns
## (RelayServer.MAX_INBOUND_FRAME_BYTES, an alias to this constant --
## WebSocketPeer.set_inbound_buffer_size() in relay_server.gd's
## _accept_new_connections()) and WebSocketTransport.send() enforces it
## against a payload before ever touching its own socket (see that file).
## Living here, not in relay_server.gd, is the point: this is a protocol
## invariant both ends must agree on, not a server implementation detail --
## a client transport that used a different number could either get its
## frames silently dropped locally (if its limit is stricter than the
## relay's) or trip the relay's own CLOSE_MESSAGE_TOO_BIG (if its limit is
## more permissive), and either way LoopbackTransport enforcing a different
## number than this would defeat the interchangeability
## tests/net/transport_conformance.gd exists to guarantee -- see that
## transport's own doc comment.
##
## Command frames in this protocol are tens of bytes (design doc, "Starting
## parameters": a batch of unit orders is "a couple of dozen bytes"
## regardless of how many units are selected) -- 4096 is roughly two orders
## of magnitude more headroom than any legitimate frame needs today, generous
## enough that no plausible future frame (a busier per-turn command bundle
## once the turn-scheduler protocol lands) will brush against it by accident,
## while still bounding worst-case per-connection memory to a few KB instead
## of an unconsidered engine default.
const MAX_INBOUND_FRAME_BYTES := 4096


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
		CLOSE_SERVER_FULL:
			return "rejected: server is at its connection limit"
		CLOSE_TOO_MANY_ROOMS:
			return "rejected: server is at its room limit"
		CLOSE_PROTOCOL_ERROR:
			return "rejected: protocol error (binary frames only)"
		CLOSE_MESSAGE_TOO_BIG:
			return (
				"rejected: frame exceeded the protocol's %d-byte limit -- the relay and this client "
				+ "disagree about MAX_INBOUND_FRAME_BYTES (version skew)"
			) % MAX_INBOUND_FRAME_BYTES
		CLOSE_NORMAL:
			return "closed normally"
		_:
			return "connection closed with code %d" % code
