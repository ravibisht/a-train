import AppKit
import ServiceManagement
import SwiftUI

// A-Train (named after the fastest man in The Boys): menu bar remote control for the vpnsplitd daemon. Runs as the user, never needs sudo.
// It only reads status.json and edits two files in ~/vpn-split/config; the daemon does the rest.

let userHome = NSHomeDirectory()
let confDir = userHome + "/vpn-split/config"
let routesFile = RoutesFile(path: confDir + "/routes.conf")
let controlFile = ControlFile(path: confDir + "/control.json")
let checksFile = ChecksFile(path: confDir + "/checks.conf")
let presetPath = userHome + "/vpn-split/daemon/routes.conf.example"
let statusPath = "/usr/local/vpn-split/status.json"
let logPath = "/var/log/vpnsplitd.log"
let docsDir = userHome + "/VPN-docs"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var status: DaemonStatus?
    private var dashboardWindow: NSWindow?
    private let model = DashboardModel()
    private let tmodel = TroubleshootModel()
    private var vpn = CheckPoint.Info()
    private var vpnPolling = false
    private var lastVPNPoll = Date.distantPast
    private var connecting = false
    private var disconnecting = false
    private var azure: [AzureVPN.Service] = []
    private var azureBusy: String?                      // service id currently being started/stopped
    private var busySince: Date?                       // when Check Point first reported Connecting/Reconnecting
    private var checkResults: [String: CheckResult] = [:]
    private var checkFailures: [String: Int] = [:]     // consecutive failures per check (warn from 2)
    private var learnSeen: [String: Int] = [:]         // tunnel peers seen in successive ticks; 2 sightings -> a learned check
    private var checksRunning = false
    private var lastChecks = Date.distantPast
    private var wasConnected = false
    private var expiryWarnedFor: Date?                 // session end time we already warned about
    private var updateAvailable: UpdateInfo?
    private var lastUpdateCheck = Date.distantPast
    private var entryPaths: [String: String] = [:]     // routes.conf entry -> interface it currently resolves to
    private let stuckAfter: TimeInterval = 75          // a healthy connect takes ~10-20 s
    private var lastVPNError: String?
    private let maxFailures = 2
    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        routesFile.ensureExists()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installEditMenu()
        VPNPrefs.wantConnected = false       // never connect on launch: the first Connect is always a click
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        registerLoginItemOnFirstLaunch()
        wireDashboard()
        #if ATRAIN_TESTHOOKS
        // Test-only hooks, compiled in by `ATRAIN_TESTHOOKS=1 bash build.sh`; absent from release builds.
        let env = ProcessInfo.processInfo.environment
        if let spec = env["ATRAIN_TEST_WINDOW"] {                                        // test hook: "WxH[:settings]" -> open at that size
            let parts = spec.split(separator: ":"); let dims = parts[0].split(separator: "x").compactMap { Double($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showDashboard()
                if dims.count == 2, let w = self?.dashboardWindow { w.setContentSize(NSSize(width: dims[0], height: dims[1])) }
                let jumpDelay = parts.count > 2 ? (Double(parts[2]) ?? 1.5) : 1.5          // "WxH:target:seconds"
                if parts.count > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + jumpDelay) { self?.model.jumpTo = String(parts[1]) } }
            }
        }
        if let secs = env["ATRAIN_TEST_CLOSE_AFTER"].flatMap(Double.init) {              // test hook: close the dashboard after N s
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in self?.dashboardWindow?.performClose(nil) }
        }
        if env["ATRAIN_TROUBLESHOOT"] == "1" {          // test hook
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showTroubleshoot() }
        }
        #endif
        applyDockPolicy()
        checksFile.ensureExists()
        Notify.shared.setup()
        Notify.shared.onReconnect = { [weak self] in self?.connectVPN() }
        Notify.shared.onOpenUpdate = { [weak self] in self?.openUpdate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.updateTick() }
        // First ever launch: show the dashboard so the app has a face. Later launches follow the preference.
        let first = !UserDefaults.standard.bool(forKey: "didShowDashboardOnce")
        UserDefaults.standard.set(true, forKey: "didShowDashboardOnce")
        if first || AppPrefs.openDashboardAtLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showDashboard() }
        }
    }

    /// Dock icon per preference: a menu bar app has none (accessory); while the dashboard is open we
    /// become a regular app so the window gets a Dock tile, Cmd-Tab, and proper full screen.
    func applyDockPolicy(windowVisible: Bool? = nil) {
        let visible = windowVisible ?? (dashboardWindow?.isVisible ?? false)
        let want: NSApplication.ActivationPolicy
        switch AppPrefs.dockMode {
        case .always: want = .regular
        case .never: want = .accessory
        case .whileOpen: want = visible ? .regular : .accessory
        }
        if NSApp.activationPolicy() != want {
            NSApp.setActivationPolicy(want)
        }
    }

    /// Right-click menu on the Dock tile.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(action("Open Dashboard", #selector(showDashboard)))
        m.addItem(action("Troubleshoot…", #selector(showTroubleshoot)))
        m.addItem(.separator())
        if vpn.connected {
            m.addItem(action("Disconnect VPN", #selector(disconnectVPN)))
        } else {
            m.addItem(action("Connect VPN", #selector(connectVPN)))
        }
        return m
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.applyDockPolicy(windowVisible: false) }
    }

    /// Where a window with no saved frame should appear: the screen the mouse is on, clamped to fit.
    private func placeOnActiveScreen(_ w: NSWindow, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { w.center(); return }
        let sz = NSSize(width: min(size.width, vf.width - 40), height: min(size.height, vf.height - 40))
        w.setFrame(NSRect(x: vf.midX - sz.width / 2, y: vf.midY - sz.height / 2, width: sz.width, height: sz.height), display: false)
    }

    private var resetAfterFullScreen = false

    @objc private func resetWindowFrame() {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame " + AppPrefs.windowFrameName)
        guard let w = dashboardWindow else { return }
        if w.styleMask.contains(.fullScreen) {
            resetAfterFullScreen = true                    // frames set during the exit animation are discarded
            w.toggleFullScreen(nil)
            return
        }
        placeOnActiveScreen(w, size: NSSize(width: 1180, height: 820))
        w.makeKeyAndOrderFront(nil)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard resetAfterFullScreen else { return }
        resetAfterFullScreen = false
        resetWindowFrame()
    }

    @objc private func showSettings() {
        showDashboard()
        // the show sequence pins the scroll view to the top for ~1 s; jump after that
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in self?.model.jumpTo = "settings" }
    }

    /// Launchpad / Dock / Spotlight re-launch of an already running menu bar app lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return false
    }

    // MARK: - Dashboard window

    @objc private func showTroubleshoot() {
        showDashboard()
        model.showTroubleshoot = true
        tmodel.run()
    }

    @objc private func showDashboard() {
        if dashboardWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),   // landscape: the 16:9 video fills it
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "A-Train"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = NSColor(red: 0.024, green: 0.102, blue: 0.310, alpha: 1)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 660, height: 520)
            w.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]   // opens on the Space you are on; green button = full screen
            w.delegate = self
            w.contentView = NSHostingView(rootView: DashboardView(m: model, t: tmodel))
            let saved = UserDefaults.standard.string(forKey: "NSWindow Frame " + AppPrefs.windowFrameName) != nil
            w.setFrameAutosaveName(AppPrefs.windowFrameName)      // remembers size and position across launches
            if !saved { placeOnActiveScreen(w, size: NSSize(width: 1180, height: 820)) }
            dashboardWindow = w
        }
        syncModel()
        model.scrollToken += 1                             // every show starts at the top
        guard let w = dashboardWindow else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        let wasAccessory = NSApp.activationPolicy() == .accessory
        applyDockPolicy(windowVisible: true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if wasAccessory && NSApp.activationPolicy() == .regular {
            // after an accessory->regular switch the first activation can be swallowed; do it again
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.dashboardWindow?.makeKeyAndOrderFront(nil)
            }
        }
        for d in [0.0, 0.3, 1.0] {                         // don't let the Add field grab focus and scroll the view
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                self?.dashboardWindow?.makeFirstResponder(nil)
                self?.scrollDashboardToTop()
            }
        }
    }

    /// SwiftUI's ScrollView keeps its offset when the content height changes; pin it to the top on show
    /// through the AppKit scroll view underneath, which is deterministic.
    private func scrollDashboardToTop() {
        guard let root = dashboardWindow?.contentView else { return }
        func find(_ v: NSView) -> NSScrollView? {
            if let sv = v as? NSScrollView { return sv }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        guard let sv = find(root), let doc = sv.documentView else { return }
        let y = doc.isFlipped ? 0 : max(0, doc.bounds.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    private func wireDashboard() {
        tmodel.deps = TroubleshootDeps(
            statusPath: statusPath,
            confDir: confDir,
            installScript: userHome + "/vpn-split/install.sh",
            daemonLabel: "com.ravi.vpnsplitd",
            currentStatus: { [weak self] in self?.status },
            currentVPN: { [weak self] in self?.vpn ?? CheckPoint.Info() },
            backToSplit: { [weak self] in self?.backToSplit() },
            reloadRoutes: { [weak self] in self?.reloadNow() },
            connectVPN: { [weak self] in self?.connectVPN() },
            disconnectVPN: { [weak self] in self?.disconnectVPN() },
            hasSavedPassword: { Keychain.savedAccount() != nil },
            afterFix: { [weak self] in self?.refresh(); self?.pollVPN(force: true) },
            notify: { [weak self] msg in self?.showError(msg) })
        model.onAzureConnect = { [weak self] in self?.connectAzure() }
        model.onAzureDisconnect = { [weak self] in self?.disconnectAzure() }
        model.onConnect = { [weak self] in self?.connectVPN() }
        model.onDisconnect = { [weak self] in self?.disconnectVPN() }
        model.onSetFull = { [weak self] mins in
            let until: Double? = mins > 0 ? Date().timeIntervalSince1970 + Double(mins * 60) : nil
            if let err = controlFile.write(mode: "full", fullUntil: until) { self?.showError(err) }
            self?.syncModel()
        }
        model.onBackToSplit = { [weak self] in self?.backToSplit(); self?.syncModel() }
        model.onToggleEntry = { [weak self] v in if let err = routesFile.toggle(v) { self?.showError(err) }; self?.syncModel() }
        model.onRemoveEntry = { [weak self] v in if let err = routesFile.remove(v) { self?.showError(err) }; self?.syncModel() }
        model.onAddEntry = { [weak self] v, c, via in
            guard RoutesFile.classify(v) != nil else { return "“\(v)” is not a valid domain, *.domain, IPv4 address or CIDR subnet." }
            let err = routesFile.append(v, comment: c, via: via)
            self?.syncModel()
            return err
        }
        model.onSetVia = { [weak self] v, via in if let err = routesFile.setVia(v, via: via) { self?.showError(err) }; self?.syncModel() }
        model.onSavePassword = { [weak self] in self?.savePassword(thenConnect: false); self?.syncModel() }
        model.onForgetPassword = { [weak self] in self?.forgetPassword(); self?.syncModel() }
        model.onToggleAuto = { [weak self] in self?.toggleAutoConnect(); self?.syncModel() }
        model.onOpenRoutesFile = { [weak self] in self?.openRoutesFile() }
        model.onReload = { [weak self] in self?.reloadNow() }
        model.onOpenLog = { [weak self] in self?.openLog() }
        model.onOpenDocs = { [weak self] in self?.openDocs() }
        (model.loginItemOn, model.loginItemNote) = AppPrefs.loginItemState()
        model.onSetLoginItem = { [weak self] on in
            if let err = AppPrefs.setStartAtLogin(on) { self?.showError(err) }
            if let m = self?.model { (m.loginItemOn, m.loginItemNote) = AppPrefs.loginItemState() }
        }
        model.onDockModeChanged = { [weak self] in self?.applyDockPolicy() }
        model.onRunChecks = { [weak self] in self?.runChecks() }
        model.onAddCheck = { [weak self] v, c in
            let err = checksFile.append(v, comment: c)
            if err == nil { self?.syncModel(); if self?.vpn.connected == true { self?.runChecks() } }
            return err
        }
        model.onRemoveCheck = { [weak self] raw in
            if let e = checksFile.remove(raw) { self?.showError(e) }
            self?.checkResults[raw] = nil; self?.checkFailures[raw] = nil
            self?.updateIcon(); self?.syncModel()
        }
        model.onAddTeamDefaults = { [weak self] in self?.addTeamDefaults() }
        model.onRouteSite = { [weak self] in self?.routeSiteClicked() }
        model.onDiagnostics = { [weak self] in self?.saveDiagnostics() }
        model.onUninstall = { [weak self] in self?.uninstallClicked() }
        model.onSetUpdateURL = { [weak self] u in
            UserDefaults.standard.set(u.trimmingCharacters(in: .whitespaces), forKey: Updates.urlKey)
            self?.model.updateURL = u.trimmingCharacters(in: .whitespaces)
        }
        model.onCheckUpdate = { [weak self] in self?.checkForUpdate(manual: true) }
        model.onOpenUpdate = { [weak self] in self?.openUpdate() }
        model.updateURL = UserDefaults.standard.string(forKey: Updates.urlKey) ?? ""
        model.onResetWindow = { [weak self] in self?.resetWindowFrame() }
    }

    /// Push current state into the SwiftUI model. Cheap; only runs while the window is visible.
    /// Push current state into the SwiftUI model, publishing only values that actually changed so the
    /// 2 s refresh never re-renders (and never scrolls) an unchanged list.
    private func syncModel() {
        guard dashboardWindow?.isVisible == true else { return }
        func put<T: Equatable>(_ kp: ReferenceWritableKeyPath<DashboardModel, T>, _ v: T) {
            if model[keyPath: kp] != v { model[keyPath: kp] = v }
        }
        let s = status
        put(\.daemonUp, health != .daemonDown)
        put(\.vpnConnected, vpn.connected)
        put(\.vpnLine, vpnLine)
        put(\.iface, s?.vpn.iface ?? "")
        put(\.routeCount, s?.routeCount ?? 0)
        let req = controlFile.read()
        let inEffect = (health == .daemonDown) ? (req?.mode ?? "split") : (s?.mode ?? "split")
        put(\.modeInEffect, inEffect)
        put(\.requestedMode, req?.mode ?? inEffect)
        put(\.fullUntil, req?.fullUntil ?? s?.fullUntil)
        put(\.publicIp, (s?.publicIp).flatMap { $0.isEmpty ? nil : $0 } ?? "—")
        put(\.note, (health == .daemonDown) ? "Daemon not running. Install or start it: sudo ~/vpn-split/install.sh" : s?.note)
        put(\.connecting, connecting)
        put(\.disconnecting, disconnecting)
        put(\.autoReconnect, VPNPrefs.autoConnect)
        let (liOn, liNote) = AppPrefs.loginItemState()        // may change behind our back in System Settings
        put(\.loginItemOn, liOn); put(\.loginItemNote, liNote)
        put(\.savedAccount, Keychain.savedAccount())
        put(\.azureName, azureService?.name)
        put(\.azureState, azureBusy != nil ? "working…" : (azureService?.state ?? ""))
        put(\.azureBusy, azureBusy != nil || (azureService?.busy ?? false))
        let rows: [RowEntry]
        if let es = s?.entries, health != .daemonDown {
            // hosts discovered for a wildcard are daemon-managed: shown inline under the wildcard, not as rows
            rows = es.filter { !(($0.auto ?? false) && $0.kind == "ip") }
                .map { RowEntry(raw: $0.raw, kind: $0.kind ?? "", enabled: $0.enabled, comment: $0.comment ?? "",
                                ipCount: $0.ips?.count ?? 0, ips: $0.ips ?? [], error: $0.error, auto: $0.auto ?? ($0.kind == "dns"),
                                via: $0.via ?? "checkpoint") }
        } else {
            rows = routesFile.entries().map { RowEntry(raw: $0.value, kind: RoutesFile.classify($0.value).map(kindName) ?? "",
                                                       enabled: $0.enabled, comment: "", ipCount: 0, ips: [], error: nil, auto: false, via: $0.via) }
        }
        put(\.entries, rows.map { var r = $0; r.path = entryPaths[$0.raw]; return r })
        put(\.checks, checkRows)
        let lines = (try? String(contentsOfFile: logPath, encoding: .utf8)).map { Array($0.split(separator: "\n").suffix(25)).map(String.init) } ?? []
        put(\.logLines, lines)
    }

    private func kindName(_ k: EntryKind) -> String {
        switch k { case .cidr: return "cidr"; case .ip: return "ip"; case .domain: return "domain"; case .wildcard: return "wildcard"; case .privateRanges: return "private" }
    }

    /// A menu-bar-only app has no main menu, so Cmd+X/C/V/A have no target and paste is dead in every
    /// dialog (including the password field). An invisible standard Edit menu fixes that.
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(title: "A-Train")
        appMenu.addItem(withTitle: "About A-Train", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide A-Train", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit A-Train", action: #selector(quit), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Open Dashboard", action: #selector(showDashboard), keyEquivalent: "o")
        view.addItem(withTitle: "Troubleshoot…", action: #selector(showTroubleshoot), keyEquivalent: "t")
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(.separator())
        win.addItem(withTitle: "Reset Window Size and Position", action: #selector(resetWindowFrame), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    // MARK: - VPN login (Check Point CLI + Keychain)

    private func pollVPN(force: Bool = false) {
        guard !vpnPolling, force || Date().timeIntervalSince(lastVPNPoll) >= 10 else { return }
        vpnPolling = true
        lastVPNPoll = Date()
        DispatchQueue.global(qos: .utility).async {
            let i = CheckPoint.info()
            let az = AzureVPN.services()
            DispatchQueue.main.async {
                let old = self.vpn
                self.vpn = i
                self.azure = az
                self.vpnPolling = false
                self.expiryTick(i)
                self.dropNotice(from: old, to: i)
                if i.connected { VPNPrefs.failures = 0; self.lastVPNError = nil; self.transientNote = nil }
                self.unstickIfNeeded(i)
                self.autoConnectTick()
            }
        }
    }

    /// Check Point sometimes wedges in "Connecting" forever (seen 2026-09-26). If it has been busy longer
    /// than `stuckAfter` and we are not the ones connecting, reset it with its own disconnect command so
    /// the next Connect (manual or automatic) can succeed.
    private func unstickIfNeeded(_ i: CheckPoint.Info) {
        guard i.busy, !connecting, !disconnecting else { busySince = nil; return }
        if busySince == nil { busySince = Date(); return }
        guard Date().timeIntervalSince(busySince!) > stuckAfter else { return }
        busySince = nil
        transientNote = "Check Point was stuck \(i.status.lowercased()) for over a minute; reset it"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CheckPoint.disconnect()
            DispatchQueue.main.async { self.pollVPN(force: true) }
        }
    }

    /// Reconnect rule: you clicked Connect earlier in this app session, auto mode on, not up, not busy,
    /// password saved, under the failure cap. Disconnect (or quitting A-Train) cancels it.
    private var nextAutoAttempt = Date.distantPast
    private var transientNote: String?

    private func autoConnectTick() {
        guard VPNPrefs.autoConnect, VPNPrefs.wantConnected, vpn.idle,
              !connecting, !disconnecting, VPNPrefs.failures < maxFailures,
              Keychain.savedAccount() != nil, Date() >= nextAutoAttempt else { return }
        startConnect(manual: false)
    }

    private func startConnect(manual: Bool) {
        guard !connecting, !disconnecting else { return }          // one attempt at a time
        guard let account = Keychain.savedAccount() else {
            if manual { savePassword(thenConnect: true) }
            return
        }
        let password: String
        switch Keychain.read(account) {
        case .password(let p):
            password = p
            Keychain.migrateIfNeeded(account, p)           // one-time: end the per-build Keychain prompts
        case .missing:
            if manual { savePassword(thenConnect: true) }
            return
        case .denied:
            // Do not nag every 10 s: count it and let the lockout guard stop automatic retries.
            VPNPrefs.failures += 1
            lastVPNError = "Keychain access to the saved password was denied"
            if manual { showError(lastVPNError! + ". Choose “Always Allow” when macOS asks, or save the password again.") }
            return
        }
        guard let site = VPNPrefs.site ?? vpn.site else {
            if manual { showError("No VPN site known yet. Connect once with the Check Point app, then try again.") }
            return
        }
        connecting = true
        lastVPNError = nil
        transientNote = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CheckPoint.connect(site: site, user: account, password: password, takeOver: manual)
            DispatchQueue.main.async {
                self.connecting = false
                switch result {
                case .success:
                    VPNPrefs.failures = 0
                    self.nextAutoAttempt = .distantPast
                case .failure(.transient(let msg)):
                    // network / client busy: retry later with backoff, never counted against the password
                    self.transientNote = msg
                    self.nextAutoAttempt = Date().addingTimeInterval(30)
                    if manual { self.showError("Could not connect right now: \(msg)") }
                case .failure(.rejected(let msg)):
                    VPNPrefs.failures += 1
                    self.lastVPNError = msg
                    self.nextAutoAttempt = Date().addingTimeInterval(60)
                    let low = msg.lowercased()
                    let credential = ["auth", "credential", "password", "wrong", "invalid", "denied", "login", "user"].contains { low.contains($0) }
                    let hint = credential
                        ? "Check Point rejected the saved password. Company passwords rotate: if yours changed or expired, click Save password… and enter the new one, then Connect."
                        : "Check Point refused the connection: \(msg)."
                    if manual || VPNPrefs.failures >= self.maxFailures {
                        self.showError("VPN login failed (\(VPNPrefs.failures) of \(self.maxFailures)).\n\n\(hint)\n\nAutomatic attempts stop after \(self.maxFailures) failures; the next manual Connect resets the count.")
                    }
                    if VPNPrefs.failures >= self.maxFailures {
                        Notify.shared.post(id: "login-rejected", title: "VPN password rejected",
                                           body: credential ? "Your company password probably changed. Open A-Train > Save password…" : msg)
                    }
                }
                self.pollVPN(force: true)
            }
        }
    }

    @objc private func connectVPN() {
        VPNPrefs.wantConnected = true
        VPNPrefs.failures = 0
        nextAutoAttempt = .distantPast
        startConnect(manual: true)
    }

    @objc private func disconnectVPN() {
        guard !disconnecting else { return }
        VPNPrefs.wantConnected = false                     // also stops auto-reconnect until Connect is clicked
        transientNote = nil
        disconnecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CheckPoint.disconnect()
            DispatchQueue.main.async {
                self.disconnecting = false
                if case .failure(let msg) = r { self.showError("Disconnect failed: \(msg)") }
                self.pollVPN(force: true)
            }
        }
    }

    @objc private func toggleAutoConnect() {
        VPNPrefs.autoConnect.toggle()
        // Only keeps an existing session alive: it never starts a connection you did not click for.
        if VPNPrefs.autoConnect && Keychain.savedAccount() == nil { savePassword(thenConnect: false) }
    }

    @objc private func savePasswordClicked() { savePassword(thenConnect: false) }

    private func savePassword(thenConnect: Bool) {
        let alert = NSAlert()
        alert.messageText = "Save VPN password"
        alert.informativeText = "Stored in your macOS Keychain, protected by your Mac login. A-Train uses it to run the Check Point command-line login so you are not asked every time. Update it here when your company password changes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 90))
        let site = NSTextField(frame: NSRect(x: 0, y: 64, width: 340, height: 24))
        site.placeholderString = "VPN site (e.g. 203.0.113.10)"
        site.stringValue = VPNPrefs.site ?? vpn.site ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 32, width: 340, height: 24))
        user.placeholderString = "username"
        user.stringValue = Keychain.savedAccount() ?? vpn.user ?? ""
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        pass.placeholderString = "password"
        box.addSubview(site); box.addSubview(user); box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = pass.stringValue.isEmpty && !user.stringValue.isEmpty ? pass : user
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let s = site.stringValue.trimmingCharacters(in: .whitespaces)
        let u = user.stringValue.trimmingCharacters(in: .whitespaces)
        let p = pass.stringValue
        guard !s.isEmpty, !u.isEmpty, !p.isEmpty else { showError("Site, username and password are all required."); return }
        if let err = Keychain.set(u, p) { showError(err); return }
        VPNPrefs.site = s
        VPNPrefs.failures = 0
        lastVPNError = nil
        if thenConnect { VPNPrefs.wantConnected = true; startConnect(manual: true) }
    }

    @objc private func forgetPassword() {
        Keychain.delete()
        VPNPrefs.autoConnect = false
        VPNPrefs.wantConnected = false
    }

    // MARK: - Azure VPN (macOS system VPN service; no Azure window needed)

    private var azureService: AzureVPN.Service? { azure.first }

    private var azureLine: String {
        guard let a = azureService else { return "Azure VPN: no profile yet" }
        if azureBusy == a.id { return "Azure VPN: working… (\(a.name))" }
        return "Azure VPN: \(a.state) · \(a.name)"
    }

    @objc private func connectAzure() { azureAction(start: true) }
    @objc private func disconnectAzure() { azureAction(start: false) }

    private func azureAction(start: Bool) {
        guard let a = azureService, azureBusy == nil else { return }
        azureBusy = a.id
        DispatchQueue.global(qos: .userInitiated).async {
            let r = start ? AzureVPN.start(a.id) : AzureVPN.stop(a.id)
            var finalState = ""
            if case .success = r { finalState = AzureVPN.waitFor(a.id, connected: start, seconds: start ? 40 : 15) }
            DispatchQueue.main.async {
                self.azureBusy = nil
                switch r {
                case .failure(let msg):
                    self.showError("Azure VPN could not \(start ? "connect" : "disconnect"): \(msg)")
                case .success:
                    if start && finalState != "Connected" {
                        self.showError("Azure VPN did not reach Connected (state: \(finalState)). If its sign-in expired, open the Azure VPN Client once, sign in, then use A-Train from then on.")
                        _ = AzureVPN.stop(a.id)
                    }
                }
                self.pollVPN(force: true)
            }
        }
    }

    private func addAzureSection(_ menu: NSMenu) {
        menu.addItem(info(azureLine))
        guard let a = azureService else {
            menu.addItem(info("Add a profile in the Azure VPN Client once; A-Train drives it after that."))
            menu.addItem(.separator()); return
        }
        if a.connected || a.state == "Disconnecting" {
            let it = action("Disconnect Azure VPN", #selector(disconnectAzure)); it.isEnabled = azureBusy == nil && !a.busy; menu.addItem(it)
        } else {
            let it = action("Connect Azure VPN (\(a.name))", #selector(connectAzure)); it.isEnabled = azureBusy == nil && !a.busy; menu.addItem(it)
        }
        menu.addItem(.separator())
    }

    private var vpnLine: String {
        if !vpn.installed { return "VPN: Check Point client not found" }
        if connecting { return "VPN: Connecting…" }
        if disconnecting { return "VPN: Disconnecting…" }
        if !vpn.serviceUp { return "VPN: Check Point service not responding" }
        if vpn.busy { return "VPN: \(vpn.status)…" }
        if vpn.connected {
            return "VPN: Connected" + (vpn.remainingPretty.map { " · \($0)" } ?? "")
        }
        return "VPN: Not connected"
    }

    private func addVPNSection(_ menu: NSMenu) {
        menu.addItem(info(vpnLine))
        if VPNPrefs.failures >= maxFailures, let e = lastVPNError {
            for l in wrap("VPN login failed \(VPNPrefs.failures)×: \(e). Password changed? Use Save password… below.", width: 60) { menu.addItem(info(l)) }
        }
        if let n = transientNote, VPNPrefs.autoConnect, VPNPrefs.wantConnected, !vpn.connected {
            for l in wrap("\(n). Retrying automatically.", width: 60) { menu.addItem(info(l)) }
        }
        guard vpn.installed else { menu.addItem(.separator()); return }
        if vpn.connected || disconnecting {
            let it = action("Disconnect VPN", #selector(disconnectVPN)); it.isEnabled = !disconnecting && !connecting; menu.addItem(it)
        } else {
            let it = action(Keychain.savedAccount() == nil ? "Connect VPN (save password first)…" : "Connect VPN", #selector(connectVPN))
            it.isEnabled = !connecting && !vpn.busy && vpn.serviceUp
            menu.addItem(it)
        }
        let auto = action("Reconnect automatically if the session drops", #selector(toggleAutoConnect))
        auto.state = VPNPrefs.autoConnect ? .on : .off
        menu.addItem(auto)
        if let acct = Keychain.savedAccount() {
            menu.addItem(action("Save VPN password… (\(acct))", #selector(savePasswordClicked)))
            menu.addItem(action("Forget VPN password", #selector(forgetPassword)))
        } else {
            menu.addItem(action("Save VPN password…", #selector(savePasswordClicked)))
        }
        menu.addItem(.separator())
    }

    // MARK: - State

    private enum Health { case daemonDown, vpnOff, split, full }

    private var health: Health {
        guard let s = status, !s.isStale else { return .daemonDown }
        if !s.vpn.connected { return .vpnOff }
        return s.mode == "full" ? .full : .split
    }

    private func refresh() {
        status = DaemonStatus.load(from: statusPath)
        pollVPN()
        checksTick()
        updateIcon()
        syncModel()
    }

    // MARK: - Reachability checks

    /// Every 60 s while the VPN is up, 5 s after it comes up, and whenever the config changes while up.
    private func checksTick() {
        let connected = status?.vpn.connected == true && vpn.connected
        if connected != wasConnected {
            wasConnected = connected
            if connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.runChecks() }
            } else {
                checkFailures.removeAll()             // no point warning while the VPN is down
            }
        }
        if connected, Date().timeIntervalSince(lastChecks) >= 60 { runChecks() }
        if Date().timeIntervalSince(lastUpdateCheck) >= 6 * 3600 { updateTick() }
    }

    private func runChecks() {
        guard !checksRunning else { return }
        checksRunning = true
        lastChecks = Date()
        model.checksRunning = true
        let specs = [CheckSpec.dns] + checksFile.specs()
        let probes: [(String, String)] = (status?.entries ?? []).compactMap { e in
            guard e.enabled, let k = e.kind, let a = Reachability.probeAddress(for: e.raw, kind: k) else { return nil }
            return (e.raw, a)
        }
        let known = Set(specs.map { $0.raw })
        let learnedCount = specs.filter { $0.comment.hasPrefix("learned") }.count
        DispatchQueue.global(qos: .utility).async {
            var results: [String: CheckResult] = [:]
            for sp in specs { results[sp.raw] = Reachability.run(sp) }
            var paths: [String: String] = [:]
            for (raw, addr) in probes { paths[raw] = Reachability.interface(for: addr) }
            // learn checks: private destinations this Mac is talking to through the tunnel right now
            var candidates: [String] = []
            if learnedCount < 5 {
                for c in Reachability.establishedPrivatePeers() where !known.contains(c) && candidates.count < 5 {
                    if Reachability.interface(for: String(c.split(separator: ":")[0])).hasPrefix("utun") { candidates.append(c) }
                }
            }
            DispatchQueue.main.async {
                for c in candidates {
                    let n = (self.learnSeen[c] ?? 0) + 1
                    self.learnSeen[c] = n
                    if n == 2, checksFile.append(c, comment: "learned from your traffic") == nil {
                        self.learnSeen[c] = nil
                    }
                }
                self.checksRunning = false
                self.model.checksRunning = false
                self.checkResults = results
                self.entryPaths = paths
                for (raw, r) in results {
                    let n = r.ok ? 0 : (self.checkFailures[raw] ?? 0) + 1
                    self.checkFailures[raw] = n
                    if n == 2, self.vpn.connected, let sp = specs.first(where: { $0.raw == raw }) {
                        Notify.shared.post(id: "check-" + raw,
                                           title: sp.builtIn ? "DNS is not resolving" : "\(sp.label) is not reachable",
                                           body: sp.builtIn ? "Names do not resolve (\(r.line)). Web pages will not load until this is fixed; open A-Train > Troubleshoot."
                                                            : "\(sp.raw): \(r.line). The VPN is connected; open A-Train > Troubleshoot.")
                    }
                }
                self.updateIcon()
                self.syncModel()
            }
        }
    }

    /// A check that failed twice in a row while the VPN is up: the tunnel is not doing its job.
    private var allSpecs: [CheckSpec] { [CheckSpec.dns] + checksFile.specs() }

    private var degraded: [CheckSpec] {
        guard vpn.connected else { return [] }
        return allSpecs.filter { (checkFailures[$0.raw] ?? 0) >= 2 }
    }

    private var checkRows: [CheckRow] {
        allSpecs.map { CheckRow(raw: $0.raw, label: $0.label, result: checkResults[$0.raw], failures: checkFailures[$0.raw] ?? 0) }
    }

    // MARK: - Session expiry / drop notifications

    private func expiryTick(_ i: CheckPoint.Info) {
        guard i.connected, let r = i.remaining else { expiryWarnedFor = nil; return }
        let p = r.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return }
        let secs = p[0] * 3600 + p[1] * 60 + p[2]
        let end = Date().addingTimeInterval(TimeInterval(secs))
        guard secs <= 15 * 60 else { return }
        if let w = expiryWarnedFor, abs(w.timeIntervalSince(end)) < 120 { return }     // same session, already warned
        expiryWarnedFor = end
        Notify.shared.post(id: "expiry", title: "VPN session ends in \(max(1, secs / 60)) min",
                           body: VPNPrefs.autoConnect ? "A-Train will reconnect automatically." : "Reconnect now to keep the database reachable.",
                           reconnectAction: !VPNPrefs.autoConnect)
    }

    private func dropNotice(from old: CheckPoint.Info, to new: CheckPoint.Info) {
        guard old.connected, !new.connected, !new.busy, !disconnecting, VPNPrefs.wantConnected else { return }
        Notify.shared.post(id: "drop", title: "VPN disconnected",
                           body: VPNPrefs.autoConnect ? "A-Train is reconnecting." : "Internal hosts are unreachable until you reconnect.",
                           reconnectAction: !VPNPrefs.autoConnect)
    }

    // MARK: - Updates

    private func updateTick() {
        lastUpdateCheck = Date()
        let url = UserDefaults.standard.string(forKey: Updates.urlKey) ?? ""
        guard !url.isEmpty else { return }
        if let last = UserDefaults.standard.object(forKey: Updates.lastCheckKey) as? Double,
           Date().timeIntervalSince1970 - last < 20 * 3600 { return }              // once a day
        checkForUpdate(manual: false)
    }

    private func checkForUpdate(manual: Bool) {
        let url = UserDefaults.standard.string(forKey: Updates.urlKey) ?? ""
        guard !url.isEmpty else { model.updateStatus = "Set an update URL first."; return }
        model.updateStatus = "Checking…"
        Updates.check(url: url) { [weak self] info, err in
            guard let self = self else { return }
            if let e = err { self.model.updateStatus = "Check failed: \(e)"; return }
            self.updateAvailable = info
            self.model.updateAvailable = info
            self.model.updateStatus = info == nil ? "You have the latest build (\(Updates.currentBuild))." : "Newer build available."
            if let i = info, !manual {
                Notify.shared.post(id: "update-" + i.build, title: "A-Train update available", body: "Version \(i.label). Click to download.", update: true)
            }
        }
    }

    @objc private func openUpdate() {
        guard let i = updateAvailable, let u = URL(string: i.url) else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: - Support

    @objc private func saveDiagnostics() {
        let extra = [vpnLine, azureLine, headerLine, modeLine, "public IP: \(status?.publicIp ?? "?")",
                     "entry paths: \(entryPaths)"].joined(separator: "\n")
        let results = Array(checkResults.values)
        DispatchQueue.global(qos: .userInitiated).async {
            let url = Diagnostics.collect(checks: results, extra: extra)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @objc private func uninstallClicked() {
        let a = NSAlert()
        a.messageText = "Uninstall A-Train?"
        a.informativeText = "This stops and removes the background service, its DNS resolver files, the installer receipt and the app itself. Your routes file (~/vpn-split/config) and the route backups are kept. Reconnect the VPN afterwards to get the normal full tunnel back.\n\nYou will be asked for your Mac password."
        a.alertStyle = .warning
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // Self-contained root script (never executes anything from the user's home).
        let script = """
        launchctl bootout system/com.ravi.vpnsplitd 2>/dev/null || true
        rm -f /Library/LaunchDaemons/com.ravi.vpnsplitd.plist /etc/newsyslog.d/vpnsplitd.conf
        if [ -d /etc/resolver ]; then for f in /etc/resolver/*; do [ -f "$f" ] && head -1 "$f" 2>/dev/null | grep -q 'managed by vpnsplitd' && rm -f "$f"; done; fi
        rm -f /usr/local/vpn-split/vpnsplitd.py /usr/local/vpn-split/status.json /usr/local/vpn-split/status.json.tmp /usr/local/vpn-split/applied.json /usr/local/vpn-split/applied.json.tmp
        rm -rf /usr/local/vpn-split/pkg
        pkgutil --forget com.ravi.atrain.pkg 2>/dev/null || true
        rm -rf /Applications/A-Train.app '\(userHome)/Applications/A-Train.app'
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Admin.run(script)
            DispatchQueue.main.async {
                switch r {
                case .success:
                    _ = AppPrefs.setStartAtLogin(false)
                    let done = NSAlert()
                    done.messageText = "A-Train removed"
                    done.informativeText = "The service is gone. Disconnect and reconnect the VPN to restore its normal full-tunnel routes. Config kept in ~/vpn-split/config."
                    done.runModal()
                    NSApp.terminate(nil)
                case .failure(let e):
                    if !e.lowercased().contains("cancel") { self.showError("Uninstall failed: \(e)") }
                }
            }
        }
    }

    /// "This site says access denied unless I'm on the VPN": paste its address, the whole domain gets routed.
    @objc private func routeSiteClicked() {
        let a = NSAlert()
        a.messageText = "Route a website through the VPN"
        a.informativeText = "Paste the address of the site that refused you off-VPN, e.g. https://portal.example.com/login. Its whole domain will go through the VPN, so it sees the office IP."
        a.addButton(withTitle: "Route it"); a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…"
        a.accessoryView = field
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !text.contains("://") { text = "https://" + text }
        guard let host = URL(string: text)?.host, !host.isEmpty else { showError("That does not look like a web address."); return }
        let entry: String
        if RoutesFile.classify(host) == .ip { entry = host }
        else if RoutesFile.classify(host) == .domain { entry = "*." + Self.registrableDomain(host) }
        else { showError("“\(host)” is not a valid host name."); return }
        let existing = routesFile.entries().first { $0.value == entry }
        if let e = existing {
            if !e.enabled, let err = routesFile.toggle(entry) { showError(err); return }
            showInfo(e.enabled ? "\(entry) is already routed through the VPN." : "\(entry) was disabled; enabled it again.")
        } else if let err = routesFile.append(entry, comment: "added via Route a website (\(host))") {
            showError(err); return
        } else {
            showInfo("\(entry) now goes through the VPN. Reload the page in a few seconds.")
        }
        syncModel()
    }

    /// portal.intranet.example.co.uk -> example.co.uk; portal.example.com -> example.com
    static func registrableDomain(_ host: String) -> String {
        let l = host.split(separator: ".").map(String.init)
        guard l.count > 2 else { return host }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac"]
        if l[l.count - 1].count == 2, secondLevel.contains(l[l.count - 2]), l.count >= 3 { return l.suffix(3).joined(separator: ".") }
        return l.suffix(2).joined(separator: ".")
    }

    @objc private func addTeamDefaults() {
        let (n, err) = routesFile.addMissing(fromPreset: presetPath)
        if let e = err { showError(e); return }
        showInfo(n == 0 ? "All team defaults are already in your routes file." : "Added \(n) team default\(n == 1 ? "" : "s") to routes.conf.")
        syncModel()
    }

    private static var menuIconCache: [String: NSImage] = [:]

    /// A-Train's own mark as a macOS template icon (black + alpha, so it follows the menu bar's light/dark
    /// look). One file per state; falls back to SF Symbols if the resources are missing.
    private func menuIcon(_ name: String, fallback: String) -> NSImage? {
        if let cached = Self.menuIconCache[name] { return cached }
        let img: NSImage
        if let p1 = Bundle.main.path(forResource: name, ofType: "png"), let base = NSImage(contentsOfFile: p1) {
            img = base
            if let p2 = Bundle.main.path(forResource: name + "@2x", ofType: "png"), let hi = NSImage(contentsOfFile: p2),
               let rep = hi.representations.first {
                rep.size = NSSize(width: 18, height: 18)               // logical size for the retina rep
                img.addRepresentation(rep)
            }
            img.size = NSSize(width: 18, height: 18)
        } else if let sym = NSImage(systemSymbolName: fallback, accessibilityDescription: "A-Train") {
            img = sym
        } else {
            return nil
        }
        img.isTemplate = true
        Self.menuIconCache[name] = img
        return img
    }

    private func updateIcon() {
        let img: NSImage?
        switch health {
        case .daemonDown: img = menuIcon("menu-warn", fallback: "exclamationmark.shield")
        case .vpnOff:     img = menuIcon("menu-off", fallback: "shield.slash")
        case .split:      img = degraded.isEmpty ? menuIcon("menu-split", fallback: "shield.lefthalf.filled") : menuIcon("menu-warn", fallback: "exclamationmark.shield")
        case .full:       img = degraded.isEmpty ? menuIcon("menu-full", fallback: "shield.fill") : menuIcon("menu-warn", fallback: "exclamationmark.shield")
        }
        statusItem.button?.image = img
        statusItem.button?.toolTip = vpnLine + "\n" + azureLine + "\n" + headerLine + "\n" + modeLine + reachLine.map { "\n" + $0 }.joined()
    }

    /// Menu lines for the checks (only while the VPN is up).
    private var reachLine: [String] {
        guard vpn.connected else { return [] }
        return allSpecs.compactMap { sp in
            guard let r = checkResults[sp.raw] else { return nil }
            return (r.ok ? "✓ " : "✗ ") + sp.label + ": " + r.line
        }
    }

    private var headerLine: String {
        switch health {
        case .daemonDown: return "⚠ A-Train daemon not running"
        case .vpnOff:     return "○ VPN not connected"
        case .split, .full:
            let iface = status?.vpn.iface ?? "utun"
            let n = status?.routeCount ?? 0
            return "● VPN connected · \(iface) · \(n) route\(n == 1 ? "" : "s") via VPN"
        }
    }

    private var modeLine: String {
        guard let s = status, !s.isStale else { return "Mode: unknown (install or start the daemon)" }
        if s.mode == "full" {
            if let u = s.fullUntil {
                return "Mode: Full VPN until \(timeFmt.string(from: Date(timeIntervalSince1970: u)))"
            }
            return "Mode: Full VPN (until you switch back)"
        }
        return "Mode: Split (only listed routes via VPN)"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = status

        let openIt = NSMenuItem(title: "Open A-Train Dashboard", action: #selector(showDashboard), keyEquivalent: "o")
        openIt.target = self
        menu.addItem(openIt)
        let fixIt = NSMenuItem(title: "Troubleshoot…", action: #selector(showTroubleshoot), keyEquivalent: "t")
        fixIt.target = self
        menu.addItem(fixIt)
        menu.addItem(.separator())
        addVPNSection(menu)
        addAzureSection(menu)
        menu.addItem(info(headerLine))
        menu.addItem(info(modeLine))
        if vpn.connected, health != .daemonDown {
            for l in reachLine { menu.addItem(info(l)) }
            if !degraded.isEmpty { menu.addItem(info("⚠ VPN is up but \(degraded.map { $0.label }.joined(separator: ", ")) not reachable")) }
            if checksFile.specs().isEmpty { menu.addItem(info("No host checks yet (dashboard > Reachability)")) }
            menu.addItem(action(checksRunning ? "Testing reachability…" : "Test reachability now", #selector(testNow)))
        }
        if let u = updateAvailable {
            menu.addItem(action("Update available: \(u.label)…", #selector(openUpdate)))
        }
        if let ip = s?.publicIp, s?.vpn.connected == true, health != .daemonDown {
            menu.addItem(info("Public IP: \(ip)"))
        }
        if let note = s?.note, !note.isEmpty, health != .daemonDown {
            for line in wrap(note, width: 60) { menu.addItem(info(line)) }
        }
        // the mode the user asked for may be a second or two ahead of what the daemon reports
        let requested = controlFile.read()
        let shownMode = requested?.mode ?? s?.mode ?? "split"
        if let r = requested, let s = s, health != .daemonDown, r.mode != s.mode {
            menu.addItem(info("Switching to \(r.mode == "full" ? "Full VPN" : "Split")…"))
        }
        menu.addItem(.separator())

        if shownMode == "full" {
            menu.addItem(action("Back to Split now", #selector(backToSplit)))
        } else {
            let sub = NSMenu()
            let choices: [(String, Int)] = [("For 15 minutes", 15), ("For 30 minutes", 30),
                                            ("For 1 hour", 60), ("For 2 hours", 120),
                                            ("Until I switch back", 0)]
            for (title, mins) in choices {
                let it = NSMenuItem(title: title, action: #selector(setFull(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = mins
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: "Switch to Full VPN", action: nil, keyEquivalent: "")
            menu.addItem(parent)
            menu.setSubmenu(sub, for: parent)
        }
        menu.addItem(.separator())

        let routes = NSMenu()
        if let entries = s?.entries, health != .daemonDown {
            if entries.isEmpty { routes.addItem(info("(no entries yet)")) }
            for e in entries {
                if e.kind == "dns" {                       // synthesized by the daemon, not in routes.conf
                    routes.addItem(info("DNS \(e.raw)  –  pushed by the VPN, routed automatically"))
                    continue
                }
                var title = e.raw
                if let c = e.comment, !c.isEmpty { title += "  –  \(c)" }
                if e.kind == "domain", let ips = e.ips, e.enabled {
                    title += "  (\(ips.count) IP\(ips.count == 1 ? "" : "s"))"
                }
                if e.kind == "wildcard", e.enabled {
                    let n = e.ips?.count ?? 0
                    title += n == 0 ? "  (whole domain, no hosts visited yet)" : "  (routing \(n) live host\(n == 1 ? "" : "s"))"
                }
                if let err = e.error, !err.isEmpty { title += "  ⚠ \(err)" }
                let it = NSMenuItem(title: title, action: #selector(toggleEntry(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = e.raw
                it.state = e.enabled ? .on : .off
                routes.addItem(it)
            }
        } else {
            let local = routesFile.entries()
            if local.isEmpty { routes.addItem(info("(no entries yet)")) }
            for e in local {
                let it = NSMenuItem(title: e.value, action: #selector(toggleEntry(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = e.value
                it.state = e.enabled ? .on : .off
                routes.addItem(it)
            }
        }
        routes.addItem(.separator())
        routes.addItem(action("Add domain or IP…", #selector(addEntry)))
        routes.addItem(action("Route a website…", #selector(routeSiteClicked)))
        routes.addItem(action("Open routes file", #selector(openRoutesFile)))
        routes.addItem(action("Reload now", #selector(reloadNow)))
        let rp = NSMenuItem(title: "Routes via VPN", action: nil, keyEquivalent: "")
        menu.addItem(rp)
        menu.setSubmenu(routes, for: rp)
        menu.addItem(.separator())

        menu.addItem(action("Open log", #selector(openLog)))
        menu.addItem(action("Open VPN docs folder", #selector(openDocs)))
        menu.addItem(action("Save diagnostics to Desktop", #selector(saveDiagnostics)))
        let login = action("Start at login", #selector(toggleLogin))
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("Quit A-Train", #selector(quit)))
    }

    private func info(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }

    private func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var cur = ""
        for w in text.split(separator: " ") {
            if cur.count + w.count + 1 > width, !cur.isEmpty { lines.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + w
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.map { "⚠ " + $0 }
    }

    // MARK: - Actions

    @objc private func setFull(_ sender: NSMenuItem) {
        let mins = sender.representedObject as? Int ?? 0
        let until: Double? = mins > 0 ? Date().timeIntervalSince1970 + Double(mins * 60) : nil
        if let err = controlFile.write(mode: "full", fullUntil: until) { showError(err) }
    }

    @objc private func backToSplit() {
        if let err = controlFile.write(mode: "split", fullUntil: nil) { showError(err) }
    }

    @objc private func toggleEntry(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        if let err = routesFile.toggle(v) { showError(err) }
    }

    @objc private func addEntry() {
        let alert = NSAlert()
        alert.messageText = "Add a route via VPN"
        alert.informativeText = "A domain (jira.example.com), an IP (10.25.8.118), a subnet (10.26.0.0/16), or a whole domain with a wildcard (*.example.com) so every subdomain you visit is routed via the VPN. Domains are re-resolved every 5 minutes."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
        let entry = NSTextField(frame: NSRect(x: 0, y: 32, width: 340, height: 24))
        entry.placeholderString = "domain, IP or CIDR"
        let comment = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        comment.placeholderString = "comment (optional)"
        box.addSubview(entry)
        box.addSubview(comment)
        alert.accessoryView = box
        alert.window.initialFirstResponder = entry
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = entry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard RoutesFile.classify(value) != nil else {
            showError("“\(entry.stringValue)” is not a valid domain, IPv4 address or CIDR subnet.")
            return
        }
        if let err = routesFile.append(value, comment: comment.stringValue.trimmingCharacters(in: .whitespaces)) {
            showError(err)
        }
    }

    @objc private func openRoutesFile() {
        routesFile.ensureExists()
        openInEditor(routesFile.path)
    }

    @objc private func reloadNow() {
        routesFile.touch()
        refresh()
    }

    @objc private func openLog() {
        guard FileManager.default.fileExists(atPath: logPath) else {
            showError("No log yet at \(logPath). Install the daemon first:\n\nsudo ~/vpn-split/install.sh")
            return
        }
        openInEditor(logPath)
    }

    @objc private func openDocs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: docsDir))
    }

    @objc private func testNow() { runChecks() }

    private func showInfo(_ msg: String) {
        let a = NSAlert(); a.messageText = "A-Train"; a.informativeText = msg; a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if NSWorkspace.shared.open(url) { return }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err = err { DispatchQueue.main.async { self.showError("Could not open \(path): \(err.localizedDescription)") } }
        }
    }

    private func showError(_ msg: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "A-Train"
        a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: - Login item

    private var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            showError("Could not change the login item: \(error.localizedDescription)\n\nYou can also add A-Train under System Settings › General › Login Items.")
        }
    }

    private func registerLoginItemOnFirstLaunch() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
