import Charts
import ChronatoCore
import SwiftUI

/// The Reports tab: hours per customer by day, week, month or year, for me,
/// the AI agents or everyone. Same data and maths as the Mac's Reports window
/// (Sources/Chronato/ReportsView.swift): KimaiClient.timesheets(user: "all")
/// (own entries only when Kimai answers 403) → Report.build.
struct ReportsTab: View {
    @Environment(PhoneTracker.self) private var tracker
    /// Remembered between launches (and settable with `-reportPeriod month` for screenshots).
    @AppStorage("reportPeriod") private var period: ReportPeriod = .week
    @AppStorage("reportScope") private var scope: ReportScope = .me
    /// Any date inside the shown period; ‹ / › move it by one period.
    @State private var anchor = Date()
    /// Fetched entries per period, so flipping back and forth does not refetch.
    @State private var cache: [DateInterval: [KimaiTimesheet]] = [:]
    /// Fetches in flight. A count, because the cancelled fetch of the period
    /// just left may finish after the new one started.
    @State private var loading = 0
    @State private var failure: String?
    /// Kimai refused `user=all` (403): the report only holds the token user's entries.
    @State private var ownOnly = false
    /// Customers start expanded, projects collapsed; row ids in here are flipped.
    @State private var toggled: Set<String> = []

    var body: some View {
        let calendar = tracker.calendar
        let interval = Report.interval(for: period, containing: anchor, calendar: calendar)
        let entries = tracker.isFixture ? fixtureEntries() : cache[interval]
        let report = entries.map {
            Report.build(entries: $0, interval: interval, period: period, scope: scope,
                         meId: tracker.me?.id ?? 0, calendar: calendar)
        }
        NavigationStack {
            List {
                Section { header(interval) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                content(report, interval)
            }
            .navigationTitle("Reports")
            .toolbar { toolbar(report, interval) }
            .refreshable { await load(interval, force: true) }
        }
        .task(id: interval) {
            failure = nil
            await load(interval)
        }
        // A timer started or stopped: every cached period that holds it is stale
        // (a stopped entry would keep counting up). Refetch the shown one in place.
        .onChange(of: tracker.active?.id) {
            cache = cache.filter { $0.key == interval }
            Task { await load(interval, force: true) }
        }
        // Connected to another server or user: start over.
        .onChange(of: tracker.connection) {
            cache = [:]
            failure = nil
            ownOnly = false
            Task { await load(interval) }
        }
        .sensoryFeedback(.selection, trigger: interval)
    }

    // MARK: Header and toolbar

    /// Period picker, then ‹ title and scope ›.
    private func header(_ interval: DateInterval) -> some View {
        VStack(spacing: 16) {
            Picker("Period", selection: $period) {
                ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                stepButton(-1, interval)
                VStack(spacing: 4) {
                    Text(title(interval))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .contentTransition(.numericText())
                    Menu {
                        Picker("Show", selection: $scope) {
                            ForEach(ReportScope.allCases) { Label($0.longTitle, systemImage: $0.systemImage).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(scope.longTitle)
                            Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    .accessibilityLabel("Show \(scope.longTitle)")
                    .accessibilityHint("Choose between your hours, AI agents and everyone")
                }
                .frame(maxWidth: .infinity)
                stepButton(1, interval).disabled(interval.end > Date())
            }
        }
        .buttonStyle(.borderless)
    }

    private func stepButton(_ direction: Int, _ interval: DateInterval) -> some View {
        Button {
            withAnimation(.snappy) {
                anchor = tracker.calendar.date(byAdding: period.component, value: direction, to: interval.start) ?? anchor
            }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(direction < 0 ? "Previous \(period.rawValue)" : "Next \(period.rawValue)")
    }

    @ToolbarContentBuilder
    private func toolbar(_ report: Report?, _ interval: DateInterval) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Today") { withAnimation(.snappy) { anchor = Date() } }
                .disabled(interval.contains(Date()))
        }
        ToolbarItem(placement: .topBarTrailing) {
            if loading > 0, report != nil {
                ProgressView()
            } else {
                let title = "\(title(interval)) · \(scope.longTitle)"
                ShareLink(item: report.map { $0.summary(title: title, currency: currency($0)) } ?? "",
                          subject: Text(title), preview: SharePreview(title))
                    .disabled(report?.customers.isEmpty ?? true)
                    .accessibilityLabel("Share summary")
            }
        }
    }

    /// "Thursday, 8 October 2026", "Week 41 · 5–11 Oct 2026", "October 2026", "2026".
    private func title(_ interval: DateInterval) -> String {
        let cal = tracker.calendar
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

    // MARK: Content

    @ViewBuilder private func content(_ report: Report?, _ interval: DateInterval) -> some View {
        if let report {
            if ownOnly || failure != nil {
                Section {
                    if ownOnly {
                        Label("Only your own entries: this API user may not list other users' timesheets.", systemImage: "info.circle")
                    }
                    if let failure {
                        Label("Couldn't reload: \(failure)", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if report.customers.isEmpty {
                Section {
                    ContentUnavailableView("No Time Booked", systemImage: "clock",
                                           description: Text(scope.emptyText(period)))
                }
            } else {
                Section { KPIGrid(report: report, currency: currency(report), calendar: tracker.calendar) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                Section {
                    ReportChart(report: report, calendar: tracker.calendar, color: color)
                }
                if !report.agents.isEmpty { agents(report) }
                breakdown(report)
            }
        } else if let failure {
            Section {
                ContentUnavailableView {
                    Label("Couldn't Load the Report", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { Task { await load(interval, force: true) } }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            Section {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
            .listRowBackground(Color.clear)
        }
    }

    private func agents(_ report: Report) -> some View {
        let total = max(report.agents.values.reduce(0, +), 1)
        return Section {
            ForEach(report.agents.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { tag, seconds in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(.purple).accessibilityHidden(true)
                        Text(String(tag.dropFirst(3))).lineLimit(1)
                        Spacer()
                        Text(DurationText.hours(seconds)).monospacedDigit()
                    }
                    ShareBar(share: Double(seconds) / Double(total), color: .purple)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("AI Agents")
        } footer: {
            if report.scope == .all, report.totalSeconds > 0 {
                Text("\((Double(total) / Double(report.totalSeconds)).formatted(.percent.precision(.fractionLength(0)))) of all hours")
            }
        }
    }

    /// Customer → project → activity, with hours, share and revenue.
    private func breakdown(_ report: Report) -> some View {
        let currency = currency(report)
        func row(_ line: ReportLine, depth: Int, color: Color) -> LineRow {
            LineRow(line: line, total: report.totalSeconds, depth: depth, color: color, currency: currency)
        }
        return Section("Customers") {
            ForEach(report.customers) { customer in
                let path = "c\(customer.id)"
                let tint = color(customer.id)
                DisclosureGroup(isExpanded: expansion(path, depth: 0)) {
                    ForEach(customer.children) { project in
                        DisclosureGroup(isExpanded: expansion("\(path)/\(project.id)", depth: 1)) {
                            ForEach(project.children) { row($0, depth: 2, color: tint) }
                        } label: {
                            row(project, depth: 1, color: tint)
                        }
                    }
                } label: {
                    row(customer, depth: 0, color: tint)
                }
            }
        }
    }

    /// Customers default to expanded, projects to collapsed.
    private func expansion(_ path: String, depth: Int) -> Binding<Bool> {
        Binding {
            (depth == 0) != toggled.contains(path)
        } set: { expanded in
            if expanded == (depth == 0) { toggled.remove(path) } else { toggled.insert(path) }
        }
    }

    // MARK: Data

    private func load(_ interval: DateInterval, force: Bool = false) async {
        guard !tracker.isFixture, force || cache[interval] == nil, let client = tracker.client else { return }
        loading += 1
        failure = nil
        defer { loading -= 1 }
        // The API's `end` is inclusive.
        let end = interval.end.addingTimeInterval(-1)
        do {
            do {
                cache[interval] = try await client.timesheets(user: "all", begin: interval.start, end: end)
            } catch KimaiError.http(403, _) {
                cache[interval] = try await client.timesheets(user: nil, begin: interval.start, end: end)
                ownOnly = true
            }
        } catch {
            // Switching periods cancels the old fetch; that is not an error worth showing.
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    /// Revenue is in the customers' currency; mixed currencies are not converted.
    private func currency(_ report: Report) -> String {
        report.customers.lazy.compactMap { tracker.customer($0.id)?.currency }.first ?? "EUR"
    }

    /// The customer's Kimai colour, else a stable pick from a system palette.
    private func color(_ customerId: Int) -> Color {
        if let color = Brand.color(hex: tracker.customer(customerId)?.color) { return color }
        let palette: [Color] = [.blue, .orange, .purple, .pink, .teal, .yellow, .indigo, .mint, .brown, .cyan]
        return palette[abs(customerId) % palette.count]
    }

    // MARK: Fixture

    /// Five weeks of fictional weekdays for `-ChronatoFixture` (no network), with
    /// the customer/project/activity ids of PhoneTracker.fixture so colours resolve.
    /// A trimmed copy of the Mac's ReportsView.fixtureEntries.
    private func fixtureEntries(now: Date = .now) -> [KimaiTimesheet] {
        let cal = tracker.calendar
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
        func add(_ begin: Date, _ minutes: Int, _ w: Work, user: Int = 1, tags: [String] = []) {
            let ai = user != 1
            out.append(KimaiTimesheet(
                id: 1000 + out.count, begin: begin, end: begin.addingTimeInterval(Double(minutes) * 60),
                duration: minutes * 60, tags: tags, billable: w.rate > 0 && !ai,
                rate: ai ? 0 : w.rate * Double(minutes) / 60, userId: user,
                projectId: w.project, projectName: w.projectName, customerId: w.customer, customerName: w.customerName,
                activityId: w.activity, activityName: w.activityName))
        }
        let today = cal.startOfDay(for: now)
        for offset in (0..<35).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  (2...6).contains(cal.component(.weekday, from: day)) else { continue }
            // Keyed by the date, so a given day looks the same whenever it is rendered.
            let n = cal.ordinality(of: .day, in: .era, for: day) ?? 0
            for (hour, minutes, work) in plans[n % plans.count] {
                let begin = day.addingTimeInterval(hour * 3600)
                if begin.addingTimeInterval(Double(minutes) * 60) <= now { add(begin, minutes, work) }
            }
            for (hour, minutes, work, every) in [(10.0, 75, ops, 2), (14.0, 50, house, 3)] where n % every == 0 {
                let begin = day.addingTimeInterval(hour * 3600)
                if begin.addingTimeInterval(Double(minutes) * 60) <= now { add(begin, minutes, work, user: 2, tags: ["ai-claude-code"]) }
            }
        }
        // The Track tab's running fixture timer counts here too.
        if let active = tracker.active { out.append(active) }
        return out
    }
}

// MARK: - Pieces

/// Total, billable share, revenue (when there is any) and entries, two per row.
private struct KPIGrid: View {
    let report: Report
    let currency: String
    let calendar: Calendar
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let billableShare = report.totalSeconds > 0 ? Double(report.billableSeconds) / Double(report.totalSeconds) : 0
        let activeDays = Set(report.buckets.map { calendar.startOfDay(for: $0.start) }).count
        var cards = [
            KPI(title: "Total", systemImage: "clock", value: DurationText.hours(report.totalSeconds),
                caption: report.period == .week || report.period == .month
                    ? "Ø \(DurationText.hours(report.totalSeconds / max(activeDays, 1))) on \(activeDays) day\(activeDays == 1 ? "" : "s")"
                    : DurationText.short(report.totalSeconds) + " h:mm"),
            KPI(title: "Billable", systemImage: "checkmark.seal", value: billableShare.formatted(.percent.precision(.fractionLength(0))),
                caption: DurationText.hours(report.billableSeconds)),
        ]
        if report.totalRevenue > 0 {
            cards.append(KPI(title: "Revenue", systemImage: "banknote",
                             value: report.totalRevenue.formatted(.currency(code: currency).precision(.fractionLength(0))),
                             caption: report.billableSeconds > 0
                                 ? "Ø " + (report.totalRevenue / (Double(report.billableSeconds) / 3600)).formatted(.currency(code: currency).precision(.fractionLength(0))) + " per hour"
                                 : " "))
        }
        cards.append(KPI(title: "Entries", systemImage: "list.bullet", value: report.entryCount.formatted(),
                         caption: report.customers.count == 1 ? "1 customer" : "\(report.customers.count) customers"))
        // Two per row; one at accessibility text sizes, where half a phone is too
        // narrow. A lone last card (no revenue) takes the whole row.
        let perRow = typeSize.isAccessibilitySize ? 1 : 2
        let rows = stride(from: 0, to: cards.count, by: perRow).map { Array(cards[$0..<min($0 + perRow, cards.count)]) }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        rows[row][column].gridCellColumns(rows[row].count == 1 ? perRow : 1)
                    }
                }
            }
        }
    }
}

private struct KPI: View {
    let title: String
    let systemImage: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).accessibilityHidden(true)
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text(value)
                .font(.title2.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Stacked bars per customer. Tap or drag across the bars to read one slot;
/// the line above the chart shows its hours instead of the period's total.
private struct ReportChart: View {
    let report: Report
    let calendar: Calendar
    let color: (Int) -> Color
    @State private var selected: Date?

    private var unit: Calendar.Component { report.period.bucketComponent }

    var body: some View {
        let slot = selected.flatMap { calendar.dateInterval(of: unit, for: $0) }
        let slotSeconds = slot.map { s in report.buckets.filter { $0.start == s.start }.reduce(0) { $0 + $1.seconds } }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.map { slotTitle($0.start) } ?? "Hours")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(DurationText.hours(slotSeconds ?? report.totalSeconds))
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            Chart {
                ForEach(report.buckets) { bucket in
                    BarMark(x: .value("Date", bucket.start, unit: unit),
                            y: .value("Hours", Double(bucket.seconds) / 3600))
                        .foregroundStyle(by: .value("Customer", bucket.customerName))
                        .opacity(slot == nil || slot?.start == bucket.start ? 1 : 0.35)
                }
            }
            .chartForegroundStyleScale(domain: report.customers.map(\.name), range: report.customers.map { color($0.id) })
            .chartXScale(domain: report.interval.start...report.interval.end)
            .chartXAxis {
                AxisMarks(values: .stride(by: unit)) { value in
                    if let date = value.as(Date.self), showsLabel(date) {
                        AxisValueLabel(format: format, centered: true)
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let h = value.as(Double.self) { Text("\(h.formatted()) h") } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
            .chartXSelection(value: $selected)
            // Slots and labels in the Kimai user's time zone, as Report.build buckets them.
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .frame(height: 240)
            .accessibilityLabel("Hours per customer")
        }
        .padding(.vertical, 8)
        .sensoryFeedback(.selection, trigger: slot?.start)
    }

    /// One label per slot is too many on a phone for days (24) and months (31).
    private func showsLabel(_ date: Date) -> Bool {
        switch report.period {
        case .day: calendar.component(.hour, from: date) % 6 == 0
        case .month: (calendar.component(.day, from: date) - 1) % 7 == 0
        case .week, .year: true
        }
    }

    private var format: Date.FormatStyle {
        switch report.period {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day()
        case .year: .dateTime.month(.narrow)
        }
    }

    /// "14:00–15:00", "Tue 6 Oct", "March".
    private func slotTitle(_ start: Date) -> String {
        let style = Date.FormatStyle(locale: .current, calendar: calendar, timeZone: calendar.timeZone)
        switch report.period {
        case .day:
            let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
            return "\(start.formatted(style.hour().minute())) – \(end.formatted(style.hour().minute()))"
        case .week, .month: return start.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
        case .year: return start.formatted(style.month(.wide).year())
        }
    }
}

/// One breakdown line: name and hours, then its share of the total (and revenue).
private struct LineRow: View {
    let line: ReportLine
    let total: Int
    let depth: Int
    let color: Color
    let currency: String

    var body: some View {
        let share = total > 0 ? Double(line.seconds) / Double(total) : 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if depth == 0 {
                    Image(systemName: "circle.fill").font(.system(size: 10)).foregroundStyle(color).accessibilityHidden(true)
                }
                Text(line.name)
                    .fontWeight(depth == 0 ? .semibold : .regular)
                    .foregroundStyle(depth == 2 ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(DurationText.hours(line.seconds))
                    .monospacedDigit()
                    .foregroundStyle(depth == 2 ? .secondary : .primary)
            }
            HStack(spacing: 8) {
                ShareBar(share: share, color: color.opacity(depth == 0 ? 1 : 0.55))
                Text(share.formatted(.percent.precision(.fractionLength(0))))
                if line.revenue > 0 {
                    Text(line.revenue.formatted(.currency(code: currency).precision(.fractionLength(0))))
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule().fill(color).frame(width: max(3, geo.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private extension ReportPeriod {
    var title: String { rawValue.capitalized }
}

private extension ReportScope {
    var longTitle: String {
        switch self {
        case .me: "My hours"
        case .ai: "AI agents"
        case .all: "Everyone"
        }
    }

    var systemImage: String {
        switch self {
        case .me: "person"
        case .ai: "sparkles"
        case .all: "person.2"
        }
    }

    func emptyText(_ period: ReportPeriod) -> String {
        switch self {
        case .me: "You have not tracked any time this \(period.rawValue)."
        case .ai: "No AI agent booked time this \(period.rawValue)."
        case .all: "Nobody tracked time this \(period.rawValue)."
        }
    }
}
