import Foundation

/// Persistent host-key store used for TOFU (Trust On First Use) verification.
actor SSHHostKeyTrustStore {
    enum ValidationResult: Sendable {
        case trusted
        case mismatch(expected: String, presented: String)
    }

    static let shared = SSHHostKeyTrustStore()

    private let fileURL: URL
    private var entries: [String: String] = [:]
    private var didLoad = false

    init(fileURL: URL = SSHHostKeyTrustStore.defaultStoreURL()) {
        self.fileURL = fileURL
    }

    func validate(host: String, port: Int, presentedKey: String) throws -> ValidationResult {
        try loadIfNeeded()

        let key = Self.hostIdentifier(host: host, port: port)
        if let existing = entries[key] {
            if existing == presentedKey {
                return .trusted
            }
            return .mismatch(expected: existing, presented: presentedKey)
        }

        entries[key] = presentedKey
        try persist()
        return .trusted
    }

    func remove(host: String, port: Int) throws {
        try loadIfNeeded()
        let key = Self.hostIdentifier(host: host, port: port)
        guard entries.removeValue(forKey: key) != nil else { return }
        try persist()
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        defer { didLoad = true }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            entries = [:]
            return
        }

        let data = try Data(contentsOf: fileURL)
        entries = try JSONDecoder().decode([String: String].self, from: data)
    }

    private func persist() throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)

        // Ensure trusted-host metadata is encrypted at rest when the platform supports it.
        #if os(iOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }

    nonisolated static func hostIdentifier(host: String, port: Int) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedHost.contains(":") && !normalizedHost.hasPrefix("[") {
            return "[\(normalizedHost)]:\(port)"
        }
        return "\(normalizedHost):\(port)"
    }

    nonisolated static func defaultStoreURL() -> URL {
        let fileManager = FileManager.default
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport
                .appendingPathComponent("Spectty", isDirectory: true)
                .appendingPathComponent("ssh_known_hosts.json", isDirectory: false)
        }

        return fileManager.temporaryDirectory
            .appendingPathComponent("Spectty", isDirectory: true)
            .appendingPathComponent("ssh_known_hosts.json", isDirectory: false)
    }
}

/// Public API for host-key trust management (used by app UI for recovery flows).
public enum SSHHostKeyTrustManager {
    /// Forget a previously trusted host key so the next connection can re-TOFU.
    public static func forget(host: String, port: Int) async throws {
        try await SSHHostKeyTrustStore.shared.remove(host: host, port: port)
    }
}
