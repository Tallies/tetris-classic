package render

import "core:fmt"
import rl "vendor:raylib"
import "../game"

// Top-level session rendering: chooses a layout for the mode, draws the pit(s),
// pieces, and HUD panels, plus pause / game-over overlays.

draw_session :: proc(s: ^game.Session, sw, sh: i32, p1_name, p2_name: string, high_score: int, new_high: bool) {
	// Background colour reflects the current level (placeholder for per-level
	// artwork). Same level -> same colour.
	top := bg_for_level(representative_level(s))
	rl.DrawRectangleGradientV(0, 0, sw, sh, top, bg_bottom(top))

	switch s.mode {
	case .Campaign:
		draw_single_layout(s, 0, sw, sh, p1_name, high_score)
	case .Cooperative, .Competitive:
		draw_shared_layout(s, sw, sh, p1_name, p2_name)
	case .DualPit, .HeadToHead:
		draw_dual_layout(s, sw, sh, p1_name, p2_name)
	}

	// The pause menu (drawn by the app over the frozen game) handles the paused
	// state; here we only draw the game-over result.
	if !s.paused && s.state == .GameOver {
		draw_result(s, sw, sh, p1_name, p2_name, high_score, new_high)
	}
}

// Pause overlay menu drawn over the frozen game.
// Y position of pause-menu option `i` (kept in sync with mouse hit-testing).
PAUSE_OPTION_Y0 :: proc(sh: i32) -> i32 { return sh / 2 }
PAUSE_OPTION_DY :: 48

draw_pause_menu :: proc(sw, sh: i32, options: []string, selected: int) {
	rl.DrawRectangleRec({0, 0, f32(sw), f32(sh)}, {0, 0, 0, 175})
	text_center("PAUSED", sw / 2, sh / 2 - 90, 52, COLOR_HIGHLIGHT)

	for opt, i in options {
		y := PAUSE_OPTION_Y0(sh) + i32(i) * PAUSE_OPTION_DY
		color := i == selected ? COLOR_HIGHLIGHT : COLOR_TEXT_DIM
		prefix := i == selected ? "> " : "   "
		text_center(fmt.tprintf("%s%s", prefix, opt), sw / 2, y, 30, color)
	}
	text_center("Up/Down or mouse   Enter/click   Esc continue", sw / 2, sh - 60, 18, COLOR_TEXT_DIM)
}

// The level used to pick the background: the highest level among active players
// so the backdrop advances with the leading player.
representative_level :: proc(s: ^game.Session) -> int {
	lvl := 1
	for i in 0 ..< s.num_players {
		if s.players[i].active {
			lvl = max(lvl, s.players[i].level)
		}
	}
	return lvl
}

// Geometry of player 0's pit from the last draw, so the app can map the mouse
// position to a board column for mouse gameplay.
PitView :: struct {
	ox, oy, cell: f32,
	cols, rows:   int,
	valid:        bool,
}
player0_pit: PitView

// Compute a cell size so a pit of `cols` x `rows` plus margins fits in the area.
fit_cell :: proc(area_w, area_h: f32, cols, rows: int) -> f32 {
	by_w := area_w / f32(cols)
	by_h := area_h / f32(rows)
	return min(by_w, by_h)
}

// --- Single pit (campaign): pit on the left, HUD panel on the right. ---
draw_single_layout :: proc(s: ^game.Session, idx: int, sw, sh: i32, name: string, high_score: int) {
	margin := f32(40)
	hud_w := f32(260)
	avail_w := f32(sw) - hud_w - margin * 3
	avail_h := f32(sh) - margin * 2

	b := game.player_board(s, idx)
	cell := fit_cell(avail_w, avail_h, b.width, b.height)

	pit_w := f32(b.width) * cell
	pit_h := f32(b.height) * cell
	ox := margin + (avail_w - pit_w) / 2
	oy := (f32(sh) - pit_h) / 2

	draw_board(b, ox, oy, cell)
	draw_player_piece(s, idx, ox, oy, cell)
	player0_pit = {ox, oy, cell, b.width, b.height, true}

	hud_x := ox + pit_w + margin
	panel_h := draw_hud_panel(s, idx, i32(hud_x), i32(oy), i32(hud_w), name, true, high_score)
	draw_piece_counts(s, idx, i32(hud_x), i32(oy) + panel_h + 16, i32(hud_w))
}

// --- Shared wide pit (coop / competitive). ---
draw_shared_layout :: proc(s: ^game.Session, sw, sh: i32, n1, n2: string) {
	margin := f32(40)
	hud_w := f32(220)
	avail_w := f32(sw) - hud_w * 2 - margin * 3
	avail_h := f32(sh) - margin * 2

	b := &s.boards[0]
	cell := fit_cell(avail_w, avail_h, b.width, b.height)

	pit_w := f32(b.width) * cell
	pit_h := f32(b.height) * cell
	ox := (f32(sw) - pit_w) / 2
	oy := (f32(sh) - pit_h) / 2

	draw_board(b, ox, oy, cell)
	player0_pit = {ox, oy, cell, b.width, b.height, true}
	// Player 0 first so player 1 (right) ghost layers cleanly.
	draw_player_piece(s, 0, ox, oy, cell)
	draw_player_piece(s, 1, ox, oy, cell)

	// HUD panels left and right.
	draw_hud_panel(s, 0, i32(margin), i32(oy), i32(hud_w), n1, true)
	draw_hud_panel(s, 1, i32(f32(sw) - margin - hud_w), i32(oy), i32(hud_w), n2, true)

	if s.mode == .Cooperative {
		txt := fmt.ctprintf("TEAM SCORE  %d", game.team_score(s))
		w := rl.MeasureText(txt, 28)
		rl.DrawText(txt, sw / 2 - w / 2, i32(oy) - 40, 28, COLOR_HIGHLIGHT)
	}
}

// --- Two separate pits side by side (dual pit / head-to-head). ---
draw_dual_layout :: proc(s: ^game.Session, sw, sh: i32, n1, n2: string) {
	margin := f32(30)
	// Wide enough for the side-by-side Current/Next boxes; the pits are usually
	// height-limited so this doesn't shrink them.
	hud_w := f32(240)
	// Each half holds a pit + a HUD column.
	half_w := (f32(sw) - margin * 3) / 2
	avail_h := f32(sh) - margin * 2

	draw_one_pit_with_hud :: proc(s: ^game.Session, idx: int, half_x, half_w, avail_h, sh, hud_w: f32, name: string) {
		b := game.player_board(s, idx)
		pit_area_w := half_w - hud_w - 20
		cell := fit_cell(pit_area_w, avail_h, b.width, b.height)
		pit_w := f32(b.width) * cell
		pit_h := f32(b.height) * cell
		ox := half_x
		oy := (sh - pit_h) / 2
		draw_board(b, ox, oy, cell)
		draw_player_piece(s, idx, ox, oy, cell)
		if idx == 0 do player0_pit = {ox, oy, cell, b.width, b.height, true}
		draw_hud_panel(s, idx, i32(ox + pit_w + 16), i32(oy), i32(hud_w), name, true)
	}

	draw_one_pit_with_hud(s, 0, margin, half_w, avail_h, f32(sh), hud_w, n1)
	draw_one_pit_with_hud(s, 1, margin * 2 + half_w, half_w, avail_h, f32(sh), hud_w, n2)
}

// A HUD panel for one player: name, score, [high score], lines, level, next,
// timer. Returns the panel height. `high_score < 0` hides the high-score row.
draw_hud_panel :: proc(s: ^game.Session, idx: int, x, y, w: i32, name: string, show_next: bool, high_score := -1) -> i32 {
	p := &s.players[idx]
	pad := i32(14)
	line_h := i32(30)
	cy := y + pad

	// Panel background.
	panel_h := high_score >= 0 ? i32(384) : i32(330)
	rl.DrawRectangleRec({f32(x), f32(y), f32(w), f32(panel_h)}, COLOR_PANEL)
	rl.DrawRectangleLinesEx({f32(x), f32(y), f32(w), f32(panel_h)}, 2, {255, 255, 255, 40})

	rl.DrawText(fmt.ctprintf("%s", name), x + pad, cy, 24, COLOR_HIGHLIGHT)
	cy += line_h + 6

	rl.DrawText(fmt.ctprintf("SCORE"), x + pad, cy, 18, COLOR_TEXT_DIM); cy += 22
	rl.DrawText(fmt.ctprintf("%d", p.score), x + pad, cy, 26, COLOR_TEXT); cy += line_h + 6

	if high_score >= 0 {
		// Once the current score reaches the stored best, the high score tracks
		// upward with it.
		shown_high := max(high_score, p.score)
		rl.DrawText(fmt.ctprintf("HIGH SCORE"), x + pad, cy, 18, COLOR_TEXT_DIM); cy += 22
		rl.DrawText(fmt.ctprintf("%d", shown_high), x + pad, cy, 24, COLOR_HIGHLIGHT); cy += line_h + 6
	}

	rl.DrawText(fmt.ctprintf("LEVEL"), x + pad, cy, 18, COLOR_TEXT_DIM)
	rl.DrawText(fmt.ctprintf("LINES"), x + w/2, cy, 18, COLOR_TEXT_DIM); cy += 22
	rl.DrawText(fmt.ctprintf("%d", p.level), x + pad, cy, 26, COLOR_TEXT)
	rl.DrawText(fmt.ctprintf("%d", p.lines), x + w/2, cy, 26, COLOR_TEXT); cy += line_h + 10

	// Current + Next previews, side by side. Current is always shown (the piece
	// is already on the board, so it gives nothing away); Next is hidden when the
	// Next-off scoring option is on.
	if show_next {
		show_next_box := !s.next_disabled
		half := (f32(w) - f32(pad) * 3) / 2
		box_h := f32(90)
		left := f32(x + pad)
		right := left + half + f32(pad)

		rl.DrawText(fmt.ctprintf("CURRENT"), i32(left), cy, 18, COLOR_TEXT_DIM)
		if show_next_box do rl.DrawText(fmt.ctprintf("NEXT"), i32(right), cy, 18, COLOR_TEXT_DIM)
		cy += 24
		box_y := f32(cy)

		cur := p.has_piece ? p.current.kind : game.PieceKind.None
		rl.DrawRectangleRec({left, box_y, half, box_h}, {0, 0, 0, 120})
		draw_next_preview(cur, left, box_y, half, box_h)

		if show_next_box {
			rl.DrawRectangleRec({right, box_y, half, box_h}, {0, 0, 0, 120})
			draw_next_preview(p.next, right, box_y, half, box_h)
		}
	}

	// Timer (campaign only, shown under player 0).
	if s.time_limit != .Unlimited && idx == 0 {
		mins := int(s.time_remaining) / 60
		secs := int(s.time_remaining) % 60
		rl.DrawText(fmt.ctprintf("TIME %02d:%02d", mins, secs), x + pad, y + panel_h - 30, 22, COLOR_TEXT)
	}
	return panel_h
}

// A panel listing how many of each piece kind the player has spawned, each row
// showing the actual tetromino shape and its count.
draw_piece_counts :: proc(s: ^game.Session, idx: int, x, y, w: i32) {
	p := &s.players[idx]
	pad := i32(14)
	row_h := i32(34)
	order := [7]game.PieceKind{.I, .O, .T, .S, .Z, .J, .L}
	h := pad * 2 + 28 + i32(len(order)) * row_h

	rl.DrawRectangleRec({f32(x), f32(y), f32(w), f32(h)}, COLOR_PANEL)
	rl.DrawRectangleLinesEx({f32(x), f32(y), f32(w), f32(h)}, 2, {255, 255, 255, 40})
	rl.DrawText(fmt.ctprintf("PIECES USED"), x + pad, y + pad, 18, COLOR_TEXT_DIM)

	cell := f32(11)
	cy := y + pad + 28
	for k in order {
		// Vertically centre the shape in the row.
		miny, maxy := 99, -1
		for off in game.SHAPES[k][game.Rotation.R0] {
			miny = min(miny, off.y); maxy = max(maxy, off.y)
		}
		icon_h := f32(maxy - miny + 1) * cell
		iy := f32(cy) + (f32(row_h) - icon_h) / 2
		draw_piece_icon(k, f32(x + pad), iy, cell)

		ct := fmt.ctprintf("%d", p.counts[k])
		rl.DrawText(ct, x + w - pad - rl.MeasureText(ct, 22), cy + (row_h - 22) / 2, 22, COLOR_TEXT)
		cy += row_h
	}
}

// Draw a tetromino's spawn (R0) shape with its bounding box top-left at (ox,oy).
draw_piece_icon :: proc(kind: game.PieceKind, ox, oy, cell: f32) {
	minx, miny := 99, 99
	for off in game.SHAPES[kind][game.Rotation.R0] {
		minx = min(minx, off.x); miny = min(miny, off.y)
	}
	ci := game.PIECE_COLOR[kind]
	for off in game.SHAPES[kind][game.Rotation.R0] {
		draw_block(ox + f32(off.x - minx) * cell, oy + f32(off.y - miny) * cell, cell, ci)
	}
}

draw_overlay :: proc(sw, sh: i32, title, subtitle: string) {
	rl.DrawRectangleRec({0, 0, f32(sw), f32(sh)}, {0, 0, 0, 150})
	text_center(title, sw / 2, sh / 2 - 40, 56, COLOR_HIGHLIGHT)
	text_center(subtitle, sw / 2, sh / 2 + 30, 24, COLOR_TEXT)
}

draw_result :: proc(s: ^game.Session, sw, sh: i32, n1, n2: string, high_score: int, new_high: bool) {
	rl.DrawRectangleRec({0, 0, f32(sw), f32(sh)}, {0, 0, 0, 160})

	// Campaign: show the (possibly new) high score under the result.
	if s.mode == .Campaign {
		if new_high {
			text_center("NEW HIGH SCORE!", sw / 2, sh / 2 + 110, 28, COLOR_HIGHLIGHT)
		} else {
			text_center(fmt.tprintf("High Score  %d", high_score), sw / 2, sh / 2 + 110, 24, COLOR_TEXT_DIM)
		}
	}

	title := "GAME OVER"
	sub := ""
	switch s.mode {
	case .Campaign:
		title = s.winner == 0 ? "CAMPAIGN CLEARED!" : "GAME OVER"
		sub = fmt.tprintf("Score %d   Lines %d   Level %d", s.players[0].score, s.players[0].lines, s.players[0].level)
	case .Cooperative:
		title = "GAME OVER"
		sub = fmt.tprintf("Team Score %d", game.team_score(s))
	case .Competitive, .DualPit, .HeadToHead:
		if s.winner < 0 {
			title = "DRAW"
		} else {
			winner_name := s.winner == 0 ? n1 : n2
			title = fmt.tprintf("%s WINS!", winner_name)
		}
		sub = fmt.tprintf("%s %d    %s %d", n1, s.players[0].score, n2, s.players[1].score)
	}

	text_center(title, sw / 2, sh / 2 - 50, 56, COLOR_HIGHLIGHT)
	text_center(sub, sw / 2, sh / 2 + 20, 26, COLOR_TEXT)
	text_center("Press ENTER for menu", sw / 2, sh / 2 + 70, 22, COLOR_TEXT_DIM)
}
