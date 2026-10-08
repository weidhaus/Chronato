import CryptoKit
import Foundation

// AI agents that may book their time in Kimai through Chronato.
//
// Convention (matches what is already in the Kimai instance):
//   * AI time is booked as a separate Kimai user (default: the user named
//     "Claude"), so "my hours" stay clean.
//   * Every AI entry carries the tag `ai-<agent-name>`.
//   * Entries are booked finished (begin + end) when the agent stops, never
//     as running timers: Kimai allows one running entry per user, and an AI
//     starting a timer must never stop the human's.

/// One allow-listed AI agent.
public struct AIAgent: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Lower-case slug, unique. Tag in Kimai = `ai-<name>`.
    public var name: String
    public var enabled: Bool
    /// SHA-256 (hex) of the agent's token. The token itself is shown once.
    public var tokenHash: String
    /// Optional per-agent defaults, used when the agent does not name a project/activity.
    public var defaultProjectId: Int?
    public var defaultActivityId: Int?
    public var createdAt: Date

    public var tag: String { "ai-\(name)" }

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, tokenHash: String, defaultProjectId: Int? = nil, defaultActivityId: Int? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.tokenHash = tokenHash
        self.defaultProjectId = defaultProjectId
        self.defaultActivityId = defaultActivityId
        self.createdAt = createdAt
    }
}

/// agents.json: the allowlist plus where AI time goes by default.
public struct AIConfig: Codable, Sendable, Equatable {
    /// Kimai user AI time is booked as. nil = the API token's own user.
    public var bookingUserId: Int?
    /// Fallback project/activity when neither the agent call nor the agent's defaults name one.
    public var defaultProjectId: Int?
    public var defaultActivityId: Int?
    public var agents: [AIAgent]
    /// The Kimai server those user, project and activity ids belong to. nil: saved by an
    /// older build, taken to be the current server.
    public var server: URL?

    public init(bookingUserId: Int? = nil, defaultProjectId: Int? = nil, defaultActivityId: Int? = nil, agents: [AIAgent] = [], server: URL? = nil) {
        self.bookingUserId = bookingUserId
        self.defaultProjectId = defaultProjectId
        self.defaultActivityId = defaultActivityId
        self.agents = agents
        self.server = server
    }

    /// The ids in here mean something on `url`: never book user #2 or project 12 of one
    /// server into another.
    public func isFor(_ url: URL) -> Bool { server == nil || server == url }

    public static func load(from url: URL = Paths.agentsFile) -> AIConfig {
        guard let data = try? Data(contentsOf: url) else { return AIConfig() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AIConfig.self, from: data)) ?? AIConfig()
    }

    public func save(to url: URL = Paths.agentsFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
        // Only token hashes live here, but there is no reason for anyone else to read it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// "Claude Code" → "claude-code".
    public static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// New random token: 32 bytes, base64url.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Adds an agent and returns it with its plaintext token (shown to the user once).
    public mutating func addAgent(named raw: String) throws -> (agent: AIAgent, token: String) {
        let name = Self.slug(raw)
        guard !name.isEmpty else { throw AIAgentError.invalidName }
        guard !agents.contains(where: { $0.name == name }) else { throw AIAgentError.duplicate(name) }
        let token = Self.makeToken()
        let agent = AIAgent(name: name, tokenHash: Self.hash(token))
        agents.append(agent)
        return (agent, token)
    }

    /// Replaces an agent's token; the old one stops working at once.
    public mutating func regenerateToken(for id: UUID) -> String? {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return nil }
        let token = Self.makeToken()
        agents[index].tokenHash = Self.hash(token)
        return token
    }

    /// The enabled agent with this name and token, or nil.
    public func authenticate(name: String, token: String) -> AIAgent? {
        guard let agent = agents.first(where: { $0.name == name }), agent.enabled else { return nil }
        // Constant-time compare of the two hex digests.
        let a = Array(agent.tokenHash.utf8), b = Array(Self.hash(token).utf8)
        guard a.count == b.count else { return nil }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 ? agent : nil
    }
}

public enum AIAgentError: Error, LocalizedError, Equatable {
    case invalidName
    case duplicate(String)
    case notAllowed
    case noProject
    case notConfigured
    /// agents.json was set up for another Kimai server.
    case settingsForOtherServer(String)
    /// The session was started on another Kimai server.
    case startedOnOtherServer(String)
    /// Kimai booked the entry but dropped its ai- tag.
    case untagged(entry: Int, tag: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Agent names need at least one letter or digit."
        case let .duplicate(name): return "An agent named \(name) already exists."
        case .notAllowed: return "This agent is not allowed to track time (unknown, disabled, or wrong token). Allow it in Chronato → Settings → AI Agents."
        case .noProject: return "No project/activity given and no default configured for this agent."
        case .notConfigured: return "Chronato is not connected to Kimai yet. Open Chronato → Settings → Connection."
        case let .settingsForOtherServer(host): return "Chronato's AI agent settings were made for another Kimai server (\(host)). Check them in Chronato → Settings → AI Agents."
        case let .startedOnOtherServer(host): return "Started on another Kimai server (\(host)). Connect Chronato to it again to book this session, or discard it."
        case let .untagged(entry, tag): return "Kimai booked entry #\(entry) but dropped its tag \(tag). Add the tag to that entry in Kimai."
        }
    }
}

/// An AI agent's open work session. Lives as `sessions/<id>.json` until it is
/// booked, so the menu bar can show it and a crashed agent can be cleaned up.
public struct AgentSession: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var agentName: String
    public var projectId: Int
    public var activityId: Int
    public var customerName: String?
    public var projectName: String?
    public var activityName: String?
    public var description: String
    public var begin: Date
    /// Last time the agent called Chronato.
    public var lastSeen: Date
    /// The `Chronato mcp` process that owns the session; 0 once it has left it to the app.
    public var pid: Int32
    /// The Kimai server it was started on (nil: an older build). It is booked there only.
    public var server: URL?
    /// When the agent stopped it. Saved before booking, so the end survives Kimai being
    /// down or the process being killed; the app books it then.
    public var stoppedAt: Date?
    /// Kimai's reason when it last refused to book the session; nil while it never did.
    public var lastError: String?

    public init(id: UUID = UUID(), agentName: String, projectId: Int, activityId: Int, customerName: String? = nil, projectName: String? = nil, activityName: String? = nil, description: String, begin: Date = .now, lastSeen: Date = .now, pid: Int32 = ProcessInfo.processInfo.processIdentifier, server: URL? = nil, stoppedAt: Date? = nil, lastError: String? = nil) {
        self.id = id
        self.agentName = agentName
        self.projectId = projectId
        self.activityId = activityId
        self.customerName = customerName
        self.projectName = projectName
        self.activityName = activityName
        self.description = description
        self.begin = begin
        self.lastSeen = lastSeen
        self.pid = pid
        self.server = server
        self.stoppedAt = stoppedAt
        self.lastError = lastError
    }
}
