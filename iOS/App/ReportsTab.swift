import Charts
import ChronatoCore
import SwiftUI

/// The Reports tab (spec §7): hours per customer by day, week, month or year,
/// for me, the AI agents or everyone, restrained like the Mac's Reports
/// window. Same data and maths (Sources/Chronato/ReportsView.swift):
/// KimaiClient.timesheets(user: "all") (own entries only when Kimai answers
/// 403) → Report.build.
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
                Section {
                    Picker("Period", selection: $period) {
                        ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Section { heading(interval) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
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

    // MARK: Heading and toolbar

    /// ‹ the period's title, once, over the scope ›.
    private func heading(_ interval: DateInterval) -> some View {
        HStack(spacing: 0) {
            stepButton(-1, interval)
            VStack(spacing: 2) {
                Text(title(interval))
                    .font(Studio.Typography.title)
                    .foregroundStyle(Studio.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(scope.longTitle)
                    .font(Studio.Typography.secondary)
                    .foregroundStyle(Studio.textSecondary)
            }
            .frame(maxWidth: .infinity)
            stepButton(1, interval).disabled(interval.end > Date())
        }
        .buttonStyle(.borderless)
    }

    private func stepButton(_ direction: Int, _ interval: DateInterval) -> some View {
        Button {
            anchor = tracker.calendar.date(byAdding: period.component, value: direction, to: interval.start) ?? anchor
        } label: {
            Label(direction < 0 ? "Previous \(period.rawValue)" : "Next \(period.rawValue)",
                  systemImage: direction < 0 ? "chevron.left" : "chevron.right")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ report: Report?, _ interval: DateInterval) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Today") { anchor = Date() }
                .disabled(interval.contains(Date()))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Show", selection: $scope) {
                    ForEach(ReportScope.allCases) { Label($0.longTitle, systemImage: $0.systemImage).tag($0) }
                }
            } label: {
                Label("Show", systemImage: scope.systemImage)
            }
            .accessibilityValue(scope.longTitle)
            .accessibilityHint("Your hours, AI agents, or everyone")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if loading > 0, report != nil {
                ProgressView()
            } else {
                let title = "\(title(interval)) · \(scope.longTitle)"
                ShareLink(item: report.map { $0.summary(title: title, currency: currency($0)) } ?? "",
                          subject: Text(title), preview: SharePreview(title)) {
                    Label("Share Summary", systemImage: "square.and.arrow.up")
                }
                .disabled(report?.customers.isEmpty ?? true)
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
            if (ownOnly && scope != .me) || failure != nil {
                Section {
                    if ownOnly, scope != .me {
                        Label {
                            Text("Only your own entries: this API user may not see other users' timesheets.")
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .foregroundStyle(Studio.textSecondary)
                    }
                    // A reload failed but the cached report is still shown.
                    if let failure { Problem("Couldn't reload: \(failure)") }
                }
                .font(Studio.Typography.secondary)
            }
            if report.customers.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label { Text("No time booked").foregroundStyle(Studio.textPrimary) } icon: { Image(systemName: "clock") }
                    } description: {
                        Text(scope.emptyText(period)).foregroundStyle(Studio.textSecondary)
                    }
                }
            } else {
                Section {
                    ReportChart(report: report, calendar: tracker.calendar, color: color)
                }
                figures(report)
                if !report.agents.isEmpty { agents(report) }
                breakdown(report)
            }
        } else if let failure {
            Section {
                ContentUnavailableView {
                    Label {
                        Text("Couldn't load the report").foregroundStyle(Studio.textPrimary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Studio.errorInk)
                    }
                } description: {
                    Text(failure).foregroundStyle(Studio.textSecondary)
                } actions: {
                    Button("Try Again") { Task { await load(interval, force: true) } }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
            .listRowBackground(Color.clear)
        }
    }

    /// Billable share, revenue (when there is any) and entries, as rows: the
    /// Mac's KPI tiles without the tiles. Total is over the chart.
    private func figures(_ report: Report) -> some View {
        let currency = currency(report)
        let billableShare = report.totalSeconds > 0 ? Double(report.billableSeconds) / Double(report.totalSeconds) : 0
        return Section {
            FigureRow(title: "Billable", value: billableShare.formatted(.percent.precision(.fractionLength(0))),
                      caption: DurationText.hours(report.billableSeconds))
            if report.totalRevenue > 0 {
                FigureRow(title: "Revenue", value: report.totalRevenue.formatted(.currency(code: currency).precision(.fractionLength(0))),
                          caption: report.billableSeconds > 0
                              ? "Ø " + (report.totalRevenue / (Double(report.billableSeconds) / 3600)).formatted(.currency(code: currency).precision(.fractionLength(0))) + " per billable hour"
                              : nil)
            }
            FigureRow(title: "Entries", value: report.entryCount.formatted(),
                      caption: report.customers.count == 1 ? "1 customer" : "\(report.customers.count) customers")
        }
    }

    /// Neutral bars: agents are not customers.
    private func agents(_ report: Report) -> some View {
        let total = max(report.agents.values.reduce(0, +), 1)
        return Section {
            ForEach(report.agents.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { tag, seconds in
                VStack(alignment: .leading, spacing: Studio.Space.s) {
                    HStack {
                        Label {
                            Text(String(tag.dropFirst(3))).foregroundStyle(Studio.textPrimary).lineLimit(1)
                        } icon: {
                            Image(systemName: "sparkles").foregroundStyle(Studio.textSecondary)
                        }
                        Spacer()
                        Text(DurationText.hours(seconds)).monospacedDigit().foregroundStyle(Studio.textPrimary)
                    }
                    ShareBar(share: Double(seconds) / Double(total), color: Studio.controlBorder)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("AI agents")
        } footer: {
            if report.scope == .all, report.totalSeconds > 0 {
                Text("\((Double(total) / Double(report.totalSeconds)).formatted(.percent.precision(.fractionLength(0)))) of all hours")
                    .foregroundStyle(Studio.textSecondary)
            }
        }
    }

    /// Customer → project → activity, with hours, share and revenue: the Mac's
    /// outline table as a native outline list.
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

/// One report figure: what it is (and a caption) leading, the value trailing.
private struct FigureRow: View {
    let title: String
    let value: String
    let caption: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Studio.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Studio.textPrimary)
                if let caption {
                    Text(caption).font(Studio.Typography.secondary).monospacedDigit().foregroundStyle(Studio.textSecondary)
                }
            }
            Spacer(minLength: Studio.Space.s)
            Text(value)
                .font(Studio.Typography.figure)
                .foregroundStyle(Studio.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Total over the stacked bars per customer. Tap or drag across the bars to
/// read one slot; the figure above shows its hours instead of the period's.
/// Restrained as on the Mac: customer colours muted to 85 %, a hairline grid,
/// and one accent, the axis label of the slot holding now.
private struct ReportChart: View {
    let report: Report
    let calendar: Calendar
    let color: (Int) -> Color
    @State private var selected: Date?

    private var unit: Calendar.Component { report.period.bucketComponent }

    var body: some View {
        let slot = selected.flatMap { calendar.dateInterval(of: unit, for: $0) }
        let slotSeconds = slot.map { s in report.buckets.filter { $0.start == s.start }.reduce(0) { $0 + $1.seconds } }
        let now = Date()
        let currentSlot = report.interval.contains(now) ? calendar.dateInterval(of: unit, for: now)?.start : nil
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.map { slotTitle($0.start) } ?? "Total")
                    .font(Studio.Typography.secondary)
                    .foregroundStyle(Studio.textSecondary)
                Text(DurationText.hours(slotSeconds ?? report.totalSeconds))
                    .font(Studio.Typography.figure)
                    .foregroundStyle(Studio.textPrimary)
                // Kept in place while a slot is read, so the chart does not jump.
                Text(caption)
                    .font(Studio.Typography.secondary)
                    .monospacedDigit()
                    .foregroundStyle(Studio.textSecondary)
                    .opacity(slot == nil ? 1 : 0)
            }
            .accessibilityElement(children: .combine)
            Chart(report.buckets) { bucket in
                BarMark(x: .value("Date", bucket.start, unit: unit),
                        y: .value("Hours", Double(bucket.seconds) / 3600))
                    .foregroundStyle(by: .value("Customer", bucket.customerName))
                    .cornerRadius(2)
                    .opacity(slot == nil || slot?.start == bucket.start ? 1 : 0.35)
            }
            .chartForegroundStyleScale(domain: report.customers.map(\.name), range: report.customers.map { color($0.id).opacity(0.85) })
            .chartXScale(domain: report.interval.start...report.interval.end)
            .chartXAxis {
                // A label (empty or not) on every slot: `centered` centres it up to the
                // next mark that has one, so a skipped label would shift the others.
                AxisMarks(values: .stride(by: unit)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            let current = date == currentSlot
                            if current || showsLabel(date, near: currentSlot) {
                                Text(date, format: format)
                                    .font(current ? Studio.Typography.numeral.weight(.semibold) : Studio.Typography.numeral)
                                    .foregroundStyle(current ? Studio.accentInk : Studio.textSecondary)
                            }
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
            // A legend that wraps eats the plot; the breakdown below has the same colour dots.
            .chartLegend(report.customers.count > 8 ? .hidden : .visible)
            .chartLegend(position: .top, alignment: .leading, spacing: Studio.Space.m) { legend }
            .chartXSelection(value: $selected)
            // Slots and labels in the Kimai user's time zone, as Report.build buckets them.
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .frame(height: 220)
            // Axis labels and legend grow only so far: at accessibility sizes they
            // would crowd out the bars. The figures above and the breakdown below scale.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityLabel("Hours per customer")
        }
        .padding(.vertical, Studio.Space.s)
        .sensoryFeedback(.selection, trigger: slot?.start)
    }

    /// "Ø 5.26 h on 5 days" for a week or month, else the total as h:mm.
    private var caption: String {
        let activeDays = Set(report.buckets.map { calendar.startOfDay(for: $0.start) }).count
        return report.period == .week || report.period == .month
            ? "Ø \(DurationText.hours(report.totalSeconds / max(activeDays, 1))) on \(activeDays) day\(activeDays == 1 ? "" : "s")"
            : DurationText.short(report.totalSeconds) + " h:mm"
    }

    /// One "● Customer" pair after another, wrapping only between customers.
    private var legend: some View {
        let entries = report.customers.map { customer in
            let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 8)).foregroundStyle(color(customer.id).opacity(0.85))
            return Text("\(dot)\u{00A0}\(customer.name.replacingOccurrences(of: " ", with: "\u{00A0}"))")
        }
        return entries.dropFirst().reduce(entries.first ?? Text("")) { Text("\($0)   \($1)") }
            .font(Studio.Typography.numeral)
            .foregroundStyle(Studio.textSecondary)
            .accessibilityLabel("Customers: " + report.customers.map(\.name).joined(separator: ", "))
    }

    /// One label per slot is too many on a phone for hours (24) and days of a
    /// month (31): every sixth hour, every seventh day, and none next to the
    /// slot holding now, whose label is always shown.
    private func showsLabel(_ date: Date, near current: Date?) -> Bool {
        let regular = switch report.period {
        case .day: calendar.component(.hour, from: date) % 6 == 0
        case .month: (calendar.component(.day, from: date) - 1) % 7 == 0
        case .week, .year: true
        }
        guard regular, report.period == .day || report.period == .month, let current else { return regular }
        return abs(calendar.dateComponents([unit], from: current, to: date).value(for: unit) ?? 0) > 1
    }

    private var format: Date.FormatStyle {
        switch report.period {
        case .day: .dateTime.hour(.twoDigits(amPM: .omitted))
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day()
        case .year: .dateTime.month(.narrow)
        }
    }

    /// "14:00–15:00", "Tue 6 Oct", "March 2026".
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
/// Customers medium with their colour dot, activities in secondary ink.
private struct LineRow: View {
    let line: ReportLine
    let total: Int
    let depth: Int
    let color: Color
    let currency: String

    var body: some View {
        let share = total > 0 ? Double(line.seconds) / Double(total) : 0
        let ink = depth == 2 ? Studio.textSecondary : Studio.textPrimary
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
                if depth == 0 {
                    Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(color).accessibilityHidden(true)
                }
                Text(line.name)
                    .fontWeight(depth == 0 ? .medium : .regular)
                    .lineLimit(1)
                Spacer(minLength: Studio.Space.s)
                Text(DurationText.hours(line.seconds)).monospacedDigit()
            }
            .foregroundStyle(ink)
            HStack(spacing: Studio.Space.s) {
                ShareBar(share: share, color: color.opacity(depth == 0 ? 1 : 0.55))
                Text(share.formatted(.percent.precision(.fractionLength(0))))
                if line.revenue > 0 {
                    Text(line.revenue.formatted(.currency(code: currency).precision(.fractionLength(0))))
                }
            }
            .font(Studio.Typography.numeral)
            .foregroundStyle(Studio.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Track in `lineSubtle`, fill in the given colour.
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
