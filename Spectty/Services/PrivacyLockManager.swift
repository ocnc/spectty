import Foundation
import LocalAuthentication
import CryptoKit
import SpecttyKeychain

@Observable
@MainActor
final class PrivacyLockManager {

    private(set) var isLocked: Bool
    private(set) var hasPIN = false
    private(set) var biometricsAvailable = false
    private(set) var biometricType: LABiometryType = .none

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "privacyModeEnabled")
    }


    private let keychain = KeychainManager()
    private static let pinAccount = "privacy-mode-pin"

    init() {
        // Synchronously lock if enabled to prevent flash of unlocked content
        isLocked = UserDefaults.standard.bool(forKey: "privacyModeEnabled")
        Task { await refreshState() }
    }

    // MARK: - State

    func refreshState() async {
        let context = LAContext()
        var error: NSError?
        biometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometricType = context.biometryType

        do {
            let data = try await keychain.load(account: Self.pinAccount)
            hasPIN = data != nil
        } catch {
            hasPIN = false
        }

        // Refine lock state: stay locked only if enabled AND a PIN exists
        if isEnabled && hasPIN {
            isLocked = true
        } else {
            isLocked = false
        }
    }

    // MARK: - Scene Phase

    func appDidEnterBackground() {
        if isEnabled && hasPIN {
            isLocked = true
        }
    }

    func appDidBecomeActive() {
        let biometricUnlock = UserDefaults.standard.bool(forKey: "biometricUnlockEnabled")
        if isLocked && biometricUnlock && biometricsAvailable {
            attemptBiometricUnlock()
        }
    }

    // MARK: - Biometrics

    func attemptBiometricUnlock() {
        let context = LAContext()
        context.localizedCancelTitle = "Enter PIN"
        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Unlock Spectty"
                )
                if success {
                    isLocked = false
                }
            } catch {
                // User cancelled or biometrics failed — they can use PIN
            }
        }
    }

    // MARK: - PIN

    func setPIN(_ pin: String) async throws {
        let hash = SHA256.hash(data: Data(pin.utf8))
        let hashData = Data(hash)
        try await keychain.saveOrUpdate(key: hashData, account: Self.pinAccount)
        hasPIN = true
    }

    func verifyPIN(_ pin: String) async -> Bool {
        guard let stored = try? await keychain.load(account: Self.pinAccount) else {
            return false
        }
        let hash = Data(SHA256.hash(data: Data(pin.utf8)))
        return hash == stored
    }

    func unlockWithPIN(_ pin: String) async -> Bool {
        let correct = await verifyPIN(pin)
        if correct {
            isLocked = false
        }
        return correct
    }

    func removePIN() async throws {
        try await keychain.delete(account: Self.pinAccount)
        hasPIN = false
        isLocked = false
    }
}
