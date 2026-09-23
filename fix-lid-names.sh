#!/usr/bin/env bash
#
# fix-lid-names.sh - teach the WhatsApp bridge about LID addressing
#
# WhatsApp moved from phone-number addressing to opaque "linked identity" (@lid)
# ids. lharries/whatsapp-mcp predates that: handleMessage stores only
# msg.Info.Sender.User, so LID chats show up as bare digits, and it throws away
# msg.Info.PushName (the sender's display name) which arrives on nearly every
# message.
#
# This script:
#   1. adds a sender_names table (jid -> push_name, alt_jid)
#   2. makes handleMessage prefer SenderAlt (the real phone JID) over a LID,
#      and record PushName for both addresses
#   3. makes whatsapp.py's get_sender_name consult that table first
#   4. rebuilds the bridge and restarts the services
#   5. runs backfill-lid.sh to repair history already in the database
#
# Usage:
#   sudo bash fix-lid-names.sh              # patch, rebuild, restart, backfill
#   sudo bash fix-lid-names.sh --report     # change nothing; just show what is
#                                           # in the databases (run this first if
#                                           # you want to look before leaping)
#
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/whatsapp-mcp}"
SVC_USER="${SVC_USER:-whatsapp}"
BRIDGE_DIR="$INSTALL_DIR/whatsapp-bridge"
SERVER_DIR="$INSTALL_DIR/whatsapp-mcp-server"
MSG_DB="$BRIDGE_DIR/store/messages.db"
WA_DB="$BRIDGE_DIR/store/whatsapp.db"
GO_BIN="${GO_BIN:-/usr/local/go/bin/go}"

REPORT_ONLY=0
[[ "${1:-}" == "--report" ]] && REPORT_ONLY=1

c_ok()   { printf '  \033[32m OK \033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }
[[ -f "$BRIDGE_DIR/main.go" ]] || { echo "no main.go at $BRIDGE_DIR"; exit 1; }

# ============================================================== REPORT MODE ===
step "What is in the databases right now"
python3 - "$MSG_DB" "$WA_DB" <<'PY'
import sqlite3, sys, os

msg_db, wa_db = sys.argv[1], sys.argv[2]

def tables(path):
    if not os.path.exists(path):
        return []
    c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return [r[0] for r in c.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
    finally:
        c.close()

print("  messages.db tables:", ", ".join(tables(msg_db)) or "(none)")

c = sqlite3.connect(f"file:{msg_db}?mode=ro", uri=True)
try:
    total = c.execute("SELECT count(*) FROM messages").fetchone()[0]
    distinct = c.execute("SELECT count(DISTINCT sender) FROM messages").fetchone()[0]
    # A LID is a long numeric id; phone numbers are shorter. Heuristic, for
    # reporting only.
    lidish = c.execute(
        "SELECT count(DISTINCT sender) FROM messages WHERE length(sender) >= 15").fetchone()[0]
    print(f"  messages: {total}, distinct senders: {distinct}, "
          f"long-numeric (likely LID) senders: {lidish}")
    print("  sample of the unresolved ones:")
    for (s,) in c.execute(
            "SELECT DISTINCT sender FROM messages WHERE length(sender) >= 15 LIMIT 8"):
        print(f"    {s}")
finally:
    c.close()

print()
print("  whatsmeow store tables (looking for a LID mapping):")
for t in tables(wa_db):
    marker = "  <-- candidate" if "lid" in t.lower() else ""
    print(f"    {t}{marker}")

c = sqlite3.connect(f"file:{wa_db}?mode=ro", uri=True)
try:
    for t in tables(wa_db):
        if "lid" not in t.lower():
            continue
        cols = [r[1] for r in c.execute(f"PRAGMA table_info('{t}')")]
        n = c.execute(f"SELECT count(*) FROM '{t}'").fetchone()[0]
        print(f"\n  {t}: {n} rows, columns = {cols}")
        for row in c.execute(f"SELECT * FROM '{t}' LIMIT 3"):
            print(f"    {row}")
finally:
    c.close()
PY

if (( REPORT_ONLY )); then
  printf '\n\033[1mReport only - nothing was changed.\033[0m\n\n'
  exit 0
fi

# ============================================================ PATCH THE GO ===
step "Patch main.go"
cp "$BRIDGE_DIR/main.go" "$BRIDGE_DIR/main.go.bak.$(date +%s)"

python3 - "$BRIDGE_DIR/main.go" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

def swap(old, new, why):
    global s
    if new in s:
        print(f"  already patched: {why}"); return
    assert old in s, f"could not find anchor for: {why}"
    s = s.replace(old, new, 1)
    print(f"  patched: {why}")

# 1. schema: display names, keyed by BOTH addresses a person has
swap("""\t\t\tPRIMARY KEY (id, chat_jid),
\t\t\tFOREIGN KEY (chat_jid) REFERENCES chats(jid)
\t\t);
\t`)""",
"""\t\t\tPRIMARY KEY (id, chat_jid),
\t\t\tFOREIGN KEY (chat_jid) REFERENCES chats(jid)
\t\t);

\t\t-- WhatsApp's LID addressing means a person can appear under an opaque
\t\t-- @lid id OR their phone number. Store the display name under both so
\t\t-- either one resolves.
\t\tCREATE TABLE IF NOT EXISTS sender_names (
\t\t\tjid TEXT PRIMARY KEY,
\t\t\tpush_name TEXT,
\t\t\talt_jid TEXT,
\t\t\tupdated_at TIMESTAMP
\t\t);
\t`)""",
     "sender_names table")

# 2. the upsert helper
swap("func handleMessage(",
"""// StoreSenderName records a display name against an address. Called for both
// the LID and the phone number so a lookup by either one succeeds.
func (store *MessageStore) StoreSenderName(jid, pushName, altJID string) error {
\tif jid == "" || pushName == "" {
\t\treturn nil
\t}
\t_, err := store.db.Exec(
\t\t`INSERT INTO sender_names (jid, push_name, alt_jid, updated_at)
\t\t VALUES (?, ?, ?, ?)
\t\t ON CONFLICT(jid) DO UPDATE SET
\t\t   push_name = excluded.push_name,
\t\t   alt_jid = CASE WHEN excluded.alt_jid != '' THEN excluded.alt_jid
\t\t                  ELSE sender_names.alt_jid END,
\t\t   updated_at = excluded.updated_at`,
\t\tjid, pushName, altJID, time.Now())
\treturn err
}

func handleMessage(""",
     "StoreSenderName helper")

# 3. prefer the phone number over the LID, and capture the display name
swap("""\tchatJID := msg.Info.Chat.String()
\tsender := msg.Info.Sender.User
""",
"""\tchatJID := msg.Info.Chat.String()
\tsender := msg.Info.Sender.User

\t// LID addressing: Sender may be an opaque @lid id rather than a phone
\t// number. SenderAlt carries the real phone JID when that happens.
\tif msg.Info.Sender.Server == "lid" && msg.Info.SenderAlt.User != "" {
\t\tsender = msg.Info.SenderAlt.User
\t}

\t// PushName is the sender's WhatsApp display name. It arrives on nearly
\t// every message and upstream throws it away, which is why LID chats show
\t// as bare digits. Record it against both addresses.
\tif msg.Info.PushName != "" {
\t\t_ = messageStore.StoreSenderName(msg.Info.Sender.User, msg.Info.PushName, msg.Info.SenderAlt.User)
\t\tif msg.Info.SenderAlt.User != "" {
\t\t\t_ = messageStore.StoreSenderName(msg.Info.SenderAlt.User, msg.Info.PushName, msg.Info.Sender.User)
\t\t}
\t}
""",
     "prefer SenderAlt over LID, capture PushName")

p.write_text(s)
PY

# ======================================================== PATCH THE PYTHON ===
step "Patch whatsapp.py"
cp "$SERVER_DIR/whatsapp.py" "$SERVER_DIR/whatsapp.py.bak.$(date +%s)"

python3 - "$SERVER_DIR/whatsapp.py" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

marker = "# sender_names lookup"
if marker in s:
    print("  already patched: get_sender_name")
else:
    old = """def get_sender_name(sender_jid: str) -> str:
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()
        """
    assert old in s, "could not find get_sender_name anchor"
    new = """def get_sender_name(sender_jid: str) -> str:
    try:
        conn = sqlite3.connect(MESSAGES_DB_PATH)
        cursor = conn.cursor()

        # sender_names lookup: WhatsApp's LID addressing means the stored sender
        # may be an opaque id. The bridge records the display name against both
        # the LID and the phone number, so try that first.
        bare = sender_jid.split('@')[0]
        try:
            cursor.execute(
                "SELECT push_name FROM sender_names "
                "WHERE (jid = ? OR alt_jid = ?) "
                "AND push_name IS NOT NULL AND push_name != '' LIMIT 1",
                (bare, bare))
            row = cursor.fetchone()
            if row and row[0]:
                return row[0]
        except sqlite3.Error:
            pass  # table not created yet; fall through to the old behaviour
        """
    s = s.replace(old, new, 1)
    print("  patched: get_sender_name consults sender_names first")

p.write_text(s)
PY
python3 -m py_compile "$SERVER_DIR/whatsapp.py" && c_ok "whatsapp.py compiles"

# ==================================================================== BUILD ===
step "Rebuild the bridge"
git config --global --add safe.directory "$INSTALL_DIR" 2>/dev/null || true
cd "$BRIDGE_DIR"
"$GO_BIN" build -buildvcs=false -o whatsapp-bridge . && c_ok "build succeeded"

step "Restart"
chown -R "$SVC_USER":"$SVC_USER" "$INSTALL_DIR"
systemctl restart whatsapp-bridge
sleep 4
systemctl restart whatsapp-mcp
sleep 2
systemctl is-active whatsapp-bridge whatsapp-mcp

# ================================================================= BACKFILL ===
step "Backfill historical senders"
# Kept in its own script so it can be re-run on its own, and because it backs up
# messages.db before rewriting any rows.
curl -fsSL https://raw.githubusercontent.com/jwu711/whatsapp-mcp-installer/main/backfill-lid.sh \\
  -o /root/backfill-lid.sh && bash /root/backfill-lid.sh

printf '\n\033[1mDone.\033[0m New messages carry display names, and history is\n'
printf 'repaired wherever whatsmeow had a mapping for the sender.\n\n'
