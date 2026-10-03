#!/usr/bin/env sh
set -e

# Scans the image with trivy. Fails on fixable HIGH/CRITICAL vulnerabilities;
# --all also lists unfixed ones.
#
# Usage: ./scripts/security-scan.sh [--all]

IMAGE_NAME="claudine"
# Pinned: it gets the Docker socket, i.e. root on the host.
TRIVY_IMAGE="aquasec/trivy:0.75.0"
IGNORE_UNFIXED="--ignore-unfixed"

case "${1:-}" in
  "") ;;
  --all) IGNORE_UNFIXED="" ;;
  -h|--help)
    echo "Usage: ./scripts/security-scan.sh [--all]"
    exit 0
    ;;
  *)
    echo "security-scan.sh: unknown argument: $1" >&2
    exit 1
    ;;
esac

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "security-scan.sh: image '$IMAGE_NAME' not found, run ./scripts/build.sh first" >&2
  exit 1
fi

TRIVY_CACHE_DIR="${HOME}/.cache/trivy"
mkdir -p "$TRIVY_CACHE_DIR"

# shellcheck disable=SC2086 # IGNORE_UNFIXED is empty or a single flag
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${TRIVY_CACHE_DIR}:/root/.cache/trivy" \
  "$TRIVY_IMAGE" image \
  --scanners vuln \
  --severity HIGH,CRITICAL \
  $IGNORE_UNFIXED \
  --exit-code 1 \
  "$IMAGE_NAME"
