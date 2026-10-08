import AppKit
import ChronatoCore
import SwiftUI

// MARK: - Menu-bar label

/// Menu-bar label: glyph + elapsed h:mm while running (⏸ when paused).
struct MenuBarLabel: View {
    @Environment(TrackerStore.self) private var store
    @AppStorage(Prefs.showCustomerInMenuBar) private var showCustomer = false

    var body: some View {
        let paused = !store.isRunning && store.paused != nil
        let glyph = Brand.menuBarGlyph(running: store.isRunning)
        Image(nsImage: Self.compose(glyph: glyph, paused: paused, title: title))
            .accessibilityLabel(spoken(paused: paused))
    }

    /// "1:05" or "1:05  Northwind Trade…"; nil when nothing runs.
    private var title: String? {
        guard let active = store.active else { return nil }
        // Minutes, not seconds: the label (an NSImage) redraws once a minute.
        let time = DurationText.short(store.elapsedMinutes * 60)
        let name = EntryNames(active, in: store).customer
        guard showCustomer, !name.isEmpty else { return time }
        return time + "  " + (name.count > 16 ? name.prefix(15) + "…" : name)
    }

    private func spoken(paused: Bool) -> String {
        guard let active = store.active else { return paused ? "Chronato, paused" : "Chronato" }
        let customer = EntryNames(active, in: store).customer
        return ["Chronato, running \(DurationText.short(store.elapsedMinutes * 60))", customer].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Glyph, pause bars and title drawn into one template image. A MenuBarExtra
    /// label ignores font modifiers (no monospaced digits) and shows a single
    /// image, so we compose it ourselves; the snapshot then shows exactly what
    /// the menu bar draws. Nonisolated: AppKit may call the drawing block anywhere.
    nonisolated static func compose(glyph: NSImage, paused: Bool, title: String?) -> NSImage {
        let pause = paused
            ? NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .heavy))
            : nil
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let text = title.map { NSAttributedString(string: $0, attributes: [.font: font]) }
        let textSize = text?.size() ?? .zero
        let height = max(glyph.size.height, 18)
        var width = glyph.size.width
        if let pause { width += 2 + pause.size.width }
        if text != nil { width += 4 + ceil(textSize.width) }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            func draw(_ part: NSImage, at x: CGFloat) {
                let y = ((height - part.size.height) / 2).rounded()
                part.draw(in: NSRect(origin: NSPoint(x: x, y: y), size: part.size))
            }
            draw(glyph, at: 0)
            if let pause { draw(pause, at: glyph.size.width + 2) }
            text?.draw(at: NSPoint(x: glyph.size.width + 4, y: ((height - textSize.height) / 2).rounded()))
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Panel

/// The window that drops down from the menu bar.
struct MenuPanel: View {
    @Environment(TrackerStore.self) private var store
    @State private var showSwitch = false
    /// Height of everything between header and totals, measured: a MenuBarExtra
    /// window can't be resized or scrolled, so that part scrolls once it would
    /// not fit on the screen, and header, totals and footer stay reachable.
    @State private var middleHeight: CGFloat = 0
    /// The snapshot "panel-scrolled" passes a small value; else the screen decides.
    var maxMiddleHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header()
            ScrollView {
                middle
                    .padding(.horizontal, 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { middleHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(middleHeight, maxMiddleHeight ?? Self.screenMiddleHeight))
            // Full panel width, so the hover background of Recent rows and the scroller are not clipped.
            .padding(.horizontal, -14)
            if store.connectionState != .unconfigured {
                Divider()
                Totals()
            }
            UpdateReminderButton()
            Divider()
            Footer()
        }
        .padding(14)
        .frame(width: 340)
        .task { await store.refresh() }
    }

    /// Screen height minus menu bar, Dock and the pinned parts (padding, header,
    /// totals, footer: about 150 pt).
    /// ponytail: fixed allowance; measure the pinned parts if they grow.
    private static var screenMiddleHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 170
    }

    @ViewBuilder private var middle: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = store.lastError {
                Banner(icon: "exclamationmark.triangle.fill", tint: .red, message: error) {
                    Button { store.lastError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
            }
            if store.connectionState == .unconfigured {
                ConnectPrompt()
            } else {
                if case let .offline(message) = store.connectionState {
                    Banner(icon: "wifi.exclamationmark", tint: .orange, message: message) {
                        Button("Retry") { Task { await store.refresh() } }
                            .controlSize(.small)
                            .disabled(store.isBusy)
                    }
                }
                // `.id`: a new entry gets a fresh card (and note field state).
                if let entry = store.active {
                    RunningCard(entry: entry).id(entry.id)
                } else if let session = store.paused {
                    PausedCard(session: session).id(session.pausedAt)
                }
                if store.isRunning || store.paused != nil {
                    DisclosureGroup(isExpanded: $showSwitch) {
                        StartForm(switching: true) { showSwitch = false }.padding(.top, 8)
                    } label: {
                        // On macOS only the chevron toggles a DisclosureGroup; let the words do it too.
                        Button(store.isRunning ? "Switch to…" : "Start something else…") {
                            withAnimation { showSwitch.toggle() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    StartForm().card()
                }
                if !store.recent.isEmpty {
                    ListSection("Recent") {
                        VStack(spacing: 0) {
                            ForEach(store.recent.prefix(6)) { RecentRow(entry: $0) }
                        }
                        .padding(.horizontal, -8)
                    }
                }
                if !store.agentSessions.isEmpty {
                    ListSection("AI agents") {
                        ForEach(store.agentSessions) { AgentRow(session: $0) }
                    }
                }
            }
        }
    }
}

// MARK: - Header and banners

private struct Header: View {
    @Environment(TrackerStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Text("Chronato").font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.isBusy { ProgressView().controlSize(.mini) }
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(short).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail)
        }
    }

    private var color: Color {
        switch store.connectionState {
        case .online: .green
        case .connecting: .yellow
        case .offline: .orange
        case .unconfigured: .secondary
        }
    }

    private var short: String {
        switch store.connectionState {
        case .online: store.connection?.url.host() ?? "Connected"
        case .connecting: "Connecting…"
        case .offline: "Offline"
        case .unconfigured: "Not connected"
        }
    }

    private var detail: String {
        switch store.connectionState {
        case .online:
            let who = store.me.map { " as \($0.displayName)" } ?? ""
            let version = store.serverVersion.map { " (Kimai \($0))" } ?? ""
            return "Connected to \(store.connection?.url.host() ?? "Kimai")\(who)\(version)"
        case .connecting: return "Connecting to Kimai…"
        case let .offline(message): return message
        case .unconfigured: return "Not connected to Kimai"
        }
    }
}

/// A tinted notice with trailing actions (offline, errors).
private struct Banner<Actions: View>: View {
    let icon: String
    let tint: Color
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            actions
        }
        .card(tint: tint, padding: 10)
    }
}

private struct ConnectPrompt: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "stopwatch").font(.system(size: 34, weight: .light)).foregroundStyle(Brand.accent)
            Text("Connect to your Kimai").font(.headline)
            Text("Chronato tracks your time in a self-hosted Kimai. You need its address and an API token.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect to Kimai…") {
                UserDefaults.standard.set(SettingsTab.connection.rawValue, forKey: Prefs.settingsTab)
                openSettings()
                NSApp.activate()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - Current timer

private struct RunningCard: View {
    @Environment(TrackerStore.self) private var store
    let entry: KimaiTimesheet
    @State private var note: String

    init(entry: KimaiTimesheet) {
        self.entry = entry
        _note = State(initialValue: entry.description ?? "")
    }

    var body: some View {
        let names = EntryNames(entry, in: store)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CustomerLabel(names: names)
                Spacer()
                Text("since \(sinceText(entry.begin))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            ProjectActivity(names: names)
            Elapsed()
            if let end = store.pendingStopAt {
                // An auto-pause decided while Kimai was unreachable: the time is no longer counting.
                Label("Ends at \(sinceText(end)) once Kimai is reachable", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // Every change goes to the store as a draft: whatever ends or replaces
            // this entry (pause, stop, switch, hot key, auto-pause) saves it first.
            NoteField(text: $note, saved: entry.description, draftFor: entry.id) { [id = entry.id] in $0.active?.id == id }
            HStack {
                Button { Task { await store.pause() } } label: {
                    Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }
                Button { Task { await store.stop() } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .controlSize(.large)
            .disabled(store.isBusy)
            .padding(.top, 4)
        }
        .card(tint: Brand.accent)
    }
}

/// Own view so only this text redraws every second.
private struct Elapsed: View {
    @Environment(TrackerStore.self) private var store

    var body: some View {
        Text(DurationText.long(store.elapsedSeconds))
            .font(.system(size: 34, weight: .light))
            .monospacedDigit()
            .foregroundStyle(Brand.accent)
            .accessibilityLabel("Elapsed \(DurationText.long(store.elapsedSeconds))")
    }
}

private struct PausedCard: View {
    @Environment(TrackerStore.self) private var store
    let session: TrackerStore.PausedSession
    @State private var note: String

    init(session: TrackerStore.PausedSession) {
        self.session = session
        _note = State(initialValue: session.description ?? "")
    }

    var body: some View {
        let names = EntryNames(session, in: store)
        VStack(alignment: .leading, spacing: 8) {
            if let away = store.awayNotice {
                // "You were away 14:02–14:27 (25 min)", with dates when it crosses midnight.
                Label("You were away \(away.span) (\(minutes(away.seconds)))", systemImage: "moon.zzz.fill")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Label("Paused", systemImage: "pause.circle.fill").font(.headline)
                    Spacer()
                    Text("since \(sinceText(session.pausedAt))").font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
            CustomerLabel(names: names)
            ProjectActivity(names: names)
            Text("\(DurationText.short(session.workedSeconds)) worked before the break")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if store.awayNotice == nil {
                NoteField(text: $note, saved: session.description) { [at = session.pausedAt] in
                    $0.active == nil && $0.paused?.pausedAt == at
                }
            } else if let note = session.description, !note.isEmpty {
                Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            buttons(names).controlSize(.large).disabled(store.isBusy).padding(.top, 4)
        }
        .card()
    }

    @ViewBuilder private func buttons(_ names: EntryNames) -> some View {
        if let away = store.awayNotice {
            VStack(spacing: 8) {
                HStack {
                    Button { Task { await store.resolveAway(.resume) } } label: { Text("Resume").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Start again now; the time away is not tracked")
                    // A day or more away is never counted (TrackingPolicy.countAway).
                    if away.countAway != .tooLong {
                        Button { countAway(away, names) } label: {
                            Text("Count \(minutes(away.seconds))\(away.countAway == .allowed ? "" : "…")")
                                .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                        }
                        .help("Start again from \(sinceText(away.since)), so the time away counts as work")
                    }
                }
                HStack {
                    Button { Task { await store.resolveAway(.stayPaused) } } label: { Text("Stay paused").frame(maxWidth: .infinity) }
                        .help("Keep the timer paused")
                    Button { Task { await store.resolveAway(.stop) } } label: { Text("Stop").frame(maxWidth: .infinity) }
                        .help("End the paused session; nothing more is tracked")
                }
            }
        } else {
            HStack {
                Button { Task { await saveNote(note, over: session.description, in: store); await store.resume() } } label: {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button { Task { await saveNote(note, over: session.description, in: store); await store.stop() } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// More than 4 h away is booked only after the user saw the span and said yes.
    /// Decided at the click: the time away grows while the card is open.
    private func countAway(_ away: TrackerStore.AwayNotice, _ names: EntryNames) {
        let needsConfirmation = TrackingPolicy.countAway(since: away.since, now: Date()) == .needsConfirmation
        if needsConfirmation {
            let alert = NSAlert()
            alert.messageText = "Count \(minutes(Date().timeIntervalSince(away.since))) away as work?"
            alert.informativeText = "You were away \(away.span). \(names.project) · \(names.activity) then runs from "
                + "\(sinceText(away.since)), and all of that time is booked in Kimai."
            alert.addButton(withTitle: "Count It")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await store.resolveAway(.resumeCountingAway, confirmed: needsConfirmation) }
    }
}

/// The running (or paused) entry's note. Saves on Return, on focus loss and when
/// the panel closes (its window resigns key; clicking a button keeps the focus).
/// Only while `isCurrent`: `setDescription` writes to whatever runs now, and a
/// field whose entry was just replaced must not put its text on the new one.
/// For the running entry (`draftFor`) every edit is also the store's draft, which
/// the store saves before that entry ends or is replaced, whoever ends it.
/// The paused card's buttons save first (`saveNote`); that note is local only.
private struct NoteField: View {
    @Environment(TrackerStore.self) private var store
    @Binding var text: String
    let saved: String?
    var draftFor: Int?
    let isCurrent: @MainActor (TrackerStore) -> Bool
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Add a note", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: text) { if let draftFor, isCurrent(store) { store.setNoteDraft(text, for: draftFor) } }
            .onChange(of: focused) { if !focused { commit() } }
            .onChange(of: saved) { if !focused { text = saved ?? "" } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in commit() }
    }

    private func commit() {
        guard isCurrent(store) else { return }
        Task { await saveNote(text, over: saved, in: store) }
    }
}

/// Sends the note to the running entry (or paused session) if it changed.
@MainActor private func saveNote(_ text: String, over saved: String?, in store: TrackerStore) async {
    let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if note != (saved ?? "") { await store.setDescription(note) }
}

// MARK: - Start form

private struct StartForm: View {
    @Environment(TrackerStore.self) private var store
    /// Shown under a running/paused card: Return belongs to that card's note
    /// field, so this form has no default button and starts from its own note field.
    var switching = false
    var onStart: () -> Void = {}

    @AppStorage(Prefs.lastCustomerId) private var customerId: Int?
    @AppStorage(Prefs.lastProjectId) private var projectId: Int?
    @AppStorage(Prefs.lastActivityId) private var activityId: Int?
    @State private var note = ""

    private var customers: (recent: [KimaiCustomer], others: [KimaiCustomer]) { store.startableCustomers }
    /// The remembered customer while it still has something to start.
    private var selectedCustomer: Int? {
        let (recent, others) = customers
        return (recent + others).first { $0.id == customerId }?.id
    }
    private var projects: [KimaiProject] { selectedCustomer.map { store.startableProjects(forCustomer: $0) } ?? [] }
    /// The remembered project if it belongs to the customer, else the customer's only one.
    private var selectedProject: Int? {
        if let projectId, projects.contains(where: { $0.id == projectId }) { return projectId }
        return projects.count == 1 ? projects[0].id : nil
    }
    private var activities: [KimaiActivity] { selectedProject.map { store.activities(forProject: $0) } ?? [] }
    private var selectedActivity: Int? { activities.contains { $0.id == activityId } ? activityId : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                row("Customer") {
                    // Recently used customers first; the pop-up's type-select finds the rest.
                    let (recent, others) = customers
                    Picker("Customer", selection: Binding(get: { selectedCustomer }, set: { customerId = $0 })) {
                        if selectedCustomer == nil { Text("Choose…").tag(Int?.none) }
                        ForEach(recent) { Text($0.name).tag(Int?.some($0.id)) }
                        if !recent.isEmpty, !others.isEmpty { Divider() }
                        ForEach(others) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                }
                row("Project") {
                    Picker("Project", selection: Binding(get: { selectedProject }, set: { projectId = $0 })) {
                        if selectedProject == nil { Text(projects.isEmpty ? "—" : "Choose…").tag(Int?.none) }
                        ForEach(projects) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    .disabled(projects.isEmpty)
                }
                row("Activity") {
                    Picker("Activity", selection: Binding(get: { selectedActivity }, set: { activityId = $0 })) {
                        if selectedActivity == nil { Text(activities.isEmpty ? "—" : "Choose…").tag(Int?.none) }
                        ForEach(activities) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    .disabled(activities.isEmpty)
                }
                row("Note") {
                    TextField("Optional", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if switching { start() } }
                }
            }
            Button(action: start) {
                Label(switching ? "Switch" : "Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(switching ? nil : .defaultAction)
            .disabled(selectedProject == nil || selectedActivity == nil || store.isBusy)
        }
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func start() {
        guard let project = selectedProject, let activity = selectedActivity, !store.isBusy else { return }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        projectId = project
        activityId = activity
        // Note and form stay until Kimai took the start: a failure must not lose the typing.
        Task {
            guard await store.start(projectId: project, activityId: activity, description: text.isEmpty ? nil : text) == nil else { return }
            note = ""
            onStart()
        }
    }
}

extension TrackerStore {
    /// The customer's projects that have something to start (at least one activity).
    func startableProjects(forCustomer id: Int) -> [KimaiProject] {
        projects(forCustomer: id).filter { !activities(forProject: $0.id).isEmpty }
    }

    /// Customers with a startable project for the start form: the ones in Recent
    /// first (newest first), then the others by name.
    var startableCustomers: (recent: [KimaiCustomer], others: [KimaiCustomer]) {
        let usable = customers.filter { !startableProjects(forCustomer: $0.id).isEmpty }
        var recentIds: [Int] = []
        for entry in recent {
            if let id = entry.customerId ?? project(entry.projectId)?.customer, !recentIds.contains(id) { recentIds.append(id) }
        }
        return (recentIds.compactMap { id in usable.first { $0.id == id } },
                usable.filter { !recentIds.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}

// MARK: - Lists

private struct RecentRow: View {
    @Environment(TrackerStore.self) private var store
    let entry: KimaiTimesheet
    @State private var hovered = false

    var body: some View {
        let names = EntryNames(entry, in: store)
        Button { Task { await store.startAgain(entry) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Dot(hex: store.customer(names.customerId)?.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(names.activity).lineLimit(1)
                    // Middle truncation keeps the project visible behind a long customer name.
                    Text("\(names.customer) · \(names.project)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    // Often the only difference between two rows: secondary, not tertiary (contrast).
                    if let note = entry.description, !note.isEmpty {
                        Text(note).font(.caption).italic().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(hovered ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(hovered ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(store.isBusy)
        .help("Start again: \(names.full)" + (entry.description.map { " — \($0)" } ?? ""))
        .accessibilityLabel("Start \(names.activity), \(names.customer), \(names.project)" + (entry.description.map { ", \($0)" } ?? ""))
    }
}

private struct AgentRow: View {
    @Environment(TrackerStore.self) private var store
    let session: AgentSession

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: session.lastError == nil ? "sparkles" : "exclamationmark.triangle.fill")
                .foregroundStyle(session.lastError == nil ? Color.secondary : Color.orange)
            Text(session.agentName).fontWeight(.medium).lineLimit(1)
            if let task = session.activityName ?? session.projectName {
                Text("· \(task)").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // Kimai refused it: not an agent still at work. A stopped one no longer counts up.
            Text(session.lastError == nil ? minutes((session.stoppedAt ?? store.now).timeIntervalSince(session.begin)) : "Not booked")
                .monospacedDigit().foregroundStyle(.secondary).fixedSize()
        }
        .help(session.lastError.map { "Kimai refused \"\(session.description)\": \($0)" }
            ?? [session.agentName, session.customerName, session.projectName, session.activityName].compactMap { $0 }.joined(separator: " › ")
                + " — " + session.description)
        .contextMenu {
            if session.lastError != nil {
                Button("Discard Session", role: .destructive) {
                    AgentSessions.remove(session.id)
                    Task { await store.refresh() }
                }
            }
        }
    }
}

private struct Totals: View {
    @Environment(TrackerStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Text("Today").foregroundStyle(.secondary)
            Text(DurationText.short(store.todaySeconds)).monospacedDigit()
            Text("·").foregroundStyle(.tertiary)
            Text("Week").foregroundStyle(.secondary)
            Text(DurationText.short(store.weekSeconds)).monospacedDigit()
        }
        .font(.callout)
    }
}

private struct Footer: View {
    @Environment(TrackerStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 14) {
            Button {
                openWindow(id: "reports")
                NSApp.activate()
            } label: {
                Label("Reports", systemImage: "chart.bar.xaxis")
            }
            .keyboardShortcut("r")
            Button { store.openKimai() } label: {
                Label("Open Kimai", systemImage: "arrow.up.forward.square")
            }
            .disabled(store.connection == nil)
            Spacer()
            CheckForUpdatesButton()
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",")
            .help("Settings…")
            .accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit Chronato")
                .accessibilityLabel("Quit Chronato")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Small parts

/// Display names for an entry. `/timesheets/active` may return bare ids, so
/// missing names come from the catalog.
private struct EntryNames {
    var customerId: Int?
    var customer: String
    var project: String
    var activity: String

    @MainActor init(_ entry: KimaiTimesheet, in store: TrackerStore) {
        customerId = entry.customerId ?? store.project(entry.projectId)?.customer
        customer = entry.customerName ?? store.customer(customerId)?.name ?? ""
        project = entry.projectName ?? store.project(entry.projectId)?.name ?? "Project \(entry.projectId)"
        activity = entry.activityName ?? store.activity(entry.activityId)?.name ?? "Activity \(entry.activityId)"
    }

    @MainActor init(_ session: TrackerStore.PausedSession, in store: TrackerStore) {
        customerId = store.project(session.projectId)?.customer
        customer = session.customerName ?? store.customer(customerId)?.name ?? ""
        project = session.projectName ?? store.project(session.projectId)?.name ?? "Project \(session.projectId)"
        activity = session.activityName ?? store.activity(session.activityId)?.name ?? "Activity \(session.activityId)"
    }

    /// "Customer › Project › Activity" for tooltips.
    var full: String { [customer, project, activity].filter { !$0.isEmpty }.joined(separator: " › ") }
}

/// The cards' "Project · Activity": up to two lines, truncated in the middle so a
/// long project name cannot push the activity out; the tooltip has every name.
private struct ProjectActivity: View {
    let names: EntryNames

    var body: some View {
        Text("\(names.project) · \(names.activity)")
            .font(.headline)
            .lineLimit(2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .help(names.full)
    }
}

/// "17:30" today, "Fri, 9 Oct, 17:30" for another day (a timer started yesterday,
/// a session paused on Friday).
private func sinceText(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
}

/// Customer colour dot + name.
private struct CustomerLabel: View {
    @Environment(TrackerStore.self) private var store
    let names: EntryNames

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Dot(hex: store.customer(names.customerId)?.color)
            Text(names.customer).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(names.full)
    }
}

/// Kimai colour dot. An SF Symbol (not a Circle) so it sits on the text baseline.
private struct Dot: View {
    let hex: String?

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(Brand.color(hex: hex) ?? .secondary)
            .accessibilityHidden(true)
    }
}

private struct ListSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

/// "25 min", "1 hr, 5 min", "2 days, 15 hr" (a weekend away).
private func minutes(_ interval: TimeInterval) -> String {
    Duration.seconds(max(0, interval)).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
}

/// Filled tomato button for primary actions. Not `.borderedProminent` + `.tint`:
/// AppKit draws that grey whenever the app is inactive, which a menu-bar app
/// often is (and every offscreen snapshot is).
private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(
                isEnabled ? AnyShapeStyle(Brand.accent.opacity(configuration.isPressed ? 0.75 : 1)) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

private extension View {
    /// Rounded, faintly tinted box for cards and banners.
    func card(tint: Color = .primary, padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.14)))
    }
}
