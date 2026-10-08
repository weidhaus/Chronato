import Foundation
import Testing
@testable import ChronatoCore

/// Read-only smoke test against a real Kimai. Runs only when both variables
/// are set; never writes. CHRONATO_LIVE_URL=https://… CHRONATO_LIVE_TOKEN=… swift test
@Test(.enabled(if: ProcessInfo.processInfo.environment["CHRONATO_LIVE_TOKEN"] != nil && ProcessInfo.processInfo.environment["CHRONATO_LIVE_URL"] != nil))
func liveReadOnlyDecode() async throws {
    let env = ProcessInfo.processInfo.environment
    let url = try #require(KimaiConnection.normalizedURL(env["CHRONATO_LIVE_URL"] ?? ""))
    var client = KimaiClient(connection: KimaiConnection(url: url, token: env["CHRONATO_LIVE_TOKEN"]!))
    let me = try await client.me()
    client.timeZone = TimeZone(identifier: me.timezone ?? "") ?? .current
    _ = try await client.version()
    let customers = try await client.customers()
    let projects = try await client.projects()
    let activities = try await client.activities()
    let users = try await client.users()
    _ = try await client.activeTimesheets()
    let recent = try await client.recentTimesheets(size: 10)
    let all = try await client.timesheets(user: "all", begin: Date().addingTimeInterval(-120 * 86400), end: Date())
    #expect(!customers.isEmpty && !projects.isEmpty && !activities.isEmpty && !users.isEmpty)
    #expect(recent.allSatisfy { $0.customerName != nil && $0.activityName != nil })
    #expect(all.allSatisfy { $0.customerId != nil })
    print("live: \(customers.count) customers, \(projects.count) projects, \(activities.count) activities, \(users.count) users, \(all.count) entries/120d, first weekday \(me.firstWeekday)")
}
