import CryptoKit
import Foundation
import Testing
@testable import SpecttySpeech

private struct Fixture {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = Data("first model file".utf8)
    let second = Data("second model file".utf8)
    var manifest: VoiceModelManifest {
        VoiceModelManifest(revision: "tested-revision", files: [entry("first", first), entry("second", second)])
    }
    var installer: VoiceModelInstaller { VoiceModelInstaller(manifest: manifest) }
    func entry(_ name: String, _ data: Data) -> VoiceModelManifest.File {
        .init(path: name, bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test func interruptedInstallReusesVerifiedFilesOnRetry() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    let first = fixture.first
    do {
        try await fixture.installer.install(to: fixture.directory, allowCellular: false, progress: { _, _ in },
            capacity: { _ in .max }, fetch: { remote, destination, cellular, _ in
                #expect(!cellular)
                #expect(remote.path.contains("/tested-revision/"))
                if remote.lastPathComponent == "second" { throw CancellationError() }
                try first.write(to: destination)
            }, prepare: { _ in Issue.record("Interrupted files must not reach Core ML") })
        Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(!fixture.manifest.isInstalled(at: fixture.directory))
    #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("first")) == first)
    let second = fixture.second
    try await fixture.installer.install(to: fixture.directory, allowCellular: true, progress: { _, _ in },
        capacity: { _ in .max }, fetch: { remote, destination, cellular, _ in
            #expect(cellular)
            #expect(remote.lastPathComponent == "second")
            try second.write(to: destination)
        }, prepare: { _ in })
    #expect(fixture.manifest.isInstalled(at: fixture.directory))
}

@Test func lowStoragePreventsNetworkAndPreparation() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    do {
        try await fixture.installer.install(to: fixture.directory, allowCellular: false, progress: { _, _ in },
            capacity: { _ in 1 }, fetch: { _, _, _, _ in Issue.record("Must not download with insufficient storage") },
            prepare: { _ in Issue.record("Must not prepare with insufficient storage") })
        Issue.record("Expected storage error")
    } catch VoiceModelError.storage(let required, let available) {
        #expect(available == 1)
        #expect(required == VoiceModelInstaller.preparationReserve + Int64(fixture.first.count + fixture.second.count))
    }
    #expect(!fixture.manifest.isInstalled(at: fixture.directory))
}

@Test func sameSizeCorruptionIsRejectedBeforeLoading() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    do {
        try await fixture.installer.install(to: fixture.directory, allowCellular: false, progress: { _, _ in },
            capacity: { _ in .max }, fetch: { _, destination, _, _ in
                try Data(repeating: 0, count: 16).write(to: destination)
            }, prepare: { _ in Issue.record("Corrupt weights must not reach Core ML") })
        Issue.record("Expected verification error")
    } catch VoiceModelError.invalidFile {}
    #expect(!fixture.manifest.isInstalled(at: fixture.directory))
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("first.partial").path))
}

@Test func existingDownloadIsAdoptedOfflineAndMarkerWaitsForPreparation() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try fixture.first.write(to: fixture.directory.appendingPathComponent("first"))
    try fixture.second.write(to: fixture.directory.appendingPathComponent("second"))
    try Data().write(to: fixture.directory.appendingPathComponent(".ready"))
    #expect(!fixture.manifest.isInstalled(at: fixture.directory))
    let directory = fixture.directory
    let manifest = fixture.manifest
    enum PreparationFailure: Error { case unsupported }
    do {
        try await fixture.installer.install(to: directory, allowCellular: false, downloadAllowed: false,
            progress: { _, _ in }, capacity: { _ in VoiceModelInstaller.preparationReserve },
            fetch: { _, _, _, _ in Issue.record("Existing valid files need no network") }, prepare: { _ in
                #expect(!manifest.isInstalled(at: directory))
                throw PreparationFailure.unsupported
            })
        Issue.record("Expected preparation failure")
    } catch PreparationFailure.unsupported {}
    #expect(!manifest.isInstalled(at: directory))
    try await fixture.installer.install(to: directory, allowCellular: false, downloadAllowed: false,
        progress: { _, _ in }, capacity: { _ in VoiceModelInstaller.preparationReserve },
        fetch: { _, _, _, _ in Issue.record("Retry must reuse valid files") }, prepare: { _ in })
    #expect(manifest.isInstalled(at: directory))
}

@Test func offlineAdoptionNeverRepairsThroughNetwork() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    do {
        try await fixture.installer.install(to: fixture.directory, allowCellular: false, downloadAllowed: false,
            progress: { _, _ in }, capacity: { _ in .max },
            fetch: { _, _, _, _ in Issue.record("Offline adoption must not download missing files") }, prepare: { _ in })
        Issue.record("Expected missing-model error")
    } catch VoiceModelError.needsDownload {}
}

@Test func cancelledPreparationDoesNotPublishReadyMarker() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    let first = fixture.first
    let second = fixture.second
    do {
        try await fixture.installer.install(to: fixture.directory, allowCellular: false, progress: { _, _ in },
            capacity: { _ in .max }, fetch: { remote, destination, _, _ in
                try (remote.lastPathComponent == "first" ? first : second).write(to: destination)
            }, prepare: { _ in throw CancellationError() })
        Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(!fixture.manifest.isInstalled(at: fixture.directory))
}

@Test func wifiPolicyIsEnforcedByTheSessionIncludingResumedRequests() {
    let wifi = ModelFileDownload.configuration(allowCellular: false)
    #expect(!wifi.allowsCellularAccess)
    #expect(!wifi.allowsExpensiveNetworkAccess)
    #expect(!wifi.allowsConstrainedNetworkAccess)
    let cellular = ModelFileDownload.configuration(allowCellular: true)
    #expect(cellular.allowsCellularAccess)
    #expect(cellular.allowsExpensiveNetworkAccess)
    #expect(!cellular.allowsConstrainedNetworkAccess)
}

@Test func bundledManifestIsPinnedAndContainsOnlySafePaths() {
    let manifest = VoiceModelManifest.ultra
    #expect(manifest.revision.count == 40)
    #expect(manifest.files.count == 20)
    #expect(Set(manifest.files.map(\.path)).count == manifest.files.count)
    #expect(manifest.files.reduce(Int64(0)) { $0 + $1.bytes } == 632_314_500)
    for file in manifest.files {
        #expect(!file.path.hasPrefix("/"))
        #expect(!file.path.split(separator: "/").contains(".."))
        #expect(file.sha256.count == 64)
    }
}

@Test func completePartialFileIsReusedAfterCancellationBeforeCommit() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try fixture.first.write(to: fixture.directory.appendingPathComponent("first.partial"))
    try fixture.second.write(to: fixture.directory.appendingPathComponent("second"))
    try await fixture.installer.install(to: fixture.directory, allowCellular: false, progress: { _, _ in },
        capacity: { _ in .max }, fetch: { _, _, _, _ in Issue.record("Verified complete partial must not be downloaded again") },
        prepare: { _ in })
    #expect(fixture.manifest.isInstalled(at: fixture.directory))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SPECTTY_DOWNLOAD_TEST_URL"] != nil))
func realURLSessionCancellationPersistsResumeDataAndRetries() async throws {
    let base = try #require(ProcessInfo.processInfo.environment["SPECTTY_DOWNLOAD_TEST_URL"])
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("file.partial")
    let remote = URL(string: base + "/slow")!
    let (stream, updates) = AsyncStream.makeStream(of: Int64.self)
    let task = Task {
        defer { updates.finish() }
        try await ModelFileDownload.fetch(remote, to: destination, allowCellular: false) { bytes in
            updates.yield(bytes)
        }
    }
    for await bytes in stream {
        if bytes >= 32_768 { task.cancel(); break }
    }
    updates.finish()
    do { try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
    let resume = destination.appendingPathExtension("resume")
    #expect(FileManager.default.fileExists(atPath: resume.path))
    try await ModelFileDownload.fetch(remote, to: destination, allowCellular: false) { _ in }
    #expect(try Data(contentsOf: destination) == Data(repeating: 65, count: 2_097_152))
    #expect(!FileManager.default.fileExists(atPath: resume.path))
}
