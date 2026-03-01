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
