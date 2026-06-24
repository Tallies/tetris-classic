# Container image for the Tetris Classic matchmaking/relay server.
#
# Placed at the repo root so platforms that connect a GitHub repo (e.g.
# SnapDeploy) auto-detect it. The build needs the whole repo (game/, net/,
# server/), which the root build context provides.
#
# The server uses only core:net + libc (no GUI), so the runtime image is tiny.
# Self-contained build: stage 1 builds the Odin compiler from a pinned tag and
# then the server, on the same base as the runtime stage so glibc matches. The
# first build is slow (it compiles Odin); bump ODIN_REF to a real Odin release
# tag if needed.
#
# Local use:
#   docker build -t tetris-server .
#   docker run --rm -p 7777:7777 tetris-server          # or set the port:
#   docker run --rm -e PORT=9000 -p 9000:9000 tetris-server
#
# Listen port precedence: $PORT > the CMD arg below > 7777. Hosts that inject a
# PORT env var (SnapDeploy, etc.) are honored automatically.

ARG ODIN_REF=dev-2026-06

# ---- build stage ----
FROM ubuntu:24.04 AS build
ARG ODIN_REF
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        git make clang llvm ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${ODIN_REF}" https://github.com/odin-lang/Odin /opt/odin \
    && cd /opt/odin && ./build_odin.sh release
ENV PATH="/opt/odin:${PATH}"

WORKDIR /src
COPY . .
RUN odin build server -out:tetris-server -o:speed

# ---- runtime stage ----
FROM ubuntu:24.04
COPY --from=build /src/tetris-server /usr/local/bin/tetris-server
EXPOSE 7777
ENTRYPOINT ["tetris-server"]
CMD ["7777"]
