import AppKit
import ChronatoCore

/// The status item and its native menu, as in HoldFn and Meetfacts
/// (design/chronato-interaction-spec.md §3, §4). The menu is built from the
/// store when it opens and follows the store while open; the status item
/// follows it all the time, but redraws only when its glyph, title or label
/// actually changed (once a minute while a timer runs).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    /// "Update to x — Install…" once Sparkle found x. The snapshot passes its own.
    var availableUpdate: () -> String? = { Updater.shared.availableVersion }

    private let store: TrackerStore
    private let statusItem: NSStatusItem?
    private lazy var notePanel = NotePanel(store: store)
    private lazy var newTimerPanel = NewTimerPanel(store: store)
    private var look: StatusLook?
    private var isOpen = false
    /// Bumped on every open, so observation loops of an earlier open stop.
    private var generation = 0
    /// The menu as last built, without the ticking text: rebuilt only when this changes,
    /// so a refresh that changed nothing visible does not close an open submenu.
    private var signature = ""
    /// Retitle the lines that tick (running time, totals, agent minutes).
    private var ticking: [() -> Void] = []
    private var shownError = false

    static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    private static let nothingStartable = "No project with an activity is visible to this Kimai user."

    /// `statusItem: false` builds the menu only (snapshots).
    init(store: TrackerStore, statusItem: Bool = true) {
        self.store = store
        self.statusItem = statusItem ? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) : nil
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        guard let button = self.statusItem?.button else { return }
        self.statusItem?.menu = menu
        button.imagePosition = .imageLeading
        button.font = Self.titleFont
        build() // an empty menu would not open
        followStatus()
        // "Show customer name in the menu bar" is a pref, not store state.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateButton() }
        }
    }

    // MARK: Status item

    private func followStatus() {
        withObservationTracking { updateButton() } onChange: { [weak self] in
            Task { @MainActor in self?.followStatus() }
        }
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let new = StatusLook(store, showCustomer: UserDefaults.standard.bool(forKey: Prefs.showCustomerInMenuBar))
        guard new != look else { return }
        look = new
        new.apply(to: button)
    }

    /// Panels open just under the status item.
    private var anchor: NSRect? { statusItem?.button?.window?.frame }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        generation += 1
        Task { await store.refresh() }
        follow(generation)
        followClock(generation)
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        // An error is shown once (§4.8).
        if shownError {
            store.lastError = nil
            shownError = false
        }
    }

    /// Rebuilds whenever something the menu shows changed, while it is open.
    private func follow(_ generation: Int) {
        guard isOpen, generation == self.generation else { return }
        let changed = withObservationTracking { rebuild() } onChange: { [weak self] in
            Task { @MainActor in self?.follow(generation) }
        }
        if changed { tick() }
    }

    /// The clock is read here, outside `follow`'s observation: a second must
    /// retitle two lines, not rebuild the menu.
    private func followClock(_ generation: Int) {
        guard isOpen, generation == self.generation else { return }
        withObservationTracking { tick() } onChange: { [weak self] in
            Task { @MainActor in self?.followClock(generation) }
        }
    }

    private func tick() { ticking.forEach { $0() } }

    // MARK: Building

    /// Builds the menu and sets the ticking lines, as on open (snapshots).
    func build() {
        if rebuild() { tick() }
    }

    /// Blocks A–I (§4.2); an empty block is left out with its separator.
    /// Never reads the clock (`tick` does). True when the items were replaced.
    private func rebuild() -> Bool {
        var ticking: [() -> Void] = []
        let blocks = [notices(), header(&ticking), timerActions(), recentBlock(), startBlock(), agentsBlock(&ticking),
                      windowsBlock(), appBlock(), [command("Quit Chronato", symbol: "power", key: "q") { NSApp.terminate(nil) }]]
        var items: [NSMenuItem] = []
        for block in blocks where !block.isEmpty {
            if !items.isEmpty { items.append(.separator()) }
            items += block
        }
        let signature = Self.dump(items, expand: false)
        guard signature != self.signature else { return false }
        self.signature = signature
        self.ticking = ticking
        menu.items = items
        return true
    }

    private var canAct: Bool { store.connectionState == .online && !store.isBusy }

    /// A: the last error, connecting, offline.
    private func notices() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let error = store.lastError {
            items.append(info(firstSentence(error), tail: true, image: Self.errorImage, imageName: "exclamationmark.triangle.fill", tip: error))
            if isOpen { shownError = true }
        }
        switch store.connectionState {
        case .connecting:
            items.append(info("Connecting to Kimai…", secondary: true))
        case let .offline(message):
            let prefix = "Can't reach Kimai: "
            items.append(info("Kimai is not reachable"))
            items.append(info(message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message, secondary: true, tail: true, tip: message))
            // No saved connection: the Keychain refused it at launch.
            if store.connection == nil {
                items.append(connectItem())
            } else {
                items.append(command("Try Again", symbol: "arrow.clockwise", enabled: !store.isBusy) { [store] in Task { await store.refresh() } })
            }
        case .online, .unconfigured:
            break
        }
        return items
    }

    /// B: what runs or is paused, and the totals.
    private func header(_ ticking: inout [() -> Void]) -> [NSMenuItem] {
        let store = store
        if store.connectionState == .unconfigured {
            return [info("Not connected to Kimai"), info("Add your Kimai address and an API token to start.", secondary: true, limit: .max)]
        }
        var items: [NSMenuItem] = []
        if let entry = store.active {
            items += entryLines(EntryNames(entry, in: store), note: entry.description)
            let since = sinceText(entry.begin)
            items.append(ticker(&ticking, digits: true) { "Running since \(since) · \(DurationText.long(store.elapsedSeconds))" })
            if let end = store.pendingStopAt {
                items.append(info("Ends at \(sinceText(end)) once Kimai is reachable", digits: true,
                                  image: Self.symbol("clock.badge.exclamationmark"), imageName: "clock.badge.exclamationmark"))
            }
        } else if let session = store.paused {
            items += entryLines(EntryNames(session, in: store), note: session.description)
            if let away = store.awayNotice {
                items.append(info("Away \(Self.compactSpan(away)) (\(minutes(away.seconds)))", digits: true, tip: "Away \(away.span)"))
                if away.countAway == .tooLong { items.append(info("More than a day away is not counted")) }
            } else {
                let since = sinceText(session.pausedAt)
                items.append(info("Paused since \(since) · \(DurationText.short(session.workedSeconds)) worked before", digits: true,
                                  tip: "Kimai has no pause: the entry ended at \(since). Resume starts a new one with the same customer, project, activity and note."))
            }
        } else if store.connectionState != .connecting {
            items.append(info("Not running"))
        }
        // At launch nothing is loaded yet: no totals rather than 0:00.
        if store.connectionState != .connecting {
            items.append(ticker(&ticking, secondary: true, digits: true) {
                "Today \(DurationText.short(store.todaySeconds)) · This week \(DurationText.short(store.weekSeconds))"
            })
        }
        return items
    }

    /// "14:02–14:27"; across midnight "Thu 23:10 – Fri 07:45", short enough for
    /// one menu line (the dates are in the tooltip).
    private static func compactSpan(_ away: TrackerStore.AwayNotice) -> String {
        guard !Calendar.current.isDate(away.since, inSameDayAs: away.until) else { return away.span }
        let style = Date.FormatStyle().weekday(.abbreviated).hour().minute()
        return "\(away.since.formatted(style)) – \(away.until.formatted(style))"
    }

    /// "Activity · Project", then "Customer — Note".
    private func entryLines(_ names: EntryNames, note: String?) -> [NSMenuItem] {
        let second = [names.customer, note ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
        var items = [info("\(names.activity) · \(names.project)", weight: .semibold, tip: names.full)]
        if !second.isEmpty { items.append(info(second, secondary: true)) }
        return items
    }

    /// C: what can be done with the current timer.
    private func timerActions() -> [NSMenuItem] {
        let store = store
        if store.connectionState == .unconfigured { return [connectItem()] }
        let hotKey = UserDefaults.standard.bool(forKey: Prefs.hotKeyEnabled) && store.hotKeyError == nil ? "Also ⌃⌥⌘T from anywhere" : nil
        if store.isRunning {
            return [
                command("Pause", symbol: "pause", key: "p", tip: hotKey, enabled: canAct) { Task { await store.pause() } },
                command("Stop", symbol: "stop", key: "s", enabled: canAct) { Task { await store.stop() } },
                noteItem(),
            ]
        }
        guard store.paused != nil else { return [] }
        guard let away = store.awayNotice else {
            return [
                command("Resume", symbol: "play", key: "p", tip: hotKey, enabled: canAct) { Task { await store.resume() } },
                command("Stop", symbol: "stop", key: "s", enabled: canAct) { Task { await store.stop() } },
                noteItem(),
            ]
        }
        var items = [command("Resume", symbol: "play", key: "p", subtitle: "Time away is not tracked", tip: hotKey, enabled: canAct) {
            Task { await store.resolveAway(.resume) }
        }]
        // A day or more away is never counted (TrackingPolicy.countAway).
        if away.countAway != .tooLong {
            items.append(command("Resume and Count Time Away" + (away.countAway == .needsConfirmation ? "…" : ""), symbol: "clock.arrow.circlepath",
                                 subtitle: "Starts again from \(sinceText(away.since))", enabled: canAct) { [weak self] in self?.countAway(away) })
        }
        items.append(command("Stay Paused", symbol: "pause.circle", enabled: canAct) { Task { await store.resolveAway(.stayPaused) } })
        items.append(command("Stop", symbol: "stop", key: "s", enabled: canAct) { Task { await store.resolveAway(.stop) } })
        return items
    }

    private func noteItem() -> NSMenuItem {
        let note = store.active?.description ?? store.paused?.description ?? ""
        return command(note.isEmpty ? "Add Note…" : "Edit Note…", symbol: "pencil", key: "e", enabled: canAct) { [weak self] in
            guard let self else { return }
            notePanel.show(below: anchor)
        }
    }

    private func connectItem() -> NSMenuItem {
        command("Connect to Kimai…", symbol: "link") { AppWindows.shared.showSettings(tab: .connection) }
    }

    /// More than 4 h away is booked only after the user saw the span and said yes.
    /// Decided at the click: the time away grows while the menu is open.
    private func countAway(_ away: TrackerStore.AwayNotice) {
        let needsConfirmation = TrackingPolicy.countAway(since: away.since, now: Date()) == .needsConfirmation
        if needsConfirmation, let session = store.paused {
            let names = EntryNames(session, in: store)
            let alert = NSAlert()
            alert.messageText = "Count \(minutes(Date().timeIntervalSince(away.since))) away as work?"
            alert.informativeText = "You were away \(away.span). \(names.project) · \(names.activity) then runs from "
                + "\(sinceText(away.since)), and all of that time is booked in Kimai."
            alert.addButton(withTitle: "Count It")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { [store] in await store.resolveAway(.resumeCountingAway, confirmed: needsConfirmation) }
    }

    /// D: one click starts (or switches to) a recent combination.
    private func recentBlock() -> [NSMenuItem] {
        let store = store
        guard store.connectionState != .unconfigured, !store.recent.isEmpty else { return [] }
        var items = [NSMenuItem.sectionHeader(title: "Recent")]
        for entry in store.recent.prefix(5) {
            let names = EntryNames(entry, in: store)
            let note = entry.description ?? ""
            let full = names.full + (note.isEmpty ? "" : " — \(note)")
            items.append(command("\(names.activity) · \(names.project)", image: Self.dot(store.customer(names.customerId)?.color), imageName: "dot",
                                 subtitle: [names.customer, note].filter { !$0.isEmpty }.joined(separator: " — "),
                                 tip: (store.isRunning ? "Switch to: " : "Start again: ") + full, enabled: canAct) {
                Task { await store.startAgain(entry) }
            })
        }
        return items
    }

    /// E: Start ▸ Customer ▸ Project ▸ Activity, and New Timer….
    private func startBlock() -> [NSMenuItem] {
        guard store.connectionState != .unconfigured else { return [] }
        let title = store.isRunning ? "Switch To" : store.paused != nil ? "Start Something Else" : "Start"
        let customers = store.startableCustomers
        let nothing = customers.recent.isEmpty && customers.others.isEmpty
        let tip = nothing ? Self.nothingStartable : nil
        let start = command(title, symbol: "play.circle", tip: tip, enabled: canAct && !nothing, run: nil)
        start.submenu = LazyMenu { [weak self] in self?.fillCustomers($0) }
        let new = command("New Timer…", symbol: "plus", key: "n", tip: tip, enabled: canAct && !nothing) { [weak self] in
            guard let self else { return }
            newTimerPanel.show(below: anchor)
        }
        return [start, new]
    }

    /// Recent customers first, then the rest by name. A level with one choice
    /// collapses into a section header; activities never do (choosing one is the action).
    private func fillCustomers(_ menu: NSMenu) {
        let (recent, others) = store.startableCustomers
        if recent.count + others.count == 1, let only = (recent + others).first {
            return fillProjects(menu, of: only, header: true)
        }
        for customer in recent { menu.addItem(customerItem(customer)) }
        if !recent.isEmpty, !others.isEmpty { menu.addItem(.separator()) }
        for customer in others { menu.addItem(customerItem(customer)) }
    }

    private func customerItem(_ customer: KimaiCustomer) -> NSMenuItem {
        let item = command(customer.name, image: Self.dot(customer.color), imageName: "dot", run: nil)
        item.submenu = LazyMenu { [weak self] in self?.fillProjects($0, of: customer, header: false) }
        return item
    }

    private func fillProjects(_ menu: NSMenu, of customer: KimaiCustomer, header: Bool) {
        let projects = store.startableProjects(forCustomer: customer.id)
        if projects.count == 1 {
            return fillActivities(menu, of: projects[0], header: header ? "\(customer.name) › \(projects[0].name)" : projects[0].name)
        }
        if header { menu.addItem(.sectionHeader(title: customer.name)) }
        for project in projects {
            let item = command(project.name, run: nil)
            item.submenu = LazyMenu { [weak self] in self?.fillActivities($0, of: project, header: nil) }
            menu.addItem(item)
        }
    }

    private func fillActivities(_ menu: NSMenu, of project: KimaiProject, header: String?) {
        let store = store
        if let header { menu.addItem(.sectionHeader(title: header)) }
        for activity in store.activities(forProject: project.id) {
            menu.addItem(command(activity.name) {
                Task { await store.start(projectId: project.id, activityId: activity.id, description: nil) }
            })
        }
    }

    /// F: AI-agent sessions (not the user's time).
    private func agentsBlock(_ ticking: inout [() -> Void]) -> [NSMenuItem] {
        let store = store
        guard store.connectionState != .unconfigured, !store.agentSessions.isEmpty else { return [] }
        var items = [NSMenuItem.sectionHeader(title: "AI Agents")]
        for session in store.agentSessions {
            let refused = session.lastError != nil
            let path = [session.customerName, session.projectName, session.activityName].compactMap { $0 }.joined(separator: " › ")
            let item = command([session.agentName, session.activityName ?? session.projectName].compactMap { $0 }.joined(separator: " · "),
                               image: refused ? Self.errorImage : Self.symbol("sparkles"),
                               imageName: refused ? "exclamationmark.triangle.fill" : "sparkles",
                               subtitle: refused ? "Not booked — Kimai refused it" : nil,
                               tip: "\(session.agentName): \(path) — \(session.description)", run: nil)
            if !refused {
                // A stopped session no longer counts up.
                ticking.append { [weak item] in
                    item?.subtitle = clip("\(minutes((session.stoppedAt ?? store.now).timeIntervalSince(session.begin))) · \(session.description)", 48, tail: true)
                }
            }
            item.submenu = LazyMenu { [weak self] in self?.fillAgent($0, session) }
            items.append(item)
        }
        return items
    }

    private func fillAgent(_ menu: NSMenu, _ session: AgentSession) {
        let store = store
        menu.addItem(info([session.customerName, session.projectName, session.activityName].compactMap { $0 }.joined(separator: " › ")))
        menu.addItem(info(session.description, secondary: true, tail: true))
        guard let error = session.lastError else { return }
        menu.addItem(info(firstSentence(error), tail: true, tip: error))
        menu.addItem(.separator())
        menu.addItem(command("Discard Session", symbol: "trash") {
            AgentSessions.remove(session.id)
            Task { await store.refresh() }
        })
    }

    /// G: the windows and Kimai.
    private func windowsBlock() -> [NSMenuItem] {
        let store = store
        guard store.connectionState != .unconfigured else { return [] }
        return [
            command("Show Reports", symbol: "chart.bar.xaxis", key: "r") { AppWindows.shared.showReports() },
            command("Open Kimai", symbol: "arrow.up.forward.app", enabled: store.connection != nil) { store.openKimai() },
        ]
    }

    /// H: updates and Settings.
    private func appBlock() -> [NSMenuItem] {
        let update = if let version = availableUpdate() {
            command("Update to \(version) — Install…", symbol: "arrow.down.circle") { Updater.shared.checkForUpdates() }
        } else {
            command("Check for Updates…", symbol: "arrow.triangle.2.circlepath", enabled: Updater.shared.canCheckForUpdates) {
                Updater.shared.checkForUpdates()
            }
        }
        return [update, command("Settings…", symbol: "gearshape", key: ",") { AppWindows.shared.showSettings() }]
    }

    // MARK: Items

    /// A command: Title Case, verb first, a template symbol (§4.1).
    private func command(_ title: String, symbol: String? = nil, image: NSImage? = nil, imageName: String? = nil, key: String = "",
                         subtitle: String? = nil, tip: String? = nil, enabled: Bool = true,
                         run: (@MainActor () -> Void)? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: clip(title, 44), action: run == nil ? nil : #selector(itemChosen(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = run.map(Action.init)
        item.isEnabled = enabled
        if let subtitle, !subtitle.isEmpty { item.subtitle = clip(subtitle, 48) }
        item.toolTip = tip ?? (item.title == title ? nil : title)
        if let name = imageName ?? symbol {
            item.image = image ?? Self.symbol(name)
            item.identifier = NSUserInterfaceItemIdentifier(name) // names the image in the snapshot dump
        }
        return item
    }

    /// An informative line: not clickable, but in full text colour, because the
    /// dimmed disabled colour fails 4.5:1 (§4.1). One line, no subtitle.
    /// Names are cut in the middle, sentences (`tail`, e.g. Kimai's messages) at the end.
    private func info(_ text: String, secondary: Bool = false, weight: NSFont.Weight = .regular, digits: Bool = false,
                      tail: Bool = false, limit: Int = 48, image: NSImage? = nil, imageName: String? = nil, tip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.attributedTitle = Self.infoTitle(clip(text, limit, tail: tail), secondary: secondary, weight: weight, digits: digits)
        item.toolTip = tip ?? (text.count > limit ? text : nil)
        item.image = image
        item.identifier = imageName.map { NSUserInterfaceItemIdentifier($0) }
        return item
    }

    /// An informative line whose text follows the clock (`tick`).
    private func ticker(_ ticking: inout [() -> Void], secondary: Bool = false, digits: Bool = false, _ text: @escaping @MainActor () -> String) -> NSMenuItem {
        let item = info("", secondary: secondary, digits: digits)
        ticking.append { [weak item] in item?.attributedTitle = Self.infoTitle(text(), secondary: secondary, weight: .regular, digits: digits) }
        return item
    }

    private static func infoTitle(_ text: String, secondary: Bool, weight: NSFont.Weight, digits: Bool) -> NSAttributedString {
        let size = NSFont.menuFont(ofSize: 0).pointSize
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor])
    }

    @objc private func itemChosen(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }

    private final class Action: NSObject {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Errors carry their own colour (and words); not a template.
    private static var errorImage: NSImage? {
        let image = symbol("exclamationmark.triangle.fill")?.withSymbolConfiguration(.init(paletteColors: [Studio.NS.errorInk]))
        image?.isTemplate = false
        return image
    }

    /// The customer's Kimai colour as a 10 pt dot in a 12 pt image; no colour: a secondary dot.
    /// Nonisolated: AppKit may call the drawing block on any thread.
    nonisolated private static func dot(_ hex: String?) -> NSImage {
        let color = Brand.color(hex: hex).map { NSColor($0) }
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            (color ?? .secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill()
            return true
        }
    }

    // MARK: Snapshot dump

    /// One line per item: depth, title, subtitle, key, enabled or informative,
    /// image, submenu, toolTip. `expand` fills and lists lazy submenus.
    static func dump(_ items: [NSMenuItem], depth: Int = 0, expand: Bool = true) -> String {
        let indent = String(repeating: "    ", count: depth)
        var lines: [String] = []
        for item in items {
            if item.isSeparatorItem {
                lines.append(indent + "────────")
                continue
            }
            if item.isSectionHeader {
                lines.append(indent + "[\(item.title)]")
                continue
            }
            var parts = [item.attributedTitle?.string ?? item.title]
            if let subtitle = item.subtitle { parts.append("subtitle: \(subtitle)") }
            if !item.keyEquivalent.isEmpty { parts.append("⌘" + item.keyEquivalent.uppercased()) }
            if let title = item.attributedTitle, title.length > 0 {
                let color = title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                let font = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                let bold = font.map { NSFontManager.shared.weight(of: $0) > 5 } ?? false
                parts.append("info" + (color == .secondaryLabelColor ? ", secondary" : "") + (bold ? ", semibold" : ""))
            } else if !item.isEnabled {
                parts.append("disabled")
            }
            // AppKit names an item without identifier after its action.
            if let name = item.identifier?.rawValue, name != item.action.map(NSStringFromSelector) {
                parts.append(item.image == nil ? "image MISSING \(name)" : "image \(name)")
            }
            if item.submenu != nil { parts.append("▸") }
            if let tip = item.toolTip { parts.append("tip: \(tip)") }
            lines.append(indent + parts.joined(separator: "  |  "))
            if expand, let submenu = item.submenu {
                submenu.delegate?.menuNeedsUpdate?(submenu)
                lines.append(dump(submenu.items, depth: depth + 1))
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// A submenu filled when it opens (§4.1), so a large catalog does not slow the menu.
private final class LazyMenu: NSMenu, NSMenuDelegate {
    private let fill: @MainActor (NSMenu) -> Void

    init(_ fill: @escaping @MainActor (NSMenu) -> Void) {
        self.fill = fill
        super.init(title: "")
        autoenablesItems = false
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        fill(self)
    }
}

/// What the status item shows (§3): glyph, h:mm while running, VoiceOver label.
struct StatusLook: Equatable {
    enum Glyph { case idle, running, paused }
    var glyph: Glyph
    var title: String
    var label: String

    /// Reads `elapsedMinutes`, never the clock: the title changes once a minute.
    @MainActor init(_ store: TrackerStore, showCustomer: Bool) {
        if let active = store.active {
            let customer = EntryNames(active, in: store).customer
            let time = DurationText.short(store.elapsedMinutes * 60)
            glyph = .running
            title = showCustomer && !customer.isEmpty ? time + "  " + (customer.count > 16 ? customer.prefix(15) + "…" : customer) : time
            let spoken = Duration.seconds(store.elapsedMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
            label = ["Chronato, running", spoken, customer].filter { !$0.isEmpty }.joined(separator: ", ")
            if let end = store.pendingStopAt { label += ", ends at \(sinceText(end)) once Kimai is reachable" }
        } else if store.paused != nil {
            glyph = .paused
            title = ""
            label = store.awayNotice == nil ? "Chronato, paused" : "Chronato, paused, you were away"
        } else {
            glyph = .idle
            title = ""
            label = store.connectionState == .unconfigured ? "Chronato, not connected" : "Chronato"
        }
        if case .offline = store.connectionState { label += ", Kimai not reachable" }
    }

    @MainActor func apply(to button: NSButton) {
        button.image = switch glyph {
        case .idle: Self.idle
        case .running: Self.running
        case .paused: Self.paused
        }
        button.title = title
        button.setAccessibilityLabel(label)
    }

    @MainActor private static let idle = Brand.menuBarGlyph(running: false)
    @MainActor private static let running = Brand.menuBarGlyph(running: true)
    @MainActor private static let paused = withPauseBadge(Brand.menuBarGlyph(running: false))

    /// The idle glyph with a 7 pt pause badge 2 pt to its right, one template image.
    /// Nonisolated: AppKit may call the drawing block on any thread.
    nonisolated private static func withPauseBadge(_ glyph: NSImage) -> NSImage {
        let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .heavy)) ?? NSImage()
        let height = max(glyph.size.height, 18)
        let image = NSImage(size: NSSize(width: glyph.size.width + 2 + pause.size.width, height: height), flipped: false) { _ in
            for (part, x) in [(glyph, 0), (pause, glyph.size.width + 2)] {
                part.draw(in: NSRect(origin: NSPoint(x: x, y: ((height - part.size.height) / 2).rounded()), size: part.size))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Shared wording

/// Display names for an entry. `/timesheets/active` may return bare ids, so
/// missing names come from the catalog.
struct EntryNames {
    var customerId: Int?
    var customer: String
    var project: String
    var activity: String

    @MainActor init(_ entry: KimaiTimesheet, in store: TrackerStore) {
        customerId = entry.customerId ?? store.project(entry.projectId)?.customer
        customer = entry.customerName ?? store.customer(customerId)?.name ?? ""
        project = entry.projectName ?? store.project(entry.projectId)?.name ?? "Project \(entry.projectId)"
        activity = entry.activityName ?? store.activity(entry.activityId)?.name ?? "Activity \(entry.activityId)"
    }

    @MainActor init(_ session: TrackerStore.PausedSession, in store: TrackerStore) {
        customerId = store.project(session.projectId)?.customer
        customer = session.customerName ?? store.customer(customerId)?.name ?? ""
        project = session.projectName ?? store.project(session.projectId)?.name ?? "Project \(session.projectId)"
        activity = session.activityName ?? store.activity(session.activityId)?.name ?? "Activity \(session.activityId)"
    }

    /// "Customer › Project › Activity" for tooltips.
    var full: String { [customer, project, activity].filter { !$0.isEmpty }.joined(separator: " › ") }
}

/// "17:30" today, "Fri, 9 Oct, 17:30" for another day (a timer started yesterday,
/// a session paused on Friday).
func sinceText(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
}

/// "25 min", "1 hr, 5 min", "2 days, 15 hr" (a weekend away).
func minutes(_ interval: TimeInterval) -> String {
    Duration.seconds(max(0, interval)).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
}

/// At most `limit` characters: cut in the middle so both ends of a name stay
/// readable, or at the end (`tail`) so a sentence still starts as written.
func clip(_ text: String, _ limit: Int, tail: Bool = false) -> String {
    guard text.count > limit else { return text }
    if tail { return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" }
    let head = (limit - 1) / 2
    return text.prefix(head) + "…" + text.suffix(limit - 1 - head)
}

/// "The request timed out." from "The request timed out. Kimai did not answer …".
private func firstSentence(_ text: String) -> String {
    text.range(of: ". ").map { String(text[..<$0.lowerBound]) + "." } ?? text
}

extension TrackerStore {
    /// The customer's projects that have something to start (at least one activity).
    func startableProjects(forCustomer id: Int) -> [KimaiProject] {
        projects(forCustomer: id).filter { !activities(forProject: $0.id).isEmpty }
    }

    /// Customers with a startable project: the ones in Recent first (newest
    /// first), then the others by name.
    var startableCustomers: (recent: [KimaiCustomer], others: [KimaiCustomer]) {
        let usable = customers.filter { !startableProjects(forCustomer: $0.id).isEmpty }
        var recentIds: [Int] = []
        for entry in recent {
            if let id = entry.customerId ?? project(entry.projectId)?.customer, !recentIds.contains(id) { recentIds.append(id) }
        }
        return (recentIds.compactMap { id in usable.first { $0.id == id } },
                usable.filter { !recentIds.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}
