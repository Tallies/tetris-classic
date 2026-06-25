package main

import "core:testing"
import "core:time"
import netplay "../net"
import "core:net"
import "core:strings"

// An HTTP health probe on the game port gets a 200 OK (so platform health
// checks pass) without disturbing the game protocol.
@(test)
test_http_health_probe :: proc(t: ^testing.T) {
	PORT :: 7803
	s: Server
	testing.expect(t, server_start(&s, PORT), "server starts")
	defer server_shutdown(&s)

	sock, derr := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = PORT})
	testing.expect(t, derr == nil, "probe connects")
	defer net.close(sock)
	net.set_blocking(sock, false)

	req := "GET / HTTP/1.1\r\nHost: health\r\n\r\n"
	_, _ = net.send_tcp(sock, transmute([]u8)req)

	got: [dynamic]u8
	defer delete(got)
	ok := false
	for _ in 0 ..< 300 {
		server_tick(&s)
		buf: [512]u8
		n, rerr := net.recv_tcp(sock, buf[:])
		if rerr == nil && n > 0 {
			append(&got, ..buf[:n])
			if strings.has_prefix(string(got[:]), "HTTP/1.1 200") {
				ok = true
				break
			}
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, ok, "health probe receives HTTP 200")
}

// Full lobby + relay flow against an in-process server: create, browse, join,
// match (with correct host roles), then a gameplay snapshot relayed end to end.
@(test)
test_create_browse_join_relay :: proc(t: ^testing.T) {
	PORT :: 7801

	s: Server
	ok := server_start(&s, PORT)
	testing.expect(t, ok, "server should start")
	defer server_shutdown(&s)

	a, ok_a := netplay.connect_server("127.0.0.1", PORT)
	testing.expect(t, ok_a, "client A connects")
	defer if a != nil do netplay.shutdown(a)

	netplay.send_create(a, "test", "", true)

	// A should get CreateResult ok.
	created := false
	pump(&s, {a}, &created, proc(ev: netplay.Event) -> bool {
		if r, is := ev.(netplay.CreateResult); is do return r.ok
		return false
	})
	testing.expect(t, created, "create acknowledged")

	b, ok_b := netplay.connect_server("127.0.0.1", PORT)
	testing.expect(t, ok_b, "client B connects")
	defer if b != nil do netplay.shutdown(b)

	// B browses and should see the public game "test".
	netplay.send_list(b)
	saw_listing := false
	pump(&s, {a, b}, &saw_listing, proc(ev: netplay.Event) -> bool {
		if l, is := ev.(netplay.ListingPayload); is {
			return l.count >= 1 && netplay.buf_to_name(l.games[0].name[:]) == "test"
		}
		return false
	})
	testing.expect(t, saw_listing, "browse lists the created game")

	// B joins; both sides get matched with correct host roles.
	netplay.send_join(b, "test", "")
	a_matched_host := false
	b_matched_guest := false
	for iter in 0 ..< 500 {
		server_tick(&s)
		for ev in netplay.poll(a) {
			if m, is := ev.(netplay.Matched); is && m.is_host do a_matched_host = true
		}
		for ev in netplay.poll(b) {
			if m, is := ev.(netplay.Matched); is && !m.is_host do b_matched_guest = true
		}
		if a_matched_host && b_matched_guest do break
		time.sleep(time.Millisecond)
	}
	testing.expect(t, a_matched_host, "creator matched as host")
	testing.expect(t, b_matched_guest, "joiner matched as guest")
	testing.expect_value(t, a.phase, netplay.Phase.Game)
	testing.expect_value(t, b.phase, netplay.Phase.Game)

	// Gameplay now relays through the server: A sends a snapshot, B receives it.
	snap := netplay.SnapshotPayload{score = 9001, level = 5}
	snap.cells[3][2] = 6
	netplay.send_snapshot(a, snap)

	got := false
	pump(&s, {a, b}, &got, proc(ev: netplay.Event) -> bool {
		if sp, is := ev.(netplay.SnapshotPayload); is {
			return sp.score == 9001 && sp.level == 5 && sp.cells[3][2] == 6
		}
		return false
	})
	testing.expect(t, got, "snapshot relayed from A to B")
}

// Tick the server and poll the given clients until `pred` matches an event.
pump :: proc(s: ^Server, clients: []^netplay.Net, found: ^bool, pred: proc(ev: netplay.Event) -> bool) {
	for iter in 0 ..< 500 {
		server_tick(s)
		for c in clients {
			for ev in netplay.poll(c) {
				if pred(ev) {
					found^ = true
				}
			}
		}
		if found^ do return
		time.sleep(time.Millisecond)
	}
}
