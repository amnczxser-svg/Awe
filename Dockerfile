# ─────────────────────────────────────────────────────────────────────────────
#  OpenCode server (blitz.cloud / Railway / any container host)
#
#  What changed compared to the first version:
#   • OpenCode is installed during the build, pinned — not on every start.
#     Cold starts after the platform puts the app to sleep no longer depend on
#     a runtime download, and the version no longer drifts.
#   • OpenCode 2 is served with `opencode serve`; 1.x still works via
#     `opencode web` (start.sh detects it). `opencode web` does not exist in 2.x
#     and exits instead of listening — a common "Starting…" hang.
#   • Only one HTTP port is exposed. SSH is opt-in, and reachable through
#     Tailscale (bundled, userspace mode — no NET_ADMIN, no /dev/net/tun).
#   • tini is PID 1, so SIGTERM reaches the children and restarts are clean.
#
#  Tailscale: blitz.cloud's own "Private network" toggle covers the HTTP
#  address only. To reach sshd, the container joins your tailnet itself and
#  forwards port 2222 with `tailscale serve --tcp`.
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04

ARG OPENCODE_VERSION=2.1.3
ARG TAILSCALE_VERSION=1.104.2
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/root \
    PROJECT_DIR=/workspace \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    PATH=/root/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       git \
       openssh-client \
       openssh-server \
       tar \
       tini \
  && rm -rf /var/lib/apt/lists/* \
  && ssh-keygen -A \
  && mkdir -p /run/sshd /app /workspace /var/lib/tailscale /var/run/tailscale

# OpenCode, pinned to a known version and checked right after installing.
RUN set -eux; \
    curl -fsSL https://opencode.ai/v2/install | bash -s -- --version "${OPENCODE_VERSION}" --no-modify-path; \
    /root/.opencode/bin/opencode --version

# Tailscale static binaries. tailscaled runs with --tun=userspace-networking,
# so it needs neither NET_ADMIN nor /dev/net/tun — both absent in a gVisor
# sandbox. Only amd64 and arm64 are published.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) ts_arch=amd64 ;; \
      arm64) ts_arch=arm64 ;; \
      *) echo "Tailscale: unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${ts_arch}.tgz" \
      | tar -xz -C /usr/local/bin \
          --strip-components=1 \
          "tailscale_${TAILSCALE_VERSION}_${ts_arch}/tailscale" \
          "tailscale_${TAILSCALE_VERSION}_${ts_arch}/tailscaled"; \
    tailscale version | head -1

WORKDIR /app
COPY start.sh /app/start.sh
RUN chmod 0755 /app/start.sh

# Everything OpenCode and Tailscale write here survives a restart or a new version.
VOLUME ["/root/.local/share/opencode", "/root/.config/opencode", "/workspace", "/var/lib/tailscale"]

WORKDIR /workspace

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT:-8080}"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]
