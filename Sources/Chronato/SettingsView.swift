import AppKit
import ChronatoCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, connection, agents, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .connection: "Connection"
        case .agents: "AI Agents"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .connection: "network"
        case .agents: "sparkles"
        case .about: "info.circle"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One tab's content: 560 pt wide, as tall as it needs. Grouped forms on the
/// system's form backgrounds (System Settings' look).
///
/// Tomato ink tints the switches only, not the pane: on macOS 26 a pane-wide
/// tint also colours every button's label and fills the default button with
/// it, white on light tomato in dark mode (2.2:1). Default buttons keep the
/// system accent, as the spec says once macOS draws their label white on
/// tomato too (it does).
struct SettingsPane: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .connection: ConnectionSettings()
            case .agents: AgentsSettings()
            case .about: AboutSettings()
            }
        }
        .frame(width: 560)
    }
}

// MARK: - Window

/// The Settings window, in AppKit so the status-item menu can open it: a
/// SwiftUI Settings scene has no public opener since macOS 14.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    /// Brings the window forward, on `tab` if given. Chronato is a regular app
    /// (Dock tile, ⌘-Tab, menu bar with Edit menu) while the window is open.
    func show(_ tab: SettingsTab? = nil) {
        let window = self.window ?? Self.makeWindow(store: .shared)
        if self.window == nil {
            self.window = window
            window.delegate = self
            window.setFrameAutosaveName("Settings")
            if !window.setFrameUsingName("Settings") { window.center() }
        }
        if let tab { (window.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab.index }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to the menu bar only, unless another window (Reports) is still open.
        let closing = notification.object as? NSWindow
        let othersOpen = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }

    /// Built, not shown; snapshots render it as is. NSTabViewController puts
    /// the tabs in the toolbar, titles the window after the tab, and fits the
    /// window to the tab's preferred size with the top edge kept, also when a
    /// pane grows (an error line, another agent) or a saved frame is stale.
    static func makeWindow(store: TrackerStore, tab: SettingsTab = .general) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for pane in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPane(tab: pane).environment(store))
            host.sizingOptions = .preferredContentSize
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = tab.index
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }
}

/// The SwiftUI Settings scene's content, which the MenuBarExtra panel opens;
/// it goes with the panel once the status-item menu opens the window above.
struct SettingsView: View {
    @Environment(TrackerStore.self) private var store
    @State var tab: SettingsTab = .general
    /// Set by the menu to deep-link a tab (e.g. Connection); consumed and cleared here.
    /// Observed, not just read on appear, because the window may already be open.
    @AppStorage(Prefs.settingsTab) private var requestedTab: String?

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsPane(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .onAppear(perform: openRequestedTab)
        .onChange(of: requestedTab) { openRequestedTab() }
    }

    private func openRequestedTab() {
        // Snapshots render the tab they were given.
        guard !store.isPreview, let raw = requestedTab else { return }
        if let requested = SettingsTab(rawValue: raw) { tab = requested }
        requestedTab = nil
    }
}

// MARK: - Shared pieces

/// Helper text under a control or group: 12 pt in `textSecondary`, which keeps
/// 4.5:1 on the form backgrounds (the system's `.secondary` does not).
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Studio.Typography.secondary)
            .foregroundStyle(Studio.textSecondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A problem, said with a symbol and words, never colour alone: an error in
/// `errorInk` (tomato and this red are too close to tell apart), a warning
/// with an orange symbol and ordinary text (orange text fails contrast).
struct Problem: View {
    let text: String
    let isError: Bool
    init(_ text: String, isError: Bool = true) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Label {
            Text(text).foregroundStyle(isError ? Studio.errorInk : Studio.textPrimary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(isError ? Studio.errorInk : .orange)
        }
        .font(Studio.Typography.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(TrackerStore.self) private var store
    @AppStorage(Prefs.idleMinutes) private var idleMinutes = 10
    @AppStorage(Prefs.showCustomerInMenuBar) private var showCustomer = false
    @AppStorage(Prefs.hotKeyEnabled) private var hotKeyEnabled = true
    /// AppearanceMode.follow() applies it to every window, panel and menu.
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system
    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: openAtLogin) {
                    Text("Open at login")
                    Text("Start Chronato in the menu bar when you log in.").foregroundStyle(Studio.textSecondary)
                }
                .tint(Studio.accentInk)
                if loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Needs your approval")
                        Text("Allow Chronato in System Settings → General → Login Items.").foregroundStyle(Studio.textSecondary)
                    }
                }
                if let loginError {
                    Problem(loginError)
                }
            }
            Section {
                Picker(selection: $idleMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                } label: {
                    Text("Auto-pause when idle")
                    Text("Pause the timer after this long without keyboard or mouse input.").foregroundStyle(Studio.textSecondary)
                }
                Toggle(isOn: $hotKeyEnabled) {
                    Text("Global shortcut ⌃⌥⌘T")
                    Text("Pauses, resumes, or starts your last activity.").foregroundStyle(Studio.textSecondary)
                }
                .tint(Studio.accentInk)
                if hotKeyEnabled, let error = store.hotKeyError {
                    Problem(error)
                }
                Toggle("Show customer name in the menu bar", isOn: $showCustomer)
                    .tint(Studio.accentInk)
            } footer: {
                Footnote("Timers that run for 24 hours, yours and AI agents', are stopped automatically.")
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLoginStatus)
        // Coming back from System Settings after approving the login item.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private var openAtLogin: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { on in
                do {
                    try LoginItem.set(enabled: on)
                    loginError = nil
                } catch {
                    loginError = "\(error.localizedDescription) Open at login works only for the installed Chronato.app."
                }
                refreshLoginStatus()
            })
    }

    private func refreshLoginStatus() {
        guard !store.isPreview else { return }
        loginStatus = LoginItem.status
    }
}

// MARK: - Connection

private struct ConnectionSettings: View {
    @Environment(TrackerStore.self) private var store
    @State private var url = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $url, prompt: Text("https://kimai.example.net"))
                // The saved token is never shown; typing a new one replaces it.
                SecureField("API token", text: $token, prompt: Text(store.connection == nil ? "Paste your API token" : "Saved in Keychain"))
            } footer: {
                VStack(alignment: .leading, spacing: Studio.Space.xs) {
                    if insecureURL {
                        Problem(KimaiConnection.URLProblem.notHTTPS.localizedDescription)
                    }
                    Footnote("Create an API token in Kimai under your profile → API Access. Chronato stores it in the macOS Keychain.")
                }
            }
            Section {
                HStack(spacing: Studio.Space.s) {
                    status
                    Spacer(minLength: Studio.Space.m)
                    if store.connection != nil {
                        Button("Disconnect…") { confirmDisconnect = true }
                            .disabled(connecting)
                    }
                    Button("Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(connecting || token.isEmpty || KimaiConnection.normalizedURL(url) == nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if url.isEmpty { url = store.connection?.url.absoluteString ?? "" }
        }
        .confirmationDialog("Disconnect from Kimai?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                error = nil
                store.disconnect()
            }
        } message: {
            Text("Chronato removes the API token from the Keychain. Your time entries in Kimai are not affected.")
        }
    }

    /// An http address to another machine: Connect stays disabled, this says why.
    private var insecureURL: Bool {
        do { _ = try KimaiConnection.validatedURL(url) } catch { return error == .notHTTPS }
        return false
    }

    @ViewBuilder private var status: some View {
        if connecting || store.connectionState == .connecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(Studio.textSecondary)
            }
        } else if let error {
            Problem(error)
        } else {
            switch store.connectionState {
            case .online:
                Label {
                    Text("Connected as \(store.me?.displayName ?? "?") · Kimai \(store.serverVersion ?? "?")")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case let .offline(message):
                Problem(message, isError: false)
            case .unconfigured, .connecting:
                Text("Not connected").foregroundStyle(Studio.textSecondary)
            }
        }
    }

    private func connect() {
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do {
                try await store.connect(url: url, token: token)
                token = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: Studio.Space.s) {
            ZStack {
                MarkShape().fill(Studio.textPrimary)
                MarkShape(hand: true).fill(Studio.accentFill)
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            Text("Chronato")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Studio.textPrimary)
            Text("Version \(AppInfo.version)")
                .font(Studio.Typography.body)
                .foregroundStyle(Studio.textSecondary)
                .textSelection(.enabled)
            Text("Kimai time tracking from the menu bar.")
                .padding(.top, Studio.Space.s)
            Link("github.com/weidhaus/Chronato", destination: URL(string: "https://github.com/weidhaus/Chronato")!)
            UpdateSettings().padding(.top, Studio.Space.s)
            VStack(spacing: 2) {
                Text("Free and open source (MIT)")
                Text("Not affiliated with Kimai.")
            }
            .font(Studio.Typography.secondary)
            .foregroundStyle(Studio.textSecondary)
            .padding(.top, Studio.Space.s)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Studio.Space.xxl)
    }
}

/// The flat C-stopwatch: ring and crown, or the hand and pivot. Geometry of
/// Branding/brand.md on its 64-unit grid (master: scripts/make-icon.swift).
private struct MarkShape: Shape {
    var hand = false

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: 34, y: 28.5)
        let part: CGPath
        if hand {
            let line = CGMutablePath()
            line.move(to: center)
            line.addLine(to: CGPoint(x: center.x + 10.5 * cos(.pi / 6), y: center.y + 10.5 * sin(.pi / 6)))
            part = line.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .union(CGPath(ellipseIn: CGRect(x: center.x - 3.9, y: center.y - 3.9, width: 7.8, height: 7.8), transform: nil))
        } else {
            let arc = CGMutablePath()
            arc.addArc(center: center, radius: 18.5, startAngle: .pi * 40 / 180, endAngle: .pi * 320 / 180, clockwise: false)
            part = arc.copy(strokingWithWidth: 7.5, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .union(CGPath(rect: CGRect(x: center.x - 2.5, y: 47, width: 5, height: 6.85), transform: nil))
                .union(CGPath(roundedRect: CGRect(x: center.x - 7.5, y: 53.35, width: 15, height: 5.5),
                              cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
        }
        // The grid's y points up; the view's down.
        let scale = min(rect.width, rect.height) / 64
        return Path(part).applying(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: rect.minX, ty: rect.minY + 64 * scale))
    }
}
