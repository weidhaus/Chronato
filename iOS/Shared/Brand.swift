import ChronatoCore
import SwiftUI

// iOS copies of the Mac app's Brand and DurationText (Sources/Chronato/Brand.swift,
// which needs AppKit). Same values; change both together.

/// Chronato's colours: one accent (tomato); everything else is the system's.
enum Brand {
    /// Tomato: the running dot, the mark. Studio holds the tokens and their
    /// rules (ink for text and tint, fill for marks).
    static let accent = Studio.accentFill

    /// Kimai colours come as "#RRGGBB".
    static func color(hex: String?) -> Color? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// "1:05" (h:mm), "1:05:09" with seconds, "7.50 h" for reports.
enum DurationText {
    static func short(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }

    static func long(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// The user's decimal mark, always two decimals so a column lines up and quarter hours stay exact.
    static func hours(_ seconds: Int, locale: Locale = .current) -> String {
        (Double(max(0, seconds)) / 3600).formatted(.number.precision(.fractionLength(2)).locale(locale)) + " h"
    }

    /// "1 hour, 5 minutes" for VoiceOver.
    static func spoken(_ seconds: Int) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

/// Kimai colour dot beside a customer name, never alone. An SF Symbol (not a
/// Circle) so it sits on the text baseline.
struct Dot: View {
    let hex: String?

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(Brand.color(hex: hex) ?? .secondary)
            .accessibilityHidden(true)
    }
}

/// The 8 pt tomato dot beside the word "Running": the one "now" mark.
struct RunningDot: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(Studio.accentFill)
            .accessibilityHidden(true)
    }
}

/// The flat mark, Progress C, fitted to its frame: the arc in the text colour,
/// the dot tomato. Drawn from `MarkRing.master` (ChronatoCore), the geometry
/// the Mac and the icons use. The app icon (`Brandmark`) stays the large mark.
struct Mark: View {
    var body: some View {
        ZStack {
            MarkShape(dot: false).fill(.primary)
            MarkShape(dot: true).fill(Studio.accentFill)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// One piece of the master, its bounding box centred in the view (whose y points down).
private struct MarkShape: Shape {
    let dot: Bool

    func path(in rect: CGRect) -> Path {
        let mark = MarkRing.master
        let box = mark.arc.boundingBoxOfPath.union(mark.dot.boundingBoxOfPath)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let fit = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Path(dot ? mark.dot : mark.arc).applying(fit)
    }
}

/// A problem, said with a symbol and words, never colour alone: an error in
/// `errorInk` (tomato and this red are too close to tell apart), a warning
/// with an orange symbol and ordinary text (orange text fails contrast).
struct Problem: View {
    let text: String
    var isError = true

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
    }
}
