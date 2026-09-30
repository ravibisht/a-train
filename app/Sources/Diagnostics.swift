import Foundation
import AppKit

/// One text file with everything needed to debug a colleague's Mac remotely. Nothing secret: no
/// passwords, no Keychain contents; the VPN username and internal IPs do appear.
enum Diagnostics {
    static func collect(checks: [CheckResult], extra: String) -> URL {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/A-Train-diagnostics-\(fmt.string(from: Date())).txt")
        var out = "A-Train diagnostics  \(Date())\n"
        let info = Bundle.main.infoDictionary ?? [:]
        out += "app \(info["CFBundleShortVersionString"] ?? "?") build \(info["CFBundleVersion"] ?? "?")  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "user \(NSUserName())  home \(NSHomeDirectory())\n\n"
        out += "== app view ==\n\(extra)\n\n"
        out += "== reachability ==\n" + (checks.isEmpty ? "(no checks run yet)\n" : checks.map { "\($0.raw): \($0.line)  at \($0.at)" }.joined(separator: "\n") + "\n") + "\n"
        func section(_ title: String, _ exe: String, _ args: [String], limit: Int = 400) {
            let (st, o) = Reachability.shell(exe, args, timeout: 10)
            let lines = o.components(separatedBy: "\n")
            out += "== \(title) (exit \(st)) ==\n" + lines.prefix(limit).joined(separator: "\n") + (lines.count > limit ? "\n… (\(lines.count - limit) more)" : "") + "\n\n"
        }
        func file(_ title: String, _ path: String, tail: Int = 0) {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(missing)"
            var lines = text.components(separatedBy: "\n")
            if tail > 0 && lines.count > tail { lines = Array(lines.suffix(tail)) }
            out += "== \(title) \(path) ==\n" + lines.joined(separator: "\n") + "\n\n"
        }
        section("trac info", CheckPoint.trac, ["info"])
        file("daemon status", "/usr/local/vpn-split/status.json")
        file("routes.conf", confDir + "/routes.conf")
        file("control.json", confDir + "/control.json")
        file("checks.conf", confDir + "/checks.conf")
        file("daemon log (tail)", "/var/log/vpnsplitd.log", tail: 200)
        file("install log (tail)", "/var/log/atrain-install.log", tail: 60)
        section("launchd", "/bin/launchctl", ["print", "system/com.ravi.vpnsplitd"], limit: 25)
        section("routing table", "/usr/sbin/netstat", ["-rn", "-f", "inet"])
        section("interfaces", "/sbin/ifconfig", [])
        section("dns", "/usr/sbin/scutil", ["--dns"], limit: 60)
        section("resolver files", "/bin/ls", ["-la", "/etc/resolver"])
        section("vpn services", "/usr/sbin/scutil", ["--nc", "list"])
        section("python", "/bin/sh", ["-c", "for p in /usr/bin/python3 /opt/homebrew/bin/python3; do [ -x $p ] && echo $p $($p -I -c 'import platform;print(platform.python_version())' 2>&1); done"])
        section("app signature", "/usr/bin/codesign", ["-dv", Bundle.main.bundlePath])
        try? out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
