import SwiftUI
import SwiftData

@main
struct SpecttyApp: App {
    @State private var sessionManager = SessionManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([ServerConnection.self, TerminalProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentRoot()
                .environment(sessionManager)
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Root view that injects the ConnectionStore once the model context is available.
private struct ContentRoot: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @State private var connectionStore: ConnectionStore?

    var body: some View {
        Group {
            if let store = connectionStore {
                ConnectionListView()
                    .environment(store)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if connectionStore == nil {
                connectionStore = ConnectionStore(modelContext: modelContext)
            }
        }
    }
}
