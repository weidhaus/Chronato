import AppIntents
import ChronatoCore
import Foundation

// App Intents for Shortcuts, Siri, the Action button, widget buttons and the
// Live Activity. Every one acts on PhoneTracker.shared, so all Kimai calls
// stay in the engine. The ones that change the timer are LiveActivityIntents:
// the system runs them in the app's process (launched in the background if
// needed), where the tracker, the UI and the Live Activity live.

// MARK: Entity

/// A Kimai activity in a project: what a timer tracks (Customer → Project → Activity).
struct ActivityEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kimai Activity"
    static let defaultQuery = ActivityQuery()

    /// "project-activity": a global activity exists once per project that allows it.
    let id: String
    let projectId: Int
    let activityId: Int
    let customerName: String
    let projectName: String
    let activityName: String

    init(_ work: Work) {
        id = "\(work.projectId)-\(work.activityId)"
        projectId = work.projectId
        activityId = work.activityId
        customerName = work.customerName
        projectName = work.projectName
        activityName = work.activityName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(activityName)", subtitle: "\(customerName) · \(projectName)")
    }
}

/// Over the tracker's catalog (loaded from Kimai, refreshed every 10 minutes).
/// Suggestions are the recent combinations, as in the app; search finds the rest.
struct ActivityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ActivityEntity] {
        let all = await Self.catalog()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor func suggestedEntities() async throws -> [ActivityEntity] {
        let tracker = PhoneTracker.shared
        await tracker.bootstrap()
        let recent = Self.unique(tracker.recent.map { ActivityEntity(tracker.work($0)) })
        return recent.isEmpty ? await Self.catalog() : recent
    }

    /// Every word must appear in "customer project activity".
    @MainActor func entities(matching string: String) async throws -> [ActivityEntity] {
        let words = string.split(separator: " ")
        return await Self.catalog().filter { entity in
            let text = "\(entity.customerName) \(entity.projectName) \(entity.activityName)"
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    /// Every startable combination, by customer, project and activity.
    @MainActor private static func catalog() async -> [ActivityEntity] {
        let tracker = PhoneTracker.shared
        await tracker.bootstrap()
        let projects = tracker.projects.sorted {
            let a = tracker.customer($0.customer)?.name ?? "", b = tracker.customer($1.customer)?.name ?? ""
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : a.localizedStandardCompare(b) == .orderedAscending
        }
        return projects.flatMap { project in
            tracker.activities(forProject: project.id).map { activity in
                ActivityEntity(Work(projectId: project.id, activityId: activity.id,
                                    customerName: tracker.customer(project.customer)?.name ?? "",
                                    projectName: project.name, activityName: activity.name))
            }
        }
    }

    private static func unique(_ entities: [ActivityEntity]) -> [ActivityEntity] {
        var seen = Set<String>()
        return entities.filter { seen.insert($0.id).inserted }
    }
}

// MARK: Intents

struct StartTrackingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Tracking"
    static var description: IntentDescription { "Starts a Kimai timer. The timer that runs stops first." }

    @Parameter(title: "Activity", requestValueDialog: "Which activity?")
    var activity: ActivityEntity

    @Parameter(title: "Note")
    var note: String?

    init() {}

    init(activity: ActivityEntity, note: String?) {
        self.activity = activity
        self.note = note
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Start tracking \(\.$activity)") { \.$note }
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let tracker = try await PhoneTracker.readyForIntent()
        await tracker.start(projectId: activity.projectId, activityId: activity.activityId, description: note)
        guard let running = tracker.active, running.projectId == activity.projectId, running.activityId == activity.activityId else {
            throw IntentFailure(tracker.lastError ?? "Kimai did not start the timer.")
        }
        SnapshotSync.flush()
        return .result(dialog: "Tracking \(activity.activityName) for \(activity.customerName).")
    }
}

struct StopTrackingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Tracking"
    static var description: IntentDescription { "Stops the running Kimai timer, or ends a paused one." }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let tracker = try await PhoneTracker.readyForIntent()
        guard let running = tracker.active else {
            guard tracker.paused != nil else { return .result(dialog: "No timer is running.") }
            await tracker.stop() // forgets the paused session; nothing to tell Kimai
            SnapshotSync.flush()
            return .result(dialog: "Ended the paused timer.")
        }
        let work = tracker.work(running)
        let seconds = running.seconds(now: .now)
        await tracker.stop()
        guard tracker.active == nil else { throw IntentFailure(tracker.lastError ?? "Kimai did not stop the timer.") }
        SnapshotSync.flush()
        return .result(dialog: "Stopped \(work.activityName) for \(work.customerName) after \(spokenDuration(seconds)).")
    }
}

struct PauseTrackingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Tracking"
    static var description: IntentDescription { "Stops the running Kimai timer and remembers it, to resume later." }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let tracker = try await PhoneTracker.readyForIntent()
        guard tracker.active != nil else {
            return .result(dialog: tracker.paused != nil ? "The timer is already paused." : "No timer is running.")
        }
        await tracker.pause()
        guard let paused = tracker.paused, tracker.active == nil else {
            throw IntentFailure(tracker.lastError ?? "Kimai did not stop the timer.")
        }
        SnapshotSync.flush()
        return .result(dialog: "Paused \(paused.work.activityName) after \(spokenDuration(paused.workedSeconds)).")
    }
}

struct ResumeTrackingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Tracking"
    static var description: IntentDescription { "Starts a new Kimai timer like the paused one." }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let tracker = try await PhoneTracker.readyForIntent()
        guard let paused = tracker.paused else {
            return .result(dialog: tracker.active != nil ? "The timer is already running." : "Nothing is paused.")
        }
        await tracker.resume()
        guard tracker.active != nil else { throw IntentFailure(tracker.lastError ?? "Kimai did not start the timer.") }
        SnapshotSync.flush()
        return .result(dialog: "Resumed \(paused.work.activityName) for \(paused.work.customerName).")
    }
}

/// What runs, from Kimai (also when started in the browser or on the Mac).
struct CurrentTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Current Timer"
    static var description: IntentDescription { "Tells what the Kimai timer is tracking and for how long." }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let tracker = try await PhoneTracker.readyForIntent()
        let text: String
        if let running = tracker.active {
            let work = tracker.work(running)
            text = "Tracking \(work.activityName) for \(work.customerName), \(spokenDuration(running.seconds(now: .now)))"
        } else if let paused = tracker.paused {
            text = "Paused: \(paused.work.activityName) for \(paused.work.customerName), \(spokenDuration(paused.workedSeconds)) before the break"
        } else {
            text = "No timer is running. Today: \(spokenDuration(tracker.todaySeconds()))"
        }
        return .result(value: text, dialog: "\(text)")
    }
}

// MARK: Shortcuts and Siri

#if !WIDGET_EXTENSION // App Shortcuts belong to the app, not its extensions
struct ChronatoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTrackingIntent(), phrases: [
            "Start tracking in \(.applicationName)",
            "Start \(\.$activity) in \(.applicationName)",
            "Track time with \(.applicationName)",
        ], shortTitle: "Start Tracking", systemImageName: "play.fill")
        AppShortcut(intent: StopTrackingIntent(), phrases: [
            "Stop my \(.applicationName) timer",
            "Stop tracking in \(.applicationName)",
        ], shortTitle: "Stop Tracking", systemImageName: "stop.fill")
        AppShortcut(intent: PauseTrackingIntent(), phrases: [
            "Pause my \(.applicationName) timer",
            "Pause tracking in \(.applicationName)",
        ], shortTitle: "Pause Tracking", systemImageName: "pause.fill")
        AppShortcut(intent: ResumeTrackingIntent(), phrases: [
            "Resume my \(.applicationName) timer",
            "Resume tracking in \(.applicationName)",
        ], shortTitle: "Resume Tracking", systemImageName: "playpause.fill")
        AppShortcut(intent: CurrentTimerIntent(), phrases: [
            "What am I tracking in \(.applicationName)",
            "Show my \(.applicationName) timer",
        ], shortTitle: "Current Timer", systemImageName: "stopwatch")
    }
}
#endif

// MARK: Support

/// A failure Shortcuts and Siri show as is.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

extension PhoneTracker {
    /// The shared tracker, loaded and up to date with Kimai: the timer may have
    /// changed in the browser or on the Mac since the app last looked.
    @MainActor static func readyForIntent() async throws -> PhoneTracker {
        let tracker = shared
        await tracker.bootstrap()
        guard tracker.connection != nil else {
            throw IntentFailure("Chronato isn't connected to Kimai yet. Open the app and sign in.")
        }
        await tracker.refresh()
        // Offline, "no timer is running" could be wrong and every change would fail.
        if case let .offline(message) = tracker.connectionState { throw IntentFailure(message) }
        return tracker
    }
}

/// "1 hr, 12 min", localized.
private func spokenDuration(_ seconds: Int) -> String {
    Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}
