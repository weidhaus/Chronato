import AppKit
import ChronatoCore
import Foundation
import Observation

/// UserDefaults keys shared by the store and the Settings window.
enum Prefs {
    /// Minutes without keyboard/mouse input before the timer auto-pauses. 0 = off. Default 10.
    static let idleMinutes = "idleMinutes"
    /// Show the customer name next to the elapsed time in the menu bar. Default false.
    static let showCustomerInMenuBar = "showCustomerInMenuBar"
    /// Global hot key ⌃⌥⌘T toggles pause/resume. Default true.
    static let hotKeyEnabled = "hotKeyEnabled"
    /// Start form remembers the last choice.
    static let lastCustomerId = "lastCustomerId"
    static let lastProjectId = "lastProjectId"
    static let lastActivityId = "lastActivityId"
    /// Settings tab to show next time the Settings window opens (SettingsTab raw value).
    static let settingsTab = "settingsTab"
    /// AppearanceMode raw value: "system" (default), "light" or "dark". Applied live by AppearanceMode.follow().
    static let appearance = "appearance"

    static func register() {
        UserDefaults.standard.register(defaults: [idleMinutes: 10, showCustomerInMenuBar: false, hotKeyEnabled: true])
    }
}

/// The app's single source of truth. Views read it; only its methods change it.
///
/// Pause model: Kimai has no "paused" state, so Pause stops the running entry
/// and remembers it (`paused`); Resume starts a new entry with the same
/// customer/project/activity/note. Stop ends the entry and forgets it.
@MainActor @Observable
final class TrackerStore {
    static let shared = TrackerStore()

    enum ConnectionState: Equatable {
        case unconfigured, connecting, online
        case offline(String)
    }

    struct PausedSession: Codable, Equatable {
        enum Reason: String, Codable { case manual, idle, sleep }
        var projectId: Int
        var activityId: Int
        var description: String?
        var tags: [String]
        var customerName: String?
        var projectName: String?
        var activityName: String?
        /// When the paused entry ended.
        var pausedAt: Date
        var reason: Reason
        /// Worked seconds of the entry that was paused (display only).
        var workedSeconds: Int
    }

    /// Set when the user comes back after an idle/sleep auto-pause, until they choose.
    struct AwayNotice: Equatable {
        var since: Date
        var until: Date

        var seconds: TimeInterval { until.timeIntervalSince(since) }
        /// Whether "Count it" may back-date to `since`: at once, only after the user
        /// confirmed the span (`resolveAway(.resumeCountingAway, confirmed: true)`), or not at all.
        var countAway: TrackingPolicy.CountAway { TrackingPolicy.countAway(since: since, now: until) }
        /// "14:02–14:30", with dates when it crosses midnight: "Fri, 9 Oct, 18:00 – Mon, 12 Oct, 09:00".
        var span: String {
            guard !Calendar.current.isDate(since, inSameDayAs: until) else {
                return "\(since.formatted(date: .omitted, time: .shortened))–\(until.formatted(date: .omitted, time: .shortened))"
            }
            let style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).hour().minute()
            return "\(since.formatted(style)) – \(until.formatted(style))"
        }
    }

    enum AwayChoice {
        /// Start a new entry now; the away time is not tracked.
        case resume
        /// Start a new entry backdated to `since`, so the away time counts.
        case resumeCountingAway
        /// Keep paused.
        case stayPaused
        /// Forget the paused entry.
        case stop
    }

    /// What happens to a running timer when Chronato quits (`prepareToQuit`).
    enum QuitChoice { case pause, stop, keepRunning }

    /// Why an action did not run. Not an answer from Kimai.
    struct ActionRefused: LocalizedError {
        let message: String
        var errorDescription: String? { message }

        static let busy = ActionRefused(message: "Chronato is still busy with the last change.")
        static let notConnected = ActionRefused(message: "Chronato is not connected to Kimai.")
        static let notReachable = ActionRefused(message: "Kimai is not reachable yet.")
    }

    /// An auto-stop (idle, sleep, 24 h cap) decided but not applied yet because
    /// Kimai was unreachable, e.g. right after wake or while away. Persisted;
    /// retried once Kimai is back, so the entry still ends when the user left.
    struct PendingStop: Codable, Equatable {
        var entryId: Int
        /// When the user left: the entry's end.
        var end: Date
        /// Pause for this reason; nil = stop for good (24 h cap).
        var reason: PausedSession.Reason?
        /// The first input after `end` while the stop waited: the user came back then.
        var back: Date?
    }

    /// The running entry and the last input, kept while a timer runs (idle tick,
    /// sleep, quit), so the next launch can treat the time Chronato was not
    /// running (quit, crash, shutdown) like a sleep.
    struct LastAlive: Codable {
        var entryId: Int
        var begin: Date
        var lastInput: Date
    }

    // MARK: State (views read, never write)

    private(set) var connectionState: ConnectionState = .unconfigured
    private(set) var connection: KimaiConnection?
    private(set) var me: KimaiUser?
    private(set) var serverVersion: String?
    private(set) var customers: [KimaiCustomer] = []
    private(set) var projects: [KimaiProject] = []
    private(set) var activities: [KimaiActivity] = []
    private(set) var users: [KimaiUser] = []
    /// My running entry, as Kimai reports it (also when started in the browser).
    private(set) var active: KimaiTimesheet? {
        didSet {
            if noteDraft?.entryId != active?.id { noteDraft = nil }
            updateClock()
        }
    }
    /// Persisted ("pausedSession") so a paused session survives a relaunch.
    private(set) var paused: PausedSession? {
        didSet {
            guard paused != oldValue else { return }
            persist(paused, Self.pausedKey)
        }
    }
    /// My recent distinct (project, activity, note) combinations, newest first:
    /// startable ones only (visible catalog), never the running one.
    private(set) var recent: [KimaiTimesheet] = []
    /// My entries started this week (Kimai first weekday), for the today/week totals.
    private(set) var weekEntries: [KimaiTimesheet] = []
    /// Open AI-agent sessions (from `AgentSessions.list()`).
    private(set) var agentSessions: [AgentSession] = [] {
        didSet { updateClock() }
    }
    private(set) var awayNotice: AwayNotice?
    /// A request is in flight (disable buttons).
    private(set) var isBusy = false
    /// Last user-facing error; views show it and may clear it.
    var lastError: String?
    /// Advances every second while something is running, so elapsed labels redraw.
    private(set) var now = Date()
    /// Whole minutes the running entry has run (`elapsedSeconds / 60`). Changes once
    /// a minute, so the menu-bar label (h:mm) redraws once a minute, not every second.
    private(set) var elapsedMinutes = 0
    /// Why ⌃⌥⌘T does not work although it is switched on (for Settings), else nil.
    private(set) var hotKeyError: String?
    /// Fixture store from `preview(_:)`: every action and refresh must be a no-op
    /// (no network, no Keychain, no timers).
    private(set) var isPreview = false
    /// Persisted ("pendingStop"), so a quit or restart does not lose it.
    private var pendingStop: PendingStop? {
        didSet {
            guard pendingStop != oldValue else { return }
            persist(pendingStop, Self.pendingKey)
            updateClock()
        }
    }

    // Engine bookkeeping, not shown anywhere.
    private static let pausedKey = "pausedSession"
    private static let pendingKey = "pendingStop"
    private static let aliveKey = "lastAlive"
    @ObservationIgnored private var bootstrapped = false
    /// Bumped when an action starts and ends; a refresh that overlapped one drops
    /// its (possibly pre-action) answer instead of undoing the action.
    @ObservationIgnored private var mutations = 0
    /// Between willSleep and didWake, Power Nap's dark wakes included: no idle
    /// decisions then (HID idle time stands still while asleep).
    @ObservationIgnored private var asleep = false
    /// The last input before the sleep, and the entry that ran then.
    @ObservationIgnored private var sleepStart: (lastInput: Date, entry: (id: Int, begin: Date)?)?
    /// The last wake and the last input before that sleep, until the first input
    /// after the wake: HID idle time did not advance while asleep, so until then
    /// the input before the sleep is the last real one.
    @ObservationIgnored private var lastWake: (at: Date, inputBefore: Date)?
    /// Entry Kimai refused to end automatically (permissions, lockdown, budget).
    /// Not retried every 15 s; the error is in `lastError`. Reconnecting re-arms it.
    @ObservationIgnored private var refusedStop: Int?
    @ObservationIgnored private var applyingStop = false
    /// The running entry's note as typed but not saved yet (`setNoteDraft`).
    @ObservationIgnored private var noteDraft: (entryId: Int, text: String)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastReap = Date.distantPast
    /// Prefs, the paused session, pending stop and last-alive record; whether
    /// `connect`/`disconnect` use the Keychain. Only `Chronato selftest` changes
    /// them (scratch suite, no Keychain).
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: Bool

    init(defaults: UserDefaults = .standard, keychain: Bool = true) {
        self.defaults = defaults
        self.keychain = keychain
    }

    // MARK: Derived

    var client: KimaiClient? {
        guard let connection else { return nil }
        return KimaiClient(connection: connection, timeZone: kimaiTimeZone)
    }
    var kimaiTimeZone: TimeZone { me?.timezone.flatMap(TimeZone.init(identifier:)) ?? .current }
    var isRunning: Bool { active != nil }
    /// The running entry's time; it stops at a pending auto-stop's end (the user left then).
    var elapsedSeconds: Int { active?.seconds(now: min(now, pendingStopAt ?? now)) ?? 0 }
    /// When the running entry ends once Kimai is reachable again (idle, sleep or
    /// 24 h cap decided while offline), else nil. The menu can say so.
    var pendingStopAt: Date? { pendingStop.flatMap { $0.entryId == active?.id ? $0.end : nil } }
    /// Ticker running (selftest).
    var isTicking: Bool { ticker != nil }
    /// Mine today, including the running entry.
    var todaySeconds: Int { secondsSince(calendar.startOfDay(for: now)) }
    /// Mine this week, including the running entry.
    var weekSeconds: Int {
        secondsSince(calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now))
    }
    /// Calendar in the Kimai user's time zone and first weekday.
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kimaiTimeZone
        c.firstWeekday = me?.firstWeekday ?? 2
        return c
    }

    /// Mine since `start`: week entries plus the running one (if Kimai has not listed it yet).
    private func secondsSince(_ start: Date) -> Int {
        var entries = weekEntries.filter { $0.begin >= start }
        if let active, active.begin >= start, !entries.contains(where: { $0.id == active.id }) { entries.append(active) }
        return entries.reduce(0) { total, entry in
            total + (entry.id == active?.id ? elapsedSeconds : entry.seconds(now: now))
        }
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

    // MARK: Lifecycle

    /// Called once at launch: what the last run left behind, polling, idle
    /// monitoring, sleep/wake observers, the hot key, then the Keychain connection.
    /// (Notifications are set up by the app delegate, before launch completes.)
    func bootstrap() async {
        guard !isPreview, !bootstrapped else { return }
        bootstrapped = true
        restoreAfterLaunch()
        startBackgroundWork()
        let saved: KimaiConnection?
        do { saved = try Credentials.load() } catch {
            // Connected, but the Keychain refused (access denied, locked): say so, not "connect".
            connectionState = .offline(error.localizedDescription)
            return
        }
        await useSavedConnection(saved)
    }

    /// Launch: the paused session; an auto-stop still pending from the last run;
    /// else, if a timer ran when Chronato was last alive (quit, crash, shutdown),
    /// that gap is treated like a sleep: the cap and idle rule with the last input then.
    func restoreAfterLaunch(now: Date = Date()) {
        paused = stored(PausedSession.self, Self.pausedKey)
        if let pending = stored(PendingStop.self, Self.pendingKey) {
            pendingStop = pending
        } else if let alive = stored(LastAlive.self, Self.aliveKey),
                  let stop = TrackingPolicy.autoStop(begin: alive.begin, lastInput: alive.lastInput, now: now, idleMinutes: idleMinutes) {
            pendingStop = PendingStop(entryId: alive.entryId, end: stop.end, reason: stop.capped ? nil : .sleep)
        }
        defaults.removeObject(forKey: Self.aliveKey)
    }

    /// The saved (Keychain) connection at launch, used without probing it: Chronato also starts offline.
    func useSavedConnection(_ saved: KimaiConnection?) async {
        guard let saved else {
            connectionState = .unconfigured
            return
        }
        connection = saved
        connectionState = .connecting
        await load()
    }

    /// Validates against the server (version + /users/me), saves to the Keychain,
    /// loads everything. Throws a user-presentable error.
    func connect(url: String, token: String) async throws {
        guard !isPreview else { return }
        guard !isBusy else { throw ConnectError.busy }
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
        if keychain { try Credentials.save(candidate) }
        // Another server or user: the paused session and lists belong to the old one.
        if candidate.url != connection?.url || (me.map { $0.id != user.id } ?? false) { resetState() }
        connection = candidate
        me = user
        serverVersion = version.version
        connectionState = .online
        lastError = nil
        refusedStop = nil // a new token may be allowed to end it
        await reloadCatalog()
        await refresh()
    }

    enum ConnectError: LocalizedError {
        case missingToken, busy

        var errorDescription: String? {
            switch self {
            case .missingToken: "Paste an API token (Kimai → your profile → API access)."
            case .busy: "Wait until the current change in Kimai has finished, then connect again."
            }
        }
    }

    func disconnect() {
        guard !isPreview else { return }
        if keychain { Credentials.clear() }
        resetState()
    }

    /// Active entry, recent list, this week's entries, AI sessions. Called on a
    /// timer (~60 s), on wake, and when the menu opens. Applies a waiting auto-stop
    /// as soon as Kimai answers again.
    func refresh() async {
        guard !isPreview, !isBusy, let client else { return }
        // Launched offline: time zone and first weekday first (load refreshes then).
        guard me != nil else {
            await load()
            return
        }
        let generation = mutations
        let end = Date()
        tick(end)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: end)?.start ?? calendar.startOfDay(for: end)
        do {
            async let running = client.activeTimesheets()
            async let latest = client.recentTimesheets(size: 50)
            async let week = client.timesheets(begin: weekStart, end: end)
            let (r, l, w) = try await (running, latest, week)
            guard generation == mutations, !isBusy else { return } // an action ran meanwhile; it refreshes itself
            let agentTags = Set(AIConfig.load().agents.map(\.tag))
            let human: (KimaiTimesheet) -> Bool = { [meId = me?.id] in !TrackingPolicy.isAI($0, meId: meId, agentTags: agentTags) }
            active = r.first
            recent = TrackingPolicy.recentCombinations(l.filter(human), running: active,
                                                       projectIds: Set(projects.map(\.id)), activityIds: Set(activities.map(\.id)))
            weekEntries = w.filter(human)
            if active != nil, paused != nil { forgetPaused() } // resumed elsewhere (Kimai web, another Mac)
            connectionState = .online
        } catch {
            guard generation == mutations else { return }
            // Keep the last known data; the next successful refresh goes back online.
            connectionState = .offline(error.localizedDescription)
        }
        agentSessions = AgentSessions.list()
        if connectionState == .online, end.timeIntervalSince(lastReap) >= 5 * 60 {
            lastReap = end
            let reaped = await AgentSessions.reapStale(client: client, config: AIConfig.load())
            for line in reaped.booked { Notifications.shared.post("AI session booked", line) }
            for line in reaped.failed { Notifications.shared.post("AI session not booked", line) }
            agentSessions = AgentSessions.list()
        }
        if pendingStop != nil { await applyPendingStop() }
    }

    /// Answers that arrive after `connect`/`disconnect` replaced the connection
    /// belong to the old server and are dropped.
    func reloadCatalog() async {
        guard !isPreview, let client else { return }
        let started = client.connection
        do {
            async let c = client.customers()
            async let p = client.projects()
            async let a = client.activities()
            let catalog = try await (c, p, a)
            guard connection == started else { return }
            (customers, projects, activities) = catalog
        } catch {
            guard connection == started else { return }
            connectionState = .offline(error.localizedDescription)
            return
        }
        do {
            let list = try await client.users()
            guard connection == started else { return }
            users = list
        } catch KimaiError.http(status: 403, _) {
            // Only admins may list users; the one we know is ourselves.
            guard connection == started else { return }
            users = me.map { [$0] } ?? []
        } catch {
            // Keep the last list; the next refresh reports the connection problem.
        }
    }

    /// The Kimai user again (every 10th poll): a profile time zone changed while
    /// travelling moves the GET windows, the totals' calendar and new dates along.
    func reloadMe() async {
        guard !isPreview, let client, let user = try? await client.me(), connection == client.connection, user != me else { return }
        me = user
    }

    /// me (time zone, first weekday) → version → catalog → refresh. The poll and
    /// `refresh()` retry it until it gets through, so a launch while offline recovers.
    private func load() async {
        guard let client else { return }
        let started = client.connection
        do {
            async let user = client.me()
            async let version = client.version()
            let answer = try await (user, version.version)
            guard connection == started else { return }
            (me, serverVersion) = answer
        } catch {
            guard connection == started else { return }
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
        users = []
        active = nil
        forgetPaused()
        recent = []
        weekEntries = []
        agentSessions = []
        lastError = nil
        connectionState = .unconfigured
        sleepStart = nil
        pendingStop = nil
        refusedStop = nil
        for key in [Self.pausedKey, Self.pendingKey, Self.aliveKey] { defaults.removeObject(forKey: key) }
    }

    /// Poll, idle tick, sleep/wake, hot key. The store lives as long as the app,
    /// so none of this is ever torn down. (The 1 s ticker runs only while needed.)
    private func startBackgroundWork() {
        Task {
            var polls = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                polls += 1
                guard connection != nil, !asleep else { continue }
                if me == nil { await load(); continue }
                // New projects/activities appear in Kimai web now and then.
                if polls % 10 == 0 { await reloadMe() }
                if polls % 10 == 0 || customers.isEmpty { await reloadCatalog() }
                await refresh()
            }
        }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: IdleMonitor.pollInterval)
                await idleTick()
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.willSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await self.didWake() }
        }

        updateHotKey()
        // Settings writes the pref through @AppStorage; any defaults change lands here.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.updateHotKey() }
        }
    }

    private func updateHotKey() {
        let error = HotKey.setEnabled(UserDefaults.standard.bool(forKey: Prefs.hotKeyEnabled))
        if error != hotKeyError { hotKeyError = error }
    }

    /// " or with ⌃⌥⌘T" when the shortcut works.
    private var hotKeyHint: String {
        defaults.bool(forKey: Prefs.hotKeyEnabled) && hotKeyError == nil ? " or with ⌃⌥⌘T" : ""
    }

    private func tick(_ date: Date) {
        now = date
        let minutes = elapsedSeconds / 60
        if minutes != elapsedMinutes { elapsedMinutes = minutes }
    }

    /// Keeps `elapsedMinutes` current; runs the 1 s ticker only while a running
    /// time is shown (my timer or AI sessions), not all day.
    private func updateClock() {
        tick(isPreview ? now : Date())
        guard !isPreview, active != nil || !agentSessions.isEmpty else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick(Date())
            }
        }
    }

    private func persist<T: Encodable>(_ value: T?, _ key: String) {
        guard !isPreview else { return }
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    private func stored<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    // MARK: Tracking

    /// Starts a new entry; Kimai stops whatever runs in the same request.
    @discardableResult
    func start(projectId: Int, activityId: Int, description: String?) async -> Error? {
        await perform { client in
            try await startEntry(NewTimesheet(project: projectId, activity: activityId, description: Self.note(description)), client)
            defaults.set(project(projectId)?.customer ?? active?.customerId, forKey: Prefs.lastCustomerId)
            defaults.set(projectId, forKey: Prefs.lastProjectId)
            defaults.set(activityId, forKey: Prefs.lastActivityId)
        }
    }

    @discardableResult
    func pause() async -> Error? {
        guard let running = active else { return nil }
        return await perform { client in
            let (stopped, pending) = try await stopRunning(running, client)
            active = nil
            paused = pausedSession(from: stopped, reason: pending?.reason ?? .manual, at: stopped.end ?? Date())
            if pending?.reason != nil { raiseAwayNotice() } // an auto-pause was still waiting: the user is back
        }
    }

    @discardableResult
    func resume() async -> Error? { await resumePaused(from: nil) }

    @discardableResult
    func stop() async -> Error? {
        guard !isPreview else { return nil }
        guard let running = active else {
            forgetPaused() // nothing runs: Stop just forgets the paused session
            return nil
        }
        return await perform { client in
            _ = try await stopRunning(running, client)
            active = nil
            forgetPaused()
        }
    }

    /// The running entry's note as the user types it. Saved before that entry
    /// ends or is replaced (pause, stop, switch, hot key, auto-pause), so a typed
    /// but uncommitted note is never lost.
    func setNoteDraft(_ text: String, for entryId: Int) {
        noteDraft = (entryId, text)
    }

    /// The unsaved note typed for `entryId`, if any (the Note panel reopens with it).
    func noteDraft(for entryId: Int) -> String? {
        noteDraft.flatMap { $0.entryId == entryId ? $0.text : nil }
    }

    /// Updates the note of entry `entryId` (default: the running one; it may have
    /// ended meanwhile, e.g. a note committed after a switch), or of the paused
    /// session when nothing runs.
    @discardableResult
    func setDescription(_ text: String, entryId: Int? = nil) async -> Error? {
        guard !isPreview else { return nil }
        let note = Self.note(text)
        guard let id = entryId ?? active?.id else {
            paused?.description = note
            return nil
        }
        return await perform { client in
            let updated = try await client.setDescription(id: id, note ?? "")
            if updated.id == active?.id { active = updated }
            if let draft = noteDraft, draft.entryId == id, Self.note(draft.text) == note { noteDraft = nil }
        }
    }

    /// Start a recent combination again.
    @discardableResult
    func startAgain(_ entry: KimaiTimesheet) async -> Error? {
        await start(projectId: entry.projectId, activityId: entry.activityId, description: entry.description)
    }

    /// Hot key: running → pause; paused → resume; idle → start the most recent
    /// combination. When that did nothing (Kimai unreachable, busy, nothing to
    /// start), says so in a notification (the menu is usually closed) and returns it.
    @discardableResult
    func toggle() async -> String? {
        let problem: String?
        if isRunning {
            problem = await pause().map { "Couldn't pause: \($0.localizedDescription)" }
        } else if paused != nil {
            problem = await resume().map { "Couldn't resume: \($0.localizedDescription)" }
        } else if let last = recent.first {
            problem = await startAgain(last).map { "Couldn't start: \($0.localizedDescription)" }
        } else {
            problem = "Nothing to start yet: choose an activity in the menu first."
        }
        if let problem { Notifications.shared.post("⌃⌥⌘T did nothing", problem, id: Notifications.hotKeyId) }
        return problem
    }

    /// The user's answer to the away notice. Counting more than 4 h away needs
    /// `confirmed` (the menu asks, showing `AwayNotice.span`); a day or more is never
    /// counted. A refusal is returned and shown in `lastError`.
    @discardableResult
    func resolveAway(_ choice: AwayChoice, confirmed: Bool = false) async -> Error? {
        guard !isPreview else { return nil }
        switch choice {
        case .resume:
            Notifications.shared.withdraw(Notifications.awayId)
            return await resumePaused(from: nil)
        case .resumeCountingAway:
            guard let since = paused?.pausedAt else { return nil }
            if let refusal = Self.countRefusal(since: since, now: Date(), confirmed: confirmed) {
                lastError = refusal.message
                return refusal
            }
            Notifications.shared.withdraw(Notifications.awayId)
            return await resumePaused(from: since)
        case .stayPaused:
            Notifications.shared.withdraw(Notifications.awayId)
            // An ordinary pause from now on: no new "welcome back", also not after a relaunch.
            paused?.reason = .manual
            awayNotice = nil
            return nil
        case .stop:
            forgetPaused()
            return nil
        }
    }

    private static func countRefusal(since: Date, now: Date, confirmed: Bool) -> ActionRefused? {
        let away = Duration.seconds(now.timeIntervalSince(since))
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
        switch TrackingPolicy.countAway(since: since, now: now) {
        case .allowed: return nil
        case .needsConfirmation:
            return confirmed ? nil : ActionRefused(message: "Counting \(away) away as work needs a confirmation in the Chronato menu.")
        case .tooLong:
            return ActionRefused(message: "Away \(away): more than a day is not counted. Resume, and add any work in Kimai.")
        }
    }

    /// Before quitting with a timer running: pause or stop it (an error means it
    /// still runs; the app asks before quitting anyway), or keep it running in
    /// Kimai. Either way the last input is kept, so the next launch treats the
    /// time Chronato was not running like a sleep.
    func prepareToQuit(_ choice: QuitChoice) async -> Error? {
        switch choice {
        case .pause: if let error = await pause() { return error }
        case .stop: if let error = await stop() { return error }
        case .keepRunning: break
        }
        recordLastAlive()
        return nil
    }

    /// Drops the paused session, its away notice and the notification offering to resume it.
    private func forgetPaused() {
        paused = nil
        awayNotice = nil
        Notifications.shared.withdraw(Notifications.awayId)
    }

    /// New entry like the paused one, starting now (`begin` nil) or back-dated.
    @discardableResult
    private func resumePaused(from begin: Date?) async -> Error? {
        guard let session = paused else { return nil }
        return await perform { client in
            // A retry whose first attempt reached Kimai but lost its answer: adopt
            // that entry instead of booking the time away twice.
            if let begin, let existing = try await client.activeTimesheets().first(where: {
                $0.projectId == session.projectId && $0.activityId == session.activityId
                    && abs($0.begin.timeIntervalSince(begin)) < 60
            }) {
                active = existing
                forgetPaused()
                return
            }
            try await startEntry(NewTimesheet(project: session.projectId, activity: session.activityId, begin: begin,
                                              description: session.description, tags: session.tags), client)
        }
    }

    /// Starts `new` and drops the paused session: what runs now replaces it.
    /// POST first: Kimai stops the running entry in the same transaction (one
    /// running entry per user), so a refused start leaves it running. Then the
    /// old entry gets a pending auto-stop's end (the user had left), or is stopped
    /// if Kimai allows several running entries and kept it.
    private func startEntry(_ new: NewTimesheet, _ client: KimaiClient) async throws {
        let previous = active
        var leftAt: Date?
        if let previous {
            try await saveNoteDraft(of: previous, client)
            leftAt = try await waitingStop(for: previous, client)?.end
        }
        active = try await client.create(new)
        forgetPaused()
        guard let previous else { return }
        if let leftAt {
            _ = try await endEntry(previous.id, at: leftAt, client)
            pendingStop = nil
        } else if try await client.activeTimesheets().contains(where: { $0.id == previous.id }) {
            _ = try await client.stop(id: previous.id)
        }
    }

    /// Ends the running entry for a user action (pause, stop): at a pending
    /// auto-stop's end when one waits for it (the user left then; the time since
    /// is not work), else now. Saves a typed note first.
    private func stopRunning(_ running: KimaiTimesheet, _ client: KimaiClient) async throws -> (stopped: KimaiTimesheet, pending: PendingStop?) {
        try await saveNoteDraft(of: running, client)
        let pending = try await waitingStop(for: running, client)
        let stopped = try await endEntry(running.id, at: pending?.end, client)
        if pending != nil { pendingStop = nil }
        return (stopped, pending)
    }

    /// Ends entry `id` at `end` (the user left then), or now. Kimai's punch and
    /// duration tracking modes don't let a token without view_other_timesheet write
    /// times ("extra fields"): then it ends now instead of running on, and the user is told.
    private func endEntry(_ id: Int, at end: Date?, _ client: KimaiClient) async throws -> KimaiTimesheet {
        guard let end else { return try await client.stop(id: id) }
        do { return try await client.stop(id: id, at: end) } catch let KimaiError.http(400, message) where message.contains("extra fields") {
            Notifications.shared.post("Ended now, not at \(end.formatted(date: .omitted, time: .shortened))",
                                      "Kimai's tracking mode doesn't let Chronato set an earlier end. Correct the entry in Kimai.")
            return try await client.stop(id: id)
        }
    }

    /// The pending auto-stop for `entry` while Kimai still runs it; an end set
    /// elsewhere meanwhile wins (the pending stop is dropped then).
    private func waitingStop(for entry: KimaiTimesheet, _ client: KimaiClient) async throws -> PendingStop? {
        guard let pending = pendingStop, pending.entryId == entry.id else { return nil }
        guard try await client.activeTimesheets().contains(where: { $0.id == entry.id }) else {
            pendingStop = nil
            return nil
        }
        return pending
    }

    /// Saves the note typed for `running` but not committed (`setNoteDraft`).
    private func saveNoteDraft(of running: KimaiTimesheet, _ client: KimaiClient) async throws {
        guard let draft = noteDraft, draft.entryId == running.id else { return }
        let note = Self.note(draft.text)
        if note != Self.note(running.description) { _ = try await client.setDescription(id: running.id, note ?? "") }
        noteDraft = nil
    }

    /// One change in Kimai: busy while it runs, errors to `lastError` (and
    /// returned), then a refresh so totals and the recent list follow. Returns
    /// `ActionRefused` when it did not run (busy, not connected, Kimai never reached).
    @discardableResult
    private func perform(_ work: @MainActor (KimaiClient) async throws -> Void) async -> Error? {
        guard !isPreview else { return nil }
        guard !isBusy else { return ActionRefused.busy }
        guard connection != nil else { return ActionRefused.notConnected }
        // Launched offline: the Kimai user first, so dates go out in its time zone, not the Mac's.
        if me == nil { await load() }
        guard !isBusy else { return ActionRefused.busy }
        guard let client else { return ActionRefused.notConnected }
        guard me != nil else {
            lastError = ActionRefused.notReachable.message
            return ActionRefused.notReachable
        }
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

    private func pausedSession(from entry: KimaiTimesheet, reason: PausedSession.Reason, at end: Date) -> PausedSession {
        // PATCH answers carry ids only; names come from the catalog then.
        let p = project(entry.projectId)
        return PausedSession(
            projectId: entry.projectId, activityId: entry.activityId, description: entry.description, tags: entry.tags,
            customerName: entry.customerName ?? customer(p?.customer)?.name,
            projectName: entry.projectName ?? p?.name,
            activityName: entry.activityName ?? activity(entry.activityId)?.name,
            pausedAt: end, reason: reason, workedSeconds: entry.seconds(now: end))
    }

    private static func note(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Idle, sleep, 24 h cap

    private var idleMinutes: Int { defaults.integer(forKey: Prefs.idleMinutes) }

    /// The last input as far as it can be trusted: until the first input after a
    /// wake, the one before the sleep (HID idle time did not advance while asleep).
    private func trustedInput(_ lastInput: Date) -> Date {
        guard let wake = lastWake else { return lastInput }
        guard lastInput <= wake.at else {
            lastWake = nil // input since the wake: HID idle time is current again
            return lastInput
        }
        return min(lastInput, wake.inputBefore)
    }

    /// Every ~15 s: cap a day-long timer or pause an idle one (or retry such a
    /// stop that is still pending), and raise the away notice once the user is back.
    /// Skipped while asleep (dark wakes). `now`/`lastInput` are only passed by `Chronato selftest`.
    func idleTick(now: Date = Date(), lastInput: Date? = nil) async {
        guard !isPreview, !isBusy, !asleep else { return }
        let lastInput = trustedInput(lastInput ?? now.addingTimeInterval(-IdleMonitor.secondsSinceLastInput()))
        recordLastAlive(lastInput: lastInput)
        if var pending = pendingStop {
            // Back while the stop could not be applied: remember when, so the pause
            // keeps the real away window.
            if pending.back == nil, pending.reason != nil, lastInput > pending.end.addingTimeInterval(1) {
                pending.back = lastInput
                pendingStop = pending
            }
        } else if let running = active, running.id != refusedStop,
                  let stop = TrackingPolicy.autoStop(begin: running.begin, lastInput: lastInput, now: now, idleMinutes: idleMinutes) {
            pendingStop = PendingStop(entryId: running.id, end: stop.end, reason: stop.capped ? nil : .idle)
        }
        if pendingStop != nil {
            await applyPendingStop()
        } else if let session = paused, TrackingPolicy.shouldRaiseAwayNotice(
            autoPaused: session.reason != .manual, alreadyRaised: awayNotice != nil,
            pausedAt: session.pausedAt, lastInput: lastInput) {
            raiseAwayNotice()
        }
    }

    /// Ends `pendingStop`'s entry on the user's behalf at the time they left:
    /// paused for its reason, or stopped for good (24 h cap). Checks first that it
    /// still runs, so an entry stopped elsewhere keeps its real end. Only tried
    /// while online (a successful refresh tries at once), so an outage shows as
    /// offline, not as an error per attempt.
    private func applyPendingStop() async {
        guard let pending = pendingStop, connectionState == .online, !isBusy, !applyingStop, me != nil else { return }
        applyingStop = true // perform's own refresh must not start it again
        defer { applyingStop = false }
        let failure = await perform { client in
            guard let running = try await client.activeTimesheets().first(where: { $0.id == pending.entryId }) else { return }
            try await saveNoteDraft(of: running, client)
            let stopped = try await endEntry(pending.entryId, at: pending.end, client)
            active = nil
            guard let reason = pending.reason else {
                Notifications.shared.post("Stopped a timer left running for a day",
                                          "Ended it at \((stopped.end ?? pending.end).formatted(date: .abbreviated, time: .shortened)); check it in Kimai.")
                return
            }
            // Kimai's (rounded) end: "Count it" starts exactly there, nothing is booked twice.
            let session = pausedSession(from: stopped, reason: reason, at: stopped.end ?? pending.end)
            paused = session
            if reason == .idle, let back = pending.back {
                // The user came back and worked on while Kimai was unreachable: carry on from then.
                try await startEntry(NewTimesheet(project: session.projectId, activity: session.activityId, begin: max(back, session.pausedAt),
                                                  description: session.description, tags: session.tags), client)
                Notifications.shared.post("Paused \(AwayNotice(since: pending.end, until: back).span) while Kimai was unreachable",
                                          "\(Self.label(session)) runs again from when you came back.")
            } else if reason == .sleep {
                raiseAwayNotice(until: pending.back ?? Date()) // waking the Mac is coming back
            } else {
                Notifications.shared.post("Paused – no activity since \(pending.end.formatted(date: .omitted, time: .shortened))",
                                          "\(Self.label(session)). Resume from the menu bar\(hotKeyHint).")
            }
        }
        if Self.isTransient(failure) { return } // keep it pending
        if failure != nil { refusedStop = pending.entryId }
        pendingStop = nil
    }

    /// Worth another try: Kimai unreachable or not answering properly (proxy,
    /// captive portal, rate limit, rejected token). Anything else is Kimai
    /// refusing to end this entry, which is not retried every 15 s.
    private static func isTransient(_ error: Error?) -> Bool {
        guard let error else { return false }
        if error is ActionRefused { return true }
        guard let kimai = error as? KimaiError else { return false }
        guard case let .http(status, message) = kimai else { return true } // transport, decoding
        return status >= 500 || [401, 407, 408, 429].contains(status) || (status == 403 && message == "Access denied.")
    }

    func willSleep(lastInput: Date? = nil) {
        let lastInput = trustedInput(lastInput ?? Date().addingTimeInterval(-IdleMonitor.secondsSinceLastInput()))
        asleep = true
        sleepStart = (lastInput, active.map { ($0.id, $0.begin) })
        recordLastAlive(lastInput: lastInput)
    }

    /// The cap and the idle rule with the last input before the sleep: a Mac that
    /// idled into sleep was left at its last input, not when it fell asleep or woke.
    func didWake(now: Date = Date(), lastInput: Date? = nil) async {
        asleep = false
        if let sleep = sleepStart {
            lastWake = (now, sleep.lastInput)
            if pendingStop == nil, let entry = sleep.entry, entry.id != refusedStop,
               let stop = TrackingPolicy.autoStop(begin: entry.begin, lastInput: sleep.lastInput, now: now, idleMinutes: idleMinutes) {
                pendingStop = PendingStop(entryId: entry.id, end: stop.end, reason: stop.capped ? nil : .sleep)
            }
        }
        sleepStart = nil
        await refresh() // applies the stop at once if Kimai is reachable; while Wi-Fi is still off it waits
        await idleTick(now: now, lastInput: lastInput)
    }

    /// Remembers the running entry and the last input (`LastAlive`): every idle
    /// tick, before sleep, at quit.
    func recordLastAlive(lastInput: Date? = nil) {
        guard !isPreview else { return }
        let lastInput = lastInput ?? trustedInput(Date().addingTimeInterval(-IdleMonitor.secondsSinceLastInput()))
        persist(active.map { LastAlive(entryId: $0.id, begin: $0.begin, lastInput: lastInput) }, Self.aliveKey)
    }

    private func raiseAwayNotice(until back: Date = Date()) {
        guard let session = paused else { return }
        let notice = AwayNotice(since: session.pausedAt, until: back)
        awayNotice = notice
        let away = Duration.seconds(max(60, notice.seconds))
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
        let counting = notice.countAway == .allowed
        Notifications.shared.post("Welcome back — away \(away)",
                                  "\(Self.label(session)) is paused (\(notice.span)). "
                                      + (counting ? "Resume, or count the time away as work?" : "Resume, or decide in the menu."),
                                  id: Notifications.awayId, category: counting ? Notifications.awayCategory : Notifications.awayLongCategory)
    }

    /// "Northwind Traders · Ops Dashboard" for notifications.
    private static func label(_ session: PausedSession) -> String {
        let parts = [session.customerName, session.projectName].compactMap { $0 }
        return parts.isEmpty ? "Your timer" : parts.joined(separator: " · ")
    }

    /// Opens the Kimai web UI (timesheet page by default). Kimai routes carry the
    /// user's language prefix ("/de/timesheet/").
    func openKimai(path: String = "timesheet/") {
        guard let base = connection?.url else { return }
        NSWorkspace.shared.open(base.appendingPathComponent(me?.language ?? "en").appendingPathComponent(path))
    }

    // MARK: Previews / snapshots

    /// One per row of the menu's state contract (design/chronato-interaction-spec.md §4.3).
    enum PreviewState: String, CaseIterable {
        case idle, running, paused, away, awayLong, awayDay, unconfigured, connecting, offline, pendingStop, lastError, refusedAgent, busy
    }

    /// A store filled with fixture data and no network, for `Chronato snapshot`.
    static func preview(_ state: PreviewState) -> TrackerStore {
        let s = TrackerStore()
        s.isPreview = true
        let now = Date()
        s.now = now
        s.connection = KimaiConnection(url: URL(string: "https://kimai.example.net")!, token: "preview")
        s.me = KimaiUser(id: 1, username: "admin", timezone: "Europe/Berlin")
        s.serverVersion = "2.69.0"
        s.connectionState = .online
        s.customers = [
            KimaiCustomer(id: 10, name: "Northwind Traders", color: "#2ECC40"),
            KimaiCustomer(id: 7, name: "Acme Studio", color: "#3D9970"),
            KimaiCustomer(id: 11, name: "Blue Harbor", color: "#FF851B"),
            KimaiCustomer(id: 12, name: "In-house", color: "#2196F3"),
        ]
        s.projects = [
            KimaiProject(id: 12, name: "Ops Dashboard", customer: 10, color: "#FF9800"),
            KimaiProject(id: 9, name: "Consulting", customer: 7, color: "#8BC34A"),
            KimaiProject(id: 11, name: "Consulting", customer: 11, color: "#8BC34A"),
            KimaiProject(id: 13, name: "Internal", customer: 12, billable: false, color: "#2196F3"),
        ]
        s.activities = [
            KimaiActivity(id: 3, name: "Automation", project: 12, color: "#39CCCC"),
            KimaiActivity(id: 5, name: "Weekly sync", project: 12, color: "#B10DC9"),
            KimaiActivity(id: 1, name: "Consulting", project: nil, color: "#8BC34A"),
            KimaiActivity(id: 21, name: "Development", project: nil, color: "#009688"),
            KimaiActivity(id: 18, name: "Internal work", project: 13, color: "#2196F3"),
        ]
        s.users = [KimaiUser(id: 1, username: "admin"), KimaiUser(id: 2, username: "Claude")]
        func entry(_ id: Int, _ hoursAgo: Double, _ minutes: Int, project: Int, activity: Int, note: String? = nil, running: Bool = false) -> KimaiTimesheet {
            let begin = now.addingTimeInterval(-hoursAgo * 3600)
            let p = s.projects.first { $0.id == project }!
            return KimaiTimesheet(
                id: id, begin: begin, end: running ? nil : begin.addingTimeInterval(Double(minutes) * 60),
                duration: running ? 0 : minutes * 60, description: note, rate: Double(minutes) * 1.5, userId: 1,
                projectId: project, projectName: p.name, customerId: p.customer,
                customerName: s.customers.first { $0.id == p.customer }?.name,
                activityId: activity, activityName: s.activities.first { $0.id == activity }?.name)
        }
        s.recent = [
            entry(101, 3, 95, project: 12, activity: 3, note: "Lead routing webhook"),
            entry(102, 26, 60, project: 12, activity: 5),
            entry(103, 50, 45, project: 9, activity: 1, note: "Order sync service"),
            entry(104, 75, 120, project: 11, activity: 1),
        ]
        s.weekEntries = [entry(101, 3, 95, project: 12, activity: 3), entry(102, 26, 60, project: 12, activity: 5)]
        s.agentSessions = [
            AgentSession(agentName: "claude-code", projectId: 13, activityId: 18, customerName: "In-house", projectName: "Internal",
                         activityName: "Internal work", description: "Refactor billing export", begin: now.addingTimeInterval(-1260)),
        ]
        func pause(minutesAgo: Double, _ reason: PausedSession.Reason) {
            let at = now.addingTimeInterval(-minutesAgo * 60)
            s.paused = PausedSession(projectId: 12, activityId: 3, description: "Call tagging automation", tags: [],
                                     customerName: "Northwind Traders", projectName: "Ops Dashboard",
                                     activityName: "Automation", pausedAt: at, reason: reason, workedSeconds: 4380)
            if reason != .manual { s.awayNotice = AwayNotice(since: at, until: now) }
        }
        let offline = ConnectionState.offline("Can't reach Kimai: The Internet connection appears to be offline.")
        switch state {
        case .running, .lastError, .busy, .pendingStop:
            s.active = entry(200, 1.3, 0, project: 12, activity: 3, note: "Call tagging automation", running: true)
            if state == .lastError { s.lastError = "The request timed out. Kimai did not answer within 30 seconds." }
            if state == .busy { s.isBusy = true }
            if state == .pendingStop {
                // An idle auto-pause decided 10 minutes ago while Kimai was unreachable.
                s.pendingStop = PendingStop(entryId: 200, end: now.addingTimeInterval(-600), reason: .idle)
                s.connectionState = offline
            }
        case .paused:
            pause(minutesAgo: 10, .manual)
        case .away:
            pause(minutesAgo: 25, .idle)
        case .awayLong:
            pause(minutesAgo: 310, .sleep)
        case .awayDay:
            pause(minutesAgo: 26 * 60, .sleep)
        case .unconfigured:
            s.connection = nil
            s.connectionState = .unconfigured
        case .connecting:
            // Launch: only the persisted paused session is known yet.
            s.me = nil
            s.connectionState = .connecting
            s.recent = []
            s.weekEntries = []
            s.agentSessions = []
            pause(minutesAgo: 10, .manual)
        case .offline:
            s.connectionState = offline
        case .refusedAgent:
            s.agentSessions.append(
                AgentSession(agentName: "codex", projectId: 9, activityId: 21, customerName: "Acme Studio", projectName: "Consulting",
                             activityName: "Development", description: "Order sync retries", begin: now.addingTimeInterval(-7200),
                             stoppedAt: now.addingTimeInterval(-5400), lastError: "This period is locked. Ask an administrator to unlock it."))
        case .idle:
            break
        }
        return s
    }
}
