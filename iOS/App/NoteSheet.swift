import SwiftUI

/// Add Note… / Edit Note… (spec §6): the Mac's Note panel as a sheet. Save
/// closes it only once Kimai took the note; Cancel or a swipe down discards.
/// It writes to the timer it was opened for, never to one that replaced it.
struct NoteSheet: View {
    @Environment(PhoneTracker.self) private var tracker
    @Environment(\.dismiss) private var dismiss
    /// Captured when the sheet opens (State keeps the first value).
    @State private var target: Target?
    /// What runs, without its note (the field below has it).
    @State private var work: Work?
    @State private var saved: String
    @State private var text: String
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// What the note belongs to: the running entry, or the paused session.
    private enum Target: Equatable {
        case entry(Int)
        case paused(Date)
    }

    init(tracker: PhoneTracker) {
        var work = tracker.active.map(tracker.work) ?? tracker.paused?.work
        let saved = work?.note ?? ""
        work?.note = nil
        _work = State(initialValue: work)
        _target = State(initialValue: Self.current(tracker))
        _saved = State(initialValue: saved)
        _text = State(initialValue: saved)
    }

    private static func current(_ tracker: PhoneTracker) -> Target? {
        if let entry = tracker.active { return .entry(entry.id) }
        return tracker.paused.map { .paused($0.pausedAt) }
    }

    /// The timer it was opened for is still the one.
    private var isCurrent: Bool { target != nil && Self.current(tracker) == target }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let work { WorkLines(work: work) }
                    TextField("Add a note", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
                if !isCurrent {
                    Section { Problem("This timer has ended, so the note was not saved.", isError: false) }
                } else if let failure {
                    Section { Problem(failure) }
                }
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!isCurrent || (isRunningEntry && !tracker.canAct))
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    /// A running entry's note goes to Kimai; a paused session's stays on the phone until Resume.
    private var isRunningEntry: Bool { if case .entry = target { true } else { false } }

    private func save() {
        guard isCurrent, !saving else { return }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note != saved else { return dismiss() }
        saving = true
        failure = nil
        tracker.lastError = nil
        Task {
            await tracker.setDescription(note)
            saving = false
            // Never "Saved": the sheet just closes, or stays with the reason.
            if let error = tracker.lastError {
                failure = error
                tracker.lastError = nil
            } else {
                dismiss()
            }
        }
    }
}
