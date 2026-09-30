import Foundation

// Reachability checks: "is the database actually reachable, and through which interface?"
// Specs live in ~/vpn-split/config/checks.conf (host:port # comment). The app runs them itself (no root):
// `route -n get host` tells the interface, a TCP connect with a 3 s timeout tells reachability.

struct CheckSpec: Equatable, Identifiable {
    let host: String
    let port: Int
    let comment: String
    var raw: String { port == 0 ? host : "\(host):\(port)" }
    var id: String { raw }
    var label: String { comment.isEmpty ? raw : comment }
    var builtIn: Bool { port == 0 }

    /// Always-on first row: does name resolution work through the resolver macOS is using right now?
    /// (2026-09-27: Full VPN with no VPN-pushed DNS sent lookups for the office resolver into the tunnel.)
    static let dns = CheckSpec(host: "dns", port: 0, comment: "DNS resolution (www.apple.com)")
}

struct CheckResult: Equatable {
    let raw: String
    let ok: Bool
    let ms: Int
    let iface: String          // "utun7", "en0", "?"
    let error: String?
    let at: Date
    var line: String {
        ok ? "\(ms) ms via \(iface)" : "unreachable via \(iface)" + (error.map { " (\($0))" } ?? "")
    }
}

struct ChecksFile {
    let path: String

    static let template = """
    # Reachability checks shown in A-Train (menu and dashboard). One "host:port # comment" per line.
    # A-Train opens a TCP connection to each every minute while the VPN is up and warns if one fails.
    10.26.4.27:3306    # QA database (db.internal.example.com)
    10.25.8.118:22     # app server

    """

    func ensureExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return }
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? ChecksFile.template.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func parseLine(_ line: String) -> CheckSpec? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
        let parts = s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let value = parts[0].trimmingCharacters(in: .whitespaces)
        let comment = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        let host = String(value[..<colon]).lowercased()
        guard !host.isEmpty, RoutesFile.classify(host) == .ip || RoutesFile.classify(host) == .domain else { return nil }
        return CheckSpec(host: host, port: port, comment: comment)
    }

    func specs() -> [CheckSpec] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").components(separatedBy: "\n").compactMap(ChecksFile.parseLine)
    }

    /// Validate + append. Returns an error message, nil on success.
    func append(_ value: String, comment: String) -> String? {
        guard let spec = ChecksFile.parseLine(value) else { return "“\(value)” is not host:port (e.g. 10.26.4.27:3306 or db.example.com:5432)." }
        if specs().contains(where: { $0.raw == spec.raw }) { return "\(spec.raw) is already in the list." }
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += comment.isEmpty ? "\(spec.raw)\n" : "\(spec.raw)    # \(comment)\n"
        do { try text.write(toFile: path, atomically: true, encoding: .utf8); return nil } catch { return error.localizedDescription }
    }

    func remove(_ raw: String) -> String? {
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let kept = lines.filter { ChecksFile.parseLine($0)?.raw != raw }
        guard kept.count != lines.count else { return "\(raw) is not in checks.conf" }
        do { try kept.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8); return nil } catch { return error.localizedDescription }
    }
}

enum Reachability {
    /// Blocking; never call on the main thread.
    static func run(_ spec: CheckSpec) -> CheckResult {
        if spec.builtIn { return dnsCheck(spec) }
        var iface = interface(for: spec.host)
        if iface == "?" { iface = interface(for: spec.host) }              // transient miss under load: one retry
        var t0 = Date()
        var (st, out) = shell("/usr/bin/nc", ["-z", "-G", "5", "-w", "5", spec.host, String(spec.port)], timeout: 12)
        var ms = Int(Date().timeIntervalSince(t0) * 1000)
        if st != 0 {                                                        // one retry before calling it unreachable
            Thread.sleep(forTimeInterval: 1)
            t0 = Date()
            (st, out) = shell("/usr/bin/nc", ["-z", "-G", "5", "-w", "5", spec.host, String(spec.port)], timeout: 12)
            ms = Int(Date().timeIntervalSince(t0) * 1000)
        }
        let ok = st == 0
        var err: String? = nil
        if !ok {
            let o = out.lowercased()
            err = o.contains("refused") ? "connection refused" : o.contains("timed out") || o.contains("timeout") || ms >= 4900 ? "timeout" :
                  o.contains("name") || o.contains("resolve") ? "cannot resolve" : nil
        }
        return CheckResult(raw: spec.raw, ok: ok, ms: ms, iface: iface, error: err, at: Date())
    }

    /// `dig` bypasses the local cache and uses the resolvers the system is configured with, so this fails
    /// exactly when the user's browser would. Reports the server that answered (or was asked).
    static func dnsCheck(_ spec: CheckSpec) -> CheckResult {
        let t0 = Date()
        var (st, out) = shell("/usr/bin/dig", ["+time=3", "+tries=1", "www.apple.com", "A"], timeout: 10)
        var ms = Int(Date().timeIntervalSince(t0) * 1000)
        if st != 0 || !out.contains("ANSWER SECTION") {
            Thread.sleep(forTimeInterval: 1)
            (st, out) = shell("/usr/bin/dig", ["+time=3", "+tries=1", "www.apple.com", "A"], timeout: 10)
            ms = Int(Date().timeIntervalSince(t0) * 1000)
        }
        let ok = st == 0 && out.contains("ANSWER SECTION")
        var server = "?"
        if let line = out.components(separatedBy: "\n").first(where: { $0.contains("SERVER:") }),
           let r = line.range(of: "SERVER: ") {
            server = String(line[r.upperBound...]).components(separatedBy: "#").first ?? "?"
        }
        if !ok, server == "?" {
            let (_, rc) = shell("/bin/cat", ["/etc/resolv.conf"], timeout: 3)
            server = rc.components(separatedBy: "\n").first(where: { $0.hasPrefix("nameserver") })?.replacingOccurrences(of: "nameserver", with: "").trimmingCharacters(in: .whitespaces) ?? "?"
        }
        let iface = server == "?" ? "?" : interface(for: server)
        return CheckResult(raw: spec.raw, ok: ok, ms: ms, iface: "DNS \(server) on \(iface)",
                           error: ok ? nil : (out.lowercased().contains("timed out") ? "timeout" : "no answer"), at: Date())
    }

    /// The interface the kernel would use for this destination right now (host names are resolved first).
    static func interface(for host: String) -> String {
        var target = host
        if RoutesFile.classify(host) == .domain {
            let (_, r) = shell("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host], timeout: 5)
            if let line = r.components(separatedBy: "\n").first(where: { $0.hasPrefix("ip_address:") }) {
                target = line.replacingOccurrences(of: "ip_address:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        let (_, out) = shell("/sbin/route", ["-n", "get", target], timeout: 10)
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") { return t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return "?"
    }

    static func isPrivateIPv4(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { UInt8($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }

    /// "host:port" of every ESTABLISHED TCP connection to a private address, excluding DNS and ephemeral ports.
    static func establishedPrivatePeers() -> [String] {
        let (_, out) = shell("/usr/sbin/netstat", ["-n", "-p", "tcp"], timeout: 10)
        var seen: [String] = []
        for line in out.components(separatedBy: "\n") where line.contains("ESTABLISHED") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 5, let dot = cols[4].lastIndex(of: ".") else { continue }
            let host = String(cols[4][..<dot]), port = Int(cols[4][cols[4].index(after: dot)...]) ?? 0
            // skip DNS, Active Directory / LDAP / Kerberos / SMB (the VPN client and macOS talk to those, not the user) and ephemeral ports
            let noise: Set<Int> = [53, 88, 135, 137, 138, 139, 389, 445, 464, 636, 3268, 3269]
            guard port > 0, !noise.contains(port), port <= 49151, isPrivateIPv4(host) else { continue }
            let raw = "\(host):\(port)"
            if !seen.contains(raw) { seen.append(raw) }
        }
        return seen
    }

    /// Representative address for a routes.conf entry, so a route row can show where it would go.
    static func probeAddress(for raw: String, kind: String) -> String? {
        switch kind {
        case "ip": return raw
        case "cidr":
            let parts = raw.split(separator: "/")
            guard parts.count == 2, let plen = Int(parts[1]) else { return nil }
            let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
            guard octets.count == 4 else { return nil }
            let base = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
            let masked = plen == 0 ? 0 : base & (~UInt32(0) << (32 - plen))
            let probe = plen >= 31 ? masked : masked + 1
            return "\((probe >> 24) & 255).\((probe >> 16) & 255).\((probe >> 8) & 255).\(probe & 255)"
        default: return nil
        }
    }

    @discardableResult
    static func shell(_ exe: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
