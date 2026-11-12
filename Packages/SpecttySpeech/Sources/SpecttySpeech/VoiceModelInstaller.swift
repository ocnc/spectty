import CryptoKit
import Foundation

struct VoiceModelManifest: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    let revision: String
    let files: [File]

    // Bundled metadata, not a mutable remote manifest.
    static let ultra = try! JSONDecoder().decode(Self.self, from: Data(contentsOf:
        Bundle.module.url(forResource: "Ultra", withExtension: "json")!))

    func isInstalled(at directory: URL) -> Bool {
        (try? String(contentsOf: directory.appendingPathComponent(".ready"), encoding: .utf8)) == revision
            && files.allSatisfy { Self.size(of: directory.appendingPathComponent($0.path)) == $0.bytes }
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func matches(_ file: File, at url: URL) throws -> Bool {
        guard size(of: url) == file.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}

enum VoiceModelError: LocalizedError {
    case storage(required: Int64, available: Int64)
    case storageUnavailable
    case invalidFile(String)
    case needsDownload

    var errorDescription: String? {
        switch self {
        case let .storage(required, available):
            let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Voice setup needs \(needed) free, including preparation space. Only \(free) is available. Free some storage and retry."
        case .storageUnavailable: return "Could not check available storage. Please try again."
        case .invalidFile: return "A model file failed verification. Retry to download a fresh copy."
        case .needsDownload: return "The voice model needs verification or repair. Use Download & Enable in Settings; matching files will be reused."
        }
    }
}

/// Installs only the bundled Ultra manifest; verified files survive cancellation and retry.
struct VoiceModelInstaller: Sendable {
    typealias Progress = @Sendable (Double?, String) -> Void
    typealias Fetch = @Sendable (URL, URL, Bool, @escaping @Sendable (Int64) -> Void) async throws -> Void
    let manifest: VoiceModelManifest
    // Core ML's device-specific cache is additional to the model's on-disk weights.
    static let preparationReserve: Int64 = 1_000_000_000

    static func availableCapacity(at directory: URL) throws -> Int64 {
        guard let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { throw VoiceModelError.storageUnavailable }
        return capacity
    }

    func install(
        to directory: URL,
        allowCellular: Bool,
        downloadAllowed: Bool = true,
        progress: @escaping Progress,
        capacity: @Sendable (URL) throws -> Int64 = Self.availableCapacity,
        fetch: Fetch = ModelFileDownload.fetch,
        prepare: @Sendable (URL) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let marker = directory.appendingPathComponent(".ready")
        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }

        progress(nil, "Verifying model files…")
        var pending: [VoiceModelManifest.File] = []
        var completed: Int64 = 0
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.bytes }
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            let partial = destination.appendingPathExtension("partial")
            if try VoiceModelManifest.matches(file, at: destination) {
                completed += file.bytes
            } else if try VoiceModelManifest.matches(file, at: partial) {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: partial, to: destination)
                completed += file.bytes
            } else {
                pending.append(file)
            }
        }
        guard downloadAllowed || pending.isEmpty else { throw VoiceModelError.needsDownload }
        let required = total - completed + Self.preparationReserve
        let available = try capacity(directory)
        guard available >= required else { throw VoiceModelError.storage(required: required, available: available) }

        for file in pending {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("partial")
            let url = URL(string: "https://huggingface.co/FluidInference/parakeet-ultra-coreml/resolve/\(manifest.revision)/\(file.path)")!
            let previous = completed
            progress(Double(previous) / Double(total), "Downloading voice model…")
            try await fetch(url, partial, allowCellular) { received in
                progress(Double(previous + min(received, file.bytes)) / Double(total), "Downloading voice model…")
            }
            try Task.checkCancellation()
            guard try VoiceModelManifest.matches(file, at: partial) else {
                try? fm.removeItem(at: partial)
                throw VoiceModelError.invalidFile(file.path)
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: partial, to: destination)
            completed += file.bytes
        }
        try Task.checkCancellation()
        progress(nil, "Preparing model on this device…")
        try await prepare(directory)
        try Task.checkCancellation()
        try Data(manifest.revision.utf8).write(to: marker, options: .atomic)
    }
}
