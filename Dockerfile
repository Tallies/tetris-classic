# Container image for the Tetris Classic matchmaking/relay server.
#
# Placed at the repo root so platforms that connect a GitHub repo (e.g.
# SnapDeploy) auto-detect it. The build needs the whole repo (game/, net/,
# server/), which the root build context provides.
#
# The server uses only core:net + libc (no GUI), so the runtime image is tiny.
# The build downloads a prebuilt Odin compiler (matching the build arch) rather
# than compiling it from source — fast, and no LLVM toolchain to install. Only
# `clang` is needed, which Odin uses to link the final binary.
#
# Local use:
#   docker build -t tetris-server .
#   docker run --rm -p 7777:7777 tetris-server          # or set the port:
#   docker run --rm -e PORT=9000 -p 9000:9000 tetris-server
#
# ODIN_REF must be a published Odin release tag with linux-amd64/arm64 assets.

ARG ODIN_REF=dev-2026-06

# ---- build stage ----
FROM ubuntu:24.04 AS build
ARG ODIN_REF
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        clang curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download the prebuilt Odin for this architecture (amd64 or arm64).
RUN arch="$(dpkg --print-architecture)" \
    && url="https://github.com/odin-lang/Odin/releases/download/${ODIN_REF}/odin-linux-${arch}-${ODIN_REF}.tar.gz" \
    && echo "Fetching $url" \
    && curl -fsSL "$url" -o /tmp/odin.tar.gz \
    && mkdir -p /opt/odin \
    && tar -xzf /tmp/odin.tar.gz -C /opt/odin --strip-components=1 \
    && rm /tmp/odin.tar.gz

WORKDIR /src
COPY . .
RUN /opt/odin/odin build server -out:tetris-server -o:speed

# ---- runtime stage ----
FROM ubuntu:24.04
COPY --from=build /src/tetris-server /usr/local/bin/tetris-server
# The only variable worth setting: the listen port. Hosts that inject their own
# PORT override this automatically.
ENV PORT=7777
EXPOSE 7777
ENTRYPOINT ["tetris-server"]
