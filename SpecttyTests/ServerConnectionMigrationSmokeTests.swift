import XCTest
import SwiftData
@testable import Spectty

final class ServerConnectionMigrationSmokeTests: XCTestCase {
    func testV1StoreMigratesToLatestSchema() throws {
        let storeURL = try makeStoreURL(testName: #function)

        let legacySchema = Schema(versionedSchema: SpecttySchemaV1.self)
        let legacyConfig = ModelConfiguration(schema: legacySchema, url: storeURL)
        let legacyContainer = try ModelContainer(for: legacySchema, configurations: [legacyConfig])
        let legacyContext = ModelContext(legacyContainer)

        let legacy = SpecttySchemaV1.ServerConnection(
            name: "Legacy",
            host: "legacy.example.com",
            port: 22,
            username: "ocean",
            transport: .mosh,
            authMethod: .password
        )
        legacyContext.insert(legacy)
        try legacyContext.save()

        let migratedContainer = try makeLatestContainer(storeURL: storeURL)
        let migratedContext = ModelContext(migratedContainer)
        let fetched = try migratedContext.fetch(FetchDescriptor<ServerConnection>())

        XCTAssertEqual(fetched.count, 1)
        let connection = try XCTUnwrap(fetched.first)
        XCTAssertEqual(connection.name, "Legacy")
        XCTAssertEqual(connection.host, "legacy.example.com")
        XCTAssertEqual(connection.username, "ocean")
        XCTAssertEqual(connection.moshPreset, .standard)
        XCTAssertEqual(connection.moshCompatibilityMode, false)
        XCTAssertEqual(connection.moshBindFamily, .automatic)
        XCTAssertEqual(connection.moshIPResolution, .default)
    }

    func testV2StoreMigratesToLatestSchema() throws {
        let storeURL = try makeStoreURL(testName: #function)

        let v2Schema = Schema(versionedSchema: SpecttySchemaV2.self)
        let v2Config = ModelConfiguration(schema: v2Schema, url: storeURL)
        let v2Container = try ModelContainer(for: v2Schema, configurations: [v2Config])
        let v2Context = ModelContext(v2Container)

        let v2Connection = SpecttySchemaV2.ServerConnection(
            name: "V2Connection",
            host: "v2.example.com",
            port: 22,
            username: "v2user",
            transport: .mosh,
            authMethod: .password
        )
        v2Connection.moshPreset = .strictNetwork
        v2Connection.moshCompatibilityMode = false
        v2Connection.moshBindFamily = .ipv4
        v2Connection.moshIPResolution = .local
        v2Context.insert(v2Connection)
        try v2Context.save()

        let migratedContainer = try makeLatestContainer(storeURL: storeURL)
        let migratedContext = ModelContext(migratedContainer)
        let fetched = try migratedContext.fetch(FetchDescriptor<ServerConnection>())

        XCTAssertEqual(fetched.count, 1)
        let connection = try XCTUnwrap(fetched.first)
        XCTAssertEqual(connection.name, "V2Connection")
        XCTAssertEqual(connection.host, "v2.example.com")
        XCTAssertEqual(connection.username, "v2user")
        XCTAssertEqual(connection.moshPreset, .strictNetwork)
        XCTAssertEqual(connection.moshCompatibilityMode, false)
        XCTAssertEqual(connection.moshBindFamily, .ipv4)
        XCTAssertEqual(connection.moshIPResolution, .local)
    }

    func testV3NilMoshFieldsAreBackfilledDuringMigration() throws {
        let storeURL = try makeStoreURL(testName: #function)

        let transitionalSchema = Schema(versionedSchema: SpecttySchemaV3.self)
        let transitionalConfig = ModelConfiguration(schema: transitionalSchema, url: storeURL)
        let transitionalContainer = try ModelContainer(for: transitionalSchema, configurations: [transitionalConfig])
        let transitionalContext = ModelContext(transitionalContainer)

        let transitional = SpecttySchemaV3.ServerConnection(
            name: "NeedsFix",
            host: "nil.example.com",
            port: 22,
            username: "root",
            transport: .mosh,
            authMethod: .password
        )
        transitional.moshPreset = nil
        transitional.moshCompatibilityMode = nil
        transitional.moshBindFamily = nil
        transitional.moshIPResolution = nil
        transitionalContext.insert(transitional)
        try transitionalContext.save()

        let migratedContainer = try makeLatestContainer(storeURL: storeURL)
        let migratedContext = ModelContext(migratedContainer)
        let fetched = try migratedContext.fetch(FetchDescriptor<ServerConnection>())

        XCTAssertEqual(fetched.count, 1)
        let connection = try XCTUnwrap(fetched.first)
        XCTAssertEqual(connection.name, "NeedsFix")
        XCTAssertEqual(connection.moshPreset, .standard)
        XCTAssertEqual(connection.moshCompatibilityMode, false)
        XCTAssertEqual(connection.moshBindFamily, .automatic)
        XCTAssertEqual(connection.moshIPResolution, .default)
    }

    private func makeLatestContainer(storeURL: URL) throws -> ModelContainer {
        let latestSchema = Schema(versionedSchema: SpecttySchemaV4.self)
        let latestConfig = ModelConfiguration(schema: latestSchema, url: storeURL)
        return try ModelContainer(
            for: latestSchema,
            migrationPlan: SpecttyMigrationPlan.self,
            configurations: [latestConfig]
        )
    }

    private func makeStoreURL(testName: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SpecttyMigrationSmoke-\(testName)-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: directory)
        }

        return directory.appendingPathComponent("Spectty.sqlite", isDirectory: false)
    }
}
