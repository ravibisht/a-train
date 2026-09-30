Optional: put the Check Point Endpoint Security VPN installer package here (a .pkg from IT / the
Check Point support portal, e.g. Endpoint_Security_VPN.pkg). make-dmg.sh bundles it, and the DMG
installer offers to install it (admin dialog) on Macs that do not have the client, then pre-creates
the two company VPN sites (203.0.113.10 and vpn.example.com).

Notes:
- macOS will ask the person to allow Check Point's network/system extension in
  System Settings > Privacy & Security after the install. That approval cannot be automated.
- Use the same client build as the gateway expects (this Mac runs build 986202311).
- Only distribute the package internally, under the company's licence.
