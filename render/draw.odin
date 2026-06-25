package render

import "core:fmt"
import rl "vendor:raylib"
import "../game"

// Rendering of the live session: pits, pieces, ghosts, and HUD panels. Layout
// adapts to the mode (one pit, one wide pit, or two pits side by side).

// Flash blink period for clearing rows (seconds per on/off half-cycle).
FLASH_BLINK :: f32(0.06)

// A beveled block face at pixel (px, py) of given size for a Cell color index.
draw_block :: proc(px, py, size: f32, ci: game.Cell, alpha: f32 = 1.0) {
	if ci == game.CELL_EMPTY do return
	base := BLOCK_COLORS[ci]
	if alpha < 1.0 {
		base.a = u8(f32(base.a) * alpha)
	}
	draw_block_rgb(px, py, size, base)
}

// A beveled block face from an explicit colour (used for the inverse flash).
draw_block_rgb :: proc(px, py, size: f32, base: rl.Color) {
	bevel := max(2, size / 8)
	rl.DrawRectangleRec({px, py, size, size}, darken(base, 50))
	rl.DrawRectangleRec({px + bevel, py + bevel, size - 2 * bevel, size - 2 * bevel}, base)
	// Top-left highlight, bottom-right shadow.
	rl.DrawRectangleRec({px, py, size, bevel}, lighten(base, 60))
	rl.DrawRectangleRec({px, py, bevel, size}, lighten(base, 40))
	rl.DrawRectangleRec({px, py + size - bevel, size, bevel}, darken(base, 70))
	rl.DrawRectangleRec({px + size - bevel, py, bevel, size}, darken(base, 50))
}

// Ghost outline at a cell.
draw_ghost_cell :: proc(px, py, size: f32, ci: game.Cell) {
	base := BLOCK_COLORS[ci]
	base.a = 28 // faint fill so it's a hint, not a distraction
	rl.DrawRectangleRec({px, py, size, size}, base)
	rl.DrawRectangleLinesEx({px, py, size, size}, 1, {base.r, base.g, base.b, 70})
}

// Draw a board's pit (background, grid, settled cells, frame) with the visible
// region origin at (ox, oy) and the given cell size.
draw_board :: proc(b: ^game.Board, ox, oy, cell: f32) {
	w := f32(b.width) * cell
	h := f32(b.height) * cell

	// Pit backdrop: a dark translucent overlay so the level background shows
	// through faintly but never interferes with reading the playfield.
	rl.DrawRectangleRec({ox, oy, w, h}, {0, 0, 0, 200})
	for x in 0 ..= b.width {
		fx := ox + f32(x) * cell
		rl.DrawLineV({fx, oy}, {fx, oy + h}, COLOR_GRID)
	}
	for y in 0 ..= b.height {
		fy := oy + f32(y) * cell
		rl.DrawLineV({ox, fy}, {ox + w, fy}, COLOR_GRID)
	}

	// While a clear is flashing, blink the completed rows between inverse and
	// normal colours so they read as "about to disappear".
	flash_inverse := b.clearing && (int(b.clear_timer / FLASH_BLINK) % 2 == 0)

	// Settled cells (skip the hidden spawn buffer rows).
	for vy in 0 ..< b.height {
		sy := vy + game.SPAWN_BUFFER
		row_flashing := b.clearing && b.clear_rows[sy]
		for x in 0 ..< b.width {
			ci := b.cells[sy][x]
			if ci == game.CELL_EMPTY do continue
			px := ox + f32(x) * cell
			py := oy + f32(vy) * cell
			if row_flashing && flash_inverse {
				draw_block_rgb(px, py, cell, invert(BLOCK_COLORS[ci]))
			} else {
				draw_block(px, py, cell, ci)
			}
		}
	}

	// Frame.
	rl.DrawRectangleLinesEx({ox - 3, oy - 3, w + 6, h + 6}, 3, COLOR_BORDER)
}

// Draw a player's ghost then active piece on their board.
draw_player_piece :: proc(s: ^game.Session, idx: int, ox, oy, cell: f32) {
	p := &s.players[idx]
	if !p.active || !p.has_piece do return
	b := game.player_board(s, idx)

	backing: [1]^game.Player
	others := game.others_of(s, idx, &backing)

	c := p.current
	ci := game.PIECE_COLOR[c.kind]

	// Ghost (landing predictor) — hidden when disabled for a scoring bonus.
	if !s.ghost_disabled {
		gy := game.ghost_drop_y(b, p, others)
		for off in game.SHAPES[c.kind][c.rotation] {
			vx := c.x + off.x
			vy := gy + off.y - game.SPAWN_BUFFER
			if vy < 0 do continue
			draw_ghost_cell(ox + f32(vx) * cell, oy + f32(vy) * cell, cell, ci)
		}
	}

	// Active piece.
	for off in game.SHAPES[c.kind][c.rotation] {
		vx := c.x + off.x
		vy := c.y + off.y - game.SPAWN_BUFFER
		if vy < 0 do continue
		draw_block(ox + f32(vx) * cell, oy + f32(vy) * cell, cell, ci)
	}
}

// Draw a small preview of a piece kind inside a box at (bx, by, bw, bh).
draw_next_preview :: proc(kind: game.PieceKind, bx, by, bw, bh: f32) {
	if kind == .None do return
	cell := min(bw, bh) / 5
	ci := game.PIECE_COLOR[kind]
	// Compute the piece's bounding box to center it.
	minx, miny, maxx, maxy := 99, 99, -1, -1
	for off in game.SHAPES[kind][game.Rotation.R0] {
		minx = min(minx, off.x); maxx = max(maxx, off.x)
		miny = min(miny, off.y); maxy = max(maxy, off.y)
	}
	pw := f32(maxx - minx + 1) * cell
	ph := f32(maxy - miny + 1) * cell
	ox := bx + (bw - pw) / 2
	oy := by + (bh - ph) / 2
	for off in game.SHAPES[kind][game.Rotation.R0] {
		draw_block(ox + f32(off.x - minx) * cell, oy + f32(off.y - miny) * cell, cell, ci)
	}
}

// Text helpers.
text :: proc(str: string, x, y: i32, size: i32, color: rl.Color) {
	c := fmt.ctprintf("%s", str)
	rl.DrawText(c, x, y, size, color)
}

text_center :: proc(str: string, cx, y: i32, size: i32, color: rl.Color) {
	c := fmt.ctprintf("%s", str)
	w := rl.MeasureText(c, size)
	rl.DrawText(c, cx - w / 2, y, size, color)
}

// Draw one line of text confined to `max_w` pixels starting at (x, y). If the
// text is wider, it scrolls left so the end stays visible, and the overflow is
// clipped — single-line text-field behavior for entry boxes.
text_field :: proc(str: string, x, y, max_w, size: i32, color: rl.Color) {
	c := fmt.ctprintf("%s", str)
	tw := rl.MeasureText(c, size)
	rl.BeginScissorMode(x, y - 4, max_w, size + 8)
	dx := x
	if tw > max_w {
		dx = x - (tw - max_w)
	}
	rl.DrawText(c, dx, y, size, color)
	rl.EndScissorMode()
}
