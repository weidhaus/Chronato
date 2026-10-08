import Foundation

/// The App Group the app, its widgets and its intents share
/// (group.com.weidhaus.chronato, see iOS/Config/*.entitlements).
enum AppGroup {
    static let id = "group.com.weidhaus.chronato"

    /// The shared defaults suite (the paused session lives here). A build
    /// without the entitlement still gets a working, unshared suite.
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    /// snapshot.json in the group container; Caches when the group is missing.
    static var snapshotURL: URL {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("snapshot.json")
    }

    /// What the app last wrote, or nil before its first launch.
    static func readSnapshot() -> SharedSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(SharedSnapshot.self, from: data)
    }

    static func write(_ snapshot: SharedSnapshot) {
        try? JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
    }
}

/// What a timer is for: Customer → Project → Activity with its note and tags,
/// plus display names (Kimai sometimes answers with ids only; the catalog fills them in).
struct Work: Codable, Hashable, Sendable {
    var projectId: Int
    var activityId: Int
    var note: String?
    var tags: [String] = []
    var customerName: String
    var projectName: String
    var activityName: String
    /// The customer's Kimai colour ("#RRGGBB"), if it has one.
    var customerColor: String?
}

/// Kimai has no paused state: Pause stops the entry and keeps this; Resume
/// starts a new entry from it. Persisted in the App Group, so it survives a
/// relaunch and widgets and intents see it.
struct PausedSession: Codable, Equatable, Sendable {
    var work: Work
    /// When the paused entry ended.
    var pausedAt: Date
    /// Worked seconds of the entry that was paused (display only).
    var workedSeconds: Int
}

/// The compact state widgets, the Live Activity and intents read from the App
/// Group. PhoneTracker writes it after every change.
struct SharedSnapshot: Codable, Equatable, Sendable {
    struct Running: Codable, Equatable, Sendable {
        var entryId: Int
        var begin: Date
        var work: Work
    }

    var isConnected: Bool
    var running: Running?
    var paused: PausedSession?
    /// Mine today, finished entries only. The running entry is left out so a
    /// reader can let it tick from `running.begin` (see `todaySeconds(at:)`).
    var todaySeconds: Int
    /// The most recent combination, for "start again".
    var lastWork: Work?
    var updatedAt: Date

    /// Mine today at `now`, the running entry included. Finished time from an
    /// earlier day than `updatedAt` no longer counts.
    func todaySeconds(at now: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        let finished = updatedAt >= start ? todaySeconds : 0
        guard let running else { return finished }
        return finished + max(0, Int(now.timeIntervalSince(max(running.begin, start))))
    }
}
