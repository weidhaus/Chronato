import Foundation
import Testing
@testable import ChronatoCore

private func berlin(firstWeekday: Int = 2) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    c.firstWeekday = firstWeekday
    return c
}

/// "2026-10-26T10:00:00+0100"
private func at(_ s: String) -> Date { KimaiDate.parse(s)! }

private func entry(
    _ id: Int, _ begin: String, minutes: Int?, user: Int = 1, customer: Int = 10, project: Int = 12, activity: Int = 3,
    tags: [String] = [], billable: Bool = true, rate: Double = 0, names: Bool = true
) -> KimaiTimesheet {
    let start = at(begin)
    return KimaiTimesheet(
        id: id, begin: start, end: minutes.map { start.addingTimeInterval(Double($0) * 60) }, duration: minutes.map { $0 * 60 },
        tags: tags, billable: billable, rate: rate, userId: user, projectId: project, projectName: names ? "P\(project)" : nil,
        customerId: customer, customerName: names ? "C\(customer)" : nil, activityId: activity, activityName: names ? "A\(activity)" : nil)
}

@Test func intervalsHonourWeekStartAndDST() {
    // Sunday 11 Oct 2026, noon in Berlin.
    let sunday = at("2026-10-11T12:00:00+0200")
    let monWeek = Report.interval(for: .week, containing: sunday, calendar: berlin(firstWeekday: 2))
    #expect(monWeek.start == at("2026-10-05T00:00:00+0200") && monWeek.end == at("2026-10-12T00:00:00+0200"))
    let sunWeek = Report.interval(for: .week, containing: sunday, calendar: berlin(firstWeekday: 1))
    #expect(sunWeek.start == at("2026-10-11T00:00:00+0200") && sunWeek.end == at("2026-10-18T00:00:00+0200"))

    // Clocks go back on Sunday 25 Oct 2026: that week has 169 hours, the day 25.
    let dstWeek = Report.interval(for: .week, containing: at("2026-10-22T09:00:00+0200"), calendar: berlin())
    #expect(dstWeek.start == at("2026-10-19T00:00:00+0200") && dstWeek.end == at("2026-10-26T00:00:00+0100"))
    #expect(dstWeek.duration == 169 * 3600)
    #expect(Report.interval(for: .day, containing: at("2026-10-25T15:00:00+0100"), calendar: berlin()).duration == 25 * 3600)

    let month = Report.interval(for: .month, containing: sunday, calendar: berlin())
    #expect(month.start == at("2026-10-01T00:00:00+0200") && month.end == at("2026-11-01T00:00:00+0100"))
    let year = Report.interval(for: .year, containing: sunday, calendar: berlin())
    #expect(year.start == at("2026-01-01T00:00:00+0100") && year.end == at("2027-01-01T00:00:00+0100"))
    // Midnight belongs to the day it starts.
    #expect(Report.interval(for: .day, containing: at("2026-10-08T00:00:00+0200"), calendar: berlin()).start == at("2026-10-08T00:00:00+0200"))
}

@Test func scopesSplitMeFromAI() {
    let entries = [
        entry(1, "2026-10-05T09:00:00+0200", minutes: 60, rate: 100),
        entry(2, "2026-10-05T11:00:00+0200", minutes: 30, user: 2, tags: ["ai-claude-code"], billable: false),
        // Booked as me but tagged: still AI time.
        entry(3, "2026-10-06T09:00:00+0200", minutes: 15, tags: ["ai-codex"]),
        // Another user without a tag: AI, keyed by user.
        entry(4, "2026-10-06T10:00:00+0200", minutes: 45, user: 3),
    ]
    let interval = Report.interval(for: .week, containing: at("2026-10-07T12:00:00+0200"), calendar: berlin())
    func build(_ scope: ReportScope) -> Report {
        Report.build(entries: entries, interval: interval, period: .week, scope: scope, meId: 1, calendar: berlin())
    }
    let me = build(.me), ai = build(.ai), all = build(.all)
    #expect(me.totalSeconds == 3600 && me.totalRevenue == 100 && me.agents.isEmpty)
    #expect(ai.totalSeconds == 90 * 60 && ai.billableSeconds == 60 * 60)
    #expect(ai.agents == ["ai-claude-code": 1800, "ai-codex": 900, "ai-user-3": 2700])
    #expect(all.totalSeconds == 150 * 60 && all.agents == ai.agents)
    #expect(me.entryCount == 1 && ai.entryCount == 3 && all.entryCount == 4)
    #expect(all.scope == .all && all.period == .week && all.interval == interval)
}

@Test func onlyAllowListedAgentTagsMakeMyEntriesAI() {
    let entries = [
        entry(1, "2026-10-05T09:00:00+0200", minutes: 180, tags: ["ai-workshop"]), // my client workshop on AI
        entry(2, "2026-10-05T14:00:00+0200", minutes: 30, tags: ["ai-claude-code"]), // an agent booking as me
        entry(3, "2026-10-05T15:00:00+0200", minutes: 45, user: 2), // the AI booking user
    ]
    let interval = Report.interval(for: .week, containing: at("2026-10-07T12:00:00+0200"), calendar: berlin())
    func build(_ scope: ReportScope) -> Report {
        Report.build(entries: entries, interval: interval, period: .week, scope: scope, meId: 1, agentTags: ["ai-claude-code"], calendar: berlin())
    }
    #expect(build(.me).totalSeconds == 180 * 60)
    #expect(build(.ai).agents == ["ai-claude-code": 1800, "ai-user-2": 2700])
}

@Test func linesNestAndSortBySecondsThenName() {
    let entries = [
        entry(1, "2026-10-05T09:00:00+0200", minutes: 60, customer: 7, project: 9, activity: 1, rate: 50),
        entry(2, "2026-10-05T10:00:00+0200", minutes: 60, customer: 10, project: 12, activity: 3, rate: 70),
        entry(3, "2026-10-05T11:00:00+0200", minutes: 30, customer: 10, project: 12, activity: 5, rate: 30),
        entry(4, "2026-10-05T12:00:00+0200", minutes: 90, customer: 11, project: 11, activity: 1, billable: false),
        entry(5, "2026-10-05T14:00:00+0200", minutes: 20, customer: 10, project: 14, activity: 3),
    ]
    let interval = Report.interval(for: .day, containing: at("2026-10-05T12:00:00+0200"), calendar: berlin())
    let r = Report.build(entries: entries, interval: interval, period: .day, scope: .me, meId: 1, calendar: berlin())
    // C10 (110 min) > C11 (90) > C7 (60).
    #expect(r.customers.map(\.id) == [10, 11, 7])
    #expect(r.customers.map(\.seconds) == [110 * 60, 90 * 60, 60 * 60])
    #expect(r.customers[0].revenue == 100 && r.totalRevenue == 150)
    #expect(r.billableSeconds == 170 * 60)
    let northwind = r.customers[0]
    #expect(northwind.children.map(\.id) == [12, 14])
    #expect(northwind.children[0].children.map(\.name) == ["A3", "A5"])
    #expect(northwind.children[0].children[1].children.isEmpty)

    // Equal seconds: by name.
    let tied = [
        entry(1, "2026-10-05T09:00:00+0200", minutes: 60, customer: 1),
        entry(2, "2026-10-05T10:00:00+0200", minutes: 60, customer: 2),
    ]
    let named = Report.build(entries: tied, interval: interval, period: .day, scope: .me, meId: 1, calendar: berlin())
    #expect(named.customers.map(\.name) == ["C1", "C2"])
}

@Test func fallbackNamesForFlatEntries() {
    let flat = [entry(1, "2026-10-05T09:00:00+0200", minutes: 60, customer: 12, project: 13, activity: 18, names: false)]
    let interval = Report.interval(for: .day, containing: at("2026-10-05T12:00:00+0200"), calendar: berlin())
    let r = Report.build(entries: flat, interval: interval, period: .day, scope: .all, meId: 1, calendar: berlin())
    #expect(r.customers[0].name == "Customer #12")
    #expect(r.customers[0].children[0].name == "Project #13")
    #expect(r.customers[0].children[0].children[0].name == "Activity #18")
}

@Test func runningEntryCountsUpToNow() {
    let running = entry(1, "2026-10-08T09:00:00+0200", minutes: nil)
    let now = at("2026-10-08T11:30:00+0200")
    let interval = Report.interval(for: .day, containing: now, calendar: berlin())
    let r = Report.build(entries: [running], interval: interval, period: .day, scope: .me, meId: 1, calendar: berlin(), now: now)
    #expect(r.totalSeconds == 9000 && r.buckets.map(\.seconds) == [9000])
    #expect(r.buckets[0].start == at("2026-10-08T09:00:00+0200"))
}

@Test func bucketsFollowPeriodGranularity() {
    let entries = [
        // DST week: the bucket starts at local midnight on either side of the change.
        entry(1, "2026-10-24T22:30:00+0200", minutes: 120, customer: 7),   // runs past midnight: stays on the 24th
        entry(2, "2026-10-26T10:00:00+0100", minutes: 60, customer: 10),
        entry(3, "2026-10-26T14:00:00+0100", minutes: 30, customer: 7),
        entry(4, "2026-10-26T15:00:00+0100", minutes: 60, customer: 10),
        entry(5, "2026-10-27T09:00:00+0100", minutes: 15, customer: 10),
    ]
    let week = Report.interval(for: .week, containing: at("2026-10-26T12:00:00+0100"), calendar: berlin(firstWeekday: 1))
    let r = Report.build(entries: entries, interval: week, period: .week, scope: .me, meId: 1, calendar: berlin(firstWeekday: 1))
    // Sunday-start week: 25 Oct – 1 Nov; entry 1 (Saturday 24th) is outside.
    #expect(r.totalSeconds == 165 * 60)
    #expect(r.buckets.map(\.start) == [at("2026-10-26T00:00:00+0100"), at("2026-10-26T00:00:00+0100"), at("2026-10-27T00:00:00+0100")])
    // Same day: larger customer first.
    #expect(r.buckets.map(\.customerId) == [10, 7, 10])
    #expect(r.buckets.map(\.seconds) == [7200, 1800, 900])
    #expect(r.buckets[0].customerName == "C10")

    let monWeek = Report.interval(for: .week, containing: at("2026-10-24T12:00:00+0200"), calendar: berlin())
    let saturday = Report.build(entries: entries, interval: monWeek, period: .week, scope: .me, meId: 1, calendar: berlin())
    #expect(saturday.buckets.map(\.start) == [at("2026-10-24T00:00:00+0200")] && saturday.totalSeconds == 7200)

    let yearEntries = [
        entry(1, "2026-01-15T09:00:00+0100", minutes: 60),
        entry(2, "2026-01-31T23:30:00+0100", minutes: 60),
        entry(3, "2026-03-29T10:00:00+0200", minutes: 30),
        entry(4, "2025-12-31T23:00:00+0100", minutes: 60),
    ]
    let year = Report.interval(for: .year, containing: at("2026-06-01T12:00:00+0200"), calendar: berlin())
    let y = Report.build(entries: yearEntries, interval: year, period: .year, scope: .me, meId: 1, calendar: berlin())
    #expect(y.buckets.map(\.start) == [at("2026-01-01T00:00:00+0100"), at("2026-03-01T00:00:00+0100")])
    #expect(y.buckets.map(\.seconds) == [7200, 1800])
}

@Test func summaryListsLinesAndAgents() {
    let entries = [
        entry(1, "2026-10-05T09:00:00+0200", minutes: 90, rate: 150),
        entry(2, "2026-10-05T11:00:00+0200", minutes: 30, user: 2, activity: 5, tags: ["ai-claude-code"]),
    ]
    let interval = Report.interval(for: .day, containing: at("2026-10-05T12:00:00+0200"), calendar: berlin())
    let report = Report.build(entries: entries, interval: interval, period: .day, scope: .all, meId: 1, calendar: berlin())
    let text = report.summary(title: "Report", currency: "EUR", locale: Locale(identifier: "en_US"))
    let lines = text.components(separatedBy: "\n")
    #expect(lines[0] == "Report")
    #expect(lines[1] == "Total 2.00 h · billable 100 % · revenue 150.00 EUR")
    #expect(lines.contains { $0.hasPrefix("C10 ") && $0.hasSuffix("2.00 h  100 %       150.00") })
    #expect(lines.contains { $0.hasPrefix("    A3 ") && $0.contains("1.50 h   75 %") })
    #expect(lines.suffix(2).first == "AI agents")
    #expect(lines.last?.hasPrefix("  ai-claude-code ") == true)
    // The decimal mark of the user's locale, as in the Reports window.
    let german = report.summary(title: "Report", currency: "EUR", locale: Locale(identifier: "de_DE")).components(separatedBy: "\n")
    #expect(german[1] == "Total 2,00 h · billable 100 % · revenue 150,00 EUR")
}
