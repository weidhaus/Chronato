import SwiftUI

// iOS copies of the Mac app's Brand and DurationText (Sources/Chronato/Brand.swift,
// which needs AppKit). Same values; change both together.

/// Chronato's colours: one accent (tomato); everything else is the system's.
enum Brand {
    /// Tomato: running state, primary buttons, the mark's hand. Also AccentColor in Shared/Assets.xcassets.
    static let accent = Color(red: 0xE5 / 255, green: 0x53 / 255, blue: 0x3D / 255)

    /// Kimai colours come as "#RRGGBB".
    static func color(hex: String?) -> Color? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// "1:05" (h:mm), "1:05:09" with seconds, "7.5 h" for reports.
enum DurationText {
    static func short(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }

    static func long(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func hours(_ seconds: Int) -> String {
        let h = Double(max(0, seconds)) / 3600
        return h < 10 ? String(format: "%.2f h", h) : String(format: "%.1f h", h)
    }

    /// "1 hour, 5 minutes" for VoiceOver.
    static func spoken(_ seconds: Int) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

/// Kimai colour dot. An SF Symbol (not a Circle) so it sits on the text baseline.
struct Dot: View {
    let hex: String?

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(Brand.color(hex: hex) ?? .secondary)
            .accessibilityHidden(true)
    }
}
