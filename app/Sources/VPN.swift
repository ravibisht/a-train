import Foundation
import Security

/// Thin wrapper over Check Point's command-line tool. Runs as the user; no root involved.
struct CheckPoint {
    static let trac = "/Library/Application Support/Checkpoint/Endpoint Connect/trac"

    struct Info {
        var installed = true
        var serviceUp = true             // false when trac could not talk to its service (sleep/wake, service restart)
        var status = ""                  // Connected, Idle, Disconnected, Connecting, Reconnecting, Authenticating, Disconnecting
        var site: String? = nil          // e.g. "203.0.113.10"
        var user: String? = nil          // from "authentication method: username-password with username X"
        var remaining: String? = nil     // "09:54:45" as printed by trac

        var connected: Bool { status.lowercased() == "connected" }
        /// The client is mid-transition (its own GUI or a previous command). Never start another connect then.
        var busy: Bool { ["connecting", "reconnecting", "authenticating", "disconnecting"].contains(status.lowercased()) }
        /// Safe to start a connection: we know the client's state and it is at rest without a tunnel.
        var idle: Bool { installed && serviceUp && !connected && !busy }
        var remainingPretty: String? {
            guard let r = remaining else { return nil }
            let p = r.split(separator: ":").compactMap { Int($0) }
            guard p.count == 3 else { return r }
            return p[0] > 0 ? "\(p[0]) h \(p[1]) m left" : "\(p[1]) m left"
        }
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: trac) }

    /// Run a command with arguments; returns exit status and combined output. Never call on the main thread.
    /// On timeout the process gets SIGTERM, then SIGKILL 5 s later, so a hung child can never wedge a thread.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "cannot run \(exe): \(error.localizedDescription)") }
        let pid = p.processIdentifier
        let term = DispatchWorkItem { if p.isRunning { p.terminate() } }
        let kill9 = DispatchWorkItem { if p.isRunning { kill(pid, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: term)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 5, execute: kill9)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        term.cancel()
        kill9.cancel()
        let out = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (p.terminationStatus, out)
    }

    static func run(_ args: [String], timeout: TimeInterval = 90) -> (status: Int32, output: String) {
        run(trac, args, timeout: timeout)
    }

    static func info() -> Info {
        guard isInstalled else { var i = Info(); i.installed = false; return i }
        let r = run(["info"], timeout: 20)
        var i = parseInfo(r.output)
        if r.status != 0 || !r.output.contains("Trac connections") { i.serviceUp = false }
        return i
    }

    /// Pure parser for `trac info`. Picks the connected site, else the active site, else the first.
    static func parseInfo(_ text: String) -> Info {
        var info = Info()
        var blocks: [[String]] = []
        var cur: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Conn ") {
                if !cur.isEmpty { blocks.append(cur) }
                cur = [line]
            } else if !cur.isEmpty && !line.isEmpty {
                cur.append(line)
            }
        }
        if !cur.isEmpty { blocks.append(cur) }
        func field(_ b: [String], _ key: String) -> String? {
            guard let l = b.dropFirst().first(where: { $0.lowercased().hasPrefix(key) }) else { return nil }
            return String(l.dropFirst(key.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": \t"))
        }
        let chosen = blocks.first { field($0, "status")?.lowercased() == "connected" }
            ?? blocks.first { (field($0, "status") ?? "").lowercased().contains("connect") && field($0, "status")?.lowercased() != "disconnected" }
            ?? blocks.first { field($0, "active site") == "true" }
            ?? blocks.first
        guard let b = chosen else { return info }
        info.site = String(b[0].dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: ": \t"))
        info.status = field(b, "status") ?? ""
        info.remaining = field(b, "remaining time")
        if let auth = field(b, "authentication method"), let r = auth.range(of: "username ") {
            info.user = String(auth[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return info
    }

    /// TCP probe of the gateway (Check Point listens on 443). Tells "network is down" apart from
    /// "login rejected", so a Wi-Fi drop is retried and never counted as a password failure.
    static func gatewayReachable(_ host: String) -> Bool {
        run("/usr/bin/nc", ["-z", "-G", "3", host, "443"], timeout: 6).status == 0
    }

    enum ConnectError: Error {
        case rejected(String)      // trac said no: probably credentials. Counts toward the lockout guard.
        case transient(String)     // network / service problem. Retried, never counted.
        var message: String {
            switch self { case .rejected(let m), .transient(let m): return m }
        }
    }

    /// Connect with credentials. Success = trac exits 0 and `info` reports Connected within 20 s.
    /// PID of Check Point's background service, to notice a crash/restart during a connect.
    static func servicePID() -> Int32? {
        let (st, out) = run("/usr/bin/pgrep", ["-x", "TracSrvWrapper"], timeout: 5)
        return st == 0 ? out.split(separator: "\n").first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) } : nil
    }

    /// Poll until `ok` holds or `seconds` pass. Returns the last info.
    @discardableResult
    private static func waitFor(_ seconds: Int, _ ok: (Info) -> Bool) -> Info {
        var i = info()
        var left = seconds
        while !ok(i) && left > 0 { Thread.sleep(forTimeInterval: 2); left -= 2; i = info() }
        return i
    }

    /// Connect with the saved credentials.
    /// takeOver: the client's own "Always Connect" starts password-less attempts (on wake, after a service
    /// restart) that hang in "Connecting" waiting for a login window nobody sees. A manual Connect cancels
    /// such an attempt and sends ours instead of giving up with "already connecting".
    /// If the service crashes mid-connect (seen 2026-09-28/29: TracSrvWrapper SIGABRT), wait for it to come
    /// back and try once more.
    static func connect(site: String, user: String, password: String, takeOver: Bool = false) -> Result<Void, ConnectError> {
        var result = attempt(site: site, user: user, password: password, takeOver: takeOver)
        if case .failure(.transient(let why)) = result, why.hasPrefix(crashMarker) {
            result = attempt(site: site, user: user, password: password, takeOver: true)
            if case .failure(.transient(let m)) = result, m.hasPrefix(crashMarker) {
                return .failure(.transient("Check Point's service crashed twice while connecting; try again in a minute"))
            }
        }
        return result
    }

    private static let crashMarker = "Check Point's service restarted"

    private static func attempt(site: String, user: String, password: String, takeOver: Bool) -> Result<Void, ConnectError> {
        var before = info()
        if before.connected { return .success(()) }
        if !before.serviceUp {
            before = waitFor(30) { $0.serviceUp }                       // service restarting: give it time
            if !before.serviceUp { return .failure(.transient("Check Point service is not responding yet")) }
            if before.connected { return .success(()) }
        }
        if before.busy {
            guard takeOver else { return .failure(.transient("Check Point is already \(before.status.lowercased())")) }
            _ = disconnect()                                            // cancel the password-less attempt
            before = waitFor(20) { !$0.busy }
            if before.connected { return .success(()) }
            if before.busy { return .failure(.transient("Check Point is still \(before.status.lowercased()) after cancelling its own attempt")) }
        }
        if !gatewayReachable(site) { return .failure(.transient("VPN gateway \(site) is not reachable (no network?)")) }
        let pid = servicePID()
        let r = run(["connect", "-s", site, "-u", user, "-p", password], timeout: 90)
        let restarted = { () -> Bool in let now = servicePID(); return pid != nil && now != pid }
        if r.status != 0 {
            if restarted() { return .failure(.transient(crashMarker + " during connect")) }
            let msg = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? "trac exited with status \(r.status)"
            let low = msg.lowercased()
            let transientWords = ["timed out", "timeout", "network", "unreachable", "service", "not responding", "connection lost", "already"]
            return .failure(transientWords.contains { low.contains($0) } ? .transient(msg) : .rejected(msg))
        }
        for _ in 0..<10 {
            let i = info()
            if i.connected { return .success(()) }
            if restarted() { return .failure(.transient(crashMarker + " after connect")) }
            if i.status.lowercased() == "idle" || i.status.lowercased() == "disconnected" { break }
            Thread.sleep(forTimeInterval: 2)
        }
        if restarted() { return .failure(.transient(crashMarker + " after connect")) }
        return .failure(.transient("trac reported success but the tunnel did not come up"))
    }

    static func disconnect() -> Result<Void, String> {
        let r = run(["disconnect"], timeout: 30)
        return r.status == 0 ? .success(()) : .failure(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension String: @retroactive Error {}

/// One generic-password item per VPN username, service "com.ravi.atrain.vpn". Protected by the Mac login.
struct Keychain {
    static let service = "com.ravi.atrain.vpn"

    private static func base(_ account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let a = account { q[kSecAttrAccount as String] = a }
        return q
    }

    /// Attribute-only query: never triggers the Keychain access prompt.
    static func savedAccount() -> String? {
        var q = base(nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any] else { return nil }
        return attrs[kSecAttrAccount as String] as? String
    }

    enum ReadResult { case password(String), denied, missing }

    /// Items saved before the -A change still carry a per-build access list. Re-save them once.
    static func migrateIfNeeded(_ account: String, _ password: String) {
        let key = "keychainOpenACL." + account
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if set(account, password) == nil { UserDefaults.standard.set(true, forKey: key) }
    }

    /// Reads the secret. May show the macOS "allow A-Train to use this item" prompt once per build.
    static func read(_ account: String) -> ReadResult {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &item)
        switch st {
        case errSecSuccess:
            guard let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return .missing }
            return .password(s)
        case errSecItemNotFound: return .missing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .denied
        default: return .denied
        }
    }

    /// Save with an access list that does not depend on the app's code signature. A-Train is signed
    /// locally, so every rebuild is a "new app" to Keychain and would trigger the allow prompt again;
    /// `security add-generic-password -A` marks the item usable by any app running as you, which is
    /// the same trust level as the config files, and ends the prompts for good.
    static func set(_ account: String, _ password: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-U", "-A", "-s", service, "-a", account,
                       "-l", "A-Train VPN password", "-D", "A-Train VPN password", "-w", password]
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return "Could not run the keychain tool: \(error.localizedDescription)" }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return "Keychain refused to save the password: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        UserDefaults.standard.set(true, forKey: "keychainOpenACL." + account)
        // remove any other account under our service (one saved identity at a time)
        var all = base(nil)
        all[kSecReturnAttributes as String] = true
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        if SecItemCopyMatching(all as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] {
            for it in list {
                if let a = it[kSecAttrAccount as String] as? String, a != account {
                    SecItemDelete(base(a) as CFDictionary)
                }
            }
        }
        return nil
    }

    static func delete() {
        SecItemDelete(base(nil) as CFDictionary)
    }
}

/// Small persisted preferences for the VPN login feature.
struct VPNPrefs {
    private static let d = UserDefaults.standard
    static var site: String? {
        get { d.string(forKey: "vpnSite") }
        set { d.set(newValue, forKey: "vpnSite") }
    }
    static var autoConnect: Bool {
        get { d.bool(forKey: "vpnAutoConnect") }
        set { d.set(newValue, forKey: "vpnAutoConnect") }
    }
    static var wantConnected: Bool {
        get { d.bool(forKey: "vpnWantConnected") }
        set { d.set(newValue, forKey: "vpnWantConnected") }
    }
    static var failures: Int {
        get { d.integer(forKey: "vpnFailures") }
        set { d.set(newValue, forKey: "vpnFailures") }
    }
}

/// Azure VPN Client (Microsoft's macOS network-extension VPN). macOS lists it as a system VPN service,
/// so it can be started, stopped and observed with `scutil --nc` without opening the Azure window
/// (the profile caches the Azure AD sign-in; if the token has expired, start fails and the user opens
/// the Azure app once to sign in again).
struct AzureVPN {
    struct Service: Equatable {
        let id: String
        let name: String
        let state: String          // Connected, Disconnected, Connecting, Disconnecting
        var connected: Bool { state == "Connected" }
        var busy: Bool { state == "Connecting" || state == "Disconnecting" }
    }

    /// Parse `scutil --nc list`; profiles get renamed/re-created, so discover every poll, never cache IDs.
    static func services() -> [Service] {
        let r = CheckPoint.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 10)
        var out: [Service] = []
        for line in r.output.split(separator: "\n") where line.contains("com.microsoft.AzureVpnMac") {
            // * (Connected)      720C955C-... VPN (com.microsoft.AzureVpnMac) "Policy"   [VPN:com.microsoft.AzureVpnMac]
            guard let s1 = line.range(of: "("), let s2 = line.range(of: ")") else { continue }
            let state = String(line[s1.upperBound..<s2.lowerBound])
            let rest = line[s2.upperBound...].trimmingCharacters(in: .whitespaces)
            let id = String(rest.split(separator: " ").first ?? "")
            var name = id
            if let q1 = line.range(of: "\""), let q2 = line.range(of: "\"", range: q1.upperBound..<line.endIndex) {
                name = String(line[q1.upperBound..<q2.lowerBound])
            }
            if !id.isEmpty { out.append(Service(id: id, name: name, state: state)) }
        }
        return out
    }

    static func start(_ id: String) -> Result<Void, String> {
        let r = CheckPoint.run("/usr/sbin/scutil", ["--nc", "start", id], timeout: 15)
        return r.status == 0 ? .success(()) : .failure(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func stop(_ id: String) -> Result<Void, String> {
        let r = CheckPoint.run("/usr/sbin/scutil", ["--nc", "stop", id], timeout: 15)
        return r.status == 0 ? .success(()) : .failure(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Wait for the service to reach Connected (or give up) after start; returns final state.
    static func waitFor(_ id: String, connected want: Bool, seconds: Int) -> String {
        for _ in 0..<seconds {
            if let s = services().first(where: { $0.id == id }) {
                if s.connected == want && !s.busy { return s.state }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return services().first(where: { $0.id == id })?.state ?? "Unknown"
    }
}
