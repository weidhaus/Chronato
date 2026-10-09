import SwiftUI
import WidgetKit

/// Debug aid, like the Mac's `swift run Chronato snapshot <dir>`: with the
/// launch arguments `-ChronatoFixture idle -ChronatoRenderWidgets YES` the app
/// renders every widget family and the Live Activity presentations, in light
/// and dark, to Documents/WidgetGallery/*.png. Copy them out with
/// `xcrun simctl get_app_container booted com.weidhaus.chronato data`.
/// The frames only approximate the system's (sizes of a 6.3" iPhone).
@MainActor
enum WidgetGallery {
    static func renderIfRequested() {
        #if DEBUG && !WIDGET_EXTENSION
        guard UserDefaults.standard.bool(forKey: "ChronatoRenderWidgets") else { return }
        let dir = URL.documentsDirectory.appendingPathComponent("WidgetGallery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let states: [PhoneTracker.Fixture] = [.running, .paused, .idle, .unconfigured]

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            for state in states {
                let snapshot = SharedSnapshot.sample(state, now: now)
                for (family, size) in [(WidgetFamily.systemSmall, CGSize(width: 170, height: 170)),
                                       (.systemMedium, CGSize(width: 364, height: 170))] {
                    render(StatusWidgetView(snapshot: snapshot, family: family, now: now)
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(.rect(cornerRadius: 22)),
                           scheme, dir, "widget-\(family)-\(state)-\(suffix)")
                }
                // The Lock Screen tints accessory widgets; white on a dark wallpaper is close.
                for (family, size) in [(WidgetFamily.accessoryRectangular, CGSize(width: 172, height: 76)),
                                       (.accessoryInline, CGSize(width: 257, height: 26))] where scheme == .dark {
                    render(StatusWidgetView(snapshot: snapshot, family: family, now: now)
                        .foregroundStyle(.white)
                        .frame(width: size.width, height: size.height)
                        .padding(8)
                        .background(Color(red: 0.1, green: 0.15, blue: 0.3)),
                           scheme, dir, "widget-\(family)-\(state)")
                }
            }

            for state in [PhoneTracker.Fixture.running, .paused] {
                guard let (attributes, content) = ChronatoActivityAttributes.content(for: .sample(state, now: now)) else { continue }
                render(LiveActivityLockScreenView(attributes: attributes, state: content)
                    .frame(width: 370)
                    .background(scheme == .light ? Color(white: 0.93) : Color(white: 0.15))
                    .clipShape(.rect(cornerRadius: 22)),
                       scheme, dir, "activity-lockscreen-\(state)-\(suffix)")
                guard scheme == .dark else { continue } // the Dynamic Island is always dark
                render(HStack {
                    IslandMark(isPaused: content.isPaused)
                    Spacer(minLength: 120) // the camera
                    IslandCompactTime(state: content)
                }
                .padding(.horizontal, 14)
                .frame(height: 37)
                .background(.black, in: .capsule),
                       scheme, dir, "island-compact-\(state)")
                render(VStack(spacing: 8) {
                    HStack(alignment: .top) {
                        IslandMark(isPaused: content.isPaused, size: 26).font(.title2).padding(.leading, 4)
                        Spacer()
                        Text(attributes.customerName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        ActivityElapsed(state: content, size: 26).padding(.trailing, 4)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ActivityNames(attributes: attributes, note: content.note, showsCustomer: false)
                        ActivityButtons(isPaused: content.isPaused)
                    }
                }
                .padding(18)
                .frame(width: 371)
                .background(.black, in: .rect(cornerRadius: 44)),
                       scheme, dir, "island-expanded-\(state)")
            }
        }
        print("WidgetGallery: wrote \(dir.path)")
        #endif
    }

    private static func render(_ view: some View, _ scheme: ColorScheme, _ dir: URL, _ name: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 3
        try? renderer.uiImage?.pngData()?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
