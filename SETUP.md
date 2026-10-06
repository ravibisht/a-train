# Setting up A-Train

## Zero-config path (most people)

1. Install the pkg from the DMG, enter your Mac password once.
2. Menu bar "A" > **Save password…** The site and username are prefilled from the Check Point client; type
   your VPN password. Then **Connect VPN**.
3. Done. The default routes file contains one entry, `private`: every internal network (10/8, 172.16/12,
   192.168/16) goes through the VPN, and the network your Mac is on stays local. A-Train also learns which
   internal servers you actually use and adds them to the Reachability card by itself.

Only one thing cannot be discovered: a public website that refuses you unless you come from the office IP.
When that happens, menu > **Route a website…**, paste its address, and its whole domain goes through the VPN.

Everything below is for people who want precise control instead of the `private` default.

## The four things behind the scenes

| # | Value | Example | Where it goes |
|---|---|---|---|
| 1 | The Check Point **site** (gateway address or name) | `203.0.113.10` or `vpn.example.com` | A-Train > Save password… (asked once) |
| 2 | Your VPN **username and password** | `jdoe` / your company password | Same dialog; stored in the macOS Keychain |
| 3 | The **routes** that must go through the VPN | `10.20.0.0/16`, `db.internal.example.com` | `~/vpn-split/config/routes.conf` |
| 4 | **Checks**: a host and port that proves the tunnel works | `10.20.4.27:3306` | `~/vpn-split/config/checks.conf` |

Optional: `*.example.com` in routes.conf for company websites that only allow the office IP.

## Before you start

- macOS 13 or newer, an admin account.
- **Check Point Endpoint Security VPN** installed and able to connect at least once on its own. A-Train drives
  that client; it is not a VPN by itself. The client's CLI must exist:
  `/Library/Application Support/Checkpoint/Endpoint Connect/trac`.
- Python 3.9+ (macOS has it once Xcode Command Line Tools are installed: `xcode-select --install`).

## Step 1: find your site

The site is whatever the Check Point client already knows. Run:

```
"/Library/Application Support/Checkpoint/Endpoint Connect/trac" info
```

Each `Conn <site>:` block is a site; `active site: true` marks the one in use. Copy that name or address.
No sites listed? Add one in the Check Point app (Options > Sites) or with
`trac create -s <site> -di "Company VPN" -a username-password`.

## Step 2: install

Double-click `Install A-Train.pkg` from the DMG, enter your Mac password once. It installs
`/Applications/A-Train.app`, a root background service, and puts a starter config in `~/vpn-split/config/`.
Log of the install: `/var/log/atrain-install.log`.

## Step 3: routes.conf, one entry per line

```
# Routes that go THROUGH the VPN. Everything not listed uses normal Wi-Fi.
private                            # every RFC1918 network except the one this Mac is on (the default)
10.20.0.0/16                       # office subnets (CIDR)
10.30.4.27                         # one server (IP)
db.internal.example.com            # a hostname: resolved every 5 minutes, each IP gets a route
*.intranet.example.com             # a whole domain: every subdomain you visit is routed as you visit it
10.50.0.0/16 via azure             # send this one through the Azure VPN client instead
gw.example.net via local           # DNS only: resolve on Wi-Fi and pin in /etc/hosts (another VPN's gateway)
#off 10.60.0.0/16                  # kept but disabled (the app's toggle does this)
```

Rules the daemon enforces: prefixes shorter than `/8` are refused (so `0.0.0.0/0` can never hijack everything);
loopback, link-local, multicast and reserved addresses are refused; `#` starts a comment; `#off ` in front
disables an entry; `via azure` needs the Azure VPN client connected. Edits apply within 2 seconds while the VPN
is up; the dashboard's Routes card edits the same file.

How to know what to put there:
- **Subnets:** ask whoever runs the network, or read them off Check Point's own routes once: connect, then
  `netstat -rn -f inet | grep utun` shows what hub mode tunnels. The daemon also saves that list in
  `/usr/local/vpn-split/backups/<timestamp>/deleted_routes.txt` after the first split.
- **A database or server:** its hostname is enough; the daemon resolves it. For a subnet, ask for the CIDR.
- **Source-IP-gated websites** (they show "access denied" off-VPN): add the domain as `*.company.tld`.

## Step 4: checks.conf, what "working" means

```
# host:port  # label. A-Train opens a TCP connection every minute while the VPN is up.
10.30.4.27:3306              # main database
git.internal.example.com:22  # git server
```

Pick the one or two things you actually use. Green in the Reachability card means the port answered through
the tunnel; two failures in a row turn the menu bar icon to a warning and send a notification. A DNS check is
always included.

## Step 5: connect

Menu bar "A" > **Save password…**: enter the site from Step 1, your username and password. Then **Connect VPN**.
Within ~15 s the dashboard shows VPN Connected, Mode Split, and your routes each marked `→ utunN`.
Test: `route -n get <one of your hosts>` shows `interface: utunN`; `route -n get 8.8.8.8` shows `en0`.

## Working checklist

| Symptom | Look at |
|---|---|
| Connected but a host is unreachable | Reachability card; `route -n get <host>` should show utun, not en0 |
| Website says wrong IP / access denied | Add its domain as `*.domain`, or Switch to Full VPN for a while |
| Names stop resolving | Reachability card's DNS row; Troubleshoot; reconnect the VPN (it may have pushed no DNS) |
| "Connecting" forever | Turn off Always Connect in the Check Point client; click Connect VPN in A-Train |
| Anything else | Troubleshoot button (one-click fixes), then Settings > Save diagnostics |

## Undo

`sudo ~/vpn-split/uninstall.sh` removes the service; then disconnect and reconnect the VPN, which restores
Check Point's own routes. Drag the app to the Trash. Your config folder and the route backups stay.

## For agents setting this up for a person

1. Install; leave `routes.conf` at its default (`private`). Only narrow it if the person's home network has
   more than one private subnet and something on the other subnet stopped working.
2. The person enters the password in the app themselves; it goes to the Keychain, nowhere else. Site and
   username are prefilled from `trac info`.
3. Ask one question: "Does any website say access denied unless you are on the VPN?" If yes, add it with
   Route a website… (or `*.domain` in `routes.conf`).
4. Done means: `status.json` (`/usr/local/vpn-split/status.json`) shows `vpn.connected: true`, `mode: split`,
   the `private` entry `applied: true` with its `ips` list of subnets, and the Reachability card green. Checks
   for the servers the person uses appear on their own within a few minutes of use.
