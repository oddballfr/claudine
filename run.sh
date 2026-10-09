#!/usr/bin/env sh
set -e

# Runs Claude Code in a container that shares the host's ~/.claude and can
# only write to the project dir. The image is built on first run or --rebuild.
#
# Usage: ./run.sh [project-dir] [--rebuild] [--docker|--podman]

IMAGE_NAME="claudine"
PROJECT_DIR=""
REBUILD=""
# docker or podman, auto-detected when empty.
RUNTIME="${CLAUDINE_RUNTIME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<'EOF'
Usage: ./run.sh [project-dir] [--rebuild] [--docker|--podman]

  project-dir   Directory to mount as the container's workspace (default: cwd)
  --rebuild     Rebuild the image from scratch (latest claude and Debian fixes)
  --docker      Use docker (default when installed)
  --podman      Use rootless podman (default when docker is missing)

The runtime can also be set with CLAUDINE_RUNTIME=docker|podman.
EOF
      exit 0
      ;;
    --rebuild)
      REBUILD="1"
      shift
      ;;
    --docker|--podman)
      RUNTIME="${1#--}"
      shift
      ;;
    -*)
      echo "run.sh: unknown option: $1 (see --help)" >&2
      exit 1
      ;;
    *)
      if [ -n "$PROJECT_DIR" ]; then
        echo "run.sh: only one project dir allowed, got: $PROJECT_DIR and $1" >&2
        exit 1
      fi
      PROJECT_DIR="$1"
      shift
      ;;
  esac
done
# podman-docker installs a "docker" shim that is really podman.
if [ -z "$RUNTIME" ]; then
  if command -v docker >/dev/null 2>&1; then
    case "$(docker --version 2>/dev/null)" in
      *[Pp]odman*) RUNTIME="podman" ;;
      *) RUNTIME="docker" ;;
    esac
  else
    RUNTIME="podman"
  fi
fi
case "$RUNTIME" in
  docker|podman) ;;
  *)
    echo "run.sh: CLAUDINE_RUNTIME must be docker or podman, got: $RUNTIME" >&2
    exit 1
    ;;
esac
if ! command -v "$RUNTIME" >/dev/null 2>&1; then
  echo "run.sh: $RUNTIME not found in PATH" >&2
  exit 1
fi
# Resolved before the cd below, so relative paths stay relative to the caller.
PROJECT_DIR="$(cd "${PROJECT_DIR:-.}" && pwd)"

cd "$(dirname "$0")"

# Container names only allow [a-zA-Z0-9_.-].
PROJECT_NAME="$(basename "$PROJECT_DIR" | tr -c 'a-zA-Z0-9_.\n-' '_')"
# Same path as on the host, so Claude's project history matches.
CONTAINER_WORKSPACE="$PROJECT_DIR"

# Unique name so a project can be opened in several sessions at once.
RUN_HASH="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
CONTAINER_NAME="claudine-${PROJECT_NAME}-${RUN_HASH}"

if [ -n "$REBUILD" ] || ! "$RUNTIME" image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  # The image user takes the host UID, which can't be root's.
  if [ "$(id -u)" -eq 0 ]; then
    echo "run.sh: refusing to build as root, run it as your regular user" >&2
    exit 1
  fi
  # --no-cache: a cached apt layer would skip Debian security fixes.
  "$RUNTIME" build --pull ${REBUILD:+--no-cache} \
    --build-arg CLAUDE_UPDATE_DATE="$(date +%Y-%m-%d)" \
    --build-arg USER_UID="$(id -u)" \
    --build-arg USER_GID="$(id -g)" \
    -t "$IMAGE_NAME" .
fi

# Shared by all sessions for cross-session discovery (ListAgents, SendMessage).
CC_SOCKS_DIR="/tmp/cc-socks"
mkdir -p "$CC_SOCKS_DIR"
# /tmp is shared: another user could pre-create it and plant sockets.
if [ -L "$CC_SOCKS_DIR" ] || [ "$(stat -c %u "$CC_SOCKS_DIR")" != "$(id -u)" ]; then
  echo "run.sh: $CC_SOCKS_DIR must be a directory owned by you" >&2
  exit 1
fi
chmod 700 "$CC_SOCKS_DIR"

# Docker would create missing bind sources as root-owned dirs, podman fails.
mkdir -p "${HOME}/.claude"
[ -e "${HOME}/.claude.json" ] || echo '{}' > "${HOME}/.claude.json"

# --mount splits on commas: one in a path could inject mount options.
case "${HOME}${PROJECT_DIR}" in
  *,*)
    echo "run.sh: HOME and project dir must not contain a comma" >&2
    exit 1
    ;;
esac

# A project dir containing or inside ~/.claude would remount it writable.
CLAUDE_DIR_REAL="$(cd "${HOME}/.claude" && pwd -P)"
PROJECT_DIR_REAL="$(cd "$PROJECT_DIR" && pwd -P)"
case "${CLAUDE_DIR_REAL}/" in
  "${PROJECT_DIR_REAL%/}"/*)
    echo "run.sh: project dir must not contain ~/.claude: $PROJECT_DIR" >&2
    exit 1
    ;;
esac
case "${PROJECT_DIR_REAL}/" in
  "${CLAUDE_DIR_REAL}"/*)
    echo "run.sh: project dir must not be inside ~/.claude: $PROJECT_DIR" >&2
    exit 1
    ;;
esac

# Missing paths are created first: otherwise the session could create them.
[ -e "${HOME}/.claude/settings.json" ] || echo '{}' > "${HOME}/.claude/settings.json"
touch "${HOME}/.claude/CLAUDE.md"

# Executed config is read-only, so a session can't plant code that runs in
# later sessions or on the host. Built as positional params to stay quoted.
set --
for config_path in settings.json CLAUDE.md hooks skills agents commands rules output-styles; do
  case "$config_path" in
    *.*) ;;
    *) mkdir -p "${HOME}/.claude/${config_path}" ;;
  esac
  set -- "$@" --mount "type=bind,source=${HOME}/.claude/${config_path},target=/home/claudine/.claude/${config_path},readonly"
done
# Git hooks and config (core.hooksPath, core.fsmonitor) run on the host.
# A missing hooks dir wouldn't be mounted: the session could create it.
if [ -d "${PROJECT_DIR}/.git" ]; then
  mkdir -p "${PROJECT_DIR}/.git/hooks"
fi
for git_path in hooks config; do
  if [ -e "${PROJECT_DIR}/.git/${git_path}" ]; then
    set -- "$@" --mount "type=bind,source=${PROJECT_DIR}/.git/${git_path},target=${CONTAINER_WORKSPACE}/.git/${git_path},readonly"
  fi
done
# Podman rejects the tmpfs uid=/gid= options. Rootless podman also maps the
# host UID to root in the container, which can't read the host's 600 files
# (~/.claude.json): keep-id keeps the host UID, U=true chowns the tmpfs to it.
for tmpfs_dir in .cache .config .local/state; do
  if [ "$RUNTIME" = "podman" ]; then
    set -- "$@" --mount "type=tmpfs,destination=/home/claudine/${tmpfs_dir},tmpfs-mode=700,U=true"
  else
    set -- "$@" --tmpfs "/home/claudine/${tmpfs_dir}:uid=$(id -u),gid=$(id -g),mode=700"
  fi
done
if [ "$RUNTIME" = "podman" ]; then
  set -- "$@" --userns=keep-id
fi
# Optional extra variables (e.g. Jira), kept out of git.
if [ -f claudine.env ]; then
  set -- "$@" --env-file claudine.env
fi

# No --pid=host: with the host's UID it would expose every host process.
# TERM/COLORTERM/KITTY_WINDOW_ID enable OSC 52 clipboard copy.
# Updates come from --rebuild only: the container is thrown away on exit.
exec "$RUNTIME" run --rm -it \
  --name "$CONTAINER_NAME" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --pids-limit=4096 \
  --memory=8g \
  --read-only \
  --tmpfs /tmp \
  --mount "type=bind,source=${HOME}/.claude,target=/home/claudine/.claude" \
  --mount "type=bind,source=${HOME}/.claude.json,target=/home/claudine/.claude/.claude.json" \
  --mount "type=bind,source=${PROJECT_DIR},target=${CONTAINER_WORKSPACE}" \
  "$@" \
  --mount "type=bind,source=${CC_SOCKS_DIR},target=${CC_SOCKS_DIR}" \
  -e TERM="${TERM:-xterm-256color}" \
  -e KITTY_WINDOW_ID="${KITTY_WINDOW_ID:-}" \
  -e COLORTERM="${COLORTERM:-}" \
  -e CLAUDE_CONFIG_DIR=/home/claudine/.claude \
  -e DISABLE_AUTOUPDATER=1 \
  -w "$CONTAINER_WORKSPACE" \
  "$IMAGE_NAME" \
  claude
