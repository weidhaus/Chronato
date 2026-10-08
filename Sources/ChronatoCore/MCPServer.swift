import Foundation

// macOS only: a stdio server that agents launch as a process. The iPhone app has no MCP.
#if os(macOS)

/// `Chronato mcp`: a Model Context Protocol server over stdio (newline-delimited
/// JSON-RPC 2.0) that lets one allow-listed AI agent track its own time.
/// Identity comes from the environment: CHRONATO_AGENT (name) + CHRONATO_TOKEN.
///
/// stdout carries protocol messages only; diagnostics go to stderr (never the token).
/// An actor because a SIGTERM may arrive while a tool call is in flight.
public actor MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// The one revision with JSON-RPC batches (2025-06-18 dropped them again).
    static let batchingVersion = "2025-03-26"

    private let environment: [String: String]
    private let connection: @Sendable () throws -> KimaiConnection?
    private let loadConfig: @Sendable () -> AIConfig
    private let urlSession: URLSession
    private let sessionsDir: URL
    /// Made on first use and kept while the app's connection stays the same; carries the
    /// Kimai user's time zone (one /users/me call).
    private var client: KimaiClient?
    /// The session this process started and has not booked yet.
    private var open: AgentSession?
    /// Protocol revision agreed in `initialize`.
    private var negotiated: String?
    /// The request being handled, so a shutdown waits for it instead of exiting mid-booking.
    private var inFlight: Task<String?, Never>?
    /// The one shutdown, however many of stdin EOF, SIGTERM, SIGINT and SIGHUP arrive.
    private var stopping: Task<Void, Never>?
    private var signalSources: [any DispatchSourceSignal] = []

    public init() {
        self.init(environment: ProcessInfo.processInfo.environment, connection: { try Credentials.load() },
                  loadConfig: { AIConfig.load() }, urlSession: KimaiClient.defaultSession, sessionsDir: Paths.sessionsDir)
    }

    /// Tests inject everything, so they never touch the Keychain, the real agents.json or the network.
    init(environment: [String: String], connection: @escaping @Sendable () throws -> KimaiConnection?,
         loadConfig: @escaping @Sendable () -> AIConfig, urlSession: URLSession, sessionsDir: URL) {
        self.environment = environment
        self.connection = connection
        self.loadConfig = loadConfig
        self.urlSession = urlSession
        self.sessionsDir = sessionsDir
    }

    /// Runs until stdin closes. Returns the process exit code.
    public func run() async -> Int32 {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            // @Sendable: otherwise the closure counts as actor-isolated and Swift traps
            // when Dispatch runs it on its own queue.
            source.setEventHandler { @Sendable in
                Task {
                    await self.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        log("ready for agent \(environment["CHRONATO_AGENT"] ?? "(CHRONATO_AGENT not set)")")
        var line = Data()
        do {
            // Split at "\n" only: `bytes.lines` also splits at U+2028 and U+0085, which
            // JSON strings may carry unescaped (JavaScript's JSON.stringify does).
            for try await byte in FileHandle.standardInput.bytes {
                guard byte == UInt8(ascii: "\n") else { line.append(byte); continue }
                if let reply = await handle(String(decoding: line, as: UTF8.self)) {
                    FileHandle.standardOutput.write(Data((reply + "\n").utf8))
                }
                line.removeAll(keepingCapacity: true)
            }
        } catch {
            log("stdin: \(error.localizedDescription)")
        }
        await shutdown()
        return 0
    }

    /// The agent's client went away. Waits for the request in flight, then leaves an open
    /// session to the app, which books it up to the agent's last call. Nothing goes over the
    /// network here: clients kill their server a moment after closing it, and a booking cut
    /// off halfway is worse than none. Every caller waits for the same shutdown (stdin EOF
    /// and a signal often arrive together).
    func shutdown() async {
        if stopping == nil {
            stopping = Task {
                _ = await inFlight?.value
                release("the client went away")
            }
        }
        await stopping?.value
    }

    /// Hands the open session to the app: pid 0 marks it as nobody's, so the app's reaper
    /// books it up to `lastSeen`, the agent's last call.
    private func release(_ why: String) {
        guard var session = open else { return }
        open = nil
        session.pid = 0
        if (try? AgentSessions.update(session, in: sessionsDir)) == true {
            log("\(why); Chronato books the open session up to the agent's last call")
        }
    }

    // MARK: JSON-RPC

    /// One incoming line → the reply line, or nil for notifications and responses.
    func handle(_ line: String) async -> String? {
        let request = Task { await respond(to: line) }
        inFlight = request
        return await request.value
    }

    private func respond(to line: String) async -> String? {
        guard !line.allSatisfy(\.isWhitespace) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            return reply(id: NSNull(), error: (-32700, "Parse error"))
        }
        guard let batch = object as? [Any] else { return await respond(toMessage: object) }
        // A batch: only 2025-03-26 has them, and never an empty one. One reply array, without
        // the notifications and responses in it; nothing at all if that leaves none.
        guard negotiated == Self.batchingVersion, !batch.isEmpty else { return reply(id: NSNull(), error: (-32600, "Invalid Request")) }
        var replies: [String] = []
        for message in batch {
            if let reply = await respond(toMessage: message) { replies.append(reply) }
        }
        return replies.isEmpty ? nil : "[" + replies.joined(separator: ",") + "]"
    }

    private func respond(toMessage object: Any) async -> String? {
        guard let message = object as? [String: Any], let method = message["method"] as? String else {
            let dict = object as? [String: Any]
            // A response to a request we never sent: nothing to say.
            if dict?["result"] != nil || dict?["error"] != nil { return nil }
            return reply(id: dict?["id"] ?? NSNull(), error: (-32600, "Invalid Request"))
        }
        // Notifications (no id) are never answered.
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            negotiated = version
            return reply(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "chronato", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "instructions": "Chronato books your working time in Kimai. Call start_tracking with a short description when you begin a task and stop_tracking when it is done. list_projects shows the project and activity ids; log_time books work that is already finished.",
            ])
        case "ping":
            return reply(id: id, result: [String: Any]())
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return reply(id: id, error: (-32602, "Unknown tool: \(params["name"] ?? "")"))
            }
            let (text, isError) = await call(name, params["arguments"] as? [String: Any] ?? [:])
            return reply(id: id, result: ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return reply(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private func reply(id: Any, result: Any? = nil, error: (code: Int, message: String)? = nil) -> String {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error {
            object["error"] = ["code": error.code, "message": error.message]
        } else {
            object["result"] = result
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Tools

    static var tools: [[String: Any]] {
        let ids: [String: Any] = [
            "project_id": ["type": "integer", "description": "Kimai project id (see list_projects). Optional when a default project is configured."],
            "activity_id": ["type": "integer", "description": "Kimai activity id (see list_projects); must belong to the project or be a global activity the project allows. Optional when a default is configured."],
        ]
        let description: [String: Any] = ["type": "string", "description": "What you are working on, in a few words (shown in Kimai)."]
        func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        return [
            ["name": "list_projects",
             "description": "List the Kimai customers, projects and activities (with ids) your time can be booked on, and the configured defaults.",
             "inputSchema": object(["search": ["type": "string", "description": "Only show projects whose customer, project or activity name contains this text."]])],
            ["name": "start_tracking",
             "description": "Start tracking your working time on a task. Call it when you begin a task and call stop_tracking when you are done. If a task is already being tracked, it is booked first.",
             "inputSchema": object(ids.merging(["description": description]) { a, _ in a }, required: ["description"])],
            ["name": "stop_tracking",
             "description": "Stop tracking and book the time of the current task in Kimai.",
             "inputSchema": object(["description": ["type": "string", "description": "Optional final description, replacing the one given to start_tracking."]])],
            ["name": "tracking_status",
             "description": "Show the task being tracked right now, if any.",
             "inputSchema": object([:])],
            ["name": "log_time",
             "description": "Book work that is already finished: `minutes` ending now, `begin` and `minutes`, or `begin` and `end`. At most 24 h, not in the future, and begun within the last \(Self.logTimeMaxAgeDays) days.",
             "inputSchema": object(ids.merging([
                 "description": description,
                 "minutes": ["type": "integer", "minimum": 1, "maximum": 1440, "description": "Duration in minutes; ends now unless begin is given."],
                 "begin": ["type": "string", "description": "ISO 8601 start, e.g. 2026-10-08T14:00:00+02:00. Without an offset the Kimai user's time zone is used."],
                 "end": ["type": "string", "description": "ISO 8601 end, same format as begin."],
             ]) { a, _ in a }, required: ["description"])],
        ]
    }

    private struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Every call re-reads agents.json, so disabling an agent or regenerating its token takes effect at once.
    private func call(_ tool: String, _ args: [String: Any]) async -> (text: String, isError: Bool) {
        let config = loadConfig()
        guard let agent = config.authenticate(name: environment["CHRONATO_AGENT"] ?? "", token: environment["CHRONATO_TOKEN"] ?? "") else {
            // Disabled, removed or given a new token: its open session ends at its last allowed call.
            release("the agent is no longer allowed")
            return (AIAgentError.notAllowed.localizedDescription, true)
        }
        touch()
        do {
            switch tool {
            case "list_projects": return (try await listProjects(search: args["search"] as? String, agent: agent, config: config), false)
            case "start_tracking": return (try await start(args, agent: agent, config: config), false)
            case "stop_tracking": return (try await stop(args, config: config), false)
            case "tracking_status": return (status(), false)
            default: return (try await logTime(args, agent: agent, config: config), false)
            }
        } catch {
            log("\(tool): \(error.localizedDescription)")
            return (error.localizedDescription, true)
        }
    }

    /// The agent is still here: the reaper books up to lastSeen if this session is never
    /// stopped. A missing file means the app already booked it (24 h limit, agent disabled).
    private func touch() {
        guard var session = open else { return }
        session.lastSeen = .now
        if (try? AgentSessions.update(session, in: sessionsDir)) == false { open = nil } else { open = session }
    }

    private func listProjects(search: String?, agent: AIAgent, config: AIConfig) async throws -> String {
        let (customers, projects, activities) = try await catalog(kimai())
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let byName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        let globals = activities.filter { $0.project == nil }.sorted { byName($0.name, $1.name) }
        var lines = ["Customer, then project [project_id]: activities [activity_id]"]
        for customer in customers.sorted(by: { byName($0.name, $1.name) }) {
            var block: [String] = []
            for project in projects.filter({ $0.customer == customer.id }).sorted(by: { byName($0.name, $1.name) }) {
                let own = activities.filter { $0.project == project.id }.sorted { byName($0.name, $1.name) }
                let allowsGlobal = project.globalActivities != false
                let haystack = ([customer.name, project.name] + own.map(\.name) + (allowsGlobal ? globals.map(\.name) : [])).joined(separator: " ")
                guard query.isEmpty || haystack.localizedStandardContains(query) else { continue }
                var names = own.map { "\($0.name) [\($0.id)]" }
                if allowsGlobal && !globals.isEmpty { names.append("+ global") }
                block.append("  \(project.name) [\(project.id)]: \(names.isEmpty ? "no activities" : names.joined(separator: ", "))")
            }
            if !block.isEmpty { lines += [customer.name] + block }
        }
        if lines.count == 1 { return query.isEmpty ? "No visible projects in Kimai." : "No projects match \"\(query)\"." }
        if !globals.isEmpty {
            lines.append("Global activities (usable in projects marked + global): " + globals.map { "\($0.name) [\($0.id)]" }.joined(separator: ", "))
        }
        if let project = agent.defaultProjectId ?? config.defaultProjectId, let activity = agent.defaultActivityId ?? config.defaultActivityId {
            lines.append("Default when start_tracking gets no ids: project \(project), activity \(activity).")
        } else {
            lines.append("No default configured: pass project_id and activity_id.")
        }
        return lines.joined(separator: "\n")
    }

    private func start(_ args: [String: Any], agent: AIAgent, config: AIConfig) async throws -> String {
        let description = try Self.description(args)
        let client = try await kimai()
        let (project, activity, customer) = try await target(args, agent: agent, config: config, client: client)
        var text = ""
        if let previous = open {
            // Ended either way; a booking problem must not keep the new task from starting.
            do { text = try await finish(previous, at: .now, config: config) + " " } catch { text = error.localizedDescription + " " }
        }
        let session = AgentSession(agentName: agent.name, projectId: project.id, activityId: activity.id, customerName: customer?.name,
                                   projectName: project.name, activityName: activity.name, description: description,
                                   server: client.connection.url)
        try AgentSessions.save(session, in: sessionsDir)
        open = session
        return text + "Tracking \"\(description)\" on \(Self.path(session)) since \(clock(session.begin)). Call stop_tracking when the task is done."
    }

    private func stop(_ args: [String: Any], config: AIConfig) async throws -> String {
        guard var session = open else { return "Not tracking; nothing to stop." }
        if let text = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            session.description = text
        }
        return try await finish(session, at: .now, config: config)
    }

    /// Ends `session` at `end`. The stop goes into its file before anything goes to Kimai, so
    /// the end holds if Kimai is down or this process is killed; the app books it then.
    private func finish(_ session: AgentSession, at end: Date, config: AIConfig) async throws -> String {
        var session = session
        session.stoppedAt = end
        open = nil
        do {
            guard try AgentSessions.update(session, in: sessionsDir) else { throw AgentSessions.AlreadyBooked() }
            let entry = try await AgentSessions.book(session, end: end, client: kimai(), config: config, in: sessionsDir)
            return "Booked \(AgentSessions.hours(entry.seconds())) for \"\(session.description)\" on \(Self.path(session)) (Kimai entry #\(entry.id))."
        } catch is AgentSessions.AlreadyBooked {
            return "\"\(session.description)\" was already booked by the Chronato app (open for 24 h, or the agent was disabled)."
        } catch where KimaiError.isTransient(error) {
            return "Stopped \"\(session.description)\" at \(clock(end)). Kimai can't be reached right now (\(error.localizedDescription)); Chronato books it once Kimai is back."
        } catch {
            throw ToolError("Stopped \"\(session.description)\" at \(clock(end)), but it could not be booked: \(error.localizedDescription) Chronato keeps it and shows it in its menu.")
        }
    }

    private func status() -> String {
        guard let session = open else { return "Not tracking." }
        let seconds = Int(Date.now.timeIntervalSince(session.begin))
        return "Tracking \"\(session.description)\" on \(Self.path(session)) since \(clock(session.begin)) (\(AgentSessions.hours(seconds)))."
    }

    /// How far back log_time books. Models get the year wrong now and then, and older
    /// periods may be exported or invoiced already.
    static let logTimeMaxAgeDays = 7

    private func logTime(_ args: [String: Any], agent: AIAgent, config: AIConfig) async throws -> String {
        let description = try Self.description(args)
        let client = try await kimai()
        let now = Date.now
        func date(_ key: String) throws -> Date? {
            guard let value = args[key], !(value is NSNull) else { return nil }
            guard let text = value as? String, let date = Self.parseDate(text, in: client.timeZone) else {
                throw ToolError("\(key) must be ISO 8601, e.g. 2026-10-08T14:00:00+02:00.")
            }
            return date
        }
        let minutes = try Self.int(args, "minutes")
        if let minutes, !(1...1440).contains(minutes) { throw ToolError("minutes must be between 1 and 1440.") }
        let begin: Date, end: Date
        switch try (date("begin"), date("end"), minutes) {
        case let (nil, nil, minutes?): (begin, end) = (now - TimeInterval(minutes * 60), now)
        case let (start?, nil, minutes?): (begin, end) = (start, start + TimeInterval(minutes * 60))
        case let (start?, stop?, nil): (begin, end) = (start, stop)
        default: throw ToolError("Give minutes (ending now), begin and minutes, or begin and end.")
        }
        guard end > begin else { throw ToolError("end must be after begin.") }
        guard end.timeIntervalSince(begin) <= AgentSessions.maxDuration else { throw ToolError("An entry can be at most 24 h long.") }
        guard end <= now + 5 * 60 else { throw ToolError("end is in the future; only finished work can be logged.") }
        guard now.timeIntervalSince(begin) <= TimeInterval(Self.logTimeMaxAgeDays * 86400) else {
            throw ToolError("begin is more than \(Self.logTimeMaxAgeDays) days ago; today is \(clock(now, day: true)) in Kimai's time zone. Check the date; older work has to be booked in Kimai itself.")
        }
        let (project, activity, customer) = try await target(args, agent: agent, config: config, client: client)
        let entry = try await AgentSessions.create(NewTimesheet(project: project.id, activity: activity.id, begin: begin, end: end, description: description),
                                                   tag: agent.tag, client: client, config: config)
        let path = [customer?.name, project.name, activity.name].compactMap { $0 }.joined(separator: " › ")
        return "Booked \(AgentSessions.hours(Int(end.timeIntervalSince(begin)))) (\(clock(begin, day: true))–\(clock(end))) for \"\(description)\" on \(path) (Kimai entry #\(entry.id))."
    }

    // MARK: Helpers

    /// The Kimai client for the app's connection, read from the Keychain on every call: after
    /// a Disconnect or a switch to another server this process follows at once.
    private func kimai() async throws -> KimaiClient {
        guard let connection = try connection() else {
            client = nil
            throw AIAgentError.notConfigured
        }
        if let client, client.connection == connection { return client }
        var made = KimaiClient(connection: connection, session: urlSession)
        made.timeZone = try await made.me().timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        client = made
        return made
    }

    private func catalog(_ client: KimaiClient) async throws -> ([KimaiCustomer], [KimaiProject], [KimaiActivity]) {
        async let customers = client.customers()
        async let projects = client.projects()
        async let activities = client.activities()
        return try await (customers, projects, activities)
    }

    /// Project/activity from the call, else the agent's defaults, else the global ones,
    /// checked against what Kimai shows.
    private func target(_ args: [String: Any], agent: AIAgent, config: AIConfig, client: KimaiClient) async throws -> (KimaiProject, KimaiActivity, KimaiCustomer?) {
        guard config.isFor(client.connection.url) else { throw AIAgentError.settingsForOtherServer(config.server?.host ?? "?") }
        guard let projectId = try Self.int(args, "project_id") ?? agent.defaultProjectId ?? config.defaultProjectId,
              let activityId = try Self.int(args, "activity_id") ?? agent.defaultActivityId ?? config.defaultActivityId else {
            throw ToolError(AIAgentError.noProject.localizedDescription + " Call list_projects and pass project_id and activity_id.")
        }
        let (customers, projects, activities) = try await catalog(client)
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw ToolError("There is no visible Kimai project \(projectId). Call list_projects for valid ids.")
        }
        guard let activity = activities.first(where: { $0.id == activityId }) else {
            throw ToolError("There is no visible Kimai activity \(activityId). Call list_projects for valid ids.")
        }
        // Same rule as Kimai: the project's own activities, plus global ones if the project allows them.
        guard activity.project == project.id || (activity.project == nil && project.globalActivities != false) else {
            throw ToolError("Activity \(activity.name) [\(activity.id)] can't be booked on project \(project.name) [\(project.id)]. Call list_projects for valid combinations.")
        }
        return (project, activity, customers.first { $0.id == project.customer })
    }

    private static func description(_ args: [String: Any]) throws -> String {
        let text = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw ToolError("description is required: say in a few words what you are working on.") }
        return text
    }

    /// Models sometimes send numbers as strings. Present but not a whole number is an error,
    /// never a silent fall back to a default project.
    private static func int(_ args: [String: Any], _ key: String) throws -> Int? {
        guard let value = args[key], !(value is NSNull) else { return nil }
        if let number = (value as? Int) ?? (value as? String).flatMap({ Int($0) }) { return number }
        throw ToolError("\(key) must be a whole number (ids come from list_projects).")
    }

    private static func path(_ session: AgentSession) -> String {
        [session.customerName, session.projectName ?? "project \(session.projectId)", session.activityName ?? "activity \(session.activityId)"]
            .compactMap { $0 }.joined(separator: " › ")
    }

    /// "14:05" (or "2026-10-08 14:05") in the Kimai user's time zone.
    private func clock(_ date: Date, day: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = client?.timeZone ?? .current
        f.dateFormat = day ? "yyyy-MM-dd HH:mm" : "HH:mm"
        return f.string(from: date)
    }

    /// ISO 8601 with an offset ("Z", "+02:00", fractional seconds), or without one in `timeZone`.
    static func parseDate(_ string: String, in timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: string) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: string) { return date }
        }
        return nil
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("chronato mcp: \(message)\n".utf8))
    }
}
#endif
