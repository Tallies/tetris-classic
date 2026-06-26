package main

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"
import "render"

// Simple keyboard-driven menus. Drawing lives here; navigation state lives on
// the App. All menus share a vertical-list look.

MENU_LIST_OFFSET_FROM_Y0 :: i32(260) // first row top
MENU_LIST_DELTA_FROM_Y :: i32(50)  // row spacing

// Draw a titled vertical list, highlighting `selected`. `subtitle` is optional.
draw_menu_list :: proc(title, subtitle: string, items: []string, selected: int, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {20, 22, 48, 255}, {6, 6, 16, 255})

	render.text_center("TETRIS CLASSIC", sw / 2, 70, 56, render.COLOR_HIGHLIGHT)
	render.text_center(title, sw / 2, 150, 30, render.COLOR_TEXT)
	if subtitle != "" {
		render.text_center(subtitle, sw / 2, 190, 20, render.COLOR_TEXT_DIM)
	}

	for item, i in items {
		y := MENU_LIST_OFFSET_FROM_Y0 + i32(i) * MENU_LIST_DELTA_FROM_Y
		color := render.COLOR_TEXT_DIM
		prefix := "   "
		if i == selected {
			color = render.COLOR_HIGHLIGHT
			prefix = ">  "
		}
		render.text_center(fmt.tprintf("%s%s", prefix, item), sw / 2, y, 28, color)
	}

	render.text_center("Up/Down or mouse   Enter/click   Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

// Draw a vertical list of option rows (Setup / Options / Create), highlighting
// `selected`. Rows at y0 + i*dy, font 30, centred.
draw_option_rows :: proc(rows: []string, selected: int, y0, dy, sw: i32) {
	for r, i in rows {
		color := i == selected ? render.COLOR_HIGHLIGHT : render.COLOR_TEXT_DIM
		render.text_center(strings.clone(r, context.temp_allocator), sw / 2, y0 + i32(i) * dy, 30, color)
	}
}

// Keyboard navigation helper: new selection index given Up/Down presses.
menu_navigate :: proc(selected, count: int) -> int {
	s := selected
	if rl.IsKeyPressed(.DOWN) do s = (s + 1) % count
	if rl.IsKeyPressed(.UP)   do s = (s - 1 + count) % count
	return s
}

// True if the mouse is over the vertical band of row `i` (rows at y0 + i*dy).
row_hovered :: proc(i: int, y0, dy: i32) -> bool {
	my := rl.GetMousePosition().y
	top := f32(y0 + i32(i) * dy)
	return my >= top - 10 && my <= top + 38
}

// Mouse hover/click for a `draw_menu_list`. Returns the hovered row (-1 if none)
// and whether it was left-clicked this frame.
mouse_menu_pick :: proc(count: int) -> (hovered: int, clicked: bool) {
	return mouse_rows_pick(count, MENU_LIST_OFFSET_FROM_Y0, MENU_LIST_DELTA_FROM_Y)
}

// Generic hover/click for a vertical list of `count` rows starting at `y0` with
// spacing `dy`. Returns hovered row (-1 if none) and whether left-clicked.
mouse_rows_pick :: proc(count: int, y0, dy: i32) -> (hovered: int, clicked: bool) {
	hovered = -1
	for i in 0 ..< count {
		if row_hovered(i, y0, dy) {
			hovered = i
			break
		}
	}
	clicked = hovered >= 0 && rl.IsMouseButtonPressed(.LEFT)
	return
}
