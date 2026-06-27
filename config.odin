package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "audio"
import "game"

// Local persistence of user settings + recently-connected addresses. Mirrors
// highscore.odin: a flat `key=value` file in a directory that already exists
// (HOME or %APPDATA%). Parsed leniently — unknown or missing keys keep their
// defaults, so older/newer files load without fuss. Enums are stored as ints.

ADDR_HISTORY_MAX :: 5

config_path :: proc() -> string {
	when ODIN_OS == .Windows {
		base := os.get_env("APPDATA", context.temp_allocator)
		if base == "" do base = "."
		return fmt.tprintf("%s\\tetris-classic-config", base)
	} else {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do home = "."
		return fmt.tprintf("%s/.tetris-classic-config", home)
	}
}

config_load :: proc(app: ^App) {
	data, err := os.read_entire_file(config_path(), context.temp_allocator)
	if err != nil do return

	content := string(data)
	for line in strings.split_lines_iterator(&content) {
		key, _, val := strings.partition(line, "=")
		key = strings.trim_space(key)
		val = strings.trim_space(val)
		if key == "" do continue

		ival, _ := strconv.parse_int(val) // 0 on non-numeric; fine for our keys
		switch key {
		case "scoring":    app.scoring = game.ScoringSystem(ival)
		case "time_limit": app.time_limit = game.TimeLimit(ival)
		case "next":       app.next_disabled = ival != 0
		case "ghost":      app.ghost_disabled = ival != 0
		case "down":       app.down_mode = DownMode(ival)
		case "controls":   app.solo_controls = SoloControls(ival)
		case "public":     app.create_public = ival != 0
		case "music":      audio.set_music_enabled(ival != 0)
		case "sfx":        audio.set_sfx_enabled(ival != 0)
		case "mouse":      app.mouse_enabled = ival != 0
		case:
			if strings.has_prefix(key, "lan") && val != "" {
				append(&app.lan_history, strings.clone(val))
			} else if strings.has_prefix(key, "srv") && val != "" {
				append(&app.srv_history, strings.clone(val))
			}
		}
	}
}

config_save :: proc(app: ^App) {
	b := strings.builder_make(context.temp_allocator)
	bi :: proc(v: bool) -> int { return v ? 1 : 0 }

	fmt.sbprintf(&b, "scoring=%d\n", int(app.scoring))
	fmt.sbprintf(&b, "time_limit=%d\n", int(app.time_limit))
	fmt.sbprintf(&b, "next=%d\n", bi(app.next_disabled))
	fmt.sbprintf(&b, "ghost=%d\n", bi(app.ghost_disabled))
	fmt.sbprintf(&b, "down=%d\n", int(app.down_mode))
	fmt.sbprintf(&b, "controls=%d\n", int(app.solo_controls))
	fmt.sbprintf(&b, "public=%d\n", bi(app.create_public))
	fmt.sbprintf(&b, "music=%d\n", bi(audio.music_enabled()))
	fmt.sbprintf(&b, "sfx=%d\n", bi(audio.sfx_enabled()))
	fmt.sbprintf(&b, "mouse=%d\n", bi(app.mouse_enabled))
	for a, i in app.lan_history do fmt.sbprintf(&b, "lan%d=%s\n", i, a)
	for a, i in app.srv_history do fmt.sbprintf(&b, "srv%d=%s\n", i, a)

	_ = os.write_entire_file(config_path(), b.buf[:])
}

// Move `addr` to the front of `history` (dedup, case-insensitive), capping the
// list at ADDR_HISTORY_MAX. Called when a connection succeeds.
history_remember :: proc(history: ^[dynamic]string, addr: string) {
	addr := strings.trim_space(addr)
	if addr == "" do return
	for a, i in history {
		if strings.equal_fold(a, addr) {
			delete(a)
			ordered_remove(history, i)
			break
		}
	}
	inject_at(history, 0, strings.clone(addr))
	for len(history) > ADDR_HISTORY_MAX {
		delete(history[len(history) - 1])
		pop(history)
	}
}
