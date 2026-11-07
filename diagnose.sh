#!/usr/bin/env bash
#
# diagnose.sh - one-shot health report for the WhatsApp MCP stack.
#
# Prints everything needed to work out why Claude cannot reach WhatsApp, and
# ends with a verdict naming the most likely cause.
#
# Secrets are REDACTED (first 4 chars + length only), so the whole output is
# safe to paste into a chat. It changes nothing on the server.
#
# Usage (on the server):  sudo bash diagnose.sh
#
set -uo pipefail   # deliberately not -e: every check must run even if one fails

INSTALL_DIR="${INSTALL_DIR:-/opt/whatsapp-mcp}"
BRIDGE_DIR="$INSTALL_DIR/whatsapp-bridge"
SERVER_DIR="$INSTALL_DIR/whatsapp-mcp-server"
MSG_DB="$BRIDGE_DIR/store/messages.db"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"

hdr()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '   \033[31mBAD\033[0m  %s\n' "$*"; }
warn() { printf '   \033[33m??\033[0m   %s\n' "$*"; }

redact() {  # show shape, never the value
  local s="${1:-}"
  [[ -z "$s" ]] && { echo "(empty)"; return; }
  printf '%s...(%d chars)\n' "${s:0:4}" "${#s}"
}

VERDICT=()

hdr "System"
echo "   now:      $(date -Is)"
echo "   uptime:   $(uptime -p 2>/dev/null)  (booted $(uptime -s 2>/dev/null))"
free -m | awk 'NR==1{print "   mem:     " $0} NR==2{print "   mem:     " $0} NR==3{print "   swap:    " $0}'
df -h / | awk 'NR==2{print "   disk /:   " $5 " used, " $4 " free"}'
DISK_PCT=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
(( DISK_PCT > 90 )) && { bad "disk over 90% full"; VERDICT+=("Disk is ${DISK_PCT}% full - that alone can break SQLite writes and Caddy."); }

hdr "Services"
for svc in whatsapp-bridge whatsapp-mcp caddy; do
  A=$(systemctl is-active "$svc" 2>/dev/null)
  E=$(systemctl is-enabled "$svc" 2>/dev/null)
  S=$(systemctl show "$svc" -p ActiveEnterTimestamp --value 2>/dev/null)
  N=$(systemctl show "$svc" -p NRestarts --value 2>/dev/null)
  printf '   %-17s %-10s %-10s since=%s restarts=%s\n' "$svc" "$A" "$E" "${S:-?}" "${N:-?}"
  [[ "$A" != "active" ]] && { bad "$svc is $A"; VERDICT+=("$svc is not running (state: $A)."); }
  [[ "${N:-0}" =~ ^[0-9]+$ ]] && (( N > 20 )) && VERDICT+=("$svc has restarted $N times - it is crash-looping.")
done

hdr "Bridge log (last 25)"
journalctl -u whatsapp-bridge -n 25 --no-pager 2>/dev/null | sed 's/^/   /'
BL=$(journalctl -u whatsapp-bridge -n 400 --no-pager 2>/dev/null)
if grep -q "1006" <<<"$BL"; then
  bad "socket closing with 1006"
  VERDICT+=("Bridge log shows 'close 1006' - WhatsApp is rejecting the client. Either whatsmeow has gone stale again, or the linked-device session was revoked. Rebuild against whatsmeow@latest first, then re-pair.")
fi
if grep -qiE "logged out|device_removed|stream:error|401|unauthorized" <<<"$BL"; then
  bad "log mentions logout / unauthorized"
  VERDICT+=("Bridge log mentions a logout or unauthorized stream - the linked device was almost certainly removed or expired. Fix: wa-login, then re-scan.")
fi
grep -qi "Successfully authenticated\|Connected to WhatsApp" <<<"$BL" && ok "has authenticated at some point in recent log"

hdr "MCP gateway log (last 15)"
journalctl -u whatsapp-mcp -n 15 --no-pager 2>/dev/null | sed 's/^/   /'

hdr "Caddy log (last 15)"
journalctl -u caddy -n 15 --no-pager 2>/dev/null | sed 's/^/   /'
CL=$(journalctl -u caddy -n 300 --no-pager 2>/dev/null)
grep -qiE "obtain certificate|could not get certificate|acme.*error" <<<"$CL" && {
  bad "Caddy certificate trouble in log"
  VERDICT+=("Caddy is failing to obtain or renew its certificate - check ports 80/443 are reachable."); }

hdr "Message database"
if [[ -f "$MSG_DB" ]]; then
  echo "   file mtime:  $(stat -c '%y' "$MSG_DB" 2>/dev/null)"
  echo "   size:        $(du -h "$MSG_DB" 2>/dev/null | cut -f1)"
  python3 -I - "$MSG_DB" <<'PY'
import sqlite3, sys, datetime
try:
    c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    n = c.execute("SELECT count(*) FROM messages").fetchone()[0]
    newest = c.execute("SELECT max(timestamp) FROM messages").fetchone()[0]
    print(f"   messages:    {n}")
    print(f"   newest msg:  {newest}")
    try:
        ts = datetime.datetime.fromisoformat(str(newest).replace("Z", "+00:00"))
        age = (datetime.datetime.now(ts.tzinfo) - ts).total_seconds() / 3600
        print(f"   age:         {age:.1f} hours")
        print("   STALE" if age > 48 else "   FRESH")
    except Exception:
        pass
    c.close()
except Exception as e:
    print("   could not read:", e)
PY
  AGEFLAG=$(python3 -I - "$MSG_DB" 2>/dev/null <<'PY'
import sqlite3,sys,datetime
try:
    c=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro",uri=True)
    t=c.execute("SELECT max(timestamp) FROM messages").fetchone()[0]
    ts=datetime.datetime.fromisoformat(str(t).replace("Z","+00:00"))
    print(int((datetime.datetime.now(ts.tzinfo)-ts).total_seconds()/3600))
except Exception: print(-1)
PY
)
  [[ "$AGEFLAG" =~ ^[0-9]+$ ]] && (( AGEFLAG > 48 )) && {
    bad "no new message in ${AGEFLAG}h"
    VERDICT+=("No WhatsApp message has arrived in ${AGEFLAG} hours. The bridge is not receiving, which usually means the linked-device session is dead. Fix: wa-login."); }
else
  bad "no messages.db at $MSG_DB"
  VERDICT+=("messages.db is missing - the install directory may be gone.")
fi

hdr "Versions"
if [[ -x "$BRIDGE_DIR/whatsapp-bridge" ]]; then
  /usr/local/go/bin/go version -m "$BRIDGE_DIR/whatsapp-bridge" 2>/dev/null \
    | grep whatsmeow | sed 's/^/   /' || warn "could not read whatsmeow version"
else
  bad "bridge binary missing"
fi
HOME="$INSTALL_DIR" /usr/local/bin/uv pip list 2>/dev/null | grep -i '^mcp ' | sed 's/^/   mcp python: /' || warn "could not read mcp version"

hdr "Caddy config shape (secrets redacted)"
if [[ -f "$CADDYFILE" ]]; then
  WA_HOST=$(grep -oE '^[a-z0-9][a-z0-9.-]+\.[a-z]+ \{' "$CADDYFILE" 2>/dev/null | head -1 | awk '{print $1}')
  SECRET=$(sed -n 's|.*/s/\([A-Za-z0-9_-]\{16,\}\)/.*|\1|p' "$CADDYFILE" 2>/dev/null | head -1)
  APIKEY=$(sed -n 's|.*header X-Api-Key "\([^"]*\)".*|\1|p' "$CADDYFILE" 2>/dev/null | head -1)
  echo "   host:        ${WA_HOST:-(none found)}"
  echo "   secret path: $(redact "$SECRET")"
  echo "   X-Api-Key:   $(redact "$APIKEY")"
  if [[ -n "$APIKEY" ]]; then
    echo "   auth mode:   path + header (connector MUST send X-Api-Key)"
  elif [[ -n "$SECRET" ]]; then
    echo "   auth mode:   path only"
  else
    bad "no whatsapp block found in Caddyfile"
    VERDICT+=("No WhatsApp site block found in $CADDYFILE.")
  fi
  grep -qE '^\s*respond .*403' "$CADDYFILE" && {
    warn "fallback responds 403"
    VERDICT+=("Caddyfile falls back to 403. claude.ai reads that as 'needs OAuth' and fails with the sign-in error. It must be 404."); }
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
    && ok "Caddyfile validates" || { bad "Caddyfile does NOT validate"; VERDICT+=("The Caddyfile is invalid, so Caddy is serving an old or no config."); }
else
  bad "no Caddyfile"
fi

hdr "Endpoint tests"
GW=$(grep -oE '\-\-port [0-9]+' /etc/systemd/system/whatsapp-mcp.service 2>/dev/null | head -1 | awk '{print $2}')
GW="${GW:-3005}"
echo "   gateway port: $GW"

L=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$GW/healthz" 2>/dev/null)
echo "   loopback  http://127.0.0.1:$GW/healthz   -> ${L:-no response}"
[[ "$L" == "200" ]] && ok "MCP gateway answers locally" || {
  bad "MCP gateway not answering on loopback"
  VERDICT+=("The MCP gateway is not answering on 127.0.0.1:$GW, so the problem is below Caddy, not in DNS or TLS."); }

if [[ -n "${WA_HOST:-}" && -n "${SECRET:-}" ]]; then
  if [[ -n "${APIKEY:-}" ]]; then
    P1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "X-Api-Key: $APIKEY" "https://$WA_HOST/s/$SECRET/healthz" 2>/dev/null)
    echo "   public (path+header)                  -> ${P1:-no response}"
    P0=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$WA_HOST/s/$SECRET/healthz" 2>/dev/null)
    echo "   public (path only, expect 404)        -> ${P0:-no response}"
  else
    P1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$WA_HOST/s/$SECRET/healthz" 2>/dev/null)
    echo "   public (path only)                    -> ${P1:-no response}"
  fi
  [[ "${P1:-}" == "200" ]] && ok "reachable end to end over HTTPS" || {
    bad "public endpoint not returning 200"
    VERDICT+=("The public HTTPS endpoint is not returning 200, so claude.ai cannot reach it either."); }

  hdr "MCP handshake"
  R=$(curl -sS --max-time 25 -X POST "https://$WA_HOST/s/$SECRET/mcp" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        ${APIKEY:+-H "X-Api-Key: $APIKEY"} \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"diagnose","version":"1"}}}' 2>&1)
  echo "$R" | sed 's/^/   /' | head -8
  if grep -q '"protocolVersion":"2024-11-05"' <<<"$R"; then
    bad "server speaks the 2024 protocol"
    VERDICT+=("The MCP server replied protocolVersion 2024-11-05. claude.ai refuses that. Fix: uv add 'mcp[cli]<2' then restart whatsapp-mcp.")
  elif grep -q '"serverInfo"' <<<"$R"; then
    ok "MCP handshake succeeded"
  else
    bad "no valid MCP handshake"
    VERDICT+=("The MCP endpoint did not complete a handshake.")
  fi
fi

hdr "VERDICT"
if ((${#VERDICT[@]} == 0)); then
  ok "Everything on this server looks healthy."
  echo "   If Claude still cannot see WhatsApp, the problem is on the claude.ai side:"
  echo "     - the connector may be toggled off in that particular chat"
  echo "     - the saved connector URL may not match the secret path above"
  echo "     - if auth mode is 'path + header', the connector must carry X-Api-Key"
else
  for v in "${VERDICT[@]}"; do echo "   - $v"; done
fi
echo
