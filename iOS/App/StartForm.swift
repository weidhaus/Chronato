import ChronatoCore
import SwiftUI

/// What the start form opens with: the last choice, or a recent entry to change before starting.
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

/// Customer → Project → Activity, a note, Start. Rows for a List section.
/// A customer with one project (a project with one activity) picks it.
/// The choice is remembered only once a timer starts, so browsing or a
/// cancelled sheet does not change what the form offers next time.
struct StartForm: View {
    @Environment(PhoneTracker.self) private var tracker
    @State private var customerId: Int?
    @State private var projectId: Int?
    @State private var activityId: Int?
    @State private var note: String
    /// Called once the start is sent (the sheet closes then).
    var onStart: () -> Void = {}

    init(choice: StartChoice, onStart: @escaping () -> Void = {}) {
        _customerId = State(initialValue: choice.customerId)
        _projectId = State(initialValue: choice.projectId)
        _activityId = State(initialValue: choice.activityId)
        _note = State(initialValue: choice.note)
        self.onStart = onStart
    }

    private var customers: [KimaiCustomer] {
        tracker.customers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var projects: [KimaiProject] { tracker.customer(customerId).map { tracker.projects(forCustomer: $0.id) } ?? [] }
    /// The chosen project if it belongs to the customer, else the customer's only one.
    private var selectedProject: Int? {
        if let projectId, projects.contains(where: { $0.id == projectId }) { return projectId }
        return projects.count == 1 ? projects[0].id : nil
    }
    private var activities: [KimaiActivity] { selectedProject.map { tracker.activities(forProject: $0) } ?? [] }
    private var selectedActivity: Int? {
        if activities.contains(where: { $0.id == activityId }) { return activityId }
        return activities.count == 1 ? activities[0].id : nil
    }
    private var switching: Bool { tracker.isRunning || tracker.paused != nil }

    var body: some View {
        picker("Customer", selected: tracker.customer(customerId).map { ($0.name, $0.color) }, selection: $customerId,
               items: customers.map { .init(id: $0.id, name: $0.name, color: $0.color) })
        picker("Project", selected: tracker.project(selectedProject).map { ($0.name, $0.color) },
               selection: Binding(get: { selectedProject }, set: { projectId = $0 }),
               items: projects.map { .init(id: $0.id, name: $0.name, color: $0.color) })
        picker("Activity", selected: tracker.activity(selectedActivity).map { ($0.name, $0.color) },
               selection: Binding(get: { selectedActivity }, set: { activityId = $0 }),
               items: activities.map { .init(id: $0.id, name: $0.name, color: $0.color) })
        TextField("Note (optional)", text: $note)
            .submitLabel(.go)
            .onSubmit(start)
        Button(action: start) {
            HStack(spacing: 8) {
                // Not a Label: in a List row its icon takes the accent and vanishes on the filled button.
                Image(systemName: "play.fill").accessibilityHidden(true)
                Text(switching ? "Switch" : "Start")
            }
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .listRowSeparator(.hidden)
        .disabled(selectedProject == nil || selectedActivity == nil || tracker.isBusy)
    }

    private func picker(_ title: String, selected: (name: String, color: String?)?, selection: Binding<Int?>, items: [SearchPicker.Item]) -> some View {
        NavigationLink {
            SearchPicker(title: title, items: items, selection: selection)
        } label: {
            LabeledContent {
                if let selected {
                    HStack(spacing: 6) {
                        Dot(hex: selected.color)
                        Text(selected.name).lineLimit(1)
                    }
                } else {
                    Text(items.isEmpty ? "–" : "Choose").foregroundStyle(.tertiary)
                }
            } label: {
                Text(title)
            }
        }
        .disabled(items.isEmpty)
        .accessibilityValue(selected?.name ?? "not chosen")
    }

    private func start() {
        guard let project = selectedProject, let activity = selectedActivity, !tracker.isBusy else { return }
        let text = note
        note = ""
        onStart()
        Task { await tracker.start(projectId: project, activityId: activity, description: text) }
    }
}

/// The start form as a sheet: "Switch to…" while a timer runs or is paused,
/// and "Change and start" on a recent entry.
struct StartSheet: View {
    let choice: StartChoice
    @Environment(PhoneTracker.self) private var tracker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StartForm(choice: choice) { dismiss() }
                } footer: {
                    if tracker.isRunning {
                        Text("Stops the running timer and starts this one.")
                    } else if tracker.paused != nil {
                        Text("Starts this one instead of resuming the paused timer.")
                    }
                }
            }
            .navigationTitle(tracker.isRunning || tracker.paused != nil ? "Switch to" : "New Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A searchable list that picks one item and goes back; Kimai lists of
/// customers and activities get long.
struct SearchPicker: View {
    struct Item: Identifiable {
        let id: Int
        let name: String
        let color: String?
    }

    let title: String
    let items: [Item]
    @Binding var selection: Int?
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [Item] {
        query.isEmpty ? items : items.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        List(filtered) { item in
            Button {
                selection = item.id
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Dot(hex: item.color)
                    Text(item.name)
                    Spacer()
                    if item.id == selection {
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Brand.accent).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityAddTraits(item.id == selection ? .isSelected : [])
        }
        .overlay {
            if filtered.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .sensoryFeedback(.selection, trigger: selection)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
