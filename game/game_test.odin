package game

import "core:testing"

// Fill a board row fully except one column (so a piece can complete it).
@(test)
test_line_clear :: proc(t: ^testing.T) {
	b: Board
	board_init(&b, PIT_WIDTH, PIT_HEIGHT, 12345)
	rows := board_rows(&b)

	// Fill the bottom row completely.
	for x in 0 ..< b.width {
		b.cells[rows - 1][x] = 2
	}
	cleared := clear_lines(&b)
	testing.expect_value(t, cleared, 1)
	// Bottom row should now be empty.
	for x in 0 ..< b.width {
		testing.expect_value(t, b.cells[rows - 1][x], CELL_EMPTY)
	}
}

@(test)
test_tetris_clear :: proc(t: ^testing.T) {
	b: Board
	board_init(&b, PIT_WIDTH, PIT_HEIGHT, 1)
	rows := board_rows(&b)
	for r in 0 ..< 4 {
		for x in 0 ..< b.width {
			b.cells[rows - 1 - r][x] = 5
		}
	}
	cleared := clear_lines(&b)
	testing.expect_value(t, cleared, 4)
}

@(test)
test_movement_and_walls :: proc(t: ^testing.T) {
	b: Board
	p: Player
	board_init(&b, PIT_WIDTH, PIT_HEIGHT, 99)
	player_init(&b, &p, 7, -1)

	// Slam left repeatedly; piece should stop at the wall, never pass it.
	for _ in 0 ..< 20 {
		try_move(&b, &p, -1, 0, nil)
	}
	c := p.current
	min_x := 99
	for off in SHAPES[c.kind][c.rotation] {
		min_x = min(min_x, c.x + off.x)
	}
	testing.expect(t, min_x == 0, "piece should rest against the left wall")
}

@(test)
test_rotation_kicks :: proc(t: ^testing.T) {
	b: Board
	p: Player
	board_init(&b, PIT_WIDTH, PIT_HEIGHT, 3)
	player_init(&b, &p, 11, -1)
	// Rotating in open space should always succeed and keep 4 cells in bounds.
	for _ in 0 ..< 8 {
		try_rotate(&b, &p, true, nil)
		c := p.current
		for off in SHAPES[c.kind][c.rotation] {
			x := c.x + off.x
			testing.expect(t, x >= 0 && x < b.width, "rotated cell stays in bounds")
		}
	}
}

@(test)
test_garbage_insertion :: proc(t: ^testing.T) {
	b: Board
	board_init(&b, PIT_WIDTH, PIT_HEIGHT, 42)
	rows := board_rows(&b)
	insert_garbage(&b, 3)
	// Bottom 3 rows each have exactly one hole.
	for r in 0 ..< 3 {
		holes := 0
		for x in 0 ..< b.width {
			if b.cells[rows - 1 - r][x] == CELL_EMPTY do holes += 1
		}
		testing.expect_value(t, holes, 1)
	}
}

@(test)
test_seven_bag :: proc(t: ^testing.T) {
	p: Player
	p.rng_state = 0xABCDEF
	refill_bag(&p)
	seen: [8]int
	for k in p.bag {
		seen[int(k)] += 1
	}
	// Each of the 7 kinds appears exactly once.
	for kind in 1 ..= 7 {
		testing.expect_value(t, seen[kind], 1)
	}
}

@(test)
test_scoring_levels :: proc(t: ^testing.T) {
	p: Player
	p.level = 1
	award_lines(&p, 4, .Original, false, false) // a Tetris at level 1 = 1200
	testing.expect_value(t, p.score, 1200)
	testing.expect_value(t, p.lines, 4)

	// Clearing 10 total lines advances to level 2.
	award_lines(&p, 4, .Original, false, false)
	award_lines(&p, 2, .Original, false, false)
	testing.expect_value(t, p.level, 2)
}

@(test)
test_scoring_bonuses :: proc(t: ^testing.T) {
	// Base single line at level 1 (Original) = 40.
	base: Player; base.level = 1
	award_lines(&base, 1, .Original, false, false)
	testing.expect_value(t, base.score, 40)

	// Ghost off = +10%.
	g: Player; g.level = 1
	award_lines(&g, 1, .Original, false, true)
	testing.expect_value(t, g.score, 44)

	// Next off = +25%.
	n: Player; n.level = 1
	award_lines(&n, 1, .Original, true, false)
	testing.expect_value(t, n.score, 50)

	// Both off stack additively = +35%.
	b: Player; b.level = 1
	award_lines(&b, 1, .Original, true, true)
	testing.expect_value(t, b.score, 54)
}

@(test)
test_soft_drop_no_dump :: proc(t: ^testing.T) {
	// Regression: pressing soft drop after gravity has accumulated under the
	// slower normal period must NOT teleport the piece to the bottom. It should
	// advance at the soft-drop rate (about one cell for a single frame).
	b: Board
	p: Player
	board_init(&b, PIT_WIDTH, PIT_HEIGHT, 7)
	player_init(&b, &p, 13, -1)

	// Simulate a nearly-full gravity accumulator at level 1 (period 0.80s).
	p.gravity_timer = 0.79
	y_before := p.current.y

	player_update(&b, &p, 0.016, gravity_for_level(1), true, nil)

	moved := p.current.y - y_before
	testing.expect(t, moved <= 2, "soft drop should step, not dump the whole piece")
	testing.expect(t, moved >= 1, "soft drop should advance the piece")
}

@(test)
test_clear_flash_defers_removal :: proc(t: ^testing.T) {
	s: Session
	session_init(&s, .Campaign, .Original, .Unlimited, 123)
	b := &s.boards[0]
	rows := board_rows(b)

	// Fill the bottom row and start a clear, as a lock would.
	for x in 0 ..< b.width {
		b.cells[rows - 1][x] = 2
	}
	testing.expect(t, begin_clear_if_full(b), "full row should start a clear")
	testing.expect(t, b.clearing, "board should be in the clearing state")
	s.clear_owner[0] = 0
	score_before := s.players[0].score

	// Before the flash elapses, the row is still present (flashing, not removed).
	resolve_board_clear(&s, 0, 0.1)
	testing.expect(t, b.clearing, "still flashing before the timer elapses")
	testing.expect(t, b.cells[rows - 1][0] != CELL_EMPTY, "row not removed yet")

	// After the flash elapses, the row is removed and the player is scored.
	resolve_board_clear(&s, 0, CLEAR_FLASH_TIME)
	testing.expect(t, !b.clearing, "clearing finished")
	testing.expect_value(t, b.cells[rows - 1][0], CELL_EMPTY)
	testing.expect(t, s.players[0].score > score_before, "line scored on commit")
}

@(test)
test_shared_pit_respawn_keeps_side :: proc(t: ^testing.T) {
	// Regression: in a shared pit each player must respawn on its own side, not
	// recentre — otherwise both players' pieces collide on respawn and top out.
	b: Board
	p: Player
	board_init(&b, SHARED_WIDTH, PIT_HEIGHT, 5)
	player_init(&b, &p, 9, 11) // right-side spawn column
	testing.expect_value(t, p.spawn_col, 11)

	hard_drop(&b, &p, nil) // lock (no line on an 18-wide row); spawn is deferred
	testing.expect(t, !p.has_piece, "spawn is deferred to the next step")
	try_spawn(&b, &p, nil)
	testing.expect(t, !b.game_over, "single piece should not end the game")
	testing.expect_value(t, p.current.x, 11) // respawned on its side, not centre
}

@(test)
test_shared_spawn_waits_for_partner :: proc(t: ^testing.T) {
	// A spawn blocked only by the other player's falling piece must defer, not
	// top out — this was making coop/competitive end prematurely.
	b: Board
	p0, p1: Player
	board_init(&b, SHARED_WIDTH, PIT_HEIGHT, 1)
	player_init(&b, &p0, 10, 2)  // left
	player_init(&b, &p1, 20, 11) // right

	// p0 has just locked (no piece); put p1's piece over p0's spawn columns.
	p0.has_piece = false
	p0.next = .O
	p1.current = Piece{kind = .O, rotation = .R0, x = 2, y = 0}
	p1.has_piece = true

	others := []^Player{&p1}
	try_spawn(&b, &p0, others)
	testing.expect(t, !b.game_over, "partner overlap must not end the game")
	testing.expect(t, !p0.has_piece, "spawn deferred while partner is overhead")

	// Once the partner's piece is gone, p0 spawns normally.
	p1.has_piece = false
	try_spawn(&b, &p0, others)
	testing.expect(t, p0.has_piece, "spawns once the column is clear")
	testing.expect(t, !b.game_over, "")
}

@(test)
test_session_dualpit_garbage :: proc(t: ^testing.T) {
	s: Session
	session_init(&s, .DualPit, .TetrisClassic, .Unlimited, 555)
	// Simulate player 0 clearing 4 lines -> sends 4 garbage to board 1.
	handle_clear(&s, 0, 4)
	testing.expect_value(t, s.boards[1].pending_garbage, 4)
}
