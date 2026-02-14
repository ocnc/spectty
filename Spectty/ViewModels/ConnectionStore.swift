import Foundation
import SwiftData

/// Manages persistence of server connections using SwiftData.
@Observable
@MainActor
final class ConnectionStore {
    private let modelContext: ModelContext

    var connections: [ServerConnection] = []

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        fetchConnections()
    }

    func fetchConnections() {
        let descriptor = FetchDescriptor<ServerConnection>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        connections = (try? modelContext.fetch(descriptor)) ?? []
    }

    func add(_ connection: ServerConnection) {
        connection.sortOrder = connections.count
        modelContext.insert(connection)
        try? modelContext.save()
        fetchConnections()
    }

    func delete(_ connection: ServerConnection) {
        modelContext.delete(connection)
        try? modelContext.save()
        fetchConnections()
    }

    func save() {
        try? modelContext.save()
        fetchConnections()
    }
}
