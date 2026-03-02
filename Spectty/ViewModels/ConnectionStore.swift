import Foundation
import OSLog
import SwiftData

/// Manages persistence of server connections using SwiftData.
@Observable
@MainActor
final class ConnectionStore {
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.oceancheung.spectty-terminal", category: "ConnectionStore")

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

    func delete(_ connection: ServerConnection) {
        modelContext.delete(connection)
        do {
            try modelContext.save()
        } catch {
            logPersistenceError("Failed to delete connection: \(error)")
        }
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
}
