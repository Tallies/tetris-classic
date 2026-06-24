package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Local persistence of the single-player (Campaign) high score. Stored as a
// plain integer in a per-user file that always lives in a directory that
// already exists (HOME or %APPDATA%), so no directory creation is needed.

highscore_path :: proc() -> string {
	when ODIN_OS == .Windows {
		base := os.get_env("APPDATA", context.temp_allocator)
		if base == "" do base = "."
		return fmt.tprintf("%s\\tetris-classic-highscore", base)
	} else {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do home = "."
		return fmt.tprintf("%s/.tetris-classic-highscore", home)
	}
}

load_highscore :: proc() -> int {
	data, err := os.read_entire_file(highscore_path(), context.temp_allocator)
	if err != nil do return 0
	val, ok := strconv.parse_int(strings.trim_space(string(data)))
	return ok ? val : 0
}

save_highscore :: proc(score: int) {
	text := fmt.tprintf("%d\n", score)
	_ = os.write_entire_file(highscore_path(), transmute([]u8)text)
}
