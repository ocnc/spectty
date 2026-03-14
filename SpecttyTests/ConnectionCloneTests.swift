import XCTest
import SwiftData
import SpecttyKeychain
@testable import Spectty

final class ConnectionCloneTests: XCTestCase {
    func testMakeCloneCopiesConnectionSettingsAndResetsIdentity() {
        let original = ServerConnection(
            name: "Work",
            host: "work.example.com",
            port: 2222,
            username: "ocean",
            transport: .mosh,
            authMethod: .publicKey
        )
        original.profileName = "Solarized"
        original.lastConnected = Date()
        original.startupCommand = "tmux new-session -A -s main"
        original.moshPreset = .troubleshoot
        original.moshServerPath = "/usr/local/bin/mosh-server"
        original.moshUDPPortRange = "60001:60010"
        original.moshCompatibilityMode = true
        original.moshBindFamily = .ipv4
        original.moshIPResolution = .remote
        original.password = "secret"
        original.privateKeyPEM = "PRIVATE KEY"

        let clone = original.makeClone(named: "Work Copy")

        XCTAssertNotEqual(clone.id, original.id)
        XCTAssertEqual(clone.name, "Work Copy")
        XCTAssertEqual(clone.host, original.host)
        XCTAssertEqual(clone.port, original.port)
        XCTAssertEqual(clone.username, original.username)
        XCTAssertEqual(clone.transport, original.transport)
        XCTAssertEqual(clone.authMethod, original.authMethod)
        XCTAssertEqual(clone.profileName, original.profileName)
        XCTAssertEqual(clone.startupCommand, original.startupCommand)
        XCTAssertEqual(clone.moshPreset, original.moshPreset)
        XCTAssertEqual(clone.moshServerPath, original.moshServerPath)
        XCTAssertEqual(clone.moshUDPPortRange, original.moshUDPPortRange)
        XCTAssertEqual(clone.moshCompatibilityMode, original.moshCompatibilityMode)
        XCTAssertEqual(clone.moshBindFamily, original.moshBindFamily)
        XCTAssertEqual(clone.moshIPResolution, original.moshIPResolution)
        XCTAssertEqual(clone.password, original.password)
        XCTAssertEqual(clone.privateKeyPEM, original.privateKeyPEM)
        XCTAssertNil(clone.lastConnected)
    }

    @MainActor
    func testCloneCreatesUniqueCopyName() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let store = ConnectionStore(modelContext: context)

        let original = ServerConnection(
            name: "Work",
            host: "work.example.com",
            port: 22,
            username: "ocean"
        )
        let existingCopy = ServerConnection(
            name: "Work Copy",
            host: "copy.example.com",
            port: 22,
            username: "ocean"
        )

        store.add(original)
        store.add(existingCopy)

        await store.clone(original)

        XCTAssertEqual(store.connections.count, 3)

        let clone = try XCTUnwrap(store.connections.first { $0.name == "Work Copy 2" })
        XCTAssertNotEqual(clone.id, original.id)
        XCTAssertEqual(clone.host, original.host)
        XCTAssertEqual(clone.port, original.port)
        XCTAssertEqual(clone.username, original.username)
        XCTAssertEqual(clone.sortOrder, 2)
        XCTAssertNil(clone.lastConnected)
    }

    @MainActor
    func testDeleteRemovesOnlyDeletedConnectionCredentials() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let store = ConnectionStore(modelContext: context)
        let keychain = KeychainManager()

        let original = ServerConnection(
            name: "Work",
            host: "work.example.com",
            port: 22,
            username: "ocean"
        )
        let clone = original.makeClone(named: "Work Copy")

        store.add(original)
        store.add(clone)

        let originalAccount = "password-\(original.id.uuidString)"
        let cloneAccount = "password-\(clone.id.uuidString)"

        try await keychain.saveOrUpdate(key: Data("original-secret".utf8), account: originalAccount)
        try await keychain.saveOrUpdate(key: Data("clone-secret".utf8), account: cloneAccount)

        await store.delete(original)

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connections.first?.id, clone.id)
        let originalCredential = try await keychain.load(account: originalAccount)
        XCTAssertNil(originalCredential)

        let cloneCredential = try await keychain.load(account: cloneAccount)
        let cloneData = try XCTUnwrap(cloneCredential)
        XCTAssertEqual(String(data: cloneData, encoding: .utf8), "clone-secret")

        try await keychain.delete(account: cloneAccount)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SpecttySchemaV4.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: schema,
            migrationPlan: SpecttyMigrationPlan.self,
            configurations: [config]
        )
    }
}
