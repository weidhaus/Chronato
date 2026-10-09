import AppKit
import ChronatoCore
import SwiftUI

/// Settings → AI Agents: the allowlist in agents.json and where AI time is booked.
struct AgentsSettings: View {
    @Environment(TrackerStore.self) private var store
    @State private var config: AIConfig
    /// agents.json did not exist yet: the "Claude" user is shown as the booking
    /// user and saved with the first change, unless the user picks someone else.
    @State private var isFresh: Bool
    @State private var error: String?
    /// Creating an agent's ai- tag in Kimai failed (outlives the token sheet, unlike `error`).
    @State private var tagError: String?
    @State private var showingSheet = false
    @State private var newName = ""
    /// A token just created; shown once in the sheet, then forgotten.
    @State private var issued: IssuedToken?
    @State private var removing: AIAgent?

    struct IssuedToken {
        var agentName: String
        var token: String
    }

    /// Loaded here rather than on appear so the first layout already has every row.
    init() {
        let config = AIConfig.load()
        _config = State(initialValue: config)
        _isFresh = State(initialValue: config.bookingUserId == nil && !FileManager.default.fileExists(atPath: Paths.agentsFile.path))
    }

    var body: some View {
        Form {
            if let otherServer, let current = store.connection?.url {
                Section {
                    Problem("These settings were made for \(otherServer.host ?? "another server"). Their Kimai user and activities mean nothing on \(current.host ?? "this server"), so agents can't book until you set them up for it.", isError: false)
                    Button("Set Up for \(current.host ?? "This Server")", action: adopt)
                }
            }
            Section {
                Picker("Book AI time as", selection: bookingUser) {
                    Text("Me (\(store.me?.displayName ?? "API token user"))").tag(Int?.none)
                    ForEach(otherUsers) { Text($0.displayName).tag(Int?.some($0.id)) }
                    // Keeps the saved choice visible while users are not loaded (or Kimai can't book it).
                    if let id = config.bookingUserId, !otherUsers.contains(where: { $0.id == id }) {
                        Text(store.users.first { $0.id == id }.map { $0.systemAccount == true ? "\($0.displayName) (system account)" : $0.displayName } ?? "User #\(id)")
                            .tag(Int?.some(id))
                    }
                }
                LabeledContent("Default activity") {
                    ActivityMenu(projectId: config.defaultProjectId, activityId: config.defaultActivityId, noneTitle: "None") { project, activity in
                        update { $0.defaultProjectId = project; $0.defaultActivityId = activity }
                    }
                }
            } header: {
                Footnote("AI agents on this Mac (Claude Code, Codex, Cursor…) track their own work through Chronato's MCP server. Their time is booked as a separate Kimai user and tagged ai\u{2011}<name>. Only allow-listed agents with a valid token can book.")
                    .padding(.bottom, Studio.Space.s)
            } footer: {
                VStack(alignment: .leading, spacing: Studio.Space.xs) {
                    if let warning = bookingWarning {
                        Problem(warning, isError: false)
                    }
                    Footnote("The default activity is used when an agent names no project and has no default of its own.")
                }
            }
            Section {
                if config.agents.isEmpty {
                    Text("No agents allowed yet.").foregroundStyle(Studio.textSecondary)
                }
                ForEach(config.agents) { agent in
                    row(agent)
                }
                Button("Add Agent…") {
                    newName = ""
                    issued = nil
                    error = nil
                    showingSheet = true
                }
                // The first save picks the booking user, so it waits for Kimai's user list.
                .disabled(store.users.isEmpty || otherServer != nil)
                if let tagError {
                    Problem(tagError, isError: false)
                }
            } header: {
                Text("Agents")
            } footer: {
                if store.users.isEmpty {
                    Footnote("Connect to Kimai first (Settings → Connection) to add agents.")
                }
            }
            if let error, !showingSheet {
                Section {
                    Problem(error)
                }
            }
        }
        .formStyle(.grouped)
        // The sheet's errors (e.g. a duplicate name) belong to the sheet; drop them with it.
        .sheet(isPresented: $showingSheet, onDismiss: { issued = nil; error = nil }) { sheet }
        .confirmationDialog("Remove \(removing?.name ?? "agent")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { agent in
            Button("Remove", role: .destructive) { update { $0.agents.removeAll { $0.id == agent.id } } }
        } message: { _ in
            Text("Its token stops working at once. Time it already booked stays in Kimai.")
        }
    }

    private func row(_ agent: AIAgent) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                Text(agent.tag).font(Studio.Typography.secondary).foregroundStyle(Studio.textSecondary)
            }
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 12)
            ActivityMenu(projectId: agent.defaultProjectId, activityId: agent.defaultActivityId, noneTitle: "Use default") { project, activity in
                updateAgent(agent.id) { $0.defaultProjectId = project; $0.defaultActivityId = activity }
            }
            .menuStyle(.borderlessButton)
            Toggle("Enabled", isOn: Binding(get: { agent.enabled }, set: { on in updateAgent(agent.id) { $0.enabled = on } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Studio.accentInk)
                .help(agent.enabled ? "Allowed to book time" : "Disabled: its token is refused")
            Menu {
                Button("New Token…") { regenerate(agent) }
                Divider()
                Button("Remove…", role: .destructive) { removing = agent }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Sheet: add an agent, then show its token once

    @ViewBuilder private var sheet: some View {
        if let issued {
            AgentTokenView(agentName: issued.agentName, token: issued.token) { showingSheet = false }
        } else {
            VStack(alignment: .leading, spacing: Studio.Space.m) {
                Text("Add AI Agent").font(.headline)
                TextField("Name", text: $newName, prompt: Text("Claude Code"))
                    .onSubmit(add)
                Footnote("Its entries are tagged ai-\(AIConfig.slug(newName).isEmpty ? "<name>" : AIConfig.slug(newName)).")
                if let error {
                    Problem(error)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showingSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Add", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(AIConfig.slug(newName).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    // MARK: Changes (each one is saved at once)

    /// Users AI time can be booked as. Kimai refuses system accounts as the entry's user.
    private var otherUsers: [KimaiUser] {
        store.users.filter { $0.id != store.me?.id && $0.systemAccount != true }
    }

    /// The Kimai user named "Claude" (username or alias, any case), if there is one.
    private var suggestedUserId: Int? {
        otherUsers.first { user in
            [user.username, user.alias ?? ""].contains { $0.caseInsensitiveCompare("Claude") == .orderedSame }
        }?.id
    }

    /// Said under the picker when AI time won't land on a separate, bookable user.
    private var bookingWarning: String? {
        guard !store.users.isEmpty else { return nil }
        guard let id = bookingUser.wrappedValue else {
            let fix = !otherUsers.isEmpty ? "Pick a separate user, e.g. Claude, to keep your hours apart."
                : store.users.count > 1 ? "Create a Kimai user for the AI, e.g. Claude, that is not a system account."
                : "No other Kimai user is listed: create one for the AI, e.g. Claude. Kimai lists users only to a Super Admin API token."
            return "AI time is booked on your own timesheet, told apart from yours only by its ai-<agent> tag. " + fix
        }
        guard store.users.contains(where: { $0.id == id && $0.systemAccount == true }) else { return nil }
        return "Kimai refuses to book for a system account. Untick \"System account\" for this user in Kimai, or pick another."
    }

    /// agents.json belongs to another Kimai server than the one connected now.
    private var otherServer: URL? {
        guard let server = config.server, let current = store.connection?.url, server != current else { return nil }
        return server
    }

    /// Starts over for the server connected now: the old ids mean nothing here.
    private func adopt() {
        isFresh = true
        update { config in
            config.bookingUserId = nil
            config.defaultProjectId = nil
            config.defaultActivityId = nil
            for index in config.agents.indices {
                config.agents[index].defaultProjectId = nil
                config.agents[index].defaultActivityId = nil
            }
        }
    }

    private var bookingUser: Binding<Int?> {
        Binding(
            get: { isFresh ? suggestedUserId : config.bookingUserId },
            set: { id in
                isFresh = false
                update { $0.bookingUserId = id }
            })
    }

    /// Applies `change` and saves agents.json; on failure nothing changes and the error shows.
    @discardableResult
    private func update(_ change: (inout AIConfig) throws -> Void) -> Bool {
        var next = config
        do {
            try change(&next)
            if isFresh { next.bookingUserId = next.bookingUserId ?? suggestedUserId }
            next.server = store.connection?.url ?? next.server
            if !store.isPreview { try next.save() }
            config = next
            isFresh = false
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func updateAgent(_ id: UUID, _ change: (inout AIAgent) -> Void) {
        update { config in
            if let index = config.agents.firstIndex(where: { $0.id == id }) { change(&config.agents[index]) }
        }
    }

    private func add() {
        // Return can reach both onSubmit and the default button; add once.
        guard issued == nil, !AIConfig.slug(newName).isEmpty else { return }
        var added: (agent: AIAgent, token: String)?
        if update({ added = try $0.addAgent(named: newName) }), let added {
            issued = IssuedToken(agentName: added.agent.name, token: added.token)
            ensureTag(added.agent.tag)
        }
    }

    /// Kimai drops tags it doesn't know from a booking. Bookings create the tag too, but
    /// doing it now shows a missing permission here rather than in an agent's terminal.
    private func ensureTag(_ tag: String) {
        guard !store.isPreview, let client = store.client else { return }
        Task {
            do {
                try await client.ensureTag(tag)
                tagError = nil
            } catch {
                tagError = "Couldn't create the tag \(tag) in Kimai: \(error.localizedDescription)"
            }
        }
    }

    private func regenerate(_ agent: AIAgent) {
        var token: String?
        if update({ token = $0.regenerateToken(for: agent.id) }), let token {
            issued = IssuedToken(agentName: agent.name, token: token)
            showingSheet = true
        }
    }
}

/// A freshly issued agent token. Chronato keeps only its hash, so this is the
/// one chance to copy it.
struct AgentTokenView: View {
    let agentName: String
    let token: String
    let done: () -> Void
    @State private var copied: String?
    /// The binary MCP clients should start; never a disk image's or a translocated copy's path.
    private let executable = AgentSessions.stableExecutable(
        bundlePath: Bundle.main.bundlePath, executablePath: Bundle.main.executablePath ?? AgentSessions.installedExecutable)

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            Text("Token for \(agentName)").font(.headline)
            // A read-only field: raised, with a hairline edge.
            Text(token)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(Studio.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Studio.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Studio.lineSubtle, lineWidth: 0.5))
            Problem("This token won't be shown again. Copy it now, or a ready-made setup that registers Chronato as an MCP server in the agent's app.",
                    isError: false)
            if let warning = executable.warning {
                Label { Text(warning) } icon: { Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange) }
                    .font(Studio.Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Menu("Copy Setup") {
                    Button("Claude Code: Terminal Command") {
                        copy(AgentSessions.setupCommand(agentName: agentName, token: token, executable: executable.path), as: "Command copied")
                    }
                    Button("Codex: config.toml Entry") {
                        copy(AgentSessions.setupTOML(agentName: agentName, token: token, executable: executable.path), as: "Codex entry copied")
                    }
                    Button("Cursor, Claude Desktop, Others: JSON") {
                        copy(AgentSessions.setupJSON(agentName: agentName, token: token, executable: executable.path), as: "JSON copied")
                    }
                }
                .fixedSize()
                Button("Copy Token") { copy(token, as: "Token copied") }
                if let copied {
                    Text(copied).font(Studio.Typography.secondary).foregroundStyle(Studio.textSecondary)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func copy(_ text: String, as message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Both carry the token: ask clipboard managers (nspasteboard.org convention) not to keep it in their history.
        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copied = message
    }
}

/// Customer → Project → Activity as nested menus; picking an activity sets both ids.
struct ActivityMenu: View {
    @Environment(TrackerStore.self) private var store
    let projectId: Int?
    let activityId: Int?
    /// Label and first menu item when nothing is chosen.
    let noneTitle: String
    let select: (_ projectId: Int?, _ activityId: Int?) -> Void

    var body: some View {
        // A menu fills whatever width it is offered, which leaves a short title far
        // from its chevron: take the natural width when it fits, truncate when not.
        ViewThatFits(in: .horizontal) {
            menu.fixedSize()
            menu
        }
    }

    private var menu: some View {
        Menu {
            Button(noneTitle) { select(nil, nil) }
            Divider()
            ForEach(customers) { customer in
                Menu(customer.name) {
                    ForEach(store.projects(forCustomer: customer.id)) { project in
                        Menu(project.name) {
                            ForEach(store.activities(forProject: project.id)) { activity in
                                Button(activity.name) { select(project.id, activity.id) }
                            }
                        }
                    }
                }
            }
        } label: {
            Text(title)
        }
        .help(title)
        .disabled(store.projects.isEmpty)
    }

    private var customers: [KimaiCustomer] {
        store.customers
            .filter { !store.projects(forCustomer: $0.id).isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var title: String {
        guard let projectId, let activityId else { return noneTitle }
        let project = store.project(projectId)
        return [
            store.customer(project?.customer)?.name,
            project?.name ?? "Project #\(projectId)",
            store.activity(activityId)?.name ?? "Activity #\(activityId)",
        ].compactMap { $0 }.joined(separator: " › ")
    }
}
