package main

import "core:fmt"
import rl "vendor:raylib"
import "render"

// Simple keyboard-driven menus. Drawing lives here; navigation state lives on
// the App. All menus share a vertical-list look.

// Draw a titled vertical list, highlighting `selected`. `subtitle` is optional.
draw_menu_list :: proc(title, subtitle: string, items: []string, selected: int, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {20, 22, 48, 255}, {6, 6, 16, 255})

	render.text_center("TETRIS CLASSIC", sw / 2, 70, 56, render.COLOR_HIGHLIGHT)
	render.text_center(title, sw / 2, 150, 30, render.COLOR_TEXT)
	if subtitle != "" {
		render.text_center(subtitle, sw / 2, 190, 20, render.COLOR_TEXT_DIM)
	}

	start_y := i32(260)
	for item, i in items {
		y := start_y + i32(i) * 50
		color := render.COLOR_TEXT_DIM
		prefix := "   "
		if i == selected {
			color = render.COLOR_HIGHLIGHT
			prefix = ">  "
		}
		render.text_center(fmt.tprintf("%s%s", prefix, item), sw / 2, y, 28, color)
	}

	render.text_center("Up/Down select   Enter confirm   Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

// Menu navigation helper: returns the new selection index given key presses.
menu_navigate :: proc(selected, count: int) -> int {
	s := selected
	if rl.IsKeyPressed(.DOWN) do s = (s + 1) % count
	if rl.IsKeyPressed(.UP)   do s = (s - 1 + count) % count
	return s
}
