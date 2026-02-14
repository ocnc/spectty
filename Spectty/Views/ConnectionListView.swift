import SwiftUI
import SwiftData

struct ConnectionListView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(ConnectionStore.self) private var connectionStore
    @State private var editingConnection: ServerConnection?
    @State private var isNewConnection = false
    @State private var showingQuickConnect = false
    @State private var quickConnectHost = ""
    @State private var navigationPath = NavigationPath()
    @State private var connectionError: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if !sessionManager.sessions.isEmpty {
                    Section("Active Sessions") {
                        ForEach(sessionManager.sessions) { session in
                            Button {
                                sessionManager.activeSessionID = session.id
                                navigationPath.append(session.id)
                            } label: {
                                HStack {
                                    Image(systemName: "terminal")
                                        .foregroundStyle(.green)
                                    VStack(alignment: .leading) {
                                        Text(session.connectionName)
                                            .font(.body)
                                        if !session.title.isEmpty {
                                            Text(session.title)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Connections") {
                    ForEach(connectionStore.connections) { connection in
                        Button {
                            connectTo(connection)
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(connection.name.isEmpty ? connection.host : connection.name)
                                        .font(.body)
                                    Text("\(connection.username)@\(connection.host):\(connection.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(connection.transport.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                        .contextMenu {
                            Button("Edit") {
                                isNewConnection = false
                                editingConnection = connection
                            }
                            Button("Delete", role: .destructive) {
                                connectionStore.delete(connection)
                            }
                        }
                    }

                    if connectionStore.connections.isEmpty {
                        ContentUnavailableView(
                            "No Connections",
                            systemImage: "server.rack",
                            description: Text("Tap + to add a new connection")
                        )
                    }
                }
            }
            .navigationTitle("Spectty")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isNewConnection = true
                            editingConnection = ServerConnection()
                        } label: {
                            Label("New Connection", systemImage: "plus")
                        }
                        Button {
                            showingQuickConnect = true
                        } label: {
                            Label("Quick Connect", systemImage: "bolt")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editingConnection) { connection in
                ConnectionEditorView(connection: connection, isNew: isNewConnection) { saved in
                    if isNewConnection {
                        connectionStore.add(saved)
                    } else {
                        connectionStore.save()
                    }
                    editingConnection = nil
                    isNewConnection = false
                }
            }
            .alert("Quick Connect", isPresented: $showingQuickConnect) {
                TextField("user@host", text: $quickConnectHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") {
                    quickConnect()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter user@host or user@host:port")
            }
            .navigationDestination(for: UUID.self) { sessionID in
                if let session = sessionManager.sessions.first(where: { $0.id == sessionID }) {
                    TerminalSessionView(session: session)
                }
            }
            .alert("Connection Failed", isPresented: .init(
                get: { connectionError != nil },
                set: { if !$0 { connectionError = nil } }
            )) {
                Button("OK") { connectionError = nil }
            } message: {
                if let error = connectionError {
                    Text(error)
                }
            }
        }
    }

    private func connectTo(_ connection: ServerConnection) {
        Task {
            do {
                let session = try await sessionManager.connect(to: connection)
                connection.lastConnected = Date()
                connectionStore.save()
                navigationPath.append(session.id)
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }

    private func quickConnect() {
        let input = quickConnectHost.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }

        var username = "root"
        var host = input
        var port = 22

        if let atIndex = input.firstIndex(of: "@") {
            username = String(input[input.startIndex..<atIndex])
            host = String(input[input.index(after: atIndex)...])
        }

        if let colonIndex = host.lastIndex(of: ":") {
            let portStr = String(host[host.index(after: colonIndex)...])
            if let p = Int(portStr) {
                port = p
                host = String(host[host.startIndex..<colonIndex])
            }
        }

        let connection = ServerConnection(
            name: "",
            host: host,
            port: port,
            username: username
        )
        connectTo(connection)
    }
}
