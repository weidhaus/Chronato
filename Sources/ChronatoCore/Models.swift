import Foundation

// Kimai 2.x API shapes, trimmed to the fields Chronato uses.
// Collections return parents as plain ids ("customer": 12); `full=true`
// timesheets return nested objects. Timesheet decoding accepts both.

public struct KimaiVersion: Decodable, Sendable, Hashable {
    public let version: String
}

public struct KimaiUser: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let username: String
    public let alias: String?
    public let timezone: String?
    /// UI language ("de", "en"); Kimai web routes are prefixed with it.
    public let language: String?
    /// Kimai preferences (`first_weekday`, `hourly_rate`, …). Only `/users/me` and
    /// `/users/{id}` include them.
    public let preferences: [Preference]?
    /// A Kimai system account (for bots, cannot log in). Kimai's timesheet form refuses to
    /// book for one (UserRepository::getQueryBuilderForFormType skips them).
    public let systemAccount: Bool?

    public struct Preference: Codable, Sendable, Hashable {
        public let name: String
        public let value: String?
    }

    public init(id: Int, username: String, alias: String? = nil, timezone: String? = nil, language: String? = nil, preferences: [Preference]? = nil, systemAccount: Bool? = nil) {
        self.id = id
        self.username = username
        self.alias = alias
        self.timezone = timezone
        self.language = language
        self.preferences = preferences
        self.systemAccount = systemAccount
    }

    public var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        return username
    }

    public func preference(_ name: String) -> String? {
        preferences?.first { $0.name == name }?.value
    }

    /// Monday unless the user's Kimai profile says Sunday.
    public var firstWeekday: Int { preference("first_weekday") == "sunday" ? 1 : 2 }
}

/// GET /api/tags/find answers with these (POST /api/tags with one).
public struct KimaiTag: Decodable, Sendable, Hashable {
    public let name: String
}

public struct KimaiCustomer: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let visible: Bool?
    public let currency: String?
    public let color: String?

    enum CodingKeys: String, CodingKey {
        case id, name, visible, currency
        case color = "color-safe"
    }

    public init(id: Int, name: String, visible: Bool? = true, currency: String? = "EUR", color: String? = nil) {
        self.id = id
        self.name = name
        self.visible = visible
        self.currency = currency
        self.color = color
    }
}

public struct KimaiProject: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let customer: Int
    public let visible: Bool?
    public let billable: Bool?
    public let globalActivities: Bool?
    public let color: String?

    enum CodingKeys: String, CodingKey {
        case id, name, customer, visible, billable, globalActivities
        case color = "color-safe"
    }

    public init(id: Int, name: String, customer: Int, visible: Bool? = true, billable: Bool? = true, globalActivities: Bool? = true, color: String? = nil) {
        self.id = id
        self.name = name
        self.customer = customer
        self.visible = visible
        self.billable = billable
        self.globalActivities = globalActivities
        self.color = color
    }
}

public struct KimaiActivity: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    /// nil = global activity, usable in any project that allows global activities.
    public let project: Int?
    public let visible: Bool?
    public let color: String?

    enum CodingKeys: String, CodingKey {
        case id, name, project, visible
        case color = "color-safe"
    }

    public init(id: Int, name: String, project: Int?, visible: Bool? = true, color: String? = nil) {
        self.id = id
        self.name = name
        self.project = project
        self.visible = visible
        self.color = color
    }
}

public struct KimaiTimesheet: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let begin: Date
    public let end: Date?
    /// Seconds, as Kimai computed it (end - begin - break). 0 or nil while running.
    public let duration: Int?
    public let breakSeconds: Int?
    public let description: String?
    public let tags: [String]
    public let billable: Bool?
    public let rate: Double?
    public let userId: Int?
    public let projectId: Int
    public let projectName: String?
    public let customerId: Int?
    public let customerName: String?
    public let activityId: Int
    public let activityName: String?

    public init(
        id: Int, begin: Date, end: Date?, duration: Int? = nil, breakSeconds: Int? = 0,
        description: String? = nil, tags: [String] = [], billable: Bool? = true, rate: Double? = 0,
        userId: Int? = nil, projectId: Int, projectName: String? = nil, customerId: Int? = nil,
        customerName: String? = nil, activityId: Int, activityName: String? = nil
    ) {
        self.id = id
        self.begin = begin
        self.end = end
        self.duration = duration
        self.breakSeconds = breakSeconds
        self.description = description
        self.tags = tags
        self.billable = billable
        self.rate = rate
        self.userId = userId
        self.projectId = projectId
        self.projectName = projectName
        self.customerId = customerId
        self.customerName = customerName
        self.activityId = activityId
        self.activityName = activityName
    }

    public var isRunning: Bool { end == nil }

    /// Worked seconds. A running entry counts up to `now`.
    public func seconds(now: Date = .now) -> Int {
        let pause = breakSeconds ?? 0
        guard let end else { return max(0, Int(now.timeIntervalSince(begin)) - pause) }
        if let duration, duration > 0 { return duration }
        return max(0, Int(end.timeIntervalSince(begin)) - pause)
    }

    /// Tags Chronato uses to mark AI work: `ai-<agent>`.
    public var aiAgentTag: String? { tags.first { $0.hasPrefix("ai-") } }

    enum CodingKeys: String, CodingKey {
        case id, begin, end, duration, description, tags, billable, rate, user, project, activity
        case breakSeconds = "break"
    }

    /// A related record: either a bare id or an object with at least an id.
    private struct Leaf: Decodable {
        let id: Int
        let name: String?
        enum CodingKeys: String, CodingKey { case id, name }
        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let id = try? single.decode(Int.self) {
                self.id = id
                name = nil
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
        }
    }

    /// A project: a bare id, or an object whose `customer` is itself a Leaf.
    private struct Ref: Decodable {
        let id: Int
        let name: String?
        let customer: Leaf?
        enum CodingKeys: String, CodingKey { case id, name, customer }
        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let id = try? single.decode(Int.self) {
                self.id = id
                name = nil
                customer = nil
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            customer = try? c.decodeIfPresent(Leaf.self, forKey: .customer)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        begin = try c.decode(Date.self, forKey: .begin)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        breakSeconds = try c.decodeIfPresent(Int.self, forKey: .breakSeconds)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        billable = try c.decodeIfPresent(Bool.self, forKey: .billable)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate)
        userId = (try? c.decodeIfPresent(Leaf.self, forKey: .user))?.id
        let project = try c.decode(Ref.self, forKey: .project)
        projectId = project.id
        projectName = project.name
        customerId = project.customer?.id
        customerName = project.customer?.name
        let activity = try c.decode(Leaf.self, forKey: .activity)
        activityId = activity.id
        activityName = activity.name
    }
}

/// Body for POST /api/timesheets. KimaiClient turns it into JSON (dates need
/// the Kimai user's time zone, so they cannot be encoded on their own).
public struct NewTimesheet: Sendable, Equatable {
    public var project: Int
    public var activity: Int
    /// nil = now (server clock).
    public var begin: Date?
    /// nil = the entry keeps running.
    public var end: Date?
    public var description: String?
    public var tags: [String]
    /// Book for another Kimai user (the token's user needs `create_other_timesheet`, and the
    /// user must not be a system account). nil = the token's user.
    public var user: Int?
    public var billable: Bool?

    public init(project: Int, activity: Int, begin: Date? = nil, end: Date? = nil, description: String? = nil, tags: [String] = [], user: Int? = nil, billable: Bool? = nil) {
        self.project = project
        self.activity = activity
        self.begin = begin
        self.end = end
        self.description = description
        self.tags = tags
        self.user = user
        self.billable = billable
    }
}
