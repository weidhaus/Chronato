import AppKit
import ChronatoCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, connection, agents, about
    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(TrackerStore.self) private var store
    @State var tab: SettingsTab = .general
    /// Set by the menu to deep-link a tab (e.g. Connection); consumed and cleared here.
    /// Observed, not just read on appear, because the window may already be open.
    @AppStorage(Prefs.settingsTab) private var requestedTab: String?

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ConnectionSettings()
                .tabItem { Label("Connection", systemImage: "network") }
                .tag(SettingsTab.connection)
            AgentsSettings()
                .tabItem { Label("AI Agents", systemImage: "sparkles") }
                .tag(SettingsTab.agents)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 560)
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

// MARK: - General

private struct GeneralSettings: View {
    @Environment(TrackerStore.self) private var store
    @AppStorage(Prefs.idleMinutes) private var idleMinutes = 10
    @AppStorage(Prefs.showCustomerInMenuBar) private var showCustomer = false
    @AppStorage(Prefs.hotKeyEnabled) private var hotKeyEnabled = true
    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: openAtLogin) {
                    Text("Open at login")
                    Text("Start Chronato in the menu bar when you log in.")
                }
                if loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Needs your approval")
                        Text("Allow Chronato in System Settings → General → Login Items.")
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                Picker(selection: $idleMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                } label: {
                    Text("Auto-pause when idle")
                    Text("Pause the timer after this long without keyboard or mouse input.")
                }
                Toggle("Show customer name in the menu bar", isOn: $showCustomer)
                Toggle(isOn: $hotKeyEnabled) {
                    Text("Global shortcut ⌃⌥⌘T")
                    Text("Pauses, resumes, or starts your last activity.")
                }
                if hotKeyEnabled, let error = store.hotKeyError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                }
            } footer: {
                Text("Timers that run for 24 hours, yours and AI agents', are stopped automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                VStack(alignment: .leading, spacing: 4) {
                    if insecureURL {
                        Text(KimaiConnection.URLProblem.notHTTPS.localizedDescription).foregroundStyle(.red)
                    }
                    Text("Create an API token in Kimai under your profile → API Access. Chronato stores it in the macOS Keychain.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 12)
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
                Text("Connecting…").foregroundStyle(.secondary)
            }
        } else if let error {
            Label { Text(error) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
        } else {
            switch store.connectionState {
            case .online:
                Label {
                    Text("Connected as \(store.me?.displayName ?? "?") · Kimai \(store.serverVersion ?? "?")")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case let .offline(message):
                Label { Text(message) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            case .unconfigured, .connecting:
                Text("Not connected").foregroundStyle(.secondary)
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
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Chronato").font(.title.weight(.semibold))
            Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            Text("Kimai time tracking from the menu bar.").padding(.top, 8)
            Link("github.com/weidhaus/Chronato", destination: URL(string: "https://github.com/weidhaus/Chronato")!)
            UpdateSettings().padding(.top, 8)
            VStack(spacing: 2) {
                Text("Free and open source (MIT)")
                Text("Not affiliated with Kimai.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
