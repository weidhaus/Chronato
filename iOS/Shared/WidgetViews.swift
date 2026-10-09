import AppIntents
import SwiftUI
import WidgetKit

/// The Home Screen and Lock Screen widget, from the App Group snapshot.
/// Running: names, ticking time, Pause and Stop. Paused: Resume. Idle: today's
/// time and "Start <most recent>". Shared so the app's widget gallery renders it.
///
/// Studio in a widget (spec §9): the system's container and hierarchical text
/// styles, so the Home Screen's tinted and clear modes and the Lock Screen's
/// tinting keep working; neutral buttons; tomato only as the running dot.
struct StatusWidgetView: View {
    let snapshot: SharedSnapshot?
    let family: WidgetFamily
    /// The timeline entry's date, for today's total.
    let now: Date

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private enum Phase {
        case disconnected
        case running(SharedSnapshot.Running)
        case paused(PausedSession)
        case idle(todaySeconds: Int, last: Work?)
    }

    private var phase: Phase {
        guard let snapshot, snapshot.isConnected else { return .disconnected }
        if let running = snapshot.running { return .running(running) }
        if let paused = snapshot.paused { return .paused(paused) }
        return .idle(todaySeconds: snapshot.todaySeconds(at: now), last: snapshot.lastWork)
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .disconnected:
                disconnected
            case let .running(running):
                customer(running.work)
                Text(running.work.activityName).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                timer(running.begin, size: 28)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    button(PauseTrackingIntent(), "Pause", "pause.fill", compact: true)
                    button(StopTrackingIntent(), "Stop", "stop.fill", compact: true)
                }
            case let .paused(paused):
                pausedLabel
                Text(paused.work.activityName).font(.headline).lineLimit(2).padding(.top, 2)
                Spacer(minLength: 4)
                worked(paused.workedSeconds)
                Spacer(minLength: 6)
                button(ResumeTrackingIntent(), "Resume", "play.fill", compact: false)
            case let .idle(today, last):
                todayTotal(today, size: 28)
                Spacer(minLength: 6)
                if let last {
                    Text(last.customerName).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.bottom, 4)
                    startButton(last, title: last.activityName)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                switch phase {
                case .disconnected:
                    disconnected
                case let .running(running):
                    names(running.work)
                    Spacer(minLength: 4)
                    timer(running.begin, size: 34)
                case let .paused(paused):
                    pausedLabel.padding(.bottom, 2)
                    names(paused.work)
                    Spacer(minLength: 4)
                    worked(paused.workedSeconds)
                case let .idle(today, last):
                    todayTotal(today, size: 34)
                    Spacer(minLength: 4)
                    if let last {
                        Text("\(last.activityName) · \(last.projectName)").font(.subheadline.weight(.semibold)).lineLimit(1)
                        customer(last)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 8) {
                switch phase {
                case .disconnected:
                    EmptyView()
                case .running:
                    button(PauseTrackingIntent(), "Pause", "pause.fill", compact: false)
                    button(StopTrackingIntent(), "Stop", "stop.fill", compact: false)
                case .paused:
                    button(ResumeTrackingIntent(), "Resume", "play.fill", compact: false)
                    button(StopTrackingIntent(), "Stop", "stop.fill", compact: false)
                case let .idle(_, last):
                    if let last { startButton(last, title: "Start") }
                }
            }
            .frame(width: 118)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .disconnected:
                Text("Chronato").font(.headline)
                Text("Not connected to Kimai").foregroundStyle(.secondary)
            case let .running(running):
                Text(timerInterval: running.begin...Date.distantFuture, countsDown: false)
                    .font(.headline)
                    .monospacedDigit()
                    .widgetAccentable()
                Text(running.work.activityName)
                Text(running.work.customerName).foregroundStyle(.secondary)
            case let .paused(paused):
                Label("Paused", systemImage: "pause.fill").font(.headline).widgetAccentable()
                Text(paused.work.activityName)
                Text("\(DurationText.short(paused.workedSeconds)) worked before").foregroundStyle(.secondary)
            case let .idle(today, last):
                Text("Today \(DurationText.short(today))").font(.headline).monospacedDigit().widgetAccentable()
                if let last {
                    Text(last.activityName)
                    Text(last.customerName).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var inline: some View {
        switch phase {
        case .disconnected:
            Text("Chronato")
        case let .running(running):
            Label {
                Text("\(Text(timerInterval: running.begin...Date.distantFuture, countsDown: false)) \(running.work.activityName)")
            } icon: {
                Image(systemName: "stopwatch")
            }
        case let .paused(paused):
            Label("Paused · \(paused.work.activityName)", systemImage: "pause.fill")
        case let .idle(today, _):
            Label("Today \(DurationText.short(today))", systemImage: "stopwatch")
        }
    }

    // MARK: Parts

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not connected to Kimai").font(.subheadline.weight(.semibold))
            Text("Open Chronato to connect.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func customer(_ work: Work) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Dot(hex: work.customerColor)
            Text(work.customerName).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// "Activity · Project", then the customer and the note, as in the app.
    private func names(_ work: Work) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(work.activityName) · \(work.projectName)").font(.headline).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Dot(hex: work.customerColor)
                Text([work.customerName, work.note ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var pausedLabel: some View {
        Label("Paused", systemImage: "pause.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// The ticking time, the tomato dot beside it.
    private func timer(_ begin: Date, size: CGFloat) -> some View {
        HStack(spacing: 6) {
            RunningDot()
            Text(timerInterval: begin...Date.distantFuture, countsDown: false)
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Running since \(begin.formatted(date: .omitted, time: .shortened))")
    }

    private func worked(_ seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DurationText.short(seconds))
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
            Text("worked before").font(.caption)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DurationText.spoken(seconds)) worked before")
    }

    private func todayTotal(_ seconds: Int, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(DurationText.short(seconds))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today, \(DurationText.spoken(seconds))")
    }

    // Buttons run App Intents (LiveActivityIntents: in the app's process).
    // Neutral, as in the app: the system's grey fill, primary label.

    /// Icon only in the small widget's pair (its name for VoiceOver), icon and title otherwise.
    private func button(_ intent: some AppIntent, _ title: String, _ image: String, compact: Bool) -> some View {
        Button(intent: intent) {
            Group {
                if compact {
                    Image(systemName: image).accessibilityLabel(title)
                } else {
                    Label(title, systemImage: image)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.primary)
    }

    private func startButton(_ work: Work, title: String) -> some View {
        Button(intent: StartTrackingIntent(activity: ActivityEntity(work), note: work.note)) {
            Label(title, systemImage: "play.fill")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(.primary)
        .accessibilityLabel("Start \(work.activityName), \(work.customerName)")
    }
}

// MARK: Sample data

extension SharedSnapshot {
    /// Fictional snapshots for the widget gallery's placeholder and previews.
    static func sample(_ state: PhoneTracker.Fixture, now: Date = .now) -> SharedSnapshot {
        let work = Work(projectId: 12, activityId: 3, note: "Call tagging automation",
                        customerName: "Northwind Traders", projectName: "Ops Dashboard",
                        activityName: "Automation", customerColor: "#2ECC40")
        var snapshot = SharedSnapshot(isConnected: state != .unconfigured, running: nil, paused: nil,
                                      todaySeconds: 2 * 3600 + 35 * 60, lastWork: work, updatedAt: now)
        switch state {
        case .running, .offline: snapshot.running = .init(entryId: 200, begin: now.addingTimeInterval(-(72 * 60 + 9)), work: work)
        case .paused: snapshot.paused = PausedSession(work: work, pausedAt: now.addingTimeInterval(-600), workedSeconds: 4380)
        case .idle, .unconfigured, .error: break
        }
        return snapshot
    }
}
