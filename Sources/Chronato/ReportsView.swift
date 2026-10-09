import AppKit
import Charts
import ChronatoCore
import SwiftUI

/// The Reports window (design/chronato-interaction-spec.md §8): period and
/// scope in the native toolbar, the period's title once in the content, then
/// KPIs, a restrained chart and a native outline table on the Studio surface.
struct ReportsView: View {
    @Environment(TrackerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var selection: String?
    /// The content's width: the title grows from 1280 pt, the padding shrinks near the minimum.
    @State private var width: CGFloat = 960

    /// The period on screen. Actions read it (and `report(_:)`) when they run: a toolbar
    /// button's closure can outlive the body that made it, so captured values go stale.
    private var shownInterval: DateInterval {
        Report.interval(for: period, containing: anchor, calendar: store.calendar)
    }

    private func report(_ interval: DateInterval) -> Report? {
        (fixture ?? cache[interval]).map {
            Report.build(entries: $0, interval: interval, period: period, scope: scope,
                         meId: store.me?.id ?? 0, agentTags: agentTags, calendar: store.calendar, now: store.now)
        }
    }

    var body: some View {
        let interval = shownInterval
        let report = report(interval)
        let shown = "\(period.rawValue)-\(scope.rawValue)-\(interval.start.timeIntervalSince1970)"
        VStack(alignment: .leading, spacing: 0) {
            heading(interval, report)
            // Period or scope changes crossfade the content; toolbar and title stay put.
            ZStack {
                content(report).id(shown).transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : Studio.motion, value: shown)
        }
        // The window's minimum is 760 × 540 (spec §8); the toolbar takes about 52 of that.
        .frame(minWidth: 760, minHeight: 488)
        .background(Studio.surface)
        .containerBackground(Studio.surface, for: .window)
        .tint(Studio.accentInk)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background { periodShortcuts }
        .toolbar { toolbar(interval, report) }
        // The period title is in the content, once; the window keeps its name for the Window menu and VoiceOver.
        .toolbar(removing: .title)
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

    private var padding: CGFloat { width < 840 ? Studio.Space.l : Studio.Space.xl }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ interval: DateInterval, _ report: Report?) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button { step(-1) } label: { Label("Previous \(period.title)", systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow)
                    .help("Previous \(period.rawValue)")
                Button("Today") { anchor = Date() }
                    .keyboardShortcut("t")
                    .help("Go to the \(period.rawValue) containing today")
                Button { step(1) } label: { Label("Next \(period.title)", systemImage: "chevron.right") }
                    .keyboardShortcut(.rightArrow)
                    .help("Next \(period.rawValue)")
                    .disabled(interval.end > Date())
            }
        }
        // Period is centred by spacers, not `.principal`: in this AppKit-hosted window SwiftUI
        // puts a principal item first in the toolbar, which pushes ‹ Today › after it.
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Picker("Period", selection: $period) {
                ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            Picker("Scope", selection: $scope) {
                ForEach(ReportScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Me: your hours · AI: hours booked by AI agents · All: both")
        }
        ToolbarItem(placement: .primaryAction) {
            if loading > 0 {
                ProgressView().controlSize(.small).help("Loading from Kimai")
            } else {
                Button { Task { await load(shownInterval, force: true) } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Reload from Kimai")
                    .disabled(fixture != nil || store.isPreview)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy Summary", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy this report as text")
            .disabled(report?.customers.isEmpty ?? true)
        }
    }

    /// ⌘1–⌘4 choose the period, as in Calendar. A segmented control has no
    /// per-segment shortcut, so hidden buttons carry them.
    private var periodShortcuts: some View {
        ForEach(Array(ReportPeriod.allCases.enumerated()), id: \.element) { index, period in
            Button(period.title) { self.period = period }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
        }
        .hidden()
    }

    private func step(_ direction: Int) {
        anchor = store.calendar.date(byAdding: period.component, value: direction, to: shownInterval.start) ?? anchor
    }

    // MARK: Heading

    /// The period's title, the scope, and notices about this report.
    private func heading(_ interval: DateInterval, _ report: Report?) -> some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            Text(title(interval))
                .font(width >= 1280 ? Studio.Typography.titleWide : Studio.Typography.title)
                .foregroundStyle(Studio.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(scope.longTitle)
                .foregroundStyle(Studio.textSecondary)
            if ownOnly == true, scope != .me {
                Label("Only your own entries: this API user may not see other users' timesheets (view_other_timesheet).",
                      systemImage: "info.circle")
                    .foregroundStyle(Studio.textSecondary)
            }
            // A reload failed but the cached report is still shown.
            if let failure, report != nil {
                Label("Couldn't reload: \(failure)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Studio.errorInk)
                    .lineLimit(1)
                    .help(failure)
            }
        }
        .font(Studio.Typography.secondary)
        .padding(.horizontal, padding)
        .padding(.top, padding)
        .padding(.bottom, Studio.Space.l)
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

    private func copy() {
        let interval = shownInterval
        guard let report = report(interval) else { return }
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
                // Titles in textPrimary: the system's grey is 3.9:1 on `surface`, under the 4.5 for window text.
                ContentUnavailableView {
                    Label { Text("No time booked").foregroundStyle(Studio.textPrimary) } icon: { Image(systemName: "clock") }
                } description: {
                    Text(scope.emptyText(period)).foregroundStyle(Studio.textSecondary)
                }
            } else {
                ReportBody(report: report, currency: currency(report), color: color, now: store.now, padding: padding,
                           toggled: $toggled, selection: $selection)
            }
        } else if let failure {
            ContentUnavailableView {
                Label {
                    Text("Couldn't load the report").foregroundStyle(Studio.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Studio.errorInk)
                }
            } description: {
                Text(failure).foregroundStyle(Studio.textSecondary)
            } actions: {
                Button("Try Again") { Task { await load(shownInterval, force: true) } }
            }
        } else if store.client == nil, !store.isPreview {
            ContentUnavailableView {
                Label { Text("Not connected").foregroundStyle(Studio.textPrimary) } icon: { Image(systemName: "bolt.horizontal.circle") }
            } description: {
                Text("Connect to Kimai under Settings → Connection.").foregroundStyle(Studio.textSecondary)
            }
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
    /// Marks the chart's current bucket.
    let now: Date
    let padding: CGFloat
    @Binding var toggled: Set<String>
    @Binding var selection: String?
    /// The table gets its rows one update after it is built. Built with them, SwiftUI
    /// expands customer after customer and AppKit's row-height cache re-enters itself
    /// measuring the projects ("reentrant operation in its NSTableView delegate");
    /// inserted in one update, all rows are measured in one go.
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.l) {
            kpis
            HStack(alignment: .top, spacing: Studio.Space.l) {
                chart
                if !report.agents.isEmpty { agents }
            }
            .frame(height: 200)
            .padding(.bottom, Studio.Space.s)
            breakdown
        }
        .padding(.horizontal, padding)
    }

    // MARK: KPIs

    private var kpis: some View {
        let billableShare = report.totalSeconds > 0 ? Double(report.billableSeconds) / Double(report.totalSeconds) : 0
        let activeDays = Set(report.buckets.map(\.start)).count
        return HStack(spacing: Studio.Space.m) {
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

    /// Customer colours muted to 85 %, hairline horizontal grid, no other decoration.
    /// The only accent is the axis label of the bucket holding now.
    private var chart: some View {
        // One centred label per bar slot, so a label never sits between two bars.
        let format: Date.FormatStyle = switch report.period {
        case .day: .dateTime.hour(.twoDigits(amPM: .omitted))
        case .week: .dateTime.weekday(.abbreviated).day()
        case .month: .dateTime.day()
        case .year: .dateTime.month(.abbreviated)
        }
        let unit = report.period.bucketComponent
        return Chart(report.buckets) { bucket in
            BarMark(x: .value("Date", bucket.start, unit: unit),
                    y: .value("Hours", Double(bucket.seconds) / 3600))
                .foregroundStyle(by: .value("Customer", bucket.customerName))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(domain: report.customers.map(\.name), range: report.customers.map { color($0.id).opacity(0.85) })
        .chartXScale(domain: report.interval.start...report.interval.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: unit)) { value in
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) {
                        // The axis is laid out in the system calendar, so the label is matched in it too.
                        let current = Calendar.current.isDate(date, equalTo: now, toGranularity: unit)
                        Text(date, format: format)
                            .font(current ? Studio.Typography.numeral.weight(.semibold) : Studio.Typography.numeral)
                            .foregroundStyle(current ? Studio.accentInk : Studio.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Studio.lineSubtle)
                AxisValueLabel {
                    if let h = value.as(Double.self) {
                        Text("\(h.formatted()) h").font(Studio.Typography.numeral).foregroundStyle(Studio.textSecondary)
                    }
                }
            }
        }
        // A legend that wraps eats the plot's fixed height; the breakdown below has the same colour dots.
        .chartLegend(report.customers.count > 8 ? .hidden : .visible)
        .chartLegend(position: .top, alignment: .leading, spacing: Studio.Space.m) { legend }
    }

    /// One wrapping line of "● Customer" pairs. Non-breaking spaces keep a dot with its
    /// name, so a line only breaks between customers.
    private var legend: some View {
        let entries = report.customers.map { customer in
            let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 8)).foregroundStyle(color(customer.id).opacity(0.85))
            return Text("\(dot)\u{00A0}\(customer.name.replacingOccurrences(of: " ", with: "\u{00A0}"))")
        }
        return entries.dropFirst().reduce(entries.first ?? Text("")) { Text("\($0)    \($1)") }
            .font(Studio.Typography.secondary)
            .foregroundStyle(Studio.textSecondary)
            .accessibilityLabel("Customers: " + report.customers.map(\.name).joined(separator: ", "))
    }

    // MARK: AI agents

    private var agents: some View {
        let total = max(report.agents.values.reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: Studio.Space.s) {
            Text("AI agents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Studio.textSecondary)
            ForEach(report.agents.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { tag, seconds in
                HStack {
                    Label(String(tag.dropFirst(3)), systemImage: "sparkles").lineLimit(1)
                    Spacer()
                    Text(DurationText.hours(seconds)).monospacedDigit()
                }
                .foregroundStyle(Studio.textPrimary)
                // Neutral: agents are not customers.
                ShareBar(share: Double(seconds) / Double(total), color: Studio.controlBorder)
            }
            Spacer(minLength: 0)
            if report.scope == .all, report.totalSeconds > 0 {
                Text("\((Double(total) / Double(report.totalSeconds)).formatted(.percent.precision(.fractionLength(0)))) of all hours")
                    .font(Studio.Typography.secondary)
                    .foregroundStyle(Studio.textSecondary)
            }
        }
        .font(Studio.Typography.body)
        .padding(.vertical, Studio.Space.m)
        .padding(.horizontal, 14)
        .frame(width: 220, alignment: .leading)
        .frame(maxHeight: .infinity)
        .modifier(Tile())
    }

    // MARK: Breakdown

    /// A native outline table: ↑/↓ move, ←/→ collapse and expand.
    private var breakdown: some View {
        Table(of: Row.self, selection: $selection) {
            TableColumn("Customer / Project / Activity") { row in
                HStack(spacing: 6) {
                    if row.depth == 0 {
                        Circle().fill(color(row.customerId)).frame(width: 8, height: 8)
                    }
                    Text(row.line.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fontWeight(row.depth == 0 ? .medium : .regular)
                        .modifier(Ink(secondary: row.depth == 2))
                }
            }
            TableColumn("Share") { row in
                let share = report.totalSeconds > 0 ? Double(row.line.seconds) / Double(report.totalSeconds) : 0
                HStack(spacing: Studio.Space.s) {
                    ShareBar(share: share, color: color(row.customerId).opacity(row.depth == 0 ? 1 : 0.55))
                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                        .frame(width: 40, alignment: .trailing)
                        .modifier(Ink())
                }
            }
            .width(150)
            TableColumn("Hours") { row in
                Text(DurationText.hours(row.line.seconds)).modifier(Ink())
            }
            .width(72)
            .alignment(.trailing)
            if report.totalRevenue > 0 {
                TableColumn("Revenue") { row in
                    Text(row.line.revenue > 0 ? row.line.revenue.formatted(.currency(code: currency)) : "–")
                        .modifier(Ink(secondary: row.line.revenue == 0))
                }
                .width(100)
                .alignment(.trailing)
            }
        } rows: {
            ForEach(appeared ? report.customers : []) { customer in
                let c = Row(id: "c\(customer.id)", line: customer, depth: 0, customerId: customer.id)
                DisclosureTableRow(c, isExpanded: expanded(c)) {
                    ForEach(customer.children) { project in
                        let p = Row(id: "\(c.id)/\(project.id)", line: project, depth: 1, customerId: customer.id)
                        DisclosureTableRow(p, isExpanded: expanded(p)) {
                            ForEach(project.children) { activity in
                                TableRow(Row(id: "\(p.id)/\(activity.id)", line: activity, depth: 2, customerId: customer.id))
                            }
                        }
                    }
                }
            }
        }
        .monospacedDigit()
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .onAppear { appeared = true }
    }

    /// Customers start expanded and projects collapsed; `toggled` holds the rows flipped from that.
    private func expanded(_ row: Row) -> Binding<Bool> {
        Binding {
            (row.depth == 0) != toggled.contains(row.id)
        } set: { open in
            withAnimation(reduceMotion ? nil : Studio.motion) {
                if open == (row.depth == 0) { toggled.remove(row.id) } else { toggled.insert(row.id) }
            }
        }
    }
}

/// A breakdown line with an id unique across levels ("c10/12/3"); ReportLine ids
/// are Kimai ids and repeat between customers, projects and activities.
private struct Row: Identifiable {
    let id: String
    let line: ReportLine
    let depth: Int
    let customerId: Int
}

/// Studio ink, except in a selected row: there the system's selection colours take
/// over (macOS ignores the tint for selection; dark ink on it would not read).
private struct Ink: ViewModifier {
    var secondary = false
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased
            ? AnyShapeStyle(secondary ? HierarchicalShapeStyle.secondary : .primary)
            : AnyShapeStyle(secondary ? Studio.textSecondary : Studio.textPrimary))
    }
}

/// `raised` with a hairline border, stronger with Increase Contrast.
private struct Tile: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Studio.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(contrast == .increased ? Studio.controlBorder : Studio.lineSubtle, lineWidth: 0.5)
            }
    }
}

private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Studio.lineSubtle)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Studio.Typography.secondary)
                .foregroundStyle(Studio.textSecondary)
            Text(value)
                .font(Studio.Typography.figure)
                .foregroundStyle(Studio.textPrimary)
                .lineLimit(1)
            Text(caption)
                .font(Studio.Typography.secondary)
                .monospacedDigit()
                .foregroundStyle(Studio.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Studio.Space.m)
        .padding(.horizontal, 14)
        .modifier(Tile())
        .accessibilityElement(children: .combine)
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
