import Foundation
import SpecttyKeychain
import SpecttyTransport

/// Keychain-backed persistence for Mosh session state.
/// Enables session resumption after app termination.
final class MoshSessionStore: Sendable {
    private let keychain = KeychainManager()
    private static let accountPrefix = "mosh-session-"
    private static let indexAccount = "mosh-session-index"

    /// Save a session state to the Keychain.
    func save(_ state: MoshSessionState) async throws {
        let data = try JSONEncoder().encode(state)
        let account = Self.accountPrefix + state.sessionID
        try await keychain.saveOrUpdate(key: data, account: account)

        // Update index
        var ids = await loadIndex()
        if !ids.contains(state.sessionID) {
            ids.append(state.sessionID)
            await saveIndex(ids)
        }
    }

    /// Load all saved session states from the Keychain.
    func loadAll() async -> [MoshSessionState] {
        let ids = await loadIndex()
        var results: [MoshSessionState] = []
        for id in ids {
            let account = Self.accountPrefix + id
            guard let data = try? await keychain.load(account: account),
                  let state = try? JSONDecoder().decode(MoshSessionState.self, from: data) else {
                continue
            }
            results.append(state)
        }
        return results
    }

    /// Remove a session state from the Keychain.
    func remove(sessionID: String) async {
        let account = Self.accountPrefix + sessionID
        try? await keychain.delete(account: account)

        var ids = await loadIndex()
        ids.removeAll { $0 == sessionID }
        await saveIndex(ids)
    }

    /// Remove all saved session states.
    func removeAll() async {
        let ids = await loadIndex()
        for id in ids {
            let account = Self.accountPrefix + id
            try? await keychain.delete(account: account)
        }
        await saveIndex([])
    }

    // MARK: - Index Management

    private func loadIndex() async -> [String] {
        guard let data = try? await keychain.load(account: Self.indexAccount),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }

    private func saveIndex(_ ids: [String]) async {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? await keychain.saveOrUpdate(key: data, account: Self.indexAccount)
    }
}
