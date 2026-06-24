package audio

import rl "vendor:raylib"

// Music data and sound-effect synthesis.
//
// The theme is an original arrangement of "Korobeiniki" — the 19th-century
// Russian folk melody famously used as Tetris's Type-A theme. The folk
// *composition* is public domain; this is our own chiptune arrangement of it.

// MIDI note numbers used below.
R   :: u8(0)
A4  :: u8(69);  B4  :: u8(71)
C5  :: u8(72);  D5  :: u8(74);  E5  :: u8(76);  F5 :: u8(77);  G5 :: u8(79);  A5 :: u8(81)
// bass
E2  :: u8(40);  A2  :: u8(45);  B2  :: u8(47);  C3 :: u8(48);  D3 :: u8(50);  E3 :: u8(52);  A3 :: u8(57)

// Lead melody — 8 bars of 4 beats (q = 1.0, e = 0.5).
@(private="file")
MELODY := []Note {
	{E5, 1}, {B4, 0.5}, {C5, 0.5}, {D5, 1}, {C5, 0.5}, {B4, 0.5},
	{A4, 1}, {A4, 0.5}, {C5, 0.5}, {E5, 1}, {D5, 0.5}, {C5, 0.5},
	{B4, 1}, {C5, 1}, {D5, 1}, {E5, 1},
	{C5, 1}, {A4, 1}, {A4, 1}, {R, 1},
	{D5, 0.5}, {F5, 0.5}, {A5, 1}, {G5, 0.5}, {F5, 0.5}, {E5, 1},
	{C5, 0.5}, {E5, 0.5}, {E5, 1}, {D5, 0.5}, {C5, 0.5}, {B4, 1},
	{B4, 1}, {C5, 1}, {D5, 1}, {E5, 1},
	{C5, 1}, {A4, 1}, {A4, 1}, {R, 1},
}

// Bass — half-note pulse outlining the implied chords, same 32-beat length.
@(private="file")
BASS := []Note {
	{E2, 2}, {E3, 2}, // Em
	{A2, 2}, {A3, 2}, // Am
	{E2, 2}, {B2, 2}, // Em -> B
	{A2, 2}, {A3, 2}, // Am
	{D3, 2}, {D3, 2}, // Dm
	{C3, 2}, {C3, 2}, // C
	{E2, 2}, {B2, 2}, // Em -> B
	{A2, 2}, {E2, 2}, // Am -> E
}

make_song :: proc() -> []Voice {
	voices := make([]Voice, 2)
	voices[0] = Voice{notes = MELODY, total = total_beats(MELODY), kind = .Square,   vol = 0.55}
	voices[1] = Voice{notes = BASS,   total = total_beats(BASS),   kind = .Triangle, vol = 0.42}
	return voices
}

total_beats :: proc(notes: []Note) -> f32 {
	t: f32 = 0
	for n in notes do t += n.beats
	return t
}

// ---- sound effects ---------------------------------------------------------

build_sfx :: proc() {
	s.sfx[.Rotate]    = tone_sound(700, 0.045, .Square, 0.5)
	s.sfx[.Drop]      = sweep_sound(420, 120, 0.09, .Triangle, 0.6)
	s.sfx[.LineClear] = arp_sound({523, 659, 784}, 0.06, .Square, 0.5)
	s.sfx[.Tetris]    = arp_sound({523, 659, 784, 1047, 1319}, 0.07, .Square, 0.55)
	s.sfx[.LevelUp]   = arp_sound({392, 523, 659, 784}, 0.05, .Square, 0.5)
	s.sfx[.GameOver]  = arp_sound({440, 392, 330, 262, 196}, 0.13, .Triangle, 0.55)
}

// Build a Sound from synthesized f32 samples (mono, 16-bit).
sound_from_samples :: proc(samples: []f32) -> rl.Sound {
	pcm := make([]i16, len(samples))
	defer delete(pcm)
	for v, i in samples {
		pcm[i] = i16(clamp(v, -1, 1) * 30000)
	}
	w := rl.Wave{
		frameCount = u32(len(samples)),
		sampleRate = SAMPLE_RATE,
		sampleSize = 16,
		channels   = 1,
		data       = raw_data(pcm),
	}
	snd := rl.LoadSoundFromWave(w) // copies into its own buffer
	return snd
}

env_seg :: proc(p: f32) -> f32 { // p in 0..1 within a segment
	if p < 0.1 do return p / 0.1
	if p > 0.7 do return max(0, (1 - p) / 0.3)
	return 1
}

tone_sound :: proc(freq, dur: f32, kind: WaveKind, vol: f32) -> rl.Sound {
	n := int(dur * SAMPLE_RATE)
	buf := make([]f32, n)
	defer delete(buf)
	for k in 0 ..< n {
		t := f32(k) / f32(SAMPLE_RATE)
		ph := frac(freq * t)
		buf[k] = osc(kind, ph) * env_seg(f32(k) / f32(n)) * vol
	}
	return sound_from_samples(buf)
}

sweep_sound :: proc(f0, f1, dur: f32, kind: WaveKind, vol: f32) -> rl.Sound {
	n := int(dur * SAMPLE_RATE)
	buf := make([]f32, n)
	defer delete(buf)
	phase: f32 = 0
	for k in 0 ..< n {
		p := f32(k) / f32(n)
		f := f0 + (f1 - f0) * p
		phase += f / f32(SAMPLE_RATE)
		phase = frac(phase)
		buf[k] = osc(kind, phase) * env_seg(p) * vol
	}
	return sound_from_samples(buf)
}

arp_sound :: proc(freqs: []f32, step: f32, kind: WaveKind, vol: f32) -> rl.Sound {
	per := int(step * SAMPLE_RATE)
	buf := make([]f32, per * len(freqs))
	defer delete(buf)
	i := 0
	for f in freqs {
		for k in 0 ..< per {
			t := f32(k) / f32(SAMPLE_RATE)
			ph := frac(f * t)
			buf[i] = osc(kind, ph) * env_seg(f32(k) / f32(per)) * vol
			i += 1
		}
	}
	return sound_from_samples(buf)
}
