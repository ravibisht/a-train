import Foundation

enum EntryKind { case cidr, ip, domain, wildcard, privateRanges }

/// routes.conf: plain text the user may also edit by hand. We only ever toggle "#off " on a
/// line or append a line, so comments and formatting are preserved.
struct RoutesFile {
    let path: String

    static let template = """
    # Routes that go THROUGH the VPN. Everything not listed here uses normal Wi-Fi.
    #
    # One entry per line. Accepted forms:
    #   private                   every private network (10/8, 172.16/12, 192.168/16) except the one this Mac is on
    #   10.26.0.0/16              a subnet (CIDR)
    #   10.25.8.118               a single IP
    #   db.internal.example.com   a domain name: resolved every 5 minutes, every IP it returns gets a route
    #   *.example.com             a WHOLE domain: any subdomain you visit is routed via the VPN automatically
    #   *.vpn.azure.com via local resolve a domain on your Wi-Fi DNS, never route it (other VPN clients need this)
    #
    # Anything after # on a line is a comment.
    # Put "#off " in front of an entry to disable it without deleting it (the A-Train toggle does this).
    # Changes are picked up automatically within a couple of seconds while the VPN is connected.

    private    # zero-config default: all internal networks, your own LAN stays local
    *.vpn.azure.com via local   # Azure VPN gateway name: resolve on Wi-Fi, never through the office DNS

    """

    func ensureExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? RoutesFile.template.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func read() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Returns an error message on failure, nil on success.
    @discardableResult
    private func write(_ text: String) -> String? {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Could not write \(path): \(error.localizedDescription)"
        }
    }

    /// (value, enabled, via) for an entry line; nil for blank lines and plain comments.
    static func parseLine(_ line: String) -> (value: String, enabled: Bool, via: String)? {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        var enabled = true
        if s.hasPrefix("#") {
            let body = s.dropFirst().trimmingCharacters(in: .whitespaces)
            guard body.lowercased().hasPrefix("off ") else { return nil }
            enabled = false
            s = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        var value = s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var via = "checkpoint"
        let toks = value.split(separator: " ").map(String.init)
        if toks.count == 3, toks[1].lowercased() == "via", ["azure", "checkpoint", "local"].contains(toks[2].lowercased()) {
            value = toks[0]; via = toks[2].lowercased()
        }
        return value.isEmpty ? nil : (value.lowercased(), enabled, via)
    }

    /// Entries as the file has them right now (used when the daemon is not running).
    func entries() -> [(value: String, enabled: Bool, via: String)] {
        read().components(separatedBy: "\n").compactMap(RoutesFile.parseLine)
    }

    /// Flip "#off " on the matching entry line. Returns an error message on failure.
    func toggle(_ value: String) -> String? {
        var lines = read().components(separatedBy: "\n")
        var found = false
        for i in lines.indices {
            guard let p = RoutesFile.parseLine(lines[i]), p.value == value else { continue }
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if p.enabled {
                lines[i] = "#off " + t
            } else {
                let body = t.dropFirst().trimmingCharacters(in: .whitespaces)      // after '#'
                lines[i] = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
            found = true
            break
        }
        guard found else { return "\(value) is no longer in routes.conf. Use Reload now." }
        return write(lines.joined(separator: "\n"))
    }

    /// Delete the entry line (enabled or #off) whose value matches. Returns an error message on failure.
    func remove(_ value: String) -> String? {
        let lines = read().components(separatedBy: "\n")
        let kept = lines.filter { RoutesFile.parseLine($0)?.value != value }
        guard kept.count != lines.count else { return "\(value) is not in routes.conf" }
        return write(kept.joined(separator: "\n"))
    }

    func append(_ value: String, comment: String, via: String = "checkpoint") -> String? {
        var text = read()
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        let v = via == "checkpoint" ? value : "\(value) via \(via)"
        text += comment.isEmpty ? "\(v)\n" : "\(v)    # \(comment)\n"
        return write(text)
    }

    /// Change the tunnel of an existing entry in place (rewrites only that line's value part).
    func setVia(_ value: String, via: String) -> String? {
        var lines = read().components(separatedBy: "\n")
        var found = false
        for i in lines.indices {
            guard let p = RoutesFile.parseLine(lines[i]), p.value == value else { continue }
            let t = lines[i]
            let hash = t.firstIndex(of: "#").map { t.index(after: $0) }
            var comment = ""
            if p.enabled, let h = t.firstIndex(of: "#") { comment = String(t[t.index(after: h)...]).trimmingCharacters(in: .whitespaces) }
            else if !p.enabled {
                let body = t.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces).dropFirst(4)
                if let h = body.firstIndex(of: "#") { comment = String(body[body.index(after: h)...]).trimmingCharacters(in: .whitespaces) }
            }
            _ = hash
            let v = via == "checkpoint" ? value : "\(value) via \(via)"
            let line = comment.isEmpty ? v : "\(v)    # \(comment)"
            lines[i] = p.enabled ? line : "#off " + line
            found = true
            break
        }
        guard found else { return "\(value) is no longer in routes.conf." }
        return write(lines.joined(separator: "\n"))
    }

    /// Append every entry of a preset file (routes.conf.example shipped with the package) that is not already
    /// listed, enabled or #off. Comments travel with the lines. Returns (added, error).
    func addMissing(fromPreset presetPath: String) -> (Int, String?) {
        guard let preset = try? String(contentsOfFile: presetPath, encoding: .utf8) else { return (0, "Preset not found at \(presetPath)") }
        let have = Set(entries().map { $0.value })
        var text = read()
        var added = 0
        for line in preset.components(separatedBy: "\n") {
            guard let p = RoutesFile.parseLine(line), p.enabled, !have.contains(p.value) else { continue }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += line.trimmingCharacters(in: .whitespaces) + "\n"
            added += 1
        }
        if added == 0 { return (0, nil) }
        return (added, write(text))
    }

    /// Bump mtime so the daemon reloads even if nothing changed.
    func touch() {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    static func classify(_ v: String) -> EntryKind? {
        let octet = #"(25[0-5]|2[0-4]\d|1?\d?\d)"#
        let ipv4 = "^\(octet)(\\.\(octet)){3}$"
        let cidr = "^\(octet)(\\.\(octet)){3}/([0-9]|[12]\\d|3[0-2])$"
        let host = #"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{1,62}$"#
        if v == "private" { return .privateRanges }
        if v.hasPrefix("*.") {
            return String(v.dropFirst(2)).range(of: host, options: .regularExpression) != nil ? .wildcard : nil
        }
        if v.range(of: ipv4, options: .regularExpression) != nil { return .ip }
        if v.range(of: cidr, options: .regularExpression) != nil { return .cidr }
        if v.range(of: host, options: .regularExpression) != nil { return .domain }
        return nil
    }
}

/// control.json: {"mode": "split"|"full", "full_until": <epoch seconds>|null}
struct ControlFile {
    let path: String

    /// Returns an error message on failure, nil on success.
    func write(mode: String, fullUntil: Double?) -> String? {
        var d: [String: Any] = ["mode": mode]
        if let f = fullUntil { d["full_until"] = f } else { d["full_until"] = NSNull() }
        do {
            let data = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted])
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return nil
        } catch {
            return "Could not write \(path): \(error.localizedDescription)"
        }
    }

    /// The mode the user asked for (the daemon reports the mode in effect via status.json).
    /// An expired full_until counts as split, exactly as the daemon treats it.
    func read() -> (mode: String, fullUntil: Double?)? {
        guard let data = FileManager.default.contents(atPath: path),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = d["mode"] as? String, mode == "split" || mode == "full" else { return nil }
        let fu = d["full_until"] as? Double
        if mode == "full", let f = fu, f <= Date().timeIntervalSince1970 { return ("split", nil) }
        return (mode, mode == "full" ? fu : nil)
    }
}
