import AppKit
import ChronatoCore
import SwiftUI

/// Every startable customer › project › activity in one searchable list, for
/// what is not in Recent (design/chronato-interaction-spec.md §6). Keyboard
/// first: type, ↑/↓, Return. A failed start keeps query, selection and note.
@MainActor
final class NewTimerPanel: NSObject, NSWindowDelegate {
    private let store: TrackerStore
    private var panel: NSPanel?
    private var model: NewTimerModel?

    init(store: TrackerStore) {
        self.store = store
    }

    func show(below anchor: NSRect?) {
        if let panel, model != nil {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let defaults = UserDefaults.standard
        let model = NewTimerModel(store, last: (defaults.integer(forKey: Prefs.lastProjectId), defaults.integer(forKey: Prefs.lastActivityId)))
        self.model = model
        let host = NSHostingController(rootView: NewTimerForm(model: model, start: { [weak self] in self?.start() },
                                                              cancel: { [weak self] in self?.close() }).environment(store))
        host.sizingOptions = [.minSize] // resizable: the user's size, never below the content's minimum
        if let panel {
            // A new form in the same frame (its size is the user's).
            let frame = panel.frame
            panel.contentViewController = host
            panel.setFrame(frame, display: false)
        } else {
            let panel = FloatingPanel.make(title: "New Timer", resizable: true)
            panel.delegate = self
            panel.contentViewController = host
            panel.setContentSize(NSSize(width: 440, height: 400))
            panel.contentMinSize = NSSize(width: 400, height: 320)
            panel.setFrameUsingName("NewTimer")
            panel.setFrameAutosaveName("NewTimer")
            self.panel = panel
        }
        guard let panel else { return }
        FloatingPanel.place(panel, below: anchor)
        panel.makeKeyAndOrderFront(nil)
    }

    private func start() {
        guard let model, let combo = model.current, !model.starting, store.connectionState == .online, !store.isBusy else { return }
        model.starting = true
        model.error = nil
        let note = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let error = await store.start(projectId: combo.project.id, activityId: combo.activity.id, description: note.isEmpty ? nil : note)
            model.starting = false
            guard let error else { return close() }
            model.error = error.localizedDescription
            if store.lastError == model.error { store.lastError = nil } // shown here, not again in the menu
        }
    }

    private func close() {
        model = nil
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
    }
}

/// One startable customer › project › activity.
struct Combo: Identifiable {
    let customer: KimaiCustomer
    let project: KimaiProject
    let activity: KimaiActivity

    var id: String { "\(project.id)/\(activity.id)" }
}

@MainActor @Observable
final class NewTimerModel {
    /// The last choice first, then Recent's customers (newest first), then the
    /// rest, each by project and activity name.
    let combos: [Combo]
    var query = ""
    var note = ""
    /// nil: the first result.
    var selection: Combo.ID?
    var error: String?
    var starting = false

    init(_ store: TrackerStore, last: (project: Int, activity: Int)) {
        let (recent, others) = store.startableCustomers
        var combos = (recent + others).flatMap { customer in
            store.startableProjects(forCustomer: customer.id).flatMap { project in
                store.activities(forProject: project.id).map { Combo(customer: customer, project: project, activity: $0) }
            }
        }
        if let index = combos.firstIndex(where: { $0.project.id == last.project && $0.activity.id == last.activity }) {
            combos.insert(combos.remove(at: index), at: 0)
        }
        self.combos = combos
    }

    /// Every term must appear in the customer, project or activity name, ignoring
    /// case and diacritics: "nor auto" finds Northwind Traders › Ops Dashboard › Automation.
    var results: [Combo] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return combos.filter { combo in
            terms.allSatisfy { term in
                [combo.customer.name, combo.project.name, combo.activity.name].contains { $0.localizedStandardContains(term) }
            }
        }
    }

    var current: Combo? {
        let results = results
        return results.first { $0.id == selection } ?? results.first
    }

    func move(_ step: Int) {
        let results = results
        guard let index = results.firstIndex(where: { $0.id == current?.id }) else { return }
        selection = results[min(max(index + step, 0), results.count - 1)].id
    }
}

struct NewTimerForm: View {
    @Environment(TrackerStore.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast
    @Bindable var model: NewTimerModel
    var start: () -> Void = {}
    var cancel: () -> Void = {}
    @FocusState private var noteFocused: Bool

    var body: some View {
        let results = model.results
        let current = model.current
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            PanelField(text: $model.query, placeholder: "Search customers, projects and activities", search: true) { command in
                switch command {
                case #selector(NSResponder.moveUp(_:)): model.move(-1)
                case #selector(NSResponder.moveDown(_:)): model.move(1)
                case #selector(NSResponder.insertTab(_:)): noteFocused = true
                case #selector(NSResponder.insertNewline(_:)): start()
                case #selector(NSResponder.cancelOperation(_:)): cancel()
                default: return false
                }
                return true
            }
            .onChange(of: model.query) { model.selection = nil }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { combo in
                            row(combo, selected: combo.id == current?.id).id(combo.id)
                        }
                    }
                    .padding(Studio.Space.xs)
                }
                .overlay(alignment: .top) {
                    if results.isEmpty {
                        Text("No match for “\(model.query)”")
                            .font(Studio.Typography.secondary)
                            .foregroundStyle(Studio.textSecondary)
                            .padding(Studio.Space.m)
                    }
                }
                .onChange(of: current?.id) { if let id = current?.id { proxy.scrollTo(id) } }
            }
            .frame(maxHeight: .infinity)
            .background(Studio.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(contrast == .increased ? Studio.controlBorder : Studio.lineSubtle, lineWidth: 0.5))
            TextField("Note (optional)", text: $model.note)
                .textFieldStyle(.roundedBorder)
                .focused($noteFocused)
                .onSubmit(start)
            if let error = model.error {
                ErrorLine(message: error)
            } else if store.connectionState != .online {
                Text("Kimai is not reachable").font(Studio.Typography.secondary).foregroundStyle(Studio.textSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(store.isRunning ? "Switch" : "Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(current == nil || model.starting || store.isBusy || store.connectionState != .online)
            }
        }
        .padding(Studio.Space.l)
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        .background(Studio.surface)
    }

    /// Customer dot, the activity, and "Customer › Project" below it. The
    /// selection is the system's; a double click starts.
    private func row(_ combo: Combo, selected: Bool) -> some View {
        HStack(spacing: Studio.Space.s) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Brand.color(hex: combo.customer.color) ?? .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(combo.activity.name).font(Studio.Typography.body)
                    .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : Studio.textPrimary)
                Text("\(combo.customer.name) › \(combo.project.name)").font(Studio.Typography.secondary)
                    .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : Studio.textSecondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.s)
        .padding(.vertical, 5)
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = combo.id
            if NSApp.currentEvent?.clickCount == 2 { start() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selection = combo.id; start() }
    }
}
