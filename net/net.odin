package netplay

import "core:net"
import "core:mem"

// TCP transport for head-to-head play: a host listens, a client dials in. Both
// sockets are non-blocking and serviced once per frame via `poll`. Decoded
// messages are surfaced as Events for the app layer to apply.

DEFAULT_PORT :: 7777

Connected    :: struct {}
Disconnected :: struct {}
GameOverMsg  :: struct {}

// Lobby-phase events (server-based online play). Distinct wrappers so the app
// can tell create vs join results apart and react to a successful match.
CreateResult :: struct {
	ok:     bool,
	reason: ResultReason,
}
JoinResult :: struct {
	ok:     bool,
	reason: ResultReason,
}
Matched :: struct {
	is_host: bool,
}

// Tagged union of things that can happen on the wire in a frame.
Event :: union {
	Connected,
	Disconnected,
	StartPayload,
	SnapshotPayload,
	GarbagePayload,
	GameOverMsg,
	// lobby phase
	ListingPayload,
	CreateResult,
	JoinResult,
	Matched,
}

// A connection is either talking the gameplay protocol (direct LAN, or after a
// server match) or the lobby control protocol (server, pre-match).
Phase :: enum {
	Game = 0, // direct host/join start here
	Lobby,    // server connection before a match
}

Net :: struct {
	is_host:   bool,
	listener:  net.TCP_Socket, // host only
	peer:      net.TCP_Socket, // the connection to the other player (or server)
	listening: bool,
	connected: bool,
	phase:     Phase,

	rx:     [dynamic]u8, // accumulated received bytes awaiting framing
	events: [dynamic]Event,
}

// Start hosting on `port`. Returns a Net whose `connected` flips true once a
// client arrives (observed via poll -> Connected event).
host :: proc(port: int) -> (^Net, bool) {
	ep := net.Endpoint{address = net.IP4_Any, port = port}
	l, err := net.listen_tcp(ep)
	if err != nil {
		return nil, false
	}
	net.set_blocking(l, false)
	n := new(Net)
	n.is_host = true
	n.listener = l
	n.listening = true
	return n, true
}

// Connect to a host at "address" or "address:port". Blocks briefly during the
// TCP handshake, then switches to non-blocking.
join :: proc(address: string, port: int) -> (^Net, bool) {
	sock, err := net.dial_tcp_from_hostname_with_port_override(address, port)
	if err != nil {
		return nil, false
	}
	net.set_blocking(sock, false)
	n := new(Net)
	n.is_host = false
	n.peer = sock
	n.connected = true
	append(&n.events, Connected{})
	return n, true
}

// Connect to a matchmaking server. Starts in the lobby phase; the caller then
// sends a Create/Join/List control message. A successful Join/Create that gets
// paired yields a Matched event, after which the connection transparently
// becomes a relayed gameplay channel.
connect_server :: proc(address: string, port: int) -> (^Net, bool) {
	sock, err := net.dial_tcp_from_hostname_with_port_override(address, port)
	if err != nil {
		return nil, false
	}
	net.set_blocking(sock, false)
	n := new(Net)
	n.is_host = false
	n.peer = sock
	n.connected = true
	n.phase = .Lobby
	return n, true
}

shutdown :: proc(n: ^Net) {
	if n == nil do return
	if n.connected do net.close(n.peer)
	if n.listening do net.close(n.listener)
	delete(n.rx)
	delete(n.events)
	free(n)
}

// Send a typed message. `payload` may be nil for GameOver.
send_msg :: proc(n: ^Net, t: MsgType, payload: []u8) {
	if !n.connected do return
	buf: [4096]u8
	buf[0] = u8(t)
	size := len(payload)
	if size > 0 {
		mem.copy(&buf[1], raw_data(payload), size)
	}
	send_all(n, buf[:1 + size])
}

send_all :: proc(n: ^Net, data: []byte) {
	sent := 0
	for sent < len(data) {
		written, err := net.send_tcp(n.peer, data[sent:])
		if err != nil {
			// Treat any send error (incl. would-block) as a brief stall; for our
			// low data rate the kernel buffer rarely fills. Drop on hard error.
			if written <= 0 {
				if is_would_block(err) do continue
				n.connected = false
				append(&n.events, Disconnected{})
				return
			}
		}
		sent += written
	}
}

// Convenience encoders.
send_start :: proc(n: ^Net, p: StartPayload) {
	pp := p
	send_msg(n, .Start, mem.ptr_to_bytes(&pp))
}
send_snapshot :: proc(n: ^Net, p: SnapshotPayload) {
	pp := p
	send_msg(n, .Snapshot, mem.ptr_to_bytes(&pp))
}
send_garbage :: proc(n: ^Net, count: int) {
	pp := GarbagePayload{count = i32(count)}
	send_msg(n, .Garbage, mem.ptr_to_bytes(&pp))
}
send_game_over :: proc(n: ^Net) {
	send_msg(n, .GameOver, nil)
}

// --- Lobby control senders (client -> server) ---

send_ctrl :: proc(n: ^Net, t: CtrlType, payload: []u8) {
	if !n.connected do return
	buf: [4096]u8
	frame := encode_ctrl(buf[:], t, payload)
	send_all(n, frame)
}

send_create :: proc(n: ^Net, name, password: string, public: bool) {
	p := CreatePayload{
		name     = name_to_buf(name),
		password = name_to_buf(password),
		public   = public ? 1 : 0,
	}
	send_ctrl(n, .Create, mem.ptr_to_bytes(&p))
}

send_join :: proc(n: ^Net, name, password: string) {
	p := JoinPayload{
		name     = name_to_buf(name),
		password = name_to_buf(password),
	}
	send_ctrl(n, .Join, mem.ptr_to_bytes(&p))
}

send_list :: proc(n: ^Net) {
	send_ctrl(n, .List, nil)
}

// Service the socket: accept a pending client (host), read available bytes, and
// decode complete frames into events. Returns the events seen this call; the
// internal queue is cleared each call.
poll :: proc(n: ^Net) -> []Event {
	clear(&n.events)

	// Host: accept the first incoming connection.
	if n.is_host && n.listening && !n.connected {
		client, _, aerr := net.accept_tcp(n.listener)
		if aerr == nil {
			net.set_blocking(client, false)
			n.peer = client
			n.connected = true
			append(&n.events, Connected{})
		}
	}

	if n.connected {
		tmp: [8192]u8
		for {
			got, err := net.recv_tcp(n.peer, tmp[:])
			if err != nil {
				if is_would_block(err) do break
				n.connected = false
				append(&n.events, Disconnected{})
				break
			}
			if got == 0 {
				// Peer closed the connection.
				n.connected = false
				append(&n.events, Disconnected{})
				break
			}
			append(&n.rx, ..tmp[:got])
			if got < len(tmp) do break // drained the socket for now
		}
		if n.phase == .Lobby {
			parse_control_frames(n)
		} else {
			parse_frames(n)
		}
	}

	return n.events[:]
}

// Parse length-prefixed control frames (lobby phase). On a Matched frame the
// connection flips to the gameplay phase and parsing stops immediately, leaving
// any trailing (already-gameplay) bytes in rx for parse_frames next poll.
parse_control_frames :: proc(n: ^Net) {
	consumed := 0
	for {
		t, body, total, ok := read_ctrl_frame(n.rx[consumed:])
		if !ok do break

		switch t {
		case .Listing:
			p: ListingPayload
			mem.copy(&p, raw_data(body), min(len(body), size_of(ListingPayload)))
			append(&n.events, p)
		case .CreateResult:
			r: ResultPayload
			mem.copy(&r, raw_data(body), min(len(body), size_of(ResultPayload)))
			append(&n.events, CreateResult{ok = r.ok != 0, reason = ResultReason(r.reason)})
		case .JoinResult:
			r: ResultPayload
			mem.copy(&r, raw_data(body), min(len(body), size_of(ResultPayload)))
			append(&n.events, JoinResult{ok = r.ok != 0, reason = ResultReason(r.reason)})
		case .Matched:
			m: MatchedPayload
			mem.copy(&m, raw_data(body), min(len(body), size_of(MatchedPayload)))
			n.is_host = m.is_host != 0
			n.phase = .Game
			append(&n.events, Matched{is_host = n.is_host})
			consumed += total
			compact_rx(n, consumed)
			return // remaining bytes are gameplay; handled by parse_frames later
		case .Create, .Join, .List:
			// Server-only message types; ignore if seen on the client.
		}
		consumed += total
	}
	compact_rx(n, consumed)
}

// Drop the first `consumed` bytes from the receive buffer.
compact_rx :: proc(n: ^Net, consumed: int) {
	if consumed <= 0 do return
	remaining := n.rx[consumed:]
	copy(n.rx[:], remaining)
	resize(&n.rx, len(remaining))
}

// Pull all complete frames out of the receive buffer into events.
parse_frames :: proc(n: ^Net) {
	consumed := 0
	for {
		avail := len(n.rx) - consumed
		if avail < 1 do break
		t := MsgType(n.rx[consumed])
		need := payload_size(t)
		if avail - 1 < need do break // wait for the rest of the payload

		body := n.rx[consumed + 1 : consumed + 1 + need]
		switch t {
		case .Start:
			p: StartPayload
			mem.copy(&p, raw_data(body), need)
			append(&n.events, p)
		case .Snapshot:
			p: SnapshotPayload
			mem.copy(&p, raw_data(body), need)
			append(&n.events, p)
		case .Garbage:
			p: GarbagePayload
			mem.copy(&p, raw_data(body), need)
			append(&n.events, p)
		case .GameOver:
			append(&n.events, GameOverMsg{})
		}
		consumed += 1 + need
	}

	if consumed > 0 {
		remaining := n.rx[consumed:]
		copy(n.rx[:], remaining)
		resize(&n.rx, len(remaining))
	}
}

is_would_block :: proc(err: net.Network_Error) -> bool {
	#partial switch e in err {
	case net.TCP_Recv_Error:
		return e == .Would_Block
	case net.TCP_Send_Error:
		return e == .Would_Block
	case net.Accept_Error:
		return e == .Would_Block
	}
	return false
}
