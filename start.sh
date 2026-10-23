#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  OpenCode supervisor
#
#  Default: one HTTP port, taken from $PORT (blitz.cloud sends 8080).
#  Optional: SSH on 2222, reachable through a bore tunnel. Everything opt-in.
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
#    ENABLE_BORE=1             expose SSH_PORT through a bore tunnel; the public
#                              address is printed to the log
#    BORE_SERVER               tunnel server                 (default bore.pub)
#    BORE_SECRET               optional secret the server may require
#    BORE_REMOTE_PORT          preferred fixed public port (default: random).
#                              If the preferred port is taken bore picks a free
#                              one and the actually-used port is saved back here
#                              (via $BORE_PORT_FILE) so later restarts reuse it.
#    BORE_PORT_FILE            where the last-used port is kept
#                              (default $PROJECT_DIR/.bore_remote_port)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

APP_PORT="${PORT:-8080}"
SSH_PORT="${SSH_PORT:-2222}"
PROJECT_DIR="${PROJECT_DIR:-/workspace}"
ENABLE_SSH="${ENABLE_SSH:-0}"
ENABLE_BORE="${ENABLE_BORE:-0}"

BORE_BIN="${BORE_BIN:-bore}"
BORE_SERVER="${BORE_SERVER:-bore.pub}"
BORE_SECRET="${BORE_SECRET:-}"
BORE_REMOTE_PORT="${BORE_REMOTE_PORT:-}"
BORE_PORT_FILE="${BORE_PORT_FILE:-${PROJECT_DIR}/.bore_remote_port}"
# Optional: if set, the script self-syncs BORE_REMOTE_PORT on the platform when
# it changes, so the app's Environment tab always shows the port actually in use.
BLITZ_API_KEY="${BLITZ_API_KEY:-}"
BLITZ_APP="${BLITZ_APP:-}"

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
BORE_PID=""

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

# ── bore tunnel ──────────────────────────────────────────
# A host that routes HTTP only cannot publish port 2222. bore holds an outbound
# connection to a public server and gives back a port on it, so
# `ssh -p <port> root@bore.pub` works from anywhere, with no tailnet.
bore_public_address() {
  sed -e 's/\x1b\[[0-9;]*m//g' "${1:-/tmp/bore.log}" 2>/dev/null \
    | grep -oE 'listening at [^ ]+:[0-9]+' | tail -1 | awk '{print $3}'
}

# Push the actual port back to the platform's BORE_REMOTE_PORT setting so the
# app's Environment tab stays in sync even after a fallback to a random port.
bore_sync_platform_port() {
  local port="$1"
  [ -n "$BLITZ_API_KEY" ] && [ -n "$BLITZ_APP" ] || return 0
  curl -sS --max-time 15 -X POST "https://mcp.blitz.cloud/cli" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer ${BLITZ_API_KEY}" \
    -H "Mcp-Protocol-Version: 2025-06-18" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"env_set\",\"arguments\":{\"app\":\"${BLITZ_APP}\",\"name\":\"BORE_REMOTE_PORT\",\"value\":\"${port}\"}}}" \
    >/dev/null 2>&1
}

start_bore() {
  local logfile=/tmp/bore.log addr i actual requested
  local args=(local "$SSH_PORT" --local-host 127.0.0.1 --to "$BORE_SERVER")
  [ -n "$BORE_SECRET" ] && args+=(--secret "$BORE_SECRET")

  # Preferred port: env override, else the last one we actually got (persisted),
  # else leave it empty to let bore pick any free port.
  requested="$BORE_REMOTE_PORT"
  if [ -z "$requested" ] && [ -n "$BORE_PORT_FILE" ] && [ -f "$BORE_PORT_FILE" ]; then
    requested="$(cat "$BORE_PORT_FILE" 2>/dev/null | tr -dc '0-9')"
  fi

  # Try the requested fixed port first.
  if [ -n "$requested" ]; then
    : > "$logfile"
    NO_COLOR=1 "$BORE_BIN" "${args[@]}" --port "$requested" >> "$logfile" 2>&1 &
    BORE_PID=$!
    for i in $(seq 1 8); do
      addr="$(bore_public_address "$logfile")"
      [ -n "$addr" ] && break
      kill -0 "$BORE_PID" 2>/dev/null || break
      sleep 1
    done
    if [ -n "$addr" ] && [ "${addr##*:}" = "$requested" ]; then
      actual="$requested"
    else
      log "[bore] requested port $requested is not free — asking for any free port instead"
      kill "$BORE_PID" 2>/dev/null
      BORE_PID=""
      # "No" a stale requested port so the random path below does not redo this.
      requested=""
    fi
  fi

  # Random port fallback (no preferred port, or the preferred one was taken).
  if [ -z "$requested" ]; then
    : > "$logfile"
    NO_COLOR=1 "$BORE_BIN" "${args[@]}" >> "$logfile" 2>&1 &
    BORE_PID=$!
    for i in $(seq 1 20); do
      addr="$(bore_public_address "$logfile")"
      [ -n "$addr" ] && break
      kill -0 "$BORE_PID" 2>/dev/null || break
      sleep 1
    done
  fi

  if [ -n "$addr" ]; then
    actual="${addr##*:}"
    # Keep the port we actually got so later restarts reuse the same one while it
    # stays free, instead of getting a new random port every time.
    if [ "$actual" != "$BORE_REMOTE_PORT" ]; then
      BORE_REMOTE_PORT="$actual"
      if [ -n "$BORE_PORT_FILE" ]; then
        mkdir -p "$(dirname "$BORE_PORT_FILE")" 2>/dev/null
        printf '%s\n' "$actual" > "$BORE_PORT_FILE" 2>/dev/null
      fi
      bore_sync_platform_port "$actual"
    fi
    log "[bore] ssh: ssh -p $actual ${SSH_USERNAME:-root}@${addr%:*}"
    log "[bore] using fixed port $actual (kept across restarts while it stays free)"
    return 0
  fi

  log "[bore] could not open a tunnel to $BORE_SERVER — see $logfile"
  BORE_PID=""
  return 1
}

# ── Optional SSH ─────────────────────────────────────────
if [ "$ENABLE_SSH" = "1" ]; then
  [ -x /usr/sbin/sshd ] || fail "ENABLE_SSH=1 but /usr/sbin/sshd is missing from the image"
  if [ -z "${SSH_USERNAME:-}" ] || [ -z "${SSH_PASSWORD:-}" ]; then
    # Credentials are intentionally left empty for the owner to fill in.
    # Until then, keep the app up but leave SSH (and the bore tunnel that needs
    # it) off instead of crashing.
    log "SSH_USERNAME/SSH_PASSWORD are empty — SSH disabled; set them to enable sshd and the bore tunnel"
    ENABLE_SSH=0
    ENABLE_BORE=0
  else
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
fi

if [ "$ENABLE_BORE" = "1" ] && ! have "$BORE_BIN"; then
  log "[bore] $BORE_BIN is not in the image — bore disabled"
  ENABLE_BORE=0
fi
if [ "$ENABLE_BORE" = "1" ] && [ "$ENABLE_SSH" != "1" ]; then
  log "[bore] ENABLE_BORE=1 needs ENABLE_SSH=1 — there is nothing to forward"
  ENABLE_BORE=0
fi

# ── Shutdown ─────────────────────────────────────────────
shutdown() {
  trap - TERM INT
  log "shutting down"
  for pid in "$APP_PID" "$SSHD_PID" "$BORE_PID"; do
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
log "  Tunnel    : $([ "$ENABLE_BORE" = 1 ] && echo "on ($BORE_SERVER)" || echo "off")"
log "────────────────────────────────"
if [ "$generated_password" = "1" ]; then
  log "No OPENCODE_SERVER_PASSWORD set — generated one: $OPENCODE_SERVER_PASSWORD"
  log "Set OPENCODE_SERVER_PASSWORD in the app's Environment tab to keep it stable."
fi
if [ "$ENABLE_SSH" = "1" ] && [ "$ENABLE_BORE" != "1" ]; then
  log "Note: a hosted app routes HTTP only; set ENABLE_BORE=1 to reach sshd from outside."
fi

start_app
[ "$ENABLE_SSH" = "1" ] && start_sshd
[ "$ENABLE_BORE" = "1" ] && start_bore

# ── Watchdog ─────────────────────────────────────────────
app_failures=0
sshd_failures=0
bore_failures=0
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

  if [ "$ENABLE_BORE" = "1" ] && { [ -z "$BORE_PID" ] || ! kill -0 "$BORE_PID" 2>/dev/null; }; then
    bore_failures=$((bore_failures + 1))
    delay=$((bore_failures * 5))
    [ "$delay" -gt 60 ] && delay=60
    log "[bore] tunnel exited — reopening in ${delay}s"
    sleep "$delay"
    start_bore
  elif [ "$ENABLE_BORE" = "1" ]; then
    bore_failures=0
  fi
done
