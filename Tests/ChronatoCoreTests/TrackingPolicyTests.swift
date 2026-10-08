import Foundation
import Testing
@testable import ChronatoCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

@Test func idlePause() {
    let begin = ago(minutes: 120)
    // Off, or not idle long enough: keep running.
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: ago(minutes: 30), now: now, idleMinutes: 0) == nil)
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: ago(minutes: 9.9), now: now, idleMinutes: 10) == nil)
    // Exactly at the threshold: end at the last input.
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: ago(minutes: 10), now: now, idleMinutes: 10) == ago(minutes: 10))
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: ago(minutes: 45), now: now, idleMinutes: 10) == ago(minutes: 45))
}

@Test func idlePauseOfEntryYoungerThanTheIdleGap() {
    // Started elsewhere (browser, phone, another Mac) while this Mac idled: no evidence here, keep running.
    let begin = ago(minutes: 10)
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: ago(minutes: 30), now: now, idleMinutes: 10) == nil)
    #expect(TrackingPolicy.idlePauseEnd(begin: ago(minutes: 2), lastInput: ago(minutes: 30), now: now, idleMinutes: 10) == nil)
    // ... also hours later, while this Mac still has had no input since.
    #expect(TrackingPolicy.idlePauseEnd(begin: ago(minutes: 300), lastInput: ago(minutes: 600), now: now, idleMinutes: 10) == nil)
    // Input 30 s into the entry: still at least one minute.
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: begin.addingTimeInterval(30), now: now.addingTimeInterval(60), idleMinutes: 10) == begin.addingTimeInterval(60))
    // A server clock a few seconds ahead (begin just after the click) still counts as started here.
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: begin.addingTimeInterval(-20), now: now.addingTimeInterval(60), idleMinutes: 10) == begin.addingTimeInterval(60))
}

@Test func autoStopAfterLongSleepOrQuit() {
    // Friday 16:00 start, last input 17:00, lid closed; Monday 09:00 wake (64 h later).
    let begin = ago(minutes: 65 * 60), left = ago(minutes: 64 * 60)
    for idle in [10, 0] { // idle pause on or off: the cap ends it when the user left, for good
        let stop = TrackingPolicy.autoStop(begin: begin, lastInput: left, now: now, idleMinutes: idle)
        #expect(stop?.end == left && stop?.capped == true)
    }
    // The input time read after the wake (HID idle stood still) would book a full day.
    #expect(TrackingPolicy.capEnd(begin: begin, lastInput: now, now: now) == begin.addingTimeInterval(24 * 3600))
    // Quit or shut down Thursday 18:00 with a timer from 10:00; next launch Friday 09:00: a pause at 18:00.
    let thursday = ago(minutes: 23 * 60), evening = ago(minutes: 15 * 60)
    let relaunch = TrackingPolicy.autoStop(begin: thursday, lastInput: evening, now: now, idleMinutes: 10)
    #expect(relaunch?.end == evening && relaunch?.capped == false)
    // Back after less than the idle limit: keep running.
    #expect(TrackingPolicy.autoStop(begin: thursday, lastInput: ago(minutes: 5), now: now, idleMinutes: 10) == nil)
}

@Test func countingTimeAway() {
    #expect(TrackingPolicy.countAway(since: ago(minutes: 25), now: now) == .allowed)
    #expect(TrackingPolicy.countAway(since: ago(minutes: 240), now: now) == .allowed)
    #expect(TrackingPolicy.countAway(since: ago(minutes: 241), now: now) == .needsConfirmation)
    #expect(TrackingPolicy.countAway(since: ago(minutes: 24 * 60 - 1), now: now) == .needsConfirmation)
    #expect(TrackingPolicy.countAway(since: ago(minutes: 24 * 60), now: now) == .tooLong)
}

@Test func aiWorkIsAnotherUserOrAnAgentTag() {
    func entry(user: Int?, tags: [String]) -> KimaiTimesheet {
        KimaiTimesheet(id: 1, begin: ago(minutes: 60), end: now, tags: tags, userId: user, projectId: 12, activityId: 3)
    }
    let agents: Set<String> = ["ai-claude-code"]
    #expect(TrackingPolicy.isAI(entry(user: 2, tags: []), meId: 1, agentTags: agents)) // the AI booking user
    #expect(TrackingPolicy.isAI(entry(user: 1, tags: ["billing", "ai-claude-code"]), meId: 1, agentTags: agents)) // booked as me
    #expect(!TrackingPolicy.isAI(entry(user: 1, tags: ["ai-workshop"]), meId: 1, agentTags: agents)) // an ordinary tag
    #expect(!TrackingPolicy.isAI(entry(user: 1, tags: []), meId: 1, agentTags: agents))
    #expect(TrackingPolicy.isAI(entry(user: 1, tags: ["ai-workshop"]), meId: 1, agentTags: nil)) // no allowlist: any ai- tag
}

@Test func wakePause() {
    // On wake the idle rule runs with the last input before the sleep.
    let begin = ago(minutes: 180), left = ago(minutes: 60)
    // Away (mostly asleep) for less than the threshold, or idle pausing off: keep running.
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: left, now: left.addingTimeInterval(9 * 60), idleMinutes: 10) == nil)
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: left, now: now, idleMinutes: 0) == nil)
    // Away exactly the threshold: end when the user left, not when the Mac fell asleep.
    #expect(TrackingPolicy.idlePauseEnd(begin: begin, lastInput: left, now: left.addingTimeInterval(10 * 60), idleMinutes: 10) == left)
    // Lid closed seconds after starting: keep a one-minute entry.
    let fresh = left.addingTimeInterval(-20)
    #expect(TrackingPolicy.idlePauseEnd(begin: fresh, lastInput: left, now: now, idleMinutes: 10) == fresh.addingTimeInterval(60))
}

@Test func dayCap() {
    let day: TimeInterval = 24 * 3600
    let begin = now.addingTimeInterval(-day)
    #expect(TrackingPolicy.capEnd(begin: begin.addingTimeInterval(1), lastInput: now, now: now) == nil)
    // Still in use after 24 h: end exactly at 24 h.
    #expect(TrackingPolicy.capEnd(begin: begin, lastInput: now, now: now) == begin.addingTimeInterval(day))
    // Left running overnight: end at the last input.
    #expect(TrackingPolicy.capEnd(begin: begin, lastInput: ago(minutes: 600), now: now) == ago(minutes: 600))
    // No input since before it started (or right after): one minute.
    #expect(TrackingPolicy.capEnd(begin: begin, lastInput: begin.addingTimeInterval(-3600), now: now) == begin.addingTimeInterval(60))
}

@Test func awayNotice() {
    let pausedAt = ago(minutes: 20)
    #expect(TrackingPolicy.shouldRaiseAwayNotice(autoPaused: true, alreadyRaised: false, pausedAt: pausedAt, lastInput: now))
    #expect(!TrackingPolicy.shouldRaiseAwayNotice(autoPaused: false, alreadyRaised: false, pausedAt: pausedAt, lastInput: now))
    #expect(!TrackingPolicy.shouldRaiseAwayNotice(autoPaused: true, alreadyRaised: true, pausedAt: pausedAt, lastInput: now))
    // Still away: the last input is the one the pause was based on (± poll jitter).
    #expect(!TrackingPolicy.shouldRaiseAwayNotice(autoPaused: true, alreadyRaised: false, pausedAt: pausedAt, lastInput: pausedAt.addingTimeInterval(0.4)))
}

@Test func recentCombinationsAreDistinctNewestFirst() {
    func entry(_ id: Int, _ minutesAgo: Double, project: Int = 12, activity: Int = 3, note: String? = nil, running: Bool = false) -> KimaiTimesheet {
        KimaiTimesheet(id: id, begin: ago(minutes: minutesAgo), end: running ? nil : ago(minutes: minutesAgo - 5), description: note,
                       projectId: project, activityId: activity)
    }
    // The user's own latest entries, as GET /timesheets lists them (Kimai's /recent would keep one per project + activity).
    let entries = [
        entry(1, 300, note: "Lead routing"),
        entry(2, 10, note: " Lead routing "),
        entry(3, 50, activity: 5),
        entry(4, 40, activity: 5, note: ""),
        entry(5, 200, note: "Call tagging"), // same project + activity, another note: its own row
        entry(6, 100, project: 9, activity: 1),
        entry(7, 20, project: 98, activity: 1), // archived project: Kimai would refuse it
        entry(8, 30, project: 9, activity: 97), // hidden activity
    ]
    let visible = (projectIds: Set([12, 9]), activityIds: Set([3, 5, 1]))
    func recent(running: KimaiTimesheet? = nil, limit: Int = 10) -> [Int] {
        TrackingPolicy.recentCombinations(entries + [running].compactMap { $0 }, running: running,
                                          projectIds: visible.projectIds, activityIds: visible.activityIds, limit: limit).map(\.id)
    }
    #expect(recent() == [2, 4, 6, 5])
    #expect(recent(limit: 2) == [2, 4])
    // Never the combination that runs now, nor the running entry itself.
    #expect(recent(running: entry(9, 1, activity: 5, running: true)) == [2, 6, 5])
    #expect(recent(running: entry(10, 1, note: "Lead routing", running: true)) == [4, 6, 5])
}
