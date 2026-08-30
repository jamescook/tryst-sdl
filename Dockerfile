# Dev/test image for tryst-sdl. Built from this repo's own root as
# context - tryst is a `github:` shard dependency now (its own repo), so
# `shards install` fetches it directly rather than needing it copied
# into the build context.
#
# Debian forky rather than the crystallang/crystal image the parent
# project uses, purely for SDL3 packaging: that image is Ubuntu 24.04 and
# has no sdl3 packages at all. Ubuntu 26.04 and Debian trixie carry core,
# image and ttf but not mixer; Alpine edge lacks image and mixer. Debian
# forky (testing) and sid are the only bases with all four, and forky is
# the more stable of the two. Forky still defaults tcl-dev/tk-dev to
# 8.6.18 with no Tcl 9 anywhere in the image, so the project's 8.6-only
# scoping survives the newer base.
#
# Crystal is not in Debian apt, hence the official release tarball below.
#
# Must be run as `docker run --rm --init <image>` - same requirement as
# the parent project's image. Without --init, xvfb-run hangs forever: it
# runs as the container's PID 1, and its Xvfb-readiness handshake relies
# on a SIGUSR1 trap that doesn't fire reliably for PID 1.
FROM debian:forky

# Kept in step with the `crystal:` constraint in both shard.yml files.
ARG CRYSTAL_VERSION=1.21.0
ARG CRYSTAL_RELEASE=1

# The libsdl3-*-dev four are what the @[Link] line in src/tryst/sdl/
# lib_sdl.cr resolves through pkg-config, so pkg-config is a build
# requirement and not just a convenience. The lib*-dev tail is what the
# non-bundled Crystal tarball expects to find on the system.
#
# The --mount=type=cache pair is what lets the GitHub-hosted CI build
# keep apt's downloaded packages across runs (restored/saved by
# buildkit-cache-dance in .github/workflows/crystal-spec.yml) when this
# layer has to rebuild - same pattern as tryst's own Dockerfile. It
# needs BuildKit, which every current docker build has by default.
# Nothing to clean up afterwards: the lists live in the mount, not the
# image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    tcl-dev tk-dev \
    libsdl3-dev libsdl3-mixer-dev libsdl3-image-dev libsdl3-ttf-dev \
    xvfb xauth \
    ca-certificates curl git gcc pkg-config \
    libpcre2-dev libgc-dev libevent-dev libssl-dev zlib1g-dev libyaml-dev libxml2-dev

# uname -m already spells the architectures the way the release assets do
# (aarch64 / x86_64), so no translation table is needed.
RUN set -eux; \
    arch="$(uname -m)"; \
    curl -fsSL -o /tmp/crystal.tar.gz \
      "https://github.com/crystal-lang/crystal/releases/download/${CRYSTAL_VERSION}/crystal-${CRYSTAL_VERSION}-${CRYSTAL_RELEASE}-linux-${arch}.tar.gz"; \
    mkdir -p /opt/crystal; \
    tar -xzf /tmp/crystal.tar.gz -C /opt/crystal --strip-components=1; \
    rm /tmp/crystal.tar.gz; \
    ln -s /opt/crystal/bin/crystal /usr/local/bin/crystal; \
    ln -s /opt/crystal/bin/shards /usr/local/bin/shards; \
    crystal --version

WORKDIR /app

# SDL's audio backends probe XDG_RUNTIME_DIR on the way to finding a
# driver, and the PulseAudio client prints `error: XDG_RUNTIME_DIR is
# invalid or not set in the environment.` to stderr when it is unset -
# which it is in a container. Audio init succeeds regardless, SDL simply
# moves on to another driver, but the word "error" landing in the middle
# of the spec output reads exactly like a failing test. Pointing it at a
# real directory keeps the run quiet without swapping in the dummy audio
# driver, which would make the mixer example prove rather less.
ENV XDG_RUNTIME_DIR=/tmp/xdg-runtime
RUN mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

COPY shard.yml ./
COPY src/ src/
COPY spec/ spec/

# Docker's cache key for this layer is shard.yml's own content, not
# what's actually at the github: refs it resolves - any cache that
# outlives one build (a long-running local daemon, or the type=gha
# layer cache the CI workflow restores on every hosted run) would
# otherwise keep reusing whatever tryst/ameba commit got fetched the
# FIRST time this layer ever ran, no matter how many times the actual
# dependency changed afterward. CACHEBUST (scripts/docker-test.sh
# passes the time, the workflow passes the run id) forces this layer -
# only this one, everything above it still caches normally - to always
# re-resolve.
ARG CACHEBUST=1
RUN shards install

CMD ["xvfb-run", "-a", "crystal", "spec"]
