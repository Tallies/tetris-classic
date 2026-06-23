package main

// Tetris Classic matchmaking + relay server.
//
// Clients connect over TCP and exchange length-prefixed control frames (the
// lobby protocol in the netplay package): create a named game, browse open
// games, or join by name (optionally with a password). When two clients are
// paired the server stops interpreting their traffic and simply relays raw
// bytes between them, so the existing peer-to-peer gameplay protocol works
// unchanged through the relay. Works behind any NAT — no port forwarding for
// players; only the server needs its port reachable.
//
// Single-threaded, non-blocking. Lobbies are in-memory and ephemeral.

import "core:fmt"
import "core:mem"
import "core:net"
import netplay "../net"

ClientState :: enum {
	Lobby,   // connected, exchanging control messages
	Waiting, // created a game, waiting for an opponent
	Playing, // matched; traffic is relayed to `partner`
}

Client :: struct {
	socket:  net.TCP_Socket,
	state:   ClientState,
	rx:      [dynamic]u8,
	partner: int, // client slot index, or -1
	lobby:   int, // lobby slot index while Waiting, or -1
	alive:   bool,
}

Lobby :: struct {
	name:        string, // cloned
	password:    string, // cloned ("" = open)
	public:      bool,
	host_client: int,
	alive:       bool,
}

Server :: struct {
	listener: net.TCP_Socket,
	clients:  [dynamic]Client,
	lobbies:  [dynamic]Lobby,
}

server_start :: proc(s: ^Server, port: int) -> bool {
	ep := net.Endpoint{address = net.IP4_Any, port = port}
	l, err := net.listen_tcp(ep)
	if err != nil {
		fmt.eprintfln("listen on :%d failed: %v", port, err)
		return false
	}
	net.set_blocking(l, false)
	s.listener = l
	return true
}

// Free all sockets and buffers. The long-running server never calls this (it
// loops forever), but tests and clean-exit paths do.
server_shutdown :: proc(s: ^Server) {
	for &c in s.clients {
		if c.alive {
			net.close(c.socket)
		}
		delete(c.rx)
	}
	for &l in s.lobbies {
		if l.alive {
			delete(l.name)
			delete(l.password)
		}
	}
	delete(s.clients)
	delete(s.lobbies)
	net.close(s.listener)
}

// One service pass: accept, receive, then dispatch/relay.
server_tick :: proc(s: ^Server) {
	accept_new(s)

	for i in 0 ..< len(s.clients) {
		if s.clients[i].alive {
			recv_into(s, i)
		}
	}

	for i in 0 ..< len(s.clients) {
		if !s.clients[i].alive do continue
		switch s.clients[i].state {
		case .Lobby:
			process_lobby_client(s, i)
		case .Waiting:
			// Nothing expected from a waiting host until matched; ignore.
		case .Playing:
			relay_client(s, i)
		}
	}
}

// Accept all pending connections (non-blocking).
accept_new :: proc(s: ^Server) {
	for {
		sock, _, err := net.accept_tcp(s.listener)
		if err != nil do break // would-block or transient: stop for this tick
		net.set_blocking(sock, false)
		idx := alloc_client(s)
		s.clients[idx] = Client{socket = sock, state = .Lobby, partner = -1, lobby = -1, alive = true}
		fmt.printfln("[+] client %d connected", idx)
	}
}

// Find a free client slot (reusing dead ones to keep indices stable).
alloc_client :: proc(s: ^Server) -> int {
	for &c, i in s.clients {
		if !c.alive {
			c = Client{}
			return i
		}
	}
	append(&s.clients, Client{})
	return len(s.clients) - 1
}

alloc_lobby :: proc(s: ^Server) -> int {
	for &l, i in s.lobbies {
		if !l.alive {
			l = Lobby{}
			return i
		}
	}
	append(&s.lobbies, Lobby{})
	return len(s.lobbies) - 1
}

recv_into :: proc(s: ^Server, i: int) {
	tmp: [8192]u8
	for {
		got, err := net.recv_tcp(s.clients[i].socket, tmp[:])
		if err != nil {
			if err == net.TCP_Recv_Error.Would_Block do return
			drop_client(s, i)
			return
		}
		if got == 0 {
			drop_client(s, i) // peer closed
			return
		}
		append(&s.clients[i].rx, ..tmp[:got])
		if got < len(tmp) do return
	}
}

// Forward everything received from a playing client to its partner.
relay_client :: proc(s: ^Server, i: int) {
	if len(s.clients[i].rx) == 0 do return
	p := s.clients[i].partner
	if p < 0 || !s.clients[p].alive {
		drop_client(s, i)
		return
	}
	send_raw(s, p, s.clients[i].rx[:])
	clear(&s.clients[i].rx)
}

// Parse and handle control frames from a lobby-phase client.
process_lobby_client :: proc(s: ^Server, i: int) {
	consumed := 0
	for {
		t, body, total, ok := netplay.read_ctrl_frame(s.clients[i].rx[consumed:])
		if !ok do break

		switch t {
		case netplay.CtrlType.Create:
			p: netplay.CreatePayload
			mem.copy(&p, raw_data(body), min(len(body), size_of(p)))
			handle_create(s, i, p)
		case netplay.CtrlType.Join:
			p: netplay.JoinPayload
			mem.copy(&p, raw_data(body), min(len(body), size_of(p)))
			handle_join(s, i, p)
		case netplay.CtrlType.List:
			handle_list(s, i)
		case netplay.CtrlType.Listing, netplay.CtrlType.CreateResult,
		     netplay.CtrlType.JoinResult, netplay.CtrlType.Matched:
			// Server-bound only; ignore client-sent server messages.
		}

		consumed += total
		if !s.clients[i].alive || s.clients[i].state != .Lobby do break
	}
	compact_rx(s, i, consumed)
}

handle_create :: proc(s: ^Server, i: int, p: netplay.CreatePayload) {
	pp := p
	name := netplay.buf_to_name(pp.name[:])
	if name == "" || lobby_index_by_name(s, name) >= 0 {
		reply_result(s, i, netplay.CtrlType.CreateResult, false, .NameInUse)
		return
	}
	li := alloc_lobby(s)
	s.lobbies[li] = Lobby{
		name        = clone_string(name),
		password    = clone_string(netplay.buf_to_name(pp.password[:])),
		public      = pp.public != 0,
		host_client = i,
		alive       = true,
	}
	s.clients[i].state = .Waiting
	s.clients[i].lobby = li
	reply_result(s, i, netplay.CtrlType.CreateResult, true, .None)
	fmt.printfln("[*] client %d created game %q (public=%v, pw=%v)", i, name, pp.public != 0, len(s.lobbies[li].password) > 0)
}

handle_join :: proc(s: ^Server, i: int, p: netplay.JoinPayload) {
	pp := p
	name := netplay.buf_to_name(pp.name[:])
	li := lobby_index_by_name(s, name)
	if li < 0 {
		reply_result(s, i, netplay.CtrlType.JoinResult, false, .NotFound)
		return
	}
	given := netplay.buf_to_name(pp.password[:])
	if s.lobbies[li].password != "" && s.lobbies[li].password != given {
		reply_result(s, i, netplay.CtrlType.JoinResult, false, .WrongPassword)
		return
	}

	host := s.lobbies[li].host_client
	if host < 0 || !s.clients[host].alive || s.clients[host].state != .Waiting {
		reply_result(s, i, netplay.CtrlType.JoinResult, false, .NotFound)
		return
	}

	// Pair the two clients and retire the lobby.
	s.clients[i].partner = host
	s.clients[i].state = .Playing
	s.clients[i].lobby = -1
	s.clients[host].partner = i
	s.clients[host].state = .Playing
	free_lobby(s, li)

	send_matched(s, host, true)  // creator is the gameplay host (seed authority)
	send_matched(s, i, false)
	fmt.printfln("[=] matched client %d (host) with client %d -> game %q", host, i, name)
}

handle_list :: proc(s: ^Server, i: int) {
	payload: netplay.ListingPayload
	count := 0
	for l in s.lobbies {
		if !l.alive || !l.public do continue
		if count >= netplay.MAX_LISTING do break
		payload.games[count] = netplay.GameInfo{
			name         = netplay.name_to_buf(l.name),
			has_password = len(l.password) > 0 ? 1 : 0,
		}
		count += 1
	}
	payload.count = u16(count)

	pp := payload
	buf: [4096]u8
	frame := netplay.encode_ctrl(buf[:], netplay.CtrlType.Listing, mem.ptr_to_bytes(&pp))
	send_raw(s, i, frame)
}

reply_result :: proc(s: ^Server, i: int, t: netplay.CtrlType, ok: bool, reason: netplay.ResultReason) {
	r := netplay.ResultPayload{ok = ok ? 1 : 0, reason = u8(reason)}
	buf: [64]u8
	frame := netplay.encode_ctrl(buf[:], t, mem.ptr_to_bytes(&r))
	send_raw(s, i, frame)
}

send_matched :: proc(s: ^Server, i: int, is_host: bool) {
	m := netplay.MatchedPayload{is_host = is_host ? 1 : 0}
	buf: [64]u8
	frame := netplay.encode_ctrl(buf[:], netplay.CtrlType.Matched, mem.ptr_to_bytes(&m))
	send_raw(s, i, frame)
}

// Blocking-ish send: loop over partial writes, spin on would-block (data is
// small and infrequent), drop the client on a hard error.
send_raw :: proc(s: ^Server, i: int, data: []byte) {
	sent := 0
	for sent < len(data) {
		written, err := net.send_tcp(s.clients[i].socket, data[sent:])
		if err != nil && written <= 0 {
			if err == net.TCP_Send_Error.Would_Block do continue
			drop_client(s, i)
			return
		}
		sent += written
	}
}

lobby_index_by_name :: proc(s: ^Server, name: string) -> int {
	for l, i in s.lobbies {
		if l.alive && l.name == name do return i
	}
	return -1
}

free_lobby :: proc(s: ^Server, li: int) {
	if li < 0 || li >= len(s.lobbies) || !s.lobbies[li].alive do return
	delete(s.lobbies[li].name)
	delete(s.lobbies[li].password)
	s.lobbies[li].alive = false
}

// Tear down a client, cleaning up its lobby and disconnecting any partner (the
// partner's app treats a closed socket as the opponent quitting -> a win).
drop_client :: proc(s: ^Server, i: int) {
	if i < 0 || i >= len(s.clients) || !s.clients[i].alive do return
	was_playing := s.clients[i].state == .Playing
	partner := s.clients[i].partner

	net.close(s.clients[i].socket)
	delete(s.clients[i].rx)
	if s.clients[i].lobby >= 0 {
		free_lobby(s, s.clients[i].lobby)
	}
	s.clients[i].alive = false
	fmt.printfln("[-] client %d disconnected", i)

	if was_playing && partner >= 0 {
		drop_client(s, partner) // partner's alive flag stops the recursion
	}
}

compact_rx :: proc(s: ^Server, i: int, consumed: int) {
	if consumed <= 0 do return
	remaining := s.clients[i].rx[consumed:]
	copy(s.clients[i].rx[:], remaining)
	resize(&s.clients[i].rx, len(remaining))
}

clone_string :: proc(src: string) -> string {
	if len(src) == 0 do return ""
	b := make([]u8, len(src))
	copy(b, src)
	return string(b)
}
