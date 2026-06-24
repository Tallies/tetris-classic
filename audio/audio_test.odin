package audio

import "core:testing"

// These cover the music data and note math (no audio device needed).

@(test)
test_song_bar_totals :: proc(t: ^testing.T) {
	v := make_song()
	defer delete(v)
	testing.expect_value(t, len(v), 2)
	// Both voices must be 32 beats (8 bars of 4/4) so they loop in sync; a
	// mis-summed bar in the melody/bass data would trip this.
	testing.expect(t, abs(v[0].total - 32) < 0.001, "melody is 32 beats")
	testing.expect(t, abs(v[1].total - 32) < 0.001, "bass is 32 beats")
}

@(test)
test_note_freq :: proc(t: ^testing.T) {
	testing.expect(t, abs(note_freq(69) - 440) < 0.01, "A4 = 440 Hz")
	testing.expect(t, abs(note_freq(81) - 880) < 0.1, "A5 = 880 Hz (octave up)")
	testing.expect_value(t, note_freq(0), 0) // rest
}

@(test)
test_note_at_loops :: proc(t: ^testing.T) {
	v := make_song()
	defer delete(v)
	m := &v[0]
	a, _, _ := note_at(m, 0)
	b, _, _ := note_at(m, m.total) // exactly one loop later
	testing.expect_value(t, b, a)
}
