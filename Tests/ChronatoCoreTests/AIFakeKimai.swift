import Foundation
import Synchronization
@testable import ChronatoCore

/// A canned Kimai for the AI-agent tests. Each instance answers on its own
/// fictional host, so parallel tests never see each other's requests.
/// The user's time zone is Pacific/Kiritimati (+14:00, no DST) so formatting in
/// the Kimai time zone is visibly different from the test machine's.
final class AIFakeKimai: Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data?

        var json: [String: Any] { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
    }

    struct State {
        var requests: [Request] = []
        var postStatus = 200
        var postDelay: TimeInterval = 0
        /// Tags Kimai has. Like Kimai's API form, a booking keeps only these.
        var tags: Set<String> = ["ai-claude-code"]
        /// POST /api/tags answers this (200 = creates the tag).
        var tagStatus = 200
        /// Booked entries, as Kimai's JSON, for GET /api/timesheets.
        var entries: [Data] = []
    }

    static let registry = Mutex<[String: AIFakeKimai]>([:])
    static let timeZone = TimeZone(identifier: "Pacific/Kiritimati")!

    let host = "kimai-\(UUID().uuidString.prefix(8).lowercased()).example.net"
    private let state = Mutex(State())

    init() {
        Self.registry.withLock { $0[host] = self }
    }

    var connection: KimaiConnection { KimaiConnection(url: URL(string: "https://\(host)")!, token: "test-token") }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIFakeKimaiProtocol.self]
        return URLSession(configuration: configuration)
    }

    var client: KimaiClient { KimaiClient(connection: connection, timeZone: Self.timeZone, session: session) }
    var requests: [Request] { state.withLock { $0.requests } }
    /// Bodies of POST /api/timesheets.
    var posts: [[String: Any]] { requests.filter { $0.method == "POST" && $0.path == "/api/timesheets" }.map(\.json) }
    var tags: Set<String> { state.withLock { $0.tags } }

    /// Make POST /api/timesheets fail with this status (200 = succeed).
    func setPostStatus(_ status: Int) { state.withLock { $0.postStatus = status } }
    /// Answer POST /api/timesheets only after this many seconds (a booking in flight).
    func setPostDelay(_ seconds: TimeInterval) { state.withLock { $0.postDelay = seconds } }
    func setTags(_ tags: Set<String>) { state.withLock { $0.tags = tags } }
    func setTagStatus(_ status: Int) { state.withLock { $0.tagStatus = status } }

    func respond(to request: URLRequest) -> (Int, String) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = Self.body(of: request)
        let current = state.withLock {
            $0.requests.append(Request(method: method, path: path, body: body))
            return $0
        }
        switch (method, path) {
        case ("GET", "/api/users/me"):
            return (200, #"{"id":1,"username":"admin","timezone":"Pacific/Kiritimati","language":"en"}"#)
        case ("GET", "/api/customers"):
            return (200, #"[{"id":10,"name":"Northwind Traders"},{"id":12,"name":"In-house"}]"#)
        case ("GET", "/api/projects"):
            return (200, #"[{"id":12,"name":"Ops Dashboard","customer":10,"globalActivities":true},{"id":13,"name":"Internal","customer":12,"globalActivities":false}]"#)
        case ("GET", "/api/activities"):
            return (200, #"[{"id":3,"name":"Automation","project":12},{"id":18,"name":"Internal work","project":13},{"id":21,"name":"Development","project":null}]"#)
        case ("GET", "/api/tags/find"):
            // A substring search, like Kimai's.
            let name = query.first { $0.name == "name" }?.value ?? ""
            return (200, Self.json(current.tags.filter { $0.contains(name) }.sorted().enumerated().map { ["id": $0.offset + 1, "name": $0.element] }))
        case ("POST", "/api/tags"):
            guard current.tagStatus == 200 else { return (current.tagStatus, #"{"code":403,"message":"Access denied."}"#) }
            let name = Request(method: method, path: path, body: body).json["name"] as? String ?? ""
            guard !current.tags.contains(name) else {
                return (400, #"{"code":400,"message":"Validation Failed","errors":{"children":{"name":{"errors":["This value is already used."]}}}}"#)
            }
            state.withLock { _ = $0.tags.insert(name) }
            return (200, Self.json(["id": 99, "name": name]))
        case ("GET", "/api/timesheets"):
            return (200, "[" + current.entries.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]")
        case ("POST", "/api/timesheets"):
            Thread.sleep(forTimeInterval: current.postDelay)
            guard current.postStatus == 200 else {
                return (current.postStatus, #"{"code":400,"message":"Validation Failed","errors":{"children":{"project":{"errors":["Invalid project."]}}}}"#)
            }
            // Echo the entry the way Kimai does: dates with the user's offset, a computed duration,
            // and only the tags Kimai already has (it drops unknown ones without a word).
            let json = Request(method: method, path: path, body: body).json
            let begin = KimaiDate.parse(json["begin"] as? String ?? "") ?? .now, end = KimaiDate.parse(json["end"] as? String ?? "") ?? .now
            let entry: [String: Any] = [
                "id": 500 + requests.count,
                "begin": KimaiDate.formatWithOffset(begin, in: Self.timeZone), "end": KimaiDate.formatWithOffset(end, in: Self.timeZone),
                "duration": Int(end.timeIntervalSince(begin)),
                "tags": (json["tags"] as? String)?.split(separator: ",").map(String.init).filter(current.tags.contains) ?? [],
                "user": json["user"] ?? 1, "project": json["project"] ?? 0, "activity": json["activity"] ?? 0,
                "description": json["description"] ?? NSNull(),
            ]
            let text = Self.json(entry)
            state.withLock { $0.entries.append(Data(text.utf8)) }
            return (200, text)
        default:
            return (404, #"{"code":404,"message":"Not Found"}"#)
        }
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// URLSession moves a request's body into a stream before URLProtocol sees it.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// A fresh, empty directory for session files.
    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chronato-ai-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

final class AIFakeKimaiProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fake = AIFakeKimai.registry.withLock { $0[request.url?.host ?? ""] }
        let (status, body) = fake?.respond(to: request) ?? (599, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
