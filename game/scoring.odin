package game

// Scoring, level progression, and gravity timing. Score/lines/level live on the
// Player; gravity speed is derived from the player's level.

LINES_PER_LEVEL :: 10
MAX_LEVEL       :: 10

// Per-level gravity period (seconds per cell), faster each level. Index 0
// unused; levels are 1..MAX_LEVEL.
GRAVITY_TABLE := [MAX_LEVEL + 1]f32 {
	0  = 0.80,
	1  = 0.80,
	2  = 0.72,
	3  = 0.63,
	4  = 0.55,
	5  = 0.47,
	6  = 0.38,
	7  = 0.30,
	8  = 0.22,
	9  = 0.13,
	10 = 0.08,
}

gravity_for_level :: proc(level: int) -> f32 {
	return GRAVITY_TABLE[clamp(level, 1, MAX_LEVEL)]
}

line_clear_base :: proc(lines: int) -> int {
	switch lines {
	case 1: return 40
	case 2: return 100
	case 3: return 300
	case 4: return 1200
	}
	return 0
}

// Bonus percentages for playing with optional aids disabled (stackable).
NEXT_OFF_BONUS_PCT  :: 25
GHOST_OFF_BONUS_PCT :: 10

// Award points for a line clear and advance the player's line/level counters.
// Returns points added. Disabling the Next preview or the ghost piece grants
// stacking percentage bonuses (a harder game scores more).
award_lines :: proc(p: ^Player, lines: int, system: ScoringSystem, next_disabled, ghost_disabled: bool) -> int {
	if lines <= 0 do return 0

	pts := 0
	switch system {
	case .Original:
		pts = line_clear_base(lines) * p.level
	case .TetrisClassic:
		pts = line_clear_base(lines) * p.level
		if lines >= 2 {
			pts += (lines - 1) * 50 * p.level
		}
	}
	bonus_pct := 0
	if next_disabled  do bonus_pct += NEXT_OFF_BONUS_PCT
	if ghost_disabled do bonus_pct += GHOST_OFF_BONUS_PCT
	pts += pts * bonus_pct / 100

	p.score += pts
	p.lines += lines
	new_level := p.lines / LINES_PER_LEVEL + 1
	if new_level > p.level {
		p.level = min(new_level, MAX_LEVEL)
	}
	return pts
}

award_soft_drop :: proc(p: ^Player, cells: int) {
	p.score += cells
}

award_hard_drop :: proc(p: ^Player, cells: int) {
	p.score += cells * 2
}

// How far the player's current piece would fall (ghost / hard-drop preview)
// without mutating anything.
ghost_drop_y :: proc(b: ^Board, p: ^Player, others: []^Player) -> int {
	if !p.has_piece do return 0
	c := p.current
	y := c.y
	for !piece_collides(b, c.kind, c.rotation, c.x, y + 1, others) {
		y += 1
	}
	return y
}

// Standard formula for how many garbage rows to send when clearing `lines`
// lines at once in dual-pit / head-to-head (send lines-1; a Tetris sends 4).
garbage_to_send :: proc(lines: int) -> int {
	switch lines {
	case 2: return 1
	case 3: return 2
	case 4: return 4
	}
	return 0
}
