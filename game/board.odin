package game

// Board + Player simulation: spawning, collision, movement, rotation with wall
// kicks, locking, and line clearing. Timing is in seconds and advanced via
// `player_update(dt)`, so the same code runs at any frame rate and can be
// stepped deterministically for networked play.
//
// In shared-pit modes two Players act on one Board simultaneously; each Player's
// movement treats the *other* Player's falling piece as solid. Pass the other
// players via `others` (nil/empty for single-pit modes).

LOCK_DELAY :: f32(0.5)

// Seconds per cell while soft-dropping (the down key in Fast-drop mode).
SOFT_DROP_PERIOD :: f32(0.02)

// How long completed rows flash before being removed (kept under half a second).
CLEAR_FLASH_TIME :: f32(0.28)

board_init :: proc(b: ^Board, width, height: int, seed: u64) {
	b^ = Board{}
	b.width = clamp(width, 1, MAX_WIDTH)
	b.height = clamp(height, 1, MAX_HEIGHT)
	b.rng_state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
}

// Initialize a player and spawn its first piece on the given board. `spawn_col`
// lets shared-pit modes place the two players on opposite sides.
player_init :: proc(b: ^Board, p: ^Player, seed: u64, spawn_col: int) {
	p^ = Player{}
	p.active = true
	p.rng_state = seed == 0 ? 0x123456789ABCDEF : seed
	p.level = 1
	// Remember the spawn column so every respawn keeps this player on its side
	// of a shared pit (otherwise both players would respawn centered and clash).
	p.spawn_col = spawn_col >= 0 ? spawn_col : (b.width - 4) / 2
	refill_bag(p)
	p.next = draw_piece(p)
	try_spawn(b, p, nil)
}

// True if any of the other players' falling pieces occupy (x, y).
occupied_by_other :: proc(others: []^Player, x, y: int) -> bool {
	for o in others {
		if o == nil || !o.has_piece do continue
		c := o.current
		for off in SHAPES[c.kind][c.rotation] {
			if c.x + off.x == x && c.y + off.y == y {
				return true
			}
		}
	}
	return false
}

// True if piece `kind`@`rot` at (px, py) collides with walls, floor, settled
// cells, or another player's falling piece.
piece_collides :: proc(b: ^Board, kind: PieceKind, rot: Rotation, px, py: int, others: []^Player) -> bool {
	rows := board_rows(b)
	for off in SHAPES[kind][rot] {
		x := px + off.x
		y := py + off.y
		if x < 0 || x >= b.width do return true
		if y >= rows do return true
		if y < 0 do continue
		if b.cells[y][x] != CELL_EMPTY do return true
		if occupied_by_other(others, x, y) do return true
	}
	return false
}

// Attempt to spawn the player's queued piece at its stored spawn column.
//   - Blocked by the settled stack / walls -> genuine top-out (game over).
//   - Blocked ONLY by another player's falling piece (shared pit) -> no spawn
//     this frame; the caller retries next frame once that piece has moved on.
//     This keeps coop/competitive from ending just because the partner's piece
//     was passing over your spawn column.
// Returns true once a piece is actually placed.
try_spawn :: proc(b: ^Board, p: ^Player, others: []^Player) -> bool {
	if p.has_piece || p.topped_out || b.game_over do return false

	kind := p.next
	px := p.spawn_col
	py := 0

	// Settled stack / walls at the spawn area => real top-out.
	if piece_collides(b, kind, .R0, px, py, nil) {
		p.topped_out = true
		b.game_over = true
		return false
	}
	// Only the other player's falling piece is in the way => wait a frame.
	for off in SHAPES[kind][Rotation.R0] {
		if occupied_by_other(others, px + off.x, py + off.y) {
			return false
		}
	}

	p.next = draw_piece(p)
	p.counts[kind] += 1
	p.current = Piece{kind = kind, rotation = .R0, x = px, y = py}
	p.has_piece = true
	p.locking = false
	p.lock_timer = 0
	p.gravity_timer = 0
	return true
}

try_move :: proc(b: ^Board, p: ^Player, dx, dy: int, others: []^Player) -> bool {
	if !p.has_piece do return false
	c := p.current
	if piece_collides(b, c.kind, c.rotation, c.x + dx, c.y + dy, others) {
		return false
	}
	p.current.x += dx
	p.current.y += dy
	return true
}

try_rotate :: proc(b: ^Board, p: ^Player, cw: bool, others: []^Player) -> bool {
	if !p.has_piece do return false
	c := p.current
	if c.kind == .O do return true

	to := cw ? rotate_cw(c.rotation) : rotate_ccw(c.rotation)
	trans, ok := kick_transition(c.rotation, to)
	if !ok do return false

	kicks := c.kind == .I ? KICKS_I[trans] : KICKS_JLSTZ[trans]
	for k in kicks {
		// SRS kick y is expressed y-up; board y is down, so negate.
		nx := c.x + k.x
		ny := c.y - k.y
		if !piece_collides(b, c.kind, to, nx, ny, others) {
			p.current.rotation = to
			p.current.x = nx
			p.current.y = ny
			return true
		}
	}
	return false
}

// Hard drop: fall as far as possible, then lock — but only if it came to rest on
// the settled stack/floor. If it merely landed on the other player's falling
// piece it stays unlocked and resumes falling once that piece moves (avoiding a
// floating block).
hard_drop :: proc(b: ^Board, p: ^Player, others: []^Player) -> (dropped: int, cleared: int) {
	if !p.has_piece do return 0, 0
	for try_move(b, p, 0, 1, others) {
		dropped += 1
	}
	if piece_grounded(b, p) {
		cleared = lock_piece(b, p, others)
	}
	return
}

// True only if the piece rests on the settled stack or the floor. It is NOT
// grounded merely by sitting on another player's falling piece — a piece locks
// onto settled cells only, otherwise it would freeze in mid-air (and leave a
// floating block once the supporting piece moves away).
piece_grounded :: proc(b: ^Board, p: ^Player) -> bool {
	c := p.current
	return piece_collides(b, c.kind, c.rotation, c.x, c.y + 1, nil)
}

// Stamp the player's piece into the board. If it completes rows, begin the
// line-clear flash (rows are removed later by commit_clear); otherwise resolve
// pending garbage and spawn the next piece immediately. Returns 0 — completed
// lines are scored when the flash commits, not here.
lock_piece :: proc(b: ^Board, p: ^Player, others: []^Player) -> int {
	if !p.has_piece do return 0
	c := p.current
	color := PIECE_COLOR[c.kind] // locked blocks always use the original colour
	for off in SHAPES[c.kind][c.rotation] {
		x := c.x + off.x
		y := c.y + off.y
		if y < 0 {
			p.topped_out = true
			b.game_over = true
		}
		if y >= 0 && y < board_rows(b) && x >= 0 && x < b.width {
			b.cells[y][x] = color
		}
	}
	p.has_piece = false

	if b.game_over do return 0

	if begin_clear_if_full(b) {
		return 0 // flashing; commit_clear (driven by the session) finishes it
	}

	// No lines completed: resolve garbage. The next piece is spawned by the
	// session on a following frame (via try_spawn), which also lets a shared-pit
	// spawn wait for the partner's piece instead of topping out.
	if b.pending_garbage > 0 {
		insert_garbage(b, b.pending_garbage)
		b.pending_garbage = 0
	}
	return 0
}

// Flag any full rows and start the flash. Returns true if a clear began.
begin_clear_if_full :: proc(b: ^Board) -> bool {
	rows := board_rows(b)
	n := 0
	for y in 0 ..< rows {
		full := true
		for x in 0 ..< b.width {
			if b.cells[y][x] == CELL_EMPTY {
				full = false
				break
			}
		}
		b.clear_rows[y] = full
		if full do n += 1
	}
	if n > 0 {
		b.clearing = true
		b.clear_timer = 0
		b.clear_count = n
		return true
	}
	return false
}

// Remove full rows, shift everything above down, return count cleared.
clear_lines :: proc(b: ^Board) -> int {
	rows := board_rows(b)
	cleared := 0
	y := rows - 1
	for y >= 0 {
		full := true
		for x in 0 ..< b.width {
			if b.cells[y][x] == CELL_EMPTY {
				full = false
				break
			}
		}
		if full {
			for yy := y; yy > 0; yy -= 1 {
				b.cells[yy] = b.cells[yy - 1]
			}
			b.cells[0] = {}
			cleared += 1
			// Re-examine this row index (now holds the row that dropped in).
		} else {
			y -= 1
		}
	}
	return cleared
}

// Insert `n` garbage rows at the bottom, pushing the stack up. Each row is solid
// except for one random hole. Overflow at the top tops the board out.
insert_garbage :: proc(b: ^Board, n: int) {
	rows := board_rows(b)
	for _ in 0 ..< n {
		for x in 0 ..< b.width {
			if b.cells[0][x] != CELL_EMPTY {
				b.game_over = true
			}
		}
		for y in 0 ..< rows - 1 {
			b.cells[y] = b.cells[y + 1]
		}
		hole := rng_range(&b.rng_state, b.width)
		row: [MAX_WIDTH]Cell
		for x in 0 ..< b.width {
			row[x] = x == hole ? CELL_EMPTY : CELL_GARBAGE
		}
		b.cells[rows - 1] = row
	}
}

queue_garbage :: proc(b: ^Board, n: int) {
	b.pending_garbage += n
}

// Advance one player by dt seconds. gravity_period = seconds per cell of fall;
// soft_drop speeds it up. Returns lines cleared from a gravity-driven lock.
player_update :: proc(b: ^Board, p: ^Player, dt: f32, gravity_period: f32, soft_drop: bool, others: []^Player) -> int {
	if b.game_over || p.topped_out || !p.has_piece do return 0

	period := gravity_period
	if soft_drop && period > SOFT_DROP_PERIOD {
		period = SOFT_DROP_PERIOD
		// Clamp any gravity accumulated under the (slower) normal period so that
		// engaging soft drop steps down at the soft rate instead of dumping the
		// whole built-up timer at once (which looked like an instant hard drop).
		if p.gravity_timer > period {
			p.gravity_timer = period
		}
	}

	cleared := 0
	p.gravity_timer += dt

	for period > 0 && p.gravity_timer >= period {
		p.gravity_timer -= period
		if try_move(b, p, 0, 1, others) {
			p.locking = false
			p.lock_timer = 0
		} else {
			break
		}
	}

	if piece_grounded(b, p) {
		p.locking = true
		p.lock_timer += dt
		if p.lock_timer >= LOCK_DELAY {
			cleared += lock_piece(b, p, others)
		}
	} else {
		// Either falling freely or merely resting on the other player's piece;
		// in the latter case gravity resumes once that piece moves on.
		p.locking = false
		p.lock_timer = 0
	}

	return cleared
}
