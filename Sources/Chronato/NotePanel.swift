import AppKit
import ChronatoCore
import SwiftUI

/// The note of the running entry or the paused session, typed in a small
/// panel (design/chronato-interaction-spec.md §5). Return saves and closes once
/// Kimai took it; Esc, Cancel or the close button discard; clicking elsewhere
/// saves if the text changed. While typing, the text is the store's draft, so
/// a pause, stop, switch or hot key meanwhile still saves it.
@MainActor
final class NotePanel: NSObject, NSWindowDelegate {
    private let store: TrackerStore
    private var panel: NSPanel?
    /// The open note; nil once it was saved, discarded or replaced.
    private var model: NoteModel?

    init(store: TrackerStore) {
        self.store = store
    }

    func show(below anchor: NSRect?) {
        if let panel, model != nil {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = NoteModel(store) else { return }
        self.model = model
        let panel = panel ?? FloatingPanel.make(title: "Note")
        panel.delegate = self
        let host = NSHostingController(rootView: NoteForm(model: model, save: { [weak self] in self?.save() },
                                                          cancel: { [weak self] in self?.discard() }).environment(store))
        // Default sizing: the panel follows the content's height (an error line grows it).
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        self.panel = panel
        FloatingPanel.place(panel, below: anchor)
        panel.makeKeyAndOrderFront(nil)
        follow(model)
    }

    /// Closes when the entry ends or is replaced meanwhile: the store saved the draft.
    private func follow(_ model: NoteModel) {
        guard self.model === model else { return }
        let current = withObservationTracking { model.isCurrent(in: store) } onChange: { [weak self] in
            Task { @MainActor in self?.follow(model) }
        }
        if !current { close() }
    }

    private func save() {
        guard let model, !model.saving else { return }
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != model.saved, model.isCurrent(in: store) else { return close() }
        model.saving = true
        model.error = nil
        Task {
            let error = await store.setDescription(text, entryId: model.entryId)
            model.saving = false
            guard let error else { return close() }
            // Stays open with the text; the error is shown here, so not again in the menu.
            model.error = error.localizedDescription
            if store.lastError == model.error { store.lastError = nil }
        }
    }

    private func discard() {
        guard let model else { return }
        restoreDraft(model)
        close()
    }

    private func restoreDraft(_ model: NoteModel) {
        if let id = model.entryId, store.active?.id == id { store.setNoteDraft(model.saved, for: id) }
    }

    private func close() {
        model = nil
        panel?.close()
    }

    // MARK: NSWindowDelegate

    /// Clicking elsewhere: save if changed, then close; a failure lands in `store.lastError`.
    func windowDidResignKey(_ notification: Notification) {
        guard let model, !model.saving else { return }
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != model.saved, model.isCurrent(in: store) {
            Task { [store] in await store.setDescription(text, entryId: model.entryId) }
        }
        close()
    }

    /// The close button discards.
    func windowWillClose(_ notification: Notification) {
        guard let model else { return }
        self.model = nil
        restoreDraft(model)
    }
}

@MainActor @Observable
final class NoteModel {
    /// The running entry; nil for the paused session.
    let entryId: Int?
    let pausedAt: Date?
    /// "Activity · Project" and the customer.
    let title: String
    let customer: String
    let saved: String
    var text: String
    var error: String?
    var saving = false

    /// Nil when there is nothing to note (idle, or away: the away choice comes first).
    init?(_ store: TrackerStore) {
        if let entry = store.active {
            let names = EntryNames(entry, in: store)
            (entryId, pausedAt, title, customer) = (entry.id, nil, "\(names.activity) · \(names.project)", names.customer)
            saved = entry.description ?? ""
            text = store.noteDraft(for: entry.id) ?? saved
        } else if let session = store.paused, store.awayNotice == nil {
            let names = EntryNames(session, in: store)
            (entryId, pausedAt, title, customer) = (nil, session.pausedAt, "\(names.activity) · \(names.project)", names.customer)
            saved = session.description ?? ""
            text = saved
        } else {
            return nil
        }
    }

    /// Still the entry (or paused session) this note is for.
    func isCurrent(in store: TrackerStore) -> Bool {
        if let entryId { return store.active?.id == entryId }
        return store.active == nil && store.paused?.pausedAt == pausedAt
    }
}

struct NoteForm: View {
    @Environment(TrackerStore.self) private var store
    @Bindable var model: NoteModel
    var save: () -> Void = {}
    var cancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Studio.textPrimary)
                if !model.customer.isEmpty {
                    Text(model.customer).font(Studio.Typography.secondary).foregroundStyle(Studio.textSecondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            PanelField(text: $model.text, placeholder: "Add a note") { command in
                switch command {
                case #selector(NSResponder.insertNewline(_:)): save()
                case #selector(NSResponder.cancelOperation(_:)): cancel()
                default: return false
                }
                return true
            }
            .onChange(of: model.text) {
                if let id = model.entryId, store.active?.id == id { store.setNoteDraft(model.text, for: id) }
            }
            if let error = model.error { ErrorLine(message: error) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.saving)
            }
        }
        .padding(Studio.Space.l)
        .frame(width: 360)
        .background(Studio.surface)
    }
}

// MARK: - Shared by the Note and New Timer panels

/// A small floating panel that takes the keyboard without activating Chronato,
/// so the app the user was in stays frontmost and gets it back on close (§5).
@MainActor
enum FloatingPanel {
    static func make(title: String, resizable: Bool = false) -> NSPanel {
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        let panel = NSPanel(contentRect: .zero, styleMask: style, backing: .buffered, defer: true)
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = NSColor(Studio.surface)
        return panel
    }

    /// Top edge 6 pt under the status item, centred on it, 8 pt inside the
    /// screen. Without a status-item window (hidden behind the notch): centred
    /// on the mouse's screen, its top a third of the way down.
    static func place(_ panel: NSPanel, below anchor: NSRect?) {
        let size = panel.frame.size
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let visible = screen.visibleFrame
            let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - 8 - size.width)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6))
        } else {
            let mouse = NSEvent.mouseLocation
            let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
            panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height / 3))
        }
    }
}

/// A native text (or search) field that takes the keyboard when its panel
/// appears, with all text selected, and hands the field editor's commands
/// (↑ ↓ Tab Return Esc) to `command`, which returns true when it handled one.
struct PanelField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var search = false
    var command: @MainActor (Selector) -> Bool = { _ in false }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = search ? FocusedSearchField() : FocusedTextField()
        if !search { field.bezelStyle = .roundedBezel }
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.stringValue = text
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PanelField

        init(_ parent: PanelField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            parent.command(selector)
        }
    }
}

/// Becomes first responder as soon as it is in a window; AppKit then selects its text.
private final class FocusedTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

private final class FocusedSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

/// An error: symbol and words in `errorInk`, never colour alone (§2).
struct ErrorLine: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(Studio.Typography.secondary)
        .foregroundStyle(Studio.errorInk)
        .fixedSize(horizontal: false, vertical: true)
    }
}
