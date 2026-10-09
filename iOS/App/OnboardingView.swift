import ChronatoCore
import SwiftUI

/// First screen: server address and API token, checked against Kimai before
/// anything is saved (PhoneTracker.connect).
struct OnboardingView: View {
    @Environment(PhoneTracker.self) private var tracker
    @State private var url = ""
    @State private var token = ""
    @State private var failure: String?
    @State private var connecting = false
    @FocusState private var focus: Field?

    private enum Field { case url, token }

    var body: some View {
        NavigationStack {
            Form {
                // The mark large once; the next thing is the form.
                Section {
                    VStack(spacing: Studio.Space.m) {
                        AppIconImage(size: 88)
                        Text("Welcome to Chronato")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Studio.textPrimary)
                            .multilineTextAlignment(.center)
                        Text("Start and stop your Kimai timers in two taps. Connect your Kimai to begin.")
                            .font(.subheadline)
                            .foregroundStyle(Studio.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)

                Section {
                    field(icon: "globe") {
                        TextField("Server address", text: $url, prompt: Text("kimai.example.net"))
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .url)
                            .submitLabel(.next)
                            .onSubmit { focus = .token }
                    }
                    field(icon: "key") {
                        SecureField("API token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .token)
                            .submitLabel(.go)
                            .onSubmit(connect)
                        // No paste-permission prompt, and tokens are long.
                        PasteButton(payloadType: String.self) { strings in
                            token = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? token
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                        // Neutral: its glyph is white, and white on light tomato ink fails in dark.
                        .tint(Studio.controlBorder)
                    }
                } header: {
                    Text("Your Kimai")
                } footer: {
                    Text("The token stays in this iPhone's Keychain. Chronato talks only to your Kimai server.")
                        .foregroundStyle(Studio.textSecondary)
                }

                Section {
                    if let failure {
                        Problem(failure)
                    }
                    Button(action: connect) {
                        HStack(spacing: Studio.Space.s) {
                            Text(connecting ? "Connecting…" : "Connect")
                            if connecting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty || connecting)
                }

                Section("Where do I get an API token?") {
                    step(1, "Open Kimai in a browser and sign in.")
                    step(2, "Open your profile (your avatar, top right) → API Access.")
                    step(3, "Create a token, copy it, and paste it above.")
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(trigger: failure) { _, new in new != nil ? .error : nil }
        }
    }

    private func field(icon: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Studio.textSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            content()
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "\(number).circle")
                .foregroundStyle(Studio.textSecondary)
                .font(.title3)
                .accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(Studio.textPrimary)
        }
        .accessibilityLabel("Step \(number): \(text)")
    }

    private func connect() {
        guard !connecting, !url.isEmpty, !token.isEmpty else { return }
        connecting = true
        failure = nil
        focus = nil
        Task {
            do {
                try await tracker.connect(url: url, token: token)
            } catch {
                failure = Self.message(for: error)
            }
            connecting = false
        }
    }

    /// Kimai's own wording points at the Mac's settings; here it should say what to fix in this form.
    private static func message(for error: Error) -> String {
        switch error as? KimaiError {
        case .http(401, _)?, .http(403, _)?:
            "Kimai didn't accept this API token. Copy it again from your profile → API Access."
        case .http(404, _)?, .decoding?:
            "There is no Kimai at this address. If Kimai runs in a subfolder, include it (example.net/kimai)."
        default:
            error.localizedDescription
        }
    }
}

/// The app icon, for onboarding and About (an image set copied from
/// Branding/AppIcon-iOS-1024.png): the one place the mark is shown large.
struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image("Brandmark")
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
