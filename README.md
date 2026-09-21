# Connect Claude to your personal WhatsApp

This gives Claude the ability to read and send your WhatsApp messages. You can ask
things like "what did Priya say about the trip last week?" or "reply to my mother
that I will call after dinner," and Claude will actually do it.

Everything runs on a small server you control. Your messages are stored on that
server, not on anyone else's. Only the parts of a conversation Claude actually
looks at ever leave it.

**It takes about 30 minutes**, most of which is waiting for things to install.
You do not need to know how to program. You do need to be willing to copy and
paste commands into a black terminal window, and the instructions tell you
exactly what to paste.

> **Easiest path:** open Claude and say *"help me set up WhatsApp MCP using
> github.com/jwu711/whatsapp-mcp-installer"*. Claude will walk you through this
> whole document one step at a time and read your error messages when something
> goes wrong. That is genuinely much easier than doing it alone.

---

## Before you start

You will need four things.

**A phone with WhatsApp on it.** Any phone. This uses the same "linked devices"
feature that WhatsApp Web uses, so your phone stays the main device.

**A Claude Pro, Max, Team or Enterprise plan.** Custom connectors are not
available on the free plan.

**About $6 a month for a server.** This guide uses DigitalOcean. Any Ubuntu
server works, including one you already have.

**A hostname.** This is the part people get stuck on, so read the two options in
Step 2 before deciding. One is free.

### What this costs

| Item | Cost |
|---|---|
| DigitalOcean droplet, 2GB | about $12/month (1GB at $6 works but is tight) |
| Domain name | about $10/year, or free with DuckDNS |
| HTTPS certificate | free, issued automatically |

---

## Step 1: Get a server

Skip this if you already have an Ubuntu server you can SSH into. It does not
need to be empty; the installer checks for conflicts and works around them.

1. Sign up at [digitalocean.com](https://www.digitalocean.com).
2. Click **Create**, then **Droplets**.
3. Choose **Ubuntu 24.04 LTS**.
4. Choose the **Basic** plan, **Regular** CPU, the **$12/month** option with 2GB
   of RAM. The $6 option works too, but compiling is slow and close to the memory
   limit.
5. Pick a region near you.
6. For authentication choose **SSH Key** and follow DigitalOcean's instructions
   to add yours. Password login also works but is less safe, and the installer
   turns password login off at the end.
7. Click **Create Droplet**, wait about a minute, and copy the **IP address** it
   shows you. It looks like `203.0.113.45`.

**One thing to check:** in the DigitalOcean panel under **Networking → Firewalls**,
make sure this droplet either has no firewall attached, or has one that allows
incoming traffic on ports **80** and **443**. Without those, the HTTPS certificate
cannot be issued and nothing will work. The installer cannot see DigitalOcean's
firewall, so it cannot warn you.

---

## Step 2: Get a hostname

Claude requires HTTPS, and HTTPS requires a real hostname. An IP address alone
will not do. You have two options.

### Option A: you own a domain (recommended)

Create an **A record** pointing a subdomain at your server's IP:

```
Name:  wa
Type:  A
Value: 203.0.113.45      ← your droplet's IP
TTL:   300
```

That gives you `wa.yourdomain.com`. Where you do this depends on who hosts your
DNS: Cloudflare, Namecheap, GoDaddy, Google Domains and the rest all have a "DNS"
or "DNS records" page.

**If you use Cloudflare, turn the proxy OFF** for this record. The cloud icon next
to it must be grey, not orange. The orange proxy handles HTTPS itself, which stops
the certificate from being issued, and it also interferes with the streaming
responses Claude relies on. This one setting costs people an hour.

### Option B: you do not own a domain (free)

Use [DuckDNS](https://www.duckdns.org). It is free, takes about a minute, and
unlike similar services it works reliably with the free certificate authority
this setup depends on.

1. Go to duckdns.org and sign in with Google, GitHub or Reddit.
2. Type a name in the "sub domain" box, for example `janes-whatsapp`, and click
   **add domain**.
3. In the box next to your new domain, paste your droplet's IP and click
   **update ip**.

That gives you `janes-whatsapp.duckdns.org`.

> **Avoid `nip.io` and `sslip.io`.** They look convenient because they need no
> setup, but the free certificate authority treats every `nip.io` address on
> earth as one domain sharing a single weekly quota. Certificate issuance becomes
> a coin flip.

### Check it worked

Wait a minute, then on your own computer open a terminal and run:

```bash
dig +short wa.yourdomain.com
```

It must print your droplet's IP. If it prints nothing, or a different address,
wait a few more minutes and try again before moving on. Nothing downstream works
until this is right.

---

## Step 3: Connect to your server

**On a Mac:** open the **Terminal** app (press Cmd+Space, type "terminal").

**On Windows:** open **PowerShell** or **Windows Terminal** from the Start menu.

Then type this, substituting your droplet's IP:

```bash
ssh root@203.0.113.45
```

The first time, it asks whether you trust this machine. Type `yes` and press
Enter. You are now typing commands on the server rather than on your own
computer. The prompt changes to something ending in `#`.

Everything from here until Step 6 happens in this window.

---

## Step 4: Run the installer

Download it:

```bash
curl -fsSL https://raw.githubusercontent.com/jwu711/whatsapp-mcp-installer/main/install.sh -o install.sh
```

Have a look at what you are about to run, which is a good habit with any script
off the internet:

```bash
less install.sh
```

Press `q` to quit that view.

**Check your server first.** This changes nothing, it only reports:

```bash
sudo bash install.sh --check
```

It prints your memory, disk, what is already running, and whether your hostname
points at this machine. Read the DNS line. If it says the name does not resolve
here, go back to Step 2.

**Then install**, substituting your own hostname and email:

```bash
sudo WA_HOST=wa.yourdomain.com ACME_EMAIL=you@example.com bash install.sh
```

The email is only used by the certificate authority to warn you if a certificate
is about to expire.

This takes five to ten minutes. Most of it is downloading a compiler and building
the WhatsApp bridge, during which nothing appears to happen. That silence is
normal. **Do not press Ctrl+C.**

When it finishes it prints a URL. Keep that window open.

---

## Step 5: Pair your phone

Have your phone in your hand for this. Then run:

```bash
wa-login
```

A QR code appears in the terminal.

**Make your terminal font smaller first**, with Cmd+minus on a Mac or Ctrl+minus
on Windows, until the whole QR square fits with clear space around it. A code
that wraps or gets cut off will never scan.

On your phone:

- **iPhone:** WhatsApp → Settings (bottom right) → Linked Devices → Link a Device
- **Android:** WhatsApp → three-dot menu (top right) → Linked Devices → Link a Device

Point your phone at the screen. The code refreshes every 20 seconds or so and
redraws itself, which is normal.

The moment your phone confirms, the script takes over on its own: it stops the
pairing process, starts the two background services, and prints your connector
URL again. You do not type anything else.

Your message history arrives gradually over the following minutes and hours.
Asking about a conversation from last year immediately after pairing may come up
empty.

---

## Step 6: Connect it to Claude

Get your URL:

```bash
cat /root/whatsapp-mcp-connector.txt
```

Then in Claude:

1. Go to **Settings → Connectors**
2. Click **Add custom connector**
3. Give it a name, such as `WhatsApp`
4. Paste the URL
5. Under Authentication choose **No sign-in**
6. Leave Request headers empty
7. Click **Add**

**That URL is your password.** Anyone who has it can read and send your WhatsApp
messages. Keep it out of screenshots and shared documents.

Now ask Claude something like *"what are my most recent WhatsApp conversations?"*

---

## When something goes wrong

These are the actual failures, in the order people hit them.

### The QR code never appears, and the log says `close 1006 (abnormal closure)`

WhatsApp rejected the connection because the client software is out of date. The
installer already builds against the current version, so if you see this, the
current version has drifted again. Rebuild:

```bash
cd /opt/whatsapp-mcp/whatsapp-bridge
export PATH=/usr/local/go/bin:$PATH
go get go.mau.fi/whatsmeow@latest && go mod tidy
go build -buildvcs=false -o whatsapp-bridge .
```

If that build fails with `not enough arguments in call to ...`, the library added
a parameter. Each error names the file, line and what it now expects, and Claude
can write the fix for you if you paste the errors in.

### Claude says "Couldn't reach WhatsApp"

Usually a typo in the URL. Check the exact string:

```bash
cat /root/whatsapp-mcp-connector.txt
```

If the URL is definitely right, test the server directly. Substitute your own URL:

```bash
curl -sS -X POST 'YOUR-URL-HERE' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```

If the reply contains `"protocolVersion":"2024-11-05"`, the Python library is too
old. Upgrade it, staying on the 1.x line:

```bash
cd /opt/whatsapp-mcp/whatsapp-mcp-server
HOME=/opt/whatsapp-mcp /usr/local/bin/uv add 'mcp[cli]<2'
chown -R whatsapp:whatsapp /opt/whatsapp-mcp && systemctl restart whatsapp-mcp
```

Do not jump to version 2.x. It renames things this project still uses, and the
server will refuse to start.

### Claude says "Couldn't register with WhatsApp's sign-in service"

Claude thinks your server wants OAuth. That happens when the server answers with
403 instead of 404. Check `/etc/caddy/Caddyfile` says `respond "not found" 404`,
then `systemctl reload caddy`.

### Claude connects, but the message contents do not come through

The tools are returning text where a structured list is declared. Fix:

```bash
cd /opt/whatsapp-mcp/whatsapp-mcp-server
sed -i 's|) -> List\[Dict\[str, Any\]\]:|):|; s|) -> Dict\[str, Any\]:|):|; s|) -> str:|):|' main.py
chown -R whatsapp:whatsapp /opt/whatsapp-mcp && systemctl restart whatsapp-mcp
```

### Certificate errors, or the site does not load at all

Almost always DNS or a firewall. Confirm `dig +short yourhostname` returns your
droplet's IP, confirm Cloudflare's proxy is off if you use Cloudflare, and confirm
ports 80 and 443 are open in any DigitalOcean firewall. Then:

```bash
journalctl -u caddy -n 50 --no-pager
```

### It worked, then stopped weeks later

WhatsApp linked-device sessions expire. Check with
`journalctl -u whatsapp-bridge -n 30`, then run `wa-login` and scan again.

---

## What this does and does not protect

Worth reading before you trust it with years of personal messages.

**What protects you.** The connector URL contains 64 random hex characters, which
is not guessable. All traffic is encrypted with HTTPS. The internal services
listen only on the server's own loopback interface, so they are not reachable
from the internet. Password login over SSH is disabled during install.

**What it does not do.**

*The URL is the only credential.* There is no concept of who is calling. Anyone
holding that URL has full access from anywhere. Revoking means changing it and
reconnecting.

*Claude can send messages, not just read them.* Sending text, files and voice
notes are all enabled. See below to turn that off.

*Your messages are stored unencrypted on the server.* Anyone with access to that
machine can read your entire history. Think about what else runs there.

*Media stays on WhatsApp's servers* until Claude explicitly downloads a file, so
the database holds text rather than photos and videos.

### Optional: make it read-only

If you want Claude to read your WhatsApp but never send anything:

```bash
cd /opt/whatsapp-mcp/whatsapp-mcp-server
python3 - <<'PY'
import re, pathlib
p = pathlib.Path('main.py'); t = p.read_text()
for tool in ('send_message', 'send_file', 'send_audio_message'):
    t = re.sub(r'@mcp\.tool\(\)\n(def %s\()' % tool, r'\1', t)
p.write_text(t)
PY
chown -R whatsapp:whatsapp /opt/whatsapp-mcp && systemctl restart whatsapp-mcp
```

Then remove and re-add the connector in Claude so it picks up the shorter tool
list.

### Optional: move the secret into a header

More secure, because URLs end up in logs and screenshots while headers mostly do
not. It is fiddly, because Claude's first probe when *adding* a connector does
not send headers. The sequence is: require only the path, add the connector with
the header filled in anyway, then require both. The comments in
`/etc/caddy/Caddyfile` explain the config, and Claude can walk you through it.

---

## Maintenance

```bash
systemctl status whatsapp-bridge whatsapp-mcp   # are both running?
journalctl -u whatsapp-bridge -f                # watch the WhatsApp connection
journalctl -u whatsapp-mcp -f                   # watch Claude's requests
wa-login                                        # re-pair the phone
```

Everything lives in `/opt/whatsapp-mcp`. Your messages are in
`/opt/whatsapp-mcp/whatsapp-bridge/store/messages.db`, which is a plain SQLite
file you can copy or delete.

To remove it entirely:

```bash
systemctl disable --now whatsapp-bridge whatsapp-mcp
rm -rf /opt/whatsapp-mcp /etc/systemd/system/whatsapp-{bridge,mcp}.service
systemctl daemon-reload
```

Then unlink the device in WhatsApp under Settings → Linked Devices, and delete the
connector in Claude.

---

## How it works

Four pieces, each talking only to the next:

```
WhatsApp  ──►  Go bridge          connects as a linked device, stores messages in SQLite
               (whatsmeow)
                   │  REST on 127.0.0.1
                   ▼
               Python MCP server  turns that database into tools Claude understands
                   │  stdio
                   ▼
               supergateway       exposes those tools over HTTP
                   │  127.0.0.1
                   ▼
               Caddy              HTTPS, certificate, checks the secret URL
                   │
                   ▼
               claude.ai
```

Only Caddy is reachable from the internet. Everything else is bound to loopback.

Built on [lharries/whatsapp-mcp](https://github.com/lharries/whatsapp-mcp), which
does the real work. This repository adds an installer that pins working versions
and applies the patches needed for the two to talk to each other today.

---

## Credits and license

MIT licensed. Not affiliated with WhatsApp, Meta or Anthropic. Using an unofficial
client carries some risk to your WhatsApp account; that risk is yours to weigh.
