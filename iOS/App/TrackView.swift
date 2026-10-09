import ChronatoCore
import SwiftUI

/// The Track tab (design/chronato-ios-spec.md §4): the Mac menu's blocks as a
/// grouped list. Notices; what runs or is paused, its actions and today's
/// totals; Recent, one tap to start again; New Timer….
struct TrackView: View {
    @Environment(PhoneTracker.self) private var tracker
    @State private var sheet: TrackSheet?
    @State private var openedLaunchSheet = false

    var body: some View {
        NavigationStack {
            List {
                Notices()
                TimerSection(open: { sheet = $0 })
                if !tracker.recent.isEmpty {
                    Section {
                        ForEach(tracker.recent) { entry in
                            RecentRow(entry: entry) { sheet = .newTimer(choice(from: entry)) }
                        }
                    } header: {
                        Text("Recent")
                    } footer: {
                        Text(tracker.isRunning ? "Tap to switch to an entry. Touch and hold to change it first."
                                               : "Tap to start an entry again. Touch and hold to change it first.")
                            .foregroundStyle(Studio.textSecondary)
                    }
                }
                Section {
                    Button { sheet = .newTimer(.remembered(tracker)) } label: { CommandLabel("New Timer…", "plus") }
                        .disabled(!tracker.canAct)
                }
            }
            .navigationTitle("Track")
            .toolbar {
                if tracker.isBusy {
                    ToolbarItem(placement: .topBarTrailing) { ProgressView() }
                }
            }
            // Pulling also reloads customers, projects and activities (just created in Kimai, say).
            .refreshable {
                await tracker.reloadCatalog()
                await tracker.refresh()
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case let .newTimer(choice): NewTimerSheet(choice: choice)
                case .note: NoteSheet(tracker: tracker)
                }
            }
            // Haptics confirm what Kimai accepted (start; stop and pause), or that it failed.
            .sensoryFeedback(trigger: tracker.active?.id) { old, new in
                new != nil ? .start : (old != nil ? .stop : nil)
            }
            .sensoryFeedback(trigger: tracker.lastError) { _, new in new != nil ? .error : nil }
            // `-ChronatoSheet newTimer|note` opens a sheet at launch, for screenshots.
            .task {
                guard !openedLaunchSheet else { return }
                openedLaunchSheet = true
                switch UserDefaults.standard.string(forKey: "ChronatoSheet") {
                case "newTimer": sheet = .newTimer(.remembered(tracker))
                case "note" where tracker.active != nil || tracker.paused != nil: sheet = .note
                default: break
                }
            }
        }
    }

    private func choice(from entry: KimaiTimesheet) -> StartChoice {
        StartChoice(customerId: entry.customerId ?? tracker.project(entry.projectId)?.customer,
                    projectId: entry.projectId, activityId: entry.activityId, note: entry.description ?? "")
    }
}

enum TrackSheet: Identifiable {
    case newTimer(StartChoice)
    case note

    var id: String {
        switch self {
        case let .newTimer(choice): "new-\(choice.id)"
        case .note: "note"
        }
    }
}

// MARK: - Notices

/// The last error (or the 24 h notice), then connecting or offline: above
/// everything, as block A of the Mac menu.
private struct Notices: View {
    @Environment(PhoneTracker.self) private var tracker

    var body: some View {
        let offline: String? = if case let .offline(message) = tracker.connectionState { message } else { nil }
        if tracker.lastError != nil || offline != nil || tracker.connectionState == .connecting {
            Section {
                if let error = tracker.lastError {
                    HStack(alignment: .firstTextBaseline) {
                        Problem(error)
                        Spacer(minLength: 0)
                        Button("Dismiss", systemImage: "xmark.circle.fill") { tracker.lastError = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(Studio.textSecondary)
                    }
                }
                if tracker.connectionState == .connecting {
                    HStack(spacing: Studio.Space.s) {
                        ProgressView()
                        Text("Connecting to Kimai…").foregroundStyle(Studio.textSecondary)
                    }
                }
                if let offline {
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text("Kimai is not reachable").foregroundStyle(Studio.textPrimary)
                        } icon: {
                            Image(systemName: "wifi.slash").foregroundStyle(.orange)
                        }
                        Text(Self.reason(offline))
                            .font(.subheadline)
                            .foregroundStyle(Studio.textSecondary)
                            .lineLimit(3)
                    }
                    Button { Task { await tracker.refresh() } } label: { CommandLabel("Try Again", "arrow.clockwise") }
                        .disabled(tracker.isBusy)
                }
            } footer: {
                if offline != nil, tracker.active != nil || tracker.paused != nil {
                    Text("Below is what Chronato knew last.").foregroundStyle(Studio.textSecondary)
                }
            }
        }
    }

    /// "The Internet connection appears to be offline." from "Can't reach Kimai: …":
    /// the line above already says it.
    private static func reason(_ message: String) -> String {
        let prefix = "Can't reach Kimai: "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
    }
}

// MARK: - Timer

/// Block B and C of the Mac menu: what runs or is paused, its time, its
/// actions; Today · This week below.
private struct TimerSection: View {
    @Environment(PhoneTracker.self) private var tracker
    let open: (TrackSheet) -> Void
    /// The large time, scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 52

    var body: some View {
        if let entry = tracker.active {
            let work = tracker.work(entry)
            Section {
                VStack(alignment: .leading, spacing: Studio.Space.xs) {
                    WorkLines(work: work)
                    // Ticks by itself; no per-second state in the tracker.
                    Text(timerInterval: entry.begin...Date.distantFuture, countsDown: false)
                        .font(.system(size: heroSize, weight: .light).monospacedDigit())
                        .foregroundStyle(Studio.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.top, Studio.Space.s)
                    HStack(spacing: 6) {
                        RunningDot()
                        Text("Running since \(sinceText(entry.begin))")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Studio.textSecondary)
                }
                .padding(.vertical, Studio.Space.xs)
                Button { Task { await tracker.pause() } } label: { CommandLabel("Pause", "pause") }
                    .disabled(!tracker.canAct)
                Button { Task { await tracker.stop() } } label: { CommandLabel("Stop", "stop") }
                    .disabled(!tracker.canAct)
                noteButton(work.note)
            } footer: {
                Totals()
            }
        } else if let session = tracker.paused {
            let since = sinceText(session.pausedAt)
            Section {
                VStack(alignment: .leading, spacing: Studio.Space.xs) {
                    WorkLines(work: session.work)
                    HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
                        Text(DurationText.short(session.workedSeconds))
                            .font(.system(size: heroSize, weight: .light).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("worked before").font(.subheadline)
                    }
                    .foregroundStyle(Studio.textSecondary)
                    .padding(.top, Studio.Space.s)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(DurationText.spoken(session.workedSeconds)) worked before")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "pause.fill").font(.caption2).accessibilityHidden(true)
                        Text("Paused since \(since)")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Studio.textSecondary)
                }
                .padding(.vertical, Studio.Space.xs)
                // No away state on iPhone: there is no idle signal (spec §4.3).
                Button { Task { await tracker.resume() } } label: { CommandLabel("Resume", "play") }
                    .disabled(!tracker.canAct)
                // Stop forgets the paused timer; Kimai has nothing to stop.
                Button { Task { await tracker.stop() } } label: { CommandLabel("Stop", "stop") }
                    .disabled(tracker.isBusy)
                noteButton(session.work.note)
            } footer: {
                VStack(alignment: .leading, spacing: Studio.Space.s) {
                    Totals()
                    Text("Kimai has no pause: the entry ended at \(since). Resume starts a new one with the same customer, project, activity and note.")
                }
                .foregroundStyle(Studio.textSecondary)
            }
        } else if tracker.connectionState != .connecting {
            // At launch nothing is known yet: no "Not running" and no 0:00 rather than a guess.
            Section {
                Text("Not running").foregroundStyle(Studio.textPrimary)
            } footer: {
                Totals()
            }
        }
    }

    private func noteButton(_ note: String?) -> some View {
        Button { open(.note) } label: { CommandLabel((note ?? "").isEmpty ? "Add Note…" : "Edit Note…", "pencil") }
            .disabled(tracker.isBusy || (tracker.active != nil && !tracker.canAct))
    }
}

/// A command row, read like a Mac menu item: the title in primary ink, the
/// symbol in the tint. (Tomato text on every row would read as destructive.)
private struct CommandLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let systemImage: String

    init(_ title: String, _ systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(Studio.textPrimary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint)
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// "Activity · Project", then the customer (with its colour) and the note.
struct WorkLines: View {
    let work: Work
    var titleFont = Studio.Typography.heading

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(work.activityName) · \(work.projectName)")
                .font(titleFont)
                .foregroundStyle(Studio.textPrimary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Dot(hex: work.customerColor)
                Text([work.customerName, work.note ?? ""].filter { !$0.isEmpty }.joined(separator: " — "))
            }
            .font(.subheadline)
            .foregroundStyle(Studio.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Today 3:05 · This week 12:40", mine, refreshed every minute.
private struct Totals: View {
    @Environment(PhoneTracker.self) private var tracker

    var body: some View {
        TimelineView(.everyMinute) { context in
            let today = tracker.todaySeconds(at: context.date)
            let week = tracker.weekSeconds(at: context.date)
            Text("Today \(DurationText.short(today)) · This week \(DurationText.short(week))")
                .monospacedDigit()
                .foregroundStyle(Studio.textSecondary)
                .accessibilityLabel("Today \(DurationText.spoken(today)). This week \(DurationText.spoken(week)).")
        }
    }
}

/// "13:02" today, "Fri, 9 Oct, 17:30" for another day, as on the Mac.
func sinceText(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
}

// MARK: - Recent

/// One recent combination: a tap starts it again (Kimai stops whatever runs).
private struct RecentRow: View {
    @Environment(PhoneTracker.self) private var tracker
    let entry: KimaiTimesheet
    /// Opens New Timer with this entry, to change it before starting.
    let change: () -> Void

    var body: some View {
        let work = tracker.work(entry)
        let verb = tracker.isRunning ? "Switch To" : "Start"
        Button(action: start) {
            HStack(spacing: Studio.Space.m) {
                WorkLines(work: work, titleFont: Studio.Typography.body)
                Spacer(minLength: Studio.Space.s)
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(Studio.textSecondary)
                    .accessibilityHidden(true)
            }
            .opacity(tracker.canAct ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .disabled(!tracker.canAct)
        .contextMenu {
            Button(verb, systemImage: "play", action: start)
            Button("Change and Start…", systemImage: "slider.horizontal.3", action: change)
        }
        .accessibilityHint(tracker.isRunning ? "Switches the timer to this entry" : "Starts a timer for this entry")
        .accessibilityAction(named: "Change and Start", change)
    }

    private func start() { Task { await tracker.startAgain(entry) } }
}
