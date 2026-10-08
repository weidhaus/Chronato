import Foundation
import Testing
@testable import ChronatoCore

/// Whole seconds, because session files store ISO 8601 dates.
private let aiT0 = Date(timeIntervalSince1970: 1_791_450_000)

private func aiSession(agent: String = "claude-code", begin: Date = aiT0, lastSeen: Date? = nil, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                       server: URL? = nil, stoppedAt: Date? = nil, description: String = "Refactor billing export") -> AgentSession {
    AgentSession(agentName: agent, projectId: 12, activityId: 3, customerName: "Northwind Traders", projectName: "Ops Dashboard",
                 activityName: "Automation", description: description, begin: begin, lastSeen: lastSeen ?? begin, pid: pid,
                 server: server, stoppedAt: stoppedAt)
}

/// claude-code allowed, AI time to Kimai user 2.
private func aiConfig() -> AIConfig {
    var config = AIConfig(bookingUserId: 2)
    _ = try! config.addAgent(named: "Claude Code")
    return config
}

/// The pid of a process that has exited (and been reaped).
private func aiDeadPid() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
}

private func files(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

@Test func sessionFilesRoundTripAndSkipCorruptOnes() throws {
    let dir = AIFakeKimai.tempDir()
    let a = aiSession(), b = aiSession(begin: aiT0 - 600)
    try AgentSessions.save(a, in: dir)
    try AgentSessions.save(b, in: dir)
    try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
    #expect(AgentSessions.list(in: dir) == [b, a])
    let attributes = try FileManager.default.attributesOfItem(atPath: AgentSessions.file(a.id, in: dir).path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    AgentSessions.remove(b.id, in: dir)
    #expect(AgentSessions.list(in: dir) == [a])
}

@Test func updateNeverBringsABookedSessionBack() throws {
    let dir = AIFakeKimai.tempDir()
    var s = aiSession()
    try AgentSessions.save(s, in: dir)
    s.lastSeen = aiT0 + 300
    #expect(try AgentSessions.update(s, in: dir))
    #expect(AgentSessions.list(in: dir) == [s] && files(dir) == ["\(s.id.uuidString).json"])
    // The app's reaper claimed it in the meantime.
    try FileManager.default.moveItem(at: AgentSessions.file(s.id, in: dir), to: AgentSessions.file(s.id, in: dir).appendingPathExtension("booking"))
    #expect(try !AgentSessions.update(s, in: dir))
    #expect(files(dir) == ["\(s.id.uuidString).json.booking"])
}

@Test func bookingClampsAndDeletesOnlyAfterKimaiAccepted() async throws {
    let kimai = AIFakeKimai(), dir = AIFakeKimai.tempDir()
    let config = AIConfig(bookingUserId: 2)
    let s = aiSession()
    try AgentSessions.save(s, in: dir)

    kimai.setPostStatus(400)
    await #expect(throws: KimaiError.self) { try await AgentSessions.book(s, end: aiT0 + 5, client: kimai.client, config: config, in: dir) }
    // Kept, with Kimai's reason.
    #expect(AgentSessions.list(in: dir).map(\.id) == [s.id])
    #expect(AgentSessions.list(in: dir).first?.lastError?.contains("Invalid project") == true)

    kimai.setPostStatus(503)
    await #expect(throws: KimaiError.self) { try await AgentSessions.book(s, end: aiT0 + 5, client: kimai.client, config: config, in: dir) }
    #expect(AgentSessions.list(in: dir).map(\.id) == [s.id])

    kimai.setPostStatus(200)
    let entry = try await AgentSessions.book(s, end: aiT0 + 5, client: kimai.client, config: config, in: dir)
    #expect(entry.seconds() == 60 && entry.tags == ["ai-claude-code"])
    #expect(AgentSessions.list(in: dir).isEmpty)
    #expect(files(dir).isEmpty)
    let body = try #require(kimai.posts.last)
    // Bodies carry the offset, so Kimai can't read them in another zone.
    #expect(body["begin"] as? String == KimaiDate.formatWithOffset(aiT0, in: AIFakeKimai.timeZone))
    #expect(body["end"] as? String == KimaiDate.formatWithOffset(aiT0 + 60, in: AIFakeKimai.timeZone))
    #expect((body["end"] as? String)?.hasSuffix("+14:00") == true)
    #expect(body["tags"] as? String == "ai-claude-code" && body["user"] as? Int == 2)
    #expect(body["project"] as? Int == 12 && body["activity"] as? Int == 3 && body["description"] as? String == "Refactor billing export")

    // Already booked (file gone): refuses instead of booking twice.
    await #expect(throws: AgentSessions.AlreadyBooked.self) { try await AgentSessions.book(s, end: aiT0 + 600, client: kimai.client, config: config, in: dir) }
    #expect(kimai.posts.count == 3)

    let long = aiSession()
    try AgentSessions.save(long, in: dir)
    _ = try await AgentSessions.book(long, end: aiT0 + 3 * 86400, client: kimai.client, config: config, in: dir)
    #expect(kimai.posts.last?["end"] as? String == KimaiDate.formatWithOffset(aiT0 + AgentSessions.maxDuration, in: AIFakeKimai.timeZone))
}

@Test func bookingCreatesAMissingTagAndChecksKimaiKeptIt() async throws {
    let kimai = AIFakeKimai(), dir = AIFakeKimai.tempDir()
    kimai.setTags([])
    let s = aiSession(agent: "codex")
    try AgentSessions.save(s, in: dir)
    let entry = try await AgentSessions.book(s, end: aiT0 + 600, client: kimai.client, config: AIConfig(), in: dir)
    #expect(entry.tags == ["ai-codex"] && kimai.tags == ["ai-codex"])
    #expect(kimai.requests.filter { $0.method == "POST" && $0.path == "/api/tags" }.map { $0.json["name"] as? String } == ["ai-codex"])

    // Kimai may not create it: say so, keep the session.
    let other = AIFakeKimai()
    other.setTags([])
    other.setTagStatus(403)
    try AgentSessions.save(s, in: dir)
    let refused = await #expect(throws: KimaiError.self) {
        try await AgentSessions.book(s, end: aiT0 + 600, client: other.client, config: AIConfig(), in: dir)
    }
    #expect(refused?.localizedDescription.contains("create_tag") == true)
    #expect(other.posts.isEmpty && AgentSessions.list(in: dir).first?.lastError?.contains("create_tag") == true)

    // Kimai dropped it anyway (the tag was removed after it was looked up): the entry exists,
    // so it is reported and never booked a second time.
    let dropping = AIFakeKimai()
    try await dropping.client.ensureTag("ai-claude-code")
    dropping.setTags([])
    let t = aiSession()
    try AgentSessions.save(t, in: dir)
    let dropped = await #expect(throws: AIAgentError.self) {
        try await AgentSessions.book(t, end: aiT0 + 600, client: dropping.client, config: AIConfig(), in: dir)
    }
    #expect(dropped?.localizedDescription.contains("dropped its tag ai-claude-code") == true)
    #expect(!AgentSessions.list(in: dir).contains { $0.id == t.id } && dropping.posts.count == 1)
}

@Test func bookingRefusesAnotherServersSessionOrSettings() async throws {
    let kimai = AIFakeKimai(), dir = AIFakeKimai.tempDir()
    let s = aiSession(server: URL(string: "https://kimai-old.example.net")!)
    try AgentSessions.save(s, in: dir)
    await #expect(throws: AIAgentError.startedOnOtherServer("kimai-old.example.net")) {
        try await AgentSessions.book(s, end: aiT0 + 600, client: kimai.client, config: AIConfig(), in: dir)
    }
    let mine = aiSession(server: kimai.connection.url)
    try AgentSessions.save(mine, in: dir)
    await #expect(throws: AIAgentError.settingsForOtherServer("kimai-old.example.net")) {
        try await AgentSessions.book(mine, end: aiT0 + 600, client: kimai.client, config: AIConfig(bookingUserId: 2, server: URL(string: "https://kimai-old.example.net")!), in: dir)
    }
    #expect(kimai.posts.isEmpty && AgentSessions.list(in: dir).count == 2)
    _ = try await AgentSessions.book(mine, end: aiT0 + 600, client: kimai.client, config: AIConfig(bookingUserId: 2, server: kimai.connection.url), in: dir)
    #expect(kimai.posts.count == 1)
}

@Test func reapsUpToTheLastCallOrTheStop() async throws {
    let kimai = AIFakeKimai(), dir = AIFakeKimai.tempDir()
    let now = aiT0 + 3600
    let dead = aiSession(begin: aiT0, lastSeen: aiT0 + 72 * 60, pid: try aiDeadPid(), description: "dead")
    let left = aiSession(begin: aiT0 + 60, lastSeen: aiT0 + 20 * 60, pid: 0, description: "left to the app")
    let live = aiSession(begin: aiT0 + 600, description: "live")
    let stopped = aiSession(begin: aiT0 + 120, lastSeen: aiT0 + 120, stoppedAt: aiT0 + 30 * 60, description: "stopped")
    let disabled = aiSession(agent: "old-bot", begin: aiT0 + 180, lastSeen: aiT0 + 15 * 60, description: "disabled")
    let overlong = aiSession(begin: now - AgentSessions.maxDuration - 60, lastSeen: now - AgentSessions.maxDuration + 40 * 60 - 60, description: "overlong")
    for s in [dead, left, live, stopped, disabled, overlong] { try AgentSessions.save(s, in: dir) }

    let reaped = await AgentSessions.reapStale(client: kimai.client, config: aiConfig(), now: now, in: dir)
    #expect(reaped.booked == [
        "Booked 0:40 h for claude-code (still open after 24 h)",
        "Booked 1:12 h for claude-code (process ended)",
        "Booked 0:19 h for claude-code (process ended)",
        "Booked 0:28 h for claude-code (stopped earlier)",
        "Booked 0:12 h for old-bot (agent disabled)",
    ])
    #expect(reaped.failed.isEmpty)
    #expect(AgentSessions.list(in: dir) == [live])
    #expect(kimai.posts.map { $0["end"] as? String } == [overlong.lastSeen, dead.lastSeen, left.lastSeen, aiT0 + 30 * 60, disabled.lastSeen].map {
        KimaiDate.formatWithOffset($0, in: AIFakeKimai.timeZone)
    })
}

@Test func reaperReportsARefusalOnceAndKeepsRetrying() async throws {
    let kimai = AIFakeKimai(), dir = AIFakeKimai.tempDir()
    let s = aiSession(lastSeen: aiT0 + 600, pid: 0)
    try AgentSessions.save(s, in: dir)

    kimai.setPostStatus(503) // unreachable: quiet
    var reaped = await AgentSessions.reapStale(client: kimai.client, config: aiConfig(), now: aiT0 + 3600, in: dir)
    #expect(reaped.booked.isEmpty && reaped.failed.isEmpty && AgentSessions.list(in: dir).first?.lastError == nil)

    kimai.setPostStatus(400)
    reaped = await AgentSessions.reapStale(client: kimai.client, config: aiConfig(), now: aiT0 + 3600, in: dir)
    #expect(reaped.failed == ["claude-code, \"Refactor billing export\": Kimai 400: Validation Failed — project: Invalid project."])
    #expect(AgentSessions.list(in: dir).first?.lastError == "Kimai 400: Validation Failed — project: Invalid project.")
    reaped = await AgentSessions.reapStale(client: kimai.client, config: aiConfig(), now: aiT0 + 3600, in: dir)
    #expect(reaped.failed.isEmpty && kimai.posts.count == 3) // retried, not reported again

    kimai.setPostStatus(200)
    reaped = await AgentSessions.reapStale(client: kimai.client, config: aiConfig(), now: aiT0 + 3600, in: dir)
    #expect(reaped.booked == ["Booked 0:10 h for claude-code (process ended)"] && AgentSessions.list(in: dir).isEmpty)
}

@Test func reaperRecoversClaimsLeftByAKilledBooking() async throws {
    let kimai = AIFakeKimai(), dir = AIFakeKimai.tempDir()
    let now = Date.now
    func claim(_ s: AgentSession, age: TimeInterval) throws {
        let url = AgentSessions.file(s.id, in: dir).appendingPathExtension("booking")
        try AgentSessions.write(s, to: url)
        try FileManager.default.setAttributes([.modificationDate: now - age], ofItemAtPath: url.path)
    }
    // Kimai got this one before the process died.
    let landed = aiSession(begin: now - 3600, stoppedAt: now - 1800, description: "landed")
    _ = try await AgentSessions.create(NewTimesheet(project: 12, activity: 3, begin: landed.begin, end: now - 1800, description: "landed"),
                                       tag: "ai-claude-code", client: kimai.client, config: aiConfig())
    try claim(landed, age: 600)
    // This one never reached Kimai.
    let lost = aiSession(begin: now - 3000, stoppedAt: now - 1200, description: "lost")
    try claim(lost, age: 600)
    // A booking still in progress.
    let busy = aiSession(begin: now - 2400, stoppedAt: now - 600, description: "busy")
    try claim(busy, age: 5)

    let reaped = await AgentSessions.reapStale(client: kimai.client, config: aiConfig(), now: now, in: dir)
    #expect(reaped.booked == ["Booked 0:30 h for claude-code (stopped earlier)"])
    #expect(kimai.posts.map { $0["description"] as? String } == ["landed", "lost"])
    #expect(files(dir) == ["\(busy.id.uuidString).json.booking"])
}

@Test func setupCommandQuotesForTheShellAndReplacesAnOlderRegistration() {
    let command = AgentSessions.setupCommand(agentName: "claude-code", token: "tok_123", executable: "/Users/x/My Apps/Chronato's.app/Contents/MacOS/Chronato")
    #expect(command == #"claude mcp remove chronato --scope user 2>/dev/null; claude mcp add chronato --scope user -e CHRONATO_AGENT='claude-code' -e CHRONATO_TOKEN='tok_123' -- '/Users/x/My Apps/Chronato'\''s.app/Contents/MacOS/Chronato' mcp"#)

    // What a POSIX shell makes of it, with `claude` stubbed: remove (failing when nothing is
    // registered) does not stop the add, which gets exactly the original arguments.
    let echo = Process()
    echo.executableURL = URL(fileURLWithPath: "/bin/sh")
    echo.arguments = ["-c", "claude() { if [ \"$1\" = mcp ] && [ \"$2\" = remove ]; then echo 'not found' >&2; return 1; fi; shift 2; printf '%s\\n' \"$@\"; }; " + command]
    let pipe = Pipe()
    echo.standardOutput = pipe
    try? echo.run()
    echo.waitUntilExit()
    let args = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(args == ["chronato", "--scope", "user", "-e", "CHRONATO_AGENT=claude-code", "-e", "CHRONATO_TOKEN=tok_123", "--",
                     "/Users/x/My Apps/Chronato's.app/Contents/MacOS/Chronato", "mcp"])
}

@Test func setupJSONIsAStandardMCPServersBlock() throws {
    let text = AgentSessions.setupJSON(agentName: "codex", token: "tok\"123", executable: "/Applications/Chronato.app/Contents/MacOS/Chronato")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let server = try #require((json["mcpServers"] as? [String: Any])?["chronato"] as? [String: Any])
    #expect(server["command"] as? String == "/Applications/Chronato.app/Contents/MacOS/Chronato")
    #expect(server["args"] as? [String] == ["mcp"])
    #expect(server["env"] as? [String: String] == ["CHRONATO_AGENT": "codex", "CHRONATO_TOKEN": "tok\"123"])
}

@Test func setupTOMLIsACodexServerTable() {
    #expect(AgentSessions.setupTOML(agentName: "codex", token: "tok_123", executable: #"/Users/x/A "B"\C/Chronato"#) == """
        [mcp_servers.chronato]
        command = "/Users/x/A \\"B\\"\\\\C/Chronato"
        args = ["mcp"]
        env = { CHRONATO_AGENT = "codex", CHRONATO_TOKEN = "tok_123" }
        """)
}

@Test func setupPointsAtAPathThatLasts() {
    let installed = AgentSessions.stableExecutable(bundlePath: "/Applications/Chronato.app", executablePath: "/Applications/Chronato.app/Contents/MacOS/Chronato", home: "/Users/x")
    #expect(installed.path == "/Applications/Chronato.app/Contents/MacOS/Chronato" && installed.warning == nil)
    let mine = AgentSessions.stableExecutable(bundlePath: "/Users/x/Applications/Chronato.app", executablePath: "/Users/x/Applications/Chronato.app/Contents/MacOS/Chronato", home: "/Users/x")
    #expect(mine.path == "/Users/x/Applications/Chronato.app/Contents/MacOS/Chronato" && mine.warning == nil)
    for ephemeral in ["/Volumes/Chronato/Chronato.app", "/private/var/folders/ab/T/AppTranslocation/1234-5678/d/Chronato.app"] {
        let result = AgentSessions.stableExecutable(bundlePath: ephemeral, executablePath: ephemeral + "/Contents/MacOS/Chronato", home: "/Users/x")
        #expect(result.path == AgentSessions.installedExecutable && result.warning?.contains("Move it to Applications") == true)
    }
    let dist = AgentSessions.stableExecutable(bundlePath: "/Users/x/DEV/chronato/dist/Chronato.app", executablePath: "/Users/x/DEV/chronato/dist/Chronato.app/Contents/MacOS/Chronato", home: "/Users/x")
    #expect(dist.path == "/Users/x/DEV/chronato/dist/Chronato.app/Contents/MacOS/Chronato" && dist.warning?.contains("isn't in Applications") == true)
}
