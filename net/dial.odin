package netplay

import "core:strings"
import "core:sync"
import "core:thread"

// Asynchronous connect. core:net's dial is blocking with no timeout, so doing it
// inline freezes the UI until the OS connect resolves (which can take a long
// time for an unreachable host). Instead we run the dial on a worker thread and
// let the caller poll for completion each frame.

Dial :: struct {
	thread: ^thread.Thread,
	host:   string, // owned copy
	port:   int,
	lobby:  bool,   // true: connect to matchmaking server; false: direct LAN host
	done:   bool,   // written by the worker (atomic), read by the main thread
	result: ^Net,   // the connection on success, nil on failure
}

// Begin connecting in the background. `lobby` selects connect_server (matchmaking
// server, lobby phase) vs join (direct LAN host, game phase).
dial_start :: proc(host: string, port: int, lobby: bool) -> ^Dial {
	d := new(Dial)
	d.host = strings.clone(host)
	d.port = port
	d.lobby = lobby
	d.thread = thread.create_and_start_with_poly_data(d, dial_run)
	return d
}

@(private)
dial_run :: proc(d: ^Dial) {
	n: ^Net
	ok: bool
	if d.lobby {
		n, ok = connect_server(d.host, d.port)
	} else {
		n, ok = join(d.host, d.port)
	}
	if ok {
		d.result = n
	}
	sync.atomic_store(&d.done, true)
}

// True once the worker has finished (success or failure).
dial_done :: proc(d: ^Dial) -> bool {
	return sync.atomic_load(&d.done)
}

// Collect the result and free the dialer. Only call once dial_done is true.
// Returns the connection, or nil on failure.
dial_take :: proc(d: ^Dial) -> ^Net {
	thread.join(d.thread)
	thread.destroy(d.thread)
	n := d.result
	delete(d.host)
	free(d)
	return n
}
