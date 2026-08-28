#!/bin/sh
# Builds the tryst-sdl Docker test image and runs its spec suite under
# Xvfb (see ../Dockerfile), then cleans up the dangling images repeated
# builds leave behind - re-tagging the same name orphans the previous
# image (<none>:<none>) every time, and they pile up fast. Labeled so
# cleanup only ever touches this image, never dangling images belonging
# to the parent project or anything else on the machine.
#
# The build context is this repo's own root: tryst is a `github:` shard
# dependency now, fetched by `shards install` inside the image rather
# than needing to be copied in. Run it from anywhere.
#
# Any arguments are passed straight through to `crystal spec` inside the
# container, so a focused run works here as well as on the host:
#
#   scripts/docker-test.sh                                # everything
#   scripts/docker-test.sh spec/tryst/sdl/linking_spec.cr  # one file
#   scripts/docker-test.sh -e "links SDL3_mixer"           # by name
set -eu

IMAGE=tryst-sdl-test
LABEL=project=tryst-sdl

# This script lives in <repo>/scripts, so the root is one up.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

docker build --label "$LABEL" -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"

status=0
if [ "$#" -eq 0 ]; then
  docker run --rm --init "$IMAGE" || status=$?
else
  docker run --rm --init "$IMAGE" xvfb-run -a crystal spec "$@" || status=$?
fi

docker image prune -f --filter "label=$LABEL" >/dev/null

exit "$status"
