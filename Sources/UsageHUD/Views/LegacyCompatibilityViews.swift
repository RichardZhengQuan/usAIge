import AppKit
import SwiftUI

/// A SwiftUI implementation restricted to APIs present on the first M1 Macs.
struct LegacyHUDView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: HUDSettings
    @ObservedObject var updateController: UpdateController
    @ObservedObject var screenState: PanelScreenState
    @ObservedObject var liveWork: LiveWorkMonitor
    let openTool: (AIToolDescriptor) -> Void
    let openSettings: () -> Void
    let resizePanel: (CGSize) -> Void
    @State private var labelWidth: CGFloat = 0
    @State private var isHovered = false

    private var availableSnapshots: [QuotaSnapshot] { store.visibleSnapshots }
    private var snapshots: [QuotaSnapshot] { settings.ordered(availableSnapshots) }
    private var desiredSize: CGSize {
        // A legacy row places its icon beside the title and percentage.
        let naturalWidth = max(ceil(216 * settings.textSize.factor), labelWidth + 62)
        let maximumWidth = (screenState.visibleWidth - 2 * PanelPositioner.inset) / settings.scale
        let maximumHeight = HUDMetrics.maximumRailHeight(visibleHeight: screenState.visibleHeight, scale: settings.scale)
        let rowsHeight = HUDMetrics.railHeight(
            rowCount: snapshots.count,
            maximumHeight: maximumHeight,
            textSize: settings.textSize
        )
        return CGSize(width: min(naturalWidth, maximumWidth), height: min(maximumHeight, rowsHeight + 46 * settings.textSize.factor))
    }

    var body: some View {
        VStack(spacing: 8) {
            LegacyResourceReadings(cpu: liveWork.cpu, memory: liveWork.memoryUsage)
            if snapshots.isEmpty {
                legacyStatus
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(snapshots) { snapshot in
                            LegacyQuotaRow(snapshot: snapshot, openTool: openTool)
                        }
                    }
                }
                Divider()
                HStack {
                    Button("Refresh") { Task { await store.refresh() } }
                    Spacer()
                    Button("Settings") { openSettings() }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .font(.system(size: 13 * settings.textSize.factor))
        .environment(\.hudTextSize, settings.textSize)
        .padding(10)
        .frame(width: desiredSize.width, height: desiredSize.height)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.94))
        .cornerRadius(18)
        .opacity(HUDMetrics.contentOpacity(configured: settings.opacity, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onPreferenceChange(HUDLabelWidthKey.self) { width in
            MainActor.assumeIsolated { labelWidth = width }
        }
        .scaleEffect(settings.scale)
        .frame(width: desiredSize.width * settings.scale, height: desiredSize.height * settings.scale)
        .onAppear {
            settings.registerBuckets(availableSnapshots)
            resizePanel(HUDMetrics.scaledSize(desiredSize, scale: settings.scale))
        }
        .onChange(of: availableSnapshots.map(\.id)) { _ in
            // Buckets that appear after launch (a second tool signing in)
            // need a slot in the order too.
            settings.registerBuckets(availableSnapshots)
        }
        .onChange(of: HUDMetrics.scaledSize(desiredSize, scale: settings.scale)) { size in
            resizePanel(size)
        }
    }

    @ViewBuilder
    private var legacyStatus: some View {
        switch store.state {
        case .connecting:
            ProgressView("Connecting…")
        case .signedOut:
            Button("Open ChatGPT to sign in") { openTool(.descriptor(for: .chatGPT)) }
        case let .unavailable(message):
            VStack { Text(message); Button("Open ChatGPT") { openTool(.descriptor(for: .chatGPT)) } }
        case .empty:
            VStack { Text("No usage limits"); Button("Retry") { Task { await store.refresh() } } }
        default:
            EmptyView()
        }
    }
}

private struct LegacyResourceReadings: View {
    @ObservedObject var cpu: SystemCPUMonitor
    let memory: SystemMemoryUsage?
    var showsCPUTrend = false
    @Environment(\.hudTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("CPU  \(cpu.usage.map { LiveWorkText.percent($0.busy) } ?? "–")")
                if !showsCPUTrend {
                    CPUTrendPlot(samples: cpu.samples, compact: true).frame(width: 32, height: 15)
                }
            }
            if showsCPUTrend {
                CPUTrendChart(samples: cpu.samples, plotHeight: 88)
            }
            Label(memory?.compactTotal ?? "Memory unavailable", systemImage: "memorychip")
                .hudRailLabel()
                .help(memory?.breakdown() ?? AppLanguage.text("Memory unavailable"))
                .accessibilityLabel("Memory")
                .accessibilityValue(memory?.compactTotal ?? "Unavailable")
        }
        .font(.system(size: 11 * textSize.factor, weight: .medium).monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LegacyQuotaRow: View {
    let snapshot: QuotaSnapshot
    let openTool: (AIToolDescriptor) -> Void

    private var remaining: Double { min(100, max(0, snapshot.remainingPercent)) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { openTool(.descriptor(for: snapshot.toolID)) }) {
                AIToolIcon(tool: .descriptor(for: snapshot.toolID), size: 24)
            }
            .buttonStyle(PlainButtonStyle())
            VStack(alignment: .leading, spacing: 4) {
                // An unusually long provider title can wrap at the screen
                // edge. Its ideal width still drives the normal panel size.
                readout.background(readout.hudRailLabel().hidden().accessibilityHidden(true))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.gray.opacity(0.25))
                        Rectangle()
                            .fill(remaining <= 10 ? Color.red : Color.accentColor)
                            .frame(width: geometry.size.width * remaining / 100)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 4)
    }

    private var readout: some View {
        HStack {
            Text(snapshot.displayName).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let count = ResetCreditPresentation.displayedCount(for: snapshot) {
                Text("\(count)r")
                    .fontWeight(.medium)
                    .fixedSize()
                    .accessibilityLabel("\(count) reset \(count == 1 ? "credit" : "credits") available")
            }
            Text("\(Int(remaining.rounded()))%").fixedSize()
        }
    }
}

struct LegacyHUDSettingsRootView: View {
    @ObservedObject var settings: HUDSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updateController: UpdateController
    @ObservedObject var relaySync: RelaySyncController
    @ObservedObject var liveWork: LiveWorkMonitor
    @State private var showsThisMac = false
    @State private var feedbackDraft = FeedbackDraft()
    @State private var isSendingFeedback = false
    @State private var feedbackStatusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Overview").font(.headline)
                LegacyResourceReadings(cpu: liveWork.cpu, memory: liveWork.memoryUsage, showsCPUTrend: true)
                Button("CPU…") { showsThisMac = true }
                    .sheet(isPresented: $showsThisMac) {
                        VStack(alignment: .trailing) {
                            ThisMacPage(liveWork: liveWork)
                            Button("Done") { showsThisMac = false }.padding([.bottom, .trailing])
                        }
                        .frame(width: 440, height: 430)
                    }
                Divider()
                Text("Display", bundle: AppLanguage.resourceBundle).font(.headline)
                AppLanguagePicker()
                HStack { Text("Opacity"); Slider(value: opacityBinding, in: HUDSettings.opacityRange) }
                HStack { Text("Scale"); Slider(value: scaleBinding, in: HUDSettings.scaleRange) }
                Picker("Panel text size", selection: $settings.textSize) {
                    ForEach(HUDTextSize.allCases, id: \.self) { size in
                        Text(LocalizedStringKey(size.title), bundle: AppLanguage.resourceBundle).tag(size)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())

                Divider()
                Text("Usage display").font(.headline)
                Picker("Usage alerts", selection: $settings.usageAlertIntervalPercent) {
                    ForEach(HUDSettings.usageAlertIntervalOptions, id: \.self) { interval in
                        Text("\(interval)%").tag(interval)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())

                Divider()
                Text("Startup").font(.headline)
                IconVisibilityToggle(location: .menuBar, isOn: $settings.showsMenuBarIcon)
                IconVisibilityToggle(location: .dock, isOn: $settings.showsDockIcon)
                Toggle("Open usAIge at login", isOn: launchAtLoginBinding)
                    .disabled(!launchAtLogin.isSupported)
                if !launchAtLogin.isSupported {
                    Text("Open at login is available on macOS 13 or later.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()
                Text("iPhone & Apple Watch Sync").font(.headline)
                Text("How it works").font(.subheadline).bold()
                Text("Enter this Mac’s one-time code in usAIge on your iPhone. Open usAIge on the paired Apple Watch to sync its limits.")
                    .font(.caption).foregroundColor(.secondary)
                PhonePairingCard(relaySync: relaySync)
                    .modifier(PhonePairingVisibility(relaySync: relaySync))
                let docks = RelayDeviceDock.list(relaySync.devices, localPhones: relaySync.localDockPhones)
                Text("Device docks").font(.subheadline).bold()
                ForEach(docks.isEmpty ? [.empty] : docks) { dock in
                    GroupBox {
                        HStack(alignment: .top, spacing: 14) {
                            dockSlot(dock.phone, isWatch: false, missing: dock.missingPhoneText(isLinked: relaySync.isLinked))
                            Divider()
                            dockSlot(dock.watch, isWatch: true,
                                     missing: relaySync.isLinked ? "No Apple Watch reported" : "No Apple Watch paired")
                        }
                        .padding(4)
                    }
                }
                if relaySync.isLinked {
                    Text("Connected as \(relaySync.macName)")
                    Button("Refresh devices") { Task { await relaySync.refreshDevices() } }
                    Button("Disconnect All") { Task { await relaySync.disconnectAll() } }
                }

                Divider()
                Text("Software Update").font(.headline)
                Text("Current version \(updateController.currentVersionText)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(updateController.statusText).font(.caption)
                Button("What’s New") {
                    NSApp.sendAction(
                        #selector(AppDelegate.showWhatsNewWindow(_:)),
                        to: nil,
                        from: nil
                    )
                }
                Button(updateController.primaryButtonTitle) {
                    Task { await updateController.performPrimaryAction() }
                }
                .disabled(!updateController.canPerformPrimaryAction)

                Divider()
                Text("Send Feedback").font(.headline)
                TextEditor(text: $feedbackDraft.content)
                    .frame(height: 80)
                Text("Your message is sent with basic system and app details. No account is required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let feedbackStatusMessage {
                    Text(feedbackStatusMessage)
                        .font(.caption)
                        .foregroundColor(feedbackStatusMessage == "Feedback sent. Thank you!" ? .green : .red)
                }
                Button(isSendingFeedback ? "Sending…" : "Send Feedback") {
                    submitFeedback()
                }
                .disabled(!feedbackDraft.canSubmit || isSendingFeedback)

                Divider()
                Text("Visible limits").font(.headline)
                if store.visibleSnapshots.isEmpty {
                    Text("No usage limits available.").foregroundColor(.secondary)
                } else {
                    ForEach(store.visibleSnapshots) { snapshot in
                        Toggle(snapshot.displayName, isOn: visibilityBinding(for: snapshot.id))
                    }
                }
                Button("Refresh usage") { Task { await store.refresh() } }
                Spacer()
                Button("Quit usAIge") { NSApplication.shared.terminate(nil) }
            }
            .padding(24)
        }
    }

    private func dockSlot(_ device: RelayPhoneDevice?, isWatch: Bool, missing: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(isWatch ? "Apple Watch" : "iPhone", systemImage: isWatch ? "applewatch" : "iphone")
                .font(.caption)
            if let device {
                Text(device.name)
                Button("Revoke") { Task { await relaySync.revoke(device) } }
                    .accessibilityLabel("Revoke \(device.name)")
            } else {
                Text(missing)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { settings.opacity }, set: { settings.opacity = $0 })
    }

    private var scaleBinding: Binding<Double> {
        Binding(get: { settings.scale }, set: { settings.scale = $0 })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
    }

    private func submitFeedback() {
        let submission = FeedbackSubmission(content: feedbackDraft.trimmedContent)
        isSendingFeedback = true
        feedbackStatusMessage = nil
        Task {
            do {
                _ = try await FeedbackClient().submit(submission)
                feedbackDraft.content = ""
                feedbackStatusMessage = "Feedback sent. Thank you!"
            } catch {
                feedbackStatusMessage = error.localizedDescription
            }
            isSendingFeedback = false
        }
    }

    private func visibilityBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenBucketIDs.contains(id) },
            set: { visible in
                if visible { settings.hiddenBucketIDs.remove(id) }
                else { settings.hiddenBucketIDs.insert(id) }
            }
        )
    }
}
