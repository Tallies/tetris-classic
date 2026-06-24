package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import netplay "../net"

// Entry point. Port precedence: $PORT (used by container/PaaS hosts such as
// SnapDeploy) > CLI arg > the client's DEFAULT_PORT. Runs the matchmaking/relay
// loop until killed.

main :: proc() {
	port := netplay.DEFAULT_PORT
	if len(os.args) > 1 {
		if p, ok := strconv.parse_int(os.args[1]); ok {
			port = p
		}
	}
	if env := os.get_env("PORT", context.temp_allocator); env != "" {
		if p, ok := strconv.parse_int(env); ok {
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
