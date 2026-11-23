import AppKit
import SwiftUI

struct RelayDeviceDock: Identifiable, Equatable {
    let phone: RelayPhoneDevice?
    let watch: RelayPhoneDevice?
    var id: String { watch.map { "watch-" + $0.id } ?? "phone-" + (phone?.id ?? "") }

    static func list(_ devices: [RelayPhoneDevice], localPhones: [String: String] = [:]) -> [Self] {
        let phones = devices.filter { !$0.isWatch }
        let watches = devices.filter(\.isWatch)
        let phoneIDs = Set(phones.map { $0.id.lowercased() })
        func phoneID(for watch: RelayPhoneDevice) -> String? {
            watch.parentPhoneID?.lowercased() ?? localPhones[watch.id.lowercased()]
        }
        let byPhone = Dictionary(grouping: watches, by: phoneID(for:))
        var docks = phones.flatMap { phone -> [Self] in
            guard let matches = byPhone[phone.id.lowercased()] else {
                return [Self(phone: phone, watch: nil)]
            }
            return matches.map { Self(phone: phone, watch: $0) }
        }
        for watch in watches where !phoneIDs.contains(phoneID(for: watch) ?? "") {
            docks.append(Self(phone: nil, watch: watch))
        }
        return docks
    }
}

@available(macOS 14.0, *)
struct ModernDevicesPage: View {
    @ObservedObject var relaySync: RelaySyncController
    var showsHeading = true
    @State private var copied = false
    @State private var confirmsDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                steps
                if case let .failed(message) = relaySync.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let code = relaySync.pairingCode, let expiry = relaySync.pairingExpiresAt, expiry > Date() {
                    pairingCode(code, expiry: expiry)
                }
                deviceDocks
                if relaySync.isLinked { disconnect }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if !showsHeading {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SettingsPageHeightKey.self, value: geometry.size.height)
                    }
                }
            }
        }
        .background(ModernPalette.page)
        .environment(\.interfaceStyle, .modern)
        .task(id: relaySync.pairingCode ?? relaySync.channelID) {
            guard relaySync.isLinked else { return }
            repeat {
                await relaySync.refreshDevices()
                guard let expiry = relaySync.pairingExpiresAt, expiry > Date(),
                      !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
        .confirmationDialog("Disconnect all devices?", isPresented: $confirmsDisconnect) {
            Button("Disconnect All", role: .destructive) { Task { await relaySync.disconnectAll() } }
        } message: {
            Text("This revokes every linked iPhone, Apple Watch and remote AI tool. You can connect again with a new code.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if showsHeading {
                Text("iPhone & Apple Watch")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(relaySync.macName).font(.headline)
            }
            Spacer(minLength: 12)
            if relaySync.isLinked {
                Button("Add iPhone…") { Task { await relaySync.createPairingCode() } }
                    .controlSize(.large)
                    .disabled(isBusy)
            } else {
                Button("Connect iPhone…") { Task { await relaySync.createChannel() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy)
            }
        }
        .padding(.horizontal, 4)
    }

    private var isBusy: Bool {
        if case .connecting = relaySync.status { true } else { false }
    }

    // MARK: Pairing

    private func pairingCode(_ code: String, expiry: Date) -> some View {
        ModernSection(title: "Pairing code",
                      footer: "Enter it in usAIge on your iPhone. It works once and expires at \(expiry.formatted(date: .omitted, time: .shortened)).") {
            HStack(spacing: 12) {
                Text(code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .kerning(4)
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
                Spacer(minLength: 12)
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .padding(.horizontal, ModernMetrics.rowPadding)
            .padding(.vertical, 14)
        }
        .onChange(of: code) { _, _ in copied = false }
    }

    private var steps: some View {
        ModernSection(title: "How it works") {
            stepRow(1, "Choose \(relaySync.isLinked ? "Add iPhone" : "Connect iPhone") to create a one-time code.")
            stepRow(2, "Enter the code in usAIge on your iPhone to receive this Mac’s usage.")
            stepRow(3, "Open usAIge on your paired Apple Watch to sync through that iPhone.")
        }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .systemIndigo))
                .frame(width: ModernMetrics.iconSize, height: ModernMetrics.iconSize)
                .background(Color(nsColor: .systemIndigo).opacity(0.12), in: Circle())
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ModernMetrics.rowPadding)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if number > 1 {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                    .padding(.leading, ModernMetrics.separatorInset)
            }
        }
    }

    private var deviceDocks: some View {
        let docks = RelayDeviceDock.list(relaySync.devices, localPhones: relaySync.localDockPhones)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Device docks").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if case .uploading = relaySync.status {
                    Text("Sending…").font(.caption).foregroundStyle(.secondary)
                } else if let sent = relaySync.lastUploadAt {
                    Text("Last sent \(sent.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if relaySync.isLinked {
                    Button("Refresh") { Task { await relaySync.refreshDevices() } }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 4)
            if docks.isEmpty {
                ModernCard(padding: 16) {
                    Text(relaySync.isLinked ? "Waiting for an iPhone to pair." : "Connect an iPhone to add your first dock.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(docks) { dock in
                ModernCard(padding: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) {
                            phoneSlot(dock).frame(minWidth: 190)
                            Divider()
                            deviceSlot(dock.watch, isWatch: true).frame(minWidth: 190)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            phoneSlot(dock)
                            Divider()
                            deviceSlot(dock.watch, isWatch: true)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("devices.dock.\(dock.id)")
            }
        }
    }

    private var linkedPhones: [RelayPhoneDevice] { relaySync.devices.filter { !$0.isWatch } }

    private func phoneLabel(_ phone: RelayPhoneDevice) -> String {
        guard linkedPhones.contains(where: { $0.id != phone.id && $0.name == phone.name }) else { return phone.name }
        return "\(phone.name) · \(phone.id.suffix(6))"
    }

    private func phoneSlot(_ dock: RelayDeviceDock) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            deviceSlot(dock.phone, isWatch: false, missingPhone: dock.watch?.parentPhoneID == nil
                       ? "Paired iPhone unknown" : "Paired iPhone no longer linked")
            if let watch = dock.watch, watch.parentPhoneID == nil, let channel = relaySync.channelID {
                VStack(alignment: .leading, spacing: 5) {
                    if dock.phone != nil {
                        Text("Chosen on this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    if linkedPhones.isEmpty {
                        Text("Connect an iPhone to choose it for this dock.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Menu(dock.phone == nil ? "Choose iPhone…" : "Change iPhone…") {
                            ForEach(linkedPhones) { phone in
                                Button(phoneLabel(phone)) {
                                    relaySync.chooseDockPhone(phone.id, for: watch.id, in: channel)
                                }
                            }
                            if dock.phone != nil {
                                Divider()
                                Button("Clear choice") {
                                    relaySync.chooseDockPhone(nil, for: watch.id, in: channel)
                                }
                            }
                        }
                        .fixedSize()
                        .controlSize(.small)
                        .help("Group this Watch with an iPhone on this Mac.")
                        .accessibilityLabel("Choose an iPhone for \(watch.name) on this Mac")
                    }
                }
                .padding(.leading, 46)
            }
        }
    }

    private func deviceSlot(_ device: RelayPhoneDevice?, isWatch: Bool,
                            missingPhone: String = "Paired iPhone unknown") -> some View {
        HStack(alignment: .top, spacing: 12) {
            ModernIcon(symbol: isWatch ? "applewatch" : "iphone", color: device == nil ? .gray : .indigo, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(isWatch ? "Apple Watch" : "iPhone").font(.caption).foregroundStyle(.secondary)
                if let device {
                    Text(isWatch ? device.name : phoneLabel(device)).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("Last seen \(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Revoke", role: .destructive) { Task { await relaySync.revoke(device) } }
                        .controlSize(.small)
                        .accessibilityLabel("Revoke \(device.name)")
                } else {
                    Text(isWatch ? "No watch reported" : missingPhone)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disconnect: some View {
        HStack {
            Button("Disconnect All…", role: .destructive) { confirmsDisconnect = true }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
