package game

// Deterministic RNG so networked play can stay in sync from a shared seed.
// xorshift64* — small, fast, good enough for piece sequencing and garbage holes.

rng_next :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	state^ = x
	return x * 0x2545F4914F6CDD1D
}

rng_range :: proc(state: ^u64, n: int) -> int {
	if n <= 0 do return 0
	return int(rng_next(state) % u64(n))
}

// Refill and shuffle a player's seven-bag (Fisher-Yates).
refill_bag :: proc(p: ^Player) {
	kinds := [7]PieceKind{.I, .O, .T, .S, .Z, .J, .L}
	for i := 6; i > 0; i -= 1 {
		j := rng_range(&p.rng_state, i + 1)
		kinds[i], kinds[j] = kinds[j], kinds[i]
	}
	p.bag = kinds
	p.bag_index = 0
}

draw_piece :: proc(p: ^Player) -> PieceKind {
	if p.bag_index >= 7 {
		refill_bag(p)
	}
	k := p.bag[p.bag_index]
	p.bag_index += 1
	return k
}
