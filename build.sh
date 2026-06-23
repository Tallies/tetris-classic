#!/usr/bin/env bash
# Build Tetris Classic. Override the compiler with ODIN=/path/to/odin.
set -euo pipefail
cd "$(dirname "$0")"

ODIN="${ODIN:-odin}"
if ! command -v "$ODIN" >/dev/null 2>&1; then
	ODIN="/home/charlmarais/odin/odin-linux-amd64-nightly+2026-06-08/odin"
fi

"$ODIN" build . -out:tetris -o:speed "$@"
echo "Built ./tetris"
