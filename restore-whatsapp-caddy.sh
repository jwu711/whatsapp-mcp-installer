#!/usr/bin/env bash
#
# restore-whatsapp-caddy.sh
#
# Re-adds the WhatsApp MCP site block to Caddy. APPENDS ONLY: every other site
# block already in the Caddyfile is left exactly as it is, so whatever else this
# server is hosting keeps working.
#
# Use when Claude cannot reach WhatsApp and diagnose.sh reports
# "No WhatsApp site block found in /etc/caddy/Caddyfile" while the gateway is
# still answering on loopback - i.e. the stack is fine and only the front door
# is missing. That happens when another installer rewrites the Caddyfile
# wholesale instead of appending to it.
#
# Usage (on the server):
#   sudo WA_HOST=wa.example.com ACME_EMAIL=you@example.com bash restore-whatsapp-caddy.sh
#
# Optional: MCP_SECRET=<existing secret>  to keep an existing connector URL
#           working instead of generating a new one. STRONGLY preferred when
#           a connector already exists: it avoids re-adding it in claude.ai.
#
set -euo pipefail

WA_HOST="${WA_HOST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
MCP_SECRET="${MCP_SECRET:-}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
UNIT=/etc/systemd/system/whatsapp-mcp.service

ok()  { printf '  \033[32m OK \033[0m %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
step(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]]      || { bad "run as root (sudo)"; exit 1; }
[[ -n "$WA_HOST" ]]    || { bad "WA_HOST is required"; exit 1; }
[[ -n "$ACME_EMAIL" ]] || { bad "ACME_EMAIL is required"; exit 1; }
[[ -f "$CADDYFILE" ]]  || { bad "no Caddyfile at $CADDYFILE"; exit 1; }

step "Preflight"

# 1. the gateway must actually be up, or Caddy would front a dead service
GW=$(grep -oE '\-\-port [0-9]+' "$UNIT" 2>/dev/null | head -1 | awk '{print $2}')
GW="${GW:-3005}"
L=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$GW/healthz" 2>/dev/null || true)
if [[ "$L" == "200" ]]; then
  ok "MCP gateway answering on 127.0.0.1:$GW"
else
  bad "MCP gateway NOT answering on 127.0.0.1:$GW (got '${L:-nothing}')"
  echo "     Fix the service first: systemctl status whatsapp-mcp"
  exit 1
fi

# 2. DNS must point here or Let's Encrypt will fail and Caddy will retry-loop
MY_IP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
HOST_IP=$(getent ahostsv4 "$WA_HOST" 2>/dev/null | awk 'NR==1{print $1}')
echo "     this droplet: ${MY_IP:-unknown}    $WA_HOST -> ${HOST_IP:-NXDOMAIN}"
if [[ -n "$MY_IP" && "$MY_IP" == "$HOST_IP" ]]; then
  ok "DNS points here"
else
  bad "DNS mismatch - point $WA_HOST at ${MY_IP:-this droplet} first"
  exit 1
fi

# 3. show what is already in the file, so nothing is clobbered silently
echo "     existing site blocks in $CADDYFILE:"
grep -oE '^[A-Za-z0-9:][A-Za-z0-9.:-]* \{' "$CADDYFILE" | sed 's/ {//' | sed 's/^/       /'

step "Backup"
BACKUP="$CADDYFILE.bak.$(date +%s)"
cp "$CADDYFILE" "$BACKUP"
ok "saved $BACKUP"
echo "     to undo:  cp '$BACKUP' '$CADDYFILE' && systemctl reload caddy"

step "Build the site block"
REUSED=1
[[ -n "$MCP_SECRET" ]] || { MCP_SECRET="$(openssl rand -hex 32)"; REUSED=0; }
CONNECTOR_URL="https://${WA_HOST}/s/${MCP_SECRET}/mcp"

# Drop any previous block of OURS (marked), leaving everyone else's alone.
if grep -q "whatsapp-mcp (added by" "$CADDYFILE"; then
  python3 -I - "$CADDYFILE" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t = re.sub(r"\n?# --- whatsapp-mcp \(added by.*?# --- end whatsapp-mcp ---\n", "\n", t, flags=re.S)
p.write_text(t)
print("  removed the previous whatsapp-mcp block")
PY
fi

cat >> "$CADDYFILE" <<EOF

# --- whatsapp-mcp (added by restore-whatsapp-caddy.sh) ---
${WA_HOST} {
	tls ${ACME_EMAIL}

	# No 'encode': gzip/zstd buffering breaks MCP's streaming (SSE) responses.

	# The secret path is the credential. claude.ai does NOT send request headers
	# on the probe it makes while ADDING a connector, so header auth cannot get
	# through setup. And a 401/403 makes claude.ai assume OAuth and fail with
	# "Couldn't register with the sign-in service" - hence 404 below, never 403.
	handle_path /s/${MCP_SECRET}/* {
		reverse_proxy 127.0.0.1:${GW}
	}

	# Caddy sorts directives into a FIXED order regardless of written order.
	# 'handle_path' sorts before 'respond', so this is the fallback. Do NOT use a
	# bare 'handle { }' here: it sorts BEFORE 'handle_path' and would swallow
	# every request, including the proxied ones.
	respond "not found" 404
}
# --- end whatsapp-mcp ---
EOF
ok "appended a block for ${WA_HOST}"

step "Validate and reload"
if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  ok "Caddyfile validates"
else
  bad "Caddyfile does NOT validate - rolling back"
  cp "$BACKUP" "$CADDYFILE"
  caddy validate --config "$CADDYFILE" --adapter caddyfile || true
  exit 1
fi
systemctl reload caddy || systemctl restart caddy
ok "caddy reloaded"

step "Verify"
echo "     waiting for the certificate (first request triggers issuance)..."
for i in $(seq 1 12); do
  C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${WA_HOST}/s/${MCP_SECRET}/healthz" 2>/dev/null || true)
  [[ "$C" == "200" ]] && break
  sleep 5
done
if [[ "${C:-}" == "200" ]]; then
  ok "https://${WA_HOST}/s/.../healthz returns 200"
else
  bad "public endpoint returned '${C:-nothing}' after 60s"
  echo "     check: journalctl -u caddy -n 40 --no-pager"
fi

R=$(curl -sS --max-time 25 -X POST "$CONNECTOR_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"restore","version":"1"}}}' 2>&1 || true)
if grep -q '"serverInfo"' <<<"$R"; then
  ok "MCP handshake succeeded"
  grep -o '"protocolVersion":"[^"]*"' <<<"$R" | head -1 | sed 's/^/     /'
else
  bad "MCP handshake did not complete"
  echo "$R" | head -4 | sed 's/^/     /'
fi

cat > /root/whatsapp-mcp-connector.txt <<EOF
WhatsApp MCP connector
======================
In claude.ai > Settings > Connectors > Add custom connector:

  URL             ${CONNECTOR_URL}
  Authentication  No sign-in
  Request header  (none)

The URL IS the credential. Keep it out of screenshots and shared docs.
Caddyfile backup from this run: ${BACKUP}
EOF
chmod 600 /root/whatsapp-mcp-connector.txt

printf '\n\033[1m=====================================================\033[0m\n'
if (( REUSED )); then
  printf ' Done. The existing connector URL was preserved, so there is\n'
  printf ' NOTHING to change in claude.ai - just use WhatsApp again.\n'
else
  printf ' Delete the old WhatsApp connector in claude.ai and add:\n\n'
  printf '   \033[1m%s\033[0m\n\n' "$CONNECTOR_URL"
  printf ' No sign-in, no request headers.\n'
fi
printf ' (details saved to /root/whatsapp-mcp-connector.txt)\n'
printf '\033[1m=====================================================\033[0m\n\n'
