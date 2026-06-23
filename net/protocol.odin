package netplay

import "../game"

// Wire protocol for head-to-head play over TCP.
//
// Design: each peer authoritatively simulates ONLY its own pit and streams a
// snapshot of it to the other peer, which displays it as a read-only mirror.
// Line clears produce garbage that is *sent* to the opponent, who applies it to
// their own (locally simulated) pit. This is latency-tolerant: a late snapshot
// only makes the opponent's mirror briefly stale, never desyncs the simulation.
//
// Framing: each message is a single type byte followed by a fixed-size payload
// whose size is determined by the type. Both peers run the same build on the
// same architecture, so payloads are sent as raw little-endian structs. (If
// cross-architecture play is ever needed, swap these for explicit encoders.)

MsgType :: enum u8 {
	Start    = 1, // host -> client: game parameters
	Snapshot = 2, // either -> either: opponent pit mirror
	Garbage  = 3, // either -> either: send N garbage rows to opponent
	GameOver = 4, // sender topped out; receiver wins
}

// Host announces the agreed game parameters and shared seed.
StartPayload :: struct #packed {
	seed:       u64,
	scoring:    u8, // game.ScoringSystem
	time_limit: u8, // game.TimeLimit
}

// Full pit mirror for display on the opponent's screen.
SnapshotPayload :: struct #packed {
	cells:      [game.MAX_HEIGHT + game.SPAWN_BUFFER][game.MAX_WIDTH]game.Cell,
	score:      i32,
	lines:      i32,
	level:      i32,
	piece_kind: u8,
	piece_rot:  u8,
	piece_x:    i32,
	piece_y:    i32,
	next_kind:  u8,
	has_piece:  u8,
	topped_out: u8,
}

GarbagePayload :: struct #packed {
	count: i32,
}

// Payload size in bytes for a given message type (0 for GameOver).
payload_size :: proc(t: MsgType) -> int {
	switch t {
	case .Start:    return size_of(StartPayload)
	case .Snapshot: return size_of(SnapshotPayload)
	case .Garbage:  return size_of(GarbagePayload)
	case .GameOver: return 0
	}
	return 0
}
