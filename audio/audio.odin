package audio

import "core:math"
import rl "vendor:raylib"

// Procedural chiptune audio: no asset files. Music is synthesized on the fly
// into a streamed buffer; sound effects are short waveforms rendered once at
// startup. Everything degrades gracefully if there is no audio device (e.g. a
// headless run) — every call is a no-op until `ready`.

SAMPLE_RATE   :: 44100
BUFFER_FRAMES :: 2048 // ~46 ms per refill at 44.1 kHz

WaveKind :: enum {
	Square,
	Triangle,
	Pulse, // 25% duty
	Noise,
}

// One note in a voice's sequence. midi 0 == rest. `beats` is its length.
Note :: struct {
	midi:  u8,
	beats: f32,
}

// A melodic voice: a looping note sequence rendered with one waveform.
Voice :: struct {
	notes: []Note,
	total: f32, // sum of beats (cached)
	kind:  WaveKind,
	vol:   f32,
}

Sfx :: enum {
	Rotate,
	Drop,
	LineClear,
	Tetris,
	LevelUp,
	GameOver,
}

State :: struct {
	ready:         bool,
	music_on:      bool,
	sfx_on:        bool,
	music_started: bool,

	stream: rl.AudioStream,
	buf:    [BUFFER_FRAMES]i16,

	voices:     []Voice,
	play_beats: f32, // global playhead in beats (kept wrapped to song_beats)
	song_beats: f32, // loop length; wrapping keeps play_beats small for f32 precision
	bpm:        f32,
	rng:        u64,

	sfx: [Sfx]rl.Sound,
}

@(private) s: State

// ---- lifecycle -------------------------------------------------------------

init :: proc() {
	s.music_on = true
	s.sfx_on = true
	s.bpm = BASE_BPM
	s.rng = 0x1234_5678_9abc_def1

	rl.InitAudioDevice()
	s.ready = rl.IsAudioDeviceReady()
	if !s.ready do return

	rl.SetAudioStreamBufferSizeDefault(BUFFER_FRAMES)
	s.stream = rl.LoadAudioStream(SAMPLE_RATE, 16, 1)
	rl.SetAudioStreamVolume(s.stream, 0.5)

	s.voices = make_song()
	s.song_beats = 0
	for v in s.voices do s.song_beats = max(s.song_beats, v.total)
	if s.song_beats <= 0 do s.song_beats = 32
	build_sfx()

	rl.PlayAudioStream(s.stream)
	s.music_started = true
}

shutdown :: proc() {
	if !s.ready do return
	rl.StopAudioStream(s.stream)
	rl.UnloadAudioStream(s.stream)
	for snd in s.sfx do rl.UnloadSound(snd)
	delete(s.voices)
	rl.CloseAudioDevice()
	s.ready = false
}

// Feed the music stream. Call once per frame.
update :: proc() {
	if !s.ready || !s.music_on do return
	for rl.IsAudioStreamProcessed(s.stream) {
		fill_buffer()
	}
}

// ---- controls --------------------------------------------------------------

set_music_enabled :: proc(on: bool) {
	s.music_on = on
	if !s.ready do return
	if on {
		rl.ResumeAudioStream(s.stream)
	} else {
		rl.PauseAudioStream(s.stream)
	}
}

set_sfx_enabled :: proc(on: bool) {
	s.sfx_on = on
}

music_enabled :: proc() -> bool { return s.music_on }
sfx_enabled   :: proc() -> bool { return s.sfx_on }

// Set the gameplay level so the music tempo rises as play speeds up.
set_level :: proc(level: int) {
	l := clamp(level, 1, 10)
	s.bpm = BASE_BPM + f32(l - 1) * BPM_PER_LEVEL
}

play :: proc(kind: Sfx) {
	if !s.ready || !s.sfx_on do return
	rl.PlaySound(s.sfx[kind])
}

// ---- synthesis -------------------------------------------------------------

BASE_BPM      :: f32(142)
BPM_PER_LEVEL :: f32(7)

frac :: proc(x: f32) -> f32 { return x - math.floor(x) }

note_freq :: proc(midi: u8) -> f32 {
	if midi == 0 do return 0
	return 440.0 * math.pow(2.0, (f32(midi) - 69.0) / 12.0)
}

osc :: proc(kind: WaveKind, phase: f32) -> f32 {
	switch kind {
	case .Square:   return phase < 0.5 ? 1 : -1
	case .Pulse:    return phase < 0.25 ? 1 : -1
	case .Triangle: return 4 * abs(phase - 0.5) - 1
	case .Noise:    return 0 // handled separately
	}
	return 0
}

// Short attack/release envelope (in seconds) to avoid clicks.
env_ar :: proc(t, dur: f32) -> f32 {
	atk := f32(0.006)
	rel := min(f32(0.05), dur * 0.3)
	if t < atk do return t / atk
	if t > dur - rel do return max(0, (dur - t) / rel)
	return 1
}

// Find the active note in a voice at a beat position (looping).
note_at :: proc(v: ^Voice, beats: f32) -> (midi: u8, t_in_beats, dur_beats: f32) {
	b := beats - v.total * math.floor(beats / v.total)
	acc: f32 = 0
	for n in v.notes {
		if b < acc + n.beats {
			return n.midi, b - acc, n.beats
		}
		acc += n.beats
	}
	last := v.notes[len(v.notes) - 1]
	return last.midi, last.beats, last.beats
}

rng_noise :: proc() -> f32 {
	s.rng ~= s.rng << 13
	s.rng ~= s.rng >> 7
	s.rng ~= s.rng << 17
	return (f32(s.rng & 0xffff) / 32768.0) - 1.0
}

fill_buffer :: proc() {
	spb := 60.0 / s.bpm           // seconds per beat
	dbeat := (1.0 / f32(SAMPLE_RATE)) / spb

	for i in 0 ..< BUFFER_FRAMES {
		mix: f32 = 0

		for &v in s.voices {
			midi, tb, db := note_at(&v, s.play_beats)
			if midi == 0 do continue
			sec := tb * spb
			dur := db * spb
			f := note_freq(midi)
			ph := frac(f * sec)
			mix += osc(v.kind, ph) * env_ar(sec, dur) * v.vol
		}

		// Procedural percussion: a short noise tick on each beat.
		fb := frac(s.play_beats)
		if fb < 0.08 {
			decay := (0.08 - fb) / 0.08
			mix += rng_noise() * decay * decay * 0.12
		}

		mix = clamp(mix, -1, 1)
		s.buf[i] = i16(mix * 30000)

		// Keep the playhead small so the f32 increment never rounds to zero
		// (which previously froze the music after a few minutes).
		s.play_beats += dbeat
		if s.play_beats >= s.song_beats {
			s.play_beats -= s.song_beats
		}
	}

	rl.UpdateAudioStream(s.stream, &s.buf[0], BUFFER_FRAMES)
}
