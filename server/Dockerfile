# Matchmaking/relay server image.
#
# The server uses only core:net + libc (no GUI), so the runtime image is tiny.
# It is built self-contained: stage 1 builds the Odin compiler from source
# (pinned via ODIN_REF) and then the server, on the same base as the runtime
# stage so the binary's glibc matches. The first build is slow (it compiles
# Odin); adjust ODIN_REF to a real Odin release tag as needed.
#
# Build from the REPO ROOT (the build needs game/, net/, server/):
#   docker build -f server/Dockerfile -t tetris-server .
#   docker run --rm -p 7777:7777 tetris-server
# Override the port:
#   docker run --rm -p 9000:9000 tetris-server 9000

ARG ODIN_REF=dev-2026-06

# ---- build stage ----
FROM ubuntu:24.04 AS build
ARG ODIN_REF
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        git make clang llvm ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build the Odin compiler from a pinned tag.
RUN git clone --depth 1 --branch "${ODIN_REF}" https://github.com/odin-lang/Odin /opt/odin \
    && cd /opt/odin && ./build_odin.sh release
ENV PATH="/opt/odin:${PATH}"

# Build the server.
WORKDIR /src
COPY . .
RUN odin build server -out:tetris-server -o:speed

# ---- runtime stage ----
FROM ubuntu:24.04
COPY --from=build /src/tetris-server /usr/local/bin/tetris-server
EXPOSE 7777
ENTRYPOINT ["tetris-server"]
CMD ["7777"]
