# Tetris Classic (Odin)

A native, cross-platform recreation of *Tetris Classic* (Spectrum HoloByte, 1992)
written in [Odin](https://odin-lang.org), rendered with raylib, with online
multiplayer over TCP.

> Background artwork from the original is trademarked and intentionally omitted;
> each level currently has its own background colour (same level → same colour),
> a placeholder for per-level artwork later. The pit is drawn over a dark
> translucent overlay so the background never interferes with play. Block art
> uses a beveled 90s look; completed rows flash (inverse colours) before clearing.

## Modes

| Mode | Players | Pit | Network |
|------|---------|-----|---------|
| **Campaign** | 1 | 10×20 | — |
| **Cooperative** | 2 (local) | shared wide | — |
| **Competitive** | 2 (local) | shared wide | — |
| **Dual Pit** | 2 (local) | two pits, garbage sending | — |
| **Head-to-Head** | 2 | two pits, garbage sending | **online host/join** |

Campaign supports the original time-limit variants (Unlimited / 15 / 10 / 5 / 3
minutes) and both scoring systems (Original and Tetris Classic), plus the
optional hidden-Next bonus.

## Build & Run

```sh
./build.sh          # builds the game client -> ./tetris
./tetris

./build-server.sh   # builds the matchmaking server -> ./tetris-server
./tetris-server [port]   # default port 7777
```

Or directly:

```sh
odin build .      -out:tetris        -o:speed
odin build server -out:tetris-server -o:speed
```

Requires the Odin toolchain (tested with the 2026-06 nightly). raylib and
`core:net` ship with Odin — no system libraries needed.

## Running a downloaded release

Release builds are attached to each tagged release: a `.zip` for Windows and a
`.tar.gz` for Linux/macOS (each also contains this README). Extract it, then:

**Windows** — the build is **not code-signed**, so Microsoft Defender SmartScreen
shows *"Windows protected your PC … unknown publisher."* This is expected for an
unsigned app, not a virus warning. To run it:

- Click **More info → Run anyway** on the SmartScreen dialog, or
- Right-click `tetris.exe` → **Properties** → tick **Unblock** → OK (then run),
  or in PowerShell: `Unblock-File .\tetris.exe`.

(Removing the warning entirely requires code-signing the executable with a
trusted certificate — a paid step that isn't set up for these builds.)

**Linux / macOS** — extract and run `./tetris` (the executable bit is preserved
in the tarball). On macOS, Gatekeeper may need **Right-click → Open** the first
time for the same unsigned-app reason.

## Controls

**Single player / online:** by default **all three** schemes are active at once
(left- and right-handed friendly) — **Arrows** (↑ CW, `Z` CCW, ↓ drop),
**IJKL** (`I` CW, `U` CCW, `J`/`L` move, `K` drop), and **WASD** (`W` CW,
`Left Shift` CCW, `A`/`D` move, `S` drop). The Controls option in setup can
restrict it to a single scheme.

**Two-player local** — fixed schemes, one per side of the pit:
- **Left player:** `A`/`D` move, `W` rotate CW, `Left Shift` rotate CCW, `S` drop.
- **Right player:** Arrow keys **or** `J`/`I`/`K`/`L` (+`U` for CCW) — both work,
  handy when a laptop's arrow keys are cramped.

`Esc` or `P` open the pause menu (Continue / Exit to Menu) · `Enter` confirm /
return after game over.
`M` toggle music · `N` toggle sound effects.

## Single-player extras

Campaign shows a **high score** that persists between runs (saved locally to
`~/.tetris-classic-highscore`, or `%APPDATA%\tetris-classic-highscore` on
Windows) and flags a **NEW HIGH SCORE!** on the results screen when you beat it.
The HUD also shows a **Pieces Used** panel under the Next box with a running
count of each tetromino kind.

## Audio

Music and sound are **synthesized procedurally at runtime** (a small chiptune
engine in `audio/`) — there are no audio asset files. The theme is an original
chiptune arrangement of *Korobeiniki*, the public-domain Russian folk melody;
its tempo rises with the level. Sound effects (rotate, drop, line clear, Tetris,
level up, game over) are short generated waveforms. Toggle either with `M` / `N`.

The **down key** is the only drop control; its behavior is set in options:

- **Fast drop** (default) — hold to fall faster, stops when released.
- **Immediate drop** — a press drops and locks the piece instantly.

## Options (scoring tradeoffs)

Disabling on-screen aids scores more — bonuses stack:

- **Next Piece off:** +25%
- **Ghost Piece off** (the landing-shadow predictor): +10%

Set these (and the down-key behavior) on the **Setup** screen for local modes, or
via **Head-to-Head → Online → Options** for networked play. They're personal and
apply to your pit in every mode.

## Head-to-Head play

Two ways to connect, both under the **Head-to-Head** menu:

### Direct (LAN) — same network, no server

1. One player picks **Head-to-Head → Direct (LAN) → Host Game** and shares their IP.
2. The other picks **Direct (LAN) → Join Game** and types the host's address.
3. Uses TCP port **7777**. Over the internet this needs the host to port-forward;
   on a LAN/VPN it just works.

### Online (Server) — internet play via matchmaking

Run `tetris-server` somewhere both players can reach (a cloud VM), then:

1. Both players pick **Head-to-Head → Online (Server)** and enter the server's
   address (IP or hostname).
2. One picks **Create Game**, gives it a name, optionally a password, and chooses
   whether it's listed publicly (Browse) or join-by-name only.
3. The other picks **Browse Games** (to pick from the list) or knows the name and
   joins it; if it's password-protected they're prompted for the password.
4. They're matched and play begins.

**All gameplay traffic relays through the server**, so neither player needs to
port-forward and it works behind any NAT. The server only needs its TCP port
(default **7777**) reachable. See *Deployment* below.

### Netcode model

Each peer authoritatively simulates only its own pit and streams a snapshot to the
other for display; line clears send garbage rows to the opponent, who applies them
to their own pit. This is latency-tolerant — a late packet only briefly makes the
opponent mirror stale, never desyncs your own game. The online server is a
transparent relay: once matched, it forwards these same gameplay packets verbatim,
so the protocol is identical to direct play.

## Deployment (matchmaking server)

The server is a single static-ish binary with no runtime dependencies beyond libc.

```sh
./build-server.sh                 # -> ./tetris-server
scp tetris-server user@your-vm:   # copy to a cloud VM
ssh user@your-vm './tetris-server 7777'
# open TCP 7777 in the VM's firewall / security group
```

Then point both clients' server address at the VM's public IP or hostname. Lobbies
are in-memory and ephemeral (no database, no accounts); restart clears them. For
always-on use, run it under a process manager (systemd / a container).

### Docker

A self-contained image is provided (`Dockerfile` at the repo root):

```sh
docker build -t tetris-server .
docker run --rm -p 7777:7777 tetris-server               # or set the port:
docker run --rm -e PORT=9000 -p 9000:9000 tetris-server
```

Listen port precedence is `$PORT` > the CMD arg > 7777. The first build is slow
because it compiles the Odin toolchain from source (pinned via the `ODIN_REF`
build arg) so the binary matches the runtime image's glibc. For ARM hosts, build
with `docker buildx --platform linux/arm64`.

### Deploying to a container host (SnapDeploy etc.)

The root `Dockerfile` is what a Docker-native PaaS like
[SnapDeploy](https://snapdeploy.dev/) builds: connect the GitHub repo, it detects
the Dockerfile, builds, and runs the server. The server reads `$PORT` if the host
injects one, and `EXPOSE 7777` advertises the default.

> **Important — the server speaks raw TCP, not HTTP.** Hosts that only route
> HTTP/HTTPS (with HTTP health checks and SSL termination) cannot carry the game
> protocol, and an HTTP health check against the raw-TCP port will fail. Before
> relying on SnapDeploy, confirm it supports a **raw TCP service / TCP health
> check** (and exposes a reachable TCP port to clients). If it is HTTP-only, the
> server would need its transport changed to **WebSocket** (rides on HTTP/S) —
> a larger change to both client and server that isn't done here. A VM or a
> TCP-capable host (Fly.io, a plain Docker host, etc.) runs it as-is.

### Continuous builds

`.github/workflows/build.yml` builds native client + server binaries for Linux,
Windows, and macOS (Apple Silicon) on every push, and attaches them to a
GitHub Release when you push a `v*` tag.

## Tests

```sh
odin test game     # board logic, scoring, garbage, seven-bag
odin test net      # localhost direct host/join message round-trip
odin test server   # in-process create/browse/join/match + gameplay relay
odin test audio    # music data (bar sums), note frequencies, loop wrap
```

## Project layout

```
main.odin / app.odin / input.odin / menu.odin   app state machine, loop, input
game/      core simulation (no rendering/net): types, board, scoring, session
render/    raylib drawing: palette, blocks, pits, HUD, layouts
audio/     procedural chiptune engine: synth, Korobeiniki arrangement, SFX
net/       client TCP transport + gameplay & lobby wire protocols (package `netplay`)
server/    dedicated matchmaking + relay server (separate binary, package `main`)
```

## Roadmap

- Decorative per-level background art (original-style) behind the pits.
- Hold piece; full high-score *table* (per mode) beyond the single-player best.
- Richer arrangement / per-level music variations.
- WASM build target (raylib supports it) for browser play.
```
