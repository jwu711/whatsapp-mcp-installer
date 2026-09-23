# Why your chats show numbers instead of names

If Claude tells you things like *"147038322880518 says they can come"* instead of
naming the person, this is why, and it is fixable in about fifteen minutes.

## What happened

WhatsApp has been migrating from phone-number addressing to opaque **LID**
identifiers ("linked identity"). A message that used to arrive tagged
`15551234567@s.whatsapp.net` now often arrives tagged `147038322880518@lid`.

The upstream bridge predates that change. Its message handler does this:

```go
sender := msg.Info.Sender.User
```

So it stores the LID digits and nothing else. Worse, every incoming message also
carries `msg.Info.PushName`, the sender's WhatsApp display name, and the bridge
throws it away. The name you wanted was arriving the whole time.

Current whatsmeow gives us both missing pieces:

- **`PushName`** — the display name, on nearly every message
- **`SenderAlt`** — when `Sender` is a LID, this holds the real phone JID

And your own server has been quietly keeping a full mapping table the entire
time, in the whatsmeow store: `whatsmeow_lid_map`, with columns `lid` and `pn`.
Nobody was reading it.

## The fix

Two scripts. Run them **on the server**, in this order.

See what you are dealing with first. This changes nothing:

```bash
curl -fsSL https://raw.githubusercontent.com/jwu711/whatsapp-mcp-installer/main/fix-lid-names.sh -o /root/fix-lid-names.sh
sudo bash /root/fix-lid-names.sh --report
```

It prints how many of your senders are unresolved and whether a mapping table
exists. Then run it for real:

```bash
sudo bash /root/fix-lid-names.sh
```

That patches the bridge, rebuilds it, restarts the services, and then fetches and
runs `backfill-lid.sh` to repair the history already in your database.

## What each part does

**Going forward**, the bridge now prefers `SenderAlt` over a LID, so new messages
store real phone numbers. It also records `PushName` in a new `sender_names`
table, keyed under *both* a person's LID and their phone number, so a lookup by
either address finds the name.

**Backwards**, `backfill-lid.sh` reads `whatsmeow_lid_map` for LID-to-phone pairs
and `whatsmeow_contacts` for display names, rewrites historical message senders,
and renames chats that were showing bare digits.

The subtle part is that senders are stored **inconsistently**, some bare and some
with an `@lid` suffix, so a naive match misses most of them. The backfill strips
the suffix before matching. On a real 4,347-message database that was the
difference between recovering 845 rows and recovering all of them:

| | Before normalising | After |
|---|---|---|
| Message rows rewritten | 845 | 2,437 more |
| Chats given a real name | 0 | 80 |
| Senders left unidentified | 191 | **0** |

## Safety

`backfill-lid.sh` copies `messages.db` to a timestamped backup and prints the
exact restore command before it changes anything. `fix-lid-names.sh` backs up
`main.go` and `whatsapp.py` the same way. The whatsmeow store is opened read-only
throughout; nothing touches your WhatsApp session.

## What it cannot do

Someone whose LID is not in `whatsmeow_lid_map` and who is not in your contacts
stays a number. That resolves by itself the moment they send their next message,
because the patched bridge captures the name from the message itself.
