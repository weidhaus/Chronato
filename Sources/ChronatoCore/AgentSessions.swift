import Foundation

/// Open AI-agent sessions on disk (`Paths.sessionsDir/<id>.json`) and booking
/// them into Kimai. Shared by `Chronato mcp` (writes) and the menu-bar app
/// (shows them, reaps orphans). `dir` is only overridden by tests.
public enum AgentSessions {
    /// Longest session Chronato will book; older ones are capped (same rule as the human timer).
    public static let maxDuration: TimeInterval = 24 * 60 * 60
    /// Shortest entry Chronato books, so a task started and stopped within the same minute still shows up.
    static let minDuration: TimeInterval = 60
    /// A `.booking` claim this old belongs to a booking that died before Kimai answered:
    /// a live one takes a minute at most (each request times out after 20 s).
    static let staleClaim: TimeInterval = 5 * 60

    /// The session file is gone: the app or the agent booked it meanwhile.
    public struct AlreadyBooked: Error, LocalizedError {
        public var errorDescription: String? { "This session was already booked (by the Chronato app or the agent)." }
    }

    /// Every readable session, oldest first. Corrupt files are skipped, not deleted.
    public static func list(in dir: URL = Paths.sessionsDir) -> [AgentSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(read).sorted { $0.begin < $1.begin }
    }

    static func read(_ url: URL) -> AgentSession? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentSession.self, from: Data(contentsOf: url))
    }

    public static func save(_ session: AgentSession, in dir: URL = Paths.sessionsDir) throws {
        try write(session, to: file(session.id, in: dir))
    }

    static func write(_ session: AgentSession, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Rewrites the session's existing file. Unlike `save` it never brings a missing file back,
    /// so a write racing a booking can't resurrect a booked session: RENAME_SWAP fails unless
    /// both files exist. false (nothing written) when the file is gone.
    @discardableResult
    public static func update(_ session: AgentSession, in dir: URL = Paths.sessionsDir) throws -> Bool {
        let tmp = dir.appendingPathComponent("\(session.id.uuidString).\(getpid()).tmp")
        try write(session, to: tmp)
        defer { unlink(tmp.path) }
        guard renamex_np(tmp.path, file(session.id, in: dir).path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    public static func remove(_ id: UUID, in dir: URL = Paths.sessionsDir) {
        try? FileManager.default.removeItem(at: file(id, in: dir))
    }

    static func file(_ id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    /// Books `session` as a finished entry (begin…end) for `config.bookingUserId`,
    /// tagged `ai-<agent>`, then deletes the session file. `end` is clamped to
    /// [begin + 1 min, begin + 24 h]. Throws `AlreadyBooked` when the file is gone. When
    /// Kimai refuses, throws and keeps the file, noting the reason in `lastError` (not
    /// when Kimai was merely unreachable).
    public static func book(_ session: AgentSession, end: Date, client: KimaiClient, config: AIConfig, in dir: URL = Paths.sessionsDir) async throws -> KimaiTimesheet {
        let file = file(session.id, in: dir)
        let claim = file.appendingPathExtension("booking")
        // The rename is the lock: the app's reaper (refreshes can overlap) and the agent's
        // own `Chronato mcp` may book the same session; only one rename wins. Its time stamp
        // dates the claim, so `recoverClaims` can tell one left by a killed booking.
        do { try FileManager.default.moveItem(at: file, to: claim) } catch { throw AlreadyBooked() }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: claim.path)
        do {
            if let server = session.server, server != client.connection.url {
                throw AIAgentError.startedOnOtherServer(server.host ?? server.absoluteString)
            }
            let entry = try await create(NewTimesheet(
                project: session.projectId, activity: session.activityId, begin: session.begin,
                end: min(max(end, session.begin + minDuration), session.begin + maxDuration),
                description: session.description), tag: "ai-\(session.agentName)", client: client, config: config)
            try? FileManager.default.removeItem(at: claim)
            return entry
        } catch {
            if case .untagged? = error as? AIAgentError {
                // The entry exists; booking it again would count the time twice.
                try? FileManager.default.removeItem(at: claim)
                throw error
            }
            if !KimaiError.isTransient(error), var refused = read(claim) {
                refused.lastError = error.localizedDescription
                try? write(refused, to: claim)
            }
            try? FileManager.default.moveItem(at: claim, to: file)
            throw error
        }
    }

    /// POSTs a finished AI entry tagged `tag` for `config.bookingUserId`. Makes sure the tag
    /// exists first and that Kimai kept it: with no booking user, the tag is all that tells
    /// AI time from the owner's.
    public static func create(_ new: NewTimesheet, tag: String, client: KimaiClient, config: AIConfig) async throws -> KimaiTimesheet {
        guard config.isFor(client.connection.url) else {
            throw AIAgentError.settingsForOtherServer(config.server?.host ?? "?")
        }
        try await client.ensureTag(tag)
        var new = new
        new.tags = [tag]
        new.user = config.bookingUserId
        let entry: KimaiTimesheet
        do {
            entry = try await client.create(new)
        } catch let KimaiError.http(status, message) where status == 400 && message.contains("extra fields") {
            throw KimaiError.http(status: 400, message: message + ". Booking as another Kimai user needs the create_other_timesheet permission; setting begin and end outside Kimai's default tracking mode needs view_other_timesheet.")
        }
        guard entry.tags.contains(tag) else {
            client.forgetTag(tag)
            throw AIAgentError.untagged(entry: entry.id, tag: tag)
        }
        return entry
    }

    /// Books what no `Chronato mcp` will book any more: sessions the agent stopped (at that
    /// stop), and, up to the agent's last call (`lastSeen`), sessions whose process is gone or
    /// left them to the app, sessions of agents disabled or removed since, and any open for
    /// 24 h. Kimai refusals stay on disk with `lastError` and are retried; each new reason is
    /// reported once in `failed`. While Kimai is unreachable everything is retried quietly.
    public static func reapStale(client: KimaiClient, config: AIConfig, now: Date = .now, in dir: URL = Paths.sessionsDir) async -> (booked: [String], failed: [String]) {
        await recoverClaims(client: client, config: config, now: now, in: dir)
        var booked: [String] = [], failed: [String] = []
        for session in list(in: dir) {
            let end: Date, reason: String
            if let stopped = session.stoppedAt {
                (end, reason) = (stopped, "stopped earlier")
            } else if !isAlive(session.pid) {
                (end, reason) = (session.lastSeen, "process ended")
            } else if !config.agents.contains(where: { $0.name == session.agentName && $0.enabled }) {
                (end, reason) = (session.lastSeen, "agent disabled")
            } else if now.timeIntervalSince(session.begin) >= maxDuration {
                (end, reason) = (session.lastSeen, "still open after 24 h")
            } else {
                continue
            }
            do {
                let entry = try await book(session, end: end, client: client, config: config, in: dir)
                booked.append("Booked \(hours(entry.seconds())) for \(session.agentName) (\(reason))")
            } catch is AlreadyBooked {
                continue
            } catch {
                guard !KimaiError.isTransient(error), error.localizedDescription != session.lastError else { continue }
                failed.append("\(session.agentName), \"\(session.description)\": \(error.localizedDescription)")
            }
        }
        return (booked, failed)
    }

    /// `.booking` claims left by a booking that was killed before Kimai answered (an MCP
    /// client kills its server a moment after closing it). If Kimai has the entry the claim
    /// goes, otherwise it becomes a session again and is booked. Never booked twice.
    static func recoverClaims(client: KimaiClient, config: AIConfig, now: Date, in dir: URL) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for claim in files where claim.pathExtension == "booking" {
            guard let claimed = (try? claim.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(claimed) > staleClaim, let session = read(claim),
                  session.server == nil || session.server == client.connection.url,
                  // Kimai floors begin to the minute.
                  let near = try? await client.timesheets(user: config.bookingUserId.map(String.init), begin: session.begin - 60, end: session.begin + 60)
            else { continue }
            // ponytail: matched on begin, tag and description; Kimai has no field for our session id.
            if near.contains(where: { $0.tags.contains("ai-\(session.agentName)") && $0.description == session.description }) {
                try? FileManager.default.removeItem(at: claim)
            } else {
                try? FileManager.default.moveItem(at: claim, to: file(session.id, in: dir))
            }
        }
    }

    /// kill(pid, 0) probes without signalling. Only ESRCH means gone; EPERM is a live process
    /// we may not signal. pid ≤ 0 would address a process group, so it counts as gone.
    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH)
    }

    /// "1:12 h".
    static func hours(_ seconds: Int) -> String {
        String(format: "%d:%02d h", seconds / 3600, (seconds % 3600) / 60)
    }

    // MARK: Setup snippets

    /// Where the installed app's binary lives; MCP clients should start `Chronato mcp` from here.
    public static let installedExecutable = "/Applications/Chronato.app/Contents/MacOS/Chronato"

    /// The binary path to put into an MCP client's config, plus a warning when the running
    /// copy's path won't last: a mounted disk image, or a quarantined download macOS runs
    /// from a random read-only place (App Translocation). Those get the /Applications path.
    public static func stableExecutable(bundlePath: String, executablePath: String, home: String = NSHomeDirectory()) -> (path: String, warning: String?) {
        if bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/") {
            return (installedExecutable, "Chronato is running from the disk image or from Downloads. Move it to Applications and open it from there: this setup points at /Applications.")
        }
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/") {
            return (executablePath, nil)
        }
        return (executablePath, "Chronato isn't in Applications: this setup points at \(executablePath), so keep it there.")
    }

    /// Shell command that registers Chronato as an MCP server in Claude Code. It first drops
    /// an older "chronato" registration (new token, another agent), so it can be run again.
    public static func setupCommand(agentName: String, token: String, executable: String) -> String {
        "claude mcp remove chronato --scope user 2>/dev/null; claude mcp add chronato --scope user -e CHRONATO_AGENT=\(shellQuoted(agentName)) -e CHRONATO_TOKEN=\(shellQuoted(token)) -- \(shellQuoted(executable)) mcp"
    }

    /// The `mcpServers` block most other MCP clients (Cursor, Claude Desktop, …) read from their JSON config.
    public static func setupJSON(agentName: String, token: String, executable: String) -> String {
        let object: [String: Any] = ["mcpServers": ["chronato": [
            "command": executable,
            "args": ["mcp"],
            "env": ["CHRONATO_AGENT": agentName, "CHRONATO_TOKEN": token],
        ]]]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The server table for Codex CLI's ~/.codex/config.toml.
    public static func setupTOML(agentName: String, token: String, executable: String) -> String {
        """
        [mcp_servers.chronato]
        command = \(tomlQuoted(executable))
        args = ["mcp"]
        env = { CHRONATO_AGENT = \(tomlQuoted(agentName)), CHRONATO_TOKEN = \(tomlQuoted(token)) }
        """
    }

    /// POSIX single quotes; an embedded ' becomes '\''.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A TOML basic string.
    static func tomlQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
