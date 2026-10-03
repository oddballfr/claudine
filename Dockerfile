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
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claudine/.local/bin:${PATH}"

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'path-exclude /usr/share/doc/*' > /etc/dpkg/dpkg.cfg.d/01-nodoc \
    && echo 'path-exclude /usr/share/man/*' >> /etc/dpkg/dpkg.cfg.d/01-nodoc

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

USER claudine
ENV PATH="/home/claudine/.local/bin:${PATH}"

CMD ["claude"]
