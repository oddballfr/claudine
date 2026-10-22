# syntax=docker/dockerfile:1
FROM debian:trixie-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Fail "curl | bash" if curl fails.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Build-only tools: only what they produce reaches the final image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates

# Host UID/GID (from run.sh) so bind-mounted files keep their owner.
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid "$USER_GID" claudine \
    && useradd --create-home --shell /bin/bash --uid "$USER_UID" --gid "$USER_GID" claudine
USER claudine

# CLAUDE_UPDATE_DATE busts this layer's cache so a rebuild fetches the latest claude.
ARG CLAUDE_UPDATE_DATE=unset
# Temporary ~/.curlrc bounds and retries the downloads made inside install.sh.
RUN printf '%s\n' 'retry = 3' 'retry-all-errors' 'connect-timeout = 15' 'max-time = 120' > ~/.curlrc \
    && curl -fsSL https://claude.ai/install.sh -o /tmp/install.sh \
    && timeout 300 bash /tmp/install.sh \
    && rm -f /tmp/install.sh ~/.curlrc
ENV PATH="/home/claudine/.local/bin:${PATH}"

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'path-exclude /usr/share/doc/*' > /etc/dpkg/dpkg.cfg.d/01-nodoc \
    && echo 'path-exclude /usr/share/man/*' >> /etc/dpkg/dpkg.cfg.d/01-nodoc

# APT_UPDATE_DATE busts this layer's cache so a rebuild gets Debian security fixes.
ARG APT_UPDATE_DATE=unset
# upgrade applies Debian security fixes not yet in the base image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    ripgrep \
    jq \
    yq \
    shellcheck \
    yamllint \
    flake8 \
    git \
    ca-certificates \
    python3 \
    curl

ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid "$USER_GID" claudine \
    && useradd --create-home --shell /bin/bash --uid "$USER_UID" --gid "$USER_GID" claudine

COPY --from=builder --chown=claudine:claudine /home/claudine/.local /home/claudine/.local
# Image copy used when the versions dir is empty (e.g. hidden by a host mount).
# The build-time symlink would break once that version is gone: point it to /tmp.
RUN install -D -m 755 "$(readlink -f /home/claudine/.local/bin/claude)" /opt/claude/claude \
    && ln -sfn /tmp/claude-bin/claude /home/claudine/.local/bin/claude
COPY --chmod=755 entrypoint.sh /usr/local/bin/claudine-entrypoint

USER claudine
ENV PATH="/home/claudine/.local/bin:${PATH}"

ENTRYPOINT ["/usr/local/bin/claudine-entrypoint"]
CMD ["claude"]
