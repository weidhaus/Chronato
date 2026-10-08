import ActivityKit
import SwiftUI
import WidgetKit

// The widget extension: the status widget (Home Screen and Lock Screen) and
// the Live Activity. Their views live in Shared/ (WidgetViews.swift,
// LiveActivity.swift) so the app can render them for inspection.

@main
struct ChronatoWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        ChronatoLiveActivity()
    }
}

// MARK: Status widget

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: StatusProvider()) { entry in
            StatusEntryView(entry: entry)
        }
        .configurationDisplayName("Timer")
        .description("What runs, with Pause and Stop; otherwise today's time and your last activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        StatusWidgetView(snapshot: entry.snapshot, family: family, now: entry.date)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: .sample(.running))
    }

    /// The widget gallery shows sample data until the app has written a snapshot.
    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        let saved = AppGroup.readSnapshot()
        completion(StatusEntry(date: .now, snapshot: context.isPreview && saved == nil ? .sample(.running) : saved))
    }

    /// The app (and every intent) reloads timelines when the snapshot changes,
    /// and a running timer ticks by itself; a new timeline at midnight resets today's time.
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let midnight = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [StatusEntry(date: .now, snapshot: AppGroup.readSnapshot())], policy: .after(midnight)))
    }
}

// MARK: Live Activity

struct ChronatoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChronatoActivityAttributes.self) { context in
            LiveActivityLockScreenView(attributes: context.attributes, state: context.state)
                .activitySystemActionForegroundColor(Brand.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandMark(isPaused: context.state.isPaused).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityElapsed(state: context.state, size: 26).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.customerName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        ActivityNames(attributes: context.attributes, note: context.state.note, showsCustomer: false)
                        ActivityButtons(isPaused: context.state.isPaused)
                    }
                }
            } compactLeading: {
                IslandMark(isPaused: context.state.isPaused)
            } compactTrailing: {
                IslandCompactTime(state: context.state)
            } minimal: {
                IslandMark(isPaused: context.state.isPaused)
            }
            .keylineTint(Brand.accent)
        }
    }
}
