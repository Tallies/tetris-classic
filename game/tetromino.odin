package game

// Tetromino shape and rotation data following the Super Rotation System (SRS).
//
// Each piece is described as four occupied cells per rotation state, expressed
// as (x, y) offsets from the piece's bounding-box origin. SRS bounding boxes:
// I uses 4x4, O uses 2x2 (but we keep it in a 4x4 frame so all pieces share
// one origin convention), others use 3x3.

CellOffset :: [2]int // {x, y}

// Shapes[kind][rotation] -> 4 occupied offsets.
// Coordinates use x right, y down, matching board space.
SHAPES := [PieceKind][4][4]CellOffset {
	.None = {},

	// I piece (horizontal at spawn).
	.I = {
		{{0, 1}, {1, 1}, {2, 1}, {3, 1}}, // R0
		{{2, 0}, {2, 1}, {2, 2}, {2, 3}}, // R1
		{{0, 2}, {1, 2}, {2, 2}, {3, 2}}, // R2
		{{1, 0}, {1, 1}, {1, 2}, {1, 3}}, // R3
	},

	// O piece (does not change under rotation).
	.O = {
		{{1, 0}, {2, 0}, {1, 1}, {2, 1}},
		{{1, 0}, {2, 0}, {1, 1}, {2, 1}},
		{{1, 0}, {2, 0}, {1, 1}, {2, 1}},
		{{1, 0}, {2, 0}, {1, 1}, {2, 1}},
	},

	// T piece.
	.T = {
		{{1, 0}, {0, 1}, {1, 1}, {2, 1}},
		{{1, 0}, {1, 1}, {2, 1}, {1, 2}},
		{{0, 1}, {1, 1}, {2, 1}, {1, 2}},
		{{1, 0}, {0, 1}, {1, 1}, {1, 2}},
	},

	// S piece.
	.S = {
		{{1, 0}, {2, 0}, {0, 1}, {1, 1}},
		{{1, 0}, {1, 1}, {2, 1}, {2, 2}},
		{{1, 1}, {2, 1}, {0, 2}, {1, 2}},
		{{0, 0}, {0, 1}, {1, 1}, {1, 2}},
	},

	// Z piece.
	.Z = {
		{{0, 0}, {1, 0}, {1, 1}, {2, 1}},
		{{2, 0}, {1, 1}, {2, 1}, {1, 2}},
		{{0, 1}, {1, 1}, {1, 2}, {2, 2}},
		{{1, 0}, {0, 1}, {1, 1}, {0, 2}},
	},

	// J piece.
	.J = {
		{{0, 0}, {0, 1}, {1, 1}, {2, 1}},
		{{1, 0}, {2, 0}, {1, 1}, {1, 2}},
		{{0, 1}, {1, 1}, {2, 1}, {2, 2}},
		{{1, 0}, {1, 1}, {0, 2}, {1, 2}},
	},

	// L piece.
	.L = {
		{{2, 0}, {0, 1}, {1, 1}, {2, 1}},
		{{1, 0}, {1, 1}, {1, 2}, {2, 2}},
		{{0, 1}, {1, 1}, {2, 1}, {0, 2}},
		{{0, 0}, {1, 0}, {1, 1}, {1, 2}},
	},
}

// Color index per piece (1..7), used by the renderer to map to a palette.
PIECE_COLOR := [PieceKind]Cell {
	.None = CELL_EMPTY,
	.I    = 1,
	.O    = 2,
	.T    = 3,
	.S    = 4,
	.Z    = 5,
	.J    = 6,
	.L    = 7,
}

// SRS wall-kick offsets. When a rotation collides, these candidate (x, y)
// shifts are tried in order. Indexed by [from_rotation][to_rotation-as-pair].
// SRS defines two tables: one for J,L,S,T,Z and one for I.

// Kick test pairs are keyed by transition. We encode transitions as an index:
// 0: 0->R, 1: R->0, 2: R->2, 3: 2->R, 4: 2->L, 5: L->2, 6: L->0, 7: 0->L
KickTransition :: enum {
	R0_R1, R1_R0, R1_R2, R2_R1, R2_R3, R3_R2, R3_R0, R0_R3,
}

// Standard kicks for J, L, S, T, Z. Five tests each (SRS includes the no-op
// {0,0} first).
KICKS_JLSTZ := [KickTransition][5]CellOffset {
	.R0_R1 = {{0, 0}, {-1, 0}, {-1, -1}, {0, 2}, {-1, 2}},
	.R1_R0 = {{0, 0}, {1, 0}, {1, 1}, {0, -2}, {1, -2}},
	.R1_R2 = {{0, 0}, {1, 0}, {1, 1}, {0, -2}, {1, -2}},
	.R2_R1 = {{0, 0}, {-1, 0}, {-1, -1}, {0, 2}, {-1, 2}},
	.R2_R3 = {{0, 0}, {1, 0}, {1, -1}, {0, 2}, {1, 2}},
	.R3_R2 = {{0, 0}, {-1, 0}, {-1, 1}, {0, -2}, {-1, -2}},
	.R3_R0 = {{0, 0}, {-1, 0}, {-1, 1}, {0, -2}, {-1, -2}},
	.R0_R3 = {{0, 0}, {1, 0}, {1, -1}, {0, 2}, {1, 2}},
}

// Kicks for the I piece.
KICKS_I := [KickTransition][5]CellOffset {
	.R0_R1 = {{0, 0}, {-2, 0}, {1, 0}, {-2, 1}, {1, -2}},
	.R1_R0 = {{0, 0}, {2, 0}, {-1, 0}, {2, -1}, {-1, 2}},
	.R1_R2 = {{0, 0}, {-1, 0}, {2, 0}, {-1, -2}, {2, 1}},
	.R2_R1 = {{0, 0}, {1, 0}, {-2, 0}, {1, 2}, {-2, -1}},
	.R2_R3 = {{0, 0}, {2, 0}, {-1, 0}, {2, -1}, {-1, 2}},
	.R3_R2 = {{0, 0}, {-2, 0}, {1, 0}, {-2, 1}, {1, -2}},
	.R3_R0 = {{0, 0}, {1, 0}, {-2, 0}, {1, 2}, {-2, -1}},
	.R0_R3 = {{0, 0}, {-1, 0}, {2, 0}, {-1, -2}, {2, 1}},
}

// Map a (from, to) rotation pair to its transition key. Returns ok=false for
// non-adjacent transitions (we only ever rotate by one step).
kick_transition :: proc(from, to: Rotation) -> (KickTransition, bool) {
	switch from {
	case .R0: if to == .R1 do return .R0_R1, true; if to == .R3 do return .R0_R3, true
	case .R1: if to == .R2 do return .R1_R2, true; if to == .R0 do return .R1_R0, true
	case .R2: if to == .R3 do return .R2_R3, true; if to == .R1 do return .R2_R1, true
	case .R3: if to == .R0 do return .R3_R0, true; if to == .R2 do return .R3_R2, true
	}
	return .R0_R1, false
}

// Rotate a rotation state clockwise or counter-clockwise.
rotate_cw :: proc(r: Rotation) -> Rotation {
	return Rotation((u8(r) + 1) % 4)
}

rotate_ccw :: proc(r: Rotation) -> Rotation {
	return Rotation((u8(r) + 3) % 4)
}
