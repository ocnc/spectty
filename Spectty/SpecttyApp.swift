import SwiftUI
import SwiftData

@main
struct SpecttyApp: App {
    @State private var sessionManager = SessionManager()
    @State private var lockManager = PrivacyLockManager()
    @Environment(\.scenePhase) private var scenePhase

    var sharedModelContainer: ModelContainer = {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let schema = Schema(versionedSchema: SpecttySchemaV4.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isRunningTests)
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: SpecttyMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentRoot()
                .environment(sessionManager)
                .environment(lockManager)
                .task {
                    await sessionManager.autoResumeSessions()
                }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { @MainActor in
                    await sessionManager.checkAllConnections()
                    lockManager.appDidBecomeActive()
                }
            }
            if newPhase == .background {
                Task { @MainActor in
                    await sessionManager.saveActiveSessions()
                    lockManager.appDidEnterBackground()
                }
            }
        }
    }
}

/// Root view that injects the ConnectionStore once the model context is available.
private struct ContentRoot: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Environment(PrivacyLockManager.self) private var lockManager
    @State private var connectionStore: ConnectionStore?

    var body: some View {
        ZStack {
            Group {
                if let store = connectionStore {
                    ConnectionListView()
                        .environment(store)
                } else {
                    ProgressView()
                }
            }

            if lockManager.isLocked {
                LockScreenView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: lockManager.isLocked)
        .onAppear {
            if connectionStore == nil {
                connectionStore = ConnectionStore(modelContext: modelContext)
            }
        }
    }
}
