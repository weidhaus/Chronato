import SwiftUI

/// The Settings tab: the connected Kimai, Disconnect, About.
struct SettingsView: View {
    @Environment(PhoneTracker.self) private var tracker
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: server)
                    LabeledContent("User", value: tracker.me?.displayName ?? "–")
                    LabeledContent("Kimai version", value: tracker.serverVersion ?? "–")
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(status.color).accessibilityHidden(true)
                            Text(status.text)
                        }
                    }
                    if let web = webURL {
                        Link(destination: web) {
                            Label("Open Kimai in Safari", systemImage: "safari")
                        }
                    }
                } header: {
                    Text("Kimai")
                } footer: {
                    if case let .offline(message) = tracker.connectionState { Text(message) }
                }
                Section {
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("Removes the API token from this iPhone. Your time in Kimai stays where it is.")
                }
                Section {
                    HStack(spacing: 14) {
                        AppIconImage(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chronato").font(.headline)
                            Text("Version \(appVersion)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    Link(destination: URL(string: "https://github.com/weidhaus/Chronato")!) {
                        Label("Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    LabeledContent("Licence", value: "MIT")
                } header: {
                    Text("About")
                } footer: {
                    Text("Chronato is an independent open-source project. It is not affiliated with or endorsed by Kimai.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Disconnect from Kimai?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { tracker.disconnect() }
            } message: {
                Text("The API token is removed from this iPhone. Your time in Kimai stays where it is.")
            }
        }
    }

    /// "kimai.example.net", or "example.net/kimai" for Kimai in a subdirectory.
    private var server: String {
        guard let url = tracker.connection?.url else { return "–" }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (url.host() ?? url.absoluteString) + (path.isEmpty ? "" : "/" + path)
    }

    private var status: (text: String, color: Color) {
        switch tracker.connectionState {
        case .online: ("Connected", .green)
        case .connecting: ("Connecting…", .yellow)
        case .offline: ("Offline", .orange)
        case .unconfigured: ("Not connected", .secondary)
        }
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
