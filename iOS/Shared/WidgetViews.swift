import AppIntents
import SwiftUI
import WidgetKit

/// The Home Screen and Lock Screen widget, from the App Group snapshot.
/// Running: names, ticking time, Pause and Stop. Paused: Resume. Idle: today's
/// time and "Start <most recent>". Shared so the app's widget gallery renders it.
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
                timer(running.begin, size: 30)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    pauseButton(compact: true)
                    stopButton(prominent: true, compact: true)
                }
            case let .paused(paused):
                pausedLabel
                Text(paused.work.activityName).font(.headline).lineLimit(2).padding(.top, 2)
                Spacer(minLength: 4)
                worked(paused.workedSeconds)
                Spacer(minLength: 6)
                resumeButton
            case let .idle(today, last):
                todayTotal(today, size: 30)
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
                    customer(running.work, withProject: true)
                    names(running.work)
                    Spacer(minLength: 4)
                    timer(running.begin, size: 36)
                case let .paused(paused):
                    pausedLabel
                    customer(paused.work, withProject: true).padding(.top, 2)
                    names(paused.work)
                    Spacer(minLength: 4)
                    worked(paused.workedSeconds)
                case let .idle(today, last):
                    todayTotal(today, size: 36)
                    Spacer(minLength: 4)
                    if let last {
                        Text("Last: \(last.activityName)").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(last.customerName) · \(last.projectName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 8) {
                switch phase {
                case .disconnected:
                    EmptyView()
                case .running:
                    pauseButton(compact: false)
                    stopButton(prominent: true, compact: false)
                case .paused:
                    resumeButton
                    stopButton(prominent: false, compact: false)
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
                Text("Not connected").foregroundStyle(.secondary)
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
                Text("\(DurationText.short(paused.workedSeconds)) worked").foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "stopwatch").font(.title2).foregroundStyle(Brand.accent)
            Text("Open Chronato to connect to Kimai.").font(.subheadline)
        }
    }

    private func customer(_ work: Work, withProject: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Dot(hex: work.customerColor)
            Text(withProject ? "\(work.customerName) · \(work.projectName)" : work.customerName).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func names(_ work: Work) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(work.activityName).font(.headline).lineLimit(1)
            if let note = work.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var pausedLabel: some View {
        Label("Paused", systemImage: "pause.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func timer(_ begin: Date, size: CGFloat) -> some View {
        Text(timerInterval: begin...Date.distantFuture, countsDown: false)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(Brand.accent)
            .widgetAccentable()
            .accessibilityLabel("Running since \(begin.formatted(date: .omitted, time: .shortened))")
    }

    private func worked(_ seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DurationText.short(seconds))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("worked").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DurationText.spoken(seconds)) worked before the break")
    }

    private func todayTotal(_ seconds: Int, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(DurationText.short(seconds))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today, \(DurationText.spoken(seconds))")
    }

    // Buttons run App Intents (LiveActivityIntents: in the app's process).

    private func pauseButton(compact: Bool) -> some View {
        Button(intent: PauseTrackingIntent()) {
            label("Pause", "pause.fill", compact: compact)
        }
        .buttonStyle(.bordered)
        .tint(.primary) // gray, as in the app: tomato text on a pale tomato fill reads poorly
    }

    @ViewBuilder private func stopButton(prominent: Bool, compact: Bool) -> some View {
        let button = Button(intent: StopTrackingIntent()) {
            label("Stop", "stop.fill", compact: compact)
        }
        if prominent {
            button.buttonStyle(.borderedProminent).tint(Brand.accent)
        } else {
            button.buttonStyle(.bordered).tint(.primary)
        }
    }

    private var resumeButton: some View {
        Button(intent: ResumeTrackingIntent()) {
            label("Resume", "play.fill", compact: false)
        }
        .buttonStyle(.borderedProminent)
        .tint(Brand.accent)
    }

    private func startButton(_ work: Work, title: String) -> some View {
        Button(intent: StartTrackingIntent(activity: ActivityEntity(work), note: work.note)) {
            Label(title, systemImage: "play.fill")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .tint(Brand.accent)
        .accessibilityLabel("Start \(work.activityName), \(work.customerName)")
    }

    /// Icon only in the small widget (its name for VoiceOver), icon and title in the medium one.
    private func label(_ title: String, _ image: String, compact: Bool) -> some View {
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
        case .running: snapshot.running = .init(entryId: 200, begin: now.addingTimeInterval(-(72 * 60 + 9)), work: work)
        case .paused: snapshot.paused = PausedSession(work: work, pausedAt: now.addingTimeInterval(-600), workedSeconds: 4380)
        case .idle, .unconfigured: break
        }
        return snapshot
    }
}
