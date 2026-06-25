package netplay

import "core:testing"
import "core:time"

// The async dialer completes off the main thread; a refused connection resolves
// quickly to a nil result without blocking the caller.
@(test)
test_async_dial_refused :: proc(t: ^testing.T) {
	d := dial_start("127.0.0.1", 1, false) // nothing listens on port 1 -> refused
	done := false
	for _ in 0 ..< 500 {
		if dial_done(d) {
			done = true
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, done, "async dial finishes")
	n := dial_take(d)
	testing.expect(t, n == nil, "refused connection yields no Net")
}

// End-to-end localhost test: host accepts a client, then a snapshot and a
// garbage message round-trip across the socket and decode correctly.
@(test)
test_host_join_roundtrip :: proc(t: ^testing.T) {
	PORT :: 7799

	h, ok_h := host(PORT)
	testing.expect(t, ok_h, "host should start")
	defer if h != nil do shutdown(h)

	c, ok_c := join("127.0.0.1", PORT)
	testing.expect(t, ok_c, "client should connect")
	defer if c != nil do shutdown(c)

	// Pump until the host observes the client connecting.
	connected := false
	for _ in 0 ..< 100 {
		for ev in poll(h) {
			#partial switch _ in ev {
			case Connected:
				connected = true
			}
		}
		if connected do break
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, connected, "host should see the client connect")

	// Host sends a snapshot with a recognizable marker, plus garbage.
	snap := SnapshotPayload{score = 4242, level = 7}
	snap.cells[0][0] = 5
	send_snapshot(h, snap)
	send_garbage(h, 3)

	got_snap := false
	got_garbage := false
	for _ in 0 ..< 100 {
		for ev in poll(c) {
			#partial switch e in ev {
			case SnapshotPayload:
				testing.expect_value(t, e.score, 4242)
				testing.expect_value(t, e.level, 7)
				testing.expect_value(t, e.cells[0][0], 5)
				got_snap = true
			case GarbagePayload:
				testing.expect_value(t, e.count, 3)
				got_garbage = true
			}
		}
		if got_snap && got_garbage do break
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, got_snap, "client should receive the snapshot")
	testing.expect(t, got_garbage, "client should receive the garbage message")
}
