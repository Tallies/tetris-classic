package game

// Core data types for Tetris Classic.
//
// The model is split into two pieces so that every mode is expressible:
//   Board  - the pit/grid of settled cells (shared in coop/competitive modes).
//   Player - one controllable falling piece, its queue, timers, and score.
//
// Single-pit modes (campaign, dual pit, head-to-head) use one Player per Board.
// Shared-pit modes (cooperative, competitive) use two Players on one Board with
// both pieces falling simultaneously.
//
// Nothing here references raylib or networking; rendering (`render`) and
// networking (`net`) import this package and operate on these types, keeping
// the simulation deterministic and portable.

MAX_WIDTH  :: 20
MAX_HEIGHT :: 20

// Standard single-pit dimensions. Shared-pit modes use SHARED_WIDTH.
PIT_WIDTH    :: 10
PIT_HEIGHT   :: 20
SHARED_WIDTH :: 18

// Hidden rows above the visible pit where pieces spawn.
SPAWN_BUFFER :: 2

// Cell holds either empty (0), a piece-color index (1..7), or garbage (8).
Cell :: u8

CELL_EMPTY   :: Cell(0)
CELL_GARBAGE :: Cell(8)

PieceKind :: enum u8 {
	None = 0,
	I, O, T, S, Z, J, L,
}

// Rotation state: 0 = spawn, then clockwise.
Rotation :: enum u8 {
	R0 = 0, R1, R2, R3,
}

// A live, falling piece. (x, y) is the top-left of the piece's 4x4 bounding box
// in board coordinates (x right, y down). y may be negative in the spawn buffer.
Piece :: struct {
	kind:     PieceKind,
	rotation: Rotation,
	x:        int,
	y:        int,
}

// The five Tetris Classic game modes.
GameMode :: enum u8 {
	Campaign,
	Cooperative,
	Competitive,
	DualPit,
	HeadToHead,
}

// Campaign time-limit variants ("ranging from unlimited to 15 minutes").
TimeLimit :: enum u8 {
	Unlimited, Min15, Min10, Min5, Min3,
}

// Player-selectable scoring system.
ScoringSystem :: enum u8 {
	Original,
	TetrisClassic,
}

// The pit grid plus state shared by everyone playing in it.
Board :: struct {
	width:  int,
	height: int,

	// cells[y][x]; rows 0..SPAWN_BUFFER-1 are the hidden spawn area at the top.
	cells: [MAX_HEIGHT + SPAWN_BUFFER][MAX_WIDTH]Cell,

	rng_state:       u64, // garbage-hole randomization
	pending_garbage: int, // rows to insert at the next lock
	game_over:       bool,

	// Line-clear flash: when a lock completes rows they are flagged here and
	// flashed for CLEAR_FLASH_TIME before actually being removed. While
	// `clearing` is true the board is frozen (no player acts on it).
	clearing:    bool,
	clear_timer: f32,
	clear_count: int,
	clear_rows:  [MAX_HEIGHT + SPAWN_BUFFER]bool,
}

// One controllable falling piece with its own queue, timing, and score. A
// Player references the Board it plays on by index in the Session.
Player :: struct {
	active:    bool, // false for unused second player in single-player modes
	current:   Piece,
	next:      PieceKind,
	has_piece: bool,
	spawn_col: int, // left edge of the spawn position (per-player side in shared pits)

	// Seven-bag randomizer (independent per player).
	bag:       [7]PieceKind,
	bag_index: int,
	rng_state: u64,

	// Timing accumulators (seconds).
	gravity_timer: f32,
	lock_timer:    f32,
	locking:       bool,

	// Progress.
	score:     int,
	lines:     int,
	level:     int,
	topped_out: bool, // this player can no longer place pieces

	// How many of each piece kind this player has spawned (for the HUD).
	counts: [PieceKind]int,
}

board_rows :: proc(b: ^Board) -> int {
	return b.height + SPAWN_BUFFER
}
