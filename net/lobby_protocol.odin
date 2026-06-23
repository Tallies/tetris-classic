package netplay

import "core:mem"

// Control protocol for the matchmaking/relay server (the "lobby phase" of a
// connection). Unlike the gameplay protocol in protocol.odin, control messages
// are length-prefixed so the server can frame variable-content payloads (game
// names, the browse listing) cleanly:
//
//   [u32 length][u8 CtrlType][payload bytes]   (length covers type + payload)
//
// Once two clients are matched the server stops parsing and relays raw bytes,
// at which point the unframed gameplay protocol takes over on the same socket.

// Max length of a game name / password on the wire (fixed-size, NUL-padded).
NAME_LEN :: 24
// Max games returned in a single browse listing.
MAX_LISTING :: 64

CtrlType :: enum u8 {
	// client -> server
	Create = 1,
	Join   = 2,
	List   = 3,
	// server -> client
	Listing      = 10,
	CreateResult = 11,
	JoinResult   = 12,
	Matched      = 13,
}

// Reason codes for CreateResult / JoinResult.
ResultReason :: enum u8 {
	None         = 0,
	NameInUse    = 1,
	NotFound     = 2,
	WrongPassword = 3,
	Full         = 4,
}

CreatePayload :: struct #packed {
	name:     [NAME_LEN]u8,
	password: [NAME_LEN]u8,
	public:   u8,
}

JoinPayload :: struct #packed {
	name:     [NAME_LEN]u8,
	password: [NAME_LEN]u8,
}

ListPayload :: struct #packed {} // empty

GameInfo :: struct #packed {
	name:         [NAME_LEN]u8,
	has_password: u8,
}

ListingPayload :: struct #packed {
	count: u16,
	games: [MAX_LISTING]GameInfo,
}

ResultPayload :: struct #packed {
	ok:     u8,
	reason: u8,
}

MatchedPayload :: struct #packed {
	is_host: u8,
}

// Fixed payload size for a control type (0 for List, which has no body).
ctrl_payload_size :: proc(t: CtrlType) -> int {
	switch t {
	case .Create:       return size_of(CreatePayload)
	case .Join:         return size_of(JoinPayload)
	case .List:         return size_of(ListPayload)
	case .Listing:      return size_of(ListingPayload)
	case .CreateResult: return size_of(ResultPayload)
	case .JoinResult:   return size_of(ResultPayload)
	case .Matched:      return size_of(MatchedPayload)
	}
	return 0
}

// Copy a string into a fixed NAME_LEN buffer (truncating, NUL-padded).
name_to_buf :: proc(s: string) -> [NAME_LEN]u8 {
	buf: [NAME_LEN]u8
	n := min(len(s), NAME_LEN)
	for i in 0 ..< n {
		buf[i] = s[i]
	}
	return buf
}

// Read a NUL-padded fixed buffer back into a string slice (no allocation; the
// returned string borrows from `buf`).
buf_to_name :: proc(buf: []u8) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n += 1
	}
	return string(buf[:n])
}

// Encode one length-prefixed control frame into `buf`, returning the written
// slice. Layout: [u32 length][u8 type][payload]; length covers type + payload.
encode_ctrl :: proc(buf: []u8, t: CtrlType, payload: []u8) -> []u8 {
	body_len := 1 + len(payload)
	l := u32(body_len)
	mem.copy(raw_data(buf), &l, 4)
	buf[4] = u8(t)
	if len(payload) > 0 {
		mem.copy(&buf[5], raw_data(payload), len(payload))
	}
	return buf[:4 + body_len]
}

// Try to read one control frame from the front of `buf`. On success returns the
// type, a slice of its payload body, and the total bytes the frame occupies.
read_ctrl_frame :: proc(buf: []u8) -> (t: CtrlType, body: []u8, total: int, ok: bool) {
	if len(buf) < 4 do return
	l: u32
	mem.copy(&l, raw_data(buf), 4)
	frame_len := int(l)
	if frame_len < 1 do return // malformed (need at least the type byte)
	if len(buf) - 4 < frame_len do return // incomplete; wait for more bytes
	t = CtrlType(buf[4])
	body = buf[5 : 4 + frame_len]
	total = 4 + frame_len
	ok = true
	return
}
