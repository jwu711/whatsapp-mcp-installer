#!/usr/bin/env bash
#
# backfill-lid.sh - put names and phone numbers on history already in the database
#
# Run this AFTER fix-lid-names.sh. That script fixes messages arriving from now
# on; this one repairs what is already stored, using two tables whatsmeow keeps
# in its own store:
#
#   whatsmeow_lid_map   lid -> pn   (the LID to phone-number mapping)
#   whatsmeow_contacts  their_jid -> full_name / push_name / business_name
#
# It rewrites message senders from LID to phone number, and names chats that are
# currently showing a bare numeric id. Both source tables are read-only here.
#
# Usage (on the server):
#   sudo bash backfill-lid.sh
#
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/whatsapp-mcp}"
SVC_USER="${SVC_USER:-whatsapp}"
MSG_DB="$INSTALL_DIR/whatsapp-bridge/store/messages.db"
WA_DB="$INSTALL_DIR/whatsapp-bridge/store/whatsapp.db"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }
[[ -f "$MSG_DB" ]] || { echo "no messages.db at $MSG_DB"; exit 1; }

BACKUP="$MSG_DB.bak.$(date +%s)"
cp "$MSG_DB" "$BACKUP"
echo "Backed up messages.db to $BACKUP"
echo "(to undo: systemctl stop whatsapp-bridge whatsapp-mcp; cp '$BACKUP' '$MSG_DB'; systemctl start whatsapp-bridge whatsapp-mcp)"
echo

python3 - "$MSG_DB" "$WA_DB" <<'PY'
import sqlite3, os, sys

msg_db, wa_db = sys.argv[1], sys.argv[2]

def bare(x):
    x = str(x or "")
    return x.split('@')[0].split(':')[0]

conn = sqlite3.connect(msg_db)
cur = conn.cursor()
cur.execute("""CREATE TABLE IF NOT EXISTS sender_names (
    jid TEXT PRIMARY KEY, push_name TEXT, alt_jid TEXT, updated_at TIMESTAMP)""")
cur.execute("CREATE TABLE IF NOT EXISTS lid_map (lid TEXT PRIMARY KEY, pn TEXT)")

lid_to_pn = {}
names = {}

if os.path.exists(wa_db):
    wa = sqlite3.connect(f"file:{wa_db}?mode=ro", uri=True)
    try:
        tabs = [r[0] for r in wa.execute("SELECT name FROM sqlite_master WHERE type='table'")]

        # --- LID -> phone number ------------------------------------------
        for t in tabs:
            if "lid" not in t.lower():
                continue
            cols = [r[1] for r in wa.execute(f"PRAGMA table_info('{t}')")]
            lid_col = next((c for c in cols if c.lower() == "lid"), None) or \
                      next((c for c in cols if "lid" in c.lower()), None)
            pn_col = next((c for c in cols if c != lid_col and
                           any(k in c.lower() for k in ("pn", "phone", "jid", "user"))), None)
            if not (lid_col and pn_col):
                continue
            for lid, pn in wa.execute(f"SELECT {lid_col}, {pn_col} FROM '{t}'"):
                if lid and pn:
                    lid_to_pn[bare(lid)] = bare(pn)
            print(f"  {t}: {len(lid_to_pn)} LID -> phone mappings")

        # --- display names ------------------------------------------------
        for t in tabs:
            if "contact" not in t.lower():
                continue
            cols = [r[1] for r in wa.execute(f"PRAGMA table_info('{t}')")]
            jid_col = next((c for c in cols if "their" in c.lower()), None) or \
                      next((c for c in cols if "jid" in c.lower() and "our" not in c.lower()), None)
            name_cols = [c for c in ("full_name", "push_name", "business_name", "first_name")
                         if c in cols]
            if not (jid_col and name_cols):
                continue
            sel = ", ".join([jid_col] + name_cols)
            n = 0
            for row in wa.execute(f"SELECT {sel} FROM '{t}'"):
                jid, vals = row[0], row[1:]
                nm = next((v for v in vals if v and str(v).strip()), None)
                if not (jid and nm):
                    continue
                names[bare(jid)] = nm
                n += 1
            print(f"  {t}: {n} contact names")
    finally:
        wa.close()

if not lid_to_pn:
    print("  no LID mapping table found")

for lid, pn in lid_to_pn.items():
    cur.execute("INSERT INTO lid_map (lid, pn) VALUES (?, ?) "
                "ON CONFLICT(lid) DO UPDATE SET pn = excluded.pn", (lid, pn))
    nm = names.get(pn) or names.get(lid)
    for addr, alt in ((lid, pn), (pn, lid)):
        cur.execute(
            "INSERT INTO sender_names (jid, push_name, alt_jid) VALUES (?, ?, ?) "
            "ON CONFLICT(jid) DO UPDATE SET "
            "  push_name = COALESCE(NULLIF(excluded.push_name,''), sender_names.push_name), "
            "  alt_jid = COALESCE(NULLIF(excluded.alt_jid,''), sender_names.alt_jid)",
            (addr, nm, alt))

for jid, nm in names.items():
    cur.execute(
        "INSERT INTO sender_names (jid, push_name) VALUES (?, ?) "
        "ON CONFLICT(jid) DO UPDATE SET "
        "  push_name = COALESCE(NULLIF(excluded.push_name,''), sender_names.push_name)",
        (jid, nm))

# 1. normalise: strip any @suffix so every sender is a bare id
cur.execute("""UPDATE messages SET sender =
   CASE WHEN instr(sender,'@') > 0 THEN substr(sender, 1, instr(sender,'@')-1)
        ELSE sender END
   WHERE instr(sender,'@') > 0""")
print(f"  normalised {cur.rowcount} sender values that carried an @suffix")

# 2. LID -> phone number
cur.execute("""UPDATE messages SET sender = (SELECT pn FROM lid_map WHERE lid = messages.sender)
               WHERE sender IN (SELECT lid FROM lid_map)""")
print(f"  rewrote {cur.rowcount} message rows from LID to phone number")

# 3. name the chats showing a bare id (groups already have real names)
cur.execute("""UPDATE chats SET name = (
     SELECT push_name FROM sender_names
     WHERE sender_names.jid = CASE WHEN instr(chats.jid,'@') > 0
            THEN substr(chats.jid, 1, instr(chats.jid,'@')-1) ELSE chats.jid END
       AND push_name IS NOT NULL AND push_name != '')
   WHERE chats.jid NOT LIKE '%@g.us'
     AND (name IS NULL OR name = '' OR name = CASE WHEN instr(chats.jid,'@') > 0
            THEN substr(chats.jid, 1, instr(chats.jid,'@')-1) ELSE chats.jid END)
     AND EXISTS (SELECT 1 FROM sender_names
     WHERE sender_names.jid = CASE WHEN instr(chats.jid,'@') > 0
            THEN substr(chats.jid, 1, instr(chats.jid,'@')-1) ELSE chats.jid END
       AND push_name IS NOT NULL AND push_name != '')""")
print(f"  named {cur.rowcount} chats that were showing a bare id")

conn.commit()
print("  remaining long-numeric senders:",
      cur.execute("SELECT count(DISTINCT sender) FROM messages WHERE length(sender) >= 15").fetchone()[0])
conn.close()
PY

chown "$SVC_USER":"$SVC_USER" "$MSG_DB" 2>/dev/null || true
systemctl restart whatsapp-mcp 2>/dev/null || true

echo
echo "Done. Anything still unresolved is someone whatsmeow has no mapping for;"
echo "those fill in as soon as that person sends their next message."
