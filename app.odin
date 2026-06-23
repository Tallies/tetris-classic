package main

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

import "game"
import "render"
import netplay "net"

// Application state machine: menus -> setup -> (lobby) -> play. One App holds
// everything; `run` drives it until the window closes.

Screen :: enum {
	MainMenu,
	Setup,       // options for a local mode
	NetMenu,     // head-to-head: direct (LAN) vs online (server)
	LanMenu,     // direct LAN: host or join
	NetJoin,     // type an address to join (LAN)
	ServerSetup, // type the matchmaking server address
	ServerMenu,  // create or browse games
	Options,     // online: drop/ghost/next personal options
	CreateGame,  // name + password + public toggle
	BrowseGames, // list of open games to join
	JoinPassword,// password prompt for a protected game
	Lobby,       // waiting / connecting
	Playing,
}

SNAPSHOT_INTERVAL :: f32(0.05) // 20 Hz opponent-pit updates
DEFAULT_SERVER    :: "127.0.0.1"

App :: struct {
	screen: Screen,

	// menu cursors / chosen options
	main_sel:    int,
	setup_sel:   int,
	netmenu_sel: int,
	lan_sel:     int,
	server_sel:  int,
	options_sel: int,

	mode:           game.GameMode,
	scoring:        game.ScoringSystem,
	time_limit:     game.TimeLimit,
	next_disabled:  bool,
	ghost_disabled: bool,
	down_mode:      DownMode,

	// networking
	net:            ^netplay.Net,
	is_host:        bool,
	seed:           u64,
	addr_buf:       [64]u8, // LAN join address
	addr_len:       int,
	lobby_status:   string,
	snapshot_timer: f32,
	sent_game_over: bool,

	// online (server) entry fields
	server_addr_buf: [64]u8,
	server_addr_len: int,
	name_buf:        [netplay.NAME_LEN]u8, // game name (create / chosen to join)
	name_len:        int,
	pass_buf:        [netplay.NAME_LEN]u8, // password (create / join)
	pass_len:        int,
	create_public:   bool,
	create_field:    int, // 0 name, 1 password, 2 public, 3 start
	browse:          [netplay.MAX_LISTING]netplay.GameInfo,
	browse_count:    int,
	browse_sel:      int,

	session: game.Session,
}

MODE_NAMES := [game.GameMode]string {
	.Campaign    = "Campaign (1P)",
	.Cooperative = "Cooperative (2P)",
	.Competitive = "Competitive (2P)",
	.DualPit     = "Dual Pit (2P)",
	.HeadToHead  = "Head-to-Head (Online)",
}

run :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.InitWindow(1280, 720, "Tetris Classic")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app := App{}
	app.scoring = .TetrisClassic
	app.time_limit = .Unlimited

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		sw := rl.GetScreenWidth()
		sh := rl.GetScreenHeight()

		rl.BeginDrawing()
		switch app.screen {
		case .MainMenu:     update_main_menu(&app)
		case .Setup:        update_setup(&app)
		case .NetMenu:      update_net_menu(&app)
		case .LanMenu:      update_lan_menu(&app)
		case .NetJoin:      update_net_join(&app)
		case .ServerSetup:  update_server_setup(&app)
		case .ServerMenu:   update_server_menu(&app)
		case .Options:      update_options(&app)
		case .CreateGame:   update_create_game(&app)
		case .BrowseGames:  update_browse_games(&app)
		case .JoinPassword: update_join_password(&app)
		case .Lobby:        update_lobby(&app)
		case .Playing:      update_playing(&app, dt)
		}
		draw_screen(&app, sw, sh)
		rl.EndDrawing()
	}

	if app.net != nil {
		netplay.shutdown(app.net)
	}
}

// ---------------------------------------------------------------- main menu ---

update_main_menu :: proc(app: ^App) {
	count := len(game.GameMode) + 1 // modes + Quit
	app.main_sel = menu_navigate(app.main_sel, count)

	if rl.IsKeyPressed(.ENTER) {
		if app.main_sel == count - 1 {
			rl.CloseWindow() // Quit handled by WindowShouldClose next frame
			return
		}
		app.mode = game.GameMode(app.main_sel)
		if app.mode == .HeadToHead {
			app.screen = .NetMenu
			app.netmenu_sel = 0
		} else {
			app.screen = .Setup
			app.setup_sel = 0
		}
	}
}

// ------------------------------------------------------------------- setup ---

SETUP_START :: 5 // index of the START row

update_setup :: proc(app: ^App) {
	app.setup_sel = menu_navigate(app.setup_sel, SETUP_START + 1)

	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.SPACE) {
		right := rl.IsKeyPressed(.RIGHT)
		switch app.setup_sel {
		case 0: app.scoring = game.ScoringSystem((int(app.scoring) + 1) % 2)
		case 1: cycle_time_limit(app, right)
		case 2: app.next_disabled = !app.next_disabled
		case 3: app.down_mode = DownMode((int(app.down_mode) + 1) % 2)
		case 4: app.ghost_disabled = !app.ghost_disabled
		}
	}

	if rl.IsKeyPressed(.ENTER) && app.setup_sel == SETUP_START {
		start_local_game(app)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .MainMenu
	}
}

cycle_time_limit :: proc(app: ^App, right: bool) {
	n := len(game.TimeLimit)
	v := int(app.time_limit)
	v = right ? (v + 1) % n : (v - 1 + n) % n
	app.time_limit = game.TimeLimit(v)
}

start_local_game :: proc(app: ^App) {
	app.seed = make_seed()
	game.session_init(&app.session, app.mode, app.scoring, app.time_limit, app.seed)
	app.session.next_disabled = app.next_disabled
	app.session.ghost_disabled = app.ghost_disabled
	app.screen = .Playing
}

// ------------------------------------------------------- head-to-head menus ---

// Top head-to-head menu: direct LAN vs online (server matchmaking).
update_net_menu :: proc(app: ^App) {
	app.netmenu_sel = menu_navigate(app.netmenu_sel, 3) // Direct / Online / Back

	if rl.IsKeyPressed(.ENTER) {
		switch app.netmenu_sel {
		case 0: app.screen = .LanMenu; app.lan_sel = 0
		case 1:
			app.screen = .ServerSetup
			if app.server_addr_len == 0 {
				set_buf(app.server_addr_buf[:], &app.server_addr_len, DEFAULT_SERVER)
			}
		case 2: app.screen = .MainMenu
		}
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .MainMenu
	}
}

// --- Direct LAN ---

update_lan_menu :: proc(app: ^App) {
	app.lan_sel = menu_navigate(app.lan_sel, 3) // Host / Join / Back

	if rl.IsKeyPressed(.ENTER) {
		switch app.lan_sel {
		case 0: start_host(app)
		case 1: app.screen = .NetJoin; app.addr_len = 0
		case 2: app.screen = .NetMenu
		}
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .NetMenu
	}
}

start_host :: proc(app: ^App) {
	n, ok := netplay.host(netplay.DEFAULT_PORT)
	if !ok {
		app.lobby_status = "Failed to start host (port in use?)"
		app.screen = .Lobby
		return
	}
	app.net = n
	app.is_host = true
	app.lobby_status = fmt.aprintf("Hosting on port %d - waiting for player...", netplay.DEFAULT_PORT)
	app.screen = .Lobby
}

update_net_join :: proc(app: ^App) {
	edit_text(app.addr_buf[:], &app.addr_len)
	if rl.IsKeyPressed(.ENTER) && app.addr_len > 0 {
		start_join(app)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .LanMenu
	}
}

start_join :: proc(app: ^App) {
	addr := string(app.addr_buf[:app.addr_len])
	app.lobby_status = fmt.aprintf("Connecting to %s...", addr)
	app.screen = .Lobby
	n, ok := netplay.join(addr, netplay.DEFAULT_PORT)
	if !ok {
		app.lobby_status = "Connection failed"
		return
	}
	app.net = n
	app.is_host = false
}

// --- Online (matchmaking server) ---

update_server_setup :: proc(app: ^App) {
	edit_text(app.server_addr_buf[:], &app.server_addr_len)
	if rl.IsKeyPressed(.ENTER) && app.server_addr_len > 0 {
		app.screen = .ServerMenu
		app.server_sel = 0
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .NetMenu
	}
}

update_server_menu :: proc(app: ^App) {
	app.server_sel = menu_navigate(app.server_sel, 4) // Create / Browse / Options / Back

	if rl.IsKeyPressed(.ENTER) {
		switch app.server_sel {
		case 0:
			app.screen = .CreateGame
			app.create_field = 0
		case 1:
			start_browse(app)
		case 2:
			app.screen = .Options
			app.options_sel = 0
		case 3:
			app.screen = .ServerSetup
		}
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .ServerSetup
	}
}

// Personal options for online play (down-key behavior + scoring tradeoffs).
// These edit the same app fields the local Setup screen uses, so they apply
// everywhere.
update_options :: proc(app: ^App) {
	app.options_sel = menu_navigate(app.options_sel, 3) // Down / Ghost / Next

	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.SPACE) {
		switch app.options_sel {
		case 0: app.down_mode = DownMode((int(app.down_mode) + 1) % 2)
		case 1: app.ghost_disabled = !app.ghost_disabled
		case 2: app.next_disabled = !app.next_disabled
		}
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.ESCAPE) {
		app.screen = .ServerMenu
	}
}

update_create_game :: proc(app: ^App) {
	app.create_field = menu_navigate(app.create_field, 4)

	switch app.create_field {
	case 0: edit_text(app.name_buf[:], &app.name_len)
	case 1: edit_text(app.pass_buf[:], &app.pass_len)
	case 2:
		if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.SPACE) {
			app.create_public = !app.create_public
		}
	}

	if rl.IsKeyPressed(.ENTER) && app.create_field == 3 && app.name_len > 0 {
		submit_create(app)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .ServerMenu
	}
}

submit_create :: proc(app: ^App) {
	if !connect_server(app) do return
	netplay.send_create(
		app.net,
		string(app.name_buf[:app.name_len]),
		string(app.pass_buf[:app.pass_len]),
		app.create_public,
	)
	app.lobby_status = "Creating game - waiting for opponent..."
	app.screen = .Lobby
}

start_browse :: proc(app: ^App) {
	if !connect_server(app) do return
	app.browse_count = 0
	app.browse_sel = 0
	netplay.send_list(app.net)
	app.screen = .BrowseGames
}

update_browse_games :: proc(app: ^App) {
	if app.net != nil {
		handle_net_events(app, netplay.poll(app.net))
	}
	// handle_net_events may have transitioned us (match/error); stop if so.
	if app.screen != .BrowseGames do return

	if app.browse_count > 0 {
		app.browse_sel = menu_navigate(app.browse_sel, app.browse_count)
	}
	if rl.IsKeyPressed(.R) && app.net != nil {
		netplay.send_list(app.net)
	}
	if rl.IsKeyPressed(.ENTER) && app.browse_count > 0 {
		g := app.browse[app.browse_sel]
		set_buf(app.name_buf[:], &app.name_len, netplay.buf_to_name(g.name[:]))
		if g.has_password != 0 {
			app.pass_len = 0
			app.screen = .JoinPassword
		} else {
			submit_join(app, "")
		}
	}
	if rl.IsKeyPressed(.ESCAPE) {
		leave_game(app)
		app.screen = .ServerMenu
	}
}

update_join_password :: proc(app: ^App) {
	edit_text(app.pass_buf[:], &app.pass_len)
	if rl.IsKeyPressed(.ENTER) {
		submit_join(app, string(app.pass_buf[:app.pass_len]))
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .BrowseGames
	}
}

submit_join :: proc(app: ^App, password: string) {
	if app.net == nil do return
	netplay.send_join(app.net, string(app.name_buf[:app.name_len]), password)
	app.lobby_status = "Joining game..."
	app.screen = .Lobby
}

// Dial the matchmaking server, storing the connection on the app.
connect_server :: proc(app: ^App) -> bool {
	addr := string(app.server_addr_buf[:app.server_addr_len])
	n, ok := netplay.connect_server(addr, netplay.DEFAULT_PORT)
	if !ok {
		app.lobby_status = fmt.aprintf("Could not reach server %s", addr)
		app.screen = .Lobby
		return false
	}
	app.net = n
	return true
}

// -------------------------------------------------------------------- lobby ---

update_lobby :: proc(app: ^App) {
	if rl.IsKeyPressed(.ESCAPE) {
		leave_game(app)
		app.screen = .MainMenu
		return
	}
	if app.net == nil do return
	handle_net_events(app, netplay.poll(app.net))
}

// Central handler for all network events, shared by the lobby and browse
// screens. Drives the create/join/match handshake and starts the game.
handle_net_events :: proc(app: ^App, events: []netplay.Event) {
	for ev in events {
		#partial switch e in ev {
		case netplay.Connected:
			// Direct-LAN host saw the peer arrive: send params and start.
			if app.is_host {
				app.seed = make_seed()
				netplay.send_start(app.net, netplay.StartPayload{
					seed = app.seed, scoring = u8(app.scoring), time_limit = u8(app.time_limit),
				})
				begin_head_to_head(app)
			}

		case netplay.Matched:
			// Server paired us. The creator (is_host) drives the seed.
			app.is_host = e.is_host
			if app.is_host {
				app.seed = make_seed()
				netplay.send_start(app.net, netplay.StartPayload{
					seed = app.seed, scoring = u8(app.scoring), time_limit = u8(app.time_limit),
				})
				begin_head_to_head(app)
			} else {
				app.lobby_status = "Matched - starting..."
				app.screen = .Lobby
			}

		case netplay.StartPayload:
			// Guest (LAN or online) receives parameters and starts.
			app.seed = e.seed
			app.scoring = game.ScoringSystem(e.scoring)
			app.time_limit = game.TimeLimit(e.time_limit)
			begin_head_to_head(app)

		case netplay.ListingPayload:
			app.browse_count = min(int(e.count), netplay.MAX_LISTING)
			for i in 0 ..< app.browse_count {
				app.browse[i] = e.games[i]
			}
			if app.browse_sel >= app.browse_count {
				app.browse_sel = max(0, app.browse_count - 1)
			}

		case netplay.CreateResult:
			if !e.ok {
				app.lobby_status = "Game name already in use"
				leave_game(app)
				app.screen = .CreateGame
			} else {
				app.lobby_status = "Waiting for opponent to join..."
			}

		case netplay.JoinResult:
			if !e.ok {
				app.lobby_status = join_error(e.reason)
				leave_game(app)
				app.screen = .BrowseGames
			}

		case netplay.Disconnected:
			app.lobby_status = "Disconnected"
			leave_game(app)
		}
	}
}

join_error :: proc(r: netplay.ResultReason) -> string {
	#partial switch r {
	case .NotFound:      return "Game not found"
	case .WrongPassword: return "Wrong password"
	case .Full:          return "Game is full"
	}
	return "Could not join"
}

begin_head_to_head :: proc(app: ^App) {
	game.session_init(&app.session, .HeadToHead, app.scoring, app.time_limit, app.seed)
	app.session.next_disabled = app.next_disabled
	app.session.ghost_disabled = app.ghost_disabled
	app.snapshot_timer = 0
	app.sent_game_over = false
	app.screen = .Playing
}

// ------------------------------------------------------------------ playing ---

update_playing :: proc(app: ^App, dt: f32) {
	s := &app.session

	if rl.IsKeyPressed(.P) {
		game.session_toggle_pause(s)
	}
	if s.state == .GameOver && rl.IsKeyPressed(.ENTER) {
		leave_game(app)
		return
	}
	if rl.IsKeyPressed(.ESCAPE) {
		leave_game(app)
		return
	}

	if app.mode == .HeadToHead {
		update_head_to_head(app, dt)
		return
	}

	// Local modes.
	intents: [2]game.PlayerIntent
	intents[0] = gather_intent_p1(app.down_mode)
	if s.num_players > 1 {
		intents[1] = gather_intent_p2(app.down_mode)
	}
	game.session_update(s, dt, intents)
}

update_head_to_head :: proc(app: ^App, dt: f32) {
	s := &app.session
	n := app.net

	intents: [2]game.PlayerIntent
	intents[0] = gather_intent_p1(app.down_mode)
	game.session_update(s, dt, intents)

	if n == nil do return

	// Ship any garbage we produced.
	if s.outgoing_garbage > 0 {
		netplay.send_garbage(n, s.outgoing_garbage)
		s.outgoing_garbage = 0
	}

	// Notify the peer once when we top out.
	if s.players[0].topped_out && !app.sent_game_over {
		netplay.send_game_over(n)
		app.sent_game_over = true
	}

	// Stream our pit to the opponent at a fixed rate.
	app.snapshot_timer += dt
	if app.snapshot_timer >= SNAPSHOT_INTERVAL {
		app.snapshot_timer = 0
		netplay.send_snapshot(n, make_snapshot(s))
	}

	// Apply incoming events.
	events := netplay.poll(n)
	for ev in events {
		#partial switch e in ev {
		case netplay.SnapshotPayload:
			apply_snapshot(s, e)
		case netplay.GarbagePayload:
			game.queue_garbage(&s.boards[0], int(e.count))
		case netplay.GameOverMsg:
			s.remote_dead = true
		case netplay.Disconnected:
			// Opponent left: we win by default.
			s.remote_dead = true
		}
	}
}

leave_game :: proc(app: ^App) {
	if app.net != nil {
		netplay.shutdown(app.net)
		app.net = nil
	}
	app.screen = .MainMenu
}

// Build a snapshot of the local pit (board[0]/player[0]) for the opponent.
make_snapshot :: proc(s: ^game.Session) -> netplay.SnapshotPayload {
	b := &s.boards[0]
	p := &s.players[0]
	sp := netplay.SnapshotPayload{
		cells      = b.cells,
		score      = i32(p.score),
		lines      = i32(p.lines),
		level      = i32(p.level),
		piece_kind = u8(p.current.kind),
		piece_rot  = u8(p.current.rotation),
		piece_x    = i32(p.current.x),
		piece_y    = i32(p.current.y),
		next_kind  = u8(p.next),
		has_piece  = p.has_piece ? 1 : 0,
		topped_out = p.topped_out ? 1 : 0,
	}
	return sp
}

// Write a received snapshot into the opponent mirror (board[1]/player[1]).
apply_snapshot :: proc(s: ^game.Session, sp: netplay.SnapshotPayload) {
	b := &s.boards[1]
	p := &s.players[1]
	b.cells = sp.cells
	p.score = int(sp.score)
	p.lines = int(sp.lines)
	p.level = int(sp.level)
	p.current = game.Piece{
		kind     = game.PieceKind(sp.piece_kind),
		rotation = game.Rotation(sp.piece_rot),
		x        = int(sp.piece_x),
		y        = int(sp.piece_y),
	}
	p.next = game.PieceKind(sp.next_kind)
	p.has_piece = sp.has_piece != 0
	p.topped_out = sp.topped_out != 0
	p.active = true
}

make_seed :: proc() -> u64 {
	t := transmute(u64)rl.GetTime()
	r := u64(rl.GetRandomValue(1, 1 << 30))
	s := t ~ (r << 21) ~ 0x9E3779B97F4A7C15
	if s == 0 do s = 0xD1B54A32D192ED03
	return s
}

// ----------------------------------------------------------------- drawing ---

draw_screen :: proc(app: ^App, sw, sh: i32) {
	switch app.screen {
	case .MainMenu:
		items: [len(game.GameMode) + 1]string
		for m in game.GameMode {
			items[int(m)] = MODE_NAMES[m]
		}
		items[len(game.GameMode)] = "Quit"
		draw_menu_list("Select Mode", "", items[:], app.main_sel, sw, sh)

	case .Setup:
		draw_setup(app, sw, sh)

	case .NetMenu:
		items := []string{"Direct (LAN)", "Online (Server)", "Back"}
		draw_menu_list("Head-to-Head", "Same network, or online via a matchmaking server", items, app.netmenu_sel, sw, sh)

	case .LanMenu:
		items := []string{"Host Game", "Join Game", "Back"}
		draw_menu_list("Direct (LAN)", "Play another machine on the same network", items, app.lan_sel, sw, sh)

	case .NetJoin:
		draw_net_join(app, sw, sh)

	case .ServerSetup:
		draw_text_entry(app, sw, sh, "MATCHMAKING SERVER", "Enter server address (IP or hostname):",
			string(app.server_addr_buf[:app.server_addr_len]), "Enter to continue   Esc back")

	case .ServerMenu:
		items := []string{"Create Game", "Browse Games", "Options", "Back"}
		sub := fmt.tprintf("Server: %s", string(app.server_addr_buf[:app.server_addr_len]))
		draw_menu_list("Online Play", sub, items, app.server_sel, sw, sh)

	case .Options:
		draw_options(app, sw, sh)

	case .CreateGame:
		draw_create_game(app, sw, sh)

	case .BrowseGames:
		draw_browse_games(app, sw, sh)

	case .JoinPassword:
		draw_text_entry(app, sw, sh, "PASSWORD REQUIRED",
			fmt.tprintf("Enter password for %q:", string(app.name_buf[:app.name_len])),
			mask(app.pass_len), "Enter to join   Esc back")

	case .Lobby:
		rl.DrawRectangleGradientV(0, 0, sw, sh, {16, 32, 56, 255}, {6, 6, 16, 255})
		render.text_center("HEAD-TO-HEAD", sw / 2, 120, 48, render.COLOR_HIGHLIGHT)
		render.text_center(app.lobby_status, sw / 2, sh / 2, 26, render.COLOR_TEXT)
		render.text_center("Esc to cancel", sw / 2, sh - 60, 20, render.COLOR_TEXT_DIM)

	case .Playing:
		p1 := app.mode == .HeadToHead ? "YOU" : "PLAYER 1"
		p2 := app.mode == .HeadToHead ? "OPPONENT" : "PLAYER 2"
		render.draw_session(&app.session, sw, sh, p1, p2)
	}
}

draw_setup :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {20, 22, 48, 255}, {6, 6, 16, 255})
	render.text_center("TETRIS CLASSIC", sw / 2, 70, 56, render.COLOR_HIGHLIGHT)
	render.text_center(MODE_NAMES[app.mode], sw / 2, 150, 30, render.COLOR_TEXT)

	rows := []string{
		fmt.tprintf("Scoring:     < %s >", scoring_name(app.scoring)),
		fmt.tprintf("Time Limit:  < %s >", time_limit_name(app.time_limit)),
		fmt.tprintf("Next Piece:  < %s >", next_name(app.next_disabled)),
		fmt.tprintf("Down Key:    < %s >", down_mode_name(app.down_mode)),
		fmt.tprintf("Ghost Piece: < %s >", ghost_name(app.ghost_disabled)),
		"START",
	}
	start_y := i32(230)
	for r, i in rows {
		y := start_y + i32(i) * 52
		color := render.COLOR_TEXT_DIM
		if i == app.setup_sel {
			color = render.COLOR_HIGHLIGHT
		}
		render.text_center(strings.clone(r, context.temp_allocator), sw / 2, y, 30, color)
	}
	render.text_center("Up/Down move   Left/Right change   Enter start   Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

draw_net_join :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {16, 32, 56, 255}, {6, 6, 16, 255})
	render.text_center("JOIN GAME", sw / 2, 120, 48, render.COLOR_HIGHLIGHT)
	render.text_center("Enter host address (IP or hostname):", sw / 2, 230, 24, render.COLOR_TEXT)

	addr := app.addr_len > 0 ? string(app.addr_buf[:app.addr_len]) : "_"
	box_w := i32(500)
	bx := sw / 2 - box_w / 2
	rl.DrawRectangleRec({f32(bx), f32(sh / 2 - 30), f32(box_w), 60}, {0, 0, 0, 140})
	rl.DrawRectangleLinesEx({f32(bx), f32(sh / 2 - 30), f32(box_w), 60}, 2, render.COLOR_BORDER)
	render.text(strings.clone(addr, context.temp_allocator), bx + 16, sh / 2 - 14, 28, render.COLOR_TEXT)

	render.text_center(fmt.tprintf("Port %d", netplay.DEFAULT_PORT), sw / 2, sh / 2 + 60, 20, render.COLOR_TEXT_DIM)
	render.text_center("Enter to connect   Esc back", sw / 2, sh - 60, 20, render.COLOR_TEXT_DIM)
}

// --- shared input + drawing helpers for the online screens ---

// Append typed characters / handle backspace for a fixed text buffer.
edit_text :: proc(buf: []u8, length: ^int) {
	for {
		ch := rl.GetCharPressed()
		if ch == 0 do break
		if ch >= 32 && ch < 127 && length^ < len(buf) {
			buf[length^] = u8(ch)
			length^ += 1
		}
	}
	if rl.IsKeyPressed(.BACKSPACE) && length^ > 0 {
		length^ -= 1
	}
}

// Set a fixed text buffer to a string (truncating to capacity).
set_buf :: proc(buf: []u8, length: ^int, s: string) {
	n := min(len(s), len(buf))
	for i in 0 ..< n {
		buf[i] = s[i]
	}
	length^ = n
}

// A masked rendering of a password (bullets) of the given length.
mask :: proc(n: int) -> string {
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		b[i] = '*'
	}
	return string(b)
}

// Single-field text-entry screen.
draw_text_entry :: proc(app: ^App, sw, sh: i32, title, prompt: string, value: string, hint: string) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {16, 32, 56, 255}, {6, 6, 16, 255})
	render.text_center(title, sw / 2, 120, 48, render.COLOR_HIGHLIGHT)
	render.text_center(prompt, sw / 2, 230, 24, render.COLOR_TEXT)

	shown := len(value) > 0 ? value : "_"
	box_w := i32(500)
	bx := sw / 2 - box_w / 2
	rl.DrawRectangleRec({f32(bx), f32(sh / 2 - 30), f32(box_w), 60}, {0, 0, 0, 140})
	rl.DrawRectangleLinesEx({f32(bx), f32(sh / 2 - 30), f32(box_w), 60}, 2, render.COLOR_BORDER)
	render.text(strings.clone(shown, context.temp_allocator), bx + 16, sh / 2 - 14, 28, render.COLOR_TEXT)

	render.text_center(hint, sw / 2, sh - 60, 20, render.COLOR_TEXT_DIM)
}

draw_options :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {16, 32, 56, 255}, {6, 6, 16, 255})
	render.text_center("OPTIONS", sw / 2, 100, 48, render.COLOR_HIGHLIGHT)
	render.text_center("Applies to your games in every mode", sw / 2, 165, 20, render.COLOR_TEXT_DIM)

	rows := []string{
		fmt.tprintf("Down Key:    < %s >", down_mode_name(app.down_mode)),
		fmt.tprintf("Ghost Piece: < %s >", ghost_name(app.ghost_disabled)),
		fmt.tprintf("Next Piece:  < %s >", next_name(app.next_disabled)),
	}
	start_y := i32(280)
	for r, i in rows {
		y := start_y + i32(i) * 56
		color := i == app.options_sel ? render.COLOR_HIGHLIGHT : render.COLOR_TEXT_DIM
		render.text_center(strings.clone(r, context.temp_allocator), sw / 2, y, 30, color)
	}
	render.text_center("Up/Down move   Left/Right change   Enter/Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

draw_create_game :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {16, 32, 56, 255}, {6, 6, 16, 255})
	render.text_center("CREATE GAME", sw / 2, 90, 48, render.COLOR_HIGHLIGHT)

	name_val := app.name_len > 0 ? string(app.name_buf[:app.name_len]) : "_"
	pass_val := app.pass_len > 0 ? mask(app.pass_len) : "(none)"
	public_val := app.create_public ? "Yes (listed in Browse)" : "No (join by name only)"

	rows := []string{
		fmt.tprintf("Name:      %s", name_val),
		fmt.tprintf("Password:  %s", pass_val),
		fmt.tprintf("Public:    < %s >", public_val),
		"CREATE",
	}
	start_y := i32(240)
	for r, i in rows {
		y := start_y + i32(i) * 60
		color := i == app.create_field ? render.COLOR_HIGHLIGHT : render.COLOR_TEXT_DIM
		render.text_center(strings.clone(r, context.temp_allocator), sw / 2, y, 30, color)
	}
	render.text_center("Up/Down field   type to edit   Left/Right toggle   Enter create   Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

draw_browse_games :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {16, 32, 56, 255}, {6, 6, 16, 255})
	render.text_center("BROWSE GAMES", sw / 2, 80, 48, render.COLOR_HIGHLIGHT)

	if app.browse_count == 0 {
		render.text_center("No open games. Press R to refresh.", sw / 2, sh / 2, 26, render.COLOR_TEXT_DIM)
	} else {
		start_y := i32(200)
		for i in 0 ..< app.browse_count {
			g := app.browse[i]
			name := netplay.buf_to_name(g.name[:])
			lock := g.has_password != 0 ? " [locked]" : ""
			line := fmt.tprintf("%s%s", name, lock)
			color := i == app.browse_sel ? render.COLOR_HIGHLIGHT : render.COLOR_TEXT
			prefix := i == app.browse_sel ? "> " : "  "
			render.text_center(strings.clone(fmt.tprintf("%s%s", prefix, line), context.temp_allocator),
				sw / 2, start_y + i32(i) * 44, 28, color)
		}
	}
	render.text_center("Up/Down select   Enter join   R refresh   Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

time_limit_name :: proc(t: game.TimeLimit) -> string {
	switch t {
	case .Unlimited: return "Unlimited"
	case .Min15:     return "15 min"
	case .Min10:     return "10 min"
	case .Min5:      return "5 min"
	case .Min3:      return "3 min"
	}
	return "?"
}

scoring_name :: proc(s: game.ScoringSystem) -> string {
	return s == .Original ? "Original" : "Tetris Classic"
}

next_name :: proc(disabled: bool) -> string {
	return disabled ? fmt.tprintf("Off (+%d%% score)", game.NEXT_OFF_BONUS_PCT) : "On"
}

ghost_name :: proc(disabled: bool) -> string {
	return disabled ? fmt.tprintf("Off (+%d%% score)", game.GHOST_OFF_BONUS_PCT) : "On"
}

down_mode_name :: proc(m: DownMode) -> string {
	return m == .FastDrop ? "Fast drop" : "Immediate drop"
}
