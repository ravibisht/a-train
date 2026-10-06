# A-Train (vpn-split)

Split tunnel for the Check Point Endpoint Security VPN on macOS. Check Point in *hub mode* pushes ~90 routes that
send all traffic through the office gateway; A-Train removes them and routes only the entries the user lists, so
everything else stays on the local internet. A menu bar app switches back to the full tunnel on demand.

## Map

Two processes that never call each other. They talk only through files, and that file contract is the architecture.

| Process | Runs as | Source | Role |
|---|---|---|---|
| `vpnsplitd` | root, LaunchDaemon `com.ravi.vpnsplitd` | `daemon/vpnsplitd.py` (single file, stdlib only) | Watches the routing table (`route -n monitor`) and the config dir (kqueue); strips the tiling, adds the user's routes, runs the wildcard DNS forwarder |
| A-Train.app | the user | `app/Sources/*.swift` (AppKit + SwiftUI, no Xcode project) | Menu bar + dashboard: edits config, reads status, drives the Check Point CLI (`trac`) and Azure VPN (`scutil --nc`) |

| File | Written by | Read by |
|---|---|---|
| `~/vpn-split/config/routes.conf` | user / app | daemon |
| `~/vpn-split/config/control.json` (`mode`, `full_until`) | app | daemon |
| `~/vpn-split/config/checks.conf` (`host:port`) | user / app | app only |
| `/usr/local/vpn-split/status.json` | daemon | app |
| `/usr/local/vpn-split/applied.json`, `backups/<ts>/` | daemon | daemon |

The daemon module docstring is the reference for its modes, files and CLI. `routes.conf` grammar lives in the
`RoutesFile.template` comment (`app/Sources/Config.swift`) and in the daemon's `load_entries`.

## Verification loop

Every change ends *green* on the loops for the parts it touched:

- **Daemon:** `python3 daemon/vpnsplitd.py --self-test` prints `self-test OK`. It runs unit checks plus an
  end-to-end pass against a fake routing table (`fake_sh` in `self_test`), no root. A daemon behaviour change
  ships with a self-test case that fails without it.
- **Daemon against the real table, read-only:** `sudo python3 daemon/vpnsplitd.py --once --dry-run` prints the
  route commands it would run.
- **App:** `bash app/build.sh` compiles a universal binary into `app/build/A-Train.app` and launches it.
  `ATRAIN_TESTHOOKS=1 bash app/build.sh` compiles the test hooks in: `ATRAIN_TEST_WINDOW=WxH[:cardId[:delay]]`
  opens the dashboard at a size and scrolls to a card; release builds contain no hooks.
- **Screenshots of the dashboard:** find the on-screen window with `CGWindowListCopyWindowInfo` (owner
  `A-Train`, `kCGWindowIsOnscreen`, height > 300; hidden helper windows exist), then `screencapture -l<id>`.
- **Package:** `bash dist/make-dmg.sh` builds the app, `dist/A-Train-<ver>.pkg` (via `dist/make-pkg.sh`) and the
  DMG. `pkgutil --expand` the pkg to inspect `Distribution`, `PackageInfo` and scripts.

## Invariants

Each of these exists because it broke once. Keep them when changing nearby code.

- **Root reads, never writes, the user's config dir.** The daemon reads with `read_user_file` (`O_NOFOLLOW` +
  owner check) and never creates or rewrites files there. The user owns `control.json`; the app writes it.
- **The internet default route is untouchable.** Before touching anything the daemon requires a default route on
  a non-tunnel interface *with a real gateway address* (`internet_default_present`); Internet Sharing's
  `default link#N bridge100` does not count. No such route: log `SAFETY:` and stand still.
- **Check Point's tunnel is the utun whose `UHr` link route has two different private addresses** (`find_tunnel`).
  Self-peer link routes (Tailscale, WireGuard, Cisco) are other VPNs and stay untouched. Azure is found separately
  (`find_azure`) and gets interface routes (`-interface utunN`).
- **Tiling is judged by content, not count** (`tiling_present`): wildcard routing legitimately adds dozens of
  host routes; a count threshold once made the daemon strip and re-add its own routes every 2 s.
- **Every strip is backed up first**, and Full VPN restores the *largest* backup of the current connection
  (`find_session_backup`). Junk backups are pruned at start.
- **Stale-route sweep is scoped to LAN interfaces** (`en*`, `bridge*`). macOS re-parents a vanished tunnel's
  gateway routes onto Wi-Fi; `sweep_stale` removes our targets there plus any private route whose gateway is
  off-link (`dead_gateway_routes`). Point-to-point interfaces carry peer gateways and are never inspected.
- **VPN-pushed DNS = resolvers absent from the no-tunnel baseline** (`State.lan_dns`). An office resolver can be
  off-subnet and still be the LAN's. In Full VPN with no pushed DNS, the LAN resolvers are pinned to the LAN
  gateway (`st.applied_lan`), or name resolution dies inside the tunnel.
- **`private` carves out the LAN** (`private_targets`, `lan_carve`): RFC1918 minus every directly connected
  private network, recomputed each evaluate, so the LAN gateway and LAN devices never enter the tunnel.
  Prefixes stay ≥ /8 (`MIN_PREFIX`).
- **`via local` is DNS-only.** `*.suffix via local` writes a resolver file pointing at the LAN baseline
  resolvers; `host via local` pins the host in `/etc/hosts` between `HOSTS_BEGIN`/`HOSTS_END` markers after
  resolving it through the LAN DNS (`lan_resolve`, raw UDP). Neither ever adds a route. Needed because
  network-extension VPN clients resolve bound to Wi-Fi, where VPN-pushed DNS is unreachable.
- **Wildcards (`*.suffix`)** work through a loopback DNS forwarder plus `/etc/resolver/<suffix>`; every resolver
  file the daemon writes starts with `# managed by vpnsplitd`, and only files with that marker are removed.
- **Connecting goes through `CheckPoint.connect`** (`app/Sources/VPN.swift`). A manual connect takes over a
  password-less "Connecting" started by Check Point's own Always Connect, waits for a restarting service, and
  retries once if the `TracSrvWrapper` PID changes mid-connect (the service is known to crash).
- **Passwords live only in the Keychain** (service `com.ravi.atrain.vpn`, saved with `security
  add-generic-password -A` so ad-hoc re-signed builds keep access). They reach `trac` as an argument, never a file.
- **The installed app is `/Applications/A-Train.app`**, root-owned, from the pkg. Builds go to `app/build/`; the
  path of the last build is in `app/.last-build-path`, which the packaging scripts read. The component plist marks
  every bundle `BundleIsRelocatable=false`, because Installer once relocated the app onto a stray copy.

## Working on a live machine

Internal builds carry company defaults from the gitignored `dist/profile/` (see its README.txt); the public tree ships example.com values only.

The daemon changes the real routing table of the Mac it runs on. Reach for the read-only tools first:
`--self-test`, `--once --dry-run`, `--status`, `netstat -rn -f inet`, `route -n get <ip>`, `scutil --dns`,
`/var/log/vpnsplitd.log`. Installing (`sudo ./install.sh`, or the pkg) and `launchctl` changes need the human's
password; hand them the exact command. Undo paths: `sudo ./uninstall.sh`, then reconnect the VPN, which
rebuilds Check Point's own routes; `vpn-restore.sh` replays a backup by hand.

## Setting it up for someone

`SETUP.md` is the setup contract. Zero-config: the default `private` route entry, site and username
prefilled from `trac info`, checks learned from live tunnel connections (`establishedPrivatePeers`, two
sightings). The one question for the human: which website refuses them off-VPN (Route a website…).
Completion criterion: status.json connected + split, `private` applied, Reachability green.

## Deeper reference

- **User guide, revert steps and incident write-ups** (hub-mode tiling, stale routes, Full VPN DNS, installer
  relocation, Check Point crashes): `docs/GUIDE.md`. Its numbered sections are the design history.
- **Check Point client evidence:** `/Library/Application Support/Checkpoint/Endpoint Connect/helpdesk.log` (a good
  connect shows `Starting new connection` right after `No need to upgrade client`) and
  `~/Library/Logs/CheckPoint/Endpoint Connect/command_line.log*`.
- **Signing and notarization:** header comment of `dist/make-pkg.sh`.
