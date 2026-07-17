import Foundation
import Testing
@testable import UsageHUD

@MainActor
@Test func enablingLaunchAtLoginRegistersTheMainApp() {
    let service = LaunchAtLoginServiceStub(status: .notRegistered)
    let controller = LaunchAtLoginController(service: service, defaults: initializedDefaults())

    controller.setEnabled(true)

    #expect(service.registerCallCount == 1)
    #expect(controller.isEnabled)
    #expect(controller.errorMessage == nil)
}

@MainActor
@Test func disablingLaunchAtLoginUnregistersTheMainApp() {
    let service = LaunchAtLoginServiceStub(status: .enabled)
    let controller = LaunchAtLoginController(service: service, defaults: initializedDefaults())

    controller.setEnabled(false)

    #expect(service.unregisterCallCount == 1)
    #expect(!controller.isEnabled)
}

@MainActor
@Test func launchAtLoginSurfacesRequiredUserApproval() {
    let service = LaunchAtLoginServiceStub(status: .notRegistered)
    service.statusAfterRegister = .requiresApproval
    let controller = LaunchAtLoginController(service: service, defaults: initializedDefaults())

    controller.setEnabled(true)

    #expect(controller.requiresApproval)
    #expect(controller.errorMessage?.contains("Login Items") == true)
}

@MainActor
@Test func launchAtLoginIsEnabledByDefaultOnlyOnce() {
    let defaults = isolatedDefaults()
    let firstService = LaunchAtLoginServiceStub(status: .notRegistered)

    let firstController = LaunchAtLoginController(service: firstService, defaults: defaults)

    #expect(firstService.registerCallCount == 1)
    #expect(firstController.isEnabled)

    firstController.setEnabled(false)
    let secondService = LaunchAtLoginServiceStub(status: .notRegistered)
    let secondController = LaunchAtLoginController(service: secondService, defaults: defaults)

    #expect(secondService.registerCallCount == 0)
    #expect(!secondController.isEnabled)
}

private func initializedDefaults() -> UserDefaults {
    let defaults = isolatedDefaults()
    defaults.set(true, forKey: "usageHUD.launchAtLoginDefaultApplied.v1")
    return defaults
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "LaunchAtLoginControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private final class LaunchAtLoginServiceStub: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var statusAfterRegister: LaunchAtLoginStatus = .enabled
    var registerCallCount = 0
    var unregisterCallCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }
}
