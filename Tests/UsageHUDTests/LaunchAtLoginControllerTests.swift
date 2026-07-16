import Testing
@testable import UsageHUD

@MainActor
@Test func enablingLaunchAtLoginRegistersTheMainApp() {
    let service = LaunchAtLoginServiceStub(status: .notRegistered)
    let controller = LaunchAtLoginController(service: service)

    controller.setEnabled(true)

    #expect(service.registerCallCount == 1)
    #expect(controller.isEnabled)
    #expect(controller.errorMessage == nil)
}

@MainActor
@Test func disablingLaunchAtLoginUnregistersTheMainApp() {
    let service = LaunchAtLoginServiceStub(status: .enabled)
    let controller = LaunchAtLoginController(service: service)

    controller.setEnabled(false)

    #expect(service.unregisterCallCount == 1)
    #expect(!controller.isEnabled)
}

@MainActor
@Test func launchAtLoginSurfacesRequiredUserApproval() {
    let service = LaunchAtLoginServiceStub(status: .notRegistered)
    service.statusAfterRegister = .requiresApproval
    let controller = LaunchAtLoginController(service: service)

    controller.setEnabled(true)

    #expect(controller.requiresApproval)
    #expect(controller.errorMessage?.contains("Login Items") == true)
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
