import Foundation
import Testing
@testable import ChronatoCore

@Test func decodesFullAndFlatTimesheets() throws {
    let full = #"[{"id":95,"begin":"2026-10-06T20:50:00+0200","end":"2026-10-06T22:24:00+0200","duration":5640,"break":0,"tags":["ai-ravi"],"user":{"id":2,"username":"Claude"},"project":{"id":12,"name":"Ops","customer":{"id":10,"name":"Northwind"}},"activity":{"id":3,"name":"Automation","project":null},"description":null,"rate":12.5,"billable":true}]"#
    let flat = #"[{"id":96,"begin":"2026-10-08T09:00:00+0200","end":null,"duration":0,"tags":[],"user":1,"project":12,"activity":3,"description":"x"}]"#
    let a = try KimaiDate.decoder.decode([KimaiTimesheet].self, from: Data(full.utf8))[0]
    #expect(a.customerName == "Northwind" && a.customerId == 10 && a.projectName == "Ops" && a.activityName == "Automation")
    #expect(a.userId == 2 && a.seconds() == 5640 && a.aiAgentTag == "ai-ravi")
    let b = try KimaiDate.decoder.decode([KimaiTimesheet].self, from: Data(flat.utf8))[0]
    #expect(b.isRunning && b.projectId == 12 && b.customerId == nil && b.userId == 1)
    #expect(b.seconds(now: b.begin.addingTimeInterval(90)) == 90)
}

@Test func formatsDatesInKimaiTimeZone() {
    let date = KimaiDate.parse("2026-10-08T12:00:00+0000")!
    #expect(KimaiDate.format(date, in: TimeZone(identifier: "Europe/Berlin")!) == "2026-10-08T14:00:00")
    #expect(KimaiDate.formatWithOffset(date, in: TimeZone(identifier: "Europe/Berlin")!) == "2026-10-08T14:00:00+02:00")
    #expect(KimaiDate.parse(KimaiDate.formatWithOffset(date, in: TimeZone(identifier: "Pacific/Kiritimati")!)) == date)
}

@Test func normalizesServerURLs() throws {
    #expect(KimaiConnection.normalizedURL("kimai.example.net/")?.absoluteString == "https://kimai.example.net")
    #expect(KimaiConnection.normalizedURL("https://host:8443/kimai")?.absoluteString == "https://host:8443/kimai")
    #expect(KimaiConnection.normalizedURL("ftp://x") == nil)
    #expect(KimaiConnection.normalizedURL("  ") == nil)
    // The token must not cross a network in clear text; only this Mac may be plain http.
    for insecure in ["http://host:8001/kimai", "http://192.168.1.20:8001", "http://kimai.local", "HTTP://kimai.example.net"] {
        #expect(throws: KimaiConnection.URLProblem.notHTTPS) { try KimaiConnection.validatedURL(insecure) }
    }
    for local in ["http://localhost:8001", "http://127.0.0.1:8765/", "http://[::1]:8001"] {
        #expect(KimaiConnection.normalizedURL(local) != nil, "\(local)")
    }
    #expect(throws: KimaiConnection.URLProblem.invalid) { try KimaiConnection.validatedURL("ftp://x") }
}

@Test func refusesPlainHTTPEvenForAnOlderSavedConnection() async {
    let client = KimaiClient(connection: KimaiConnection(url: URL(string: "http://kimai.example.net")!, token: "t"))
    await #expect(throws: KimaiError.transport(KimaiConnection.URLProblem.notHTTPS.localizedDescription)) { try await client.me() }
}

@Test func kimaiTrafficIsNeverCachedOnDisk() {
    #expect(KimaiClient(connection: KimaiConnection(url: URL(string: "https://kimai.example.net")!, token: "t")).session === KimaiClient.defaultSession)
    #expect(KimaiClient.defaultSession.configuration.urlCache?.diskCapacity ?? 0 == 0)
    #expect(KimaiClient.defaultSession.configuration.httpCookieStorage == nil || KimaiClient.defaultSession.configuration.httpCookieStorage !== HTTPCookieStorage.shared)
}

@Test func explainsAnswersThatAreNotKimaiJSON() {
    struct Probe: Decodable { let id: Int }
    let client = KimaiClient(connection: KimaiConnection(url: URL(string: "https://kimai.example.net")!, token: "t"))
    let portal = Data("\n  <!DOCTYPE html><html><body>Hotel Wi-Fi login</body></html>".utf8)
    #expect(throws: KimaiError.decoding("the server sent a web page instead of Kimai's API answer. Check the server address, and whether a login page or proxy sits in front of Kimai.")) {
        try client.decode(Probe.self, portal)
    }
    let missing = #expect(throws: KimaiError.self) { try client.decode([Probe].self, Data(#"[{"name":"x"}]"#.utf8)) }
    let text = missing?.localizedDescription ?? ""
    #expect(!text.contains("\n") && text.contains("(at 0)") && text.count < 200, "\(text)")
}

@Test func flattensKimaiValidationErrors() {
    let body = #"{"code":400,"message":"Validation Failed","errors":{"children":{"end":{"errors":["End date must not be earlier then start date."]},"project":{}}}}"#
    #expect(KimaiClient.errorMessage(Data(body.utf8)) == "Validation Failed — end: End date must not be earlier then start date.")
}

@Test func agentAllowlist() throws {
    var config = AIConfig()
    let (agent, token) = try config.addAgent(named: "Claude Code")
    #expect(agent.name == "claude-code" && agent.tag == "ai-claude-code")
    #expect(config.authenticate(name: "claude-code", token: token) != nil)
    #expect(config.authenticate(name: "claude-code", token: token + "x") == nil)
    #expect(throws: AIAgentError.duplicate("claude-code")) { try config.addAgent(named: "claude code") }
    config.agents[0].enabled = false
    #expect(config.authenticate(name: "claude-code", token: token) == nil)
}
