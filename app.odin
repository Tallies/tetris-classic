package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

import "audio"
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
	About,       // author / version / description + License / Close buttons
	License,     // CC BY-NC-SA 4.0 summary
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
	paused_sel:  int,
	about_sel:   int,

	mode:           game.GameMode,
	scoring:        game.ScoringSystem,
	time_limit:     game.TimeLimit,
	next_disabled:  bool,
	ghost_disabled: bool,
	down_mode:      DownMode,
	solo_controls:  SoloControls,
	mouse_enabled:  bool, // mouse gameplay control (toggle with C); trackpad can interfere
	config_dirty:   bool, // a persisted setting changed this frame; flush at frame end

	// networking
	net:            ^netplay.Net,
	is_host:        bool,
	seed:           u64,

	// async connect (so the UI stays responsive while dialing)
	dial:           ^netplay.Dial,
	dial_cancelled: bool,
	dial_action:    DialAction,
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

	// previous-frame values for deriving sound-effect triggers
	prev_lines:      int,
	prev_level:      int,
	prev_game_over:  bool,

	// recently-connected addresses (most-recent-first, cap ADDR_HISTORY_MAX),
	// separate lists because LAN and online values rarely overlap (persisted)
	lan_history:    [dynamic]string,
	srv_history:    [dynamic]string,

	// single-player high score (persisted)
	high_score:     int,
	new_high_score: bool,

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
	rl.SetExitKey(.KEY_NULL) // we handle Esc ourselves (pause menu); don't let it quit

	audio.init()
	defer audio.shutdown()

	app := App{}
	app.scoring = .TetrisClassic
	app.time_limit = .Unlimited
	app.solo_controls = .All // arrows, IJKL and WASD all work out of the box
	app.mouse_enabled = true
	app.high_score = load_highscore()
	config_load(&app) // restore saved settings + address history over the defaults
	defer config_save(&app)

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		sw := rl.GetScreenWidth()
		sh := rl.GetScreenHeight()

		handle_hotkeys(&app)
		audio.update()
		poll_connect(&app)

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
		case .About:        update_about(&app)
		case .License:      update_license(&app)
		}
		draw_screen(&app, sw, sh)
		draw_hotkey_hint(&app, sw, sh)
		rl.EndDrawing()

		// Persist settings the moment they change (the exit-time defer can be
		// skipped on a forced window close, so we don't rely on it alone).
		if app.config_dirty {
			config_save(&app)
			app.config_dirty = false
		}

		// All temp allocations (tprintf/ctprintf strings, label slices) are
		// frame-scoped; reclaim them so the arena doesn't grow over a session.
		free_all(context.temp_allocator)
	}

	if app.net != nil {
		netplay.shutdown(app.net)
	}
}

// ---------------------------------------------------------------- main menu ---

update_main_menu :: proc(app: ^App) {
	count := len(game.GameMode) + 2 // modes + About + Quit
	app.main_sel = menu_navigate(app.main_sel, count)

	activate := rl.IsKeyPressed(.ENTER)
	if h, clicked := mouse_menu_pick(count); h >= 0 {
		app.main_sel = h
		if clicked do activate = true
	}

	if activate {
		if app.main_sel == count - 1 {
			rl.CloseWindow() // Quit handled by WindowShouldClose next frame
			return
		}
		if app.main_sel == len(game.GameMode) { // About
			app.screen = .About
			app.about_sel = 0
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

// Setup rows. The Controls scheme only applies to single player, so it appears
// only in Campaign setup; two-player modes have fixed AWSD (left) / arrows+JIKL
// (right) controls.
SetupField :: enum {
	Scoring, TimeLimit, Next, Down, Ghost, Controls, Start,
}

SETUP_CAMPAIGN := [?]SetupField{.Scoring, .TimeLimit, .Next, .Down, .Ghost, .Controls, .Start}
SETUP_LOCAL    := [?]SetupField{.Scoring, .TimeLimit, .Next, .Down, .Ghost, .Start}
SETUP_OFFSET_FROM_Y0 :: i32(230)
SETUP_ROW_SPACING :: i32(52)

setup_fields :: proc(mode: game.GameMode) -> []SetupField {
	return mode == .Campaign ? SETUP_CAMPAIGN[:] : SETUP_LOCAL[:]
}

cycle_setup_field :: proc(app: ^App, f: SetupField, right: bool) {
	#partial switch f {
	case .Scoring:   app.scoring = game.ScoringSystem((int(app.scoring) + 1) % 2)
	case .TimeLimit: cycle_time_limit(app, right)
	case .Next:      app.next_disabled = !app.next_disabled
	case .Down:      app.down_mode = DownMode((int(app.down_mode) + 1) % 2)
	case .Ghost:     app.ghost_disabled = !app.ghost_disabled
	case .Controls:  app.solo_controls = SoloControls((int(app.solo_controls) + 1) % 4)
	}
	app.config_dirty = true
}

update_setup :: proc(app: ^App) {
	fields := setup_fields(app.mode)
	app.setup_sel = menu_navigate(app.setup_sel, len(fields))

	// Mouse: hover selects a row; click starts (START) or cycles the value.
	if h, clicked := mouse_rows_pick(len(fields), SETUP_OFFSET_FROM_Y0, SETUP_ROW_SPACING); h >= 0 {
		app.setup_sel = h
		if clicked {
			if fields[h] == .Start {
				start_local_game(app)
			} else {
				cycle_setup_field(app, fields[h], true)
			}
		}
	}

	field := fields[app.setup_sel]
	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.SPACE) {
		cycle_setup_field(app, field, rl.IsKeyPressed(.RIGHT))
	}
	if rl.IsKeyPressed(.ENTER) && field == .Start {
		start_local_game(app)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .MainMenu
	}
}

setup_field_label :: proc(app: ^App, f: SetupField) -> string {
	switch f {
	case .Scoring:   return fmt.tprintf("Scoring:     < %s >", scoring_name(app.scoring))
	case .TimeLimit: return fmt.tprintf("Time Limit:  < %s >", time_limit_name(app.time_limit))
	case .Next:      return fmt.tprintf("Next Piece:  < %s >", next_name(app.next_disabled))
	case .Down:      return fmt.tprintf("Down Key:    < %s >", down_mode_name(app.down_mode))
	case .Ghost:     return fmt.tprintf("Ghost Piece: < %s >", ghost_name(app.ghost_disabled))
	case .Controls:  return fmt.tprintf("Controls:    < %s >", solo_controls_name(app.solo_controls))
	case .Start:     return "START"
	}
	return ""
}

cycle_time_limit :: proc(app: ^App, right: bool) {
	n := len(game.TimeLimit)
	v := int(app.time_limit)
	v = right ? (v + 1) % n : (v - 1 + n) % n
	app.time_limit = game.TimeLimit(v)
}

init_local_session :: proc(app: ^App) {
	app.seed = make_seed()
	game.session_init(&app.session, app.mode, app.scoring, app.time_limit, app.seed)
	app.session.next_disabled = app.next_disabled
	app.session.ghost_disabled = app.ghost_disabled
	app.new_high_score = false
	reset_audio_tracking(app)
}

start_local_game :: proc(app: ^App) {
	init_local_session(app)
	app.screen = .Playing
}

// ------------------------------------------------------- head-to-head menus ---

// Top head-to-head menu: direct LAN vs online (server matchmaking).
update_net_menu :: proc(app: ^App) {
	app.netmenu_sel = menu_navigate(app.netmenu_sel, 3) // Direct / Online / Back

	activate := rl.IsKeyPressed(.ENTER)
	if h, clicked := mouse_menu_pick(3); h >= 0 {
		app.netmenu_sel = h
		if clicked do activate = true
	}
	if activate {
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

	activate := rl.IsKeyPressed(.ENTER)
	if h, clicked := mouse_menu_pick(3); h >= 0 {
		app.lan_sel = h
		if clicked do activate = true
	}
	if activate {
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
	ip := netplay.host_lan_ip()
	if ip != "" {
		app.lobby_status = fmt.aprintf("Have the other player join:  %s:%d", ip, netplay.DEFAULT_PORT)
	} else {
		app.lobby_status = fmt.aprintf("Hosting on port %d - waiting for player...", netplay.DEFAULT_PORT)
	}
	app.screen = .Lobby
}

update_net_join :: proc(app: ^App) {
	update_address_field(app.addr_buf[:], &app.addr_len, app.lan_history)
	if rl.IsKeyPressed(.ENTER) && app.addr_len > 0 {
		start_join(app)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .LanMenu
	}
}

start_join :: proc(app: ^App) {
	host, port := parse_host_port(string(app.addr_buf[:app.addr_len]))
	start_connect(app, host, port, false, .LanJoin)
}

// --- Online (matchmaking server) ---

update_server_setup :: proc(app: ^App) {
	update_address_field(app.server_addr_buf[:], &app.server_addr_len, app.srv_history)
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

	activate := rl.IsKeyPressed(.ENTER)
	if h, clicked := mouse_menu_pick(4); h >= 0 {
		app.server_sel = h
		if clicked do activate = true
	}
	if activate {
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
OPTIONS_OFFSET_FROM_Y0 :: i32(280)
OPTIONS_ROW_SPACING :: i32(56)

cycle_option_field :: proc(app: ^App, i: int) {
	switch i {
	case 0: app.down_mode = DownMode((int(app.down_mode) + 1) % 2)
	case 1: app.ghost_disabled = !app.ghost_disabled
	case 2: app.next_disabled = !app.next_disabled
	}
	app.config_dirty = true
}

update_options :: proc(app: ^App) {
	app.options_sel = menu_navigate(app.options_sel, 3) // Down / Ghost / Next

	if h, clicked := mouse_rows_pick(3, OPTIONS_OFFSET_FROM_Y0, OPTIONS_ROW_SPACING); h >= 0 {
		app.options_sel = h
		if clicked do cycle_option_field(app, h)
	}
	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.SPACE) {
		cycle_option_field(app, app.options_sel)
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.ESCAPE) {
		app.screen = .ServerMenu
	}
}

CREATE_OFFSET_FROM_Y0 :: i32(240)
CREATE_ROW_SPACING :: i32(60)

update_create_game :: proc(app: ^App) {
	app.create_field = menu_navigate(app.create_field, 4) // name / password / public / CREATE

	// Mouse: hover selects a field; click toggles public, submits CREATE, or just
	// focuses a text field for typing.
	if h, clicked := mouse_rows_pick(4, CREATE_OFFSET_FROM_Y0, CREATE_ROW_SPACING); h >= 0 {
		app.create_field = h
		if clicked {
			switch h {
			case 2: app.create_public = !app.create_public; app.config_dirty = true
			case 3: if app.name_len > 0 do submit_create(app)
			}
		}
	}

	switch app.create_field {
	case 0: edit_text(app.name_buf[:], &app.name_len)
	case 1: edit_text(app.pass_buf[:], &app.pass_len)
	case 2:
		if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.SPACE) {
			app.create_public = !app.create_public
			app.config_dirty = true
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
	host, port := parse_host_port(string(app.server_addr_buf[:app.server_addr_len]))
	start_connect(app, host, port, true, .Create)
}

start_browse :: proc(app: ^App) {
	app.browse_count = 0
	app.browse_sel = 0
	host, port := parse_host_port(string(app.server_addr_buf[:app.server_addr_len]))
	start_connect(app, host, port, true, .Browse)
}

BROWSE_OFFSET_FROM_Y0 :: i32(200)
BROWSE_ROW_SPACING :: i32(44)

join_browse :: proc(app: ^App, idx: int) {
	g := app.browse[idx]
	set_buf(app.name_buf[:], &app.name_len, netplay.buf_to_name(g.name[:]))
	if g.has_password != 0 {
		app.pass_len = 0
		app.screen = .JoinPassword
	} else {
		submit_join(app, "")
	}
}

update_browse_games :: proc(app: ^App) {
	if app.net != nil {
		handle_net_events(app, netplay.poll(app.net))
	}
	// handle_net_events may have transitioned us (match/error); stop if so.
	if app.screen != .BrowseGames do return

	if app.browse_count > 0 {
		app.browse_sel = menu_navigate(app.browse_sel, app.browse_count)
		if h, clicked := mouse_rows_pick(app.browse_count, BROWSE_OFFSET_FROM_Y0, BROWSE_ROW_SPACING); h >= 0 {
			app.browse_sel = h
			if clicked do join_browse(app, h)
		}
	}
	if rl.IsKeyPressed(.R) && app.net != nil {
		netplay.send_list(app.net)
	}
	if rl.IsKeyPressed(.ENTER) && app.browse_count > 0 {
		join_browse(app, app.browse_sel)
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
// What to do once an async connect succeeds.
DialAction :: enum {
	Create,  // online: create a game
	Browse,  // online: request the game list
	LanJoin, // direct LAN: just wait for the host to start
}

// Begin connecting in the background and show the lobby with a status. The UI
// stays responsive while dialing; the result is handled by poll_connect.
start_connect :: proc(app: ^App, host: string, port: int, lobby: bool, action: DialAction) {
	if app.dial != nil do return // a connect is already in flight
	app.dial = netplay.dial_start(host, port, lobby)
	app.dial_cancelled = false
	app.dial_action = action
	app.lobby_status = fmt.aprintf("Connecting to %s:%d ...", host, port)
	app.screen = .Lobby
}

// Poll an in-flight async connect; called every frame from the main loop.
poll_connect :: proc(app: ^App) {
	if app.dial == nil || !netplay.dial_done(app.dial) do return
	n := netplay.dial_take(app.dial)
	app.dial = nil

	if app.dial_cancelled {
		if n != nil do netplay.shutdown(n) // user backed out while dialing
		return
	}
	if n == nil {
		app.lobby_status = "Connection failed"
		return
	}

	app.net = n
	// Remember the address we just reached (separate LAN vs online lists).
	switch app.dial_action {
	case .Create, .Browse:
		history_remember(&app.srv_history, string(app.server_addr_buf[:app.server_addr_len]))
	case .LanJoin:
		history_remember(&app.lan_history, string(app.addr_buf[:app.addr_len]))
	}
	config_save(app)

	switch app.dial_action {
	case .Create:
		netplay.send_create(n,
			string(app.name_buf[:app.name_len]),
			string(app.pass_buf[:app.pass_len]),
			app.create_public)
		app.lobby_status = "Creating game - waiting for opponent..."
	case .Browse:
		netplay.send_list(n)
		app.screen = .BrowseGames
	case .LanJoin:
		app.is_host = false
		app.lobby_status = "Connected - waiting for host..."
	}
}

// Split "host" or "host:port" into a host and port (default 7777). Lets players
// reach a server on a non-default port, e.g. a cloud host's mapped port.
parse_host_port :: proc(s: string) -> (host: string, port: int) {
	host, port = s, netplay.DEFAULT_PORT
	if i := strings.last_index_byte(s, ':'); i >= 0 {
		host = s[:i]
		if p, ok := strconv.parse_int(s[i + 1:]); ok {
			port = p
		}
	}
	return
}

// -------------------------------------------------------------------- lobby ---

update_lobby :: proc(app: ^App) {
	if rl.IsKeyPressed(.ESCAPE) {
		if app.dial != nil {
			// Still dialing: mark cancelled; poll_connect cleans up the
			// background connect when it eventually finishes.
			app.dial_cancelled = true
		} else {
			leave_game(app)
		}
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
	reset_audio_tracking(app)
	app.screen = .Playing
}

// ------------------------------------------------------------------ playing ---

update_playing :: proc(app: ^App, dt: f32) {
	s := &app.session

	// Game over: Enter or Esc returns to the menu.
	if s.state == .GameOver {
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.ESCAPE) {
			leave_game(app)
		}
		return
	}

	// Paused: the pause menu has focus (no gameplay).
	if s.paused {
		update_pause_menu(app)
		return
	}

	// Esc or P opens the pause menu.
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.P) {
		s.paused = true
		app.paused_sel = 0
		return
	}

	// Reaching here implies state == .Playing and !paused (the guards above
	// early-return otherwise), so gameplay input always applies.
	if app.mode == .HeadToHead {
		update_head_to_head(app, dt)
		audio_post(app)
		return
	}

	// Local modes. Single player uses the chosen solo scheme; two-player modes
	// put the LEFT player on AWSD and the RIGHT player on arrows+JIKL.
	intents: [2]game.PlayerIntent
	if app.mode == .Campaign {
		intents[0] = gather_solo(app.solo_controls, app.down_mode)
	} else {
		intents[0] = gather_awsd(app.down_mode)  // left side
		intents[1] = gather_right(app.down_mode) // right side
	}
	if app.mouse_enabled do apply_mouse_gameplay(&intents[0], app.down_mode) // mouse controls player 0 (toggle with C)
	sfx_for_intent(intents[0])
	if s.num_players > 1 do sfx_for_intent(intents[1])
	game.session_update(s, dt, intents)
	audio_post(app)
}

// Overlay mouse control onto player 0's intent: horizontal mouse movement snaps
// the piece to the column under the cursor, right-click rotates, and the left
// button behaves exactly like the Down key (per `down_mode`): a press in
// Immediate mode hard-drops; holding in Fast-drop mode soft-drops. Keyboard
// still works when the mouse is idle. Down state is OR'd in so it never clears
// the keyboard's.
apply_mouse_gameplay :: proc(intent: ^game.PlayerIntent, down_mode: DownMode) {
	pit := render.player0_pit
	if pit.valid && abs(rl.GetMouseDelta().x) > 0 {
		col := int((rl.GetMousePosition().x - pit.ox) / pit.cell)
		intent.use_target = true
		intent.target_x = col - 1 // roughly centre the 4-wide piece box
	}
	if rl.IsMouseButtonPressed(.RIGHT) do intent.rotate_cw = true

	switch down_mode {
	case .FastDrop:
		if rl.IsMouseButtonDown(.LEFT) do intent.soft_drop = true
	case .Immediate:
		if rl.IsMouseButtonPressed(.LEFT) do intent.hard_drop = true
	}
}

// Pause menu: Continue or Exit to Menu. Esc resumes.
PauseOption :: enum {
	Continue,
	Restart,
	ExitToMenu,
}

// Restart only makes sense for local games; a networked match can't be restarted
// unilaterally.
PAUSE_LOCAL := [?]PauseOption{.Continue, .Restart, .ExitToMenu}
PAUSE_NET   := [?]PauseOption{.Continue, .ExitToMenu}

pause_options :: proc(mode: game.GameMode) -> []PauseOption {
	return mode == .HeadToHead ? PAUSE_NET[:] : PAUSE_LOCAL[:]
}

pause_label :: proc(o: PauseOption) -> string {
	switch o {
	case .Continue:   return "Continue"
	case .Restart:    return "Restart"
	case .ExitToMenu: return "Exit to Menu"
	}
	return ""
}

update_pause_menu :: proc(app: ^App) {
	opts := pause_options(app.mode)
	app.paused_sel = menu_navigate(app.paused_sel, len(opts))
	mouse_select_pause(app, len(opts))

	if rl.IsKeyPressed(.ESCAPE) {
		app.session.paused = false // Esc = continue
		return
	}
	if rl.IsKeyPressed(.ENTER) {
		pause_select(app, opts[app.paused_sel])
	}
}

mouse_select_pause :: proc(app: ^App, count: int) {
	sh := rl.GetScreenHeight()
	for i in 0 ..< count {
		if row_hovered(i, render.PAUSE_OPTION_OFFSET_FROM_Y0(sh), render.PAUSE_OPTION_ROW_SPACING) {
			app.paused_sel = i
			if rl.IsMouseButtonPressed(.LEFT) {
				pause_select(app, pause_options(app.mode)[i])
			}
			return
		}
	}
}

pause_select :: proc(app: ^App, o: PauseOption) {
	switch o {
	case .Continue:   app.session.paused = false
	case .Restart:    restart_game(app)
	case .ExitToMenu: leave_game(app)
	}
}

// Re-initialise the current local session with a fresh seed and resume.
restart_game :: proc(app: ^App) {
	init_local_session(app)
	app.session.paused = false
	app.screen = .Playing
}

// Play input-driven sound effects (rotate / hard drop).
sfx_for_intent :: proc(i: game.PlayerIntent) {
	if i.rotate_cw || i.rotate_ccw do audio.play(.Rotate)
	if i.hard_drop do audio.play(.Drop)
}

// Update music tempo from the level and fire state-driven SFX (line clears,
// level up, game over) by diffing against the previous frame.
audio_post :: proc(app: ^App) {
	s := &app.session
	lines, level := local_progress(app)
	audio.set_level(level)

	if level > app.prev_level do audio.play(.LevelUp)
	if lines > app.prev_lines {
		audio.play(lines - app.prev_lines >= 4 ? .Tetris : .LineClear)
	}
	if s.state == .GameOver && !app.prev_game_over {
		audio.play(.GameOver)
		app.prev_game_over = true
		finalize_campaign_score(app)
	}
	app.prev_lines = lines
	app.prev_level = level
}

// On a Campaign game over, record a new high score to disk if it was beaten.
finalize_campaign_score :: proc(app: ^App) {
	if app.mode != .Campaign do return
	score := app.session.players[0].score
	if score > app.high_score {
		app.high_score = score
		app.new_high_score = true
		save_highscore(score)
	}
}

// Lines cleared and top level for the locally-controlled player(s). In
// head-to-head only our own pit (player 0) counts; the opponent is a mirror.
local_progress :: proc(app: ^App) -> (lines: int, level: int) {
	s := &app.session
	level = 1
	if app.mode == .HeadToHead {
		return s.players[0].lines, max(1, s.players[0].level)
	}
	for i in 0 ..< s.num_players {
		if s.players[i].active {
			lines += s.players[i].lines
			level = max(level, s.players[i].level)
		}
	}
	return
}

reset_audio_tracking :: proc(app: ^App) {
	app.prev_lines, app.prev_level = local_progress(app)
	app.prev_game_over = false
}

update_head_to_head :: proc(app: ^App, dt: f32) {
	s := &app.session
	n := app.net

	intents: [2]game.PlayerIntent
	intents[0] = gather_solo(app.solo_controls, app.down_mode)
	if app.mouse_enabled do apply_mouse_gameplay(&intents[0], app.down_mode)
	sfx_for_intent(intents[0])
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

// Global hotkeys (audio mute + gameplay mouse toggle). Suppressed on text-entry
// screens so typed letters (e.g. a server address or game name) don't trigger
// them. Any toggle marks the config dirty so it persists immediately.
handle_hotkeys :: proc(app: ^App) {
	#partial switch app.screen {
	case .NetJoin, .ServerSetup, .CreateGame, .JoinPassword:
		return
	}
	if rl.IsKeyPressed(.M) {
		audio.set_music_enabled(!audio.music_enabled())
		app.config_dirty = true
	}
	if rl.IsKeyPressed(.N) {
		audio.set_sfx_enabled(!audio.sfx_enabled())
		app.config_dirty = true
	}
	if app.screen == .Playing && rl.IsKeyPressed(.C) {
		app.mouse_enabled = !app.mouse_enabled
		app.config_dirty = true
	}
}

// A small persistent reminder of the hotkeys (mouse only shown while playing).
draw_hotkey_hint :: proc(app: ^App, sw, sh: i32) {
	on :: proc(b: bool) -> string { return b ? "on" : "off" }
	txt: cstring
	if app.screen == .Playing {
		txt = fmt.ctprintf("M music: %s   N sound: %s   C mouse: %s",
			on(audio.music_enabled()), on(audio.sfx_enabled()), on(app.mouse_enabled))
	} else {
		txt = fmt.ctprintf("M music: %s   N sound: %s", on(audio.music_enabled()), on(audio.sfx_enabled()))
	}
	w := rl.MeasureText(txt, 16)
	x := sw - w - 12
	y := sh - 24
	// Dark backing so the hint stays legible over a pit/HUD (e.g. dual-pit).
	rl.DrawRectangle(x - 6, y - 4, w + 12, 24, {0, 0, 0, 150})
	rl.DrawText(txt, x, y, 16, {210, 210, 225, 255})
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
		items: [len(game.GameMode) + 2]string
		for m in game.GameMode {
			items[int(m)] = MODE_NAMES[m]
		}
		items[len(game.GameMode)] = "About"
		items[len(game.GameMode) + 1] = "Quit"
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
		draw_address_field(app, sw, sh, "MATCHMAKING SERVER", "Enter server address (host or host:port):",
			app.server_addr_buf[:], app.server_addr_len, app.srv_history,
			"Tab/-> complete   Enter continue   Esc back")

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
		render.draw_session(&app.session, sw, sh, p1, p2, app.high_score, app.new_high_score)
		if app.session.paused {
			opts := pause_options(app.mode)
			labels := make([]string, len(opts), context.temp_allocator)
			for o, i in opts do labels[i] = pause_label(o)
			render.draw_pause_menu(sw, sh, labels, app.paused_sel)
		}

	case .About:
		draw_about(app, sw, sh)

	case .License:
		draw_license(app, sw, sh)
	}
}

// ------------------------------------------------------------------ about ---

ABOUT_BUTTONS := []string{"License", "Close"}

update_about :: proc(app: ^App) {
	if rl.IsKeyPressed(.ESCAPE) {
		app.screen = .MainMenu
		return
	}
	app.about_sel = menu_navigate(app.about_sel, len(ABOUT_BUTTONS))

	activate := rl.IsKeyPressed(.ENTER)
	y0, dy := about_buttons_geom()
	if h, clicked := mouse_rows_pick(len(ABOUT_BUTTONS), y0, dy); h >= 0 {
		app.about_sel = h
		if clicked do activate = true
	}
	if activate {
		switch app.about_sel {
		case 0: app.screen = .License
		case 1: app.screen = .MainMenu
		}
	}
}

update_license :: proc(app: ^App) {
	if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.ENTER) {
		app.screen = .About
	}
}

about_buttons_geom :: proc() -> (y0, dy: i32) {
	return i32(rl.GetScreenHeight()) - 140, 50
}

draw_about :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {20, 22, 48, 255}, {6, 6, 16, 255})
	render.text_center("ABOUT", sw / 2, 90, 48, render.COLOR_HIGHLIGHT)

	lines := []string{
		"Author: Charl Marais",
		fmt.tprintf("Version: %s", VERSION),
		fmt.tprintf("Date: %s", VERSION_DATE),
		fmt.tprintf("Description: %s", DESCRIPTION),
		"",
		"This game was created using Claude Code.",
	}
	y := i32(190)
	for line in lines {
		render.text_center(line, sw / 2, y, 24, render.COLOR_TEXT)
		y += 40
	}

	y0, dy := about_buttons_geom()
	draw_option_rows(ABOUT_BUTTONS, app.about_sel, y0, dy, sw)
	render.text_center("Up/Down or mouse   Enter/click   Esc back", sw / 2, sh - 40, 18, render.COLOR_TEXT_DIM)
}

draw_license :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {20, 22, 48, 255}, {6, 6, 16, 255})
	render.text_center("LICENSE", sw / 2, 80, 48, render.COLOR_HIGHLIGHT)

	y := i32(170)
	for line in strings.split_lines(LICENSE_SUMMARY, context.temp_allocator) {
		render.text_center(line, sw / 2, y, 20, render.COLOR_TEXT)
		y += 30
	}
	render.text_center("Esc back   Full text in the LICENSE file", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

draw_setup :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {20, 22, 48, 255}, {6, 6, 16, 255})
	render.text_center("TETRIS CLASSIC", sw / 2, 70, 56, render.COLOR_HIGHLIGHT)
	render.text_center(MODE_NAMES[app.mode], sw / 2, 150, 30, render.COLOR_TEXT)

	fields := setup_fields(app.mode)
	labels := make([]string, len(fields), context.temp_allocator)
	for f, i in fields do labels[i] = setup_field_label(app, f)
	draw_option_rows(labels, app.setup_sel, SETUP_OFFSET_FROM_Y0, SETUP_ROW_SPACING, sw)

	if app.mode != .Campaign {
		render.text_center("Left: A W S D + Shift     Right: Arrows / J I K L", sw / 2, SETUP_OFFSET_FROM_Y0 + i32(len(fields)) * SETUP_ROW_SPACING + 16, 20, render.COLOR_TEXT_DIM)
	}
	render.text_center("Up/Down or mouse   Left/Right or click changes   Enter/click start   Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

draw_net_join :: proc(app: ^App, sw, sh: i32) {
	draw_address_field(app, sw, sh, "JOIN GAME",
		fmt.tprintf("Enter host address (host or host:port, default port %d):", netplay.DEFAULT_PORT),
		app.addr_buf[:], app.addr_len, app.lan_history,
		"Tab/-> complete   Enter connect   Esc back")
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
	render.text_field(shown, bx + 16, sh / 2 - 14, box_w - 32, 28, render.COLOR_TEXT)

	render.text_center(hint, sw / 2, sh - 60, 20, render.COLOR_TEXT_DIM)
}

// --- address entry with last-connected autocomplete (LAN + online) ---

// Case-insensitive prefix test, no allocation.
has_prefix_fold :: proc(s, prefix: string) -> bool {
	if len(prefix) > len(s) do return false
	return strings.equal_fold(s[:len(prefix)], prefix)
}

// History entries that start with `prefix` (order preserved). Empty prefix
// returns the whole history. Result lives in the temp allocator.
filter_history :: proc(history: [dynamic]string, prefix: string) -> [dynamic]string {
	out := make([dynamic]string, 0, len(history), context.temp_allocator)
	for a in history {
		if prefix == "" || has_prefix_fold(a, prefix) do append(&out, a)
	}
	return out
}

// Dropdown row geometry (below the entry box), shared by update + draw.
addr_dropdown_geom :: proc(sh: i32) -> (y0, dy: i32) {
	return sh / 2 + 44, 30
}

// Typing + autocomplete behaviour for an address field. Tab / Right completes
// to the top match; clicking a dropdown row selects it. Enter stays with the
// caller (it means different things per screen).
update_address_field :: proc(buf: []u8, length: ^int, history: [dynamic]string) {
	edit_text(buf, length)
	matches := filter_history(history, string(buf[:length^]))
	if len(matches) > 0 && (rl.IsKeyPressed(.TAB) || rl.IsKeyPressed(.RIGHT)) {
		set_buf(buf, length, matches[0])
		return
	}
	y0, dy := addr_dropdown_geom(i32(rl.GetScreenHeight()))
	if h, clicked := mouse_rows_pick(len(matches), y0, dy); h >= 0 && clicked {
		set_buf(buf, length, matches[h])
	}
}

// Entry box with inline ghost-text completion and a dropdown of matches.
draw_address_field :: proc(app: ^App, sw, sh: i32, title, prompt: string, buf: []u8, length: int, history: [dynamic]string, hint: string) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {16, 32, 56, 255}, {6, 6, 16, 255})
	render.text_center(title, sw / 2, 120, 48, render.COLOR_HIGHLIGHT)
	render.text_center(prompt, sw / 2, 230, 24, render.COLOR_TEXT)

	value := string(buf[:length])
	shown := length > 0 ? value : "_"
	box_w := i32(500)
	bx := sw / 2 - box_w / 2
	by := sh / 2 - 30
	rl.DrawRectangleRec({f32(bx), f32(by), f32(box_w), 60}, {0, 0, 0, 140})
	rl.DrawRectangleLinesEx({f32(bx), f32(by), f32(box_w), 60}, 2, render.COLOR_BORDER)
	render.text_field(shown, bx + 16, by + 16, box_w - 32, 28, render.COLOR_TEXT)

	matches := filter_history(history, value)

	// Inline ghost-text: the remainder of the top match after what was typed.
	if length > 0 && len(matches) > 0 && len(matches[0]) > length {
		tx := bx + 16 + rl.MeasureText(fmt.ctprintf("%s", value), 28)
		rl.DrawText(fmt.ctprintf("%s", matches[0][length:]), tx, by + 16, 28, render.COLOR_TEXT_DIM)
	}

	// Dropdown of matches (full history when the field is empty).
	y0, dy := addr_dropdown_geom(sh)
	for m, i in matches {
		col := row_hovered(i, y0, dy) ? render.COLOR_HIGHLIGHT : render.COLOR_TEXT_DIM
		render.text_center(strings.clone(m, context.temp_allocator), sw / 2, y0 + i32(i) * dy, 22, col)
	}

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
	draw_option_rows(rows, app.options_sel, OPTIONS_OFFSET_FROM_Y0, OPTIONS_ROW_SPACING, sw)
	render.text_center("Up/Down or mouse   Left/Right or click changes   Enter/Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
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
	draw_option_rows(rows, app.create_field, CREATE_OFFSET_FROM_Y0, CREATE_ROW_SPACING, sw)
	render.text_center("Up/Down or click field   type to edit   click CREATE   Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
}

draw_browse_games :: proc(app: ^App, sw, sh: i32) {
	rl.DrawRectangleGradientV(0, 0, sw, sh, {16, 32, 56, 255}, {6, 6, 16, 255})
	render.text_center("BROWSE GAMES", sw / 2, 80, 48, render.COLOR_HIGHLIGHT)

	if app.browse_count == 0 {
		render.text_center("No open games. Press R to refresh.", sw / 2, sh / 2, 26, render.COLOR_TEXT_DIM)
	} else {
		for i in 0 ..< app.browse_count {
			g := app.browse[i]
			name := netplay.buf_to_name(g.name[:])
			lock := g.has_password != 0 ? " [locked]" : ""
			line := fmt.tprintf("%s%s", name, lock)
			color := i == app.browse_sel ? render.COLOR_HIGHLIGHT : render.COLOR_TEXT
			prefix := i == app.browse_sel ? "> " : "  "
			render.text_center(strings.clone(fmt.tprintf("%s%s", prefix, line), context.temp_allocator),
				sw / 2, BROWSE_OFFSET_FROM_Y0 + i32(i) * BROWSE_ROW_SPACING, 28, color)
		}
	}
	render.text_center("Up/Down or mouse   Enter/click join   R refresh   Esc back", sw / 2, sh - 50, 18, render.COLOR_TEXT_DIM)
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

solo_controls_name :: proc(c: SoloControls) -> string {
	switch c {
	case .All:    return "All (Arrows/IJKL/WASD)"
	case .Arrows: return "Arrow keys"
	case .JIKL:   return "I J K L"
	case .WASD:   return "W A S D"
	}
	return "?"
}
