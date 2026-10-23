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
#   • Only one HTTP port is exposed. SSH is opt-in, and reachable through a
#     bore tunnel (bundled) when the host routes HTTP only.
#   • tini is PID 1, so SIGTERM reaches the children and restarts are clean.
#
#  bore: hosts that route HTTP only cannot expose port 2222 at all. With
#  ENABLE_BORE=1 the container opens an outbound tunnel to bore.pub and prints
#  the public port to connect to: ssh -p <port> root@bore.pub
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04

ARG OPENCODE_VERSION=2.1.3
ARG BORE_VERSION=0.6.0
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
  && mkdir -p /run/sshd /app /workspace

# OpenCode, pinned to a known version and checked right after installing.
RUN set -eux; \
    curl -fsSL https://opencode.ai/v2/install | bash -s -- --version "${OPENCODE_VERSION}" --no-modify-path; \
    /root/.opencode/bin/opencode --version

# bore: a tiny outbound-only tunnel, so sshd can be reached even where the host
# proxies HTTP only. Installed at build time so start.sh never downloads at boot.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) bore_arch=x86_64-unknown-linux-musl ;; \
      arm64) bore_arch=aarch64-unknown-linux-musl ;; \
      *) echo "bore: unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/bore-v${BORE_VERSION}-${bore_arch}.tar.gz" \
      | tar -xz -C /usr/local/bin bore; \
    bore --version

WORKDIR /app
COPY start.sh /app/start.sh
RUN chmod 0755 /app/start.sh

# Everything OpenCode writes under HOME (/root) and the project folder survive a
# restart or a new version.
VOLUME ["/root", "/workspace"]

WORKDIR /workspace

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT:-8080}"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]
