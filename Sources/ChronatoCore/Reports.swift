import Foundation

// Report maths: pure functions over timesheets, no I/O. The Reports window
// fetches with KimaiClient.timesheets(user: "all", …) and calls `Report.build`.

public enum ReportPeriod: String, CaseIterable, Sendable, Identifiable {
    case day, week, month, year
    public var id: String { rawValue }

    /// The calendar unit one period spans (also the step for ‹ / › navigation).
    public var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// Chart granularity: hours of a day, days of a week or month, months of a year.
    public var bucketComponent: Calendar.Component {
        switch self {
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        }
    }
}

/// Whose hours a report shows. The instance has one human user; everything
/// booked by another user or tagged with an agent's `ai-<name>` is AI time.
public enum ReportScope: String, CaseIterable, Sendable, Identifiable {
    case me, ai, all
    public var id: String { rawValue }
}

public struct ReportBucket: Sendable, Hashable, Identifiable {
    /// Start of the day (week/month periods), hour (day period) or month (year period).
    public let start: Date
    public let customerId: Int
    public let customerName: String
    public let seconds: Int
    public var id: String { "\(start.timeIntervalSince1970)-\(customerId)" }
}

public struct ReportLine: Sendable, Hashable, Identifiable {
    /// Customer, project or activity id (depending on depth).
    public let id: Int
    public let name: String
    public let seconds: Int
    /// Sum of Kimai `rate` (money) for the line's entries.
    public let revenue: Double
    /// Customers contain projects, projects contain activities.
    public let children: [ReportLine]
}

public struct Report: Sendable, Hashable {
    public let interval: DateInterval
    public let period: ReportPeriod
    public let scope: ReportScope
    public let totalSeconds: Int
    public let totalRevenue: Double
    public let billableSeconds: Int
    /// Timesheets counted (after scope and interval filtering).
    public let entryCount: Int
    /// Customers, largest first.
    public let customers: [ReportLine]
    /// For the bar chart.
    public let buckets: [ReportBucket]
    /// AI agent tag (e.g. "ai-claude-code") → seconds. Empty for `.me`.
    public let agents: [String: Int]

    /// Calendar interval of `period` that contains `date`. Weeks start on
    /// `calendar.firstWeekday`; `end` is the start of the next period, so a
    /// DST week is 167 or 169 hours long.
    public static func interval(for period: ReportPeriod, containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: period.component, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// True when the entry counts as AI time for the given human user
    /// (`TrackingPolicy.isAI`, the rule the menu's totals use too).
    public static func isAI(_ entry: KimaiTimesheet, meId: Int, agentTags: Set<String>? = nil) -> Bool {
        TrackingPolicy.isAI(entry, meId: meId, agentTags: agentTags)
    }

    /// Aggregates `entries` (normally already limited to `interval` by the API;
    /// entries that did not start inside it are ignored) for `scope`.
    /// `agentTags`: the allow-listed agents' tags (nil: any "ai-…" tag is AI).
    /// Running entries count up to `now`. Each entry lands in the chart bucket
    /// of its begin, even when it runs past midnight.
    public static func build(entries: [KimaiTimesheet], interval: DateInterval, period: ReportPeriod, scope: ReportScope, meId: Int,
                             agentTags: Set<String>? = nil, calendar: Calendar, now: Date = .now) -> Report {
        let items: [Item] = entries
            .filter { entry in
                guard entry.begin >= interval.start, entry.begin < interval.end else { return false }
                switch scope {
                case .me: return !isAI(entry, meId: meId, agentTags: agentTags)
                case .ai: return isAI(entry, meId: meId, agentTags: agentTags)
                case .all: return true
                }
            }
            .map { ($0, $0.seconds(now: now)) }

        let customers = lines(items, depth: 0)
        let rank = Dictionary(uniqueKeysWithValues: customers.enumerated().map { ($1.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0.name) })
        // Within a bucket, largest customer first, so stacks keep the same order.
        let buckets = Dictionary(grouping: items) { item in
            BucketKey(start: calendar.dateInterval(of: period.bucketComponent, for: item.entry.begin)?.start ?? item.entry.begin,
                      customerId: item.entry.customerId ?? 0)
        }
        .map { key, group in
            ReportBucket(start: key.start, customerId: key.customerId, customerName: names[key.customerId] ?? "", seconds: total(group))
        }
        .sorted { ($0.start, rank[$0.customerId] ?? 0) < ($1.start, rank[$1.customerId] ?? 0) }

        let agents = Dictionary(grouping: items.filter { isAI($0.entry, meId: meId, agentTags: agentTags) }) {
            $0.entry.aiAgentTag ?? "ai-user-\($0.entry.userId ?? 0)"
        }
        .mapValues(total)

        return Report(
            interval: interval, period: period, scope: scope,
            totalSeconds: total(items),
            totalRevenue: items.reduce(0) { $0 + ($1.entry.rate ?? 0) },
            billableSeconds: total(items.filter { $0.entry.billable != false }),
            entryCount: items.count,
            customers: customers, buckets: buckets, agents: agents)
    }

    private typealias Item = (entry: KimaiTimesheet, seconds: Int)

    private struct BucketKey: Hashable {
        let start: Date
        let customerId: Int
    }

    private static func total(_ items: [Item]) -> Int { items.reduce(0) { $0 + $1.seconds } }

    /// Customers (depth 0) → projects (1) → activities (2), each level sorted.
    private static func lines(_ items: [Item], depth: Int) -> [ReportLine] {
        Dictionary(grouping: items) { item in
            switch depth {
            case 0: item.entry.customerId ?? 0
            case 1: item.entry.projectId
            default: item.entry.activityId
            }
        }
        .map { id, group in
            ReportLine(id: id, name: name(of: group, depth: depth, id: id), seconds: total(group),
                       revenue: group.reduce(0) { $0 + ($1.entry.rate ?? 0) },
                       children: depth < 2 ? lines(group, depth: depth + 1) : [])
        }
        .sorted { a, b in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return a.id < b.id
        }
    }

    /// Names come with `full=true` entries; flat ones only carry ids.
    private static func name(of group: [Item], depth: Int, id: Int) -> String {
        switch depth {
        case 0: group.lazy.compactMap(\.entry.customerName).first ?? (id == 0 ? "No customer" : "Customer #\(id)")
        case 1: group.lazy.compactMap(\.entry.projectName).first ?? "Project #\(id)"
        default: group.lazy.compactMap(\.entry.activityName).first ?? "Activity #\(id)"
        }
    }

    /// Plain-text table for the clipboard: totals, then one row per customer,
    /// project (indented) and activity, then the AI agents. Numbers in `locale`,
    /// like the Reports window.
    public func summary(title: String, currency: String, locale: Locale = .current) -> String {
        let twoDecimals = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)).locale(locale)
        func hours(_ seconds: Int) -> String { (Double(seconds) / 3600).formatted(twoDecimals) + " h" }
        func share(_ seconds: Int) -> String {
            totalSeconds > 0 ? "\(Int((Double(seconds) / Double(totalSeconds) * 100).rounded())) %" : "–"
        }
        func money(_ value: Double) -> String { value.formatted(twoDecimals) }
        func right(_ s: String, _ width: Int) -> String { String(repeating: " ", count: max(0, width - s.count)) + s }

        var rows: [(name: String, seconds: Int, revenue: Double)] = []
        func walk(_ lines: [ReportLine], depth: Int) {
            for line in lines {
                rows.append((String(repeating: "  ", count: depth) + line.name, line.seconds, line.revenue))
                walk(line.children, depth: depth + 1)
            }
        }
        walk(customers, depth: 0)
        let width = max(30, rows.map(\.name.count).max() ?? 0) + 2
        let showMoney = totalRevenue > 0
        func row(_ name: String, _ h: String, _ s: String, _ r: String) -> String {
            name.padding(toLength: width, withPad: " ", startingAt: 0) + right(h, 10) + right(s, 7)
                + (showMoney ? right(r, 13) : "")
        }

        var out = [title]
        var totals = "Total \(hours(totalSeconds)) · billable \(share(billableSeconds))"
        if showMoney { totals += " · revenue \(money(totalRevenue)) \(currency)" }
        out += [totals, ""]
        out.append(row("Customer / Project / Activity", "Hours", "Share", "Revenue \(currency)"))
        out += rows.map { row($0.name, hours($0.seconds), share($0.seconds), money($0.revenue)) }
        if !agents.isEmpty {
            out += ["", "AI agents"]
            out += agents.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { row("  " + $0.key, hours($0.value), share($0.value), "") }
        }
        return out.joined(separator: "\n")
    }
}
