#!/usr/bin/env sh
set -e

# Builds the claudine image. --no-cache also refreshes the cached apt layer.
#
# Usage: ./scripts/build.sh [--no-cache]

IMAGE_NAME="claudine"
NO_CACHE=""

case "${1:-}" in
  "") ;;
  --no-cache) NO_CACHE="--no-cache" ;;
  -h|--help)
    echo "Usage: ./scripts/build.sh [--no-cache]"
    exit 0
    ;;
  *)
    echo "build.sh: unknown argument: $1" >&2
    exit 1
    ;;
esac

# The image user takes the host UID, which can't be root's.
if [ "$(id -u)" -eq 0 ]; then
  echo "build.sh: refusing to build as root, run it as your regular user" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# shellcheck disable=SC2086 # NO_CACHE is empty or a single flag
docker build --pull $NO_CACHE \
  --build-arg CLAUDE_UPDATE_DATE="$(date +%Y-%m-%d)" \
  --build-arg USER_UID="$(id -u)" \
  --build-arg USER_GID="$(id -g)" \
  -t "$IMAGE_NAME" .
