# A-Train

**Split tunnel for the Check Point Endpoint Security VPN on macOS.**
Only your company's internal networks go through the VPN. Everything else stays on your own internet.

> Made out of frustration, so you don't have to be.

<p align="center"><img src="app/icon/preview.png" width="160" alt="A-Train icon"></p>

## Why it exists

Many companies run Check Point in **hub mode**: the moment you connect, every packet on your Mac is routed
through the office gateway, often on another continent. Video calls stutter, downloads crawl, Spotify buffers,
and your public IP becomes the office's. You only wanted to reach one database.

A-Train fixes the routing, not the VPN. It watches for Check Point's ~90 hub-mode routes, backs them up,
removes them, and adds routes for just the destinations you care about. A menu bar switch brings the full
tunnel back for as long as you need it. Disconnect the VPN and Check Point's own routes return by themselves.

## Why "A-Train"

A-Train is the speedster in *The Boys*: the fastest man alive, and not a nice guy. The joke wrote itself.
Hub-mode VPN makes your laptop feel like it is wading through mud; this app makes it fast again, and it does
so by being slightly ruthless with someone else's routing table. The icon is an original mark, an italic A
with speed streaks, and the dashboard plays a green-screen clip of the character behind the cards. The clip
is not in this repository: `app/build.sh` downloads it with `yt-dlp` on first build, with credit to its
creator in the footer (see `app/video/README.txt`). The project is not affiliated with Amazon, Sony, or Check Point.

## What you get

- **Zero-config split.** The default routes file has one entry, `private`: every RFC1918 network reaches
  the VPN, minus the network your Mac is on. Internal servers work, your printer still works, and the rest
  of the internet leaves through your own connection.
- **Precise control when you want it.** Subnets, single hosts, DNS names (re-resolved every 5 minutes),
  whole domains (`*.intranet.example.com`), and per-entry choice of tunnel when the Azure VPN client is also
  in use (`… via azure`).
- **Route a website.** A site that only allows the office IP? Paste its address; its domain goes through
  the VPN. A local DNS forwarder plus `/etc/resolver` makes wildcard domains work.
- **Full VPN for a while.** 15 minutes, an hour, or until you switch back. Restored from the session's
  backup, so it is exactly what Check Point installed.
- **VPN login from the menu bar.** Password in the Keychain, never on disk. Optional auto-reconnect when the
  session drops, never at login. Copes with the Check Point client's stuck "Connecting" states and crashes.
- **Reachability.** Real TCP connects to the hosts you use (learned from your traffic) plus a DNS check,
  every minute while connected. Two failures turn the icon amber and send a notification, so "connected but
  nothing works" is caught in seconds.
- **Troubleshoot** with one-click fixes, a diagnostics file for support, an installer package, an in-app
  uninstall, and an optional update check against a JSON you host.

## Install

Download the DMG from Releases, open it, double-click **Install A-Train.pkg**, enter your Mac password.
Until the package is signed with an Apple Developer ID, macOS will ask you to allow it once in
System Settings > Privacy & Security.

Then click the **A** in the menu bar > **Save password…** (site and username are prefilled from the Check Point
client) > **Connect VPN**. That is the whole setup. `SETUP.md` covers the precise-control options.

Requirements: macOS 13+, an admin account, the Check Point Endpoint Security VPN client, Python 3.9+
(present once Xcode Command Line Tools are installed).

## How it works

```
 Check Point client ──(routes)──▶ kernel routing table ◀──(route -n monitor)── vpnsplitd (root, launchd)
                                         ▲                                            │
                                         │ adds/removes routes                        │ status.json
                                         └────────────────────────────────────────────▼
 ~/vpn-split/config/{routes.conf, control.json, checks.conf} ◀──── A-Train.app (menu bar + dashboard)
```

Two processes that never call each other. The root daemon (`daemon/vpnsplitd.py`, one file, standard library
only) reacts to routing-table events and the config folder. The user-level app edits the config, reads the
status, and drives the Check Point CLI. `AGENTS.md` describes the contract between them and the invariants
that keep the daemon safe; `docs/GUIDE.md` is the long-form guide with the revert steps and the history of
every incident that shaped the design.

**Safety rules built into the daemon:** it never touches the internet default route and stops entirely if that
route disappears; it refuses entries shorter than /8; it backs up before every change; it only manages the
tunnel it identified as Check Point's and leaves other VPNs alone; it reads your config without following
symlinks and never writes into your home. `SECURITY.md` has the full list.

## Build from source

```
python3 daemon/vpnsplitd.py --self-test   # unit + end-to-end checks against a fake routing table, no root
bash app/build.sh                         # universal app into app/build/A-Train.app (needs swiftc)
sudo ./install.sh                         # daemon + LaunchDaemon on this Mac
bash dist/make-dmg.sh                     # installer package + DMG (signs and notarizes if a Developer ID is present)
```

An internal build can ship company defaults (routes, checks, the Check Point site) from a gitignored
`dist/profile/` folder; the public tree contains example values only.

## Status and limitations

- Tested on macOS 14 to 26 with Check Point Endpoint Security VPN E86/E87 in hub mode; Apple Silicon and Intel.
- IPv4 only. If your network has IPv6 internet, that traffic bypasses the VPN entirely; Troubleshoot warns
  and can turn IPv6 off per interface.
- Hub mode is usually a deliberate company policy. A-Train is a personal, fully reversible workaround. Use it
  with your employer's knowledge.
- Other VPN clients: the daemon only needs to find a tunnel and its routes, so ports are feasible. Issues welcome.

## Contributing

See `CONTRIBUTING.md`. The self-test must stay green and each invariant in `AGENTS.md` must survive.

## License

MIT. See `LICENSE`.
