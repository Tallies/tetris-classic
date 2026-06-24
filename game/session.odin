package game

// Session ties Boards and Players together for a specific GameMode and drives
// the whole simulation from one `session_update`. This is the single entry
// point the renderer and networking layers use to step the game.
//
// Board/player wiring per mode:
//   Campaign            board[0] <- player[0]
//   Cooperative         board[0] <- player[0], player[1]   (shared score)
//   Competitive         board[0] <- player[0], player[1]   (separate scores)
//   DualPit/HeadToHead  board[0] <- player[0], board[1] <- player[1]

// Delayed Auto Shift tuning for held left/right.
DAS_DELAY  :: f32(0.17) // before auto-repeat begins
DAS_REPEAT :: f32(0.04) // between auto-repeat steps

SessionState :: enum u8 {
	Playing,
	GameOver,
}

// Per-frame player intent produced by input (local keys or network packets).
// move_left/right and soft_drop are "held this frame"; rotate/hard_drop are
// edges (pressed this frame).
PlayerIntent :: struct {
	move_left:  bool,
	move_right: bool,
	soft_drop:  bool,
	rotate_cw:  bool,
	rotate_ccw: bool,
	hard_drop:  bool,
}

Session :: struct {
	mode:           GameMode,
	scoring:        ScoringSystem,
	next_disabled:  bool,
	ghost_disabled: bool,

	boards:      [2]Board,
	players:     [2]Player,
	num_boards:  int,
	num_players: int,

	// Per-player DAS state.
	das_timer: [2]f32,
	das_dir:   [2]int, // -1, 0, +1

	// Campaign timing.
	time_limit:     TimeLimit,
	time_remaining: f32, // seconds; only meaningful when time_limit != Unlimited
	elapsed:        f32,

	state:  SessionState,
	winner: int, // -1 = none/draw, else player index
	paused: bool,

	// Head-to-head only: garbage produced locally that must be sent to the
	// remote peer (the app drains this each frame), and whether the remote
	// player has topped out (set from a network message).
	outgoing_garbage: int,
	remote_dead:      bool,

	// Which player triggered the in-progress line-clear flash on each board, so
	// the right player is credited when it commits. -1 = none pending.
	clear_owner: [2]int,
}

time_limit_seconds :: proc(t: TimeLimit) -> f32 {
	switch t {
	case .Unlimited: return 0
	case .Min15:     return 15 * 60
	case .Min10:     return 10 * 60
	case .Min5:      return 5 * 60
	case .Min3:      return 3 * 60
	}
	return 0
}

// Which board a player plays on.
player_board :: proc(s: ^Session, idx: int) -> ^Board {
	return &s.boards[board_index(s, idx)]
}

// Board slot index for a player.
board_index :: proc(s: ^Session, idx: int) -> int {
	if s.mode == .DualPit || s.mode == .HeadToHead {
		return idx
	}
	return 0
}

// Other players sharing a board with player idx (for collision). Returns a
// slice into a caller-independent static-free temp via the provided backing
// array.
others_of :: proc(s: ^Session, idx: int, backing: ^[1]^Player) -> []^Player {
	// Only shared-pit modes have a co-located other player.
	if s.mode == .Cooperative || s.mode == .Competitive {
		other := 1 - idx
		if other >= 0 && other < s.num_players && s.players[other].active {
			backing[0] = &s.players[other]
			return backing[:]
		}
	}
	return nil
}

// Configure a session for a mode. `seed` drives all randomization; pass the same
// seed on both ends of a network game to stay in sync.
session_init :: proc(s: ^Session, mode: GameMode, scoring: ScoringSystem, time_limit: TimeLimit, seed: u64) {
	s^ = Session{}
	s.mode = mode
	s.scoring = scoring
	s.time_limit = time_limit
	s.time_remaining = time_limit_seconds(time_limit)
	s.winner = -1
	s.state = .Playing
	s.clear_owner = {-1, -1}

	switch mode {
	case .Campaign:
		s.num_boards = 1
		s.num_players = 1
		board_init(&s.boards[0], PIT_WIDTH, PIT_HEIGHT, seed)
		player_init(&s.boards[0], &s.players[0], seed ~ 0xA1, -1)

	case .Cooperative, .Competitive:
		s.num_boards = 1
		s.num_players = 2
		board_init(&s.boards[0], SHARED_WIDTH, PIT_HEIGHT, seed)
		// Spawn the two players toward opposite sides of the shared pit.
		player_init(&s.boards[0], &s.players[0], seed ~ 0xA1, SHARED_WIDTH / 4 - 2)
		player_init(&s.boards[0], &s.players[1], seed ~ 0xB2, 3 * SHARED_WIDTH / 4 - 2)

	case .DualPit, .HeadToHead:
		s.num_boards = 2
		s.num_players = 2
		board_init(&s.boards[0], PIT_WIDTH, PIT_HEIGHT, seed)
		board_init(&s.boards[1], PIT_WIDTH, PIT_HEIGHT, seed ~ 0xCAFE)
		// Both players draw from the SAME piece seed so they get the identical
		// tetromino sequence regardless of pace. Each bag RNG is independent and
		// only advances on its own draws, so the Nth piece matches for both.
		// (In head-to-head each machine simulates its own player 0 with the same
		// shared seed, so the sequences match across the network too.)
		player_init(&s.boards[0], &s.players[0], seed ~ 0xA1, -1)
		player_init(&s.boards[1], &s.players[1], seed ~ 0xA1, -1)
	}
}

// Apply one player's intent and advance their piece by dt. Handles DAS, soft
// drop scoring, hard drop, rotation, then gravity. Returns lines cleared so the
// caller can route garbage.
step_player :: proc(s: ^Session, idx: int, intent: PlayerIntent, dt: f32) -> int {
	p := &s.players[idx]
	if !p.active || p.topped_out do return 0
	b := player_board(s, idx)
	if b.clearing do return 0 // board frozen during the line-clear flash

	backing: [1]^Player
	others := others_of(s, idx, &backing)

	// No active piece (just locked, or post-clear): try to spawn the next one.
	// On a shared pit this may wait a frame for the partner's piece to pass.
	if !p.has_piece {
		try_spawn(b, p, others)
		return 0 // either still waiting, topped out, or freshly spawned
	}

	// Rotation (edge-triggered).
	if intent.rotate_cw  do try_rotate(b, p, true, others)
	if intent.rotate_ccw do try_rotate(b, p, false, others)

	// Horizontal movement with DAS.
	dir := 0
	if intent.move_left  do dir -= 1
	if intent.move_right do dir += 1
	if dir != 0 && dir != s.das_dir[idx] {
		// New press: move once immediately, then arm the initial delay.
		try_move(b, p, dir, 0, others)
		s.das_dir[idx] = dir
		s.das_timer[idx] = DAS_DELAY
	} else if dir != 0 && dir == s.das_dir[idx] {
		s.das_timer[idx] -= dt
		for s.das_timer[idx] <= 0 {
			if !try_move(b, p, dir, 0, others) do break
			s.das_timer[idx] += DAS_REPEAT
		}
	} else {
		s.das_dir[idx] = 0
		s.das_timer[idx] = 0
	}

	// Hard drop (edge-triggered) preempts gravity this frame.
	if intent.hard_drop {
		dropped, _ := hard_drop(b, p, others)
		award_hard_drop(p, dropped)
	} else {
		y_before := p.current.y
		gravity := gravity_for_level(p.level)
		player_update(b, p, dt, gravity, intent.soft_drop, others)
		if intent.soft_drop && p.has_piece {
			award_soft_drop(p, max(0, p.current.y - y_before))
		}
	}

	// If this lock started a line-clear flash, remember who triggered it so the
	// right player is scored when the flash commits.
	bidx := board_index(s, idx)
	if b.clearing && s.clear_owner[bidx] < 0 {
		s.clear_owner[bidx] = idx
	}
	return 0
}

// Score a clear and route garbage according to mode.
handle_clear :: proc(s: ^Session, idx: int, cleared: int) {
	p := &s.players[idx]
	award_lines(p, cleared, s.scoring, s.next_disabled, s.ghost_disabled)

	#partial switch s.mode {
	case .DualPit:
		send := garbage_to_send(cleared)
		if send > 0 {
			queue_garbage(player_board(s, 1 - idx), send)
		}
	case .HeadToHead:
		// The opponent's pit lives on the remote machine; queue garbage for the
		// app to ship over the network rather than applying it locally.
		s.outgoing_garbage += garbage_to_send(cleared)
	}
}

// Advance the whole session by dt with both players' intents. Players not in use
// should pass a zeroed intent.
session_update :: proc(s: ^Session, dt: f32, intents: [2]PlayerIntent) {
	if s.state != .Playing || s.paused do return

	s.elapsed += dt
	if s.time_limit != .Unlimited {
		s.time_remaining -= dt
		if s.time_remaining <= 0 {
			s.time_remaining = 0
			end_session(s)
			return
		}
	}

	if s.mode == .HeadToHead {
		// Only the local player (index 0) is simulated here; the opponent's pit
		// (board[1]/player[1]) is a mirror updated by the app from snapshots.
		step_player(s, 0, intents[0], dt)
		resolve_board_clear(s, 0, dt)
	} else {
		for i in 0 ..< s.num_players {
			step_player(s, i, intents[i], dt)
		}
		for bi in 0 ..< s.num_boards {
			resolve_board_clear(s, bi, dt)
		}
	}

	check_end(s)
}

// Advance the line-clear flash on a board; when it elapses, remove the rows,
// score the triggering player, and apply pending garbage. Players left without
// a piece are respawned by step_player (via try_spawn) on the next frame.
resolve_board_clear :: proc(s: ^Session, bidx: int, dt: f32) {
	b := &s.boards[bidx]
	if !b.clearing do return

	b.clear_timer += dt
	if b.clear_timer < CLEAR_FLASH_TIME do return

	n := clear_lines(b)
	b.clearing = false
	b.clear_timer = 0

	if b.pending_garbage > 0 {
		insert_garbage(b, b.pending_garbage)
		b.pending_garbage = 0
	}

	owner := s.clear_owner[bidx]
	s.clear_owner[bidx] = -1
	if owner >= 0 && n > 0 {
		handle_clear(s, owner, n)
	}
}

// Determine whether the session has ended and who won.
check_end :: proc(s: ^Session) {
	switch s.mode {
	case .Campaign:
		if s.players[0].topped_out {
			s.winner = -1
			end_session(s)
		} else if s.players[0].lines >= MAX_LEVEL * LINES_PER_LEVEL {
			s.winner = 0 // campaign cleared
			end_session(s)
		}

	case .Cooperative:
		if s.boards[0].game_over {
			s.winner = -1 // co-op: no individual winner
			end_session(s)
		}

	case .Competitive:
		if s.boards[0].game_over {
			decide_by_score(s)
			end_session(s)
		}

	case .DualPit:
		p0_dead := s.players[0].topped_out
		p1_dead := s.players[1].topped_out
		if p0_dead || p1_dead {
			if p0_dead && p1_dead {
				decide_by_score(s)
			} else {
				s.winner = p0_dead ? 1 : 0
			}
			end_session(s)
		}

	case .HeadToHead:
		p0_dead := s.players[0].topped_out
		if p0_dead || s.remote_dead {
			if p0_dead && s.remote_dead {
				decide_by_score(s)
			} else {
				s.winner = p0_dead ? 1 : 0
			}
			end_session(s)
		}
	}
}

decide_by_score :: proc(s: ^Session) {
	if s.players[0].score > s.players[1].score {
		s.winner = 0
	} else if s.players[1].score > s.players[0].score {
		s.winner = 1
	} else {
		s.winner = -1
	}
}

// On a time-limit expiry, decide the outcome per mode.
end_session :: proc(s: ^Session) {
	if s.state == .GameOver do return
	// If we reached here via time expiry without a winner decided, pick one.
	if s.time_limit != .Unlimited && s.time_remaining <= 0 {
		#partial switch s.mode {
		case .Campaign:
			// Survived to the clock: count as cleared.
			s.winner = 0
		case .Competitive, .DualPit, .HeadToHead:
			decide_by_score(s)
		case .Cooperative:
			s.winner = -1
		}
	}
	s.state = .GameOver
}

session_toggle_pause :: proc(s: ^Session) {
	if s.state == .Playing {
		s.paused = !s.paused
	}
}

// Combined score for co-op display.
team_score :: proc(s: ^Session) -> int {
	return s.players[0].score + s.players[1].score
}
