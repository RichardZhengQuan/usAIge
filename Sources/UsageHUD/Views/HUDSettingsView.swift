import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct HUDSettingsRootView: View {
    @ObservedObject var settings: HUDSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updateController: UpdateController

    var body: some View {
        HUDSettingsView(
            settings: settings,
            snapshots: store.visibleSnapshots,
            launchAtLogin: launchAtLogin,
            updateController: updateController,
            refreshUsage: { await store.refresh() }
        )
    }
}

@available(macOS 14.0, *)
struct HUDSettingsView: View {
    private static let websiteURL = URL(string: "https://pmrichq.com/project/usaige/")!

    @ObservedObject var settings: HUDSettings
    let snapshots: [QuotaSnapshot]
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updateController: UpdateController
    let refreshUsage: () async -> Void
    @State private var remoteToolToDelete: RemoteAITool?
    @State private var remoteToolError: String?
    @State private var route: [SettingsDestination] = []
    @State private var isDetectingLocalTools = false

    private var activeToolIDs: [AIToolID] {
        settings.toolOrder.filter { id in snapshots.contains(where: { $0.toolID == id }) }
    }

    private var activeLocalToolIDs: [AIToolID] {
        activeToolIDs.filter { AIToolID.builtInIDs.contains($0) }
    }

    private var activeRemoteToolIDs: [AIToolID] {
        activeToolIDs.filter { !AIToolID.builtInIDs.contains($0) }
    }

    var body: some View {
        Group {
            if let destination = route.last {
                destinationPage(destination)
            } else {
                settingsPage
            }
        }
        .confirmationDialog(
            "Remove remote tool?",
            isPresented: Binding(
                get: { remoteToolToDelete != nil },
                set: { if !$0 { remoteToolToDelete = nil } }
            ),
            presenting: remoteToolToDelete
        ) { tool in
            Button("Remove \(tool.name)", role: .destructive) {
                removeRemoteTool(tool)
            }
        } message: { tool in
            Text("This removes \(tool.name)'s endpoint and saved bearer token from this Mac.")
        }
    }

    private var settingsPage: some View {
        Form {
            Section("General") {
                Toggle(
                    "Open usAIge at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                if let message = launchAtLogin.errorMessage {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(launchAtLogin.requiresApproval ? Color.secondary : Color.red)
                        if launchAtLogin.requiresApproval {
                            Spacer()
                            Button("Open Login Items") {
                                launchAtLogin.openSystemSettings()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Usage alerts")

                        Text("Alerts are sent when usage crosses each selected interval.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(
                        "Usage alerts",
                        selection: Binding(
                            get: { settings.usageAlertIntervalPercent },
                            set: { settings.usageAlertIntervalPercent = $0 }
                        )
                    ) {
                        ForEach(HUDSettings.usageAlertIntervalOptions, id: \.self) { interval in
                            Text("\(interval)%").tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Usage alerts")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                pageLink("Manage AI Tools", destination: .aiTools)
            }

            Section("Display") {
                LabeledContent("Opacity") {
                    Slider(value: binding(for: \HUDSettings.opacity), in: HUDSettings.opacityRange)
                        .frame(width: 180)
                }
                LabeledContent("Scale") {
                    Slider(value: binding(for: \HUDSettings.scale), in: HUDSettings.scaleRange)
                        .frame(width: 180)
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show reset credits")

                        Text("Shows available Codex resets beside the live reset countdown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "Show reset credits",
                        isOn: Binding(
                            get: { settings.showsResetCredits },
                            set: { settings.showsResetCredits = $0 }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Show reset credits")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("More") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Software updates")
                        Text("Current version \(updateController.currentVersionText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(updateController.statusText)
                        .font(.caption)
                        .foregroundStyle(isUpdateError ? Color.red : Color.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Link("About usAIge", destination: Self.websiteURL)
                    Spacer()
                    if isUpdateBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    ZStack(alignment: .topTrailing) {
                        Button(updateController.primaryButtonTitle) {
                            Task { await updateController.performPrimaryAction() }
                        }
                        .disabled(!updateController.canPerformPrimaryAction)

                        if updateController.canInstallUpdate {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -3)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityValue(
                        updateController.canInstallUpdate
                            ? "New version available"
                            : updateController.statusText
                    )
                    Button("Quit usAIge") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .padding()
    }

    private var aiToolsPage: some View {
        pageContainer(title: "AI Tools") {
            Form {
                Section("Local AI Tools") {
                    if activeLocalToolIDs.isEmpty {
                        Text("No local tools detected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activeLocalToolIDs, id: \.self) { id in
                            toolRow(for: id)
                            ForEach(orderedSnapshots(for: id)) { snapshot in
                                usageTypeRow(snapshot)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            Task {
                                isDetectingLocalTools = true
                                await refreshUsage()
                                isDetectingLocalTools = false
                            }
                        } label: {
                            if isDetectingLocalTools {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Detecting…")
                                }
                            } else {
                                Label("Detect", systemImage: "magnifyingglass")
                            }
                        }
                        .disabled(isDetectingLocalTools)
                        .accessibilityHint("Scans again for supported local AI tools")
                    }
                }

                Section("Remote AI Tools") {
                    if settings.remoteTools.isEmpty {
                        Text("No remote tools connected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.remoteTools) { tool in
                            remoteToolRow(tool)
                        }
                    }
                    if let remoteToolError {
                        Text(remoteToolError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button {
                            route.append(.remoteToolSetup(nil))
                        } label: {
                            Label("Add Remote", systemImage: "plus")
                        }
                        .accessibilityHint("Opens remote AI tool setup")
                    }
                }

                if !activeRemoteToolIDs.isEmpty {
                    Section("Displayed Remote Limits") {
                        ForEach(activeRemoteToolIDs, id: \.self) { id in
                            toolRow(for: id)
                            ForEach(orderedSnapshots(for: id)) { snapshot in
                                usageTypeRow(snapshot)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func destinationPage(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .aiTools:
            aiToolsPage
        case let .remoteToolSetup(toolID):
            let tool = remoteTool(for: toolID)
            pageContainer(title: tool == nil ? "Set Up Remote AI Tool" : "Edit Remote AI Tool") {
                RemoteToolEditorPage(
                    tool: tool,
                    onSave: { tool, token, removeToken in
                        try saveRemoteTool(tool, token: token, removeToken: removeToken)
                    },
                    onDismiss: goBack
                )
            }
        }
    }

    private func pageContainer<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Back")
                .accessibilityLabel("Back")
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 4)

            content()
        }
    }

    private func pageLink(
        _ title: String,
        destination: SettingsDestination
    ) -> some View {
        Button {
            route.append(destination)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title)")
    }

    private func goBack() {
        guard !route.isEmpty else { return }
        route.removeLast()
    }

    private func remoteTool(for id: AIToolID?) -> RemoteAITool? {
        guard let id else { return nil }
        return settings.remoteTools.first { $0.id == id }
    }

    private func saveRemoteTool(
        _ tool: RemoteAITool,
        token: String,
        removeToken: Bool
    ) throws {
        let credentials = KeychainCredentialStore()
        if removeToken {
            try credentials.setToken(nil, for: tool.id)
        } else if !token.isEmpty {
            try credentials.setToken(token, for: tool.id)
        }
        try settings.upsertRemoteTool(tool)
        Task { await refreshUsage() }
    }

    private func orderedSnapshots(for toolID: AIToolID) -> [QuotaSnapshot] {
        settings.bucketOrder.compactMap { id in
            snapshots.first(where: { $0.id == id && $0.toolID == toolID })
        }
    }

    private func toolRow(for id: AIToolID) -> some View {
        let tool = snapshots.first(where: { $0.toolID == id })
            .map(AIToolDescriptor.descriptor(for:)) ?? AIToolDescriptor.descriptor(for: id)
        return HStack(spacing: 10) {
            AIToolIcon(tool: tool, size: 26)
            Toggle(
                tool.name,
                isOn: Binding(
                    get: { !settings.hiddenToolIDs.contains(id) },
                    set: { visible in
                        if visible { settings.hiddenToolIDs.remove(id) }
                        else { settings.hiddenToolIDs.insert(id) }
                    }
                )
            )
            Spacer()
            Text("\(orderedSnapshots(for: id).count) types")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func remoteToolRow(_ tool: RemoteAITool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tool.systemImage)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Toggle(
                    tool.name,
                    isOn: Binding(
                        get: { tool.isEnabled },
                        set: { enabled in
                            settings.setRemoteToolEnabled(tool.id, enabled: enabled)
                            Task { await refreshUsage() }
                        }
                    )
                )
                Text(tool.endpoint.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Edit") {
                route.append(.remoteToolSetup(tool.id))
            }
            .buttonStyle(.link)
            Button(role: .destructive) {
                remoteToolToDelete = tool
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(tool.name)")
            .accessibilityLabel("Remove \(tool.name)")
        }
    }

    private func removeRemoteTool(_ tool: RemoteAITool) {
        do {
            try KeychainCredentialStore().setToken(nil, for: tool.id)
            settings.removeRemoteTool(tool.id)
            remoteToolError = nil
            remoteToolToDelete = nil
            Task { await refreshUsage() }
        } catch {
            remoteToolError = error.localizedDescription
        }
    }

    private func usageTypeRow(_ snapshot: QuotaSnapshot) -> some View {
        HStack(spacing: 9) {
            Text(snapshot.combinedTypeTag)
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 72)
            Toggle(
                snapshot.displayName,
                isOn: Binding(
                    get: { !settings.hiddenBucketIDs.contains(snapshot.id) },
                    set: { visible in
                        if visible { settings.hiddenBucketIDs.remove(snapshot.id) }
                        else { settings.hiddenBucketIDs.insert(snapshot.id) }
                    }
                )
            )
            Spacer()
            orderButtons(
                moveUp: { settings.moveBucket(snapshot.id, by: -1) },
                moveDown: { settings.moveBucket(snapshot.id, by: 1) },
                label: snapshot.displayName
            )
        }
    }

    private func orderButtons(
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        label: String
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: moveUp) { Image(systemName: "chevron.up") }
                .help("Move \(label) up")
                .accessibilityLabel("Move \(label) up")
            Button(action: moveDown) { Image(systemName: "chevron.down") }
                .help("Move \(label) down")
                .accessibilityLabel("Move \(label) down")
        }
        .buttonStyle(.borderless)
    }

    private func binding(for keyPath: ReferenceWritableKeyPath<HUDSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private var isUpdateBusy: Bool {
        switch updateController.status {
        case .checking, .downloading, .preparing: true
        default: false
        }
    }

    private var isUpdateError: Bool {
        if case .failed = updateController.status { true } else { false }
    }
}

private enum SettingsDestination: Hashable {
    case aiTools
    case remoteToolSetup(AIToolID?)
}

@available(macOS 14.0, *)
private struct RemoteToolEditorPage: View {
    private let existingTool: RemoteAITool?
    private let onSave: (RemoteAITool, String, Bool) throws -> Void
    private let onDismiss: () -> Void
    @State private var name: String
    @State private var endpoint: String
    @State private var webURL: String
    @State private var connectionLink = ""
    @State private var token = ""
    @State private var removeToken = false
    @State private var showsAdvanced: Bool
    @State private var errorMessage: String?
    @State private var setupPromptCopyID: UUID?

    init(
        tool: RemoteAITool?,
        onSave: @escaping (RemoteAITool, String, Bool) throws -> Void,
        onDismiss: @escaping () -> Void
    ) {
        existingTool = tool
        self.onSave = onSave
        self.onDismiss = onDismiss
        _name = State(initialValue: tool?.name ?? "")
        _endpoint = State(initialValue: tool?.endpoint.absoluteString ?? "")
        _webURL = State(initialValue: tool?.webURL?.absoluteString ?? "")
        _showsAdvanced = State(initialValue: tool != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Form {
                if existingTool == nil {
                    Section("Recommended") {
                        HStack {
                            TextField(
                                "Connection link",
                                text: $connectionLink,
                                prompt: Text("usaige://connect?… or https://…")
                            )
                            Button("Paste") { pasteConnectionLink() }
                        }
                        Text("A connection link packages the server address and access key for you. Get it from a compatible service or your team administrator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(
                            "Codex connects automatically. Other services require an official usage API or a compatible adapter.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Link(
                            "Why can't some accounts connect?",
                            destination: URL(string: "https://github.com/RichardZhengQuan/usAIge#remote-ai-tools-011")!
                        )
                    }

                    Section("Get help") {
                        Label("Use Codex or Claude Code", systemImage: "terminal")
                        Text("Not sure where to get these details? Ask Codex or Claude Code to check the service's official options and prepare them for you. They cannot unlock data your account does not expose; personal Claude subscriptions currently have no official API for reading remaining limits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            copySetupPrompt()
                        } label: {
                            Label("Copy Setup Prompt", systemImage: "doc.on.doc")
                        }
                        .accessibilityHint("Copies instructions for setting up a safe usAIge connection.")
                        if setupPromptCopyID != nil {
                            Label(
                                "Prompt Copied — paste it into Codex or Claude Code.",
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        DisclosureGroup("Advanced setup", isExpanded: $showsAdvanced) {
                            connectionFields
                                .padding(.top, 8)
                        }
                    } footer: {
                        Text("Use Advanced setup only when you operate a usAIge-compatible JSON endpoint.")
                    }
                } else {
                    Section("Connection details") {
                        connectionFields
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existingTool == nil ? "Connect" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var connectionFields: some View {
        TextField("Display name", text: $name)
        TextField("Usage URL", text: $endpoint, prompt: Text("https://example.com/api/limits"))
        TextField("Website (optional)", text: $webURL)
        SecureField(
            existingTool == nil ? "Access token (optional)" : "New access token (leave blank to keep)",
            text: $token
        )
        if existingTool != nil {
            Toggle("Remove saved access token", isOn: $removeToken)
        }
        Text("The access token is stored in Keychain and sent only to this Usage URL.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var canSave: Bool {
        if existingTool == nil,
           !connectionLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return showsAdvanced
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func pasteConnectionLink() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            errorMessage = "The clipboard does not contain a connection link."
            return
        }
        connectionLink = value.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
    }

    private func copySetupPrompt() {
        guard RemoteToolSetupPrompt.copy() else {
            setupPromptCopyID = nil
            errorMessage = "The setup prompt could not be copied. Please try again."
            return
        }
        let copyID = UUID()
        setupPromptCopyID = copyID
        errorMessage = nil
        AccessibilityNotification.Announcement("Setup prompt copied").post()
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard setupPromptCopyID == copyID else { return }
            setupPromptCopyID = nil
        }
    }

    private func save() {
        var resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedWebURL = webURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedToken = token

        if existingTool == nil,
           !connectionLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let connection = try RemoteToolConnectionLink.parse(connectionLink)
                resolvedName = connection.name
                resolvedEndpoint = connection.endpoint.absoluteString
                resolvedWebURL = connection.webURL?.absoluteString ?? ""
                resolvedToken = connection.token ?? token
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        guard !resolvedName.isEmpty,
              let endpointURL = URL(string: resolvedEndpoint),
              isAllowedEndpoint(endpointURL) else {
            errorMessage = "Use a display name and an HTTPS Usage URL (HTTP is allowed only for localhost)."
            return
        }
        let parsedWebURL = resolvedWebURL.isEmpty ? nil : URL(string: resolvedWebURL)
        if !resolvedWebURL.isEmpty,
           !["http", "https"].contains(parsedWebURL?.scheme?.lowercased() ?? "") {
            errorMessage = "The tool URL must use HTTP or HTTPS."
            return
        }
        let tool = RemoteAITool(
            id: existingTool?.id ?? AIToolID(rawValue: UUID().uuidString.lowercased()),
            name: resolvedName,
            endpoint: endpointURL,
            webURL: parsedWebURL,
            systemImage: existingTool?.systemImage ?? "cpu",
            isEnabled: existingTool?.isEnabled ?? true
        )
        do {
            try onSave(tool, resolvedToken, removeToken)
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isAllowedEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }
}
