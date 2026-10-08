import Foundation
import Synchronization
import Testing
@testable import ChronatoCore

/// What the app changes under a running `Chronato mcp`: agents.json and the Keychain item.
private final class Shared: Sendable {
    let config: Mutex<AIConfig>
    let connection: Mutex<Result<KimaiConnection?, Credentials.KeychainError>>
    init(_ config: AIConfig, _ connection: KimaiConnection?) {
        self.config = Mutex(config)
        self.connection = Mutex(.success(connection))
    }
}

/// An MCP server wired to a fake Kimai and a temp sessions dir; never the Keychain.
private struct MCPHarness {
    let kimai = AIFakeKimai()
    let dir = AIFakeKimai.tempDir()
    let server: MCPServer
    let token: String
    let shared: Shared

    /// One agent "claude-code"; AI time goes to Kimai user 2.
    init(enabled: Bool = true, connected: Bool = true, agentDefaults: (Int, Int)? = nil, configDefaults: (Int, Int)? = nil, presentedToken: String? = nil) {
        var config = AIConfig(bookingUserId: 2, defaultProjectId: configDefaults?.0, defaultActivityId: configDefaults?.1)
        let (_, token) = try! config.addAgent(named: "Claude Code")
        config.agents[0].enabled = enabled
        config.agents[0].defaultProjectId = agentDefaults?.0
        config.agents[0].defaultActivityId = agentDefaults?.1
        self.token = token
        let shared = Shared(config, connected ? kimai.connection : nil)
        self.shared = shared
        server = MCPServer(environment: ["CHRONATO_AGENT": "claude-code", "CHRONATO_TOKEN": presentedToken ?? token],
                           connection: { try shared.connection.withLock { try $0.get() } }, loadConfig: { shared.config.withLock { $0 } },
                           urlSession: kimai.session, sessionsDir: dir)
    }

    func changeConfig(_ change: (inout AIConfig) -> Void) { shared.config.withLock { change(&$0) } }

    /// The session file as it is on disk now.
    var session: AgentSession? { sessions.first }

    func send(_ method: String, _ params: [String: Any] = [:], id: Any = 1) async -> [String: Any] {
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]), as: UTF8.self)
        let reply = await server.handle(line)
        return try! JSONSerialization.jsonObject(with: Data((reply ?? "{}").utf8)) as! [String: Any]
    }

    func call(_ tool: String, _ arguments: [String: Any] = [:]) async -> (text: String, isError: Bool) {
        let result = await send("tools/call", ["name": tool, "arguments": arguments])["result"] as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    var sessions: [AgentSession] { AgentSessions.list(in: dir) }
}

@Test func mcpInitializeNegotiatesVersion() async throws {
    let h = MCPHarness()
    let known = try #require(await h.send("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:]], id: "a")["result"] as? [String: Any])
    #expect(known["protocolVersion"] as? String == "2025-03-26")
    #expect(known["capabilities"] as? [String: [String: String]] == ["tools": [:]])
    #expect((known["serverInfo"] as? [String: Any])?["name"] as? String == "chronato")
    #expect((known["instructions"] as? String)?.contains("start_tracking") == true)
    let unknown = await h.send("initialize", ["protocolVersion": "1999-01-01"])
    #expect((unknown["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    #expect(unknown["id"] as? Int == 1 && unknown["jsonrpc"] as? String == "2.0")
}

@Test func mcpProtocolPlumbing() async throws {
    let h = MCPHarness()
    #expect(await h.send("ping")["result"] as? [String: String] == [:])
    #expect((await h.send("resources/list")["error"] as? [String: Any])?["code"] as? Int == -32601)
    #expect((await h.send("tools/call", ["name": "rm_rf"])["error"] as? [String: Any])?["code"] as? Int == -32602)
    #expect(await h.server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    #expect(await h.server.handle("") == nil)
    let malformed = try #require(await h.server.handle("{nope"))
    let error = try #require(try JSONSerialization.jsonObject(with: Data(malformed.utf8)) as? [String: Any])
    #expect(error["id"] is NSNull && (error["error"] as? [String: Any])?["code"] as? Int == -32700)
    #expect(!malformed.contains("\n"))
}

@Test func mcpListsToolsWithSchemas() async throws {
    let h = MCPHarness()
    let tools = try #require((await h.send("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String } == ["list_projects", "start_tracking", "stop_tracking", "tracking_status", "log_time"])
    for tool in tools {
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object" && schema["properties"] is [String: Any])
        #expect((tool["description"] as? String)?.isEmpty == false)
    }
    let start = try #require(tools[1]["inputSchema"] as? [String: Any])
    #expect(start["required"] as? [String] == ["description"])
    #expect((start["properties"] as? [String: Any])?.keys.sorted() == ["activity_id", "description", "project_id"])
}

@Test func mcpRejectsUnknownWrongTokenAndDisabledAgents() async {
    for h in [MCPHarness(presentedToken: "guess"), MCPHarness(enabled: false)] {
        let reply = await h.call("start_tracking", ["description": "x", "project_id": 12, "activity_id": 3])
        #expect(reply.isError && reply.text == AIAgentError.notAllowed.localizedDescription)
        #expect(h.kimai.requests.isEmpty && h.sessions.isEmpty)
    }
}

@Test func mcpReportsMissingConnection() async {
    let h = MCPHarness(connected: false)
    let reply = await h.call("list_projects")
    #expect(reply.isError && reply.text == AIAgentError.notConfigured.localizedDescription)
}

@Test func mcpTellsAKeychainRefusalFromNoConnection() async {
    let h = MCPHarness()
    h.shared.connection.withLock { $0 = .failure(Credentials.KeychainError(status: errSecInteractionNotAllowed, reading: true)) }
    let reply = await h.call("list_projects")
    #expect(reply.isError && reply.text.contains("could not read its Kimai connection from the Keychain") && reply.text.contains("-25308"))
}

@Test func mcpFollowsTheAppsConnection() async {
    let h = MCPHarness()
    #expect(await !h.call("list_projects").isError)
    #expect(await !h.call("list_projects").isError)
    #expect(h.kimai.requests.filter { $0.path == "/api/users/me" }.count == 1) // client kept while the connection stays
    // Disconnected in the app: this long-running process stops using the old token at once.
    h.shared.connection.withLock { $0 = .success(nil) }
    let reply = await h.call("list_projects")
    #expect(reply.isError && reply.text == AIAgentError.notConfigured.localizedDescription)
    // Connected to another server: settings made for the old one are refused there.
    let other = AIFakeKimai()
    h.shared.connection.withLock { $0 = .success(other.connection) }
    h.changeConfig { $0.server = h.kimai.connection.url }
    let start = await h.call("start_tracking", ["description": "x", "project_id": 12, "activity_id": 3])
    #expect(start.isError && start.text == AIAgentError.settingsForOtherServer(h.kimai.host).localizedDescription)
    #expect(h.sessions.isEmpty)
}

@Test func mcpStartStopBooksOneFinishedEntry() async throws {
    let h = MCPHarness()
    #expect(await h.call("tracking_status").text == "Not tracking.")
    let started = await h.call("start_tracking", ["description": "Refactor billing export", "project_id": 12, "activity_id": "3"])
    #expect(!started.isError && started.text.contains("Northwind Traders › Ops Dashboard › Automation"))
    let session = try #require(h.sessions.first)
    #expect(h.sessions.count == 1 && session.agentName == "claude-code" && session.pid == ProcessInfo.processInfo.processIdentifier)
    #expect(session.server == h.kimai.connection.url && session.stoppedAt == nil)
    #expect(h.kimai.posts.isEmpty) // no running timer in Kimai
    #expect(await h.call("tracking_status").text.hasPrefix("Tracking \"Refactor billing export\""))

    let stopped = await h.call("stop_tracking", ["description": "Refactor billing export (done)"])
    #expect(!stopped.isError && stopped.text.contains("Kimai entry #"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).isEmpty)
    let posts = h.kimai.posts
    #expect(posts.count == 1)
    let body = try #require(posts.first)
    #expect(body["tags"] as? String == "ai-claude-code" && body["user"] as? Int == 2)
    #expect(body["project"] as? Int == 12 && body["activity"] as? Int == 3 && body["description"] as? String == "Refactor billing export (done)")
    // Begin/end with the Kimai user's offset; a short task is booked as one minute.
    #expect(body["begin"] as? String == KimaiDate.formatWithOffset(session.begin, in: AIFakeKimai.timeZone))
    #expect(body["end"] as? String == KimaiDate.formatWithOffset(session.begin + 60, in: AIFakeKimai.timeZone))
    #expect(h.kimai.requests.filter { $0.path == "/api/users/me" }.count == 1)
    #expect(await h.call("stop_tracking").text.hasPrefix("Not tracking"))
}

@Test func mcpStartingAgainBooksThePreviousTask() async {
    let h = MCPHarness(agentDefaults: (13, 18))
    _ = await h.call("start_tracking", ["description": "First"])
    let second = await h.call("start_tracking", ["description": "Second", "project_id": 12, "activity_id": 21])
    #expect(!second.isError && second.text.hasPrefix("Booked 0:01 h for \"First\""))
    #expect(h.kimai.posts.map { $0["description"] as? String } == ["First"])
    #expect(h.kimai.posts.first?["project"] as? Int == 13)
    #expect(h.sessions.map(\.description) == ["Second"])
}

@Test func mcpShutdownLeavesTheSessionToTheAppWithoutNetwork() async throws {
    let h = MCPHarness(configDefaults: (12, 3))
    _ = await h.call("start_tracking", ["description": "Forgotten"])
    let lastCall = try #require(h.session).lastSeen
    // stdin closed or a signal: the client kills its server a moment later. No booking now…
    await h.server.shutdown()
    #expect(h.kimai.posts.isEmpty)
    let left = try #require(h.session)
    #expect(left.pid == 0 && left.lastSeen == lastCall && left.stoppedAt == nil)
    // …the app books it, up to the agent's last call, not the client's exit.
    let reaped = await AgentSessions.reapStale(client: h.kimai.client, config: h.shared.config.withLock { $0 }, now: .now + 8 * 3600, in: h.dir)
    #expect(reaped.booked == ["Booked 0:01 h for claude-code (process ended)"] && h.sessions.isEmpty)
}

@Test func mcpStopWhileKimaiIsDownKeepsTheStopTime() async throws {
    let h = MCPHarness(configDefaults: (12, 3))
    _ = await h.call("start_tracking", ["description": "On a train"])
    h.kimai.setPostStatus(503)
    let before = Date.now
    let stop = await h.call("stop_tracking")
    #expect(!stop.isError && stop.text.contains("books it once Kimai is back"))
    let stopped = try #require(h.session)
    #expect(stopped.stoppedAt.map { abs($0.timeIntervalSince(before)) < 2 } == true && stopped.lastError == nil)
    #expect(await h.call("tracking_status").text == "Not tracking.") // done with it; nothing booked later by this process
    await h.server.shutdown()
    #expect(h.kimai.posts.count == 1)

    // Back online, hours later: booked at the stop, not at the retry.
    h.kimai.setPostStatus(200)
    let reaped = await AgentSessions.reapStale(client: h.kimai.client, config: h.shared.config.withLock { $0 }, now: .now + 2 * 3600, in: h.dir)
    #expect(reaped.booked == ["Booked 0:01 h for claude-code (stopped earlier)"])
    #expect(h.kimai.posts.last?["end"] as? String == KimaiDate.formatWithOffset(max(stopped.stoppedAt!, stopped.begin + 60), in: AIFakeKimai.timeZone))
}

@Test func mcpStopRefusedByKimaiSaysSoAndKeepsTheSession() async throws {
    let h = MCPHarness(configDefaults: (12, 3))
    _ = await h.call("start_tracking", ["description": "Refused"])
    h.kimai.setPostStatus(400)
    let stop = await h.call("stop_tracking")
    #expect(stop.isError && stop.text.contains("could not be booked: Kimai 400: Validation Failed"))
    let kept = try #require(h.session)
    #expect(kept.stoppedAt != nil && kept.lastError?.contains("Invalid project") == true)
}

@Test func mcpDisabledAgentsSessionEndsAtItsLastAllowedCall() async throws {
    let h = MCPHarness(configDefaults: (12, 3))
    _ = await h.call("start_tracking", ["description": "Then disabled"])
    let lastCall = try #require(h.session).lastSeen
    try await Task.sleep(for: .milliseconds(1100)) // session files keep whole seconds
    h.changeConfig { $0.agents[0].enabled = false }
    #expect(await h.call("tracking_status").text == AIAgentError.notAllowed.localizedDescription)
    let left = try #require(h.session)
    #expect(left.pid == 0 && left.lastSeen == lastCall) // a refused call is not "the agent was here"
    h.changeConfig { $0.agents[0].enabled = true }
    #expect(await h.call("stop_tracking").text.hasPrefix("Not tracking")) // released: the app books it
}

@Test func mcpNeverRecreatesASessionTheAppIsBooking() async throws {
    let h = MCPHarness(configDefaults: (12, 3))
    _ = await h.call("start_tracking", ["description": "Day-long"])
    let session = try #require(h.session)
    let file = AgentSessions.file(session.id, in: h.dir)
    // The reaper's claim (24 h limit) lands between two calls.
    try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("booking"))
    #expect(await h.call("tracking_status").text == "Not tracking.")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(await h.call("stop_tracking").text.hasPrefix("Not tracking") && h.kimai.posts.isEmpty)
}

@Test func mcpShutdownWaitsForTheBookingInFlight() async throws {
    let h = MCPHarness(configDefaults: (12, 3))
    _ = await h.call("start_tracking", ["description": "Long task"])
    h.kimai.setPostDelay(0.3)
    let stop = Task { await h.call("stop_tracking") }
    try await Task.sleep(for: .milliseconds(100)) // stop_tracking is now waiting for Kimai
    // stdin EOF and SIGTERM arrive together; neither may return (the process exits) mid-booking.
    async let eof: Void = h.server.shutdown()
    async let term: Void = h.server.shutdown()
    _ = await (eof, term)
    #expect(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).isEmpty)
    #expect(h.kimai.posts.count == 1)
    #expect(await !stop.value.isError)
}

@Test func mcpValidatesProjectAndActivity() async {
    let h = MCPHarness()
    let noDefault = await h.call("start_tracking", ["description": "x"])
    #expect(noDefault.isError && noDefault.text.contains(AIAgentError.noProject.localizedDescription))
    // Activity of another project.
    #expect(await h.call("start_tracking", ["description": "x", "project_id": 12, "activity_id": 18]).isError)
    // Global activity in a project that does not allow global activities.
    #expect(await h.call("start_tracking", ["description": "x", "project_id": 13, "activity_id": 21]).isError)
    #expect(await h.call("start_tracking", ["description": "x", "project_id": 99, "activity_id": 3]).isError)
    #expect(await h.call("start_tracking", ["description": " ", "project_id": 12, "activity_id": 3]).isError)
    #expect(h.sessions.isEmpty)
    // Global activity in a project that allows them, project from the config defaults.
    let fallback = MCPHarness(configDefaults: (12, 21))
    // A name where an id belongs is an error, not a silent fall back to the default project.
    #expect(await fallback.call("start_tracking", ["description": "x", "project_id": "Internal"]).isError)
    #expect(await !fallback.call("start_tracking", ["description": "x"]).isError)
    #expect(fallback.sessions.map(\.activityId) == [21])
}

@Test func mcpListsProjectsRespectingGlobalActivities() async {
    let h = MCPHarness(agentDefaults: (13, 18))
    let all = await h.call("list_projects").text
    #expect(all.contains("Northwind Traders\n  Ops Dashboard [12]: Automation [3], + global"))
    #expect(all.contains("In-house\n  Internal [13]: Internal work [18]\n"))
    #expect(all.contains("Global activities (usable in projects marked + global): Development [21]"))
    #expect(all.contains("project 13, activity 18"))
    let filtered = await h.call("list_projects", ["search": "internal"]).text
    #expect(!filtered.contains("Northwind") && filtered.contains("Internal [13]"))
    #expect(await h.call("list_projects", ["search": "zzz"]).text == "No projects match \"zzz\".")
}

@Test func mcpLogTimeValidatesAndBooks() async throws {
    let h = MCPHarness(configDefaults: (12, 3))
    // Yesterday 23:30 in a +02:00 zone, whole minutes.
    let plus2 = TimeZone(secondsFromGMT: 2 * 3600)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = plus2
    let yesterday = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: calendar.date(byAdding: .day, value: -1, to: .now)!)!
    let iso = { (date: Date) in KimaiDate.formatWithOffset(date, in: plus2) }
    for bad: [String: Any] in [
        ["description": "x"],
        ["description": "x", "minutes": 0],
        ["description": "x", "minutes": 1441],
        ["description": "x", "begin": "2026-10-08T15:00:00", "end": "2026-10-08T14:00:00"],
        ["description": "x", "begin": "2026-10-06T08:00:00Z", "end": "2026-10-07T08:00:01Z"],
        ["description": "x", "begin": "yesterday", "end": "today"],
        ["description": "x", "begin": KimaiDate.format(.now, in: AIFakeKimai.timeZone), "end": KimaiDate.format(.now + 3600, in: AIFakeKimai.timeZone)],
        // Half or mixed: never a silent "minutes ending now" that drops the begin.
        ["description": "x", "begin": iso(yesterday)],
        ["description": "x", "end": iso(yesterday)],
        ["description": "x", "end": iso(yesterday), "minutes": 30],
        ["description": "x", "begin": iso(yesterday), "end": iso(yesterday + 600), "minutes": 10],
        // A wrong year (or month) is refused, not booked into a closed period.
        ["description": "x", "begin": iso(yesterday - 365 * 86400), "end": iso(yesterday - 365 * 86400 + 3600)],
        ["description": "x", "begin": iso(.now - 8 * 86400), "minutes": 30],
    ] {
        #expect(await h.call("log_time", bad).isError, "\(bad)")
    }
    #expect(h.kimai.posts.isEmpty)
    let old = await h.call("log_time", ["description": "x", "begin": iso(.now - 30 * 86400), "minutes": 30]).text
    #expect(old.contains("more than 7 days ago; today is \(KimaiDate.format(.now, in: AIFakeKimai.timeZone).prefix(10))"))

    let booked = await h.call("log_time", ["description": "Review", "begin": iso(yesterday), "end": iso(yesterday + 5400)])
    #expect(!booked.isError && booked.text.hasPrefix("Booked 1:30 h"))
    let body = try #require(h.kimai.posts.last)
    // 23:30 at +02:00 is 11:30 the next day at +14:00.
    #expect((body["begin"] as? String)?.hasSuffix("T11:30:00+14:00") == true && (body["end"] as? String)?.hasSuffix("T13:00:00+14:00") == true)
    #expect(body["tags"] as? String == "ai-claude-code" && body["user"] as? Int == 2 && body["project"] as? Int == 12)

    _ = await h.call("log_time", ["description": "Quick fix", "minutes": 25])
    let quick = try #require(h.kimai.posts.last)
    let begin = try #require(KimaiDate.parse(quick["begin"] as? String ?? ""))
    let end = try #require(KimaiDate.parse(quick["end"] as? String ?? ""))
    #expect(end.timeIntervalSince(begin) == 25 * 60 && abs(end.timeIntervalSinceNow) < 5)

    // From a begin, for some minutes.
    let fromBegin = await h.call("log_time", ["description": "Pairing", "begin": iso(yesterday), "minutes": 45])
    #expect(!fromBegin.isError && fromBegin.text.hasPrefix("Booked 0:45 h"))
    #expect(h.kimai.posts.last?["end"] as? String == KimaiDate.formatWithOffset(yesterday + 45 * 60, in: AIFakeKimai.timeZone))
    #expect(h.sessions.isEmpty)
}

@Test func mcpLogTimeCreatesANewAgentsTag() async throws {
    let h = MCPHarness(configDefaults: (12, 3))
    h.kimai.setTags([])
    let booked = await h.call("log_time", ["description": "First ever", "minutes": 5])
    #expect(!booked.isError, "\(booked.text)")
    #expect(h.kimai.tags == ["ai-claude-code"] && h.kimai.posts.last?["tags"] as? String == "ai-claude-code")
}

@Test func mcpAnswersBatchesOnlyWhere2025_03_26AllowsThem() async throws {
    let h = MCPHarness()
    let batch = #"[{"jsonrpc":"2.0","id":2,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":3,"method":"tools/list"}]"#
    // Not negotiated (yet): one Invalid Request, as before.
    let refused = try #require(await h.server.handle(batch))
    #expect(refused.contains("-32600") && refused.hasPrefix("{"))

    _ = await h.send("initialize", ["protocolVersion": "2025-03-26"])
    let reply = try #require(await h.server.handle(batch))
    let replies = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [[String: Any]])
    #expect(replies.map { $0["id"] as? Int } == [2, 3] && replies[1]["result"] is [String: Any])
    #expect(!reply.contains("\n"))
    #expect(await h.server.handle(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#) == nil)
    #expect(await h.server.handle("[]")?.contains("-32600") == true)

    _ = await h.send("initialize", ["protocolVersion": "2025-06-18"])
    #expect(await h.server.handle(batch)?.hasPrefix("{") == true)
}
