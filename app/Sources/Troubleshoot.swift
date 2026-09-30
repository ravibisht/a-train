import SwiftUI
import AppKit

// Troubleshoot: a checklist that diagnoses the common ways A-Train can fail on a machine and offers a
// one-click fix for each. Fixes that need root run through macOS's own administrator password dialog
// (osascript "with administrator privileges"), so the app itself never holds a password.

enum Admin {
    /// Run a shell command as root via the system password dialog. Blocking; call off the main thread.
    static func run(_ shell: String) -> Result<String, String> {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(error.localizedDescription) }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .success(o) }
        if e.contains("-128") { return .failure("cancelled") }          // user pressed Cancel
        return .failure(e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "exit \(p.terminationStatus)" : e)
    }
}

struct CheckItem: Identifiable {
    enum State { case pass, warn, fail, info }
    let id: String
    var title: String
    var state: State
    var detail: String
    var fixTitle: String? = nil
    var fixNeedsAdmin = false
    var fix: (() -> Void)? = nil
}

/// Everything the checks need from the app, passed as closures so this file stays independent.
struct TroubleshootDeps {
    var statusPath: String
    var confDir: String
    var installScript: String
    var daemonLabel: String
    var currentStatus: () -> DaemonStatus?
    var currentVPN: () -> CheckPoint.Info
    var backToSplit: () -> Void
    var reloadRoutes: () -> Void
    var connectVPN: () -> Void
    var disconnectVPN: () -> Void
    var hasSavedPassword: () -> Bool
    var afterFix: () -> Void
    var notify: (String) -> Void
}

final class TroubleshootModel: ObservableObject {
    @Published var items: [CheckItem] = []
    @Published var running = false
    @Published var lastRun: Date?
    @Published var busyFix: String?
    var deps: TroubleshootDeps!

    func run() {
        guard !running else { return }
        running = true
        let d = deps!
        DispatchQueue.global(qos: .userInitiated).async {
            let items = self.compute(d)
            DispatchQueue.main.async {
                self.items = items
                self.running = false
                self.lastRun = Date()
            }
        }
    }

    var failures: Int { items.filter { $0.state == .fail }.count }
    var warnings: Int { items.filter { $0.state == .warn }.count }

    // MARK: checks (background thread)

    private func compute(_ d: TroubleshootDeps) -> [CheckItem] {
        var out: [CheckItem] = []
        let fm = FileManager.default

        // 1. Check Point client present
        if CheckPoint.isInstalled {
            out.append(CheckItem(id: "cp", title: "Check Point client installed", state: .pass, detail: CheckPoint.trac))
        } else {
            out.append(CheckItem(id: "cp", title: "Check Point client not found", state: .fail,
                                 detail: "Install Check Point Endpoint Security VPN. A-Train has nothing to split without it."))
        }

        // 2. Daemon
        let status = DaemonStatus.load(from: d.statusPath)
        let daemonFix: () -> Void = { [weak self] in self?.adminFix(id: "daemon", "bash '\(d.installScript)'", d) }
        let restartFix: () -> Void = { [weak self] in self?.adminFix(id: "daemon", "launchctl kickstart -k system/\(d.daemonLabel)", d) }
        if status == nil {
            let installed = fm.fileExists(atPath: "/Library/LaunchDaemons/\(d.daemonLabel).plist")
            out.append(CheckItem(id: "daemon", title: installed ? "Daemon installed but not reporting" : "Background daemon not installed",
                                 state: .fail,
                                 detail: installed ? "Its status file is missing. Restarting it usually fixes this."
                                                   : "The root service that adjusts routes is missing. Installing asks for your Mac password once.",
                                 fixTitle: installed ? "Restart daemon" : "Install daemon", fixNeedsAdmin: true,
                                 fix: installed ? restartFix : daemonFix))
        } else if status!.isStale {
            let age = Int(Date().timeIntervalSince1970 - status!.ts)
            out.append(CheckItem(id: "daemon", title: "Daemon not responding", state: .fail,
                                 detail: "Last status \(age) s ago. It should refresh at least every 45 s.",
                                 fixTitle: "Restart daemon", fixNeedsAdmin: true, fix: restartFix))
        } else {
            out.append(CheckItem(id: "daemon", title: "Daemon running (v\(status!.daemonVersion ?? "?"))", state: .pass,
                                 detail: "status refreshed \(Int(Date().timeIntervalSince1970 - status!.ts)) s ago"))
        }

        // 3. Config ownership (daemon refuses config not owned by you)
        let routes = d.confDir + "/routes.conf"
        if let attrs = try? fm.attributesOfItem(atPath: routes), let uid = attrs[.ownerAccountID] as? NSNumber {
            if uid.uint32Value == getuid() {
                out.append(CheckItem(id: "perm", title: "Config files owned by you", state: .pass, detail: routes))
            } else {
                let user = NSUserName()
                out.append(CheckItem(id: "perm", title: "Config files owned by another user", state: .fail,
                                     detail: "The daemon ignores routes.conf unless it belongs to you (owner uid \(uid)).",
                                     fixTitle: "Fix ownership", fixNeedsAdmin: true,
                                     fix: { [weak self] in self?.adminFix(id: "perm", "chown -R '\(user)' '\(d.confDir)'", d) }))
            }
        } else {
            out.append(CheckItem(id: "perm", title: "routes.conf missing", state: .warn,
                                 detail: "It is created on first launch or install. Add a route to create it.",
                                 fixTitle: "Create default", fix: { d.reloadRoutes(); d.afterFix() }))
        }

        // 4. VPN connection (query the client fresh; the app's cached value may be seconds old or unset)
        let vpn = CheckPoint.isInstalled ? CheckPoint.info() : d.currentVPN()
        if !vpn.installed {
            // covered by check 1
        } else if !vpn.serviceUp {
            out.append(CheckItem(id: "vpn", title: "Check Point service not responding", state: .warn,
                                 detail: "Usually right after sleep/wake. Wait a few seconds, or open the Check Point app once."))
        } else if vpn.connected {
            out.append(CheckItem(id: "vpn", title: "VPN connected", state: .pass,
                                 detail: [vpn.site, vpn.remainingPretty].compactMap { $0 }.joined(separator: " · ")))
        } else if vpn.busy {
            out.append(CheckItem(id: "vpn", title: "VPN is \(vpn.status.lowercased())", state: .warn,
                                 detail: "A healthy connect takes 10-20 s. If this has been stuck for a minute, reset the client and connect again.",
                                 fixTitle: "Reset Check Point client",
                                 fix: { DispatchQueue.global().async { _ = CheckPoint.disconnect(); DispatchQueue.main.async { d.afterFix() } } }))
        } else {
            out.append(CheckItem(id: "vpn", title: "VPN not connected", state: .warn,
                                 detail: d.hasSavedPassword() ? "Nothing is routed until the tunnel is up." : "Save your VPN password in the dashboard to connect from here.",
                                 fixTitle: d.hasSavedPassword() ? "Connect VPN" : nil,
                                 fix: d.hasSavedPassword() ? { d.connectVPN() } : nil))
        }

        // 4b. Azure VPN (informational; it is split by itself and never touched by the daemon)
        if let a = AzureVPN.services().first {
            out.append(CheckItem(id: "azure", title: "Azure VPN \(a.state.lowercased()) (\(a.name))", state: .info,
                                 detail: a.connected ? "Azure routes only its own subnets. Overlaps with Check Point (10.25/16, 10.26/16) are won by A-Train's /17 entries."
                                                     : "Connect it from the A-Train menu when you need Azure resources."))
        }

        guard let s = status, !s.isStale, vpn.connected else {
            out.append(CheckItem(id: "routes", title: "Route checks skipped", state: .info,
                                 detail: "They need the daemon running and the VPN connected."))
            return out
        }

        // 5. Safety guard tripped? (daemon saw no internet default route and is standing still)
        if let n = s.note, n.contains("No internet default route") {
            out.append(CheckItem(id: "default", title: "No internet default route", state: .fail,
                                 detail: "macOS has no default route on Wi-Fi/Ethernet. Toggle Wi-Fi off and on; disconnecting the VPN also clears every tunnel route.",
                                 fixTitle: "Disconnect VPN", fix: { d.disconnectVPN() }))
        }

        // 5b. Mode
        if s.mode == "full" {
            out.append(CheckItem(id: "mode", title: "Full VPN mode is on", state: .warn,
                                 detail: "Everything goes through the office. Fine on purpose; switch back when done.",
                                 fixTitle: "Back to Split", fix: { d.backToSplit(); d.afterFix() }))
        } else {
            out.append(CheckItem(id: "mode", title: "Split mode", state: .pass, detail: "Only listed routes use the VPN."))
        }

        // 6. Hub-mode tiling should not be present in split mode
        if s.mode == "split", s.tiling == true {
            out.append(CheckItem(id: "tiling", title: "Check Point's full tiling is still on the tunnel", state: .fail,
                                 detail: "The daemon should have removed it. Restarting the daemon re-applies the split.",
                                 fixTitle: "Restart daemon", fixNeedsAdmin: true, fix: restartFix))
        }

        // 7. Entries applied
        if s.mode == "split" {
            let enabled = (s.entries ?? []).filter { $0.enabled && ($0.kind == "cidr" || $0.kind == "ip" || $0.kind == "domain") }
            let missing = enabled.filter { $0.applied != true }
            let invalid = (s.entries ?? []).filter { $0.enabled && ($0.kind ?? "").isEmpty }
            if enabled.isEmpty {
                out.append(CheckItem(id: "routes", title: "No routes configured", state: .warn,
                                     detail: "Nothing goes via the VPN. Add your DB subnet or hosts in the dashboard."))
            } else if missing.isEmpty {
                out.append(CheckItem(id: "routes", title: "All \(enabled.count) route entries applied", state: .pass,
                                     detail: enabled.map { $0.raw }.joined(separator: ", ")))
            } else {
                out.append(CheckItem(id: "routes", title: "\(missing.count) route entr\(missing.count == 1 ? "y" : "ies") not applied", state: .fail,
                                     detail: missing.map { "\($0.raw)\($0.error.map { " (\($0))" } ?? "")" }.joined(separator: ", "),
                                     fixTitle: "Reload routes", fix: { d.reloadRoutes(); d.afterFix() }))
            }
            if !invalid.isEmpty {
                out.append(CheckItem(id: "invalid", title: "\(invalid.count) invalid entr\(invalid.count == 1 ? "y" : "ies") in routes.conf", state: .warn,
                                     detail: invalid.map { "\($0.raw): \($0.error ?? "invalid")" }.joined(separator: "; ")))
            }
            let wild = (s.entries ?? []).filter { $0.enabled && $0.kind == "wildcard" }
            let deadWild = wild.filter { $0.resolver != true }
            if !wild.isEmpty {
                if deadWild.isEmpty {
                    out.append(CheckItem(id: "wild", title: "Wildcard DNS forwarder active", state: .pass,
                                         detail: wild.map { "\($0.raw) (\($0.ips?.count ?? 0) live)" }.joined(separator: ", ")))
                } else {
                    out.append(CheckItem(id: "wild", title: "Wildcard resolver not installed", state: .fail,
                                         detail: deadWild.map { "\($0.raw): \($0.error ?? "")" }.joined(separator: "; "),
                                         fixTitle: "Restart daemon", fixNeedsAdmin: true, fix: restartFix))
                }
            }
        }

        // 8. DNS works through the system resolver (broken DNS after a split is the classic symptom)
        let dnsOK = Self.resolves("apple.com") || Self.resolves("cloudflare.com")
        if dnsOK {
            out.append(CheckItem(id: "dns", title: "DNS resolves", state: .pass, detail: "system resolver answered"))
        } else {
            let pushed = (s.entries ?? []).filter { $0.kind == "dns" }.map { $0.raw }
            out.append(CheckItem(id: "dns", title: "DNS is not resolving", state: .fail,
                                 detail: pushed.isEmpty ? "The VPN may have replaced your DNS servers with office ones the daemon did not catch. Restart the daemon, or use Full VPN to work meanwhile."
                                                        : "VPN DNS servers routed: \(pushed.joined(separator: ", ")). Restart the daemon to re-apply.",
                                 fixTitle: "Restart daemon", fixNeedsAdmin: true, fix: restartFix))
        }

        // 8b. IPv6 internet bypasses the VPN entirely (hub mode and the daemon are IPv4-only)
        if let (v6if, service) = Self.ipv6Default() {
            out.append(CheckItem(id: "ipv6", title: "IPv6 internet on \(v6if): bypasses the VPN", state: .warn,
                                 detail: "Sites reachable over IPv6 use your ISP address even in Full VPN, so a source-IP check can pass or fail per site. Turn IPv6 off on \(service) while you need Full VPN. Revert: networksetup -setv6automatic \"\(service)\".",
                                 fixTitle: "Turn IPv6 off on \(service)", fixNeedsAdmin: true,
                                 fix: { [weak self] in self?.adminFix(id: "ipv6", "networksetup -setv6off \"\(service)\"", d) }))
        }

        // 8c. Browser DNS-over-HTTPS resolves names without the system resolver: wildcard routing never sees them
        for (browser, how) in Self.dohEnabled() {
            out.append(CheckItem(id: "doh-" + browser, title: "\(browser) resolves DNS itself (DNS over HTTPS)", state: .warn,
                                 detail: "*.domain routing works through the system resolver. \(how)"))
        }

        // 9. Public IP sanity (informational)
        if let ip = s.publicIp, !ip.isEmpty {
            out.append(CheckItem(id: "ip", title: "Public IP \(ip)", state: .info,
                                 detail: s.mode == "split" ? "Should be your home/ISP address in split mode." : "Should be the office address in Full VPN mode."))
        }
        return out
    }

    /// (interface, network service name) of an IPv6 default route on Wi-Fi/Ethernet, if any.
    private static func ipv6Default() -> (String, String)? {
        let (_, out) = Reachability.shell("/usr/sbin/netstat", ["-rn", "-f", "inet6"], timeout: 5)
        guard let line = out.components(separatedBy: "\n").first(where: { l in
            let p = l.split(separator: " ").map(String.init)
            return p.count >= 4 && p[0] == "default" && (p.last ?? "").hasPrefix("en") && !p[1].hasPrefix("fe80")
        }) else { return nil }
        let ifn = line.split(separator: " ").last.map(String.init) ?? "en0"
        // map en0 -> "Wi-Fi" via networksetup
        let (_, ports) = Reachability.shell("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 5)
        var service = "Wi-Fi", current = ""
        for l in ports.components(separatedBy: "\n") {
            if l.hasPrefix("Hardware Port:") { current = l.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces) }
            if l.hasPrefix("Device:"), l.contains(ifn) { service = current; break }
        }
        return (ifn, service)
    }

    /// Browsers configured to resolve names themselves: [(browser, how to change it)].
    private static func dohEnabled() -> [(String, String)] {
        var out: [(String, String)] = []
        let (_, chrome) = Reachability.shell("/usr/bin/defaults", ["read", "com.google.Chrome", "DnsOverHttpsMode"], timeout: 3)
        if chrome.trimmingCharacters(in: .whitespacesAndNewlines) == "secure" {
            out.append(("Chrome", "Chrome > Settings > Privacy and security > Security > Use secure DNS: choose \"With your current service provider\" or turn it off."))
        }
        let ffDir = NSHomeDirectory() + "/Library/Application Support/Firefox/Profiles"
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: ffDir) {
            for pr in profiles {
                if let prefs = try? String(contentsOfFile: ffDir + "/" + pr + "/prefs.js", encoding: .utf8),
                   prefs.contains("\"network.trr.mode\", 3") || prefs.contains("\"network.trr.mode\", 2") {
                    out.append(("Firefox", "Firefox > Settings > Privacy & Security > DNS over HTTPS: set to Off (or Default protection)."))
                    break
                }
            }
        }
        return out
    }

    private static func resolves(_ host: String) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, nil, &hints, &res)
        if let r = res { freeaddrinfo(r) }
        return rc == 0
    }

    // MARK: fixes

    private func adminFix(id: String, _ shell: String, _ d: TroubleshootDeps) {
        DispatchQueue.main.async { self.busyFix = id }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Admin.run(shell)
            DispatchQueue.main.async {
                self.busyFix = nil
                switch r {
                case .success:
                    d.notify("Done. Re-checking in a few seconds…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { d.afterFix(); self.run() }
                case .failure(let msg):
                    if msg != "cancelled" { d.notify("That fix failed: \(msg)") }
                }
            }
        }
    }
}

struct TroubleshootView: View {
    @ObservedObject var t: TroubleshootModel

    var body: some View {
        Card("Troubleshoot") {
            HStack {
                Button(t.running ? "Checking…" : "Run checks") { t.run() }.buttonStyle(AccentButtonStyle(color: Theme.blue)).disabled(t.running)
                if let when = t.lastRun {
                    Text("Last run \(when.formatted(date: .omitted, time: .shortened)) · \(t.failures) problem\(t.failures == 1 ? "" : "s"), \(t.warnings) warning\(t.warnings == 1 ? "" : "s")")
                        .font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                Spacer()
                Text("Fixes marked 🔒 ask for your Mac password (macOS dialog).").font(.system(size: 11)).foregroundColor(Theme.dim)
            }
            if t.items.isEmpty && !t.running {
                Text("Checks the VPN client, the background daemon, file permissions, mode, applied routes, the wildcard resolver and DNS, and offers a one-click fix where one exists.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            VStack(spacing: 0) {
                ForEach(t.items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(item.state)).foregroundColor(color(item.state)).frame(width: 20).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 13, weight: .semibold))
                            Text(item.detail).font(.system(size: 11)).foregroundColor(Theme.dim).lineLimit(3)
                        }
                        Spacer()
                        if let title = item.fixTitle, let fix = item.fix {
                            Button(t.busyFix == item.id ? "Working…" : (item.fixNeedsAdmin ? "🔒 \(title)" : title)) { fix() }
                                .buttonStyle(GhostButtonStyle()).disabled(t.busyFix != nil)
                        }
                    }
                    .padding(.vertical, 8)
                    Divider().background(Theme.line)
                }
            }
        }
    }

    private func icon(_ s: CheckItem.State) -> String {
        switch s {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ s: CheckItem.State) -> Color {
        switch s {
        case .pass: return Theme.ok
        case .warn: return Theme.warn
        case .fail: return Theme.red
        case .info: return Theme.dim
        }
    }
}
