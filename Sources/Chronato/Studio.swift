import AppKit
import SwiftUI

/// The shared material language: graphite, satin silver, and one restrained
/// accent, tomato.
///
/// Duplicated from Meetfacts' and HoldFn's Studio.swift (same names, same
/// values) rather than shared through a package: their art direction says to
/// document identical names and values first and share code only once a
/// maintenance problem actually appears. Only the accent is Chronato's own.
/// Where each token may be used is in design/chronato-interaction-spec.md.
enum Studio {
    // MARK: Surfaces

    static let canvas = dynamic(light: 0xF3F5F5, dark: 0x101315)
    static let sidebar = dynamic(light: 0xE9EDEF, dark: 0x151A1D)
    static let surface = dynamic(light: 0xF7F8F7, dark: 0x1D2326)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x293237)

    // MARK: Text

    static let textPrimary = dynamic(light: 0x1C2427, dark: 0xF4F6F5)
    static let textSecondary = dynamic(light: 0x53636B, dark: 0xB5BEC2)

    // MARK: Lines

    /// Decorative. Does not need to outline every block.
    static let lineSubtle = dynamic(light: 0xCFD7DA, dark: 0x3C484E)
    /// Essential boundaries and focus indicators, which need real contrast.
    static let controlBorder = dynamic(light: 0x687A84, dark: 0x80929B)

    // MARK: Accent: tomato

    /// Tomato as text and focus: dark enough on paper, light enough on graphite
    /// (at least 5.35:1 on every surface above).
    static let accentInk = dynamic(light: 0xAE3520, dark: 0xFF8F7A)
    /// The brand tomato, one value in both appearances: marks, the running dot,
    /// fills. Never small text, and never under white text (3.7:1): text over
    /// it is `onAccentFill` (4.7:1).
    static let accentFill = Color(hex: 0xE5533D)
    static let onAccentFill = Color(hex: 0x171A1B)

    /// Errors stay independent of the brand accent. This red and tomato are
    /// close, so an error is never told by colour alone: symbol and words too.
    static let errorInk = Color(nsColor: NS.errorInk)

    /// Inks AppKit draws itself (menu-item images).
    enum NS {
        static let errorInk = nsDynamic(light: 0x9A2D25, dark: 0xFFB3AA)
    }

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

    /// System font throughout; numbers that tick or line up use monospaced
    /// digits. Menus keep the system menu font and are not styled with these.
    enum Typography {
        /// The Reports title, 24/30; `titleWide` from 1280 pt window width, 28/34.
        static let title = Font.system(size: 24, weight: .semibold)
        static let titleWide = Font.system(size: 28, weight: .semibold)
        /// KPI values.
        static let figure = Font.system(size: 20, weight: .semibold).monospacedDigit()
        /// Section headings, 17/23.
        static let heading = Font.system(size: 17, weight: .semibold)
        /// Controls, table rows, panel fields, 13/18.
        static let body = Font.system(size: 13)
        /// Metadata and helper text, 12/17.
        static let secondary = Font.system(size: 12)
        /// Axis labels and small figures, 11/16.
        static let numeral = Font.system(size: 11).monospacedDigit()
    }

    // MARK: Motion

    /// Content changes, row and pane transitions: 120 ms, gentle ease-out.
    /// With Reduce Motion, change immediately or by opacity only.
    static let motion = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.12)

    // MARK: -

    /// One colour that resolves per appearance, so a view never has to ask
    /// which mode it is in.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: nsDynamic(light: light, dark: dark))
    }

    private static func nsDynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

/// Light, dark, or whatever the system is doing: Settings → General → Appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil means "do not override", which is what following the system means.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var stored: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Prefs.appearance) ?? "") ?? .system
    }

    /// Applies the stored choice now and whenever it changes, to every window,
    /// panel and menu at once. Settings only writes the pref (@AppStorage).
    /// Call once at launch.
    @MainActor static func follow() {
        apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppearanceMode.apply() }
        }
    }

    @MainActor private static func apply() {
        let wanted = stored.appearance
        guard NSApp.appearance?.name != wanted?.name else { return }
        NSApp.appearance = wanted
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    /// 0xRRGGBB. sRGB rather than the generic calibrated space, so a token
    /// renders as the value written in the spec.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
