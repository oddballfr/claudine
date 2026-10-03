# claudine

## Rules

- **Security first**: never weaken the container's isolation (capabilities, mounts, read-only config, no `--pid=host`) for convenience. When security and features conflict, security wins.
- **Less is more**: minimal code, comments and docs. No speculative options, no dead code, no filler text.
