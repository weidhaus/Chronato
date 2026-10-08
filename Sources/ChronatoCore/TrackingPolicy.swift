import Foundation

/// The tracker's timing decisions, as pure functions so they can be tested
/// without a clock, a Mac that sleeps, or a Kimai server. The menu-bar app
/// feeds them the running entry, the last input time and the idle setting.
public enum TrackingPolicy {
    /// Shortest entry Chronato leaves behind when it ends one after the fact,
    /// so a back-dated end never lands on or before the begin.
    public static let minimumEntry: TimeInterval = 60
    /// No timer runs longer than this (same rule as `AgentSessions.maxDuration`).
    public static let maximumEntry: TimeInterval = 24 * 60 * 60
    /// "Count it" back-dates this much away time without asking; more needs a confirmation.
    public static let countAwayWithoutAsking: TimeInterval = 4 * 60 * 60

    /// Idle auto-pause: when to end the running entry, or nil to keep it running.
    /// Also decides on wake from sleep, with the last input before the sleep and
    /// `now` = the wake time.
    ///
    /// Only input on this Mac *during* the entry is evidence: a timer started
    /// elsewhere (Kimai web, phone, another Mac) while this Mac had no input since
    /// keeps running (the 24 h cap still ends a forgotten one). The minute of slack
    /// absorbs a server clock slightly ahead of the Mac's.
    public static func idlePauseEnd(begin: Date, lastInput: Date, now: Date, idleMinutes: Int) -> Date? {
        guard idleMinutes > 0, lastInput.addingTimeInterval(minimumEntry) >= begin else { return nil }
        guard now.timeIntervalSince(lastInput) >= TimeInterval(idleMinutes * 60) else { return nil }
        return max(lastInput, begin.addingTimeInterval(minimumEntry))
    }

    /// 24 h cap: when to end an entry that has run for a day, or nil. Ends at the
    /// last input (the best guess for when work stopped), within [begin + 1 min, begin + 24 h].
    public static func capEnd(begin: Date, lastInput: Date, now: Date) -> Date? {
        guard now.timeIntervalSince(begin) >= maximumEntry else { return nil }
        return min(max(lastInput, begin.addingTimeInterval(minimumEntry)), begin.addingTimeInterval(maximumEntry))
    }

    /// The automatic end of a running entry, or nil to keep it running: the 24 h
    /// cap first (`capped`: stop for good), else the idle pause. Every caller
    /// (idle tick, wake, launch after a quit) passes the last input it trusts,
    /// e.g. the one before a sleep.
    public static func autoStop(begin: Date, lastInput: Date, now: Date, idleMinutes: Int) -> (end: Date, capped: Bool)? {
        if let end = capEnd(begin: begin, lastInput: lastInput, now: now) { return (end, true) }
        if let end = idlePauseEnd(begin: begin, lastInput: lastInput, now: now, idleMinutes: idleMinutes) { return (end, false) }
        return nil
    }

    /// "Welcome back": the session was paused automatically (idle/sleep), the
    /// notice has not been raised for this pause yet, and there was input after
    /// the pause. Comparing input times rather than "idle < a few seconds" keeps
    /// it reliable with a 15 s poll; the 1 s margin absorbs clock jitter between polls.
    public static func shouldRaiseAwayNotice(autoPaused: Bool, alreadyRaised: Bool, pausedAt: Date, lastInput: Date) -> Bool {
        autoPaused && !alreadyRaised && lastInput > pausedAt.addingTimeInterval(1)
    }

    public enum CountAway: Sendable, Equatable {
        case allowed
        /// Over `countAwayWithoutAsking`: only after the user confirmed the span.
        case needsConfirmation
        /// A day or more: the back-dated entry would hit the 24 h cap at once.
        case tooLong
    }

    /// Whether "Count it" may start an entry back-dated to `since`.
    public static func countAway(since: Date, now: Date) -> CountAway {
        let away = now.timeIntervalSince(since)
        if away >= maximumEntry { return .tooLong }
        return away > countAwayWithoutAsking ? .needsConfirmation : .allowed
    }

    /// AI-agent work rather than the human's: booked as another Kimai user (the
    /// AI booking user), or carrying an allow-listed agent's `ai-<name>` tag.
    /// Another "ai-…" tag on the human's own entry ("ai-workshop") is an ordinary tag.
    /// `agentTags` nil: no allowlist at hand, every "ai-…" tag counts.
    public static func isAI(_ entry: KimaiTimesheet, meId: Int?, agentTags: Set<String>?) -> Bool {
        if let user = entry.userId, let meId, user != meId { return true }
        guard let agentTags else { return entry.aiAgentTag != nil }
        return entry.tags.contains(where: agentTags.contains)
    }

    /// The "start again" list from the user's latest (human) entries: distinct
    /// (project, activity, trimmed note), newest first. Only finished entries whose
    /// project and activity are in the visible catalog (Kimai refuses the others),
    /// and never the combination that is running now.
    public static func recentCombinations(_ entries: [KimaiTimesheet], running: KimaiTimesheet?,
                                          projectIds: Set<Int>, activityIds: Set<Int>, limit: Int = 10) -> [KimaiTimesheet] {
        struct Key: Hashable {
            let project: Int
            let activity: Int
            let note: String
            init(_ entry: KimaiTimesheet) {
                project = entry.projectId
                activity = entry.activityId
                note = (entry.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var seen = Set(running.map { [Key($0)] } ?? [])
        return Array(entries
            .filter { $0.end != nil && projectIds.contains($0.projectId) && activityIds.contains($0.activityId) }
            .sorted { $0.begin > $1.begin }
            .filter { seen.insert(Key($0)).inserted }
            .prefix(limit))
    }
}
