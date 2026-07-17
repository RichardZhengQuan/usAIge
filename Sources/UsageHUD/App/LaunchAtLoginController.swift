import AppKit
import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus {
    case notRegistered
    case enabled
    case requiresApproval
}

protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@available(macOS 13.0, *)
private final class ModernLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .notRegistered
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    private static let defaultAppliedKey = "usageHUD.launchAtLoginDefaultApplied.v1"

    private let service: (any LaunchAtLoginServicing)?
    private let defaults: UserDefaults

    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    var isSupported: Bool { service != nil }

    init(
        service: (any LaunchAtLoginServicing)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        if let service {
            self.service = service
        } else if #available(macOS 13.0, *) {
            self.service = ModernLaunchAtLoginService()
        } else {
            self.service = nil
        }
        refresh()
        enableByDefaultIfNeeded()
    }

    func setEnabled(_ enabled: Bool) {
        guard let service else {
            errorMessage = "Open at login requires macOS 13 or later."
            return
        }
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
            if requiresApproval {
                errorMessage = "Approve usAIge in System Settings > General > Login Items."
            }
        } catch {
            refresh()
            errorMessage = "Could not update Login Items: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard let service else {
            isEnabled = false
            requiresApproval = false
            return
        }
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func openSystemSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func enableByDefaultIfNeeded() {
        guard defaults.object(forKey: Self.defaultAppliedKey) == nil else { return }
        defaults.set(true, forKey: Self.defaultAppliedKey)
        guard service?.status == .notRegistered else { return }
        setEnabled(true)
    }
}
