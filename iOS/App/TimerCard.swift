import ChronatoCore
import SwiftUI

/// The running entry: what it is, a large ticking time, its note, Pause and Stop.
struct RunningCard: View {
    @Environment(PhoneTracker.self) private var tracker
    let entry: KimaiTimesheet
    @State private var note: String

    init(entry: KimaiTimesheet) {
        self.entry = entry
        _note = State(initialValue: entry.description ?? "")
    }

    var body: some View {
        let work = tracker.work(entry)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                StatusLabel(title: "Running", systemImage: "record.circle", color: Brand.accent)
                Spacer()
                Text("since \(entry.begin.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true) // the timer below says it
            }
            WorkLabel(work: work)
            // Ticks by itself; no per-second state in the tracker.
            Text(timerInterval: entry.begin...Date.distantFuture, countsDown: false)
                .font(.system(size: 60, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Brand.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel("Running since \(entry.begin.formatted(date: .omitted, time: .shortened))")
            NoteField(text: $note, saved: entry.description) { $0.active?.id == entry.id }
            CardButtons {
                Button {
                    Task { await saveNote(note, over: entry.description, in: tracker); await tracker.pause() }
                } label: {
                    ButtonLabel(title: "Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                Button {
                    Task { await saveNote(note, over: entry.description, in: tracker); await tracker.stop() }
                } label: {
                    ButtonLabel(title: "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .disabled(tracker.isBusy)
        }
        .padding(.vertical, 8)
    }
}

/// The paused session: what it was, time worked before the break, Resume and Stop.
struct PausedCard: View {
    @Environment(PhoneTracker.self) private var tracker
    let session: PausedSession
    @State private var note: String

    init(session: PausedSession) {
        self.session = session
        _note = State(initialValue: session.work.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                StatusLabel(title: "Paused", systemImage: "pause.circle.fill", color: .secondary)
                Spacer()
                // The break so far, ticking like the running timer.
                HStack(spacing: 4) {
                    Text("break")
                    Text(timerInterval: session.pausedAt...Date.distantFuture, countsDown: false).monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Paused at \(session.pausedAt.formatted(date: .omitted, time: .shortened))")
            }
            WorkLabel(work: session.work)
            VStack(alignment: .leading, spacing: 0) {
                Text(DurationText.long(session.workedSeconds))
                    .font(.system(size: 60, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("worked before the break")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(DurationText.spoken(session.workedSeconds)) worked before the break")
            NoteField(text: $note, saved: session.work.note) { $0.active == nil && $0.paused?.pausedAt == session.pausedAt }
            CardButtons {
                Button {
                    Task { await saveNote(note, over: session.work.note, in: tracker); await tracker.resume() }
                } label: {
                    ButtonLabel(title: "Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await saveNote(note, over: session.work.note, in: tracker); await tracker.stop() }
                } label: {
                    ButtonLabel(title: "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }
            .controlSize(.large)
            .disabled(tracker.isBusy)
        }
        .padding(.vertical, 8)
    }
}

/// "● RUNNING" / "PAUSED" above the card.
private struct StatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    // Not a Label: List rows tint Label icons with the accent.
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(title.uppercased())
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
    }
}

/// The cards' two buttons side by side; stacked at accessibility text sizes,
/// where "Pause" would not fit half the width.
private struct CardButtons<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: Content

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        layout { content }
    }
}

/// Icon and title for the cards' buttons. Not a Label: in a List row its icon
/// would take the accent colour and vanish on the filled tomato button.
private struct ButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(title)
        }
        .fontWeight(.semibold)
        .frame(maxWidth: .infinity)
    }
}

/// Customer (colour dot and name) over "Project · Activity".
struct WorkLabel: View {
    let work: Work

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Dot(hex: work.customerColor)
                Text(work.customerName).font(.subheadline).foregroundStyle(.secondary)
            }
            Text("\(work.projectName) · \(work.activityName)")
                .font(.title3.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The note of the running entry (or paused session). Saves on Return and when
/// the field loses focus, but only while `isCurrent`: `setDescription` writes to
/// whatever runs now, and a card whose entry was replaced must not put its
/// text on the new one. The cards' buttons save first, so Pause/Stop keep it.
private struct NoteField: View {
    @Environment(PhoneTracker.self) private var tracker
    @Binding var text: String
    let saved: String?
    let isCurrent: @MainActor (PhoneTracker) -> Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Add a note", text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
                .onChange(of: saved) { if !focused { text = saved ?? "" } }
                .accessibilityLabel("Note")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func commit() {
        guard isCurrent(tracker) else { return }
        Task { await saveNote(text, over: saved, in: tracker) }
    }
}

/// Sends the note to the running entry (or paused session) if it changed.
@MainActor private func saveNote(_ text: String, over saved: String?, in tracker: PhoneTracker) async {
    let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if note != (saved ?? "") { await tracker.setDescription(note) }
}
