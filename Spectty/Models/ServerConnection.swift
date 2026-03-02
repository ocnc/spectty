import Foundation
import SwiftData

/// Transport type for a server connection.
enum TransportType: String, Codable, CaseIterable, Sendable {
    case ssh = "SSH"
    case mosh = "Mosh"
}

/// Authentication method for connecting.
enum AuthMethod: String, Codable, CaseIterable, Sendable {
    case password = "Password"
    case publicKey = "Public Key"
    case keyboardInteractive = "Keyboard Interactive"

    /// Cases shown in the connection editor picker.
    /// `keyboardInteractive` is kept for SwiftData backwards compatibility
    /// but not offered in the UI (it behaves identically to `.password`).
    static let visibleCases: [AuthMethod] = [.password, .publicKey]
}

/// Lightweight Mosh preset for balancing defaults vs advanced behavior.
enum MoshPreset: String, Codable, CaseIterable, Sendable {
    case standard = "Standard"
    case strictNetwork = "Strict Network"
    case troubleshoot = "Troubleshoot"

    var summary: String {
        switch self {
        case .standard:
            return "Default settings for normal networks."
        case .strictNetwork:
            return "Prefers IPv4 and local IP resolution to reduce mixed-stack issues."
        case .troubleshoot:
            return "Disables PTY, forces IPv4, and uses remote-reported IP for maximum compatibility."
        }
    }
}

/// Address family to request for mosh-server bind (-i).
enum MoshBindFamilySetting: String, Codable, CaseIterable, Sendable {
    case automatic = "Automatic"
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

/// How UDP target IP is selected after bootstrap.
enum MoshIPResolutionSetting: String, Codable, CaseIterable, Sendable {
    case `default` = "Default"
    case local = "Local"
    case remote = "Remote"
}

enum SpecttySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ServerConnection.self]
    }

    /// Persistent model for a saved server connection (pre-mosh fields).
    @Model
    final class ServerConnection {
        var id: UUID
        var name: String
        var host: String
        var port: Int
        var username: String
        var transport: TransportType
        var authMethod: AuthMethod

        /// Keychain account name for the stored password (if password auth).
        var passwordKeychainAccount: String?

        /// Keychain account name for the stored private key (if public key auth).
        var privateKeyKeychainAccount: String?

        /// Terminal profile name to use.
        var profileName: String?

        /// Last connected date.
        var lastConnected: Date?

        /// Command to run after connecting (e.g. "tmux new-session -A -s main").
        var startupCommand: String?

        /// Sort order for the connection list.
        var sortOrder: Int

        /// Transient password — not persisted to SwiftData, only lives in memory
        /// for the duration of a session.
        @Transient
        var password: String = ""

        init(
            name: String = "",
            host: String = "",
            port: Int = 22,
            username: String = "",
            transport: TransportType = .ssh,
            authMethod: AuthMethod = .password
        ) {
            self.id = UUID()
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.transport = transport
            self.authMethod = authMethod
            self.sortOrder = 0
        }
    }
}

enum SpecttySchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ServerConnection.self]
    }

    /// Shipped schema with non-optional mosh fields.
    @Model
    final class ServerConnection {
        var id: UUID
        var name: String
        var host: String
        var port: Int
        var username: String
        var transport: TransportType
        var authMethod: AuthMethod

        /// Keychain account name for the stored password (if password auth).
        var passwordKeychainAccount: String?

        /// Keychain account name for the stored private key (if public key auth).
        var privateKeyKeychainAccount: String?

        /// Terminal profile name to use.
        var profileName: String?

        /// Last connected date.
        var lastConnected: Date?

        /// Command to run after connecting (e.g. "tmux new-session -A -s main").
        var startupCommand: String?

        /// Mosh UI preset for applying sensible defaults quickly.
        var moshPreset: MoshPreset = MoshPreset.standard

        /// Optional override path to `mosh-server` on remote host.
        var moshServerPath: String?

        /// Optional UDP port or range (e.g. "60001" or "60001:60010").
        var moshUDPPortRange: String?

        /// Compatibility mode: skips PTY for bootstrap.
        var moshCompatibilityMode: Bool = false

        /// Requested mosh-server bind address family.
        var moshBindFamily: MoshBindFamilySetting = MoshBindFamilySetting.automatic

        /// Host IP resolution strategy for UDP target selection.
        var moshIPResolution: MoshIPResolutionSetting = MoshIPResolutionSetting.default

        /// Sort order for the connection list.
        var sortOrder: Int

        /// Transient password — not persisted to SwiftData, only lives in memory
        /// for the duration of a session.
        @Transient
        var password: String = ""
        init(
            name: String = "",
            host: String = "",
            port: Int = 22,
            username: String = "",
            transport: TransportType = .ssh,
            authMethod: AuthMethod = .password
        ) {
            self.id = UUID()
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.transport = transport
            self.authMethod = authMethod
            self.sortOrder = 0
        }
    }
}

enum SpecttySchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ServerConnection.self]
    }

    /// Transitional schema where mosh fields are optional for data repair.
    @Model
    final class ServerConnection {
        var id: UUID
        var name: String
        var host: String
        var port: Int
        var username: String
        var transport: TransportType
        var authMethod: AuthMethod

        /// Keychain account name for the stored password (if password auth).
        var passwordKeychainAccount: String?

        /// Keychain account name for the stored private key (if public key auth).
        var privateKeyKeychainAccount: String?

        /// Terminal profile name to use.
        var profileName: String?

        /// Last connected date.
        var lastConnected: Date?

        /// Command to run after connecting (e.g. "tmux new-session -A -s main").
        var startupCommand: String?

        /// Mosh UI preset for applying sensible defaults quickly.
        var moshPreset: MoshPreset?

        /// Optional override path to `mosh-server` on remote host.
        var moshServerPath: String?

        /// Optional UDP port or range (e.g. "60001" or "60001:60010").
        var moshUDPPortRange: String?

        /// Compatibility mode: skips PTY for bootstrap.
        var moshCompatibilityMode: Bool?

        /// Requested mosh-server bind address family.
        var moshBindFamily: MoshBindFamilySetting?

        /// Host IP resolution strategy for UDP target selection.
        var moshIPResolution: MoshIPResolutionSetting?

        /// Sort order for the connection list.
        var sortOrder: Int

        /// Transient password — not persisted to SwiftData, only lives in memory
        /// for the duration of a session.
        @Transient
        var password: String = ""

        init(
            name: String = "",
            host: String = "",
            port: Int = 22,
            username: String = "",
            transport: TransportType = .ssh,
            authMethod: AuthMethod = .password
        ) {
            self.id = UUID()
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.transport = transport
            self.authMethod = authMethod
            self.moshPreset = .standard
            self.moshCompatibilityMode = false
            self.moshBindFamily = .automatic
            self.moshIPResolution = .default
            self.sortOrder = 0
        }
    }
}

enum SpecttySchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ServerConnection.self]
    }

    /// Current persistent model for a saved server connection.
    @Model
    final class ServerConnection {
        var id: UUID
        var name: String
        var host: String
        var port: Int
        var username: String
        var transport: TransportType
        var authMethod: AuthMethod

        /// Keychain account name for the stored password (if password auth).
        var passwordKeychainAccount: String?

        /// Keychain account name for the stored private key (if public key auth).
        var privateKeyKeychainAccount: String?

        /// Terminal profile name to use.
        var profileName: String?

        /// Last connected date.
        var lastConnected: Date?

        /// Command to run after connecting (e.g. "tmux new-session -A -s main").
        var startupCommand: String?

        /// Mosh UI preset for applying sensible defaults quickly.
        var moshPreset: MoshPreset = MoshPreset.standard

        /// Optional override path to `mosh-server` on remote host.
        var moshServerPath: String?

        /// Optional UDP port or range (e.g. "60001" or "60001:60010").
        var moshUDPPortRange: String?

        /// Compatibility mode: skips PTY for bootstrap.
        var moshCompatibilityMode: Bool = false

        /// Requested mosh-server bind address family.
        var moshBindFamily: MoshBindFamilySetting = MoshBindFamilySetting.automatic

        /// Host IP resolution strategy for UDP target selection.
        var moshIPResolution: MoshIPResolutionSetting = MoshIPResolutionSetting.default

        /// Internal schema marker so this version remains distinct for staged migration.
        var migrationRevision: Int = 1

        /// Sort order for the connection list.
        var sortOrder: Int

        /// Transient password — not persisted to SwiftData, only lives in memory
        /// for the duration of a session.
        @Transient
        var password: String = ""

        /// Transient private key PEM — not persisted to SwiftData, only lives in memory
        /// for the duration of an editing session.
        @Transient
        var privateKeyPEM: String = ""

        init(
            name: String = "",
            host: String = "",
            port: Int = 22,
            username: String = "",
            transport: TransportType = .ssh,
            authMethod: AuthMethod = .password
        ) {
            self.id = UUID()
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.transport = transport
            self.authMethod = authMethod
            self.sortOrder = 0
        }

        /// Apply a preset and update related advanced Mosh settings.
        func applyMoshPreset(_ preset: MoshPreset) {
            moshPreset = preset
            switch preset {
            case .standard:
                moshCompatibilityMode = false
                moshBindFamily = .automatic
                moshIPResolution = .default
            case .strictNetwork:
                moshCompatibilityMode = false
                moshBindFamily = .ipv4
                moshIPResolution = .local
            case .troubleshoot:
                moshCompatibilityMode = true
                moshBindFamily = .ipv4
                moshIPResolution = .remote
            }
        }
    }
}

enum SpecttyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SpecttySchemaV1.self, SpecttySchemaV2.self, SpecttySchemaV3.self, SpecttySchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SpecttySchemaV1.self, toVersion: SpecttySchemaV2.self),
            .lightweight(fromVersion: SpecttySchemaV2.self, toVersion: SpecttySchemaV3.self),
            .custom(
                fromVersion: SpecttySchemaV3.self,
                toVersion: SpecttySchemaV4.self,
                willMigrate: { context in
                    let descriptor = FetchDescriptor<SpecttySchemaV3.ServerConnection>()
                    let connections = try context.fetch(descriptor)
                    var didChange = false

                    for connection in connections {
                        if connection.moshPreset == nil {
                            connection.moshPreset = .standard
                            didChange = true
                        }
                        if connection.moshCompatibilityMode == nil {
                            connection.moshCompatibilityMode = false
                            didChange = true
                        }
                        if connection.moshBindFamily == nil {
                            connection.moshBindFamily = .automatic
                            didChange = true
                        }
                        if connection.moshIPResolution == nil {
                            connection.moshIPResolution = .default
                            didChange = true
                        }
                    }

                    if didChange {
                        try context.save()
                    }
                },
                didMigrate: nil
            )
        ]
    }
}

typealias ServerConnection = SpecttySchemaV4.ServerConnection
