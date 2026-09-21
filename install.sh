#!/usr/bin/env bash
#
# install.sh - Connect Claude to your personal WhatsApp
#
# Installs the WhatsApp -> MCP -> Claude.ai stack onto an EXISTING Ubuntu/Debian
# droplet without disturbing whatever already runs there.
#
#   WhatsApp  <--whatsmeow-->  Go bridge (localhost only, SQLite)
#                                   ^
#                                   | REST on 127.0.0.1
#                              Python MCP server (stdio)
#                                   ^
#                                   | supergateway (stdio -> streamable HTTP)
#                              Caddy (HTTPS, secret path)  <--  claude.ai
#
# Usage:
#   sudo bash install.sh --check          # read-only preflight, changes nothing
#   sudo WA_HOST=wa.example.com ACME_EMAIL=you@example.com bash install.sh
#
# After install:
#   wa-login            # pair the phone, then start everything
#   cat /root/whatsapp-mcp-connector.txt   # the URL to paste into claude.ai
#
set -euo pipefail

# ---------------------------------------------------------------- config ----
WA_HOST="${WA_HOST:-}"                      # e.g. wa.example.com  (A record must already point here)
ACME_EMAIL="${ACME_EMAIL:-}"                # for Let's Encrypt expiry notices
MCP_SECRET="${MCP_SECRET:-}"                # leave empty to auto-generate
INSTALL_DIR="${INSTALL_DIR:-/opt/whatsapp-mcp}"
SVC_USER="${SVC_USER:-whatsapp}"
REPO_URL="https://github.com/lharries/whatsapp-mcp.git"
MIN_GO_MINOR=24                             # go.mod requires go 1.24.x
# -----------------------------------------------------------------------------

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

c_ok()   { printf '  \033[32m OK \033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
c_bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

port_free() { ! ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }
pick_port() { for p in "$@"; do port_free "$p" && { echo "$p"; return 0; }; done; return 1; }

# =============================================================== PREFLIGHT ===
step "Preflight"

[[ $EUID -eq 0 ]] || { c_bad "run as root (sudo)"; exit 1; }
c_ok "running as root"

. /etc/os-release 2>/dev/null || true
echo "     OS: ${PRETTY_NAME:-unknown}   kernel: $(uname -r)   arch: $(uname -m)"
case "$(uname -m)" in
  x86_64) GOARCH_SUFFIX=amd64 ;;
  aarch64|arm64) GOARCH_SUFFIX=arm64 ;;
  *) c_bad "unsupported architecture"; exit 1 ;;
esac

MEM_TOTAL_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
MEM_AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
DISK_FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
echo "     RAM: ${MEM_TOTAL_MB}MB total, ${MEM_AVAIL_MB}MB available, ${SWAP_MB}MB swap"
echo "     Disk free on /: ${DISK_FREE_MB}MB"
(( MEM_AVAIL_MB + SWAP_MB >= 1200 )) && c_ok "enough memory headroom to compile the Go bridge" \
  || c_warn "tight memory - the installer will add a 2GB swapfile before building"
(( DISK_FREE_MB >= 3000 )) && c_ok "enough disk (needs ~2.5GB for Go toolchain + build cache)" \
  || c_bad "need at least 3GB free on /"

step "What is already running on this droplet"
ss -ltnp 2>/dev/null | awk 'NR==1 || /LISTEN/' | sed 's/^/     /' || true

WEBSERVER=none
for s in caddy nginx apache2 httpd traefik; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then WEBSERVER=$s; fi
done
case "$WEBSERVER" in
  none)  c_ok "no web server on 80/443 - installer will install Caddy" ;;
  caddy) c_ok "Caddy already running - installer will append a site block to its Caddyfile" ;;
  *)     c_warn "$WEBSERVER holds 80/443 - installer will SKIP Caddy and print a $WEBSERVER snippet for you to paste" ;;
esac

if docker info >/dev/null 2>&1; then
  c_warn "Docker is running - port 8080 is frequently taken; installer picks a free port automatically"
fi

BRIDGE_PORT="${BRIDGE_PORT:-$(pick_port 8090 8091 8092 8093 8094 || true)}"
GW_PORT="${GW_PORT:-$(pick_port 3005 3006 3007 3008 || true)}"
[[ -n "$BRIDGE_PORT" && -n "$GW_PORT" ]] || { c_bad "could not find free ports"; exit 1; }
c_ok "will use 127.0.0.1:${BRIDGE_PORT} (bridge REST) and 127.0.0.1:${GW_PORT} (supergateway)"

if command -v go >/dev/null 2>&1; then
  GO_MINOR=$(go version | sed -n 's/.*go1\.\([0-9]*\).*/\1/p')
  (( ${GO_MINOR:-0} >= MIN_GO_MINOR )) \
    && c_ok "go $(go version | awk '{print $3}') is new enough" \
    || c_warn "go $(go version | awk '{print $3}') is too old (need 1.${MIN_GO_MINOR}+) - installer puts a current Go in /usr/local/go and leaves your existing one alone"
else
  c_warn "no Go installed - installer will add one at /usr/local/go"
fi

if command -v node >/dev/null 2>&1; then
  NODE_MAJOR=$(node -v | sed 's/v\([0-9]*\).*/\1/')
  (( NODE_MAJOR >= 18 )) && c_ok "node $(node -v) is fine" || c_warn "node $(node -v) too old - will install Node 20"
else
  c_warn "no Node - will install Node 20"
fi

if [[ -n "$WA_HOST" ]]; then
  MY_IP=$(curl -fsS --max-time 8 https://api.ipify.org || echo "")
  HOST_IP=$(getent ahostsv4 "$WA_HOST" 2>/dev/null | awk 'NR==1{print $1}')
  echo "     droplet public IP: ${MY_IP:-unknown}    ${WA_HOST} resolves to: ${HOST_IP:-NXDOMAIN}"
  if [[ -n "$MY_IP" && "$MY_IP" == "$HOST_IP" ]]; then
    c_ok "DNS for ${WA_HOST} points here - Let's Encrypt will succeed"
  else
    c_bad "DNS mismatch. Create an A record: ${WA_HOST} -> ${MY_IP:-<this droplet IP>} and re-run."
    (( CHECK_ONLY )) || exit 1
  fi
else
  c_warn "WA_HOST not set (fine for --check; required for install)"
fi

if (( CHECK_ONLY )); then
  printf '\n\033[1mPreflight only - nothing was changed.\033[0m\n'
  printf 'Re-run without --check (and with WA_HOST / ACME_EMAIL set) to install.\n\n'
  exit 0
fi

[[ -n "$WA_HOST" ]]   || { c_bad "WA_HOST is required"; exit 1; }
[[ -n "$ACME_EMAIL" ]]|| { c_bad "ACME_EMAIL is required"; exit 1; }

# ================================================================= INSTALL ===
set -x

step "Swap (only if short on memory and none configured)"
if (( MEM_AVAIL_MB + SWAP_MB < 1200 )) && (( SWAP_MB == 0 )); then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

step "Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  git curl ca-certificates build-essential pkg-config \
  python3 python3-venv qrencode ffmpeg iproute2 debian-keyring debian-archive-keyring apt-transport-https

step "Go toolchain"
NEED_GO=1
if command -v go >/dev/null 2>&1; then
  GO_MINOR=$(go version | sed -n 's/.*go1\.\([0-9]*\).*/\1/p')
  (( ${GO_MINOR:-0} >= MIN_GO_MINOR )) && NEED_GO=0
fi
if (( NEED_GO )); then
  GOVER=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
  curl -fsSL "https://go.dev/dl/${GOVER}.linux-${GOARCH_SUFFIX}.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
  export PATH="/usr/local/go/bin:$PATH"
fi
go version

step "Node 20 + supergateway"
if ! command -v node >/dev/null 2>&1 || (( $(node -v | sed 's/v\([0-9]*\).*/\1/') < 18 )); then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
npm install -g supergateway
SUPERGATEWAY_BIN="$(command -v supergateway)"

step "uv (Python package manager)"
curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
UV_BIN=/usr/local/bin/uv
"$UV_BIN" --version

step "Service account"
id -u "$SVC_USER" >/dev/null 2>&1 || useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SVC_USER"

step "Clone the WhatsApp MCP repo"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

step "Patch the bridge: bind REST to loopback, use a free port, save the QR string locally"
python3 - "$INSTALL_DIR/whatsapp-bridge/main.go" "$BRIDGE_PORT" <<'PY'
import sys, pathlib
p, port = pathlib.Path(sys.argv[1]), sys.argv[2]
s = p.read_text()

def swap(old, new, why):
    global s
    if new in s:
        print(f"  already patched: {why}"); return
    assert old in s, f"could not find anchor for: {why}"
    s = s.replace(old, new, 1)
    print(f"  patched: {why}")

# 1. never listen on a public interface
swap('serverAddr := fmt.Sprintf(":%d", port)',
     'serverAddr := fmt.Sprintf("127.0.0.1:%d", port)',
     "REST API binds to 127.0.0.1 only")

# 2. move off the default port if something else has it
swap('startRESTServer(client, messageStore, 8080)',
     f'startRESTServer(client, messageStore, {port})',
     f"REST API port -> {port}")

# 3. also write the raw QR payload to store/qr.txt so wa-login can render it big
swap('\t\t\t\tfmt.Println("\\nScan this QR code with your WhatsApp app:")',
     '\t\t\t\t_ = os.WriteFile("store/qr.txt", []byte(evt.Code), 0600)\n'
     '\t\t\t\tfmt.Println("\\nScan this QR code with your WhatsApp app:")',
     "write store/qr.txt for wa-login")

# 4-8. Newer whatsmeow (needed - see the build step) added a leading
# context.Context to these calls. Without these the build fails with
# 'not enough arguments in call to ...'.
for old, new, why in [
    ('client.Download(downloader)',
     'client.Download(context.Background(), downloader)', 'Download takes ctx'),
    ('sqlstore.New("sqlite3"',
     'sqlstore.New(context.Background(), "sqlite3"', 'sqlstore.New takes ctx'),
    ('container.GetFirstDevice()',
     'container.GetFirstDevice(context.Background())', 'GetFirstDevice takes ctx'),
    ('client.GetGroupInfo(jid)',
     'client.GetGroupInfo(context.Background(), jid)', 'GetGroupInfo takes ctx'),
    ('client.Store.Contacts.GetContact(jid)',
     'client.Store.Contacts.GetContact(context.Background(), jid)', 'GetContact takes ctx'),
]:
    swap(old, new, why)

p.write_text(s)
PY

sed -i "s|WHATSAPP_API_BASE_URL = \"http://localhost:8080/api\"|WHATSAPP_API_BASE_URL = \"http://127.0.0.1:${BRIDGE_PORT}/api\"|" \
  "$INSTALL_DIR/whatsapp-mcp-server/whatsapp.py"
grep -n 'WHATSAPP_API_BASE_URL' "$INSTALL_DIR/whatsapp-mcp-server/whatsapp.py"

step "Patch main.py: drop return annotations on the tool functions"
# Latent bug in the repo, exposed by any modern mcp SDK. whatsapp.py's
# list_messages is annotated '-> List[Message]' but actually RETURNS A STRING
# (format_messages_list), and main.py declares the tool '-> List[Dict[str, Any]]'.
# mcp 1.6.0 ignored return annotations. Modern FastMCP derives an outputSchema
# from them and validates, so every call fails with the server returning a plain
# string where a structured list is expected. Removing the annotations restores
# unstructured text output, which is what these tools actually produce.
cd "$INSTALL_DIR/whatsapp-mcp-server"
sed -i 's|) -> List\[Dict\[str, Any\]\]:|):|' main.py
sed -i 's|) -> Dict\[str, Any\]:|):|' main.py
sed -i 's|) -> str:|):|' main.py
if grep -q '\-> ' main.py; then
  c_warn "main.py still has return annotations - check these by hand:"
  grep -n '\-> ' main.py
else
  c_ok "all tool return annotations removed"
fi
python3 -m py_compile main.py && echo "  main.py compiles"

step "Build the Go bridge against a CURRENT whatsmeow"
# The repo pins whatsmeow to a March 2025 commit. WhatsApp rejects clients that
# stale: the socket closes with 'close 1006 (abnormal closure)' about two seconds
# in and no QR is ever issued. So we take the current release. The API drift that
# causes is handled by the context patches applied above.
# safe.directory: the repo may already be chowned to $SVC_USER, and git refuses to
# read a repo it does not own, which makes go build die with 'error obtaining VCS
# status: exit status 128'. -buildvcs=false skips the stamping entirely.
git config --global --add safe.directory "$INSTALL_DIR" 2>/dev/null || true
cd "$INSTALL_DIR/whatsapp-bridge"
export PATH="/usr/local/go/bin:$PATH"
go get go.mau.fi/whatsmeow@latest
go mod tidy
CGO_ENABLED=1 go build -buildvcs=false -o whatsapp-bridge .
go version -m ./whatsapp-bridge | grep whatsmeow
ls -l "$INSTALL_DIR/whatsapp-bridge/whatsapp-bridge"

step "Install the Python MCP server dependencies"
# The repo's uv.lock pins mcp 1.6.0, which only speaks MCP protocol 2024-11-05.
# claude.ai sends Mcp-Protocol-Version: 2025-11-25 and refuses a 2024 reply, so
# the connector fails with "Couldn't reach". Take the newest 1.x.
# Do NOT go to 2.x: it renames FastMCP to MCPServer and main.py is v1 code.
cd "$INSTALL_DIR/whatsapp-mcp-server"
HOME="$INSTALL_DIR" "$UV_BIN" sync
HOME="$INSTALL_DIR" "$UV_BIN" add 'mcp[cli]<2'
HOME="$INSTALL_DIR" "$UV_BIN" pip list 2>/dev/null | grep -i '^mcp' || true

step "Permissions"
mkdir -p "$INSTALL_DIR/whatsapp-bridge/store"
chown -R "$SVC_USER":"$SVC_USER" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR/whatsapp-bridge/store"

step "systemd units"
cat > /etc/systemd/system/whatsapp-bridge.service <<EOF
[Unit]
Description=WhatsApp Bridge (whatsmeow -> SQLite + loopback REST)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${INSTALL_DIR}/whatsapp-bridge
Environment=HOME=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/whatsapp-bridge/whatsapp-bridge
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/whatsapp-mcp.service <<EOF
[Unit]
Description=WhatsApp MCP server exposed over Streamable HTTP
After=whatsapp-bridge.service
Requires=whatsapp-bridge.service

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${INSTALL_DIR}/whatsapp-mcp-server
Environment=HOME=${INSTALL_DIR}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=${SUPERGATEWAY_BIN} \\
  --port ${GW_PORT} \\
  --outputTransport streamableHttp \\
  --streamableHttpPath /mcp \\
  --healthEndpoint /healthz \\
  --cors \\
  --stdio "${UV_BIN} run --directory ${INSTALL_DIR}/whatsapp-mcp-server python main.py"
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

step "HTTPS front door"
[[ -n "$MCP_SECRET" ]] || MCP_SECRET="$(openssl rand -hex 32)"
CONNECTOR_URL="https://${WA_HOST}/s/${MCP_SECRET}/mcp"

CADDY_BLOCK=$(cat <<EOF

# --- whatsapp-mcp (added by install.sh) ---
${WA_HOST} {
	tls ${ACME_EMAIL}

	# No 'encode' here on purpose: gzip/zstd buffering breaks MCP's
	# streaming (SSE) responses.

	# The secret path is the credential (a capability URL). claude.ai's connector
	# dialog does offer request headers, but it does NOT attach them to the probes
	# it makes while ADDING a connector - verified in access logs - so a server
	# that rejects unauthenticated requests never gets past setup. Worse, a 401/403
	# makes claude.ai assume OAuth and go hunting for /.well-known/oauth-* and
	# /register, failing with "Couldn't register with the sign-in service".
	# Hence: secret in the path, and 404 (never 403) for everything else.
	handle_path /s/${MCP_SECRET}/* {
		reverse_proxy 127.0.0.1:${GW_PORT}
	}

	# Caddy sorts directives into a FIXED order regardless of written order, and
	# 'handle_path' sorts before 'respond', so this is the fallback. Do NOT use a
	# bare 'handle { }' here: 'handle' sorts BEFORE 'handle_path' and would swallow
	# every request, including the proxied ones.
	respond "not found" 404
}
# --- end whatsapp-mcp ---
EOF
)

if [[ "$WEBSERVER" == "nginx" || "$WEBSERVER" == "apache2" || "$WEBSERVER" == "httpd" || "$WEBSERVER" == "traefik" ]]; then
  set +x
  cat > /root/whatsapp-mcp-${WEBSERVER}-snippet.conf <<EOF
# ${WEBSERVER} already owns ports 80/443, so Caddy was NOT installed.
# Add this to your ${WEBSERVER} config, get a cert for ${WA_HOST}, and reload.
#
# nginx example (inside an existing server{} block with TLS for ${WA_HOST}):
#
#   location /s/${MCP_SECRET}/mcp {
#       proxy_pass         http://127.0.0.1:${GW_PORT}/mcp;
#       proxy_http_version 1.1;
#       proxy_set_header   Host \$host;
#       proxy_set_header   Connection "";
#       proxy_buffering    off;
#       proxy_read_timeout 3600s;
#       chunked_transfer_encoding on;
#   }
EOF
  echo "Wrote /root/whatsapp-mcp-${WEBSERVER}-snippet.conf - apply it manually."
  set -x
else
  if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y
    apt-get install -y caddy
  fi
  mkdir -p /etc/caddy
  touch /etc/caddy/Caddyfile
  if grep -q "whatsapp-mcp (added by" /etc/caddy/Caddyfile; then
    python3 - /etc/caddy/Caddyfile <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t = re.sub(r"\n# --- whatsapp-mcp \(added by.*?# --- end whatsapp-mcp ---\n", "\n", t, flags=re.S)
p.write_text(t)
PY
  fi
  printf '%s\n' "$CADDY_BLOCK" >> /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  systemctl enable --now caddy
  systemctl reload caddy || systemctl restart caddy
fi

step "Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp  || true
  ufw allow 443/tcp || true
  ufw status numbered
else
  echo "ufw not active - leaving the firewall alone (DigitalOcean cloud firewall may be in use)."
fi

step "SSH hardening (key-only)"
if grep -qE '^\s*PasswordAuthentication\s+yes' /etc/ssh/sshd_config 2>/dev/null; then
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
  sed -i 's/^\s*PasswordAuthentication\s\+yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  sshd -t && systemctl reload ssh || systemctl reload sshd || true
fi

step "wa-login helper"
set +x
cat > /usr/local/bin/wa-login <<EOF
#!/usr/bin/env bash
# Pair this server with your WhatsApp account, then start the services.
set -euo pipefail
DIR=${INSTALL_DIR}/whatsapp-bridge
SVC_USER=${SVC_USER}
EOF
cat >> /usr/local/bin/wa-login <<'EOF'

systemctl stop whatsapp-mcp whatsapp-bridge 2>/dev/null || true
rm -f "$DIR/store/qr.txt"
LOG=$(mktemp /tmp/wa-login.XXXXXX.log)

echo "Starting the bridge in pairing mode..."
runuser -u "$SVC_USER" -- env HOME="$(dirname "$DIR")" \
  bash -c "cd '$DIR' && exec ./whatsapp-bridge" >"$LOG" 2>&1 &
BRIDGE_PID=$!
trap 'kill $BRIDGE_PID 2>/dev/null || true' EXIT

LAST=""
for _ in $(seq 1 180); do
  if grep -qiE "Successfully connected and authenticated|Successfully paired" "$LOG"; then
    echo
    echo "Paired. Starting services..."
    kill $BRIDGE_PID 2>/dev/null || true
    sleep 2
    systemctl enable --now whatsapp-bridge whatsapp-mcp
    sleep 3
    systemctl --no-pager --lines=5 status whatsapp-bridge whatsapp-mcp || true
    echo
    cat /root/whatsapp-mcp-connector.txt 2>/dev/null || true
    exit 0
  fi
  if [[ -s "$DIR/store/qr.txt" ]]; then
    CODE=$(cat "$DIR/store/qr.txt")
    if [[ "$CODE" != "$LAST" ]]; then
      LAST="$CODE"
      clear
      echo "WhatsApp > Settings > Linked devices > Link a device, then scan:"
      echo
      qrencode -t ANSIUTF8 -m 1 <<<"$CODE"
      echo "(code refreshes every ~20s; this window updates on its own)"
    fi
  fi
  sleep 1
done

echo "Timed out waiting for the scan. Log: $LOG"
exit 1
EOF
chmod +x /usr/local/bin/wa-login

cat > /root/whatsapp-mcp-connector.txt <<EOF
WhatsApp MCP connector
======================
In claude.ai > Settings > Connectors > Add custom connector, enter:

  URL             ${CONNECTOR_URL}
  Authentication  No sign-in
  Request header  (none)

The URL IS the credential: anyone holding it can read and send your WhatsApp.
Keep it out of screenshots and shared docs. Header auth looks tempting in that
dialog but does not work here - see the comment in /etc/caddy/Caddyfile.

Host          ${WA_HOST}
Bridge REST   127.0.0.1:${BRIDGE_PORT}   (loopback only)
Gateway       127.0.0.1:${GW_PORT}       (loopback only)
Install dir   ${INSTALL_DIR}
Runs as       ${SVC_USER}
Message DB    ${INSTALL_DIR}/whatsapp-bridge/store/messages.db  (plain SQLite, unencrypted)

Commands
  wa-login                                   pair the phone / re-pair after a session drop
  systemctl status whatsapp-bridge whatsapp-mcp
  journalctl -u whatsapp-bridge -f
  curl -s https://${WA_HOST}/s/${MCP_SECRET}/healthz     should return ok

  Full MCP handshake check (should report protocolVersion 2025 or newer):
    curl -sS -X POST ${CONNECTOR_URL} \\
      -H 'Content-Type: application/json' \\
      -H 'Accept: application/json, text/event-stream' \\
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'

  To rotate the secret: change the /s/... path in /etc/caddy/Caddyfile, reload caddy,
  then delete and re-add the connector in claude.ai with the new URL.

Known failure modes
  QR never appears, socket closes with 1006  -> whatsmeow is stale; rebuild against @latest
  claude.ai says "Couldn't reach"            -> server replying protocol 2024-11-05; upgrade mcp (<2)
  "Couldn't register with the sign-in service" -> server returned 401/403; claude.ai
                                                  then tries OAuth. Answer 404 instead.
  404 on everything                          -> secret in the URL does not match the Caddyfile
  Catch-all wins for every path              -> directive ordering; 'handle' sorts before 'handle_path'
EOF
chmod 600 /root/whatsapp-mcp-connector.txt

printf '\n\033[1m=====================================================\033[0m\n'
printf '\033[1m Installed. Two things left:\033[0m\n\n'
printf '  1. Pair your phone:   \033[1mwa-login\033[0m\n'
printf '  2. Add the connector in claude.ai (No sign-in, no headers):\n\n     \033[1m%s\033[0m\n\n' "$CONNECTOR_URL"
printf ' (also saved to /root/whatsapp-mcp-connector.txt)\n'
printf '\033[1m=====================================================\033[0m\n\n'
