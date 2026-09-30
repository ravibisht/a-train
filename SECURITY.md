# Security

A-Train runs a root daemon that edits the macOS routing table and writes files under `/etc/resolver`.
Treat every change to `daemon/vpnsplitd.py` as security-relevant.

## What the daemon will and will not do

- It only ever touches routes on the Check Point tunnel interface, plus its own host/network routes,
  plus leftover routes on Wi-Fi/Ethernet that point at a dead VPN gateway. The internet default route is
  never modified; if it is missing the daemon stops changing anything.
- It refuses route entries shorter than /8 and any loopback, link-local, multicast or reserved target,
  so a config file cannot hijack all traffic.
- It reads the user's config with `O_NOFOLLOW` and an owner check, and never writes into the user's
  home directory.
- Resolver files it writes start with `# managed by vpnsplitd`; only those are ever removed.
- No network traffic of its own except an HTTPS request to learn the public IP (three well-known
  endpoints) and DNS forwarding for wildcard entries to the VPN's own resolvers.

## The app

- The VPN password is stored in the macOS Keychain and passed to Check Point's `trac` CLI as an
  argument. It is never written to disk by A-Train.
- Root actions from the app (Troubleshoot fixes, uninstall) go through the standard macOS
  administrator prompt with a fixed, inline script; nothing from the user's home is executed as root.

## Reporting

Open a GitHub issue for anything that is not a live exploit. For something exploitable, email the
maintainer listed on the GitHub profile instead of filing it publicly. Include macOS version, the
daemon log (`/var/log/vpnsplitd.log`) and, if relevant, a diagnostics file from Settings > Save diagnostics
(it contains no passwords).
