import ChronatoCore
import SwiftUI

/// What New Timer opens with: the last choice, or a recent entry to change before starting.
struct StartChoice: Identifiable {
    let id = UUID()
    var customerId: Int?
    var projectId: Int?
    var activityId: Int?
    var note = ""

    /// The last started combination (PhoneTracker.start remembers it, as the Mac
    /// does), else the newest entry in Kimai: a fresh install starts where the Mac left off.
    @MainActor static func remembered(_ tracker: PhoneTracker) -> StartChoice {
        let defaults = UserDefaults.standard
        if let project = defaults.object(forKey: Prefs.lastProjectId) as? Int {
            return StartChoice(customerId: defaults.object(forKey: Prefs.lastCustomerId) as? Int, projectId: project,
                               activityId: defaults.object(forKey: Prefs.lastActivityId) as? Int)
        }
        guard let entry = tracker.recent.first else { return StartChoice() }
        return StartChoice(customerId: entry.customerId ?? tracker.project(entry.projectId)?.customer,
                           projectId: entry.projectId, activityId: entry.activityId)
    }
}

/// New Timer… (spec §5): the Mac's New Timer panel as a sheet. Every startable
/// Customer › Project › Activity in one searchable list, a note, Start (Switch
/// while a timer runs). The sheet closes once Kimai started the timer and
/// stays open with the reason when it did not.
struct NewTimerSheet: View {
    @Environment(PhoneTracker.self) private var tracker
    @Environment(\.dismiss) private var dismiss
    let choice: StartChoice
    @State private var query = ""
    @State private var selected: String?
    @State private var note: String
    @State private var starting = false
    @State private var failure: String?

    init(choice: StartChoice) {
        self.choice = choice
        _note = State(initialValue: choice.note)
        _selected = State(initialValue: choice.projectId.flatMap { p in choice.activityId.map { Combination.id(p, $0) } })
    }

    struct Combination: Identifiable {
        let id: String
        let customerId: Int
        let projectId: Int
        let activityId: Int
        let customer: String
        let project: String
        let activity: String
        let color: String?

        static func id(_ project: Int, _ activity: Int) -> String { "\(project)-\(activity)" }
    }

    /// The opening choice first, then the combinations of Recent customers in
    /// recency order, then the rest by customer, project and activity name.
    private var combinations: [Combination] {
        let recentCustomers = tracker.recent.compactMap { $0.customerId ?? tracker.project($0.projectId)?.customer }
        let chosen = choice.projectId.flatMap { p in choice.activityId.map { Combination.id(p, $0) } }
        let all = tracker.projects.flatMap { project in
            let customer = tracker.customer(project.customer)
            return tracker.activities(forProject: project.id).map { activity in
                Combination(id: Combination.id(project.id, activity.id), customerId: project.customer, projectId: project.id,
                            activityId: activity.id, customer: customer?.name ?? "", project: project.name,
                            activity: activity.name, color: customer?.color)
            }
        }
        func rank(_ c: Combination) -> Int {
            c.id == chosen ? 0 : 1 + (recentCustomers.firstIndex(of: c.customerId) ?? recentCustomers.count)
        }
        return all.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            for (x, y) in [(a.customer, b.customer), (a.project, b.project), (a.activity, b.activity)] where x != y {
                return x.localizedStandardCompare(y) == .orderedAscending
            }
            return false
        }
    }

    /// Every word must appear in the customer, project or activity name ("nor auto").
    private func matches(_ all: [Combination]) -> [Combination] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return all }
        return all.filter { c in terms.allSatisfy { "\(c.customer) \(c.project) \(c.activity)".localizedStandardContains($0) } }
    }

    var body: some View {
        let all = combinations
        let shown = matches(all)
        // The chosen row while it matches the search, else the first match.
        let current = shown.first { $0.id == selected } ?? shown.first
        NavigationStack {
            List {
                Section {
                    TextField("Note (optional)", text: $note)
                        .submitLabel(.go)
                        .onSubmit { start(current) }
                } footer: {
                    if tracker.isRunning {
                        Text("Stops the running timer and starts this one.").foregroundStyle(Studio.textSecondary)
                    } else if tracker.paused != nil {
                        Text("Starts this one instead of resuming the paused timer.").foregroundStyle(Studio.textSecondary)
                    }
                }
                if let failure {
                    Section { Problem(failure) }
                } else if case .offline = tracker.connectionState {
                    Section { Problem("Kimai is not reachable", isError: false) }
                }
                Section {
                    if all.isEmpty {
                        Text("No project with an activity is visible to this Kimai user.").foregroundStyle(Studio.textSecondary)
                    } else if shown.isEmpty {
                        Text("No match for “\(query)”").foregroundStyle(Studio.textSecondary)
                    }
                    ForEach(shown) { row($0, isSelected: $0.id == current?.id) }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search customers, projects and activities")
            .navigationTitle("New Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button(tracker.isRunning ? "Switch" : "Start") { start(current) }
                            .disabled(current == nil || !tracker.canAct)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selected)
        }
    }

    private func row(_ c: Combination, isSelected: Bool) -> some View {
        Button {
            selected = c.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Studio.Space.s) {
                Dot(hex: c.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.activity).foregroundStyle(Studio.textPrimary)
                    Text("\(c.customer) › \(c.project)").font(.subheadline).foregroundStyle(Studio.textSecondary)
                }
                Spacer(minLength: Studio.Space.s)
                if isSelected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func start(_ c: Combination?) {
        guard let c, tracker.canAct, !starting else { return }
        starting = true
        failure = nil
        tracker.lastError = nil
        Task {
            await tracker.start(projectId: c.projectId, activityId: c.activityId, description: note)
            starting = false
            if let error = tracker.lastError {
                failure = error
                tracker.lastError = nil
            } else {
                dismiss()
            }
        }
    }
}
