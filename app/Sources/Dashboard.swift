import SwiftUI
import AppKit

// A-Train dashboard: a SwiftUI window hosted by the AppKit menu bar app. It shows the same state the
// menu shows and calls the same actions; all data flows through DashboardModel, updated by AppDelegate.

struct RowEntry: Identifiable, Equatable {
    let raw: String
    let kind: String
    let enabled: Bool
    let comment: String
    let ipCount: Int
    let ips: [String]
    let error: String?
    let auto: Bool
    var via: String = "checkpoint"
    var path: String? = nil            // interface the kernel would use right now ("utun7", "en0"), for ip/cidr rows
    var id: String { raw }
}

struct CheckRow: Identifiable, Equatable {
    let raw: String
    let label: String
    let result: CheckResult?
    let failures: Int
    var id: String { raw }
}

final class DashboardModel: ObservableObject {
    @Published var daemonUp = false
    @Published var vpnConnected = false
    @Published var vpnLine = "VPN: unknown"
    @Published var iface = ""
    @Published var routeCount = 0
    @Published var modeInEffect = "split"
    @Published var requestedMode = "split"
    @Published var fullUntil: Double?
    @Published var publicIp = "—"
    @Published var note: String?
    @Published var connecting = false
    @Published var disconnecting = false
    @Published var autoReconnect = false
    @Published var savedAccount: String?
    @Published var azureName: String?
    @Published var azureState: String = ""
    @Published var azureBusy = false
    @Published var entries: [RowEntry] = []
    @Published var logLines: [String] = []
    @Published var addError: String?
    @Published var scrollToken = 0          // bumped by the app every time the window is shown
    @Published var showTroubleshoot = false
    @Published var jumpTo: String?          // scroll target id set by the app (e.g. "settings")
    @Published var loginItemOn = false
    @Published var loginItemNote: String?
    @Published var checks: [CheckRow] = []
    @Published var checksRunning = false
    @Published var checkError: String?
    @Published var updateURL: String = ""
    @Published var updateStatus: String = ""
    @Published var updateAvailable: UpdateInfo?

    var onRunChecks: () -> Void = {}
    var onAddCheck: (String, String) -> String? = { _, _ in nil }
    var onRemoveCheck: (String) -> Void = { _ in }
    var onAddTeamDefaults: () -> Void = {}
    var onRouteSite: () -> Void = {}
    var onDiagnostics: () -> Void = {}
    var onUninstall: () -> Void = {}
    var onSetUpdateURL: (String) -> Void = { _ in }
    var onCheckUpdate: () -> Void = {}
    var onOpenUpdate: () -> Void = {}

    var onSetLoginItem: (Bool) -> Void = { _ in }
    var onDockModeChanged: () -> Void = {}
    var onResetWindow: () -> Void = {}

    var onAzureConnect: () -> Void = {}
    var onAzureDisconnect: () -> Void = {}
    var onConnect: () -> Void = {}
    var onDisconnect: () -> Void = {}
    var onSetFull: (Int) -> Void = { _ in }
    var onBackToSplit: () -> Void = {}
    var onToggleEntry: (String) -> Void = { _ in }
    var onRemoveEntry: (String) -> Void = { _ in }
    var onAddEntry: (String, String, String) -> String? = { _, _, _ in nil }   // value, comment, via
    var onSetVia: (String, String) -> Void = { _, _ in }
    var onSavePassword: () -> Void = {}
    var onForgetPassword: () -> Void = {}
    var onToggleAuto: () -> Void = {}
    var onOpenRoutesFile: () -> Void = {}
    var onReload: () -> Void = {}
    var onOpenLog: () -> Void = {}
    var onOpenDocs: () -> Void = {}
}

enum Theme {
    static let navy = Color(red: 0.024, green: 0.102, blue: 0.310)
    static let navyDeep = Color(red: 0.016, green: 0.055, blue: 0.180)
    static let blue = Color(red: 0.122, green: 0.373, blue: 0.847)
    static let red = Color(red: 0.898, green: 0.071, blue: 0.169)
    static let ok = Color(red: 0.31, green: 0.86, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let card = Color.white.opacity(0.08)
    static let line = Color.white.opacity(0.12)
    static let dim = Color.white.opacity(0.62)
}

struct Card<Content: View>: View {
    let title: String
    let content: Content
    @AppStorage("showVideo") private var showVideo = true
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    /// Over live footage the cards need a real dark backing so text stays readable on bright frames.
    private var backing: Color { (showVideo && BackgroundVideo.url != nil) ? Theme.navyDeep.opacity(0.72) : Theme.card }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundColor(Theme.dim)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backing)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .cornerRadius(12)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .cornerRadius(999)
    }
}

/// Segmented switch drawn by hand: SwiftUI's Menu/Picker on macOS render their title through
/// NSPopUpButton, which ignores our colors and comes out grey on the navy card.
struct SegmentSwitch: View {
    struct Option { let title: String; let tag: String; let color: Color }
    let options: [Option]
    let selected: String
    let onSelect: (String) -> Void
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.tag) { o in segment(o) }
        }
        .padding(2)
        .background(Color.white.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 999).stroke(Color.white.opacity(0.25), lineWidth: 1))
        .cornerRadius(999)
        .fixedSize()
    }
    private func segment(_ o: Option) -> some View {
        let on = selected == o.tag
        return Button(action: { if !on { onSelect(o.tag) } }) {
            Text(o.title)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 3 : 5)
                .foregroundColor(on ? Theme.navyDeep : .white)
                .background(on ? o.color : Color.clear)
                .cornerRadius(999)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct TunnelSwitch: View {
    let via: String
    let onSelect: (String) -> Void
    var compact = false
    static let azure = Color(red: 0.55, green: 0.78, blue: 1.0)
    var body: some View {
        SegmentSwitch(options: [.init(title: "Check Point", tag: "checkpoint", color: Theme.ok),
                                .init(title: "Azure", tag: "azure", color: TunnelSwitch.azure)],
                      selected: via, onSelect: onSelect, compact: compact)
            .help("Which tunnel carries this entry")
    }
}

struct AccentButtonStyle: ButtonStyle {
    var color: Color = Theme.red
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

struct DashboardView: View {
    @ObservedObject var m: DashboardModel
    @ObservedObject var t: TroubleshootModel
    @State private var newEntry = ""
    @State private var newComment = ""
    @State private var newVia = "checkpoint"
    @State private var newCheck = ""
    @State private var newCheckComment = ""
    @State private var updateURLField = ""
    @AppStorage("showVideo") private var showVideo = true
    @AppStorage(AppPrefs.dockModeKey) private var dockMode = AppPrefs.DockMode.whileOpen.rawValue
    @AppStorage(AppPrefs.openAtLaunchKey) private var openAtLaunch = false
    @State private var compact = false      // narrow window: cards stack instead of sitting side by side
    private var videoURL: URL? { BackgroundVideo.url }

    private var timeFmt: DateFormatter { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }

    var body: some View {
        GeometryReader { geo in
            content
                .onAppear { compact = geo.size.width < 980 }
                .onChange(of: geo.size.width) { compact = $0 < 980 }
        }
        .foregroundColor(.white)
        .frame(minWidth: 640, minHeight: 480)
    }

    private var content: some View {
        ZStack {
            if showVideo, let url = videoURL {
                BackgroundVideoView(url: url).ignoresSafeArea()
                // tint so text stays readable; the video shows through the cards' translucency
                LinearGradient(colors: [Theme.blue.opacity(0.16), Theme.navy.opacity(0.24), Theme.navyDeep.opacity(0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            } else {
                LinearGradient(colors: [Theme.blue.opacity(0.9), Theme.navy, Theme.navyDeep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header.id("top")
                        statusRow
                        if m.showTroubleshoot { TroubleshootView(t: t) }
                        if compact {
                            modeCard
                            loginCard
                            azureCard
                        } else {
                            HStack(alignment: .top, spacing: 14) {
                                modeCard
                                VStack(spacing: 14) {
                                    loginCard
                                    azureCard
                                }
                            }
                        }
                        routesCard
                        reachabilityCard.id("reachability")
                        logCard
                        settingsCard.id("settings")
                        footer
                    }
                    .padding(20)
                }
                .onReceive(m.$jumpTo) { target in
                    guard let id = target else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { proxy.scrollTo(id, anchor: .top) }
                    m.jumpTo = nil
                }
                .onAppear {
                    for d in [0.15, 0.6, 1.2] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + d) { proxy.scrollTo("top", anchor: .top) }
                    }
                }
                .onReceive(m.$scrollToken) { _ in
                    for d in [0.05, 0.4] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + d) { proxy.scrollTo("top", anchor: .top) }
                    }
                }
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Theme.blue, Theme.navy], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                Rectangle().fill(Theme.red).frame(width: 70, height: 5).rotationEffect(.degrees(-4)).offset(y: 4)
                Text("A").font(.system(size: 40, weight: .heavy)).italic().foregroundColor(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
            }
            .frame(width: 56, height: 56)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text("A-Train")
                    .font(.system(size: 30, weight: .heavy))
                    .fontWidth(.condensed)
                Text("Split tunnel for the Check Point VPN")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.dim)
                Text("Made out of frustration, so you don’t have to be.")
                    .font(.system(size: 11)).italic()
                    .foregroundColor(Theme.dim.opacity(0.85))
            }
            Spacer()
            Button(m.showTroubleshoot ? "Hide troubleshoot" : "Troubleshoot") {
                m.showTroubleshoot.toggle()
                if m.showTroubleshoot { t.run() }
            }.buttonStyle(GhostButtonStyle())
            Pill(text: m.daemonUp ? "daemon running" : "daemon not running", color: m.daemonUp ? Theme.ok : Theme.warn)
        }
    }

    private var statusRow: some View {
        let tiles = [
            stat("VPN", m.vpnConnected ? "Connected" : "Not connected", m.vpnConnected ? Theme.ok : Theme.warn),
            stat("Mode", m.modeInEffect == "full" ? "Full VPN" : "Split", m.modeInEffect == "full" ? Theme.red : Theme.blue),
            stat("Public IP", m.publicIp, .white),
            stat("Routes via VPN", "\(m.routeCount)", .white),
        ]
        return Group {
            if compact {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(0..<4, id: \.self) { tiles[$0] }
                }
            } else {
                HStack(spacing: 10) { ForEach(0..<4, id: \.self) { tiles[$0] } }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundColor(Theme.dim)
            Text(value).font(.system(size: 20, weight: .heavy)).fontWidth(.condensed).foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((showVideo && videoURL != nil) ? Theme.navyDeep.opacity(0.72) : Theme.card)
        .cornerRadius(10)
    }

    // MARK: mode

    private var modeCard: some View {
        Card("Routing mode") {
            if let n = m.note, !n.isEmpty {
                Label(n, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundColor(Theme.warn)
            }
            if m.requestedMode != m.modeInEffect {
                Text("Switching to \(m.requestedMode == "full" ? "Full VPN" : "Split")…").font(.system(size: 12)).foregroundColor(Theme.warn)
            }
            if m.requestedMode == "full" {
                if let u = m.fullUntil {
                    Text("Full VPN until \(timeFmt.string(from: Date(timeIntervalSince1970: u)))").font(.system(size: 13))
                } else {
                    Text("Full VPN until you switch back").font(.system(size: 13))
                }
                Button("Back to Split now") { m.onBackToSplit() }.buttonStyle(AccentButtonStyle(color: Theme.blue))
            } else {
                Text("Only the routes below use the VPN. Everything else uses Wi-Fi.").font(.system(size: 12)).foregroundColor(Theme.dim)
                Text("Switch to Full VPN for").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach([("15 min", 15), ("30 min", 30), ("1 h", 60), ("2 h", 120)], id: \.1) { label, mins in
                        Button(label) { m.onSetFull(mins) }.buttonStyle(AccentButtonStyle()).fixedSize()
                    }
                    Button("Until I switch back") { m.onSetFull(0) }.buttonStyle(GhostButtonStyle()).fixedSize()
                }
            }
        }
    }

    // MARK: login

    private var loginCard: some View {
        Card("VPN login") {
            Text(m.vpnLine).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                if m.vpnConnected || m.disconnecting {
                    Button(m.disconnecting ? "Disconnecting…" : "Disconnect VPN") { m.onDisconnect() }
                        .buttonStyle(GhostButtonStyle()).disabled(m.disconnecting || m.connecting)
                } else {
                    Button(m.connecting ? "Connecting…" : (m.savedAccount == nil ? "Connect VPN (save password first)" : "Connect VPN")) { m.onConnect() }
                        .buttonStyle(AccentButtonStyle(color: Theme.ok.opacity(0.85))).disabled(m.connecting)
                }
            }
            Toggle(isOn: Binding(get: { m.autoReconnect }, set: { _ in m.onToggleAuto() })) {
                Text("Reconnect automatically if the session drops").font(.system(size: 12))
            }.toggleStyle(.switch)
            HStack(spacing: 8) {
                Button(m.savedAccount.map { "Save password… (\($0))" } ?? "Save VPN password…") { m.onSavePassword() }.buttonStyle(GhostButtonStyle())
                if m.savedAccount != nil {
                    Button("Forget") { m.onForgetPassword() }.buttonStyle(GhostButtonStyle())
                }
            }
            Text("Password is kept in your macOS Keychain. Never connects on its own at login.")
                .font(.system(size: 11)).foregroundColor(Theme.dim)
        }
    }

    // MARK: azure

    private var azureCard: some View {
        Card("Azure VPN") {
            if let name = m.azureName {
                HStack(spacing: 8) {
                    Text(m.azureState.isEmpty ? name : "\(m.azureState) · \(name)").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if m.azureState == "Connected" || m.azureState == "Disconnecting" {
                        Button(m.azureBusy ? "Working…" : "Disconnect") { m.onAzureDisconnect() }.buttonStyle(GhostButtonStyle()).disabled(m.azureBusy)
                    } else {
                        Button(m.azureBusy ? "Working…" : "Connect Azure") { m.onAzureConnect() }.buttonStyle(AccentButtonStyle(color: Theme.blue)).disabled(m.azureBusy)
                    }
                }
                Text("Driven through macOS; the Azure window is only needed if its sign-in expires. Azure routes only its own subnets, so it coexists with the split.")
                    .font(.system(size: 11)).foregroundColor(Theme.dim)
            } else {
                Text("No Azure profile found. Add one in the Azure VPN Client once; A-Train drives it after that.")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
        }
    }

    // MARK: routes

    private var routesCard: some View {
        Card("Routes via VPN") {
            VStack(spacing: 0) {
                ForEach(m.entries) { e in
                    HStack(alignment: .top, spacing: 14) {
                        if e.auto {
                            Image(systemName: "bolt.fill").foregroundColor(Theme.dim)
                                .frame(width: 40, height: 22).padding(.top, 1)
                        } else {
                            Toggle("", isOn: Binding(get: { e.enabled }, set: { _ in m.onToggleEntry(e.raw) }))
                                .toggleStyle(.switch).controlSize(.small).labelsHidden().fixedSize()
                                .frame(width: 40, alignment: .leading).padding(.top, 1)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(e.raw).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Pill(text: kindLabel(e.kind), color: kindColor(e.kind))
                                if let p = e.path, e.enabled {
                                    let viaTunnel = p.hasPrefix("utun")
                                    Text("→ \(p)").font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(viaTunnel ? Theme.ok : Theme.warn)
                                        .help(viaTunnel ? "Traffic to this entry goes through the tunnel" : "Traffic to this entry currently goes over \(p), not the VPN")
                                }
                                if !e.auto && e.kind != "dns" {
                                    TunnelSwitch(via: e.via, onSelect: { m.onSetVia(e.raw, $0) }, compact: true)
                                }
                                if e.kind == "wildcard" && e.enabled {
                                    Text(e.ipCount == 0 ? "no hosts visited yet" : "routing \(e.ipCount) live host\(e.ipCount == 1 ? "" : "s")")
                                        .font(.system(size: 11)).foregroundColor(Theme.dim)
                                } else if e.kind == "private" && e.enabled {
                                    Text(e.ipCount == 0 ? "10/8, 172.16/12, 192.168/16" : "\(e.ipCount) subnet\(e.ipCount == 1 ? "" : "s"), your LAN stays local")
                                        .font(.system(size: 11)).foregroundColor(Theme.dim)
                                } else if e.kind == "domain" && e.enabled {
                                    Text("\(e.ipCount) IP\(e.ipCount == 1 ? "" : "s")").font(.system(size: 11)).foregroundColor(Theme.dim)
                                }
                            }
                            if !e.comment.isEmpty { Text(e.comment).font(.system(size: 11)).foregroundColor(Theme.dim).lineLimit(1) }
                            if e.kind == "wildcard", !e.ips.isEmpty {
                                Text("live: " + e.ips.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.dim).lineLimit(2)
                            }
                            if let err = e.error, !err.isEmpty {
                                Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(Theme.warn)
                            }
                        }
                        Spacer()
                        if !e.auto {
                            Button(action: { m.onRemoveEntry(e.raw) }) { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundColor(Theme.dim).help("Remove from routes.conf")
                        }
                    }
                    .padding(.vertical, 10)
                    Divider().background(Theme.line)
                }
                if m.entries.isEmpty {
                    Text("No routes yet. Add a subnet, an IP, a domain, or *.domain below.").font(.system(size: 12)).foregroundColor(Theme.dim).padding(.vertical, 8)
                }
            }
            let fields = HStack(spacing: 8) {
                TextField("private, 10.26.0.0/16, 10.25.8.118, db.example.com or *.example.com", text: $newEntry)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 220)
                TextField("comment (optional)", text: $newComment).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            let controls = HStack(spacing: 8) {
                Text("via").font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
                TunnelSwitch(via: newVia, onSelect: { newVia = $0 })
                Button("Add") {
                    let v = newEntry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    m.addError = m.onAddEntry(v, newComment.trimmingCharacters(in: .whitespaces), newVia)
                    if m.addError == nil { newEntry = ""; newComment = "" }
                }.buttonStyle(AccentButtonStyle()).disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if compact {
                fields
                controls
            } else {
                HStack(spacing: 8) { fields; controls }
            }
            if let err = m.addError { Text(err).font(.system(size: 11)).foregroundColor(Theme.warn) }
            HStack(spacing: 8) {
                Button("Open routes file") { m.onOpenRoutesFile() }.buttonStyle(GhostButtonStyle())
                Button("Reload now") { m.onReload() }.buttonStyle(GhostButtonStyle())
                Button("Route a website…") { m.onRouteSite() }.buttonStyle(GhostButtonStyle())
                    .help("A site said access denied off-VPN? Paste its address; its whole domain goes through the VPN")
                Button("Add team defaults") { m.onAddTeamDefaults() }.buttonStyle(GhostButtonStyle())
                    .help("Append the company's standard entries (DB, app server, *.example.com) that are missing here")
                Spacer()
                Text("Changes apply within about 2 seconds while the VPN is connected.").font(.system(size: 11)).foregroundColor(Theme.dim)
            }
        }
    }

    private func kindLabel(_ k: String) -> String {
        switch k {
        case "cidr": return "subnet"
        case "ip": return "host"
        case "domain": return "domain"
        case "wildcard": return "wildcard"
        case "private": return "private ranges"
        case "dns": return "VPN DNS"
        default: return "invalid"
        }
    }

    private func kindColor(_ k: String) -> Color {
        switch k {
        case "wildcard": return Theme.red
        case "private": return Theme.ok
        case "dns": return Theme.dim
        case "invalid", "": return Theme.warn
        default: return Color(red: 0.55, green: 0.72, blue: 1.0)
        }
    }

    // MARK: log

    private var logCard: some View {
        Card("Daemon log (newest first)") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(m.logLines.reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if m.logLines.isEmpty {
                        Text("No log yet. Install the daemon with:  sudo ~/vpn-split/install.sh").font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.dim)
                    }
                }
            }
            .frame(height: 120)
            Button("Open full log") { m.onOpenLog() }.buttonStyle(GhostButtonStyle())
        }
    }

    // MARK: reachability

    private var reachabilityCard: some View {
        Card("Reachability") {
            Text("DNS plus real TCP connects to the hosts you care about, every minute while the VPN is up. Green means it answered through the interface shown.")
                .font(.system(size: 12)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(m.checks) { c in
                    HStack(spacing: 12) {
                        Circle().fill(c.result == nil ? Theme.dim : (c.result!.ok ? Theme.ok : Theme.warn)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(c.label).font(.system(size: 13, weight: .semibold))
                                if c.label != c.raw { Text(c.raw).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.dim) }
                            }
                            Text(c.result?.line ?? (m.vpnConnected ? "not tested yet" : "tested when the VPN is connected"))
                                .font(.system(size: 11)).foregroundColor(c.result?.ok == false ? Theme.warn : Theme.dim)
                        }
                        Spacer()
                        if c.raw != CheckSpec.dns.raw {
                            Button(action: { m.onRemoveCheck(c.raw) }) { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundColor(Theme.dim).help("Remove this check")
                        }
                    }
                    .padding(.vertical, 8)
                    Divider().background(Theme.line)
                }
                if m.checks.isEmpty {
                    Text("No checks. Add host:port below, e.g. 10.26.4.27:3306.").font(.system(size: 12)).foregroundColor(Theme.dim).padding(.vertical, 8)
                }
            }
            HStack(spacing: 8) {
                TextField("host:port  e.g. 10.26.4.27:3306", text: $newCheck).textFieldStyle(.roundedBorder).frame(minWidth: 200)
                TextField("comment (optional)", text: $newCheckComment).textFieldStyle(.roundedBorder).frame(width: 150)
                Button("Add") {
                    m.checkError = m.onAddCheck(newCheck.trimmingCharacters(in: .whitespaces), newCheckComment.trimmingCharacters(in: .whitespaces))
                    if m.checkError == nil { newCheck = ""; newCheckComment = "" }
                }.buttonStyle(AccentButtonStyle()).disabled(newCheck.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button(m.checksRunning ? "Testing…" : "Test now") { m.onRunChecks() }.buttonStyle(GhostButtonStyle()).disabled(m.checksRunning)
            }
            if let err = m.checkError { Text(err).font(.system(size: 11)).foregroundColor(Theme.warn) }
        }
    }

    // MARK: settings

    private func settingRow<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 6)
    }

    private var settingsCard: some View {
        Card("Settings") {
            settingRow("Show in Dock", "A Dock tile gives you Cmd-Tab, a Dock menu and proper full screen. Menu bar icon is always there.") {
                SegmentSwitch(options: AppPrefs.DockMode.allCases.map { .init(title: $0.title, tag: $0.rawValue, color: Theme.blue.opacity(0.9)) },
                              selected: dockMode, onSelect: { dockMode = $0; m.onDockModeChanged() }, compact: true)
            }
            Divider().background(Theme.line)
            settingRow("Open dashboard when A-Train starts", "Off: A-Train starts quietly in the menu bar.") {
                Toggle("", isOn: $openAtLaunch).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider().background(Theme.line)
            settingRow("Start A-Train at login", m.loginItemNote ?? "Also listed in System Settings > General > Login Items. Never connects the VPN by itself.") {
                Toggle("", isOn: Binding(get: { m.loginItemOn }, set: { m.onSetLoginItem($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if videoURL != nil {
                Divider().background(Theme.line)
                settingRow("Background video", "Turn off to save a little CPU on battery.") {
                    Toggle("", isOn: $showVideo).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            Divider().background(Theme.line)
            settingRow("Window", "Size and position are remembered. The window opens on the screen your mouse is on and can go full screen (green button or Ctrl-Cmd-F).") {
                Button("Reset size and position") { m.onResetWindow() }.buttonStyle(GhostButtonStyle())
            }
            Divider().background(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                Text("Updates").font(.system(size: 13, weight: .semibold))
                Text(m.updateAvailable.map { "Update available: \($0.label)" + ($0.notes.isEmpty ? "" : " — \($0.notes)") }
                     ?? "Checked once a day against a version.json you host (make-dmg.sh writes one in dist/). Empty = off. Nothing installs by itself.")
                    .font(.system(size: 11)).foregroundColor(m.updateAvailable == nil ? Theme.dim : Theme.ok).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("https://…/version.json", text: $updateURLField, onCommit: { m.onSetUpdateURL(updateURLField) })
                        .textFieldStyle(.roundedBorder).frame(minWidth: 260)
                    Button("Save") { m.onSetUpdateURL(updateURLField) }.buttonStyle(GhostButtonStyle())
                    Button("Check now") { m.onSetUpdateURL(updateURLField); m.onCheckUpdate() }.buttonStyle(GhostButtonStyle())
                    if m.updateAvailable != nil { Button("Download") { m.onOpenUpdate() }.buttonStyle(AccentButtonStyle()) }
                }
                if !m.updateStatus.isEmpty { Text(m.updateStatus).font(.system(size: 11)).foregroundColor(Theme.dim) }
            }
            .padding(.vertical, 6)
            .onAppear { updateURLField = m.updateURL }
            .onReceive(m.$updateURL) { if updateURLField.isEmpty { updateURLField = $0 } }
            Divider().background(Theme.line)
            settingRow("Support", "Diagnostics writes one text file to your Desktop (status, routes, DNS, logs; no passwords) to send to whoever helps you.") {
                Button("Save diagnostics") { m.onDiagnostics() }.buttonStyle(GhostButtonStyle())
            }
            Divider().background(Theme.line)
            settingRow("Uninstall", "Removes the background service, its resolver files and the app (asks for your Mac password). Your routes file and the backups stay.") {
                Button("Uninstall A-Train…") { m.onUninstall() }.buttonStyle(AccentButtonStyle(color: Theme.red.opacity(0.85)))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open VPN docs folder") { m.onOpenDocs() }.buttonStyle(GhostButtonStyle())
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Quitting A-Train never changes routing; the daemon keeps working.").font(.system(size: 11)).foregroundColor(Theme.dim)
                if videoURL != nil, showVideo {
                    Text("Background video: “A-Train Status Greenscreen” by The Mining Meteor (YouTube)").font(.system(size: 10)).foregroundColor(Theme.dim)
                } else if videoURL == nil {
                    Text("Add ~/vpn-split/app/video/atrain.mp4 and rebuild for the background video.").font(.system(size: 10)).foregroundColor(Theme.dim)
                }
            }
        }
        .padding(.top, 4)
    }
}
