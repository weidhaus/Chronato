import AppKit
import Charts
import ChronatoCore
import SwiftUI

struct ReportsView: View {
    @Environment(TrackerStore.self) private var store
    /// Snapshot/preview data instead of fetching from Kimai.
    var fixture: [KimaiTimesheet]? = nil
    @State var period: ReportPeriod = .month
    @State var scope: ReportScope = .me
    /// Any date inside the shown period; ‹ / › move it by one period.
    @State private var anchor = Date()
    /// Fetched entries per period, so flipping back and forth does not refetch.
    @State private var cache: [DateInterval: [KimaiTimesheet]] = [:]
    /// Fetches in flight. A count, because the cancelled fetch of the period
    /// just left may finish after the new one started.
    @State private var loading = 0
    @State private var failure: String?
    /// Kimai answered `user=<someone else>` with the token user's own entries: it
    /// ignores `user` without view_other_timesheet (no 403), so the report holds
    /// only those. nil = not known yet.
    @State private var ownOnly: Bool?
    /// The allow-listed agents' tags: the menu's rule for what counts as AI work.
    @State private var agentTags = Set(AIConfig.load().agents.map(\.tag))
    @State private var copied = false
    /// Customers start expanded, projects collapsed; row ids in here are flipped.
    @State private var toggled: Set<String> = []

    var body: some View {
        let interval = Report.interval(for: period, containing: anchor, calendar: store.calendar)
        let report = (fixture ?? cache[interval]).map {
            Report.build(entries: $0, interval: interval, period: period, scope: scope,
                         meId: store.me?.id ?? 0, agentTags: agentTags, calendar: store.calendar, now: store.now)
        }
        VStack(spacing: 0) {
            header(interval, report)
            Divider()
            content(report).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 540)
        .task(id: interval) {
            failure = nil
            await load(interval)
        }
        // A timer started or stopped: every cached period that holds it is stale
        // (a stopped entry would keep counting up). Refetch the shown one in place.
        .onChange(of: store.active?.id) {
            cache = cache.filter { $0.key == interval }
            Task { await load(interval, force: true) }
        }
        // Connected, disconnected or switched to another server: start over.
        .onChange(of: store.connection) {
            cache = [:]
            failure = nil
            ownOnly = nil
            Task { await load(interval) }
        }
    }

    // MARK: Header

    private func header(_ interval: DateInterval, _ report: Report?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Period", selection: $period) {
                    ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if loading > 0 { ProgressView().controlSize(.small) }
                Picker("Scope", selection: $scope) {
                    ForEach(ReportScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Me: your hours · AI: hours booked by AI agents · All: both")
                Button { Task { await load(interval, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload from Kimai")
                    .disabled(loading > 0 || fixture != nil || store.isPreview)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(interval)).font(.title2.weight(.semibold))
                    if ownOnly == true, scope != .me {
                        Label("Only your own entries: this API user may not see other users' timesheets (view_other_timesheet).",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // A reload failed but the cached report is still shown.
                    if let failure, report != nil {
                        Label("Couldn't reload: \(failure)", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help(failure)
                    }
                }
                Spacer()
                ControlGroup {
                    Button { step(-1, interval) } label: { Image(systemName: "chevron.left") }.help("Previous \(period.rawValue)")
                    Button("Today") { anchor = Date() }
                    Button { step(1, interval) } label: { Image(systemName: "chevron.right") }.help("Next \(period.rawValue)")
                        .disabled(interval.end > Date())
                }
                .fixedSize()
                Button { copy(report, interval) } label: {
                    Label(copied ? "Copied" : "Copy Summary", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(report?.customers.isEmpty ?? true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func step(_ direction: Int, _ interval: DateInterval) {
        anchor = store.calendar.date(byAdding: period.component, value: direction, to: interval.start) ?? anchor
    }

    /// "Thursday, 8 October 2026", "Week 41 · 5–11 Oct 2026", "October 2026", "2026".
    private func title(_ interval: DateInterval) -> String {
        let cal = store.calendar
        let style = Date.FormatStyle(locale: .current, calendar: cal, timeZone: cal.timeZone)
        switch period {
        case .day:
            return interval.start.formatted(style.weekday(.wide).day().month(.wide).year())
        case .week:
            // Kimai numbers weeks the ISO way (Monday start, first week has 4+ days).
            // Read it mid-week, so a Sunday-start week gets the number of six of its days.
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = cal.timeZone
            let week = iso.component(.weekOfYear, from: interval.start.addingTimeInterval(3.5 * 86400))
            let days = (interval.start..<interval.end.addingTimeInterval(-1)).formatted(
                Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, locale: .current, calendar: cal, timeZone: cal.timeZone))
            return "Week \(week) · \(days)"
        case .month:
            return interval.start.formatted(style.month(.wide).year())
        case .year:
            return interval.start.formatted(style.year())
        }
    }

    private func copy(_ report: Report?, _ interval: DateInterval) {
        guard let report else { return }
        let text = report.summary(title: "\(title(interval)) · \(scope.longTitle)", currency: currency(report))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    // MARK: Content

    @ViewBuilder private func content(_ report: Report?) -> some View {
        if let report {
            if report.customers.isEmpty {
                ContentUnavailableView("No time booked", systemImage: "clock",
                                       description: Text(scope.emptyText(period)))
            } else {
                ReportBody(report: report, currency: currency(report), color: color, toggled: $toggled)
            }
        } else if let failure {
            ContentUnavailableView {
                Label("Couldn't load the report", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") {
                    let interval = Report.interval(for: period, containing: anchor, calendar: store.calendar)
                    Task { await load(interval, force: true) }
                }
            }
        } else if store.client == nil, !store.isPreview {
            ContentUnavailableView("Not connected", systemImage: "bolt.horizontal.circle",
                                   description: Text("Connect to Kimai under Settings → Connection."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Data

    private func load(_ interval: DateInterval, force: Bool = false) async {
        guard fixture == nil, !store.isPreview, force || cache[interval] == nil, let client = store.client else { return }
        loading += 1
        failure = nil
        defer { loading -= 1 }
        // The API's `end` is inclusive.
        let end = interval.end.addingTimeInterval(-1)
        agentTags = Set(AIConfig.load().agents.map(\.tag)) // Settings may have changed the allowlist
        do {
            let entries = try await client.timesheets(user: "all", begin: interval.start, end: end)
            cache[interval] = entries
            // Once per connection. A failed probe only leaves it unknown; the report is loaded.
            if ownOnly == nil, let meId = store.me?.id {
                ownOnly = entries.contains { ($0.userId ?? meId) != meId } ? false
                    : try? await Self.onlyOwnEntries(client, meId: meId, other: otherUserId(meId), begin: interval.start, end: end)
            }
        } catch {
            // Switching periods cancels the old fetch; that is not an error worth showing.
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    /// Someone else Kimai may hold entries of: the AI booking user, else any listed user.
    private func otherUserId(_ meId: Int) -> Int? {
        if let booking = AIConfig.load().bookingUserId, booking != meId { return booking }
        return store.users.first { $0.id != meId }?.id
    }

    /// Whether Kimai shows this token only its own timesheets. Without
    /// view_other_timesheet it ignores `user` (no 403) and answers with the token
    /// user's entries, so asking for `other`'s entries tells: own entries back = only
    /// own; `other`'s = no; nothing = can't tell (nil), e.g. nobody booked anything.
    static func onlyOwnEntries(_ client: KimaiClient, meId: Int, other: Int?, begin: Date, end: Date) async throws -> Bool? {
        guard let other else { return nil }
        let probe = try await client.timesheets(user: String(other), begin: begin, end: end)
        if probe.contains(where: { $0.userId == meId }) { return true }
        return probe.isEmpty ? nil : false
    }

    /// Revenue is in the customers' currency; mixed currencies are not converted.
    private func currency(_ report: Report) -> String {
        report.customers.lazy.compactMap { store.customer($0.id)?.currency }.first ?? "EUR"
    }

    /// The customer's Kimai colour, else a stable pick from a system palette.
    private func color(_ customerId: Int) -> Color {
        if let color = Brand.color(hex: store.customer(customerId)?.color) { return color }
        let palette: [Color] = [.blue, .orange, .purple, .pink, .teal, .yellow, .indigo, .mint, .brown, .cyan]
        return palette[abs(customerId) % palette.count]
    }

    // MARK: Fixture

    /// Deterministic sample month for `Chronato snapshot` (fictional customers only).
    /// Uses the customer/project/activity ids of `TrackerStore.preview` so colours resolve.
    static func fixtureEntries(now: Date = .now) -> [KimaiTimesheet] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!  // the preview user's zone
        typealias Work = (customer: Int, customerName: String, project: Int, projectName: String, activity: Int, activityName: String, rate: Double)
        let ops: Work = (10, "Northwind Traders", 12, "Ops Dashboard", 3, "Automation", 95)
        let sync: Work = (10, "Northwind Traders", 12, "Ops Dashboard", 5, "Weekly sync", 95)
        let acme: Work = (7, "Acme Studio", 9, "Consulting", 21, "Development", 110)
        let acmeTalk: Work = (7, "Acme Studio", 9, "Consulting", 1, "Consulting", 110)
        let harbor: Work = (11, "Blue Harbor", 11, "Consulting", 1, "Consulting", 85)
        let house: Work = (12, "In-house", 13, "Internal", 18, "Internal work", 0)
        // Five weekday plans: (start hour, minutes, work).
        let plans: [[(Double, Int, Work)]] = [
            [(9, 180, ops), (13, 150, acme), (15.75, 60, house)],
            [(8.5, 30, sync), (9.25, 165, ops), (13, 120, harbor), (15.25, 45, house)],
            [(9, 210, acme), (13.5, 60, acmeTalk), (14.75, 120, ops)],
            [(8.75, 195, ops), (13, 90, harbor), (14.75, 90, house)],
            [(9, 120, acme), (11.25, 60, house), (13, 150, ops), (15.75, 45, sync)],
        ]
        var out: [KimaiTimesheet] = []
        func add(_ begin: Date, _ minutes: Int?, _ w: Work, user: Int = 1, tags: [String] = []) {
            let ai = user != 1
            out.append(KimaiTimesheet(
                id: 1000 + out.count, begin: begin, end: minutes.map { begin.addingTimeInterval(Double($0) * 60) },
                duration: (minutes ?? 0) * 60, tags: tags, billable: w.rate > 0 && !ai,
                rate: ai ? 0 : w.rate * Double(minutes ?? 0) / 60, userId: user,
                projectId: w.project, projectName: w.projectName, customerId: w.customer, customerName: w.customerName,
                activityId: w.activity, activityName: w.activityName))
        }
        let running = now.addingTimeInterval(-47 * 60)
        let today = cal.startOfDay(for: now)
        for offset in (0..<35).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  (2...6).contains(cal.component(.weekday, from: day)) else { continue }
            // Keyed by the date, so a given day looks the same whenever it is rendered.
            let n = cal.ordinality(of: .day, in: .era, for: day) ?? 0
            for (hour, minutes, work) in plans[n % plans.count] {
                let begin = day.addingTimeInterval(hour * 3600)
                if begin.addingTimeInterval(Double(minutes) * 60) <= running { add(begin, minutes, work) }
            }
            for (hour, minutes, work, every) in [(10.0, 75, ops, 2), (14.0, 50, house, 3)] where n % every == 0 {
                let begin = day.addingTimeInterval(hour * 3600)
                if begin.addingTimeInterval(Double(minutes) * 60) <= now { add(begin, minutes, work, user: 2, tags: ["ai-claude-code"]) }
            }
        }
        add(running, nil, ops)
        return out
    }
}

// MARK: - Report body

/// KPIs, chart and breakdown of one built report.
private struct ReportBody: View {
    let report: Report
    let currency: String
    let color: (Int) -> Color
    @Binding var toggled: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            kpis
            HStack(alignment: .top, spacing: 16) {
                chart
                if !report.agents.isEmpty { agents }
            }
            .frame(height: 190)
            breakdown
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    // MARK: KPIs

    private var kpis: some View {
        let billableShare = report.totalSeconds > 0 ? Double(report.billableSeconds) / Double(report.totalSeconds) : 0
        let activeDays = Set(report.buckets.map(\.start)).count
        return HStack(spacing: 12) {
            KPI(title: "Total", value: DurationText.hours(report.totalSeconds),
                caption: report.period == .week || report.period == .month
                    ? "Ø \(DurationText.hours(report.totalSeconds / max(activeDays, 1))) on \(activeDays) day\(activeDays == 1 ? "" : "s")"
                    : DurationText.short(report.totalSeconds) + " h:mm")
            KPI(title: "Billable", value: billableShare.formatted(.percent.precision(.fractionLength(0))),
                caption: DurationText.hours(report.billableSeconds))
            if report.totalRevenue > 0 {
                KPI(title: "Revenue", value: report.totalRevenue.formatted(.currency(code: currency).precision(.fractionLength(0))),
                    caption: report.billableSeconds > 0
                        ? "Ø " + (report.totalRevenue / (Double(report.billableSeconds) / 3600)).formatted(.currency(code: currency).precision(.fractionLength(0))) + " per billable hour"
                        : " ")
            }
            KPI(title: "Entries", value: report.entryCount.formatted(), caption: report.customers.count == 1 ? "1 customer" : "\(report.customers.count) customers")
        }
    }

    // MARK: Chart

    private var chart: some View {
        // One centred label per bar slot, so a label never sits between two bars.
        let format: Date.FormatStyle = switch report.period {
        case .day: .dateTime.hour(.twoDigits(amPM: .omitted))
        case .week: .dateTime.weekday(.abbreviated).day()
        case .month: .dateTime.day()
        case .year: .dateTime.month(.abbreviated)
        }
        return Chart(report.buckets) { bucket in
            BarMark(x: .value("Date", bucket.start, unit: report.period.bucketComponent),
                    y: .value("Hours", Double(bucket.seconds) / 3600))
                .foregroundStyle(by: .value("Customer", bucket.customerName))
        }
        .chartForegroundStyleScale(domain: report.customers.map(\.name), range: report.customers.map { color($0.id) })
        .chartXScale(domain: report.interval.start...report.interval.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: report.period.bucketComponent)) { _ in
                AxisValueLabel(format: format, centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(Double.self) { Text("\(h.formatted()) h") } }
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 10)
        // A legend that wraps eats the plot's fixed height; the breakdown below has the same colour dots.
        .chartLegend(report.customers.count > 8 ? .hidden : .automatic)
    }

    // MARK: AI agents

    private var agents: some View {
        let total = max(report.agents.values.reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("AI agents").font(.headline)
            ForEach(report.agents.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { tag, seconds in
                HStack {
                    Label(String(tag.dropFirst(3)), systemImage: "sparkles").lineLimit(1)
                    Spacer()
                    Text(DurationText.hours(seconds)).monospacedDigit()
                }
                ShareBar(share: Double(seconds) / Double(total), color: .purple)
            }
            Spacer(minLength: 0)
            if report.scope == .all, report.totalSeconds > 0 {
                Text("\((Double(total) / Double(report.totalSeconds)).formatted(.percent.precision(.fractionLength(0)))) of all hours")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 220)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Breakdown

    private var breakdown: some View {
        let showRevenue = report.totalRevenue > 0
        return VStack(spacing: 0) {
            Columns(showRevenue: showRevenue) {
                Text("Customer / Project / Activity")
            } share: {
                Text("Share")
            } hours: {
                Text("Hours")
            } revenue: {
                Text("Revenue")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(report.customers) { customer in
                        rows(customer, path: "c\(customer.id)", depth: 0, color: color(customer.id), showRevenue: showRevenue)
                        Divider()
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    /// A line and, when expanded, its children (AnyView because it recurses).
    private func rows(_ line: ReportLine, path: String, depth: Int, color: Color, showRevenue: Bool) -> AnyView {
        let expanded = (depth == 0) != toggled.contains(path)
        let share = report.totalSeconds > 0 ? Double(line.seconds) / Double(report.totalSeconds) : 0
        func toggle() {
            guard !line.children.isEmpty else { return }
            withAnimation(.snappy(duration: 0.2)) {
                if toggled.contains(path) { toggled.remove(path) } else { toggled.insert(path) }
            }
        }
        return AnyView(VStack(spacing: 0) {
            Columns(showRevenue: showRevenue) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(line.children.isEmpty ? 0 : 1)
                        .frame(width: 10)
                    if depth == 0 { Circle().fill(color).frame(width: 8, height: 8) }
                    Text(line.name).lineLimit(1).truncationMode(.tail)
                        .fontWeight(depth == 0 ? .medium : .regular)
                        .foregroundStyle(depth == 2 ? .secondary : .primary)
                }
                .padding(.leading, CGFloat(depth) * 20)
            } share: {
                HStack(spacing: 8) {
                    ShareBar(share: share, color: color.opacity(depth == 0 ? 1 : 0.55))
                    Text(share.formatted(.percent.precision(.fractionLength(0)))).frame(width: 40, alignment: .trailing)
                }
            } hours: {
                Text(DurationText.hours(line.seconds))
            } revenue: {
                Text(line.revenue > 0 ? line.revenue.formatted(.currency(code: currency)) : "–")
                    .foregroundStyle(line.revenue > 0 ? .primary : .tertiary)
            }
            .monospacedDigit()
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(line.children.isEmpty ? [] : .isButton)
            .accessibilityValue(line.children.isEmpty ? "" : expanded ? "expanded" : "collapsed")
            .accessibilityAction { toggle() }
            if expanded {
                ForEach(line.children) { child in
                    rows(child, path: "\(path)/\(child.id)", depth: depth + 1, color: color, showRevenue: showRevenue)
                }
            }
        })
    }
}

/// One breakdown row's column layout, shared by header and rows so numbers line up.
private struct Columns<Name: View, Share: View, Hours: View, Revenue: View>: View {
    let showRevenue: Bool
    @ViewBuilder let name: Name
    @ViewBuilder let share: Share
    @ViewBuilder let hours: Hours
    @ViewBuilder let revenue: Revenue

    var body: some View {
        HStack(spacing: 16) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            share.frame(width: 150, alignment: .trailing)
            hours.frame(width: 72, alignment: .trailing)
            if showRevenue { revenue.frame(width: 100, alignment: .trailing) }
        }
    }
}

private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

private struct KPI: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension ReportPeriod {
    var title: String { rawValue.capitalized }
}

private extension ReportScope {
    var title: String {
        switch self {
        case .me: "Me"
        case .ai: "AI"
        case .all: "All"
        }
    }

    func emptyText(_ period: ReportPeriod) -> String {
        switch self {
        case .me: "You have not tracked any time this \(period.rawValue)."
        case .ai: "No AI agent booked time this \(period.rawValue)."
        case .all: "Nobody tracked time this \(period.rawValue)."
        }
    }

    var longTitle: String {
        switch self {
        case .me: "My hours"
        case .ai: "AI agents"
        case .all: "Everyone"
        }
    }
}
