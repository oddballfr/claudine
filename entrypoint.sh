#!/bin/sh
# ~/.local/bin/claude points to /tmp/claude-bin/claude: the rootfs is read-only
# and ~/.local/share/claude may be mounted from the host with other versions.
set -eu

versions_dir="${HOME}/.local/share/claude/versions"
target=$(ls "$versions_dir" 2>/dev/null | sort -V | tail -n1)
if [ -n "$target" ]; then
  target="${versions_dir}/${target}"
else
  target=/opt/claude/claude
fi

mkdir -m 700 /tmp/claude-bin
ln -sfn "$target" /tmp/claude-bin/claude

exec "$@"
