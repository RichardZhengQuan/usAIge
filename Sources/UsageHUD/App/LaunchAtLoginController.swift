import Observation
import ServiceManagement

protocol LaunchAtLoginServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServicing {}

@MainActor
@Observable
final class LaunchAtLoginController {
    private let service: any LaunchAtLoginServicing

    private(set) var isEnabled = false
    private(set) var requiresApproval = false
    private(set) var errorMessage: String?

    init(service: any LaunchAtLoginServicing = SMAppService.mainApp) {
        self.service = service
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
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
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
