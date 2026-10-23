#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  OpenCode supervisor
#
#  Default: one HTTP port, taken from $PORT (blitz.cloud sends 8080).
#  Optional: SSH on 2222, reachable through Tailscale. Both opt-in.
#
#  Environment:
#    PORT                      port for the web UI            (default 8080)
#    OPENCODE_SERVER_USERNAME  basic-auth user               (default opencode)
#    OPENCODE_SERVER_PASSWORD  basic-auth password           (falls back to SSH_PASSWORD)
#    PROJECT_DIR               directory OpenCode starts in  (default /workspace)
#    OPENCODE_CORS             comma-separated allowed origins
#    OPENCODE_PRINT_LOGS       1 = forward server logs to stdout
#
#    ENABLE_SSH=1              also start sshd on SSH_PORT
#    SSH_USERNAME / SSH_PASSWORD / SSH_PORT
#
#    ENABLE_TAILSCALE=1        join your tailnet from inside the container
#    TS_AUTHKEY                tailnet auth key (tskey-auth-…, reusable)
#    TS_HOSTNAME               node name in the tailnet      (default opencode)
#    TS_STATE_DIR              node key + logs               (default /var/lib/tailscale)
#    TS_SOCKET                 tailscaled control socket      (default /var/run/tailscale/tailscaled.sock)
#    TS_SERVE_SSH=1            forward SSH_PORT to sshd over the tailnet
#    TS_SERVE_APP=1            also forward the web UI as raw TCP over the tailnet
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

APP_PORT="${PORT:-8080}"
SSH_PORT="${SSH_PORT:-2222}"
PROJECT_DIR="${PROJECT_DIR:-/workspace}"
ENABLE_SSH="${ENABLE_SSH:-0}"
ENABLE_TAILSCALE="${ENABLE_TAILSCALE:-0}"

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-opencode}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
TS_PORT="${TS_PORT:-41641}"
TS_SERVE_SSH="${TS_SERVE_SSH:-1}"
TS_SERVE_APP="${TS_SERVE_APP:-0}"

DATA_DIR="${OPENCODE_DATA_DIR:-/root/.local/share/opencode}"
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-/root/.config/opencode}"

log()  { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── OpenCode binary ──────────────────────────────────────
OC_BIN="${OC_BIN:-$(command -v opencode || true)}"
[ -n "$OC_BIN" ] && [ -x "$OC_BIN" ] \
  || fail "opencode is not installed. Build the image from this Dockerfile; it installs OpenCode at build time."

oc_version="$("$OC_BIN" --version 2>/dev/null | awk '{print $NF}')"
oc_version="${oc_version#v}"
oc_major="${oc_version%%.*}"
case "$oc_major" in ''|*[!0-9]*) oc_major=1 ;; esac
if [ "$oc_major" -ge 2 ]; then
  OC_SUBCOMMAND=serve      # OpenCode 2: `serve` is API + web UI
else
  OC_SUBCOMMAND=web        # OpenCode 1: `web` serves the UI
fi

# ── Auth ─────────────────────────────────────────────────
# A public address without a password means anyone can run commands in here.
: "${OPENCODE_SERVER_PASSWORD:=${SSH_PASSWORD:-}}"
generated_password=0
if [ -z "$OPENCODE_SERVER_PASSWORD" ]; then
  OPENCODE_SERVER_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  generated_password=1
fi
export OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-${SSH_USERNAME:-opencode}}"
export OPENCODE_SERVER_PASSWORD
export BROWSER=none DISPLAY=

# `opencode web` (1.x) tries to open a browser; make that a no-op.
if [ ! -x /usr/local/bin/xdg-open ]; then
  printf '#!/bin/bash\nexit 0\n' > /usr/local/bin/xdg-open
  chmod 0755 /usr/local/bin/xdg-open
fi

mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$PROJECT_DIR"

# ── Command line ─────────────────────────────────────────
oc_args=("$OC_SUBCOMMAND" --port "$APP_PORT" --hostname 0.0.0.0)
if [ -n "${OPENCODE_CORS:-}" ]; then
  IFS=', ' read -r -a origins <<< "$OPENCODE_CORS"
  for origin in "${origins[@]}"; do
    [ -n "$origin" ] && oc_args+=(--cors "$origin")
  done
fi
[ "${OPENCODE_PRINT_LOGS:-0}" = "1" ] && oc_args+=(--print-logs)

APP_PID=""
SSHD_PID=""
TAILSCALED_PID=""
TS_JOINED=0
TS_RETRY_AT=0

start_app() {
  ( cd "$PROJECT_DIR" 2>/dev/null || cd /; exec "$OC_BIN" "${oc_args[@]}" ) &
  APP_PID=$!
  log "[opencode] started (pid $APP_PID) on 0.0.0.0:$APP_PORT"
}

start_sshd() {
  mkdir -p /run/sshd
  [ -e /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >/dev/null 2>&1
  /usr/sbin/sshd -D -f /etc/ssh/sshd_config &
  SSHD_PID=$!
  sleep 1
  if kill -0 "$SSHD_PID" 2>/dev/null; then
    log "[sshd] started (pid $SSHD_PID) on :$SSH_PORT"
  else
    log "[sshd] failed to start — check /etc/ssh/sshd_config and the host keys"
    SSHD_PID=""
  fi
}

# ── Tailscale ────────────────────────────────────────────
ts() { tailscale --socket="$TS_SOCKET" "$@"; }

start_tailscaled() {
  mkdir -p "$TS_STATE_DIR" "$(dirname "$TS_SOCKET")"
  chmod 700 "$TS_STATE_DIR" 2>/dev/null
  tailscaled \
    --tun=userspace-networking \
    --state="$TS_STATE_DIR/tailscaled.state" \
    --socket="$TS_SOCKET" \
    --port="$TS_PORT" \
    >> "$TS_STATE_DIR/tailscaled.log" 2>&1 &
  TAILSCALED_PID=$!
  local i
  for i in $(seq 1 30); do
    [ -S "$TS_SOCKET" ] && { log "[tailscale] tailscaled started (pid $TAILSCALED_PID)"; return 0; }
    kill -0 "$TAILSCALED_PID" 2>/dev/null || break
    sleep 1
  done
  log "[tailscale] tailscaled did not come up — see $TS_STATE_DIR/tailscaled.log"
  return 1
}

tailscale_serve() {
  if [ "$TS_SERVE_SSH" = "1" ]; then
    if [ "$ENABLE_SSH" = "1" ]; then
      if ts serve --bg --tcp="$SSH_PORT" "tcp://127.0.0.1:$SSH_PORT" >/dev/null 2>&1; then
        log "[tailscale] ssh: ssh -p $SSH_PORT ${SSH_USERNAME:-root}@$TS_HOSTNAME"
      else
        log "[tailscale] could not forward port $SSH_PORT to sshd"
      fi
    else
      log "[tailscale] TS_SERVE_SSH=1 but ENABLE_SSH=0 — no sshd to forward"
    fi
  fi
  if [ "$TS_SERVE_APP" = "1" ]; then
    if ts serve --bg --tcp="$APP_PORT" "tcp://127.0.0.1:$APP_PORT" >/dev/null 2>&1; then
      log "[tailscale] web ui: http://$TS_HOSTNAME:$APP_PORT"
    else
      log "[tailscale] could not forward port $APP_PORT"
    fi
  fi
}

tailscale_join() {
  TS_JOINED=0
  if ts status >/dev/null 2>&1; then
    TS_JOINED=1
    log "[tailscale] already logged in (state in $TS_STATE_DIR)"
    tailscale_serve
    return 0
  fi
  if [ -z "$TS_AUTHKEY" ]; then
    log "[tailscale] TS_AUTHKEY is empty — not joining the tailnet"
    TS_RETRY_AT=$((SECONDS + 60))
    return 1
  fi
  if ts up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" \
            --accept-dns=false --timeout=30s >> "$TS_STATE_DIR/tailscaled.log" 2>&1; then
    TS_JOINED=1
    local ip
    ip="$(ts ip -4 2>/dev/null | head -1)"
    log "[tailscale] joined as ${TS_HOSTNAME}${ip:+ ($ip)}"
    tailscale_serve
  else
    log "[tailscale] join failed — retrying in 60s (see $TS_STATE_DIR/tailscaled.log)"
    TS_RETRY_AT=$((SECONDS + 60))
    return 1
  fi
}

# ── Optional SSH ─────────────────────────────────────────
if [ "$ENABLE_SSH" = "1" ]; then
  [ -x /usr/sbin/sshd ] || fail "ENABLE_SSH=1 but /usr/sbin/sshd is missing from the image"
  [ -n "${SSH_USERNAME:-}" ] || fail "ENABLE_SSH=1 requires SSH_USERNAME"
  [ -n "${SSH_PASSWORD:-}" ] || fail "ENABLE_SSH=1 requires SSH_PASSWORD"
  [[ "$SSH_USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || fail "SSH_USERNAME is invalid (lowercase letters, digits, _ or -)"
  cat > /etc/ssh/sshd_config <<SSHEOF
Port $SSH_PORT
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
UsePAM no
X11Forwarding no
PrintMotd no
Subsystem sftp /usr/lib/openssh/sftp-server
SSHEOF
  id "$SSH_USERNAME" >/dev/null 2>&1 || useradd -m -s /bin/bash "$SSH_USERNAME"
  echo "$SSH_USERNAME:$SSH_PASSWORD" | chpasswd
fi

if [ "$ENABLE_TAILSCALE" = "1" ] && { ! have tailscale || ! have tailscaled; }; then
  log "[tailscale] tailscale/tailscaled are not in the image — Tailscale disabled"
  ENABLE_TAILSCALE=0
fi

# ── Shutdown ─────────────────────────────────────────────
shutdown() {
  trap - TERM INT
  log "shutting down"
  for pid in "$APP_PID" "$SSHD_PID" "$TAILSCALED_PID"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done
  wait 2>/dev/null
  exit 0
}
trap shutdown TERM INT

# ── Go ───────────────────────────────────────────────────
log "────────────────────────────────"
log "  OpenCode  ${oc_version:-?} (opencode ${OC_SUBCOMMAND})"
log "  App port  : $APP_PORT"
log "  User      : $OPENCODE_SERVER_USERNAME"
log "  SSH       : $([ "$ENABLE_SSH" = 1 ] && echo "on :$SSH_PORT" || echo "off")"
log "  Tailscale : $([ "$ENABLE_TAILSCALE" = 1 ] && echo "on ($TS_HOSTNAME)" || echo "off")"
log "────────────────────────────────"
if [ "$generated_password" = "1" ]; then
  log "No OPENCODE_SERVER_PASSWORD set — generated one: $OPENCODE_SERVER_PASSWORD"
  log "Set OPENCODE_SERVER_PASSWORD in the app's Environment tab to keep it stable."
fi
if [ "$ENABLE_SSH" = "1" ] && [ "$ENABLE_TAILSCALE" != "1" ]; then
  log "Note: a hosted app routes HTTP only; set ENABLE_TAILSCALE=1 to reach sshd over your tailnet."
fi

start_app
[ "$ENABLE_SSH" = "1" ] && start_sshd
if [ "$ENABLE_TAILSCALE" = "1" ]; then
  start_tailscaled && tailscale_join
fi

# ── Watchdog ─────────────────────────────────────────────
app_failures=0
sshd_failures=0
while :; do
  sleep 5

  if ! kill -0 "$APP_PID" 2>/dev/null; then
    app_failures=$((app_failures + 1))
    delay=$((app_failures * 2))
    [ "$delay" -gt 30 ] && delay=30
    log "[opencode] exited — restarting in ${delay}s"
    sleep "$delay"
    start_app
  else
    app_failures=0
  fi

  if [ "$ENABLE_SSH" = "1" ] && { [ -z "$SSHD_PID" ] || ! kill -0 "$SSHD_PID" 2>/dev/null; }; then
    sshd_failures=$((sshd_failures + 1))
    delay=$((sshd_failures * 2))
    [ "$delay" -gt 60 ] && delay=60
    log "[sshd] exited — restarting in ${delay}s"
    sleep "$delay"
    start_sshd
  elif [ "$ENABLE_SSH" = "1" ]; then
    sshd_failures=0
  fi

  if [ "$ENABLE_TAILSCALE" = "1" ]; then
    if [ -z "$TAILSCALED_PID" ] || ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
      log "[tailscale] tailscaled exited — restarting"
      TS_JOINED=0
      start_tailscaled && tailscale_join
    elif [ "$TS_JOINED" != "1" ] && [ "$SECONDS" -ge "$TS_RETRY_AT" ]; then
      log "[tailscale] retrying join"
      tailscale_join
    fi
  fi
done
