package main

import rl "vendor:raylib"
import "game"

// How the down key behaves (a local control preference, applies in all modes).
DownMode :: enum {
	FastDrop,  // hold to fall faster, stops when released (soft drop)
	Immediate, // a press drops and locks the piece instantly (hard drop)
}

// Control schemes. In two-player local modes the LEFT player uses AWSD and the
// RIGHT player uses the arrows+JIKL scheme. Single player picks a scheme via the
// `solo_controls` option.
//
//   AWSD:   A/D move, W rotate CW, Left Shift rotate CCW, S drop
//   Arrows: Left/Right move, Up rotate CW, Z rotate CCW, Down drop
//   JIKL:   J/L move, I rotate CW, U rotate CCW, K drop

gather_awsd :: proc(down_mode: DownMode) -> game.PlayerIntent {
	intent := game.PlayerIntent {
		move_left  = rl.IsKeyDown(.A),
		move_right = rl.IsKeyDown(.D),
		rotate_cw  = rl.IsKeyPressed(.W),
		rotate_ccw = rl.IsKeyPressed(.LEFT_SHIFT),
	}
	apply_down(&intent, down_mode, rl.IsKeyDown(.S), rl.IsKeyPressed(.S))
	return intent
}

gather_arrows :: proc(down_mode: DownMode) -> game.PlayerIntent {
	intent := game.PlayerIntent {
		move_left  = rl.IsKeyDown(.LEFT),
		move_right = rl.IsKeyDown(.RIGHT),
		rotate_cw  = rl.IsKeyPressed(.UP),
		rotate_ccw = rl.IsKeyPressed(.Z),
	}
	apply_down(&intent, down_mode, rl.IsKeyDown(.DOWN), rl.IsKeyPressed(.DOWN))
	return intent
}

gather_jikl :: proc(down_mode: DownMode) -> game.PlayerIntent {
	intent := game.PlayerIntent {
		move_left  = rl.IsKeyDown(.J),
		move_right = rl.IsKeyDown(.L),
		rotate_cw  = rl.IsKeyPressed(.I),
		rotate_ccw = rl.IsKeyPressed(.U),
	}
	apply_down(&intent, down_mode, rl.IsKeyDown(.K), rl.IsKeyPressed(.K))
	return intent
}

// The right-hand player: arrows and JIKL both active (laptop arrow keys are
// often undersized, so JIKL is offered as an ergonomic alternative).
gather_right :: proc(down_mode: DownMode) -> game.PlayerIntent {
	return combine_intents(gather_arrows(down_mode), gather_jikl(down_mode))
}

combine_intents :: proc(a, b: game.PlayerIntent) -> game.PlayerIntent {
	return game.PlayerIntent {
		move_left  = a.move_left  || b.move_left,
		move_right = a.move_right || b.move_right,
		soft_drop  = a.soft_drop  || b.soft_drop,
		rotate_cw  = a.rotate_cw  || b.rotate_cw,
		rotate_ccw = a.rotate_ccw || b.rotate_ccw,
		hard_drop  = a.hard_drop  || b.hard_drop,
	}
}

// Single-player control scheme (Campaign and the local side of head-to-head).
// "All" enables arrows, IJKL and WASD together so left- and right-handed players
// are both covered without changing a setting.
SoloControls :: enum {
	All,    // arrows + IJKL + WASD
	Arrows, // arrows + Z
	JIKL,   // J/I/K/L + U
	WASD,   // A/W/S/D + Left Shift
}

gather_solo :: proc(scheme: SoloControls, down_mode: DownMode) -> game.PlayerIntent {
	switch scheme {
	case .All:    return combine_intents(gather_right(down_mode), gather_awsd(down_mode))
	case .Arrows: return gather_arrows(down_mode)
	case .JIKL:   return gather_jikl(down_mode)
	case .WASD:   return gather_awsd(down_mode)
	}
	return game.PlayerIntent{}
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
