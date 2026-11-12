import Foundation
import FluidAudio

/// Keeps model compilation and inference off the app's main actor.
public actor SpeechEngine {
    public static let modelFolderName = Repo.parakeetUltra.folderName
    public init() {}

    public nonisolated static func isInstalled(at directory: URL) -> Bool {
        VoiceModelManifest.ultra.isInstalled(at: directory)
    }

    public func download(to directory: URL, allowCellular: Bool = false,
                         progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        try await install(to: directory, allowCellular: allowCellular, downloadAllowed: true, progress: progress)
    }

    public func verifyExistingDownload(at directory: URL,
                                      progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        try await install(to: directory, allowCellular: false, downloadAllowed: false, progress: progress)
    }

    private func install(to directory: URL, allowCellular: Bool, downloadAllowed: Bool,
                         progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        try await VoiceModelInstaller(manifest: .ultra).install(
            to: directory, allowCellular: allowCellular, downloadAllowed: downloadAllowed, progress: progress
        ) { directory in
            _ = try AsrModels.loadLocal(from: directory, version: .ultra)
        }
    }

    public func transcribe(_ audio: URL, modelDirectory: URL) async throws -> String {
        try Task.checkCancellation()
        guard Self.isInstalled(at: modelDirectory) else { throw VoiceModelError.needsDownload }
        let models = try AsrModels.loadLocal(from: modelDirectory, version: .ultra)
        try Task.checkCancellation()
        let manager = AsrManager()
        try await manager.loadModels(models)
        var decoder = try TdtDecoderState()
        do {
            let result = try await manager.transcribe(audio, decoderState: &decoder)
            await manager.cleanup()
            try Task.checkCancellation()
            return result.text
        } catch {
            await manager.cleanup()
            throw error
        }
    }
}
