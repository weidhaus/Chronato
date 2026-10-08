import ActivityKit
import AppIntents
import SwiftUI
import os

/// The Live Activity of a running (or paused) timer. Static: what is tracked;
/// a different Customer → Project → Activity is a new Live Activity.
struct ChronatoActivityAttributes: ActivityAttributes, Equatable {
    struct ContentState: Codable, Hashable {
        /// Running: when the entry began; the timer ticks from here.
        /// Paused: when it was paused.
        var begin: Date
        var note: String?
        var isPaused: Bool
        /// Worked before the break, shown while paused.
        var workedSeconds: Int
    }

    var customerName: String
    var projectName: String
    var activityName: String
    /// The customer's Kimai colour ("#RRGGBB").
    var customerColor: String?

    init(_ work: Work) {
        customerName = work.customerName
        projectName = work.projectName
        activityName = work.activityName
        customerColor = work.customerColor
    }

    /// What the Live Activity shows for a snapshot; nil when nothing runs or is paused.
    static func content(for snapshot: SharedSnapshot) -> (attributes: Self, state: ContentState)? {
        if let running = snapshot.running {
            return (Self(running.work), ContentState(begin: running.begin, note: running.work.note, isPaused: false, workedSeconds: 0))
        }
        if let paused = snapshot.paused {
            return (Self(paused.work), ContentState(begin: paused.pausedAt, note: paused.work.note, isPaused: true, workedSeconds: paused.workedSeconds))
        }
        return nil
    }
}

/// Keeps one Live Activity in step with the snapshot: started when a timer
/// runs (from the app, an intent, or a refresh that finds one started in the
/// browser or on the Mac), updated on note change and pause, ended on stop.
@MainActor
enum LiveActivitySync {
    private static let log = Logger(subsystem: "com.weidhaus.chronato", category: "LiveActivity")

    static func sync(_ snapshot: SharedSnapshot) {
        // Only the app may start Live Activities; the widget extension shares this file.
        #if !WIDGET_EXTENSION
        let wanted = ChronatoActivityAttributes.content(for: snapshot)
        var kept = false
        for activity in Activity<ChronatoActivityAttributes>.activities {
            let id = activity.id
            let isLive = activity.activityState == .active || activity.activityState == .stale
            if isLive, !kept, let wanted, activity.attributes == wanted.attributes {
                kept = true
                if activity.content.state != wanted.state {
                    Task { await apply(ActivityContent(state: wanted.state, staleDate: nil), to: id) }
                }
            } else {
                // Stopped, switched to other work, or a leftover: gone at once.
                Task { await apply(nil, to: id) }
            }
        }
        guard let wanted, !kept, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: wanted.attributes, content: ActivityContent(state: wanted.state, staleDate: nil))
            log.info("Live Activity started")
        } catch {
            log.error("Live Activity not started: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Updates the activity, or ends it for nil. Activity isn't Sendable, so it
    /// is looked up here, off the main actor, and never crosses an actor boundary.
    private nonisolated static func apply(_ content: ActivityContent<ChronatoActivityAttributes.ContentState>?, to id: String) async {
        guard let activity = Activity<ChronatoActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        if let content {
            await activity.update(content)
        } else {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

// MARK: - Views (shared so the app's widget gallery can render them)

/// Lock Screen and banner: what runs, the time, Pause/Resume and Stop.
struct LiveActivityLockScreenView: View {
    let attributes: ChronatoActivityAttributes
    let state: ChronatoActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ActivityNames(attributes: attributes, note: state.note)
                Spacer(minLength: 0)
                ActivityElapsed(state: state, size: 30)
            }
            ActivityButtons(isPaused: state.isPaused)
        }
        .padding(16)
    }
}

/// "Customer · Project" over the activity, then the note. The Dynamic Island
/// shows the customer in its own region and "Project · Activity" here.
struct ActivityNames: View {
    let attributes: ChronatoActivityAttributes
    let note: String?
    var showsCustomer = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsCustomer {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Dot(hex: attributes.customerColor)
                    Text("\(attributes.customerName) · \(attributes.projectName)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(attributes.activityName).font(.headline)
            } else {
                Text("\(attributes.projectName) · \(attributes.activityName)").font(.headline)
            }
            if let note, !note.isEmpty {
                Text(note).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The ticking time, or "Paused" with the time worked before the break.
struct ActivityElapsed: View {
    let state: ChronatoActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        if state.isPaused {
            VStack(alignment: .trailing, spacing: 2) {
                Label("Paused", systemImage: "pause.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(DurationText.short(state.workedSeconds))
                    .font(.system(size: size * 0.8, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Paused after \(DurationText.spoken(state.workedSeconds))")
        } else {
            Text(timerInterval: state.begin...Date.distantFuture, countsDown: false)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Brand.accent)
                // A timer Text claims all the width it may get; this keeps it to "0:00:00".
                .frame(maxWidth: size * 4.2, alignment: .trailing)
                .accessibilityLabel("Running since \(state.begin.formatted(date: .omitted, time: .shortened))")
        }
    }
}

/// Pause (or Resume) and Stop, as in the app's timer card: the primary action
/// tomato, the other gray (tomato text on a pale tomato fill reads poorly). The intents are
/// LiveActivityIntents: they run in the app's process, on its tracker.
struct ActivityButtons: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isPaused {
                Button(intent: ResumeTrackingIntent()) {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(intent: StopTrackingIntent()) {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            } else {
                Button(intent: PauseTrackingIntent()) {
                    Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                Button(intent: StopTrackingIntent()) {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.subheadline.weight(.semibold))
        .tint(Brand.accent)
    }
}

/// Dynamic Island compact leading and minimal: the mark, a pause sign when paused.
struct IslandMark: View {
    let isPaused: Bool

    var body: some View {
        Image(systemName: isPaused ? "pause.circle.fill" : "stopwatch.fill")
            .foregroundStyle(Brand.accent)
            .accessibilityLabel(isPaused ? "Chronato, paused" : "Chronato, running")
    }
}

/// Dynamic Island compact trailing: the elapsed time, or the time worked when paused.
struct IslandCompactTime: View {
    let state: ChronatoActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isPaused {
                Text(DurationText.short(state.workedSeconds)).foregroundStyle(.secondary)
            } else {
                Text(timerInterval: state.begin...Date.distantFuture, countsDown: false)
                    .foregroundStyle(Brand.accent)
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        // Room for "0:00:00"; a timer Text would otherwise push into the camera.
        .frame(width: 58, alignment: .trailing)
    }
}
