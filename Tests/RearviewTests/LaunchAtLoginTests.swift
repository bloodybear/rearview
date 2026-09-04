import ServiceManagement
import Testing
@testable import Rearview

@Suite
struct LaunchAtLoginTests {
    @Test
    func defaultsRoundTrip() {
        withTestDefaults { defaults in
            #expect(LaunchAtLogin.load(from: defaults) == AppDefaults.launchAtLogin)

            LaunchAtLogin.save(false, to: defaults)
            #expect(!LaunchAtLogin.load(from: defaults))

            LaunchAtLogin.save(true, to: defaults)
            #expect(LaunchAtLogin.load(from: defaults))
        }
    }

    @Test
    func actionOnlyChangesTheActualServiceState() {
        #expect(LaunchAtLogin.action(for: true, status: .notRegistered) == .register)
        #expect(LaunchAtLogin.action(for: true, status: .requiresApproval) == .register)
        #expect(LaunchAtLogin.action(for: true, status: .enabled) == .none)
        #expect(LaunchAtLogin.action(for: false, status: .enabled) == .unregister)
        #expect(LaunchAtLogin.action(for: false, status: .notRegistered) == .none)
        #expect(LaunchAtLogin.action(for: false, status: .notFound) == .none)
    }

    @Test
    func onlyEnabledStatusTurnsTheSettingOn() {
        #expect(LaunchAtLogin.isEnabled(.enabled))
        #expect(!LaunchAtLogin.isEnabled(.notRegistered))
        #expect(!LaunchAtLogin.isEnabled(.requiresApproval))
        #expect(!LaunchAtLogin.isEnabled(.notFound))
    }
}
