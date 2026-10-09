import SwiftUI

/// The Studio tokens on iOS: the same names and values as the Mac's
/// Sources/Chronato/Studio.swift (which needs AppKit). Change both together.
/// Where each token may be used is in design/chronato-ios-spec.md.
///
/// The app draws on the system's grouped backgrounds and materials; these
/// tokens are inks, lines and the accent on top of them. Widgets and the Live
/// Activity are archived and re-rendered by the system, so they use only the
/// values that do not change with the appearance (`accentFill`,
/// `onAccentFill`) and the system's hierarchical styles for text.
enum Studio {
    // MARK: Surfaces

    static let canvas = dynamic(light: 0xF3F5F5, dark: 0x101315)
    static let sidebar = dynamic(light: 0xE9EDEF, dark: 0x151A1D)
    static let surface = dynamic(light: 0xF7F8F7, dark: 0x1D2326)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x293237)

    // MARK: Text

    static let textPrimary = dynamic(light: 0x1C2427, dark: 0xF4F6F5)
    /// 5.6:1 or more on every grouped background; the system's secondary label is 3.3:1 in light.
    static let textSecondary = dynamic(light: 0x53636B, dark: 0xB5BEC2)

    // MARK: Lines

    /// Decorative. Does not need to outline every block.
    static let lineSubtle = dynamic(light: 0xCFD7DA, dark: 0x3C484E)
    /// Essential boundaries and focus indicators, which need real contrast.
    static let controlBorder = dynamic(light: 0x687A84, dark: 0x80929B)

    // MARK: Accent: tomato

    /// Tomato as text and tint. Also the AccentColor asset, so system-drawn
    /// tints (alerts, dialogs) match. Never a fill under white text in dark (2.2:1).
    static let accentInk = dynamic(light: 0xAE3520, dark: 0xFF8F7A)
    /// The brand tomato, one value in both appearances: the running dot, marks,
    /// the primary action's fill. Never small text, never under white text
    /// (3.7:1): text over it is `onAccentFill` (4.7:1).
    static let accentFill = Color(hex: 0xE5533D)
    static let onAccentFill = Color(hex: 0x171A1B)

    /// Errors stay independent of the brand accent. This red and tomato are
    /// close, so an error is never told by colour alone: symbol and words too.
    static let errorInk = dynamic(light: 0x9A2D25, dark: 0xFFB3AA)

    // MARK: Spacing

    /// 4-point base. Native control metrics win where the platform defines
    /// them; these are for the space between things.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Type

    /// The Mac's roles as Dynamic Type text styles: on iPhone the user's text
    /// size wins over fixed points. Numbers that tick or line up use monospaced digits.
    enum Typography {
        /// The Reports period title.
        static let title = Font.title3.weight(.semibold)
        /// Report figures.
        static let figure = Font.title2.weight(.semibold).monospacedDigit()
        /// What a timer tracks: "Activity · Project".
        static let heading = Font.headline
        static let body = Font.body
        /// Metadata and helper text.
        static let secondary = Font.subheadline
        /// Axis labels and small figures.
        static let numeral = Font.caption.monospacedDigit()
    }

    // MARK: Motion

    /// Content changes: 120 ms, gentle ease-out. With Reduce Motion, none.
    static let motion = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.12)

    // MARK: -

    /// One colour that resolves per appearance, so a view never has to ask
    /// which mode it is in.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

#if !WIDGET_EXTENSION
/// Settings → Appearance: the Mac's words and symbols. Applies to the app's
/// windows (sheets and alerts included); widgets and the Live Activity follow
/// the system, as the Lock Screen and Home Screen do.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// `.unspecified` follows the system.
    private var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Sets every window of the app, like the Mac's `NSApp.appearance`.
    /// (`preferredColorScheme(nil)` does not reliably go back to the system's.)
    @MainActor func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}
#endif

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    /// 0xRRGGBB in sRGB, so a token renders as the value written in the spec.
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
