import SwiftUI

/// The Settings tab (spec §8): Connection, Appearance, AI Agents, About, in
/// the Mac's order and words, as one grouped form.
struct SettingsView: View {
    @Environment(PhoneTracker.self) private var tracker
    @AppStorage(Prefs.appearance) private var appearance = AppearanceMode.system
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    value("Server", server)
                    value("User", tracker.me?.displayName ?? "–")
                    value("Kimai version", tracker.serverVersion ?? "–")
                    status
                    if let web = webURL {
                        Link(destination: web) {
                            Label("Open Kimai", systemImage: "arrow.up.forward.app")
                        }
                    }
                }
                Section {
                    Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                        .foregroundStyle(Studio.errorInk)
                } footer: {
                    Text("Removes the API token from this iPhone. Your time in Kimai stays where it is.")
                        .foregroundStyle(Studio.textSecondary)
                }
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                } footer: {
                    Text("Widgets and the Live Activity follow the system.").foregroundStyle(Studio.textSecondary)
                }
                Section("AI Agents") {
                    Label {
                        Text("AI agents book their own time from your Mac, through Chronato's MCP server. Their hours show in Reports under AI agents.")
                            .foregroundStyle(Studio.textSecondary)
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(Studio.textSecondary)
                    }
                    .font(.subheadline)
                }
                Section {
                    HStack(spacing: 14) {
                        AppIconImage(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chronato").font(.headline).foregroundStyle(Studio.textPrimary)
                            Text("Version \(appVersion)").font(.subheadline).foregroundStyle(Studio.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    Link(destination: URL(string: "https://github.com/weidhaus/Chronato")!) {
                        Label("github.com/weidhaus/Chronato", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Kimai time tracking from your iPhone. Free and open source (MIT). Not affiliated with Kimai.")
                        .foregroundStyle(Studio.textSecondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Disconnect from Kimai?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { tracker.disconnect() }
            } message: {
                Text("Chronato removes the API token from this iPhone's Keychain. Your time entries in Kimai are not affected.")
            }
        }
    }

    /// The value in `textSecondary`: the system's secondary grey is 3.3:1 on white.
    private func value(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).foregroundStyle(Studio.textSecondary) }
    }

    /// Connected (green check), connecting, or not reachable (orange, ordinary text).
    @ViewBuilder private var status: some View {
        switch tracker.connectionState {
        case .online:
            Label {
                Text("Connected").foregroundStyle(Studio.textPrimary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .connecting:
            HStack(spacing: Studio.Space.s) {
                ProgressView()
                Text("Connecting…").foregroundStyle(Studio.textSecondary)
            }
        case let .offline(message):
            Problem(message, isError: false)
        case .unconfigured:
            Text("Not connected").foregroundStyle(Studio.textSecondary)
        }
    }

    /// "kimai.example.net", or "example.net/kimai" for Kimai in a subdirectory.
    private var server: String {
        guard let url = tracker.connection?.url else { return "–" }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (url.host() ?? url.absoluteString) + (path.isEmpty ? "" : "/" + path)
    }

    /// Kimai's timesheet page; its routes carry the user's language ("/de/timesheet/").
    private var webURL: URL? {
        tracker.connection?.url.appendingPathComponent(tracker.me?.language ?? "en").appendingPathComponent("timesheet/")
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
