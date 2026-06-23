package render

import rl "vendor:raylib"
import "../game"

// Visual palette evoking the Tetris Classic look: saturated, slightly jewel-
// toned blocks on a deep background. Block faces are drawn with a bevel
// (lighter top-left, darker bottom-right) for the chunky 90s feel. Real
// background artwork is intentionally omitted (trademark); we use gradients.

// Indexed by Cell value (0..8). Index 0 (empty) is unused for fills.
BLOCK_COLORS := [9]rl.Color {
	0 = {0, 0, 0, 0},          // empty
	1 = {0, 196, 222, 255},    // I - cyan
	2 = {240, 208, 64, 255},   // O - yellow
	3 = {176, 80, 200, 255},   // T - purple
	4 = {88, 200, 96, 255},    // S - green
	5 = {224, 72, 72, 255},    // Z - red
	6 = {72, 104, 220, 255},   // J - blue
	7 = {238, 140, 52, 255},   // L - orange
	8 = {130, 130, 140, 255},  // garbage - grey
}

// Per-level background colour (top of the gradient). The same level always maps
// to the same colour. These are placeholders for per-level artwork later; the
// pit is drawn with a dark translucent backdrop on top so the background never
// interferes with reading the playfield. Index 0 unused; levels are 1..10.
LEVEL_BG_COLORS := [game.MAX_LEVEL + 1]rl.Color {
	0  = {20, 20, 30, 255},
	1  = {28, 40, 92, 255},   // deep blue
	2  = {24, 70, 84, 255},   // teal
	3  = {26, 82, 52, 255},   // green
	4  = {78, 84, 28, 255},   // olive
	5  = {110, 74, 26, 255},  // amber
	6  = {120, 50, 30, 255},  // rust
	7  = {110, 32, 56, 255},  // maroon
	8  = {86, 30, 96, 255},   // purple
	9  = {44, 36, 110, 255},  // indigo
	10 = {40, 40, 48, 255},   // slate (max)
}

bg_for_level :: proc(level: int) -> rl.Color {
	l := clamp(level, 1, game.MAX_LEVEL)
	return LEVEL_BG_COLORS[l]
}

// Darker companion colour for the bottom of the background gradient.
bg_bottom :: proc(top: rl.Color) -> rl.Color {
	return {top.r / 3, top.g / 3, top.b / 3, 255}
}

// Invert an RGB colour (used for the line-clear flash).
invert :: proc(c: rl.Color) -> rl.Color {
	return {255 - c.r, 255 - c.g, 255 - c.b, c.a}
}

// Lighten / darken helpers for bevels.
lighten :: proc(c: rl.Color, amt: u8) -> rl.Color {
	return {
		u8(min(255, int(c.r) + int(amt))),
		u8(min(255, int(c.g) + int(amt))),
		u8(min(255, int(c.b) + int(amt))),
		c.a,
	}
}

darken :: proc(c: rl.Color, amt: u8) -> rl.Color {
	return {
		u8(max(0, int(c.r) - int(amt))),
		u8(max(0, int(c.g) - int(amt))),
		u8(max(0, int(c.b) - int(amt))),
		c.a,
	}
}

// Common UI colors.
COLOR_TEXT      :: rl.Color{235, 235, 245, 255}
COLOR_TEXT_DIM  :: rl.Color{150, 150, 165, 255}
COLOR_PANEL     :: rl.Color{0, 0, 0, 140}
COLOR_GRID      :: rl.Color{255, 255, 255, 18}
COLOR_BORDER    :: rl.Color{210, 210, 230, 255}
COLOR_HIGHLIGHT :: rl.Color{250, 220, 120, 255}
