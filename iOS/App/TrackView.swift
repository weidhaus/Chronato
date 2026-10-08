import ChronatoCore
import SwiftUI

/// The Track tab, built for "start or stop in two taps": the running or paused
/// timer (or, when idle, the start form with the last choice) at the top,
/// today/week totals, then recent entries that start again with one tap.
struct TrackView: View {
    @Environment(PhoneTracker.self) private var tracker
    /// The start sheet: "Switch to…" and "Change and start" on a recent entry.
    @State private var sheet: StartChoice?

    var body: some View {
        NavigationStack {
            List {
                Banners()
                // `.id`: a new entry gets a fresh card (and note field state).
                if let entry = tracker.active {
                    Section { RunningCard(entry: entry).id(entry.id) }
                        .listRowBackground(CardBackground(hex: tracker.work(entry).customerColor))
                    switchRow
                } else if let session = tracker.paused {
                    Section { PausedCard(session: session).id(session.pausedAt) }
                        .listRowBackground(CardBackground(hex: session.work.customerColor))
                    switchRow
                } else {
                    let choice = StartChoice.remembered(tracker)
                    // Re-created when the fallback changes (the recent list loads after launch).
                    Section("Start") { StartForm(choice: choice).id(choice.projectId) }
                }
                Section { Totals() }
                if !tracker.recent.isEmpty {
                    Section {
                        ForEach(tracker.recent) { entry in
                            RecentRow(entry: entry) { sheet = choice(from: entry) }
                        }
                    } header: {
                        Text("Recent")
                    } footer: {
                        Text(tracker.isRunning ? "Tap to switch to an entry. Swipe left to change it first." : "Tap to start an entry again. Swipe left to change it first.")
                    }
                }
            }
            .navigationTitle("Chronato")
            .toolbar {
                if tracker.isBusy || tracker.connectionState == .connecting {
                    ToolbarItem(placement: .topBarTrailing) { ProgressView() }
                }
            }
            // Pulling also reloads customers, projects and activities (just created in Kimai, say).
            .refreshable {
                await tracker.reloadCatalog()
                await tracker.refresh()
            }
            .sheet(item: $sheet) { StartSheet(choice: $0) }
            // Haptics confirm what Kimai accepted (start; stop and pause), or that it failed.
            .sensoryFeedback(trigger: tracker.active?.id) { old, new in
                new != nil ? .start : (old != nil ? .stop : nil)
            }
            .sensoryFeedback(trigger: tracker.lastError) { _, new in new != nil ? .error : nil }
        }
    }

    /// Opens the start form while something runs or is paused.
    private var switchRow: some View {
        Section {
            Button { sheet = .remembered(tracker) } label: {
                Label("Switch to Another Task…", systemImage: "arrow.left.arrow.right")
            }
        }
    }

    private func choice(from entry: KimaiTimesheet) -> StartChoice {
        StartChoice(customerId: entry.customerId ?? tracker.project(entry.projectId)?.customer,
                    projectId: entry.projectId, activityId: entry.activityId, note: entry.description ?? "")
    }
}

/// The running/paused card's row background: a thin bar in the customer's colour.
private struct CardBackground: View {
    let hex: String?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Brand.color(hex: hex) ?? .secondary).frame(width: 5)
            Color(.secondarySystemGroupedBackground)
        }
    }
}

/// The last error (or the 24 h notice) and the offline state, above everything.
private struct Banners: View {
    @Environment(PhoneTracker.self) private var tracker

    var body: some View {
        if let error = tracker.lastError {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true)
                    Text(error).font(.subheadline)
                    Spacer(minLength: 0)
                    Button { tracker.lastError = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        if case let .offline(message) = tracker.connectionState {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline").font(.subheadline.weight(.semibold))
                        Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Button("Retry") { Task { await tracker.refresh() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } footer: {
                Text("Showing what Chronato knew last.")
            }
        }
    }
}

/// One recent combination: tap starts it again (stopping whatever runs).
private struct RecentRow: View {
    @Environment(PhoneTracker.self) private var tracker
    let entry: KimaiTimesheet
    /// Opens the start sheet with this entry, to change it before starting.
    let edit: () -> Void

    var body: some View {
        let work = tracker.work(entry)
        Button(action: start) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(work.projectName) · \(work.activityName)")
                        .lineLimit(2)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Dot(hex: work.customerColor)
                        Text(work.customerName)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let note = work.note, !note.isEmpty {
                        Text(note).font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Brand.accent)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .disabled(tracker.isBusy)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: start) { Label("Start", systemImage: "play.fill") }.tint(Brand.accent)
        }
        .swipeActions(edge: .trailing) {
            Button(action: edit) { Label("Change", systemImage: "slider.horizontal.3") }.tint(.indigo)
        }
        .contextMenu {
            Button(action: start) { Label("Start", systemImage: "play.fill") }
            Button(action: edit) { Label("Change and Start…", systemImage: "slider.horizontal.3") }
        }
        .accessibilityLabel("\(work.projectName), \(work.activityName), \(work.customerName)\(work.note.map { ", \($0)" } ?? "")")
        .accessibilityHint(tracker.isRunning ? "Switches the timer to this entry" : "Starts a timer for this entry")
        .accessibilityAction(named: "Change and Start", edit)
    }

    private func start() { Task { await tracker.startAgain(entry) } }
}

/// Today and this week, mine, refreshed every minute.
private struct Totals: View {
    @Environment(PhoneTracker.self) private var tracker

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 0) {
                total("Today", tracker.todaySeconds(at: context.date))
                Divider().padding(.vertical, 4)
                total("This Week", tracker.weekSeconds(at: context.date)).padding(.leading, 16)
            }
        }
    }

    private func total(_ title: String, _ seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(DurationText.short(seconds))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(DurationText.spoken(seconds))
    }
}
