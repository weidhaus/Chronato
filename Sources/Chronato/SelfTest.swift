import ChronatoCore
import CryptoKit
import Foundation

/// `Chronato selftest --server <url> --token <t>`: end-to-end checks of the real
/// TrackerStore against scripts/mock-kimai.py (run it through scripts/e2e.sh).
/// Every scenario gets a fresh store (never `.shared`) on a scratch UserDefaults
/// suite without the Keychain; idle and sleep times are injected. Talks to
/// localhost only, needs CHRONATO_HOME (agents.json, AI session files), shows no windows.
@MainActor
final class SelfTest {
    static func run(_ args: [String]) async -> Int32 {
        var options: [String: String] = [:]
        for pair in stride(from: 0, to: args.count - 1, by: 2) { options[args[pair]] = args[pair + 1] }
        guard let server = options["--server"], let token = options["--token"], let url = URL(string: server),
              ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
            print("usage: Chronato selftest --server http://127.0.0.1:<port> --token <token>   (mock Kimai on localhost only)")
            return 2
        }
        guard ProcessInfo.processInfo.environment["CHRONATO_HOME"]?.isEmpty == false else {
            print("selftest: set CHRONATO_HOME to a scratch directory")
            return 2
        }
        // A bundled Chronato would post real notifications.
        guard Bundle.main.bundleIdentifier == nil else {
            print("selftest: run the bare binary (swift run), not the app bundle")
            return 2
        }
        let test = SelfTest(server: server, token: token, base: url)
        UserDefaults().removePersistentDomain(forName: suite)
        test.defaults.set(10, forKey: Prefs.idleMinutes)
        await test.all()
        UserDefaults().removePersistentDomain(forName: suite)
        print("\n\(test.checks) checks, \(test.failures) failed")
        return test.failures == 0 ? 0 : 1
    }

    /// One suite per checkout (from the binary's path): selftests in other
    /// worktrees may run at the same time and must not share prefs.
    static let suite = "chronato-selftest-" + SHA256.hash(data: Data((Bundle.main.executablePath ?? "").utf8))
        .prefix(4).map { String(format: "%02x", $0) }.joined()
    let server: String
    let token: String
    let base: URL
    let defaults = UserDefaults(suiteName: SelfTest.suite)!
    var checks = 0
    var failures = 0

    init(server: String, token: String, base: URL) {
        self.server = server
        self.token = token
        self.base = base
    }

    func all() async {
        print("process time zone \(TimeZone.current.identifier); mock Kimai user time zone Europe/Berlin")
        await scenario("a. connect", connect)
        await scenario("b. start", start)
        await scenario("c. note while running", note)
        await scenario("d. pause / resume / stop", pauseResumeStop)
        await scenario("e. start while another runs", startWhileRunning)
        await scenario("f. timer started in the browser", browserTimer)
        await scenario("g. idle auto-pause", idle)
        await scenario("h. sleep / wake", sleepWake)
        await scenario("i. 24 h cap", cap)
        await scenario("j. offline", offline)
        await scenario("k. toggle", toggle)
        await scenario("l. AI sessions", aiSessions)
        await scenario("m. refresh racing an action", race)
        await scenario("n. counting time away", countAway)
        await scenario("o. quit and relaunch", quitAndRelaunch)
        await scenario("p. menu and reports", menuAndReports)
        await scenario("q. Kimai time zone changed while running", timeZoneChange)
        await scenario("r. Kimai tracking mode without written times", trackingMode)
    }

    // MARK: Scenarios

    func connect() async throws {
        let rejected = TrackerStore(defaults: defaults, keychain: false)
        var error: Error?
        do { try await rejected.connect(url: server, token: "wrong-token") } catch let e { error = e }
        check("a.badToken.rejected", error != nil && rejected.connection == nil && rejected.connectionState == .unconfigured,
              "error=\(error?.localizedDescription ?? "nil") state=\(rejected.connectionState)")
        // Refused before any request: the token would cross the network in clear text.
        error = nil
        do { try await rejected.connect(url: "http://kimai.example.net", token: token) } catch let e { error = e }
        check("a.plainHTTPRefused", error?.localizedDescription == KimaiConnection.URLProblem.notHTTPS.localizedDescription && rejected.connection == nil,
              "error=\(error?.localizedDescription ?? "nil")")

        let store = try await freshStore()
        check("a.online", store.connectionState == .online, "\(store.connectionState)")
        check("a.me", store.me?.id == 1 && store.me?.username == "admin", "me=\(String(describing: store.me))")
        check("a.version", store.serverVersion == "2.69.0", "version=\(store.serverVersion ?? "nil")")
        check("a.timeZoneFromMe", store.kimaiTimeZone.identifier == "Europe/Berlin", "kimaiTimeZone=\(store.kimaiTimeZone.identifier)")
        check("a.firstWeekday", store.calendar.firstWeekday == 2, "firstWeekday=\(store.calendar.firstWeekday)")
        check("a.customers", Set(store.customers.map(\.id)) == [10, 7, 12], "\(store.customers.map(\.id))")
        check("a.projects", Set(store.projects.map(\.id)) == [12, 9, 13], "\(store.projects.map(\.id))")
        check("a.activities", Set(store.activities.map(\.id)) == [3, 5, 18, 1, 21], "\(store.activities.map(\.id))")
        check("a.users", Set(store.users.map(\.id)) == [1, 2], "\(store.users.map(\.id))")
        check("a.projectWithoutGlobalActivities", store.activities(forProject: 13).map(\.id) == [18], "\(store.activities(forProject: 13).map(\.id))")
        check("a.projectWithGlobalActivities", Set(store.activities(forProject: 12).map(\.id)) == [3, 5, 1, 21], "\(store.activities(forProject: 12).map(\.id))")
        check("a.idle", store.active == nil && store.paused == nil && store.lastError == nil,
              "active=\(show(store.active)) paused=\(String(describing: store.paused)) lastError=\(store.lastError ?? "nil")")
        let recent = store.recent.map { "\($0.projectId)/\($0.activityId)/\($0.description ?? "")" }
        check("a.recent", recent == ["12/3/Lead routing webhook", "12/5/", "12/3/Call tagging automation", "9/1/Order sync service"]
              && store.recent.allSatisfy { $0.customerName != nil && $0.activityName != nil }, "\(recent)")
        // TrackingPolicy.recentCombinations keeps distinct (project, activity, note); Kimai has
        // "Call tagging automation" (28 h ago) besides "Lead routing webhook" on Ops Dashboard / Automation.
        check("a.recentDistinctNotes", recent.contains("12/3/Call tagging automation"),
              "recent=\(recent); Kimai has an older 12/3 entry \"Call tagging automation\"")
        // The newest entry is on an archived project: Kimai would refuse to start it again.
        check("a.recentOnlyVisibleCatalog", !store.recent.contains { $0.projectId == 98 }, "recent=\(recent)")
        try await checkTotals("a", store)
    }

    func start() async throws {
        let store = try await freshStore()
        let t0 = Date()
        await store.start(projectId: 12, activityId: 3, description: "  Call tagging automation  ")
        let running = try await self.running()
        check("b.oneRunning", running.count == 1, "running=\(running.map(show))")
        guard let r = running.first else { return }
        check("b.fields", r.project == 12 && r.activity == 3 && r.description == "Call tagging automation", show(r))
        // Kimai floors a server-side begin to the minute (default rounding).
        check("b.beginNow", within(r.begin, t0 - 61, Date() + 1), "begin=\(t(r.begin)) started=\(t(t0))")
        check("b.storeActive", store.active?.id == r.id && store.active?.customerName == "Northwind Traders"
              && store.active?.activityName == "Automation", "active=\(show(store.active))")
        check("b.noError", store.lastError == nil, store.lastError ?? "")
        let recent = store.recent.map { "\($0.projectId)/\($0.activityId)/\($0.description ?? "")" }
        check("b.recentNotRunning", !store.recent.contains { $0.end == nil } && !recent.contains("12/3/Call tagging automation"),
              "recent=\(recent) while 12/3 \"Call tagging automation\" runs")
        check("b.ticking", store.isTicking && store.elapsedMinutes == store.elapsedSeconds / 60,
              "ticking=\(store.isTicking) minutes=\(store.elapsedMinutes) seconds=\(store.elapsedSeconds)")
        check("b.lastChoiceInScratchDefaults", defaults.integer(forKey: Prefs.lastCustomerId) == 10
              && defaults.integer(forKey: Prefs.lastProjectId) == 12 && defaults.integer(forKey: Prefs.lastActivityId) == 3,
              "customer=\(defaults.integer(forKey: Prefs.lastCustomerId)) project=\(defaults.integer(forKey: Prefs.lastProjectId)) activity=\(defaults.integer(forKey: Prefs.lastActivityId))")
        try await checkTotals("b", store)
    }

    func note() async throws {
        let store = try await freshStore()
        await store.start(projectId: 12, activityId: 3, description: "Lead routing webhook")
        guard let id = store.active?.id else { return check("c.setup", false, "nothing started: \(store.lastError ?? "")") }
        await store.setDescription("  Lead routing webhook v2 ")
        let e = try await entry(id)
        check("c.patched", e?.description == "Lead routing webhook v2" && e?.end == nil, show(e))
        check("c.store", store.active?.id == id && store.active?.description == "Lead routing webhook v2" && store.lastError == nil,
              "active=\(show(store.active)) lastError=\(store.lastError ?? "nil")")

        // Typed but not committed: saved before the entry is replaced (switch) or ended (hot key).
        store.setNoteDraft("  Typed, not committed ", for: id)
        await store.start(projectId: 9, activityId: 1, description: "Next task")
        let switched = try await entry(id)
        check("c.draftSavedOnSwitch", switched?.description == "Typed, not committed" && switched?.end != nil, show(switched))
        guard let next = store.active?.id else { return check("c.draft.setup", false, "nothing started: \(store.lastError ?? "")") }
        store.setNoteDraft("Typed before the hot key", for: next)
        await store.toggle()
        let paused = try await entry(next)
        check("c.draftSavedOnHotKeyPause", paused?.description == "Typed before the hot key" && store.paused?.description == "Typed before the hot key",
              "kimai=\(show(paused)) paused=\(store.paused?.description ?? "nil")")
        // A note committed after its entry was replaced still reaches that entry.
        await store.setDescription("Committed late", entryId: id)
        let late = try await entry(id)
        check("c.commitAfterSwitch", late?.description == "Committed late" && store.paused?.description == "Typed before the hot key",
              "kimai=\(show(late)) paused=\(store.paused?.description ?? "nil")")
    }

    func pauseResumeStop() async throws {
        let store = try await freshStore()
        await store.start(projectId: 12, activityId: 3, description: "Call tagging automation")
        guard let first = store.active else { return check("d.setup", false, "nothing started: \(store.lastError ?? "")") }

        let tp = Date()
        await store.pause()
        let e1 = try await entry(first.id)
        check("d.pause.ended", within(e1?.end, tp - 1, Date() + 61), "end=\(t(e1?.end)) paused=\(t(tp))")
        let p = store.paused
        check("d.pause.state", store.active == nil && p?.reason == .manual && p?.projectId == 12 && p?.activityId == 3
              && p?.description == "Call tagging automation", "active=\(show(store.active)) paused=\(String(describing: p))")
        check("d.pause.names", p?.customerName == "Northwind Traders" && p?.projectName == "Ops Dashboard" && p?.activityName == "Automation",
              "names=\(p?.customerName ?? "nil") / \(p?.projectName ?? "nil") / \(p?.activityName ?? "nil")")
        let runningAfterPause = try await running()
        check("d.pause.noneRunning", runningAfterPause.isEmpty, "running=\(runningAfterPause.map(show))")
        check("d.pause.persistedInScratchSuite", defaults.data(forKey: "pausedSession") != nil, "no pausedSession in suite")

        await store.setDescription("Call tagging automation, part 2")
        let e1b = try await entry(first.id)
        check("d.pausedNote", store.paused?.description == "Call tagging automation, part 2" && e1b?.description == "Call tagging automation",
              "paused=\(store.paused?.description ?? "nil") kimai=\(e1b?.description ?? "nil")")

        let tr = Date()
        await store.resume()
        let run = try await running()
        check("d.resume.oneNewRunning", run.count == 1 && run.first?.id != first.id, "running=\(run.map(show))")
        if let r = run.first {
            check("d.resume.sameFields", r.project == 12 && r.activity == 3 && r.description == "Call tagging automation, part 2", show(r))
            check("d.resume.beginNow", within(r.begin, tr - 61, Date() + 1), "begin=\(t(r.begin)) resumed=\(t(tr))")
        }
        check("d.resume.store", store.paused == nil && store.active?.id == run.first?.id && store.lastError == nil,
              "active=\(show(store.active)) paused=\(String(describing: store.paused))")

        let ts = Date()
        await store.stop()
        let e2 = try await entry(run.first?.id ?? -1)
        check("d.stop.ended", within(e2?.end, ts - 1, Date() + 61), "end=\(t(e2?.end)) stopped=\(t(ts))")
        let runningAfterStop = try await running()
        check("d.stop.state", store.active == nil && store.paused == nil && runningAfterStop.isEmpty,
              "active=\(show(store.active)) paused=\(String(describing: store.paused))")
        check("d.stop.pausedClearedInSuite", defaults.data(forKey: "pausedSession") == nil, "pausedSession still stored")
        check("d.stop.tickerStopped", !store.isTicking && store.elapsedMinutes == 0, "the 1 s ticker runs with nothing to show")
        try await checkTotals("d", store)
    }

    func startWhileRunning() async throws {
        let store = try await freshStore()
        await store.start(projectId: 12, activityId: 3, description: "first")
        guard let first = store.active?.id else { return check("e.setup", false, "nothing started: \(store.lastError ?? "")") }
        await store.start(projectId: 9, activityId: 1, description: "second")
        let firstEntry = try await entry(first)
        check("e.firstEnded", firstEntry?.end != nil, show(firstEntry))
        let run = try await running()
        check("e.exactlyOneRunning", run.count == 1 && run.first?.project == 9 && run.first?.activity == 1 && run.first?.description == "second",
              "running=\(run.map(show))")
        check("e.store", store.active?.id == run.first?.id && store.lastError == nil, "active=\(show(store.active)) lastError=\(store.lastError ?? "nil")")

        // A timer started in the browser that the store has not seen yet (no refresh in between).
        let browser = try await startExternal(project: 13, activity: 18, description: "from the browser")
        await store.start(projectId: 12, activityId: 5, description: "third")
        let run2 = try await running()
        check("e.unseenBrowserTimer.exactlyOneRunning", run2.count == 1 && run2.first?.project == 12 && run2.first?.activity == 5,
              "running=\(run2.map(show))")
        let browserEntry = try await entry(browser.id)
        check("e.unseenBrowserTimer.ended", browserEntry?.end != nil, show(browserEntry))
        check("e.unseenBrowserTimer.noError", store.lastError == nil && store.active?.id == run2.first?.id,
              "active=\(show(store.active)) lastError=\(store.lastError ?? "nil")")

        // The new entry is created first; Kimai stops the old one in the same request. A start
        // Kimai refuses (archived project) therefore leaves the running timer running.
        guard let third = run2.first?.id else { return }
        await store.start(projectId: 98, activityId: 1, description: "On the archived project")
        let run3 = try await running()
        check("e.refusedStart.keepsRunning", store.lastError != nil && run3.map(\.id) == [third] && store.active?.id == third,
              "running=\(run3.map(show)) active=\(show(store.active)) lastError=\(store.lastError ?? "nil")")
        // A Kimai that allows two running entries keeps the old one: Chronato stops it afterwards.
        try await post("__config", ["hard_limit": 2])
        await store.start(projectId: 9, activityId: 21, description: "fourth")
        let run4 = try await running()
        let thirdEntry = try await entry(third)
        check("e.hardLimit2.oldStopped", run4.count == 1 && run4.first?.description == "fourth" && thirdEntry?.end != nil,
              "running=\(run4.map(show)) third=\(show(thirdEntry))")
    }

    func browserTimer() async throws {
        let store = try await freshStore()
        let browser = try await startExternal(project: 9, activity: 21, description: "Started in the browser")
        await store.refresh()
        check("f.browserTimerActive", store.active?.id == browser.id && store.active?.projectName == "Consulting"
              && store.active?.customerName == "Acme Studio" && store.active?.activityName == "Development", "active=\(show(store.active))")
        try await stopExternal(browser.id)
        await store.refresh()
        check("f.browserStopClears", store.active == nil, "active=\(show(store.active))")

        await store.start(projectId: 12, activityId: 3, description: "Paused here")
        await store.pause()
        check("f.setupPaused", store.paused != nil, "paused=nil lastError=\(store.lastError ?? "nil")")
        let resumed = try await startExternal(project: 12, activity: 3, description: "Paused here")
        await store.refresh()
        check("f.resumedInBrowserDropsPaused", store.paused == nil && store.active?.id == resumed.id,
              "active=\(show(store.active)) paused=\(String(describing: store.paused))")
    }

    func idle() async throws {
        let store = try await freshStore()
        let browser = try await startExternal(project: 12, activity: 3, description: "Idle test", beginAgo: 30 * 60)
        await store.refresh()
        check("g.setup", store.active?.id == browser.id, "active=\(show(store.active))")
        check("g.elapsedMinutes", store.elapsedMinutes == store.elapsedSeconds / 60 && store.elapsedMinutes >= 29,
              "minutes=\(store.elapsedMinutes) seconds=\(store.elapsedSeconds)")

        let now = Date(), left = now - 15 * 60
        await store.idleTick(now: now, lastInput: left)
        let ended = try await entry(browser.id)
        // Kimai ceils an end to the minute (default rounding).
        check("g.idle.endsAtLastInput", within(ended?.end, left - 1, left + 61), "end=\(t(ended?.end)) lastInput=\(t(left))")
        let runningAfterIdle = try await running()
        check("g.idle.paused", store.active == nil && store.paused?.reason == .idle && runningAfterIdle.isEmpty,
              "active=\(show(store.active)) paused=\(String(describing: store.paused))")
        check("g.idle.pausedAtLastInput", within(store.paused?.pausedAt, left - 1, left + 61), "pausedAt=\(t(store.paused?.pausedAt))")

        await store.idleTick(now: now + 30, lastInput: left)
        check("g.noNoticeWhileAway", store.awayNotice == nil, "awayNotice=\(String(describing: store.awayNotice))")
        await store.idleTick(now: Date(), lastInput: Date())
        check("g.awayNoticeOnReturn", store.awayNotice != nil && store.awayNotice?.since == store.paused?.pausedAt,
              "awayNotice=\(String(describing: store.awayNotice)) pausedAt=\(t(store.paused?.pausedAt))")

        let pausedAt = store.paused?.pausedAt
        await store.resolveAway(.resumeCountingAway)
        let run = try await running()
        check("g.countingAway.oneRunning", run.count == 1 && run.first?.project == 12 && run.first?.activity == 3
              && run.first?.description == "Idle test", "running=\(run.map(show)) lastError=\(store.lastError ?? "nil")")
        guard let counted = run.first, let pausedAt else { return }
        check("g.countingAway.beginsAtPausedAt", abs(counted.begin.timeIntervalSince(pausedAt)) <= 1,
              "begin=\(t(counted.begin)) pausedAt=\(t(pausedAt))")
        if let previousEnd = ended?.end {
            check("g.countingAway.noOverlapWithPausedEntry", counted.begin >= previousEnd,
                  "paused entry ends \(t(previousEnd)) in Kimai, resumed entry begins \(t(counted.begin)): \(Int(previousEnd.timeIntervalSince(counted.begin))) s counted twice")
        }
        check("g.countingAway.store", store.paused == nil && store.awayNotice == nil && store.active?.id == counted.id,
              "active=\(show(store.active)) paused=\(String(describing: store.paused))")

        // .resume: the away time is not counted.
        let now2 = Date(), left2 = now2 - 11 * 60
        await store.idleTick(now: now2, lastInput: left2)
        let ended2 = try await entry(counted.id)
        check("g.idle2.endsAtLastInput", within(ended2?.end, left2 - 1, left2 + 61) && store.paused?.reason == .idle,
              "end=\(t(ended2?.end)) lastInput=\(t(left2)) paused=\(String(describing: store.paused))")
        await store.idleTick(now: Date(), lastInput: Date())
        check("g.idle2.awayNotice", store.awayNotice != nil, "no away notice")
        let tr = Date()
        await store.resolveAway(.resume)
        let run2 = try await running()
        check("g.resume.beginsNow", run2.count == 1 && within(run2.first?.begin, tr - 61, Date() + 1) && run2.first?.project == 12
              && run2.first?.activity == 3 && run2.first?.description == "Idle test", "running=\(run2.map(show)) resumed=\(t(tr))")
        check("g.resume.store", store.paused == nil && store.awayNotice == nil && store.active?.id == run2.first?.id,
              "active=\(show(store.active)) paused=\(String(describing: store.paused))")

        // .stayPaused, then .stop.
        _ = try await startExternal(project: 9, activity: 1, description: "Away again", beginAgo: 20 * 60)
        await store.refresh()
        let now3 = Date()
        await store.idleTick(now: now3, lastInput: now3 - 12 * 60)
        await store.idleTick(now: Date(), lastInput: Date())
        check("g.stayPaused.setup", store.awayNotice != nil && store.paused?.reason == .idle, "paused=\(String(describing: store.paused))")
        await store.resolveAway(.stayPaused)
        let runningStayPaused = try await running()
        check("g.stayPaused", store.paused?.reason == .manual && store.awayNotice == nil && runningStayPaused.isEmpty,
              "paused=\(String(describing: store.paused)) awayNotice=\(String(describing: store.awayNotice))")
        await store.idleTick(now: Date(), lastInput: Date())
        check("g.stayPaused.noNewNotice", store.awayNotice == nil, "awayNotice=\(String(describing: store.awayNotice))")
        await store.resolveAway(.stop)
        let runningAfterStop = try await running()
        check("g.stop", store.paused == nil && store.awayNotice == nil && runningAfterStop.isEmpty, "paused=\(String(describing: store.paused))")

        // A timer started in the browser while this Mac sat idle gets the full grace.
        let elsewhere = try await startExternal(project: 12, activity: 5, description: "Started elsewhere")
        await store.refresh()
        await store.idleTick(now: Date(), lastInput: Date() - 30 * 60)
        let elsewhereEntry = try await entry(elsewhere.id)
        check("g.browserStartWhileIdle.grace", elsewhereEntry?.end == nil && store.active?.id == elsewhere.id && store.paused == nil,
              "kimai=\(show(elsewhereEntry)) paused=\(String(describing: store.paused))")
        // Still no input on this Mac since it began: no evidence the user stopped, keep it running.
        await store.idleTick(now: Date() + 15 * 60, lastInput: Date() - 30 * 60)
        let elsewhereLater = try await entry(elsewhere.id)
        check("g.browserStartWhileIdle.keepsRunning", elsewhereLater?.end == nil && store.active?.id == elsewhere.id && store.paused == nil,
              "kimai=\(show(elsewhereLater)) paused=\(String(describing: store.paused))")

        // Idle pause switched off.
        defaults.set(0, forKey: Prefs.idleMinutes)
        defer { defaults.set(10, forKey: Prefs.idleMinutes) }
        let longRunner = try await startExternal(project: 12, activity: 5, beginAgo: 30 * 60)
        await store.refresh()
        await store.idleTick(now: Date(), lastInput: Date() - 25 * 60)
        let longRunnerEntry = try await entry(longRunner.id)
        check("g.idleOff.keepsRunning", longRunnerEntry?.end == nil && store.active?.id == longRunner.id && store.paused == nil,
              "kimai=\(show(longRunnerEntry)) active=\(show(store.active))")
    }

    func sleepWake() async throws {
        let store = try await freshStore()
        let browser = try await startExternal(project: 12, activity: 3, description: "Sleep test", beginAgo: 60 * 60)
        await store.refresh()
        check("h.setup", store.active?.id == browser.id, "active=\(show(store.active))")
        let now = Date(), lastInput = now - 45 * 60
        store.willSleep(lastInput: lastInput)
        // A tick before the wake handler (overdue at wake, or a Power Nap dark wake) reads a HID idle
        // time that stood still while asleep, i.e. a too recent last input. It must decide nothing.
        await store.idleTick(now: now, lastInput: now - 11 * 60)
        let duringSleep = try await entry(browser.id)
        check("h.tickWhileAsleepIgnored", duringSleep?.end == nil && store.active?.id == browser.id, show(duringSleep))
        await store.didWake(now: now, lastInput: now)
        let ended = try await entry(browser.id)
        check("h.sleep.endsAtLastInputBeforeSleep", within(ended?.end, lastInput - 1, lastInput + 61), "end=\(t(ended?.end)) lastInput=\(t(lastInput))")
        check("h.sleep.paused", store.active == nil && store.paused?.reason == .sleep, "active=\(show(store.active)) paused=\(String(describing: store.paused))")
        check("h.sleep.awayNoticeOnWake", store.awayNotice != nil && store.awayNotice?.since == store.paused?.pausedAt,
              "awayNotice=\(String(describing: store.awayNotice))")
        await store.resolveAway(.stop)

        // Asleep over a weekend (> 24 h): ends when the user left, not at begin + 24 h, also with idle pause off.
        for idle in [10, 0] {
            defaults.set(idle, forKey: Prefs.idleMinutes)
            let weekend = try await startExternal(project: 12, activity: 5, description: "Weekend", beginAgo: 65 * 3600)
            await store.refresh()
            let left = weekend.begin + 3600
            store.willSleep(lastInput: left)
            await store.idleTick(now: Date(), lastInput: Date()) // overdue at wake: ignored
            await store.didWake(now: Date(), lastInput: Date())
            let e = try await entry(weekend.id)
            check("h.longSleep.idle\(idle).endsWhenLeft", within(e?.end, left - 1, left + 61) && store.active == nil && store.paused == nil,
                  "end=\(t(e?.end)) left=\(t(left)) begin=\(t(weekend.begin)) paused=\(String(describing: store.paused))")
        }
        defaults.set(10, forKey: Prefs.idleMinutes)

        // A nap shorter than the idle limit keeps the timer running.
        await store.start(projectId: 12, activityId: 3, description: "Nap test")
        guard let napper = store.active?.id else { return check("h.nap.setup", false, "nothing started: \(store.lastError ?? "")") }
        let napStart = Date()
        store.willSleep(lastInput: napStart)
        await store.didWake(now: napStart + 5 * 60, lastInput: napStart + 5 * 60)
        let napEntry = try await entry(napper)
        check("h.nap.keepsRunning", napEntry?.end == nil && store.active?.id == napper && store.paused == nil,
              "kimai=\(show(napEntry)) paused=\(String(describing: store.paused))")
        // No input since that wake (HID idle time still counts from before the sleep): ten idle
        // minutes later the entry ends at the input before the sleep, not at the wake.
        await store.idleTick(now: napStart + 16 * 60, lastInput: napStart + 5 * 60)
        let napEnded = try await entry(napper)
        check("h.napThenAway.endsAtInputBeforeSleep", within(napEnded?.end, napStart - 1, napStart + 61),
              "end=\(t(napEnded?.end)) inputBeforeSleep=\(t(napStart))")

        // Wake while Kimai is unreachable: the pause is applied once it is back, with the old end.
        let offlineRunner = try await startExternal(project: 9, activity: 1, description: "Sleep offline", beginAgo: 40 * 60)
        await store.refresh()
        let now3 = Date(), lastInput3 = now3 - 30 * 60
        store.willSleep(lastInput: lastInput3)
        try await setOffline(true)
        await store.didWake(now: now3, lastInput: now3)
        let offlineEntry = try await entry(offlineRunner.id)
        check("h.offlineWake.notAppliedYet", offlineEntry?.end == nil, show(offlineEntry))
        try await setOffline(false)
        await store.refresh()
        await store.idleTick(now: Date(), lastInput: Date())
        let ended3 = try await entry(offlineRunner.id)
        check("h.offlineWake.appliedWithOldEnd", within(ended3?.end, lastInput3 - 1, lastInput3 + 61), "end=\(t(ended3?.end)) lastInput=\(t(lastInput3))")
        check("h.offlineWake.paused", store.paused?.reason == .sleep && store.active == nil,
              "active=\(show(store.active)) paused=\(String(describing: store.paused)) lastError=\(store.lastError ?? "nil")")
    }

    func cap() async throws {
        let store = try await freshStore()
        let forgotten = try await startExternal(project: 12, activity: 3, description: "Forgotten timer", beginAgo: 25 * 3600)
        await store.refresh()
        check("i.setup", store.active?.id == forgotten.id, "active=\(show(store.active))")
        await store.idleTick(now: Date(), lastInput: Date())
        let e = try await entry(forgotten.id)
        if let e, let end = e.end {
            check("i.cap.withinADay", end >= e.begin + 60 && end <= e.begin + 24 * 3600,
                  "ran \(String(format: "%.3f", end.timeIntervalSince(e.begin) / 3600)) h")
        } else {
            check("i.cap.ended", false, show(e))
        }
        let runningAfterCap = try await running()
        check("i.cap.stoppedForGood", store.active == nil && store.paused == nil && runningAfterCap.isEmpty,
              "active=\(show(store.active)) paused=\(String(describing: store.paused)) lastError=\(store.lastError ?? "nil")")

        let forgotten2 = try await startExternal(project: 9, activity: 1, description: "Forgotten again", beginAgo: 25 * 3600)
        await store.refresh()
        let left = Date() - 22 * 3600
        await store.idleTick(now: Date(), lastInput: left)
        let e2 = try await entry(forgotten2.id)
        check("i.cap.endsAtLastInput", within(e2?.end, left - 1, left + 61), "end=\(t(e2?.end)) lastInput=\(t(left))")
    }

    func offline() async throws {
        let store = try await freshStore()
        let runner = try await startExternal(project: 12, activity: 3, description: "Offline test", beginAgo: 30 * 60)
        await store.refresh()
        check("j.setup", store.active?.id == runner.id, "active=\(show(store.active))")
        let before = try await entries().count

        try await setOffline(true)
        let now = Date(), left = now - 15 * 60
        await store.idleTick(now: now, lastInput: left) // decided while Kimai is unreachable
        check("j.offline.state", isOffline(store), "connectionState=\(store.connectionState)")
        // The menu shows the waiting pause: the time stops at the last input instead of counting the absence.
        let expected = Int(left.timeIntervalSince(store.active?.begin ?? left))
        check("j.offline.pendingShown", store.pendingStopAt == left && abs(store.elapsedSeconds - expected) <= 1,
              "pendingStopAt=\(t(store.pendingStopAt)) elapsed=\(store.elapsedSeconds) s, want \(expected) s")
        let runnerEntry = try await entry(runner.id)
        check("j.offline.pendingNotApplied", runnerEntry?.end == nil && store.active?.id == runner.id,
              "kimai=\(show(runnerEntry)) active=\(show(store.active))")
        await store.start(projectId: 9, activityId: 1, description: "while offline")
        check("j.offline.start.reportsError", store.lastError != nil && store.active?.id == runner.id,
              "lastError=\(store.lastError ?? "nil") active=\(show(store.active))")
        await store.pause()
        check("j.offline.pause.reportsError", store.lastError != nil && store.paused == nil && store.active?.id == runner.id,
              "lastError=\(store.lastError ?? "nil") paused=\(String(describing: store.paused))")
        let countOffline = try await entries().count, runningOffline = try await running()
        check("j.offline.nothingWritten", countOffline == before && runningOffline.map(\.id) == [runner.id],
              "running=\(runningOffline.map(show))")

        try await setOffline(false)
        await store.refresh()
        check("j.backOnline", store.connectionState == .online, "connectionState=\(store.connectionState)")
        await store.idleTick(now: Date(), lastInput: Date()) // the user is back; the 15 s tick retries
        let e = try await entry(runner.id)
        check("j.pendingStopAppliedWithOldEnd", within(e?.end, left - 1, left + 61), "end=\(t(e?.end)) lastInput=\(t(left))")
        check("j.pendingStop.paused", store.paused?.reason == .idle && store.active == nil && store.lastError == nil,
              "paused=\(String(describing: store.paused)) active=\(show(store.active)) lastError=\(store.lastError ?? "nil")")

        // A proxy answering 503 is handled like an outage.
        try await setOffline(true, mode: "503")
        await store.refresh()
        check("j.503.offline", isOffline(store), "connectionState=\(store.connectionState)")
        await store.resume()
        let running503 = try await running()
        check("j.503.resume.reportsError", store.lastError?.contains("503") == true && store.paused != nil && running503.isEmpty,
              "lastError=\(store.lastError ?? "nil") paused=\(String(describing: store.paused))")
        try await setOffline(false)
        await store.refresh()
        await store.resume()
        let runningRecovered = try await running()
        check("j.503.recovered", runningRecovered.count == 1 && store.paused == nil && store.lastError == nil && store.connectionState == .online,
              "running=\(runningRecovered.map(show)) lastError=\(store.lastError ?? "nil")")

        // Kimai is back, the auto-pause still waits, and the user pauses or switches first:
        // the entry ends when they left, not now.
        let paused2 = try await decidePendingWhileOffline(store, description: "Pending, then paused")
        await store.pause()
        let e2 = try await entry(paused2.entry.id)
        check("j.manualPause.usesPendingEnd", within(e2?.end, paused2.left - 1, paused2.left + 61) && store.paused?.reason == .idle
              && store.awayNotice != nil, "end=\(t(e2?.end)) left=\(t(paused2.left)) paused=\(String(describing: store.paused))")
        await store.resolveAway(.stop)
        let switched = try await decidePendingWhileOffline(store, description: "Pending, then switched")
        await store.start(projectId: 9, activityId: 1, description: "Switched after a pending pause")
        let e3 = try await entry(switched.entry.id), run3 = try await running()
        check("j.switch.usesPendingEnd", within(e3?.end, switched.left - 1, switched.left + 61) && run3.count == 1
              && run3.first?.description == "Switched after a pending pause", "end=\(t(e3?.end)) left=\(t(switched.left)) running=\(run3.map(show))")
        // ... unless the entry was stopped elsewhere meanwhile: that end wins.
        let elsewhere = try await decidePendingWhileOffline(store, description: "Pending, stopped in the browser")
        try await stopExternal(elsewhere.entry.id)
        let stoppedThere = try await entry(elsewhere.entry.id)?.end
        await store.pause()
        let e3b = try await entry(elsewhere.entry.id)
        check("j.manualPause.endSetElsewhereWins", stoppedThere != nil && e3b?.end == stoppedThere && store.lastError == nil,
              "end=\(t(e3b?.end)) stopped in the browser at \(t(stoppedThere)) lastError=\(store.lastError ?? "nil")")
        await store.resolveAway(.stop)

        // Back and working while Kimai is still unreachable: once it answers, the entry ends when the
        // user left and goes on from when they came back (the away window, not the outage, is unbooked).
        let worked = try await startExternal(project: 12, activity: 5, description: "Worked through the outage", beginAgo: 40 * 60)
        await store.refresh()
        try await setOffline(true)
        let n4 = Date(), left4 = n4 - 20 * 60, back4 = n4 - 5 * 60
        await store.idleTick(now: n4 - 10 * 60, lastInput: left4)
        await store.idleTick(now: n4, lastInput: back4)
        try await setOffline(false)
        await store.refresh()
        let e4 = try await entry(worked.id), run4 = try await running()
        check("j.backWhileOffline.endsWhenLeft", within(e4?.end, left4 - 1, left4 + 61), "end=\(t(e4?.end)) left=\(t(left4))")
        check("j.backWhileOffline.resumedWhenBack", run4.count == 1 && run4.first?.description == "Worked through the outage"
              && within(run4.first?.begin, back4 - 1, back4 + 1) && store.active?.id == run4.first?.id && store.paused == nil,
              "running=\(run4.map(show)) back=\(t(back4)) paused=\(String(describing: store.paused))")

        // A rate limit (429) or a captive portal's HTML answering the auto-pause: tried again, not given up.
        let retried = try await startExternal(project: 12, activity: 3, description: "Retried", beginAgo: 30 * 60)
        await store.refresh()
        let n5 = Date(), left5 = n5 - 15 * 60
        try await fault("/api/timesheets/active", ["status": 429, "body": ["code": 429, "message": "Too Many Requests"]])
        await store.idleTick(now: n5, lastInput: left5)
        let after429 = try await entry(retried.id)
        try await fault("/api/timesheets/active", ["status": 200, "raw": "<html>Sign in to the guest Wi-Fi</html>"])
        await store.idleTick(now: n5 + 15, lastInput: left5)
        let afterPortal = try await entry(retried.id)
        await store.idleTick(now: n5 + 30, lastInput: left5)
        let e5 = try await entry(retried.id)
        check("j.transientFailures.retried", after429?.end == nil && afterPortal?.end == nil && within(e5?.end, left5 - 1, left5 + 61)
              && store.paused?.reason == .idle, "after 429 \(show(after429)); after HTML \(show(afterPortal)); then \(show(e5))")

        // Kimai refusing it (403, e.g. a locked period) is not retried every tick; reconnecting re-arms it.
        let refused = try await startExternal(project: 12, activity: 3, description: "Refused", beginAgo: 30 * 60)
        await store.refresh()
        let n6 = Date(), left6 = n6 - 15 * 60
        try await fault("/api/timesheets/\(refused.id)", ["method": "PATCH", "status": 403, "body": ["code": 403, "message": "This period is locked"]])
        await store.idleTick(now: n6, lastInput: left6)
        let reported = store.lastError
        await store.idleTick(now: n6 + 15, lastInput: left6)
        let afterRefusal = try await entry(refused.id)
        check("j.refused.notRetried", reported?.contains("403") == true && afterRefusal?.end == nil && store.active?.id == refused.id,
              "lastError=\(reported ?? "nil") kimai=\(show(afterRefusal))")
        try await store.connect(url: server, token: token)
        await store.idleTick(now: n6 + 30, lastInput: left6)
        let e6 = try await entry(refused.id)
        check("j.refused.reconnectRearms", within(e6?.end, left6 - 1, left6 + 61), "end=\(t(e6?.end)) left=\(t(left6))")
    }

    /// A browser timer that ran 30 min, an idle pause decided while Kimai was unreachable, Kimai back (no refresh yet).
    func decidePendingWhileOffline(_ store: TrackerStore, description: String) async throws -> (entry: MockEntry, left: Date) {
        let runner = try await startExternal(project: 12, activity: 3, description: description, beginAgo: 30 * 60)
        await store.refresh()
        try await setOffline(true)
        let now = Date(), left = now - 15 * 60
        await store.idleTick(now: now, lastInput: left)
        try await setOffline(false)
        return (runner, left)
    }

    func toggle() async throws {
        let store = try await freshStore()
        guard let last = store.recent.first else { return check("k.setup", false, "recent is empty") }
        await store.toggle()
        let r1 = try await running()
        check("k.idle→startsMostRecent", r1.count == 1 && r1.first?.project == last.projectId && r1.first?.activity == last.activityId
              && r1.first?.description == last.description, "running=\(r1.map(show)) recent.first=\(show(last))")
        await store.toggle()
        let runningPaused = try await running()
        check("k.running→pause", runningPaused.isEmpty && store.paused?.reason == .manual && store.active == nil,
              "running=\(runningPaused.map(show)) paused=\(String(describing: store.paused))")
        await store.toggle()
        let r2 = try await running()
        check("k.paused→resume", r2.count == 1 && r2.first?.id != r1.first?.id && r2.first?.project == last.projectId
              && r2.first?.activity == last.activityId && r2.first?.description == last.description && store.paused == nil,
              "running=\(r2.map(show)) paused=\(String(describing: store.paused))")

        // The menu is usually closed: a key press that did nothing says so (returned and posted).
        guard let current = store.active?.id else { return check("k.feedback.setup", false, "nothing runs") }
        try await setOffline(true)
        let failed = await store.toggle()
        check("k.feedbackWhenFailed", failed?.hasPrefix("Couldn't pause") == true && store.active?.id == current,
              "feedback=\(failed ?? "nil") active=\(show(store.active))")
        try await setOffline(false)
        await store.refresh()
        try await fault("/api/timesheets/\(current)/stop", ["seconds": 1.0])
        let slowPause = Task { await store.pause() }
        try await Task.sleep(for: .milliseconds(300))
        let busy = await store.toggle()
        _ = await slowPause.value
        check("k.feedbackWhenBusy", busy?.contains("busy") == true && store.paused != nil, "feedback=\(busy ?? "nil")")
    }

    func aiSessions() async throws {
        try await post("__reset")
        let human = try await startExternal(project: 12, activity: 3, description: "Human at work")
        var config = AIConfig(bookingUserId: 2)
        _ = try config.addAgent(named: "Claude Code")
        _ = try config.addAgent(named: "Codex") // its tag ai-codex is not in Kimai yet
        try config.save()
        let now = Date(), dead = try deadPid()
        let gone = AgentSession(agentName: "claude-code", projectId: 13, activityId: 18, customerName: "In-house", projectName: "Internal",
                                activityName: "Internal work", description: "Refactor billing export",
                                begin: now - 40 * 60, lastSeen: now - 10 * 60, pid: dead)
        let alive = AgentSession(agentName: "claude-code", projectId: 12, activityId: 3, description: "Still working", begin: now - 20 * 60, lastSeen: now)
        // Open for a day, its last call 3 h in: booked up to that call, not for 24 h.
        let dayLong = AgentSession(agentName: "claude-code", projectId: 9, activityId: 21, description: "Endless task", begin: now - 25 * 3600, lastSeen: now - 22 * 3600)
        // Stopped by the agent while Kimai was down (process still running): booked at the stop.
        let stopped = AgentSession(agentName: "claude-code", projectId: 12, activityId: 3, description: "Stopped offline",
                                   begin: now - 50 * 60, lastSeen: now - 30 * 60, stoppedAt: now - 30 * 60)
        // A new agent: Kimai drops tags it doesn't know, so Chronato creates ai-codex first.
        let codex = AgentSession(agentName: "codex", projectId: 12, activityId: 5, description: "Codex task", begin: now - 30 * 60, lastSeen: now - 5 * 60, pid: dead)
        // An agent removed in Settings while its process runs: ends at its last call.
        let retired = AgentSession(agentName: "retired-bot", projectId: 12, activityId: 3, description: "Retired bot task", begin: now - 45 * 60, lastSeen: now - 35 * 60)
        // Kimai refuses it (archived project): kept, with Kimai's reason for the app to show.
        let refused = AgentSession(agentName: "claude-code", projectId: 98, activityId: 3, description: "Archived project", begin: now - 15 * 60, lastSeen: now - 14 * 60, pid: dead)
        // Started on another Kimai: never booked into this one.
        let foreign = AgentSession(agentName: "claude-code", projectId: 12, activityId: 3, description: "Other server", begin: now - 12 * 60, lastSeen: now - 11 * 60,
                                   pid: dead, server: URL(string: "https://kimai-old.example.net"))
        for session in [gone, alive, dayLong, stopped, codex, retired, refused, foreign] { try AgentSessions.save(session) }
        defer { for session in [alive, refused, foreign] { AgentSessions.remove(session.id) } }
        // Bookings killed before Kimai answered left their claims; one of them had reached Kimai.
        let landed = AgentSession(agentName: "claude-code", projectId: 12, activityId: 3, description: "Landed before the kill",
                                  begin: now - 70 * 60, lastSeen: now - 60 * 60, pid: dead, stoppedAt: now - 60 * 60)
        let lost = AgentSession(agentName: "claude-code", projectId: 12, activityId: 3, description: "Lost in the kill",
                                begin: now - 65 * 60, lastSeen: now - 55 * 60, pid: dead, stoppedAt: now - 55 * 60)
        _ = try await AgentSessions.create(NewTimesheet(project: 12, activity: 3, begin: landed.begin, end: landed.stoppedAt, description: landed.description),
                                           tag: "ai-claude-code", client: KimaiClient(connection: KimaiConnection(url: base, token: token)), config: config)
        for session in [landed, lost] { try strandedClaim(session, age: 10 * 60) }
        let before = Set(try await entries().map(\.id))

        // The first refresh after connecting reaps (then at most every 5 min).
        let store = try await makeStore()
        let new = try await entries().filter { !before.contains($0.id) }
        func inKimai(_ session: AgentSession) -> MockEntry? { new.first { $0.description == session.description } }
        let booked = inKimai(gone)
        check("l.deadSession.booked", booked?.user == 2 && booked?.tags == ["ai-claude-code"] && booked?.project == 13 && booked?.activity == 18,
              show(booked))
        check("l.deadSession.beginEnd", within(booked?.begin, gone.begin - 60, gone.begin) && within(booked?.end, gone.lastSeen - 1, gone.lastSeen + 61),
              "begin=\(t(booked?.begin)) want \(t(gone.begin)); end=\(t(booked?.end)) want \(t(gone.lastSeen))")
        let capped = inKimai(dayLong)
        check("l.dayLongSession.endsAtLastCall", capped?.user == 2 && within(capped?.end, dayLong.lastSeen - 1, dayLong.lastSeen + 61),
              "\(show(capped)) want end \(t(dayLong.lastSeen)), the agent's last call")
        check("l.stoppedSession.endsAtStop", within(inKimai(stopped)?.end, now - 30 * 60 - 1, now - 30 * 60 + 61), "\(show(inKimai(stopped))) want end \(t(now - 30 * 60))")
        check("l.newAgent.tagCreated", inKimai(codex)?.tags == ["ai-codex"] && inKimai(codex)?.user == 2, show(inKimai(codex)))
        check("l.removedAgent.endsAtLastCall", within(inKimai(retired)?.end, retired.lastSeen - 1, retired.lastSeen + 61), show(inKimai(retired)))
        let kept = Dictionary(uniqueKeysWithValues: store.agentSessions.map { ($0.id, $0) })
        check("l.refused.keptWithReason", inKimai(refused) == nil && kept[refused.id]?.lastError?.contains("not valid") == true,
              "kimai=\(show(inKimai(refused))) lastError=\(kept[refused.id]?.lastError ?? "nil")")
        check("l.otherServer.notBooked", inKimai(foreign) == nil && kept[foreign.id]?.lastError?.contains("another Kimai server") == true,
              "kimai=\(show(inKimai(foreign))) lastError=\(kept[foreign.id]?.lastError ?? "nil")")
        check("l.strandedClaim.notBookedTwice", inKimai(landed) == nil, show(inKimai(landed)))
        check("l.strandedClaim.lostOneBooked", within(inKimai(lost)?.end, now - 55 * 60 - 1, now - 55 * 60 + 61), show(inKimai(lost)))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: Paths.sessionsDir.path))?.filter { !$0.hasSuffix(".json") } ?? []
        check("l.noClaimsLeft", leftovers.isEmpty, "\(leftovers)")
        check("l.aliveSession.kept", Set(AgentSessions.list().map(\.id)) == [alive.id, refused.id, foreign.id] && Set(kept.keys) == [alive.id, refused.id, foreign.id]
              && kept[alive.id]?.lastError == nil,
              "on disk \(AgentSessions.list().map(\.description)), store \(store.agentSessions.map(\.description))")
        check("l.onlyClaudeBooked", new.count == 6 && new.allSatisfy { $0.user == 2 && $0.end != nil }, "new=\(new.map(show))")
        check("l.notInMyHours", store.weekEntries.allSatisfy { $0.aiAgentTag == nil } && store.recent.allSatisfy { $0.aiAgentTag == nil },
              "week=\(store.weekEntries.map(show))")
        let humanEntry = try await entry(human.id)
        check("l.humanTimerUntouched", humanEntry?.end == nil && store.active?.id == human.id, "kimai=\(show(humanEntry)) active=\(show(store.active))")

        // Only an allowed agent's tag marks my own entry as AI: "ai-workshop" is an ordinary tag,
        // "ai-claude-code" (an agent booking as me) is not my work.
        let workshop = try await startExternal(project: 9, activity: 1, description: "AI workshop for a client", tags: ["ai-workshop"])
        let asMe = try await startExternal(project: 12, activity: 5, description: "Agent booked as me", tags: ["ai-claude-code"])
        try await stopExternal(asMe.id)
        await store.refresh()
        check("l.aiPrefixAloneIsMine", store.weekEntries.contains { $0.id == workshop.id } && store.recent.contains { $0.id == workshop.id },
              "week=\(store.weekEntries.map(\.id)) recent=\(store.recent.map(\.id)) workshop=#\(workshop.id)")
        check("l.agentTagAsMeIsAI", !store.weekEntries.contains { $0.id == asMe.id } && !store.recent.contains { $0.id == asMe.id },
              "week=\(store.weekEntries.map(\.id)) recent=\(store.recent.map(\.id)) agent entry=#\(asMe.id)")
    }

    func race() async throws {
        let store = try await freshStore()
        // A refresh whose answer (nothing running) arrives after a start finished must not undo it.
        try await fault("/api/timesheets/active", ["seconds": 1.5])
        let slow = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(300))
        await store.start(projectId: 12, activityId: 3, description: "Race")
        await slow.value
        let run = try await running()
        check("m.staleRefreshAfterStart", store.active != nil && store.active?.id == run.first?.id,
              "active=\(show(store.active)) kimai running=\(run.map(show))")
        // One that still shows the entry running, arriving after a pause, must not resurrect it.
        try await fault("/api/timesheets/active", ["seconds": 1.5])
        let slow2 = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(300))
        await store.pause()
        await slow2.value
        check("m.staleRefreshAfterPause", store.active == nil && store.paused != nil,
              "active=\(show(store.active)) paused=\(String(describing: store.paused))")

        // Connect while an action runs: refused, instead of releasing that action's busy guard.
        try await fault("/api/timesheets", ["method": "POST", "seconds": 1.0])
        let slowStart = Task { await store.start(projectId: 9, activityId: 1, description: "Slow start") }
        try await Task.sleep(for: .milliseconds(300))
        var connectError: Error?
        do { try await store.connect(url: server, token: token) } catch { connectError = error }
        _ = await slowStart.value
        check("m.connectWhileBusy.refused", (connectError as? TrackerStore.ConnectError) == .busy
              && store.active?.description == "Slow start" && !store.isBusy,
              "error=\(connectError?.localizedDescription ?? "nil") active=\(show(store.active))")

        // An answer from the old server that arrives after switching servers is dropped
        // (here its error must not mark the new server offline).
        let other = server.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        try await fault("/api/projects", ["seconds": 1.5, "status": 500, "body": ["code": 500, "message": "Old server is down"]])
        let stale = Task { await store.reloadCatalog() }
        try await Task.sleep(for: .milliseconds(300))
        try await store.connect(url: other, token: token)
        await stale.value
        check("m.staleCatalogAfterServerSwitch", store.connectionState == .online && store.connection?.url.host == "localhost"
              && !store.projects.isEmpty, "state=\(store.connectionState) url=\(store.connection?.url.absoluteString ?? "nil")")
    }

    func countAway() async throws {
        let store = try await freshStore()
        // Away 5 h: "Count it" needs a confirmation.
        _ = try await startExternal(project: 12, activity: 3, description: "Long away", beginAgo: 6 * 3600)
        await store.refresh()
        let now = Date()
        await store.idleTick(now: now, lastInput: now - 5 * 3600)
        await store.idleTick(now: Date(), lastInput: Date())
        let away = store.awayNotice
        check("n.long.needsConfirmation", store.paused?.reason == .idle && away?.countAway == .needsConfirmation && away?.span.isEmpty == false,
              "paused=\(String(describing: store.paused)) away=\(String(describing: away))")
        let before = try await entries().count
        let refusal = await store.resolveAway(.resumeCountingAway)
        let afterRefusal = try await entries().count
        check("n.long.notCountedWithoutConfirmation", refusal != nil && afterRefusal == before && store.paused != nil && store.awayNotice != nil,
              "refusal=\(refusal?.localizedDescription ?? "nil") new entries=\(afterRefusal - before)")
        let pausedAt = store.paused?.pausedAt
        await store.resolveAway(.resumeCountingAway, confirmed: true)
        let run = try await running()
        check("n.long.countedWhenConfirmed", run.count == 1 && within(run.first?.begin, (pausedAt ?? now) - 1, (pausedAt ?? now) + 1) && store.paused == nil,
              "running=\(run.map(show)) pausedAt=\(t(pausedAt))")

        // A "Count it" whose answer got lost (the entry exists in Kimai) and is clicked again books the time once.
        let now2 = Date()
        await store.idleTick(now: now2, lastInput: now2 - 15 * 60)
        await store.idleTick(now: Date(), lastInput: Date())
        check("n.retry.setup", store.awayNotice?.countAway == .allowed, "away=\(String(describing: store.awayNotice))")
        let before2 = try await entries().count
        try await fault("/api/timesheets", ["method": "POST", "drop_response": true, "then_offline": true])
        await store.resolveAway(.resumeCountingAway)
        let firstTry = (error: store.lastError, paused: store.paused != nil)
        try await setOffline(false)
        await store.resolveAway(.resumeCountingAway)
        let created = try await entries().count - before2, run2 = try await running()
        check("n.retry.bookedOnce", firstTry.error != nil && firstTry.paused && created == 1 && run2.count == 1
              && store.active?.id == run2.first?.id && store.paused == nil && store.lastError == nil,
              "first try: \(firstTry.error ?? "no error"); created \(created); running=\(run2.map(show)) lastError=\(store.lastError ?? "nil")")
    }

    func quitAndRelaunch() async throws {
        let store = try await freshStore()
        await store.start(projectId: 12, activityId: 3, description: "Quit test")
        let pauseError = await store.prepareToQuit(.pause)
        let afterPause = try await running()
        check("o.quit.pause", pauseError == nil && afterPause.isEmpty && store.paused?.projectId == 12, "paused=\(String(describing: store.paused))")
        await store.resume()
        let stopError = await store.prepareToQuit(.stop)
        let afterStop = try await running()
        check("o.quit.stop", stopError == nil && afterStop.isEmpty && store.active == nil && store.paused == nil, "running=\(afterStop.map(show))")

        // Quit with the timer kept running, last input an hour ago: the next launch treats the gap like a sleep.
        let kept = try await startExternal(project: 9, activity: 1, description: "Kept running", beginAgo: 2 * 3600)
        await store.refresh()
        let left = Date() - 3600
        store.recordLastAlive(lastInput: left) // what applicationWillTerminate keeps
        let relaunched = try await relaunch()
        let e = try await entry(kept.id)
        check("o.relaunch.endsWhenLeft", within(e?.end, left - 1, left + 61), "end=\(t(e?.end)) left=\(t(left))")
        check("o.relaunch.pausedWithNotice", relaunched.active == nil && relaunched.paused?.reason == .sleep && relaunched.awayNotice != nil,
              "paused=\(String(describing: relaunched.paused)) away=\(String(describing: relaunched.awayNotice))")

        // An auto-pause still waiting for Kimai at quit is applied after the relaunch, with its end.
        let pending = try await decidePendingWhileOffline(relaunched, description: "Pending at quit")
        let third = try await relaunch()
        let e2 = try await entry(pending.entry.id)
        check("o.pendingSurvivesRelaunch", within(e2?.end, pending.left - 1, pending.left + 61) && third.paused?.reason == .idle,
              "end=\(t(e2?.end)) left=\(t(pending.left)) paused=\(String(describing: third.paused))")

        // Launched while Kimai is unreachable, so the Kimai user (time zone) is unknown: an action
        // loads it first, so a back-dated begin is written in Kimai's zone, not the Mac's.
        try await setOffline(true)
        let offlineLaunch = try await relaunch()
        let unknownUser = offlineLaunch.me == nil
        try await setOffline(false)
        let pausedAt = offlineLaunch.paused?.pausedAt
        await offlineLaunch.resolveAway(.resumeCountingAway)
        let run = try await running()
        check("o.offlineLaunch.actionLoadsKimaiUserFirst", unknownUser && pausedAt != nil && run.count == 1
              && within(run.first?.begin, (pausedAt ?? .distantPast) - 1, (pausedAt ?? .distantPast) + 1)
              && offlineLaunch.kimaiTimeZone.identifier == "Europe/Berlin",
              "running=\(run.map(show)) pausedAt=\(t(pausedAt)) zone=\(offlineLaunch.kimaiTimeZone.identifier) lastError=\(offlineLaunch.lastError ?? "nil")")
    }

    /// What the menu and the Reports window decide from the store and Kimai.
    func menuAndReports() async throws {
        let store = try await freshStore()
        // Start form: only customers with something to start; Recent's first (newest first), then by name.
        let customers = store.startableCustomers
        check("p.customers.recentFirst", customers.recent.map(\.id) == [10, 7] && customers.others.map(\.id) == [12],
              "recent=\(customers.recent.map(\.id)) others=\(customers.others.map(\.id))")
        // The start form keeps its note and stays open unless the start returns no error.
        try await setOffline(true)
        let failed = await store.start(projectId: 12, activityId: 3, description: "Typed in the form")
        try await setOffline(false)
        check("p.startForm.failureReturned", failed != nil && store.active == nil, "returned=\(failed?.localizedDescription ?? "nil")")

        // Reports: without view_other_timesheet Kimai ignores `user` (no 403) and answers with own entries.
        guard let client = store.client else { return check("p.setup", false, "no client") }
        let end = Date(), begin = end.addingTimeInterval(-7 * 86400)
        let allowed = try await ReportsView.onlyOwnEntries(client, meId: 1, other: 2, begin: begin, end: end)
        check("p.reports.seesOtherUsers", allowed == false, "onlyOwnEntries=\(String(describing: allowed))")
        try await post("__config", ["view_other": false])
        let all = try await client.timesheets(user: "all", begin: begin, end: end)
        let ownOnly = try await ReportsView.onlyOwnEntries(client, meId: 1, other: 2, begin: begin, end: end)
        let noOther = try await ReportsView.onlyOwnEntries(client, meId: 1, other: nil, begin: begin, end: end)
        try await post("__config", ["view_other": true])
        check("p.reports.onlyOwnDetected", ownOnly == true && all.allSatisfy { $0.userId == 1 },
              "onlyOwnEntries=\(String(describing: ownOnly)) users=\(Set(all.compactMap(\.userId)))")
        check("p.reports.noOtherUserUnknown", noOther == nil, "onlyOwnEntries=\(String(describing: noOther))")

        // Hours: the user's decimal mark and grouping, always two decimals.
        let hours = [DurationText.hours(33300, locale: Locale(identifier: "en_US")), DurationText.hours(33300, locale: Locale(identifier: "de_DE")),
                     DurationText.hours(4_444_200, locale: Locale(identifier: "de_DE")), DurationText.hours(36000, locale: Locale(identifier: "en_US"))]
        check("p.hours.locale", hours == ["9.25 h", "9,25 h", "1.234,50 h", "10.00 h"], "\(hours)")
    }

    func timeZoneChange() async throws {
        let store = try await freshStore() // knows Europe/Berlin from /users/me
        // The user changed the profile's time zone in Kimai since (travelling); Chronato still
        // has Berlin. The entry is stored in New York time, and Kimai reads New York into
        // any date that comes without an offset.
        try await post("__timezone", ["timezone": "America/New_York"])
        let runner = try await startExternal(project: 12, activity: 3, description: "Abroad", beginAgo: 30 * 60)
        await store.refresh()
        check("q.setup", store.active?.id == runner.id && store.kimaiTimeZone.identifier == "Europe/Berlin", "active=\(show(store.active)) zone=\(store.kimaiTimeZone.identifier)")
        let now = Date(), left = now - 15 * 60
        await store.idleTick(now: now, lastInput: left)
        let ended = try await entry(runner.id)
        check("q.idlePause.endsAtLastInput", within(ended?.end, left - 1, left + 61),
              "end=\(t(ended?.end)) lastInput=\(t(left)) lastError=\(store.lastError ?? "nil")")
        await store.idleTick(now: Date(), lastInput: Date())
        guard let pausedAt = store.paused?.pausedAt else { return check("q.paused", false, "paused=nil lastError=\(store.lastError ?? "nil")") }
        await store.resolveAway(.resumeCountingAway)
        let run = try await running()
        check("q.countingAway.beginsWhenLeft", run.count == 1 && within(run.first?.begin, pausedAt - 61, pausedAt + 61),
              "running=\(run.map(show)) pausedAt=\(t(pausedAt))")
        // The poll's reload of the Kimai user picks the new zone up (GET windows, totals' calendar).
        await store.reloadMe()
        check("q.poll.followsProfileTimeZone", store.kimaiTimeZone.identifier == "America/New_York", "zone=\(store.kimaiTimeZone.identifier)")
    }

    /// Kimai in punch mode, token without view_other_timesheet: no times may be written.
    /// An auto-pause then ends the entry now instead of being refused and leaving it running.
    func trackingMode() async throws {
        let store = try await freshStore()
        let runner = try await startExternal(project: 12, activity: 3, description: "Punch mode", beginAgo: 30 * 60)
        await store.refresh()
        try await post("__config", ["tracking_mode": "punch"])
        let now = Date()
        await store.idleTick(now: now, lastInput: now - 15 * 60)
        let ended = try await entry(runner.id)
        try await post("__config")
        check("r.punchMode.idlePauseEndsNow", within(ended?.end, now - 61, Date() + 61) && store.active == nil && store.paused?.reason == .idle,
              "end=\(t(ended?.end)) paused=\(String(describing: store.paused)) lastError=\(store.lastError ?? "nil")")
    }

    // MARK: Store and mock plumbing

    /// A `.booking` claim as a booking killed before Kimai answered leaves it, `age` old.
    func strandedClaim(_ session: AgentSession, age: TimeInterval) throws {
        try AgentSessions.save(session)
        let file = Paths.sessionsDir.appendingPathComponent("\(session.id.uuidString).json")
        let claim = file.appendingPathExtension("booking")
        try FileManager.default.moveItem(at: file, to: claim)
        try FileManager.default.setAttributes([.modificationDate: Date() - age], ofItemAtPath: claim.path)
    }

    func freshStore() async throws -> TrackerStore {
        try await post("__reset")
        return try await makeStore()
    }

    func makeStore() async throws -> TrackerStore {
        let store = TrackerStore(defaults: defaults, keychain: false)
        try await store.connect(url: server, token: token)
        return store
    }

    /// The next launch: a new store on the same defaults (paused session, pending stop, last-alive
    /// record), opened like `bootstrap` opens the saved connection.
    func relaunch() async throws -> TrackerStore {
        guard let url = KimaiConnection.normalizedURL(server) else { throw HarnessError("bad server URL \(server)") }
        let store = TrackerStore(defaults: defaults, keychain: false)
        store.restoreAfterLaunch()
        await store.useSavedConnection(KimaiConnection(url: url, token: token))
        return store
    }

    struct MockEntry: Decodable {
        let id: Int
        let user: Int
        let project: Int
        let activity: Int
        let description: String?
        let tags: [String]
        let beginTs: Double
        let endTs: Double?
        let duration: Int
        var begin: Date { Date(timeIntervalSince1970: beginTs) }
        var end: Date? { endTs.map(Date.init(timeIntervalSince1970:)) }
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any] = [:]) async throws -> Data {
        try await send("POST", path, body)
    }

    func send(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HarnessError("\(method) /\(path) → \((response as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    func entries() async throws -> [MockEntry] {
        struct State: Decodable { let timesheets: [MockEntry] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(State.self, from: try await send("GET", "__state")).timesheets
    }

    func entry(_ id: Int) async throws -> MockEntry? { try await entries().first { $0.id == id } }
    func running(user: Int = 1) async throws -> [MockEntry] { try await entries().filter { $0.user == user && $0.end == nil } }

    func startExternal(project: Int, activity: Int, description: String? = nil, tags: [String] = [], beginAgo: TimeInterval = 0) async throws -> MockEntry {
        var body: [String: Any] = ["project": project, "activity": activity, "tags": tags, "begin_ago": Int(beginAgo)]
        if let description { body["description"] = description }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MockEntry.self, from: try await post("__start_external", body))
    }

    func stopExternal(_ id: Int) async throws { try await post("__stop_external", ["id": id]) }
    func setOffline(_ on: Bool, mode: String = "drop") async throws { try await post("__offline", ["on": on, "mode": mode]) }
    /// The next request to `path` misbehaves (see scripts/mock-kimai.py `__fault`).
    func fault(_ path: String, _ rule: [String: Any]) async throws { try await post("__fault", rule.merging(["path": path]) { $1 }) }

    /// Mine today/this week per Kimai (Europe/Berlin, Monday) vs. the store's totals.
    func checkTotals(_ prefix: String, _ store: TrackerStore) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = store.now
        let today = calendar.startOfDay(for: now)
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: now) + 5) % 7), to: today)!
        let mine = try await entries().filter { $0.user == 1 && $0.begin <= now }
        func total(since start: Date) -> Int {
            mine.filter { $0.begin >= start }.reduce(0) { $0 + ($1.end == nil ? max(0, Int(now.timeIntervalSince($1.begin))) : $1.duration) }
        }
        check("\(prefix).todaySeconds", abs(store.todaySeconds - total(since: today)) <= 2, "store \(store.todaySeconds) s, Kimai \(total(since: today)) s")
        check("\(prefix).weekSeconds", abs(store.weekSeconds - total(since: monday)) <= 2, "store \(store.weekSeconds) s, Kimai \(total(since: monday)) s")
    }

    /// A pid no process has (kill → ESRCH), counting down from the top of the pid range.
    func deadPid() throws -> Int32 {
        for pid in stride(from: Int32(99_998), to: 1000, by: -1) where kill(pid, 0) == -1 && errno == ESRCH { return pid }
        throw HarnessError("no free pid")
    }

    struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Reporting

    func scenario(_ name: String, _ body: () async throws -> Void) async {
        print("\n== \(name)")
        do { try await body() } catch { check("\(name.prefix(1)).harness", false, "\(error)") }
    }

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if ok {
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name) — \(detail())")
        }
    }

    func isOffline(_ store: TrackerStore) -> Bool {
        if case .offline = store.connectionState { return true }
        return false
    }

    func within(_ date: Date?, _ low: Date, _ high: Date) -> Bool {
        guard let date else { return false }
        return date >= low && date <= high
    }

    /// "now-903s"
    func t(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return String(format: "now%+.0fs", date.timeIntervalSinceNow)
    }

    func show(_ e: MockEntry?) -> String {
        guard let e else { return "nil" }
        return "#\(e.id) user \(e.user) \(e.project)/\(e.activity) \"\(e.description ?? "")\" \(e.tags) begin \(t(e.begin)) end \(t(e.end))"
    }

    func show(_ e: KimaiTimesheet?) -> String {
        guard let e else { return "nil" }
        return "#\(e.id) \(e.projectId)/\(e.activityId) \"\(e.description ?? "")\" begin \(t(e.begin)) end \(t(e.end))"
    }
}
