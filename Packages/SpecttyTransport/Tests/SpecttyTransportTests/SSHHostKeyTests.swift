import Foundation
import Testing
@testable import SpecttyTransport

@Suite("SSH Host Key TOFU")
struct SSHHostKeyTests {
    private let key1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJfkNV4OS33ImTXvorZr72q4v5XhVEQKfvqsxOEJ/XaR"
    private let key2 = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBIZS1APJofiPeoATC/VC4kKi7xRPdz934nSkFLTc0whYi3A8hEKHAOX9edgL1UWxRqRGQZq2wvvAIjAO9kCeiQA="

    @Test("Trusts first seen key and accepts it on reconnect")
    func trustsFirstUse() async throws {
        let storeURL = makeTemporaryStoreURL()
        defer { cleanupTemporaryStore(at: storeURL) }

        let store = SSHHostKeyTrustStore(fileURL: storeURL)

        let first = try await store.validate(host: "example.com", port: 22, presentedKey: key1)
        switch first {
        case .trusted:
            break
        case .mismatch:
            Issue.record("First seen host key should be trusted")
        }

        let second = try await store.validate(host: "example.com", port: 22, presentedKey: key1)
        switch second {
        case .trusted:
            break
        case .mismatch:
            Issue.record("Previously trusted host key should still be accepted")
        }
    }

    @Test("Rejects changed key for an already trusted host")
    func rejectsChangedHostKey() async throws {
        let storeURL = makeTemporaryStoreURL()
        defer { cleanupTemporaryStore(at: storeURL) }

        let store = SSHHostKeyTrustStore(fileURL: storeURL)
        _ = try await store.validate(host: "example.com", port: 22, presentedKey: key1)

        let changed = try await store.validate(host: "example.com", port: 22, presentedKey: key2)
        switch changed {
        case .trusted:
            Issue.record("Changed host key should be rejected")
        case .mismatch(let expected, let presented):
            #expect(expected == key1)
            #expect(presented == key2)
        }
    }

    @Test("Persists trusted keys to disk")
    func persistsTrustedKeys() async throws {
        let storeURL = makeTemporaryStoreURL()
        defer { cleanupTemporaryStore(at: storeURL) }

        do {
            let store = SSHHostKeyTrustStore(fileURL: storeURL)
            _ = try await store.validate(host: "example.com", port: 22, presentedKey: key1)
        }

        let reloadedStore = SSHHostKeyTrustStore(fileURL: storeURL)
        let revalidated = try await reloadedStore.validate(host: "example.com", port: 22, presentedKey: key1)

        switch revalidated {
        case .trusted:
            break
        case .mismatch:
            Issue.record("Reloaded trust store should recognize persisted host key")
        }
    }

    private func makeTemporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spectty-hostkeys-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("known_hosts.json")
    }

    private func cleanupTemporaryStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
