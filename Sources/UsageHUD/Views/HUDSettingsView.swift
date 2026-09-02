import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct HUDSettingsRootView: View {
    @ObservedObject var settings: HUDSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updateController: UpdateController
    @ObservedObject var relaySync: RelaySyncController
    @ObservedObject var localToolStatus: LocalToolStatusRegistry
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        HUDSettingsView(
            settings: settings,
            snapshots: store.visibleSnapshots,
            launchAtLogin: launchAtLogin,
            updateController: updateController,
            relaySync: relaySync,
            localToolStatus: localToolStatus,
            navigation: navigation,
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
    @ObservedObject var relaySync: RelaySyncController
    @ObservedObject var localToolStatus: LocalToolStatusRegistry
    @ObservedObject var navigation: SettingsNavigation
    let refreshUsage: () async -> Void
    @State private var remoteToolToDelete: RelayRemoteTool?
    @State private var isDetectingLocalTools = false
    @State private var remotePromptCopied = false
    @State private var feedbackDraft = FeedbackDraft()
    @State private var feedbackState: FeedbackSubmissionState = .idle
    @StateObject private var claudeSignIn = ClaudeSignInSession()
    @State private var expandedToolIDs: Set<AIToolID> = []

    private var activeToolIDs: [AIToolID] {
        settings.toolOrder.filter { id in snapshots.contains(where: { $0.toolID == id }) }
    }

    private var activeRemoteToolIDs: [AIToolID] {
        activeToolIDs.filter { !AIToolID.builtInIDs.contains($0) }
    }

    var body: some View {
        Group {
            if let destination = navigation.route.last {
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
            Text("This revokes \(tool.name)'s relay credential and removes its synced limits.")
        }
    }

    private var settingsPage: some View {
        settingsForm(topPadding: 16) {
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
                pageLink("iPhone & Apple Watch Sync", destination: .iphoneSync)
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
                pageLink("Send Feedback", destination: .feedback)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Software updates")
                        Text("Current version \(updateController.currentVersionText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            if isUpdateBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(updateController.statusText)
                                .font(.caption)
                                .foregroundStyle(isUpdateError ? Color.red : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        updateButton
                    }
                }

                HStack(spacing: 10) {
                    Link("About usAIge", destination: Self.websiteURL)
                    Button("What’s New") {
                        NSApp.sendAction(
                            #selector(AppDelegate.showWhatsNewWindow(_:)),
                            to: nil,
                            from: nil
                        )
                    }
                    Spacer()
                    Button("Quit usAIge") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .task {
            await updateController.checkForUpdates()
        }
    }

    private var updateButton: some View {
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
        .fixedSize()
        .layoutPriority(2)
        .accessibilityValue(
            updateController.canInstallUpdate
                ? "New version available"
                : updateController.statusText
        )
    }

    /// One compact list: every supported local tool on its own row with its
    /// state and controls, limits behind a disclosure, so the page fits
    /// without scrolling. Remote tools follow with their limits in place.
    private var aiToolsPage: some View {
        pageContainer(title: "AI Tools") {
            settingsForm {
                Section {
                    ForEach(LocalToolGuidance.supported) { guidance in
                        localToolStatusRow(guidance)
                    }
                    HStack {
                        Text("Sign-ins stay on this Mac; only limits are read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                } header: {
                    Text("Local AI Tools")
                }

                Section("Remote AI Tools") {
                    if relaySync.remoteTools.isEmpty && activeRemoteToolIDs.isEmpty {
                        Text("No remote tools connected.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(relaySync.remoteTools) { tool in
                        remoteToolRow(tool)
                        if expandedToolIDs.contains(tool.toolID) {
                            ForEach(orderedSnapshots(for: tool.toolID)) { snapshot in
                                usageTypeRow(snapshot)
                            }
                        }
                    }
                    ForEach(activeRemoteToolIDs.filter { id in !relaySync.remoteTools.contains { $0.toolID == id } }, id: \.self) { id in
                        toolRow(for: id)
                    }
                    if let relayErrorMessage {
                        Text(relayErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button {
                            navigation.route.append(.remoteToolPairing)
                        } label: {
                            Label("Add AI Tool", systemImage: "plus")
                        }
                        .accessibilityHint("Creates a one-time code for pairing a remote AI tool")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destinationPage(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .aiTools:
            aiToolsPage
        case .remoteToolPairing:
            remoteToolPairingPage
        case .iphoneSync:
            iPhoneSyncPage
        case .feedback:
            feedbackPage
        }
    }

    private var feedbackPage: some View {
        pageContainer(title: "Send Feedback") {
            settingsForm {
                Section("Your Feedback") {
                    TextEditor(text: $feedbackDraft.content)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if feedbackDraft.content.isEmpty {
                                Text("What happened, or what would you like us to improve?")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: feedbackDraft.content) { _, value in
                            feedbackDraft.content = String(value.prefix(FeedbackDraft.contentLimit))
                            if !value.isEmpty, feedbackState != .submitting {
                                feedbackState = .idle
                            }
                        }
                    Text("Write one sentence or several. Please don’t include passwords, API keys, or other secrets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        feedbackStatus
                        Spacer()
                        Button {
                            submitFeedback()
                        } label: {
                            if feedbackState == .submitting {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Sending…")
                                }
                            } else {
                                Label("Send Feedback", systemImage: "paperplane")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!feedbackDraft.canSubmit || feedbackState == .submitting)
                    }
                } footer: {
                    Text("usAIge sends this message with the platform, system version, architecture, locale, app version/build, and submission time. No account is required.")
                }
            }
        }
    }

    @ViewBuilder
    private var feedbackStatus: some View {
        switch feedbackState {
        case .idle, .submitting:
            EmptyView()
        case .sent:
            Label("Feedback sent. Thank you!", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func submitFeedback() {
        let submission = FeedbackSubmission(content: feedbackDraft.trimmedContent)
        feedbackState = .submitting
        Task {
            do {
                _ = try await FeedbackClient().submit(submission)
                feedbackDraft.content = ""
                feedbackState = .sent
            } catch {
                feedbackState = .failed(error.localizedDescription)
            }
        }
    }

    private var iPhoneSyncPage: some View {
        pageContainer(title: "iPhone & Apple Watch Sync") {
            settingsForm {
                Section("Connection") {
                    if relaySync.isLinked {
                        LabeledContent("Mac", value: relaySync.macName)
                        LabeledContent("Status", value: relayStatusText)
                        if let date = relaySync.lastUploadAt {
                            LabeledContent("Last upload", value: date.formatted(date: .omitted, time: .shortened))
                        }
                    } else {
                        ContentUnavailableView(
                            "Not Connected",
                            systemImage: "iphone.and.arrow.forward",
                            description: Text("Create a code, then enter it in usAIge on iPhone.")
                        )
                    }
                    if let code = relaySync.pairingCode, let expiry = relaySync.pairingExpiresAt, expiry > Date() {
                        LabeledContent("Pairing code") {
                            Text(code)
                                .font(.system(.title2, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                        }
                        Text("Expires \(expiry.formatted(date: .omitted, time: .shortened)). Each code connects one iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(relaySync.isLinked ? "Add iPhone" : "Create Connection") {
                            Task {
                                if relaySync.isLinked { await relaySync.createPairingCode() }
                                else { await relaySync.createChannel() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if relaySync.isLinked {
                    Section("Paired iPhones") {
                        if relaySync.devices.isEmpty {
                            Text("No iPhones paired yet.").foregroundStyle(.secondary)
                        }
                        ForEach(relaySync.devices) { device in
                            HStack {
                                Label(device.name, systemImage: "iphone")
                                Spacer()
                                Text(device.lastSeenAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                Button("Revoke", role: .destructive) { Task { await relaySync.revoke(device) } }
                            }
                        }
                    }
                    Section {
                        Button("Disconnect All", role: .destructive) { Task { await relaySync.disconnectAll() } }
                    } footer: {
                        Text("Only normalized limit percentages and reset times are relayed. A paired iPhone forwards them to Apple Watch. Disconnecting deletes the shared server channel and revokes every iPhone and paired AI tool.")
                    }
                }
            }
        }
    }

    private var remoteToolPairingPage: some View {
        pageContainer(title: "Connect AI Tool") {
            settingsForm {
                Section("Connection") {
                    if relaySync.remoteTools.isEmpty {
                        ContentUnavailableView(
                            "Not Connected",
                            systemImage: "link.badge.plus",
                            description: Text("Create a code, then give it to Codex, Claude Code, or another compatible AI tool.")
                        )
                    } else {
                        LabeledContent("Mac", value: relaySync.macName)
                        LabeledContent("Status", value: relayStatusText)
                    }

                    if let code = relaySync.remotePairingCode,
                       let expiry = relaySync.remotePairingExpiresAt,
                       expiry > Date() {
                        LabeledContent("Pairing code") {
                            Text(code)
                                .font(.system(.title2, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                        }
                        Text("Expires \(expiry.formatted(date: .omitted, time: .shortened)). Each code connects one AI tool.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                remotePromptCopied = RemoteToolSetupPrompt.copy(pairingCode: code)
                            } label: {
                                Label(
                                    remotePromptCopied ? "Instructions Copied" : "Copy Connection Instructions",
                                    systemImage: remotePromptCopied ? "checkmark.circle.fill" : "doc.on.doc"
                                )
                            }
                            Spacer()
                            Button("Create New Code") {
                                Task { await relaySync.createRemoteToolPairingCode() }
                            }
                            .disabled(isRelayConnecting)
                        }
                    } else {
                        HStack {
                            Spacer()
                            Button {
                                remotePromptCopied = false
                                Task { await relaySync.createRemoteToolPairingCode() }
                            } label: {
                                if isRelayConnecting {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Creating…")
                                    }
                                } else {
                                    Text(relaySync.remoteTools.isEmpty ? "Create Connection" : "Add AI Tool")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRelayConnecting)
                        }
                    }
                    if let relayErrorMessage {
                        Text(relayErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !relaySync.remoteTools.isEmpty {
                    Section("Paired AI Tools") {
                        ForEach(relaySync.remoteTools) { tool in
                            HStack {
                                Label(tool.name, systemImage: tool.symbolName)
                                Spacer()
                                if let lastUploadAt = tool.lastUploadAt {
                                    Text(lastUploadAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Waiting for limits")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button("Revoke", role: .destructive) {
                                    Task {
                                        await relaySync.revoke(tool)
                                        await refreshUsage()
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Label(
                        "Only normalized remaining percentages and reset times are accepted. Provider credentials stay with the paired tool.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .task { _ = try? await relaySync.refreshRemoteTools() }
        }
    }

    private func settingsForm<Content: View>(
        topPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            Form {
                content()
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.top, topPadding)
            .padding(.bottom, 28)
        }
    }

    private var relayStatusText: String {
        switch relaySync.status {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .uploading: "Uploading…"
        case let .failed(message): message
        }
    }

    private var isRelayConnecting: Bool {
        if case .connecting = relaySync.status { true } else { false }
    }

    private var relayErrorMessage: String? {
        if case let .failed(message) = relaySync.status { message } else { nil }
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
            navigation.route.append(destination)
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
        guard !navigation.route.isEmpty else { return }
        navigation.route.removeLast()
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

    private func localToolStatusRow(_ guidance: LocalToolGuidance) -> some View {
        let tool = AIToolDescriptor.descriptor(for: guidance.id)
        let status = localToolStatus(for: guidance.id)
        let presentation = guidance.presentation(for: status)
        let buckets = orderedSnapshots(for: guidance.id)
        let isExpanded = expandedToolIDs.contains(guidance.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AIToolIcon(tool: tool, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name)
                    Text(presentation.text)
                        .font(.caption)
                        .foregroundStyle(presentation.isProblem ? Color.orange : Color.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if guidance.id == .claude {
                    if Self.offersClaudeSignIn(status: status), !claudeSignIn.isActive {
                        Button("Sign In…") { claudeSignIn.start() }
                            .controlSize(.small)
                            .accessibilityHint("Runs Claude Code's own sign-in and opens the Claude sign-in page")
                    }
                    Toggle(
                        "Read Claude Code sign-in",
                        isOn: Binding(
                            get: { settings.readsClaudeSignIn },
                            set: { enabled in
                                settings.readsClaudeSignIn = enabled
                                Task { await refreshUsage() }
                            }
                        )
                    )
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Read Claude Code sign-in")
                    .help("Read the Claude Code sign-in from Keychain")
                }
                if !buckets.isEmpty {
                    Toggle(
                        "Show \(tool.name)",
                        isOn: Binding(
                            get: { !settings.hiddenToolIDs.contains(guidance.id) },
                            set: { visible in
                                if visible { settings.hiddenToolIDs.remove(guidance.id) }
                                else { settings.hiddenToolIDs.insert(guidance.id) }
                            }
                        )
                    )
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Show \(tool.name) in the rail")
                    .help("Show \(tool.name) in the rail")
                    Button {
                        if isExpanded { expandedToolIDs.remove(guidance.id) } else { expandedToolIDs.insert(guidance.id) }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(buckets.count) \(buckets.count == 1 ? "limit" : "limits")")
                                .font(.caption2)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "Hide \(tool.name) limits" : "Show \(tool.name) limits")
                }
            }
            .accessibilityElement(children: .contain)

            if isExpanded {
                ForEach(buckets) { snapshot in
                    usageTypeRow(snapshot)
                }
                .padding(.leading, 34)
            }

            if guidance.id == .claude {
                claudeSignInPanel
            }
        }
        .onAppear {
            claudeSignIn.onSucceeded = {
                settings.readsClaudeSignIn = true
                Task { await refreshUsage() }
            }
        }
    }

    /// The sign-in button is useful whenever no Claude plan sign-in is
    /// readable yet; a connected or rate-limited tool doesn't need it.
    static func offersClaudeSignIn(status: LocalToolStatus) -> Bool {
        switch status {
        case .connected, .rateLimited, .unknown: false
        default: true
        }
    }

    @ViewBuilder
    private var claudeSignInPanel: some View {
        switch claudeSignIn.state {
        case .idle:
            EmptyView()
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting Claude Code's sign-in…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { claudeSignIn.cancel() }.controlSize(.small)
            }
        case .waitingForCode:
            VStack(alignment: .leading, spacing: 6) {
                Text("Approve the sign-in in your browser, then paste the code it shows here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Paste the code", text: $claudeSignIn.code)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { claudeSignIn.submit() }
                    Button("Continue") { claudeSignIn.submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(claudeSignIn.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 12) {
                    Button("Open sign-in page again") { claudeSignIn.openSignInPage() }.buttonStyle(.link)
                    Button("Cancel") { claudeSignIn.cancel() }.buttonStyle(.link)
                }
                .font(.caption)
            }
        case .submitting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing the sign-in…").font(.caption).foregroundStyle(.secondary)
            }
        case .succeeded:
            HStack(spacing: 8) {
                Label("Signed in. macOS may ask once to let usAIge read the sign-in.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { claudeSignIn.reset() }.controlSize(.small)
            }
        case let .failed(message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Spacer()
                Button("Try Again") { claudeSignIn.reset(); claudeSignIn.start() }.controlSize(.small)
            }
        case .unavailable:
            HStack(spacing: 8) {
                Text("Claude Code isn’t installed. Install it, run `claude` once, then try again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { claudeSignIn.reset() }.controlSize(.small)
            }
        }
    }

    private func localToolStatus(for id: AIToolID) -> LocalToolStatus {
        if id == .chatGPT {
            return snapshots.contains(where: { $0.toolID == .chatGPT }) ? .connected : .signedOut
        }
        return localToolStatus.status(for: id)
    }

    private func remoteToolRow(_ tool: RelayRemoteTool) -> some View {
        let buckets = orderedSnapshots(for: tool.toolID)
        let isExpanded = expandedToolIDs.contains(tool.toolID)
        return HStack(spacing: 10) {
            Image(systemName: tool.symbolName)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                Text(tool.lastUploadAt == nil ? "Waiting for limits" : "Connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !buckets.isEmpty {
                Toggle(
                    "Show \(tool.name)",
                    isOn: Binding(
                        get: { !settings.hiddenToolIDs.contains(tool.toolID) },
                        set: { visible in
                            if visible { settings.hiddenToolIDs.remove(tool.toolID) }
                            else { settings.hiddenToolIDs.insert(tool.toolID) }
                        }
                    )
                )
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Show \(tool.name) in the rail")
                Button {
                    if isExpanded { expandedToolIDs.remove(tool.toolID) } else { expandedToolIDs.insert(tool.toolID) }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(buckets.count) \(buckets.count == 1 ? "limit" : "limits")").font(.caption2)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "Hide \(tool.name) limits" : "Show \(tool.name) limits")
            }
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

    private func removeRemoteTool(_ tool: RelayRemoteTool) {
        remoteToolToDelete = nil
        Task {
            await relaySync.revoke(tool)
            await refreshUsage()
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

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var route: [SettingsDestination] = []

    func showMainPage() {
        route.removeAll()
    }
}

enum SettingsDestination: Hashable {
    case aiTools
    case remoteToolPairing
    case iphoneSync
    case feedback
}

private enum FeedbackSubmissionState: Equatable {
    case idle
    case submitting
    case sent
    case failed(String)
}
