import AppKit
import Combine
import SwiftUI

struct PhonePairingVisibility: ViewModifier {
    let relaySync: RelaySyncController
    @State private var viewID = UUID()

    func body(content: Content) -> some View {
        content
            .background(RailPaperweightVisibility { visible in
                relaySync.setPhonePairingVisible(visible, for: viewID)
            })
            .onDisappear { relaySync.setPhonePairingVisible(false, for: viewID) }
    }
}

struct PhonePairingCard: View {
    @ObservedObject var relaySync: RelaySyncController
    @Environment(\.interfaceStyle) private var interfaceStyle
    @State private var copiedCode: String?
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if #available(macOS 14.0, *), interfaceStyle == .modern {
                ModernCard { contents }
            } else {
                GroupBox { contents.padding(6) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devices.phone-pairing")
        .onAppear { now = Date() }
        .onChange(of: relaySync.pairingCode) { _ in copiedCode = nil; now = Date() }
        .onReceive(clock) { date in
            if let expiry = relaySync.pairingExpiresAt, now < expiry, date >= expiry { now = date }
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pairing code").font(.headline).accessibilityAddTraits(.isHeader)
            if case let .failed(message) = relaySync.phonePairingState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: connectOrRetry)
            } else if relaySync.phonePairingState == .connecting || relaySync.status == .connecting {
                ProgressView("Getting a pairing code…").controlSize(.small)
            } else if !relaySync.isLinked {
                Text("Enable sync to share this Mac’s usage and session status through the usAIge relay.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Enable Device Sync", action: connectOrRetry)
                    .accessibilityIdentifier("devices.pair-iphone")
            } else if relaySync.needsPhonePairingCheck {
                ProgressView("Checking pairing code…").controlSize(.small)
            } else if let invitation = relaySync.validPhonePairing(at: now) {
                HStack(spacing: 12) {
                    Text(verbatim: invitation.code)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .kerning(3)
                        .accessibilityLabel("Pairing code \(invitation.code.map(String.init).joined(separator: " "))")
                    Spacer(minLength: 6)
                    Button {
                        guard relaySync.phonePairingState == .idle, !relaySync.needsPhonePairingCheck,
                              relaySync.validPhonePairing(at: Date())?.code == invitation.code else { return }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        if pasteboard.setString(invitation.code, forType: .string) { copiedCode = invitation.code }
                    } label: {
                        let copied = copiedCode == invitation.code
                        Label(LocalizedStringKey(copied ? "Copied" : "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                Text("One-time code · Expires at \(invitation.expiry, style: .time)")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ProgressView(relaySync.pairingExpiresAt == nil ? "Getting a pairing code…" : "Renewing expired code…")
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectOrRetry() {
        if relaySync.isLinked { relaySync.startVisiblePhonePairing() }
        else { Task { await relaySync.createPairingCode() } }
    }
}

struct RelayDeviceDock: Identifiable, Equatable {
    let phone: RelayPhoneDevice?
    let watch: RelayPhoneDevice?
    static let empty = Self(phone: nil, watch: nil)

    var id: String { watch.map { "watch-" + $0.id } ?? phone.map { "phone-" + $0.id } ?? "empty" }

    func missingPhoneText(isLinked: Bool) -> String {
        guard let watch else { return isLinked ? "No iPhone reported" : "No iPhone paired" }
        return watch.parentPhoneID == nil ? "Paired iPhone unknown" : "Paired iPhone no longer linked"
    }

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
    @Environment(\.locale) private var locale
    @ObservedObject var relaySync: RelaySyncController
    var showsHeading = true
    @State private var confirmsDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                steps
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
        .modifier(PhonePairingVisibility(relaySync: relaySync))
        .confirmationDialog("Disconnect all devices?", isPresented: $confirmsDisconnect) {
            Button("Disconnect All", role: .destructive) { Task { await relaySync.disconnectAll() } }
        } message: {
            Text("This revokes every linked iPhone, Apple Watch and remote AI tool. You can connect again with a new code.")
        }
    }

    private var header: some View {
        Group {
            if showsHeading {
                Text("iPhone & Apple Watch")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(relaySync.macName).font(.headline)
            }
        }
        .padding(.horizontal, 4)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("How it works").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Enter the code below in usAIge on your iPhone. Open usAIge on its paired Apple Watch to sync through that iPhone.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            PhonePairingCard(relaySync: relaySync)
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
                    Text("Last sent \(sent.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if relaySync.isLinked {
                    Button("Refresh") { Task { await relaySync.refreshDevices() } }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 4)
            if case let .failed(message) = relaySync.status, relaySync.phonePairingState != .failed(message) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(docks.isEmpty ? [.empty] : docks) { dock in
                ModernCard(padding: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
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
            deviceSlot(dock.phone, isWatch: false, missingPhone: dock.missingPhoneText(isLinked: relaySync.isLinked))
            if let watch = dock.watch, watch.parentPhoneID == nil, let channel = relaySync.channelID {
                VStack(alignment: .leading, spacing: 5) {
                    if dock.phone != nil {
                        Text("Chosen on this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    if linkedPhones.isEmpty {
                        Text("Connect an iPhone to choose it for this dock.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Menu(LocalizedStringKey(dock.phone == nil ? "Choose iPhone…" : "Change iPhone…")) {
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
                    Text("Last seen \(device.lastSeenAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Revoke", role: .destructive) { Task { await relaySync.revoke(device) } }
                        .controlSize(.small)
                        .accessibilityLabel("Revoke \(device.name)")
                } else {
                    Text(LocalizedStringKey(isWatch ? (relaySync.isLinked ? "No Apple Watch reported" : "No Apple Watch paired") : missingPhone),
                         bundle: AppLanguage.resourceBundle)
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
