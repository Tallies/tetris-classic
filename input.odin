package main

import rl "vendor:raylib"
import "game"

// How the down key behaves (a local control preference, applies in all modes).
DownMode :: enum {
	FastDrop,  // hold to fall faster, stops when released (soft drop)
	Immediate, // a press drops and locks the piece instantly (hard drop)
}

// Keyboard mapping to per-player intents. The down key is the sole drop control;
// its effect depends on `down_mode`.
//
// Player 1: Arrows move, Down drop, Up rotate CW, Z rotate CCW.
// Player 2 (local): A/D move, S drop, W rotate CW, Left Shift rotate CCW.

gather_intent_p1 :: proc(down_mode: DownMode) -> game.PlayerIntent {
	intent := game.PlayerIntent {
		move_left  = rl.IsKeyDown(.LEFT),
		move_right = rl.IsKeyDown(.RIGHT),
		rotate_cw  = rl.IsKeyPressed(.UP),
		rotate_ccw = rl.IsKeyPressed(.Z),
	}
	apply_down(&intent, down_mode, rl.IsKeyDown(.DOWN), rl.IsKeyPressed(.DOWN))
	return intent
}

gather_intent_p2 :: proc(down_mode: DownMode) -> game.PlayerIntent {
	intent := game.PlayerIntent {
		move_left  = rl.IsKeyDown(.A),
		move_right = rl.IsKeyDown(.D),
		rotate_cw  = rl.IsKeyPressed(.W),
		rotate_ccw = rl.IsKeyPressed(.LEFT_SHIFT),
	}
	apply_down(&intent, down_mode, rl.IsKeyDown(.S), rl.IsKeyPressed(.S))
	return intent
}

// Translate the down key's held/pressed state into soft- or hard-drop intent.
apply_down :: proc(intent: ^game.PlayerIntent, mode: DownMode, held, pressed: bool) {
	switch mode {
	case .FastDrop:
		intent.soft_drop = held
	case .Immediate:
		intent.hard_drop = pressed
	}
}

empty_intent :: proc() -> game.PlayerIntent {
	return game.PlayerIntent{}
}
