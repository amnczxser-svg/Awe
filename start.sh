#!/bin/bash
# ─────────────────────────────────────────────
#  Railway · OpenCode + SSH  —  supervised startup
#  Ubuntu 24.04 · PID-based watchdog (no health-check polling)

# ── جایگزین start-bore.sh: ./start.sh restart-bore ──
# تونل‌ها رو می‌کُشه؛ واچ‌داگ داخل همین اسکریپت تا ۵ ثانیه بعد دوباره بالاشون میاره
if [ "$1" = "restart-bore" ]; then
  for f in /tmp/bore-ssh.pid /tmp/bore-app.pid; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  echo "bore tunnels killed — the watchdog will restart them within ~5s (see /tmp/bore-*.log)"
  exit 0
fi
# ─────────────────────────────────────────────

APP_PORT=${PORT:-8080}
SSH_PORT=2222
[ "$APP_PORT" = "$SSH_PORT" ] && APP_PORT=8080

# یه رمز برای همه — SSH و OpenCode هر دو از همین استفاده می‌کنن
# هر دو متغیر باید از Variables پلتفرم بیان؛ مقدار پیش‌فرض وجود نداره
if [ -z "${SSH_USERNAME:-}" ] || [ -z "${SSH_PASSWORD:-}" ]; then
  echo "❌ SSH_USERNAME and SSH_PASSWORD must both be set in the service Variables." >&2
  exit 1
fi
if ! [[ "$SSH_USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "❌ SSH_USERNAME is invalid (use lowercase letters, digits, _ or -)." >&2
  exit 1
fi
export OPENCODE_SERVER_USERNAME="$SSH_USERNAME"
export OPENCODE_SERVER_PASSWORD="$SSH_PASSWORD"

# PATH همیشه global — opencode بعد از نصب اینجاست
export PATH="$HOME/.opencode/bin:$PATH"

# جلوگیری از باز شدن مرورگر:
# ۱. fake xdg-open که هیچ کاری نمی‌کنه
mkdir -p /usr/local/bin
cat > /usr/local/bin/xdg-open << 'XDGEOF'
#!/bin/bash
# headless stub — silently ignore browser-open requests
exit 0
XDGEOF
chmod +x /usr/local/bin/xdg-open

# ۲. متغیرهای محیطی headless
export BROWSER=none
export DISPLAY=""

# ── Install OpenCode (once per container lifetime) ───
if ! command -v opencode >/dev/null 2>&1; then
  echo "📥 Installing OpenCode..."
  curl -fsSL https://opencode.ai/install | bash 2>&1 | grep -i "installed\|successfully\|error" || true
  echo "✓ OpenCode installed"
fi

# Persist across redeploys — mount a Railway Volume at this path
mkdir -p /root/.local/share/opencode

# ── SSH ──────────────────────────────────────
cat > /etc/ssh/sshd_config << SSHEOF
Port $SSH_PORT
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
UsePAM no
X11Forwarding no
PrintMotd no
Subsystem sftp /usr/lib/openssh/sftp-server
SSHEOF

# اگه یوزر root نبود، ساخته می‌شه
if [ "$SSH_USERNAME" != "root" ] && ! id "$SSH_USERNAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$SSH_USERNAME"
fi
echo "$SSH_USERNAME:$SSH_PASSWORD" | chpasswd

echo "════════════════════════════════"
echo "  OpenCode + SSH"
echo "  App port : $APP_PORT"
echo "  SSH port : $SSH_PORT"
echo "  SSH user : $SSH_USERNAME"
echo "  SSH pass : $SSH_PASSWORD"
echo "  OC  pass : $SSH_PASSWORD"
echo "════════════════════════════════"

# ── Service launcher helpers ─────────────────

start_sshd() {
  /usr/sbin/sshd -D -f /etc/ssh/sshd_config &
  SSHD_PID=$!
  echo "$(date -u +%T) [sshd]     started (pid $SSHD_PID)"
}

start_app() {
  opencode web --port "$APP_PORT" --hostname 0.0.0.0 &
  APP_PID=$!
  echo "$(date -u +%T) [opencode] started (pid $APP_PID)"
}

# ── Start both services ───────────────────────
start_sshd
start_app

# ── Install bore ──────────────────────────────
if ! command -v bore >/dev/null 2>&1; then
  echo "📦 Installing bore..."
  BORE_VERSION="v0.5.1"
  curl -fsSL "https://github.com/ekzhang/bore/releases/download/${BORE_VERSION}/bore-${BORE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    -o /tmp/bore.tar.gz && \
  tar xzf /tmp/bore.tar.gz -C /usr/local/bin bore && \
  rm /tmp/bore.tar.gz
  echo "✓ bore installed: $(bore --version)"
fi

BORE_SERVER=${BORE_SERVER:-bore.pub}
BORE_PID_SSH=""
BORE_PID_APP=""

start_bore() {
  local local_port=$1
  local label=$2
  local pid_var="BORE_PID_${label}"
  local logfile="/tmp/bore-${label,,}.log"

  # NO_COLOR: جلوگیری از کدهای رنگی ANSI توی لاگ (که grep رو خراب می‌کردن)
  NO_COLOR=1 bore local "$local_port" --to "$BORE_SERVER" > "$logfile" 2>&1 &
  local pid=$!
  printf -v "$pid_var" '%s' "$pid"

  local remote_port="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || break
    remote_port=$(grep -oP 'remote_port\D*\K[0-9]+' "$logfile" | head -1)
    [ -n "$remote_port" ] && break
  done

  if [ -z "$remote_port" ]; then
    echo "$(date -u +%T) [bore:$label]  FAILED to get port — will retry"
    kill "$pid" 2>/dev/null
    printf -v "$pid_var" ''   # PID خالی => واچ‌داگ ریتراش می‌کنه
    return 1
  fi

  echo "$pid" > "/tmp/bore-${label,,}.pid"
  echo "$(date -u +%T) [bore:$label]  local $local_port -> $BORE_SERVER:$remote_port (pid $pid)"
}

start_bore "$SSH_PORT" "SSH"
start_bore "$APP_PORT" "APP"

# ── PID-only watchdog ─────────────────────────
while true; do
  sleep 5

  if ! kill -0 "$SSHD_PID" 2>/dev/null; then
    echo "$(date -u +%T) [sshd]     exited — restarting"
    start_sshd
  fi

  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "$(date -u +%T) [opencode] exited — restarting"
    start_app
  fi

  if [ -z "$BORE_PID_SSH" ] || ! kill -0 "$BORE_PID_SSH" 2>/dev/null; then
    echo "$(date -u +%T) [bore:SSH]  exited — restarting"
    start_bore "$SSH_PORT" "SSH"
  fi

  if [ -z "$BORE_PID_APP" ] || ! kill -0 "$BORE_PID_APP" 2>/dev/null; then
    echo "$(date -u +%T) [bore:APP]  exited — restarting"
    start_bore "$APP_PORT" "APP"
  fi
done
