import ChronatoCore
import Foundation
import Observation

/// Standard-defaults keys: the start form remembers the last choice (same keys as the Mac).
enum Prefs {
    static let lastCustomerId = "lastCustomerId"
    static let lastProjectId = "lastProjectId"
    static let lastActivityId = "lastActivityId"
}

/// The iPhone app's single source of truth, the counterpart of the Mac's
/// TrackerStore (Sources/Chronato/TrackerStore.swift): views read it; only its
/// methods change it. Built on ChronatoCore's KimaiClient and TrackingPolicy.
///
/// Pause model as on the Mac: Kimai has no paused state, so Pause stops the
/// running entry and remembers it (`paused`, persisted in the App Group);
/// Resume starts a new entry with the same project, activity, note and tags.
/// The 24 h cap applies; there is no idle detection and no MCP on iOS.
///
/// After every change it writes a `SharedSnapshot` to the App Group and hands it
/// to `SnapshotSync` (Live Activity, widget timelines).
///
/// One per process: the app's (its init registers it as `shared`), which App
/// Intents and Live Activity buttons act on too, so the UI follows them.
@MainActor @Observable
final class PhoneTracker {
    enum ConnectionState: Equatable {
        case unconfigured, connecting, online
        case offline(String)
    }

    // MARK: State (views read, never write)

    private(set) var connectionState: ConnectionState = .unconfigured
    private(set) var connection: KimaiConnection?
    private(set) var me: KimaiUser?
    private(set) var serverVersion: String?
    private(set) var customers: [KimaiCustomer] = []
    private(set) var projects: [KimaiProject] = []
    private(set) var activities: [KimaiActivity] = []
    /// My running entry, as Kimai reports it (also when started in the browser or on the Mac).
    private(set) var active: KimaiTimesheet?
    private(set) var paused: PausedSession? {
        didSet {
            guard !isFixture, paused != oldValue else { return }
            AppGroup.defaults.set(paused.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.pausedKey)
        }
    }
    /// My recent distinct (project, activity, note) combinations, newest first.
    private(set) var recent: [KimaiTimesheet] = []
    /// My entries started this week (Kimai first weekday), for the totals.
    private(set) var weekEntries: [KimaiTimesheet] = []
    /// A request is in flight (disable buttons).
    private(set) var isBusy = false
    /// Last user-facing error (or the 24 h notice); views show it and may clear it.
    var lastError: String?
    /// Fixture data from `fixture(_:)`: every action and refresh is a no-op.
    let isFixture: Bool

    /// The process's tracker for App Intents: the app's, or (in the widget
    /// extension, which has no app instance) one made on first use.
    static var shared: PhoneTracker { current ?? PhoneTracker() }
    private static var current: PhoneTracker?

    // Engine bookkeeping, not shown anywhere.
    private static let pausedKey = "pausedSession"
    /// The first load. Shared, so an intent arriving while the app still
    /// launches waits for it instead of acting on empty state.
    @ObservationIgnored private var bootstrapping: Task<Void, Never>?
    /// Bumped when an action starts and ends; a refresh that overlapped one drops
    /// its (possibly pre-action) answer instead of undoing the action.
    @ObservationIgnored private var mutations = 0
    /// Entry the 24 h cap already tried to stop; Kimai refused, so not every refresh retries.
    @ObservationIgnored private var refusedStop: Int?
    @ObservationIgnored private var catalogLoaded = Date.distantPast
    @ObservationIgnored private var published: SharedSnapshot?
    /// Kimai has answered `/timesheets/active` at least once. Until then `active`
    /// is unknown rather than nil (launched offline), so nothing is published:
    /// that would end a running timer's Live Activity and show the widget idle.
    @ObservationIgnored private var timerKnown = false

    init(isFixture: Bool = false) {
        self.isFixture = isFixture
        if !isFixture {
            // Read before the first frame, so a connected app does not flash the
            // onboarding while `bootstrap()` waits for its turn.
            connection = try? Credentials.load()
            connectionState = connection == nil ? .unconfigured : .connecting
            paused = Self.storedPaused()
        }
        Self.current = self
    }

    // MARK: Derived

    var client: KimaiClient? {
        guard let connection else { return nil }
        return KimaiClient(connection: connection, timeZone: kimaiTimeZone)
    }
    var kimaiTimeZone: TimeZone { me?.timezone.flatMap(TimeZone.init(identifier:)) ?? .current }
    var isRunning: Bool { active != nil }
    /// Calendar in the Kimai user's time zone and first weekday (as the Reports use it).
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kimaiTimeZone
        c.firstWeekday = me?.firstWeekday ?? 2
        return c
    }

    /// Mine today, the running entry counted up to `now`.
    func todaySeconds(at now: Date = .now) -> Int { seconds(since: calendar.startOfDay(for: now), now: now) }

    /// Mine this week, the running entry counted up to `now`.
    func weekSeconds(at now: Date = .now) -> Int {
        seconds(since: calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now), now: now)
    }

    /// Week entries since `start`, with the running one as `active` has it (Kimai may not list it yet).
    private func seconds(since start: Date, now: Date) -> Int {
        var entries = weekEntries.filter { $0.begin >= start && $0.id != active?.id }
        if let active, active.begin >= start { entries.append(active) }
        return entries.reduce(0) { $0 + $1.seconds(now: now) }
    }

    func customer(_ id: Int?) -> KimaiCustomer? { customers.first { $0.id == id } }
    func project(_ id: Int?) -> KimaiProject? { projects.first { $0.id == id } }
    func activity(_ id: Int?) -> KimaiActivity? { activities.first { $0.id == id } }
    func projects(forCustomer id: Int) -> [KimaiProject] {
        projects.filter { $0.customer == id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// The project's own activities plus global ones (if the project allows them), by name.
    func activities(forProject id: Int) -> [KimaiActivity] {
        let allowsGlobal = project(id)?.globalActivities ?? true
        return activities
            .filter { $0.project == id || ($0.project == nil && allowsGlobal) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Display names for an entry. `/timesheets/active` and PATCH answers may
    /// carry bare ids, so missing names come from the catalog.
    func work(_ entry: KimaiTimesheet) -> Work {
        let p = project(entry.projectId)
        let c = customer(entry.customerId ?? p?.customer)
        return Work(
            projectId: entry.projectId, activityId: entry.activityId, note: entry.description, tags: entry.tags,
            customerName: entry.customerName ?? c?.name ?? "",
            projectName: entry.projectName ?? p?.name ?? "Project \(entry.projectId)",
            activityName: entry.activityName ?? activity(entry.activityId)?.name ?? "Activity \(entry.activityId)",
            customerColor: c?.color)
    }

    // MARK: Lifecycle

    /// Once at launch (or at an intent's first use): everything from Kimai for
    /// the connection `init` read. Later callers wait for that first load.
    func bootstrap() async {
        guard !isFixture else { return }
        if bootstrapping == nil {
            bootstrapping = Task {
                // The Keychain is unreadable before the first unlock after a reboot.
                if connection == nil, let saved = try? Credentials.load() {
                    connection = saved
                    connectionState = .connecting
                }
                if connection != nil { await load() }
                publish()
            }
        }
        await bootstrapping?.value
    }

    /// Validates against the server (/users/me + /version), saves to the Keychain,
    /// loads everything. Throws a user-presentable error.
    func connect(url: String, token: String) async throws {
        guard !isFixture else { return }
        let base = try KimaiConnection.validatedURL(url)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConnectError.missingToken }
        let candidate = KimaiConnection(url: base, token: token)
        let probe = KimaiClient(connection: candidate)
        // Nothing changes until the server has accepted the token.
        isBusy = true
        let user: KimaiUser, version: KimaiVersion
        do {
            defer { isBusy = false }
            user = try await probe.me()
            version = try await probe.version()
        }
        try Credentials.save(candidate)
        // Another server or user: the paused session and lists belong to the old one.
        if candidate.url != connection?.url || (me.map { $0.id != user.id } ?? false) { resetState() }
        connection = candidate
        me = user
        serverVersion = version.version
        connectionState = .online
        lastError = nil
        await reloadCatalog()
        await refresh()
    }

    enum ConnectError: LocalizedError {
        case missingToken

        var errorDescription: String? {
            switch self {
            case .missingToken: "Paste an API token (Kimai → your profile → API access)."
            }
        }
    }

    func disconnect() {
        guard !isFixture else { return }
        Credentials.clear()
        resetState()
        publish()
    }

    /// Running entry, recent list, this week's entries, and the catalog when it
    /// is older than 10 minutes. On launch, on return to the foreground and on
    /// pull-to-refresh: there is no background polling on iOS.
    func refresh() async {
        guard !isFixture, !isBusy, let client else { return }
        // Launched offline: time zone and first weekday first (load refreshes then).
        guard me != nil else {
            await load()
            publish()
            return
        }
        if Date().timeIntervalSince(catalogLoaded) > 10 * 60 { await reloadCatalog() }
        // A widget or intent may have paused or resumed meanwhile.
        paused = Self.storedPaused()
        let generation = mutations
        let end = Date()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: end)?.start ?? calendar.startOfDay(for: end)
        do {
            async let running = client.activeTimesheets()
            async let latest = client.recentTimesheets(size: 50)
            async let week = client.timesheets(begin: weekStart, end: end)
            let (r, l, w) = try await (running, latest, week)
            guard generation == mutations, !isBusy else { return } // an action ran meanwhile; it refreshes itself
            active = r.first
            recent = TrackingPolicy.recentCombinations(l.filter { $0.aiAgentTag == nil }, running: active,
                                                       projectIds: Set(projects.map(\.id)), activityIds: Set(activities.map(\.id)))
            weekEntries = w.filter { $0.aiAgentTag == nil }
            if active != nil { paused = nil } // resumed elsewhere (Kimai web, the Mac)
            timerKnown = true
            connectionState = .online
        } catch {
            guard generation == mutations else { return }
            // Keep the last known data; the next successful refresh goes back online.
            connectionState = .offline(error.localizedDescription)
        }
        await applyCap()
        publish()
    }

    func reloadCatalog() async {
        guard !isFixture, let client else { return }
        do {
            async let c = client.customers()
            async let p = client.projects()
            async let a = client.activities()
            (customers, projects, activities) = try await (c, p, a)
            catalogLoaded = Date()
        } catch {
            connectionState = .offline(error.localizedDescription)
        }
    }

    /// me (time zone, first weekday) → version → catalog → refresh.
    private func load() async {
        guard let client else { return }
        do {
            async let user = client.me()
            async let version = client.version()
            (me, serverVersion) = try await (user, version.version)
        } catch {
            connectionState = .offline(error.localizedDescription)
            return
        }
        await reloadCatalog()
        await refresh()
    }

    private func resetState() {
        mutations += 1
        connection = nil
        me = nil
        serverVersion = nil
        customers = []
        projects = []
        activities = []
        active = nil
        paused = nil
        recent = []
        weekEntries = []
        lastError = nil
        connectionState = .unconfigured
        refusedStop = nil
        catalogLoaded = .distantPast
        timerKnown = false
    }

    // MARK: Tracking

    /// Stops whatever runs and starts a new entry.
    func start(projectId: Int, activityId: Int, description: String?) async {
        await perform { client in
            try await startEntry(NewTimesheet(project: projectId, activity: activityId, description: Self.note(description)), client)
            let defaults = UserDefaults.standard
            defaults.set(project(projectId)?.customer ?? active?.customerId, forKey: Prefs.lastCustomerId)
            defaults.set(projectId, forKey: Prefs.lastProjectId)
            defaults.set(activityId, forKey: Prefs.lastActivityId)
        }
    }

    func pause() async {
        guard let running = active else { return }
        await perform { client in
            let stopped = try await client.stop(id: running.id)
            let end = stopped.end ?? Date()
            active = nil
            // The stop answer carries ids only, so the names come from the running entry;
            // note and tags from the answer, as on the Mac (the note may have changed in the browser).
            var work = self.work(running)
            work.note = stopped.description
            work.tags = stopped.tags
            paused = PausedSession(work: work, pausedAt: end, workedSeconds: stopped.seconds(now: end))
        }
    }

    /// New entry like the paused one, starting now.
    func resume() async {
        guard let session = paused else { return }
        await perform { client in
            try await startEntry(NewTimesheet(project: session.work.projectId, activity: session.work.activityId,
                                              description: session.work.note, tags: session.work.tags), client)
        }
    }

    func stop() async {
        guard !isFixture else { return }
        guard let running = active else {
            paused = nil // nothing runs: Stop just forgets the paused session
            publish()
            return
        }
        await perform { client in
            _ = try await client.stop(id: running.id)
            active = nil
            paused = nil
        }
    }

    /// Updates the note of the running entry (or of the paused session).
    func setDescription(_ text: String) async {
        guard !isFixture else { return }
        let note = Self.note(text)
        if let running = active {
            await perform { client in active = try await client.setDescription(id: running.id, note ?? "") }
        } else {
            paused?.work.note = note
            publish()
        }
    }

    /// Start a recent combination again.
    func startAgain(_ entry: KimaiTimesheet) async {
        await start(projectId: entry.projectId, activityId: entry.activityId, description: entry.description)
    }

    /// Stops whatever runs (one running entry per user), starts `new`, and drops
    /// the paused session: what runs now replaces it.
    private func startEntry(_ new: NewTimesheet, _ client: KimaiClient) async throws {
        if let running = active { _ = try await client.stop(id: running.id) }
        active = try await client.create(new)
        paused = nil
    }

    /// One change in Kimai: busy while it runs, errors to `lastError` (and
    /// returned), then a refresh so totals, the recent list and the snapshot follow.
    @discardableResult
    private func perform(_ work: @MainActor (KimaiClient) async throws -> Void) async -> Error? {
        guard !isFixture, !isBusy, let client else { return nil }
        isBusy = true
        mutations += 1
        var failure: Error?
        do {
            try await work(client)
            lastError = nil
        } catch {
            failure = error
            lastError = error.localizedDescription
        }
        mutations += 1
        isBusy = false
        await refresh()
        return failure
    }

    /// The 24 h rule, as on the Mac: a timer that ran for a day is stopped. A
    /// phone has no input signal for when work ended, so `capEnd` gets `now` as
    /// the last input and the entry ends at the cap, begin + 24 h.
    private func applyCap() async {
        let now = Date()
        guard connectionState == .online, let running = active, running.id != refusedStop,
              let end = TrackingPolicy.capEnd(begin: running.begin, lastInput: now, now: now) else { return }
        refusedStop = running.id // before perform(): its refresh comes back here
        let failure = await perform { client in
            _ = try await client.stop(id: running.id, at: end)
            active = nil
        }
        if failure == nil {
            lastError = "Stopped a timer that ran for 24 h. It ends at \(end.formatted(date: .abbreviated, time: .shortened)); check it in Kimai."
        } else if case .transport? = failure as? KimaiError {
            refusedStop = nil // unreachable, not refused: try again on the next refresh
        } else if case let .http(status, _)? = failure as? KimaiError, status >= 500 {
            refusedStop = nil // proxy or server down: the same, as on the Mac
        }
    }

    private static func note(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Shared snapshot

    private static func storedPaused() -> PausedSession? {
        AppGroup.defaults.data(forKey: pausedKey).flatMap { try? JSONDecoder().decode(PausedSession.self, from: $0) }
    }

    /// Writes the snapshot to the App Group and passes it on, if it changed.
    /// The Live Activity is synced either way: the user may have dismissed it,
    /// and a refresh that finds the timer running brings it back.
    /// Launched offline, the last snapshot (and the Live Activity) stay as they
    /// are until Kimai answers: see `timerKnown`.
    private func publish() {
        guard connection == nil || timerKnown else { return }
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var next = SharedSnapshot(
            isConnected: connection != nil,
            running: active.map { .init(entryId: $0.id, begin: $0.begin, work: work($0)) },
            paused: paused,
            todaySeconds: weekEntries
                .filter { $0.begin >= today && $0.end != nil && $0.id != active?.id }
                .reduce(0) { $0 + $1.seconds(now: now) },
            lastWork: recent.first.map(work),
            updatedAt: published?.updatedAt ?? now)
        guard next != published else {
            LiveActivitySync.sync(next)
            return
        }
        next.updatedAt = now
        published = next
        AppGroup.write(next)
        SnapshotSync.didPublish(next)
    }

    // MARK: Fixtures

    enum Fixture: String, CaseIterable { case idle, running, paused, unconfigured }

    /// Fictional data and no network, for `-ChronatoFixture <state>` and previews.
    /// Its snapshot still goes to the App Group, so widgets show the same data.
    static func fixture(_ state: Fixture) -> PhoneTracker {
        let t = PhoneTracker(isFixture: true)
        let now = Date()
        t.connection = KimaiConnection(url: URL(string: "https://kimai.example.net")!, token: "fixture")
        t.me = KimaiUser(id: 1, username: "admin", timezone: TimeZone.current.identifier)
        t.serverVersion = "2.69.0"
        t.connectionState = .online
        t.customers = [
            KimaiCustomer(id: 10, name: "Northwind Traders", color: "#2ECC40"),
            KimaiCustomer(id: 7, name: "Acme Studio", color: "#3D9970"),
            KimaiCustomer(id: 11, name: "Blue Harbor", color: "#FF851B"),
            KimaiCustomer(id: 12, name: "In-house", color: "#2196F3"),
        ]
        t.projects = [
            KimaiProject(id: 12, name: "Ops Dashboard", customer: 10, color: "#FF9800"),
            KimaiProject(id: 9, name: "Consulting", customer: 7, color: "#8BC34A"),
            KimaiProject(id: 11, name: "Consulting", customer: 11, color: "#8BC34A"),
            KimaiProject(id: 13, name: "Internal", customer: 12, billable: false, color: "#2196F3"),
        ]
        t.activities = [
            KimaiActivity(id: 3, name: "Automation", project: 12, color: "#39CCCC"),
            KimaiActivity(id: 5, name: "Weekly sync", project: 12, color: "#B10DC9"),
            KimaiActivity(id: 1, name: "Consulting", project: nil, color: "#8BC34A"),
            KimaiActivity(id: 21, name: "Development", project: nil, color: "#009688"),
            KimaiActivity(id: 18, name: "Internal work", project: 13, color: "#2196F3"),
        ]
        func entry(_ id: Int, _ hoursAgo: Double, _ minutes: Int, project: Int, activity: Int, note: String? = nil, running: Bool = false) -> KimaiTimesheet {
            let begin = now.addingTimeInterval(-hoursAgo * 3600)
            let p = t.projects.first { $0.id == project }!
            return KimaiTimesheet(
                id: id, begin: begin, end: running ? nil : begin.addingTimeInterval(Double(minutes) * 60),
                duration: running ? 0 : minutes * 60, description: note, rate: Double(minutes) * 1.5, userId: 1,
                projectId: project, projectName: p.name, customerId: p.customer,
                customerName: t.customers.first { $0.id == p.customer }?.name,
                activityId: activity, activityName: t.activities.first { $0.id == activity }?.name)
        }
        t.recent = [
            entry(101, 3, 95, project: 12, activity: 3, note: "Lead routing webhook"),
            entry(102, 26, 60, project: 12, activity: 5),
            entry(103, 50, 45, project: 9, activity: 1, note: "Order sync service"),
            entry(104, 75, 120, project: 11, activity: 1),
        ]
        t.weekEntries = [entry(101, 3, 95, project: 12, activity: 3), entry(102, 26, 60, project: 12, activity: 5)]
        switch state {
        case .running:
            t.active = entry(200, 1.3, 0, project: 12, activity: 3, note: "Call tagging automation", running: true)
        case .paused:
            let work = t.work(entry(200, 1.4, 73, project: 12, activity: 3, note: "Call tagging automation"))
            t.paused = PausedSession(work: work, pausedAt: now.addingTimeInterval(-600), workedSeconds: 4380)
        case .unconfigured:
            t.connection = nil
            t.connectionState = .unconfigured
        case .idle:
            break
        }
        t.timerKnown = true
        t.publish()
        WidgetGallery.renderIfRequested()
        return t
    }
}
