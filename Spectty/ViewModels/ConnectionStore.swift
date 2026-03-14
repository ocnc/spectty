import Foundation
import OSLog
import SwiftData
import SpecttyKeychain

/// Manages persistence of server connections using SwiftData.
@Observable
@MainActor
final class ConnectionStore {
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.oceancheung.spectty-terminal", category: "ConnectionStore")
    private let keychain = KeychainManager()

    var connections: [ServerConnection] = []

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        fetchConnections()
    }

    func fetchConnections() {
        let descriptor = FetchDescriptor<ServerConnection>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        do {
            let fetched = try modelContext.fetch(descriptor)
            connections = fetched
        } catch {
            connections = []
            logPersistenceError("Failed to fetch connections: \(error)")
        }
    }

    func add(_ connection: ServerConnection) {
        connection.sortOrder = connections.count
        modelContext.insert(connection)
        do {
            try modelContext.save()
        } catch {
            logPersistenceError("Failed to save new connection: \(error)")
        }
        fetchConnections()
    }

    func clone(_ connection: ServerConnection) async {
        let clone = connection.makeClone()
        await copyCredentials(from: connection, to: clone)
        clone.name = makeUniqueCloneName(from: connection)
        add(clone)
    }

    func delete(_ connection: ServerConnection) async {
        let credentialAccounts = keychainAccounts(for: connection)
        modelContext.delete(connection)
        do {
            try modelContext.save()
        } catch {
            logPersistenceError("Failed to delete connection: \(error)")
            fetchConnections()
            return
        }

        await deleteCredentials(accounts: credentialAccounts)
        fetchConnections()
    }

    func save() {
        do {
            try modelContext.save()
        } catch {
            logPersistenceError("Failed to save connections: \(error)")
        }
        fetchConnections()
    }

    private func logPersistenceError(_ message: String) {
        logger.error("\(message)")
    }

    private func makeUniqueCloneName(from connection: ServerConnection) -> String {
        let existingNames = Set(connections.map(\.displayName))
        let baseName = connection.displayName.isEmpty ? "Connection" : connection.displayName
        var candidate = "\(baseName) Copy"
        var copyNumber = 2

        while existingNames.contains(candidate) {
            candidate = "\(baseName) Copy \(copyNumber)"
            copyNumber += 1
        }

        return candidate
    }

    private func copyCredentials(from source: ServerConnection, to clone: ServerConnection) async {
        switch source.authMethod {
        case .password, .keyboardInteractive:
            clone.privateKeyKeychainAccount = nil

            let credentialData: Data?
            if !source.password.isEmpty {
                credentialData = Data(source.password.utf8)
            } else {
                credentialData = try? await keychain.load(account: "password-\(source.id.uuidString)")
            }

            guard let credentialData else {
                clone.passwordKeychainAccount = nil
                return
            }

            let targetAccount = "password-\(clone.id.uuidString)"
            do {
                try await keychain.saveOrUpdate(key: credentialData, account: targetAccount)
                clone.passwordKeychainAccount = targetAccount
            } catch {
                clone.passwordKeychainAccount = nil
                logPersistenceError("Failed to clone password credential: \(error)")
            }

        case .publicKey:
            clone.passwordKeychainAccount = nil

            let keyData: Data?
            if !source.privateKeyPEM.isEmpty {
                keyData = Data(source.privateKeyPEM.utf8)
            } else {
                keyData = try? await keychain.load(account: "private-key-\(source.id.uuidString)")
            }

            guard let keyData else {
                clone.privateKeyKeychainAccount = nil
                return
            }

            let targetAccount = "private-key-\(clone.id.uuidString)"
            do {
                try await keychain.saveOrUpdate(key: keyData, account: targetAccount)
                clone.privateKeyKeychainAccount = targetAccount
            } catch {
                clone.privateKeyKeychainAccount = nil
                logPersistenceError("Failed to clone private key credential: \(error)")
            }
        }
    }

    private func keychainAccounts(for connection: ServerConnection) -> [String] {
        let uuid = connection.id.uuidString
        let accounts = [
            connection.passwordKeychainAccount,
            connection.privateKeyKeychainAccount,
            "password-\(uuid)",
            "private-key-\(uuid)"
        ]

        return Array(Set(accounts.compactMap { $0 }))
    }

    private func deleteCredentials(accounts: [String]) async {
        for account in accounts {
            do {
                try await keychain.delete(account: account)
            } catch {
                logPersistenceError("Failed to delete credential for account \(account): \(error)")
            }
        }
    }
}
