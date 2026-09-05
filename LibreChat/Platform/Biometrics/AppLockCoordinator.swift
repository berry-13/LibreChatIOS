import Foundation
import LocalAuthentication

@MainActor
final class AppLockCoordinator {
    private static let enabledKey = "librechat.local-app-lock"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// Whether the device can currently evaluate the authentication policy.
    /// Without a passcode (and without an available biometric fallback) an
    /// enabled lock can never be satisfied.
    func canUnlock() async -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func unlock() async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }
        return try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock your cached LibreChat conversations."
        )
    }
}
