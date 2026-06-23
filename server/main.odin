package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import netplay "../net"

// Entry point: `tetris-server [port]` (defaults to the client's DEFAULT_PORT).
// Runs the matchmaking/relay loop until killed.

main :: proc() {
	port := netplay.DEFAULT_PORT
	if len(os.args) > 1 {
		if p, ok := strconv.parse_int(os.args[1]); ok {
			port = p
		}
	}

	s: Server
	if !server_start(&s, port) {
		os.exit(1)
	}
	fmt.printfln("Tetris Classic server listening on TCP :%d", port)

	for {
		server_tick(&s)
		// Low, steady cadence: ~1 ms keeps relay latency tiny while idling cheaply.
		time.sleep(1 * time.Millisecond)
	}
}
