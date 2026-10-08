import Foundation
import Synchronization

/// Server URL + API token. Stored together in the Keychain (see `Credentials`).
public struct KimaiConnection: Codable, Sendable, Equatable {
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    /// Accepts "kimai.example.net", "https://host/", "https://host/kimai"; nil when unusable.
    public static func normalizedURL(_ raw: String) -> URL? { try? validatedURL(raw) }

    /// `normalizedURL`, saying what is wrong.
    public static func validatedURL(_ raw: String) throws(URLProblem) -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), ["https", "http"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false else {
            throw .invalid
        }
        guard isAllowed(url) else { throw .notHTTPS }
        return url
    }

    /// HTTPS only: the API token must never cross a network in clear text. Plain http is
    /// fine to this Mac itself (a local Kimai, the e2e mock); ATS allows that too.
    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
        default: false
        }
    }

    public enum URLProblem: Error, LocalizedError, Equatable {
        case invalid, notHTTPS

        public var errorDescription: String? {
            switch self {
            case .invalid: "Enter your Kimai address, e.g. kimai.example.net or https://example.net/kimai."
            case .notHTTPS: "Kimai must be reached over HTTPS (plain http only for a Kimai on this Mac)."
            }
        }
    }
}

public enum KimaiError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .http(401, _), .http(403, "Access denied."):
            return "Kimai rejected the API token (check it under Settings → Connection)."
        case let .http(status, message): return "Kimai \(status): \(message)"
        case let .transport(message): return "Can't reach Kimai: \(message)"
        case let .decoding(message): return "Unexpected answer from Kimai: \(message)"
        }
    }

    /// Kimai unreachable or down (proxy, 5xx): worth retrying as is. Anything else is a refusal.
    public static func isTransient(_ error: Error) -> Bool {
        switch error as? KimaiError {
        case .transport?: true
        case let .http(status, _)?: status >= 500
        default: false
        }
    }
}

public enum KimaiDate {
    /// Kimai answers with "2026-10-06T20:52:00+0200".
    public static func parse(_ string: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let date = f.date(from: string) { return date }
        }
        return nil
    }

    /// GET filters (`begin`/`end` of /api/timesheets): Kimai validates them strictly as
    /// HTML5 local date-time ("2026-10-08T14:05:00", `Y-m-d\TH:i:s`) and reads them in the
    /// token user's current time zone.
    public static func format(_ date: Date, in timeZone: TimeZone) -> String {
        formatter(timeZone, "yyyy-MM-dd'T'HH:mm:ss").string(from: date)
    }

    /// Request bodies (POST/PATCH `begin`, `end`): "2026-10-08T14:05:00+02:00". Kimai's API
    /// form (Form/API/DateTimeApiType → Symfony 6.4 DateTimeToHtml5LocalDateTimeTransformer)
    /// parses them with `new \DateTime($value, $zone)`, and PHP ignores `$zone` when the
    /// string has an offset. So the instant is exact whichever zone Kimai applies: the token
    /// user's current one on POST, the entry's stored one on PATCH, either may differ from ours.
    public static func formatWithOffset(_ date: Date, in timeZone: TimeZone) -> String {
        formatter(timeZone, "yyyy-MM-dd'T'HH:mm:ssxxx").string(from: date)
    }

    private static func formatter(_ timeZone: TimeZone, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }()
}

/// Thin async wrapper over the Kimai 2 REST API (Bearer token auth).
public struct KimaiClient: Sendable {
    public let connection: KimaiConnection
    /// Time zone Kimai interprets begin/end in: the API user's, from `/users/me`.
    public var timeZone: TimeZone
    let session: URLSession

    /// Nothing on disk: no cache, cookies or credential store, so Kimai's answers (and the
    /// token in each request) never land in ~/Library/Caches/<bundle id>/Cache.db.
    public static let defaultSession = URLSession(configuration: .ephemeral)

    public init(connection: KimaiConnection, timeZone: TimeZone = .current, session: URLSession = KimaiClient.defaultSession) {
        self.connection = connection
        self.timeZone = timeZone
        self.session = session
    }

    // MARK: Reads

    public func version() async throws -> KimaiVersion { try await get("api/version") }
    public func me() async throws -> KimaiUser { try await get("api/users/me") }
    public func users() async throws -> [KimaiUser] { try await get("api/users", [.init(name: "visible", value: "1")]) }
    public func customers() async throws -> [KimaiCustomer] { try await get("api/customers", [.init(name: "visible", value: "1")]) }
    public func projects() async throws -> [KimaiProject] { try await get("api/projects", [.init(name: "visible", value: "1")]) }
    public func activities() async throws -> [KimaiActivity] { try await get("api/activities", [.init(name: "visible", value: "1")]) }
    public func activeTimesheets() async throws -> [KimaiTimesheet] { try await get("api/timesheets/active") }

    /// My latest `size` timesheets, newest first (one page). Not `/timesheets/recent`:
    /// that keeps only the newest entry per project + activity, so other notes never show.
    public func recentTimesheets(size: Int = 25) async throws -> [KimaiTimesheet] {
        try await get("api/timesheets", [
            .init(name: "size", value: String(size)), .init(name: "orderBy", value: "begin"),
            .init(name: "order", value: "DESC"), .init(name: "full", value: "true"),
        ])
    }

    /// Every timesheet that *started* inside [begin, end], all pages.
    /// `user`: a Kimai user id, "all", or nil for the token's own user.
    public func timesheets(user: String? = nil, begin: Date, end: Date, tags: [String] = []) async throws -> [KimaiTimesheet] {
        var all: [KimaiTimesheet] = []
        var page = 1
        while true {
            var q: [URLQueryItem] = [
                .init(name: "begin", value: KimaiDate.format(begin, in: timeZone)),
                .init(name: "end", value: KimaiDate.format(end, in: timeZone)),
                .init(name: "full", value: "true"),
                .init(name: "size", value: "500"),
                .init(name: "page", value: String(page)),
                .init(name: "orderBy", value: "begin"),
                .init(name: "order", value: "ASC"),
            ]
            if let user { q.append(.init(name: "user", value: user)) }
            q += tags.map { .init(name: "tags[]", value: $0) }
            let (data, response) = try await send("GET", "api/timesheets", query: q)
            all += try decode([KimaiTimesheet].self, data)
            let pages = Int(response.value(forHTTPHeaderField: "X-Total-Pages") ?? "") ?? 1
            if page >= pages { return all }
            page += 1
        }
    }

    // MARK: Writes

    /// Start a running entry (`end == nil`) or book a finished one.
    public func create(_ new: NewTimesheet) async throws -> KimaiTimesheet {
        var body: [String: Any] = ["project": new.project, "activity": new.activity]
        if let begin = new.begin { body["begin"] = KimaiDate.formatWithOffset(begin, in: timeZone) }
        if let end = new.end { body["end"] = KimaiDate.formatWithOffset(end, in: timeZone) }
        if let d = new.description, !d.isEmpty { body["description"] = d }
        if !new.tags.isEmpty { body["tags"] = new.tags.joined(separator: ",") }
        if let user = new.user { body["user"] = user }
        if let billable = new.billable { body["billable"] = billable }
        let (data, _) = try await send("POST", "api/timesheets", query: [.init(name: "full", value: "true")], json: body)
        return try decode(KimaiTimesheet.self, data)
    }

    /// Stop now (server clock), or at `end` when given (e.g. when the user went idle).
    public func stop(id: Int, at end: Date? = nil) async throws -> KimaiTimesheet {
        if let end {
            return try await patch(id: id, ["end": KimaiDate.formatWithOffset(end, in: timeZone)])
        }
        let (data, _) = try await send("PATCH", "api/timesheets/\(id)/stop")
        return try decode(KimaiTimesheet.self, data)
    }

    public func setDescription(id: Int, _ description: String) async throws -> KimaiTimesheet {
        try await patch(id: id, ["description": description])
    }

    public func patch(id: Int, _ fields: [String: Any]) async throws -> KimaiTimesheet {
        let (data, _) = try await send("PATCH", "api/timesheets/\(id)", json: fields)
        return try decode(KimaiTimesheet.self, data)
    }

    /// Makes sure the tag `name` exists. Kimai's timesheet API drops tag names it doesn't
    /// know without a word (TagsInputType, allow_create off), so a booking would lose it.
    /// Checked once per server and tag per process.
    public func ensureTag(_ name: String) async throws {
        let key = "\(connection.url.absoluteString) \(name)"
        guard !Self.ensuredTags.withLock({ $0.contains(key) }) else { return }
        // A substring search over visible tags.
        let found: [KimaiTag] = try await get("api/tags/find", [.init(name: "name", value: name)])
        if !found.contains(where: { $0.name == name }) {
            do {
                _ = try await send("POST", "api/tags", json: ["name": name])
            } catch KimaiError.http(status: 400, _) {
                // Already there: hidden (find lists visible tags only), or another agent was
                // quicker. A booking that loses the tag anyway is caught by the caller's check.
            } catch KimaiError.http(status: 403, _) {
                throw KimaiError.http(status: 403, message: "this API token may not create the tag \(name). Create it in Kimai under Tags, or give the token's user the create_tag permission.")
            }
        }
        Self.ensuredTags.withLock { _ = $0.insert(key) }
    }

    /// Tags `ensureTag` already found or created, as "<server> <tag>".
    static let ensuredTags = Mutex<Set<String>>([])

    /// Makes the next `ensureTag(name)` ask Kimai again.
    func forgetTag(_ name: String) {
        Self.ensuredTags.withLock { _ = $0.remove("\(connection.url.absoluteString) \(name)") }
    }

    // MARK: Plumbing

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await send("GET", path, query: query)
        return try decode(T.self, data)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try KimaiDate.decoder.decode(T.self, from: data) } catch {
            throw KimaiError.decoding(Self.describe(error, data))
        }
    }

    /// One readable line instead of a DecodingError dump.
    static func describe(_ error: Error, _ data: Data) -> String {
        // Captive portals, SSO proxies, a URL that isn't Kimai: an HTML page with status 200.
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == UInt8(ascii: "<") {
            return "the server sent a web page instead of Kimai's API answer. Check the server address, and whether a login page or proxy sits in front of Kimai."
        }
        let context: DecodingError.Context? = switch error as? DecodingError {
        case let .keyNotFound(_, c)?, let .typeMismatch(_, c)?, let .valueNotFound(_, c)?, let .dataCorrupted(c)?: c
        default: nil
        }
        guard let context else { return error.localizedDescription }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(context.debugDescription) (at \(path))"
    }

    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        // Also covers connections saved by older builds, which accepted any http URL.
        guard KimaiConnection.isAllowed(connection.url) else {
            throw KimaiError.transport(KimaiConnection.URLProblem.notHTTPS.localizedDescription)
        }
        var components = URLComponents(url: connection.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw KimaiError.transport("bad URL") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw KimaiError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw KimaiError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw KimaiError.http(status: http.statusCode, message: Self.errorMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return (data, http)
    }

    /// Kimai errors look like {"code":400,"message":"Validation Failed","errors":{"children":{"end":{"errors":["…"]}}}}.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var details: [String] = []
        func walk(_ node: Any, field: String?) {
            if let dict = node as? [String: Any] {
                for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                    walk(value, field: key == "errors" || key == "children" ? field : key)
                }
            } else if let list = node as? [Any] {
                for item in list {
                    if let s = item as? String { details.append(field.map { "\($0): \(s)" } ?? s) } else { walk(item, field: field) }
                }
            }
        }
        if let errors = object["errors"] { walk(errors, field: nil) }
        let message = object["message"] as? String
        let joined = ([message].compactMap { $0 } + details).joined(separator: " — ")
        return joined.isEmpty ? nil : joined
    }
}
