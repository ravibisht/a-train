# VPN split-tunnel: everything you need to know

Written 2026-09-24. Machine: the author's MacBook (macOS). VPN client: Check Point Endpoint Security VPN.

---

## 1. The problem in one paragraph

The corporate Check Point gateway has **Hub Mode** enabled ("route all traffic to gateway").
On connect, the client adds about **91 routes** on a `utunN` interface (gateway `10.0.200.128`)
that together cover the entire IPv4 space, so every packet, including browsing and Postman,
goes through the VPN. It does **not** replace the default route (that stays on `en0`, Wi-Fi).
There is no IT team available to change the gateway. We wanted only the internal DB and one
EC2 host to go via the VPN.

## 2. What we do about it

Scripts live in `~/vpn-split/`. They delete the 91 tiling routes and add back only:

| Route          | Why                                                                  |
|----------------|----------------------------------------------------------------------|
| 10.25.0.0/16   | app server box 10.25.8.118 and other 10.25.x internal hosts         |
| 10.26.0.0/16   | QA database `db.internal.example.com` = 10.26.4.27 |

The tunnel's own link route (`10.0.200.128 -> 10.0.200.129 UHr utunN`) is always kept.
Deleting it kills the tunnel.

### Normal daily use

Open Terminal (not Claude Code's `!` prefix, sudo needs a real terminal):

```
sudo ~/vpn-split/vpn-split.sh          # after connecting the VPN
~/vpn-split/vpn-check.sh 10.26.4.27 8.8.8.8   # confirm
```

Good output looks like:

```
routes on utun7: 3
public IP: 198.51.100.7        <- your home ISP, not 203.0.113.10
route to 10.26.4.27: utun7    <- DB via VPN
route to 8.8.8.8: en0         <- internet via Wi-Fi
```

**You must rerun the split after every VPN reconnect** (laptop sleep, Wi-Fi change,
client restart). Reconnecting restores the full 91-route tiling. To make this automatic (and get a
menu bar switch for Full VPN), install the daemon and the A-Train app: section 8.

### Files in ~/vpn-split

| File               | What it does                                                                   |
|--------------------|--------------------------------------------------------------------------------|
| `vpn-split.sh`     | Backup, delete tiling routes, add needed routes, verify. `--dry-run` prints only. |
| `vpn-restore.sh`   | Re-add everything from a backup. Default = latest backup.                      |
| `vpn-check.sh`     | Show interface, route count, public IP, which interface a host uses.           |
| `backups/<ts>/`    | One folder per run, see section 4.                                             |
| `README.md`        | Short usage notes.                                                             |

Edit the `NEEDED_ROUTES` array at the top of `vpn-split.sh` to add more internal hosts.
Candidates seen in shell history but not yet added: 10.210.0.7, 10.82.129.188, 10.226.21.4.

---

## 3. HOW TO REVERT (from safest to most manual)

### Option A: reconnect the VPN (always works, no sudo)
Disconnect in the Check Point client, connect again. The client re-installs all 91 routes.
This is the full original state. Nothing we did survives a reconnect.

### Option B: restore script
```
sudo ~/vpn-split/vpn-restore.sh                 # latest backup
sudo ~/vpn-split/vpn-restore.sh 20260924-144040 # a specific backup
```
It removes the two routes we added and re-adds the 91 we deleted. It refuses to run if the
tunnel gateway in the backup is not the current one (meaning the VPN already reconnected
and restored itself, so there is nothing to do).

### Option C: manual restore script in this folder
`~/VPN-docs/manual-restore-routes.sh` is a plain list of the 91 `route add` commands from the
2026-09-24 run, no dependency on `~/vpn-split`. Check the gateway first:

```
netstat -rn -f inet | grep UHr            # shows current gateway and utunN
sudo ~/VPN-docs/manual-restore-routes.sh  # edit GW= inside if the gateway changed
```

### Option D: undo by hand
Only the two routes we add need removing to get back to "nothing extra":
```
sudo route -n delete -net 10.25.0.0/16 10.0.200.128
sudo route -n delete -net 10.26.0.0/16 10.0.200.128
```
Then reconnect the VPN for the original tiling.

### Option E: nuclear
Reboot. Routes are not persistent. macOS comes up clean, connect VPN as usual.

---

## 4. Backups

Every `vpn-split.sh` run writes `~/vpn-split/backups/<YYYYMMDD-HHMMSS>/`:

| File                        | Content                                            |
|-----------------------------|----------------------------------------------------|
| `netstat-rn.before.txt`     | Full routing table before any change               |
| `netstat-rn.after.txt`      | Routing table after                                |
| `scutil-dns.before.txt`     | DNS resolver config before                         |
| `ifconfig-utunN.txt`        | Tunnel interface details                           |
| `vpn-if.txt`                | `utunN gateway localIP` detected                   |
| `commands.log`              | Every `route` command executed, in order           |
| `deleted_routes.txt`        | `net|host CIDR gateway` for each deleted route     |
| `added_routes.txt`          | Same format for routes we added                    |

The first real run is `20260924-144040`. A copy of its original routing table is in this
folder as `routing-table-original-2026-09-24.txt`.

---

## 5. IF YOU ARE STUCK

**"I have no internet at all."**
1. `netstat -rn -f inet | grep default` should show `192.168.1.1 ... en0` (or your current
   router). If default is missing: `sudo route -n add default 192.168.1.1`.
2. Turn Wi-Fi off and on. That re-creates the default route.
3. Still nothing: disconnect VPN, reboot.

**"DB / EC2 not reachable after split."**
1. `route -n get 10.26.4.27` must say `interface: utun7` (or whatever utun is current).
   If it says `en0`, the needed route is missing: rerun `sudo ~/vpn-split/vpn-split.sh`.
2. The host may be outside 10.25/10.26. Find its IP (`dig +short <hostname>`), add it to
   `NEEDED_ROUTES`, rerun the split. Or one-off: `sudo route -n add -host <IP> 10.0.200.128`.
3. If the hostname does not resolve at all, check `scutil --dns`. With the daemon running, any
   private nameserver it lists is routed automatically (menu shows "DNS x.x.x.x"). With the manual
   script, add the nameserver IPs to `NEEDED_ROUTES` or use `/etc/hosts`.

**"Nothing resolves / browser says DNS error right after the split."**
The VPN replaced your DNS servers with office ones and they are cut off. Daemon: `tail /var/log/vpnsplitd.log`
should show "DNS servers pushed by the VPN, kept reachable via tunnel". If not, add the IPs from
`scutil --dns` (nameserver lines) to routes.conf. Manual script: same IPs into `NEEDED_ROUTES`.
Quick escape: menu › Switch to Full VPN, or reconnect the VPN.

**"Script says: No Check Point tunnel link route found."**
The VPN is not connected, or the client is mid-reconnect. Connect first, wait a few seconds.

**"Script says: run with sudo."**
You ran it without sudo, or via Claude Code's `!` prefix, which has no terminal for the
password. Use a real Terminal window.

**"Routes came back on their own (vpn-check shows ~90)."**
The VPN reconnected (sleep, Wi-Fi hiccup). Just rerun the split. If it happens while the
tunnel clearly stayed up, Check Point started re-enforcing routes and the approach no longer
works. Fall back to section 6.

**"utun number changed."**
Normal. The scripts detect the interface from the `UHr` link route every run. Never hard-code
`utun7`.

**"Something else on the network broke and I don't know what."**
Reconnect VPN (Option A). That returns the machine to exactly how IT configured it.

**"Public IP still shows 203.0.113.10 after split."**
Some routes still exist. `netstat -rn -f inet | grep utun` and look for anything other than
the UHr line plus 10.25/16 and 10.26/16. Delete stragglers with
`sudo route -n delete -net <dest> 10.0.200.128`, or just rerun the split.

---

## 6. Fallback if route stripping ever stops working

Run the Check Point client inside a VM (UTM or VirtualBox) and forward only the ports you need
to the Mac:

```
ssh -N -L 3306:10.26.4.27:3306 -L 2222:10.25.8.118:22 user@<VM_IP>
```
or a SOCKS proxy for just the DB client:
```
ssh -N -D 1080 user@<VM_IP>
```
Other options: a spare machine on the LAN as VPN relay with the same SSH forwarding, or
check if the gateway supports SNX (Check Point's light Linux client) in Docker.

---

## 7. Facts recorded on 2026-09-24

- Interface at the time: `utun7`, local `10.0.200.129`, gateway `10.0.200.128`.
- Public IP via VPN: `203.0.113.10`. Home ISP: `198.51.100.7`.
- DNS: on the first connection the VPN did **not** change the resolver (stayed `192.168.1.1`). On the
  second connection it **did**: system DNS became the office servers 10.0.10.16, 10.0.10.10 and
  10.80.20.180, reachable only through the tunnel, so after a plain split nothing resolved (every
  lookup timed out after ~30 s). The daemon now detects VPN-pushed private DNS servers and routes them
  through the tunnel automatically; they show in the A-Train menu as "DNS x.x.x.x (automatic)".
  The RDS hostname resolves to the private IP 10.26.4.27 from both resolvers.
- Check Point runs a network filter system extension (`com.checkpoint.fw.filter`). It did
  **not** block direct Wi-Fi traffic and did **not** re-add routes: one hour after the split,
  the route count was still 3 and both 10.26.4.27:3306 and 10.25.8.118:22 connected.
- Hub Mode is usually a deliberate compliance choice. You are aware of that trade-off.

---

## 8. Zero-effort mode: vpnsplitd daemon + A-Train menu bar app

Two pieces. Either works without the other, but you want both.

**vpnsplitd** (root LaunchDaemon `com.ravi.vpnsplitd`, Python, `/usr/local/vpn-split/vpnsplitd.py`)
is the engine. It sits inside `route -n monitor` at zero CPU. When Check Point installs its ~90
routes it waits for 2 s without further route changes (noise events are ignored, 8 s cap), backs
them up, deletes them and adds only the entries from
`~/vpn-split/config/routes.conf`. It re-resolves domain entries every 5 minutes, refreshes the
public IP every 10 minutes, and writes what it sees to `/usr/local/vpn-split/status.json`.
Mode is read from `~/vpn-split/config/control.json`:

| mode    | what the daemon does                                                                 |
|---------|--------------------------------------------------------------------------------------|
| `split` | default. Strip the tiling, keep only routes.conf entries via VPN. Everything else Wi-Fi. |
| `full`  | Put the original routes back from the session backup, so everything goes via VPN again. Optional `full_until` (epoch seconds) after which it flips back to split by itself. |

**A-Train.app** (`~/Applications/A-Train.app`, native menu bar app, A-Train "A" icon) is the remote
control. It never needs sudo: it reads status.json and edits the two config files.

| menu bar icon (A-Train "A" mark, follows light/dark) | meaning                                   |
|------------------------------------------------------|-------------------------------------------|
| solid italic A with speed streaks                    | split mode, VPN connected                 |
| A cut out of a filled block                          | full VPN mode                             |
| outlined A                                           | VPN not connected                         |
| A with a warning dot                                 | daemon not running (status older than 75 s) |

Menu: status lines (connection, mode, public IP) · **Switch to Full VPN** for 15 min / 30 min /
1 h / 2 h / until you switch back (in full mode: **Back to Split now**) · **Routes via VPN** submenu
(tick/untick entries, **Add domain or IP…**, **Open routes file**, **Reload now**) · Open log ·
Open VPN docs folder · **Start at login** (on by default after first launch) · **Quit A-Train**.

Quitting the app changes nothing about routing: the daemon keeps working. Reopen it from Spotlight,
Launchpad or `~/Applications`.

**Dashboard window.** Menu › Open A-Train Dashboard (Cmd+O), or click A-Train in Launchpad / the Dock
while it is running. One window in the A-Train colours: status tiles (VPN, mode, public IP, route count),
the Split / Full VPN switch with the timer choices, the VPN login card (connect, disconnect, auto-reconnect,
saved password), the routes table with switches, add row, remove buttons and live wildcard host counts, and
the daemon log tail. It shows the same state and runs the same actions as the menu; the menu bar stays as
the quick control. It opens once on the very first launch, then only when you ask. 
**Background video.** Drop a green-screen clip at `~/vpn-split/app/video/atrain.mp4` and rebuild
(`bash ~/vpn-split/app/build.sh`); the app keys the green to its navy with a Core Image colour cube (in
sRGB) and plays it muted and looping behind the cards under a dark tint, rendered at 640 px wide to stay
cheap. Footer switch "Background video" turns it off. The clip is not downloaded by the app: for the
"A-Train Status Greenscreen" clip by The Mining Meteor (YouTube), download it yourself; the creator asks
for credit, which the footer shows. That clip is only green for its first ~3.5 s (then a white flash),
after which it is regular show footage, so the app loops from 3.6 s onward and lifts contrast and
brightness slightly so the dark scenes read through the UI tint. The video is shown in *fit* mode (whole
frame, never cropped, so the character is always visible) and the dashboard opens landscape (1180×820)
so a 16:9 clip fills it; cards and tiles darken while the video plays so text stays readable.

Rights note: the footage in that clip belongs to the show's producers; the fan creator's permission
covers their edit, not the underlying footage. So `make-dmg.sh` leaves the clip **out** of the DMG by
default even when it is bundled in your own build. Set `ATRAIN_DMG_VIDEO=1` when running it if you
really want to ship it to a colleague.

### Install (once)
```
sudo ~/vpn-split/install.sh          # daemon (real Terminal window, asks for your password)
bash ~/vpn-split/app/build.sh        # builds and opens the menu bar app, no sudo
```
### Check
```
/usr/bin/python3 /usr/local/vpn-split/vpnsplitd.py --status     # human-readable status.json
tail -f /var/log/vpnsplitd.log
~/vpn-split/vpn-check.sh 10.26.4.27 8.8.8.8
```
### Emergency stop / remove
```
sudo launchctl bootout system/com.ravi.vpnsplitd   # stop the daemon until reboot or reinstall
sudo ~/vpn-split/uninstall.sh                      # remove it (config + backups are kept)
```
then disconnect/reconnect the VPN to get the original routes back. If you only reconnect without
stopping the daemon, it strips the routes again 2 s later (unless the app is in Full VPN mode).
Quicker alternative when you just want everything via VPN for a while: menu › Switch to Full VPN.

Daemon backups live in `/usr/local/vpn-split/backups/<timestamp>/` with the same files as the
manual script (section 4), so `vpn-restore.sh` cannot read them directly (different folder) but
`manual-restore-routes.sh` style recovery works from `deleted_routes.txt` in the same way.

---

### Hardening (v1.1, after code review on 2026-09-24)
- The daemon never writes into `~/vpn-split/config`. An expired Full-VPN timer is simply treated as
  split; control.json keeps saying "full" with a past time, which the app also reads as split.
- Config files are opened without following symlinks, must be regular files under 1 MB, and must be
  owned by the same non-root user as the config folder. Anything else is reported in the menu and ignored.
- Entries with a prefix shorter than /8, or loopback / link-local / multicast / reserved targets, are
  refused with a reason shown next to the entry. This stops a stray `0.0.0.0/0` from pulling all traffic into the tunnel.
- A `default` route on the tunnel (some gateway policies install one) is left alone instead of crashing the daemon.
- Full VPN restores only from a backup taken during the *current* connection, never an older one with a different tiling.
- Domain lookups run in a background thread; broken DNS can no longer stall mode switches.
- `/var/log/vpnsplitd.log` rotates via newsyslog (5 archives, 2 MB each).
- The app shows an error dialog if it cannot write routes.conf or control.json, and shows "Switching to…" while the daemon catches up.
- (2026-09-25) Hub-mode tiling is recognised by what the routes look like (routes the daemon did not add,
  with very short prefixes such as 0/5, 8/7, 128/2), never by how many routes the tunnel has. The first
  wildcard build used a plain count (more than 10 routes = tiling), so once a wildcard routed ten hosts the
  daemon stripped its own routes and re-added them every 2 s, and Full VPN then "restored" that junk instead
  of the real tiling. Full VPN now restores the largest genuine backup of the connection, and junk backups (fewer than 40 routes; real tilings have about 90) are
  pruned at daemon start.
- (2026-09-26, daemon 1.3.1) **Stale routes after disconnect.** When the Check Point tunnel disappears, macOS
  can re-attach the daemon's gateway routes to Wi-Fi instead of dropping them, e.g. `10.26/17 -> 10.0.202.181 on
  en0` pointing at a dead gateway. That black-holed the DB with no VPN, beat Azure's /16, and made the next
  Check Point add fail as "already exists". The daemon now deletes its routes explicitly on disconnect, sweeps
  any of its targets found on non-tunnel interfaces (gateway routes only; LAN/interface routes are never touched),
  and verifies every add actually landed on the tunnel, replacing impostors.
  (1.3.2) The sweep also removes any *dead-gateway* route: a private destination on Wi-Fi/Ethernet whose
  gateway is not on that interface's own network (e.g. the office DNS servers `10.0.10.10`, `10.0.10.16`
  parked on en0 via `10.0.202.181`). Such a route is a black hole whoever added it. On-link gateways
  (your router, DHCP static routes) are never touched. Manual check: `netstat -rn -f inet | grep en0`
  should show no `10.0.2xx.x` gateway. (1.3.3) The rule only inspects LAN interfaces (`en*`, `bridge*`):
  point-to-point VPN interfaces such as `ppp0`/`ipsec0` use peer addresses as gateways and are never touched.
- (2026-09-25) The periodic re-check is a hard 45 s deadline. Earlier it restarted on every routing-socket
  wake-up, and the kernel's constant lookup-miss noise meant status.json could go stale for minutes while the
  daemon was otherwise fine; A-Train then showed "daemon not running" and wildcard rows lost their live counts.

---

## 9. routes.conf: what goes through the VPN

File: `~/vpn-split/config/routes.conf`. Edit it in any editor (menu › Routes via VPN › Open routes
file) or tick/untick/add from the menu. The daemon notices changes within about 2 seconds while
the VPN is connected; when it is not connected, they apply at the next connect.

```
# comment lines start with #
10.26.0.0/16              # a subnet
10.25.8.118               # a single IP
jira.example.com     # a domain: all its IPv4 addresses get a route, re-resolved every 5 min
#off old.example.com      # "#off " in front = disabled but kept (what unticking in the menu does)
```
**Which tunnel carries an entry.** Append `via azure` (or `via checkpoint`, the default) to any entry:
```
10.50.0.0/16 via azure        # Azure VNet subnet
*.corp.example via azure      # whole domain through Azure
10.26.0.0/16                  # Check Point (default)
```
In the dashboard, the add row has a "via" picker and every row shows a Check Point / Azure pill you can click
to switch. Azure entries are added as interface routes on Azure's tunnel and need Azure to be connected
(otherwise the row shows "Azure VPN not connected"). When both tunnels announce the same network with the
same prefix (Azure pushes 10.25/16 and 10.26/16 too), A-Train automatically adds two more-specific halves
via the tunnel you chose, so your choice wins; the manual /17 trick is no longer needed.

Rules: IPv4 only. `10.26.4.27/32` is treated as a single host.

**Two VPNs announcing the same subnet (e.g. Azure VPN Client also pushes 10.25/16 and 10.26/16).** The kernel
keeps whichever route was added first, so the DB can silently end up in the wrong tunnel. Until A-Train has
per-tunnel precedence, list the subnet as two /17s (`10.26.0.0/17` and `10.26.128.0/17`): more-specific routes
always win, so those addresses follow Check Point even with Azure connected. The default routes.conf on this
Mac uses that form since 2026-09-26. Invalid lines are shown in the menu
with ⚠ and ignored. Domains are lowercased. Entries are applied in the order listed; overlaps are fine.

---

## 10. Websites through the VPN: what to expect

- The app resolves the domain from your Mac (home DNS). For company sites that only allow the office
  IP, this is exactly what you want: the browser connects to the same IP the daemon routed.
- Many sites sit behind AWS load balancers whose IPs rotate. The daemon re-resolves every 5 minutes,
  so a site can fail for up to 5 minutes after a rotation. Fix: menu › Routes via VPN › Reload now.
- A site with many CDN IPs (large SaaS) may need a subnet instead of a domain. Look up the IPs
  (`dig +short <domain>`) and add the covering CIDR.
- When the VPN pushes office DNS servers (it does on some connections), the daemon routes them
  through the tunnel automatically, so internal-only names (split-horizon DNS) resolve as in the
  office. When it does not push them, internal-only names will not resolve at home: ask a colleague
  for the IP and add it directly.
- Simplest fallback for a short task: Switch to Full VPN for 15 minutes.

---

## 11. Files, in one place

| Path                                          | What                                                   |
|-----------------------------------------------|--------------------------------------------------------|
| `~/vpn-split/daemon/vpnsplitd.py`             | daemon source (installed copy: `/usr/local/vpn-split/`) |
| `~/vpn-split/daemon/routes.conf.example`      | template for routes.conf                               |
| `~/vpn-split/config/routes.conf`              | your entries (source of truth)                         |
| `~/vpn-split/config/control.json`             | current mode + expiry, written by the app              |
| `~/vpn-split/app/`                            | menu bar app source + `build.sh`; `icon/atrain.svg` + `make-icon.sh` = app icon |
| `~/Applications/A-Train.app`                | the built app                                          |
| `~/vpn-split/install.sh`, `uninstall.sh`      | daemon install / remove (sudo)                         |
| `~/vpn-split/dist/make-dmg.sh`                | builds `A-Train-<version>.dmg` (app + tooling + docs + installer) for sharing with colleagues |
| `~/vpn-split/vpn-split.sh`, `vpn-restore.sh`, `vpn-check.sh` | manual scripts, still work as fallback (section 2, 3) |
| `/usr/local/vpn-split/status.json`            | live daemon status (`vpnsplitd.py --status`)           |
| `/usr/local/vpn-split/backups/`               | daemon backups                                         |
| `/var/log/vpnsplitd.log`                      | daemon log                                             |
| `~/VPN-docs/manual-restore-routes.sh`         | 91 route-add commands from the first day (edit GW=)    |

---

## 12. Sharing A-Train with a colleague

`bash ~/vpn-split/dist/make-dmg.sh` builds `~/vpn-split/dist/A-Train-1.0.dmg` (also copied to the
Desktop). It contains the universal app (Apple Silicon + Intel), the daemon and scripts, this guide,
a `README.txt` and `Install A-Train.command`. On their Mac they open the DMG and double-click the
installer (or run `bash "/Volumes/A-Train/Install A-Train.command"` in Terminal if Gatekeeper
complains, since the app is ad-hoc signed, not notarized). The installer copies the tooling to
`~/vpn-split`, the guide to `~/VPN-docs`, the app to `/Applications` (quarantine removed), then runs
`install.sh` with sudo and opens A-Train. Their `routes.conf` starts from the same defaults and is
never overwritten on reinstall. Requirements: macOS 13+, admin account, Check Point client. No Xcode.


---

## 13. Letting A-Train log in to the VPN (no more password prompts)

Check Point's Mac client ships a command-line tool, `/Library/Application Support/Checkpoint/Endpoint Connect/trac`,
which can connect with `trac connect -s <site> -u <user> -p <password>` and disconnect with `trac disconnect`.
Your site is `203.0.113.10`, authentication is plain username/password (no one-time code), and the
gateway ends every session after about 10 hours (`trac info` shows "remaining time"). Check Point's own
"remember password" is switched off by the gateway policy (`neo_remember_user_password false`).

A-Train's top menu section drives that tool:

| Item | What it does |
|---|---|
| `VPN: Connected · 9 h 54 m left` / `Not connected` / `Connecting…` | live state from `trac info`, refreshed every 10 s |
| **Connect VPN** / **Disconnect VPN** | runs `trac connect` with the saved password / `trac disconnect`. Disconnecting also switches automatic reconnect off until you click Connect again. |
| **Reconnect automatically if the session drops** | when on, and only after you clicked Connect in this A-Train session, A-Train reconnects whenever `trac info` says Idle (session expired, Wi-Fi change). A-Train never connects by itself at login or launch; the first connection is always your click. Disconnect or quitting A-Train cancels it. |
| **Save VPN password…** | site, username (prefilled from `trac info`) and password. Stored in the macOS Keychain as a generic password, service `com.ravi.atrain.vpn`. Use it again when your company password changes. |
| **Forget VPN password** | deletes the Keychain item and turns automatic reconnect off |

Once the tunnel is up the daemon splits it as usual, so one click gives you a connected, split VPN.

**Lockout guard.** Automatic attempts stop after 2 failures and the menu shows the reason. A wrong saved
password therefore cannot lock your account by retrying. Clicking Connect or saving a new password resets the counter.

**Trade-offs, stated plainly**
- The credential is protected by your Mac login only. Anyone at your unlocked Mac can bring the VPN up.
- `trac` takes the password on its command line, so it is visible in the process list for the second the
  command runs. That is how Check Point built the tool; there is no stdin option.
- Keychain prompts: fixed 2026-09-26. The item is now saved with an access list that does not depend on
  A-Train's build identity (`security add-generic-password -A`), so rebuilding the app no longer triggers
  the "allow" dialog. If you saved the password before that date you may see the dialog one last time
  (choose Always Allow); A-Train re-saves the item on that first successful read and it never asks again.
  Trade-off: any program running as you could read the item, the same trust level as your config files.
- Storing a corporate VPN password can be against company policy. Your decision.
- If IT later adds a one-time code (OTP/SecurID), this feature stops working; the Check Point GUI still works.

**Robustness rules built in (hardening pass, 2026-09-24 evening)**
- A-Train reads Check Point's own state every 10 s and only ever starts a connection when the client is truly
  idle (`Idle`/`Disconnected`). If the client is `Connecting`, `Reconnecting`, `Authenticating` or
  `Disconnecting` on its own, or its service is not answering (right after sleep/wake), A-Train waits.
- Before each automatic attempt it probes the gateway on TCP 443. No network means "retry in 30 s", never a
  failure against the password. Only a rejection from the gateway counts toward the 2-failure lockout guard.
- One attempt at a time: clicking Connect twice, or Disconnect while connecting, cannot start overlapping
  `trac` processes.
- Every `trac` and `nc` call has a timeout; a hung process gets SIGTERM and then SIGKILL, so the app can never wedge.
- If macOS denies A-Train access to the Keychain item, that counts as a failure and the menu says so instead of
  prompting every 10 seconds.
- Saving a new password updates the existing Keychain item in place; a failed save leaves the old, working one intact.
- All timing and failure state is shown in the menu: transient problems read "… Retrying automatically."
- (2026-09-26) Check Point itself can wedge in "Connecting" indefinitely (seen with the gateway reachable
  and no login attempt from A-Train). A-Train now resets it with `trac disconnect` after 75 s in that
  state and shows a note; Troubleshoot offers the same reset as a one-click fix.

**Remove the feature's traces:** Forget VPN password in the menu, or delete the `A-Train VPN password` item in Keychain Access.

---

## 14. Wildcard domains (services that check your source IP)

Some backend services allow only the office VPN IP. They read the **real source IP** of the
connection, which no HTTP header can change. The fix is to make that traffic actually leave through
the VPN. For a single host you add its domain to routes.conf. For a whole domain you add a
**wildcard**: `*.example.com`. `example.com` is added for you by default.

How it works: the daemon runs a small DNS forwarder on loopback, and for each wildcard suffix it
writes `/etc/resolver/<suffix>` so macOS sends those lookups to it. When your browser resolves any
`something.example.com`, the forwarder asks the office DNS (routed through the tunnel), adds a
route for each returned IP through the VPN, and returns the answer. So every subdomain you actually
visit is routed automatically; the menu shows how many live hosts each wildcard is currently routing.

Add or remove: menu › Routes via VPN › Add domain or IP… and type `*.suffix`, or edit routes.conf.
Untick a wildcard (or `#off` it) and its resolver file and routes are removed within a couple of seconds.

Trade-off and safety:
- DNS for a wildcarded suffix flows through the daemon while it is enabled. If the forwarder can bind
  loopback port 53, the resolver file also lists the office DNS as a fallback, so if the daemon is
  down the domain still resolves (just not routed) — never worse than before.
- When the VPN disconnects, the daemon removes the resolver files so those domains resolve normally.
- In Full VPN mode the resolver files are removed too, since everything is already tunneled.
- `uninstall.sh` deletes every resolver file the daemon created (they carry a `# managed by vpnsplitd`
  marker on line 1; nothing else is ever touched).
- Wildcards only add routes for public IPs; a private/loopback answer is ignored.

If a service still refuses after adding its wildcard: confirm the VPN is connected and split, open the
service once so a DNS lookup happens, then check the menu shows the wildcard routing at least one host.

---

## 15. Troubleshoot panel, and what can go wrong on a colleague's Mac

Dashboard header › **Troubleshoot** (or menu › Troubleshoot…, Cmd+T). It runs these checks and offers a
one-click fix where one exists. Fixes marked 🔒 run through macOS's own administrator password dialog,
so the app never stores an admin password.

| Check | Fix offered |
|---|---|
| Check Point client installed | none (install the VPN client) |
| Daemon installed and reporting fresh status | 🔒 Install daemon / 🔒 Restart daemon |
| Config files owned by you (the daemon ignores root-owned config) | 🔒 Fix ownership |
| VPN connected | Connect VPN (if a password is saved); if the client is stuck "Connecting", Reset Check Point client |
| Mode is Split | Back to Split |
| No hub-mode tiling left on the tunnel in split mode | 🔒 Restart daemon |
| Every enabled route entry applied; invalid lines listed | Reload routes |
| Wildcard resolver files present | 🔒 Restart daemon |
| DNS resolves through the system resolver | 🔒 Restart daemon (or use Full VPN meanwhile) |
| Public IP shown | informational |

Things fixed *before* they can happen on another machine:
- **No Command Line Tools.** On a Mac without Xcode's CLT, `/usr/bin/python3` is a stub that shows an
  "install developer tools" dialog and exits, so the daemon would never start. The installer now tests
  candidate interpreters (`/usr/bin/python3`, python.org, Homebrew), bakes the working one into the
  LaunchDaemon, and prints `xcode-select --install` instructions if none works.
- The installer waits up to 15 s for the daemon to report status and prints a clear warning if it does not.
- The DMG installer checks macOS ≥ 13, an admin account, and warns if the Check Point client is missing.
- The wildcard DNS forwarder tries several loopback ports (53, 55353, 55354, 55355, 55360) before giving up.
- Hub-mode detection is content-based (see §8 hardening), so a colleague with many wildcard hosts cannot
  trigger the strip loop.

Safety guard (daemon 1.2.2): on every pass the daemon checks that a default route exists on a non-tunnel
interface (your real internet path, which it never touches). If it is ever missing, the daemon logs it,
stops changing routes until it is back, and Troubleshoot shows "No internet default route" with a
Disconnect VPN fix. Disconnecting the VPN always removes every tunnel route, so it is the universal undo.

Bundling the Check Point client (optional): drop the client's installer package (.pkg from IT) into
`~/vpn-split/dist/checkpoint/` and rebuild the DMG. On a Mac without the client, the DMG installer then
installs it (admin dialog) and pre-creates the two company sites. The person still has to allow Check
Point's system extension in System Settings › Privacy & Security once; Apple does not let that be
automated. Without a package, the installer just notes the client is missing and A-Train idles.

Known limits that remain: the app is ad-hoc signed (right-click › Open on first launch); a gateway policy
with a tiling shape not seen here would still be detected as long as it uses short prefixes (/7 or shorter);
if the colleague's Check Point build prints `trac info` differently, the VPN login card degrades to "unknown"
but routing is unaffected.

---

## 16. Azure VPN from A-Train

The Azure VPN Client registers a normal macOS VPN service, so A-Train drives it through the system
(`scutil --nc start/stop/status`) and never needs the Azure window once a profile exists and its Azure AD
sign-in is cached. Menu: "Azure VPN: Connected · <profile>" with **Connect Azure VPN** / **Disconnect Azure VPN**.
Dashboard: an "Azure VPN" card under the login card with the same controls. Troubleshoot shows its state.

- Profiles are discovered on every poll (they get renamed/re-created by the Azure client), never cached by ID.
- If a connect does not reach Connected within 40 s, A-Train stops it and says so: that usually means the Azure AD
  token expired; open the Azure VPN Client once, sign in, and A-Train works again afterwards.
- Azure is split-tunnel by itself (it pushes only its subnets, no DNS) and uses interface routes, so the daemon
  never touches it. Where Azure and Check Point announce the same subnet (10.25/16, 10.26/16), A-Train's /17
  entries make Check Point win; the DB port answers only via Check Point.

## 17. Window, Dock and Settings (2026-09-26)

The dashboard is a normal macOS window now:

- **Dock tile.** By default A-Train shows a Dock icon while the dashboard is open and hides it again when
  you close the window (a menu bar app has no Dock tile otherwise). Settings > Show in Dock: *While
  dashboard is open* / *Always* / *Never*. With a tile you get Cmd-Tab, a right-click Dock menu
  (Open Dashboard, Troubleshoot, Connect/Disconnect VPN) and real full screen.
- **Full screen.** Green button or Ctrl-Cmd-F. Cmd-W closes, Cmd-M minimizes, Cmd-, opens Settings.
- **Where it opens.** On the screen your mouse is on, on the Space you are on (it no longer yanks you
  to another display). Size and position are remembered between launches. If the window ever ends up
  off-screen or the wrong size: Window menu > Reset Window Size and Position, or Settings > Reset.
- **Narrow windows.** Below ~980 pt wide the cards stack in one column and the status tiles form a 2x2
  grid, so the window works at 660x520 and up.
- **Other settings.** Open dashboard when A-Train starts (default off), Start at login (macOS login
  item; never connects the VPN by itself), Background video.
- All of these are per-user preferences in `defaults read com.ravi.atrain`; `defaults delete
  com.ravi.atrain` resets them.

## 18. Installer package, signing and notarization (2026-09-26)

`bash ~/vpn-split/dist/make-dmg.sh` now produces a DMG whose main item is **Install A-Train.pkg** (built by
`dist/make-pkg.sh`). Double-click, Installer.app asks for the Mac password once, and its postinstall does what
the old `.command` did: tooling to `~/vpn-split`, guide to `~/VPN-docs`, root daemon via `install.sh`
(with `VPNSPLIT_USER` set to the installing user), then opens the app. Apps installed by a package are never
quarantined, and Terminal is never needed. Log of a package install: `/var/log/atrain-install.log`.
The postinstall runs the root-owned copy of `install.sh` from the package payload, never the one in the
user's home, and refuses to run for `root` (login window / MDM push). `sudo installer -pkg
"/Volumes/A-Train/Install A-Train.pkg" -target /` does the same from Terminal. The old `.command` fallback is
left out of the DMG unless `make-dmg.sh` runs with `ATRAIN_DMG_FALLBACK=1`. Remove: `sudo ~/vpn-split/uninstall.sh`, delete A-Train.app, `sudo pkgutil --forget com.ravi.atrain.pkg`.

**"macOS cannot verify" prompt.** Gatekeeper only trusts packages signed with a *Developer ID Installer*
certificate and notarized by Apple. Both need a paid Apple Developer Program membership (individual or the
company's team). The only certificate on this Mac is an "Apple Development" one, which Gatekeeper ignores.
Until a Developer ID exists, recipients allow the package once: System Settings > Privacy & Security >
Open Anyway (macOS 15), or right-click > Open (macOS 13-14).

**To make it fully verified** (one-time, ~30 min after enrollment):
1. developer.apple.com > Certificates > create **Developer ID Application** and **Developer ID Installer**
   (the team's Account Holder/Admin does this), download both, double-click into the login keychain.
2. Store notarization credentials once (app-specific password from appleid.apple.com):
   `xcrun notarytool store-credentials ATRAIN_NOTARY --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx`
3. Run `make-dmg.sh` again. It auto-detects the identities: app signed with hardened runtime, pkg signed,
   both notarized and stapled, DMG signed and notarized. Recipients then just double-click.
`pkgutil --check-signature A-Train-1.0.pkg` and `spctl -a -vv -t install A-Train-1.0.pkg` show the result.

Branding (2026-09-27): tagline "Made out of frustration, so you don't have to be." appears in the Installer
window (logo bottom-left, rendered by `dist/pkg/make-background.sh` via `render-background.swift` into
`dist/pkg/resources/background*.png`; welcome/conclusion text), on the mounted DMG (volume icon from
`app/icon/AppIcon.icns`, README line 2), in About A-Train (`NSHumanReadableCopyright`) and under the
dashboard title. Change the wording in `render-background.swift`, `welcome.txt`, `conclusion.txt`,
`dist/payload/README.txt`, `app/Info.plist` and `Dashboard.swift` (header).

## 19. Reachability, notifications, updates, diagnostics, uninstall (2026-09-26)

- **Reachability checks.** `~/vpn-split/config/checks.conf` lists `host:port # comment` (seeded with the QA DB
  3306 and the app server 22). While the VPN is up A-Train opens a real TCP connection to each every minute
  (5 s after connect, and on "Test now"), and shows latency plus the interface the kernel used. Two failures
  in a row while "Connected" turn the menu bar icon to the warning mark, add a "VPN is up but … not reachable"
  line to the menu, and send a notification. Each ip/subnet row in the routes list also shows "→ utun7" (green)
  or "→ en0" (amber): where traffic to that entry would go right now.
- **Notifications** (allow them when macOS asks the first time): session ends in 15 min (with a "Reconnect
  now" button unless auto-reconnect is on), VPN dropped, check failing, update available.
- **Updates.** Settings > Updates takes the URL of a `version.json`; `make-dmg.sh` writes one in `dist/`
  (set `ATRAIN_UPDATE_URL` to the DMG's final URL when building). Checked once a day; nothing installs by
  itself, the notification/menu item opens the download. Builds are compared by CFBundleVersion (`YYYYMMDD.HHMM`).
- **Diagnostics.** Menu > "Save diagnostics to Desktop" (also in Settings): one text file with app/daemon
  status, routes, DNS, interfaces, logs, config, signature. No passwords. Send it to whoever helps you.
- **Uninstall.** Settings > Uninstall A-Train…: admin prompt, then it removes the LaunchDaemon, resolver
  files, daemon files, package receipt and the app. Config and backups stay. Reconnect the VPN afterwards.
- **Team defaults.** Routes card > "Add team defaults" appends any entry from the shipped
  `daemon/routes.conf.example` that is missing from your file (never overwrites). The /17 workaround entries
  were replaced by the plain /16s on 2026-09-26; the daemon splits them itself when Azure overlaps.

## 20. "Full VPN and the internet stopped" (2026-09-27, daemon 1.4.0)

What happened: on the 14:35 connection Check Point pushed **no DNS servers** (earlier sessions the same
day pushed 10.0.10.16/10.0.10.10/10.80.20.180). The Mac kept using the office resolver 192.168.10.2 (from
Wi-Fi DHCP). Full VPN restores hub mode, which sends *everything*, including packets to 192.168.10.2,
through the India gateway, where that address does not exist. Name resolution died, so every website
failed while IP traffic was fine. Plain Check Point in hub mode would have done exactly the same that day.
A second, quieter problem: 192.168.10.2 is not on the Wi-Fi subnet (10.20.96/20), so in split mode the
daemon mistook it for a VPN-pushed server and routed it into the tunnel too.

Fixes in 1.4.0:
- **DNS baseline.** While no tunnel is up the daemon remembers which resolvers are in use (applied.json
  `lan_dns`). After connect, only resolvers that were *not* in that baseline count as VPN-pushed.
- **Full VPN DNS guard.** If the VPN pushed no DNS, the daemon adds host routes for your usual resolvers
  via the Wi-Fi/Ethernet gateway (more specific than the tiling), logs "Full VPN: the VPN pushed no DNS
  servers; keeping DNS … reachable via …" and shows a note in the menu. They are removed on split/disconnect.
- **DNS check in the app.** The Reachability card's first row resolves www.apple.com with `dig` through the
  system resolver every minute while connected; two failures raise the warning icon and a notification.
- The wildcard forwarder falls back to the LAN resolvers when the VPN pushed none.

If it happens again: Full VPN with no VPN DNS is now handled; if names still fail, disconnect/reconnect the
VPN so Check Point pushes its DNS again, and check the Reachability card.

## 21. Hardening round (2026-09-27, daemon 1.4.1)

- **Safety guard vs Internet Sharing.** `bridge100` carries a `default link#N` route. It is not an internet
  path, but the guard counted it. Now only a default route with a real gateway address on Wi-Fi/Ethernet counts.
- **Tunnel identification.** Check Point's link route is `<gateway> <local> UHr utunN` with two different
  private addresses. Tailscale/WireGuard/Cisco-style tunnels have a self-peer route (same address twice) and
  are skipped now, so the daemon can never strip another VPN. Self-test covers both.
- **No VPN DNS in split mode.** The menu shows a note when the VPN pushed no DNS and wildcards are enabled:
  names that only exist on the office DNS will not resolve until you reconnect.
- **Network switch during Full VPN.** If the LAN gateway changes (office Wi-Fi to hotspot), the office-DNS
  pins are re-created for the new gateway.
- **Password rotation.** A rejected login now says plainly that the saved password was refused and how to
  update it; after the second automatic failure a notification says the same.
- **Troubleshoot** gained two checks: an IPv6 internet route on Wi-Fi/Ethernet (bypasses the VPN entirely;
  one-click "Turn IPv6 off on Wi-Fi", revert with `networksetup -setv6automatic "Wi-Fi"`), and browsers
  using DNS over HTTPS (Chrome "secure" mode, Firefox TRR), which makes `*.domain` routing blind.
- **Installer relocation.** The first package run relocated the app into an existing `~/Applications/A-Train.app`
  (Installer follows an existing bundle with the same id). Fixed: the component plist pins every bundle
  (`BundleIsRelocatable=false`), the payload no longer includes the app build folder, and the postinstall removes
  a leftover per-user copy. `app/build.sh` builds into `app/build/` when `~/Applications/A-Train.app` is
  root-owned and records the path in `app/.last-build-path` for the packaging scripts.

## 23. Zero-config (2026-09-30, daemon 1.5.0)

- `private` in routes.conf = 10/8 + 172.16/12 + 192.168/16 through the VPN, minus every network the Mac is
  directly connected to (recomputed on each pass, so it follows you from office Wi-Fi to home). The routes
  card shows how many subnets that became. Check Point's topology (`Trac.config`) is encrypted and hub-mode
  tiling carries no subnet information, so this default replaces asking people for their subnets.
- Learned checks: while connected, A-Train looks at established TCP connections into the tunnel; a private
  destination seen on two consecutive minutes becomes a Reachability check ("learned from your traffic",
  at most 5). Delete any you do not want.
- Route a website…: paste an address, its registrable domain becomes a `*.domain` entry.
- New installs get `private` as the only route entry. Existing routes.conf files are not changed.

## 24. Azure VPN cannot connect while Check Point is up (2026-10-06, daemon 1.5.1)

Symptom: Azure VPN Client sits in "Connecting"; its extension log says `Address resolution failed for
azuregateway-….vpn.azure.com` every 30 s. The moment Check Point disconnects, Azure connects.

Cause: Check Point sets the office DNS servers (10.0.10.x) as the resolver for the Wi-Fi interface as well
as globally. Those servers are only reachable inside the Check Point tunnel. Normal lookups work, because
the daemon routes them through the tunnel. But a network-extension VPN client resolves its gateway name
*bound to the Wi-Fi interface* to avoid routing into a tunnel, and a Wi-Fi-bound query to 10.0.10.16 goes
nowhere. Proven with a UDP query bound to en0: office DNS times out, home router answers in 11 ms;
`dns-sd -i en0 -G v4 www.apple.com` gets no answer at all while Check Point is up.

Fix, two new entry forms, both `via local` (DNS only, never routed):
- `*.vpn.azure.com via local` writes `/etc/resolver/vpn.azure.com` pointing at the LAN resolvers the
  daemon learned while no tunnel was up.
- `azuregateway-….vpn.azure.com via local` resolves that one host through the LAN DNS directly and pins it in
  `/etc/hosts` between `# >>> vpnsplitd` markers. Hosts entries are consulted before any resolver, scoped or
  not, so this is the form that is certain to work. Pins are removed on disconnect and by uninstall.sh.
The gateway hostname is `scutil --nc show <azure service id>` → RemoteAddress. Both forms stay active in
Full VPN too. The dashboard offers "Local DNS" as a third tunnel choice for *.domain rows.
