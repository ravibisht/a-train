A-Train — split tunnel for the Check Point VPN (macOS)
======================================================
Made out of frustration, so you don’t have to be.

Only the internal subnets you list go through the VPN. Everything else (browsing, Postman, calls)
uses your normal internet. A menu bar switch gives you the full VPN back for company websites that
only allow the office IP, for 15 min / 30 min / 1 h / 2 h or until you switch back.

INSTALL (2 minutes, needs your Mac password once)
  1. Double-click "Install A-Train.pkg" and follow the installer.
     If macOS says it "cannot verify" the package: open System Settings > Privacy & Security,
     scroll down and click "Open Anyway" next to the A-Train message, then run it again.
     (That prompt disappears once the package is signed with the company's Apple Developer ID.)
  2. Enter your Mac password when the installer asks (it installs a small background service).
  3. An "A" icon appears in the menu bar. Solid A with speed streaks = split mode is active.
  From Terminal instead:  sudo installer -pkg "/Volumes/A-Train/Install A-Train.pkg" -target /
  Install log: /var/log/atrain-install.log

WHAT GETS INSTALLED
  /Applications/A-Train.app                 menu bar app (starts at login, quit any time)
  /usr/local/vpn-split/  + a LaunchDaemon   background service that adjusts routes when the VPN connects
  ~/vpn-split/                              tooling, scripts, config (routes.conf = what goes via VPN)
  ~/VPN-docs/README.md                      full guide: how it works, how to revert, what to do if stuck

DEFAULT ROUTES VIA VPN
  10.25.0.0/16 and 10.26.0.0/16 (internal / QA database). Edit ~/vpn-split/config/routes.conf
  or use the menu (Routes via VPN > Add domain or IP...) to add subnets, IPs or domain names.
  DNS servers pushed by the VPN are routed automatically.

REVERT / REMOVE
  Quick: menu > Switch to Full VPN, or disconnect/reconnect the VPN after stopping the service.
  Remove: sudo ~/vpn-split/uninstall.sh, then drag A-Train.app to the Trash.

Requires macOS 13+ and Check Point Endpoint Security VPN. Universal binary (Apple Silicon + Intel).
Note: hub mode ("route everything via VPN") is usually a deliberate company policy. This tool is a
personal, fully reversible workaround. Use it responsibly.
