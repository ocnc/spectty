import Foundation
import Observation
import SpecttySpeech

@MainActor @Observable
final class VoiceInputStore {
    // Avoid the Swift 6.2 isolated-deinit back-deployment crash.
    nonisolated deinit {}

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "voiceInputEnabled")
            if !isEnabled { cancelDownload() }
        }
    }
    private(set) var isInstalled: Bool
    private(set) var isDownloading = false
    private(set) var isCancelling = false
    private(set) var progress: Double?
    private(set) var status = ""
    private(set) var error: String?

    let modelDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine = SpeechEngine()
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    var isReady: Bool { isEnabled && isInstalled && !isDownloading }
    var hasDownload: Bool { FileManager.default.fileExists(atPath: modelDirectory.path) }

    init(defaults: UserDefaults = .standard, modelDirectory: URL? = nil) {
        self.defaults = defaults
        self.modelDirectory = modelDirectory ?? URL.applicationSupportDirectory
            .appendingPathComponent("VoiceInput", isDirectory: true)
            .appendingPathComponent(SpeechEngine.modelFolderName, isDirectory: true)
        isEnabled = defaults.bool(forKey: "voiceInputEnabled")
        isInstalled = SpeechEngine.isInstalled(at: self.modelDirectory)
    }

    func download(allowCellular: Bool = false) {
        install(allowCellular: allowCellular, existingOnly: false)
    }

    func verifyExistingDownload() {
        guard !isInstalled, hasDownload else { return }
        install(allowCellular: false, existingOnly: true)
    }

    private func install(allowCellular: Bool, existingOnly: Bool) {
        guard !isDownloading else { return }
        error = nil
        isDownloading = true
        isCancelling = false
        progress = nil
        status = existingOnly ? "Verifying downloaded model…" : "Starting download…"
        let token = UUID()
        operationID = token
        downloadTask = Task {
            defer {
                isDownloading = false
                isCancelling = false
                downloadTask = nil
                isInstalled = SpeechEngine.isInstalled(at: modelDirectory)
            }
            do {
                let update: @Sendable (Double?, String) -> Void = { [weak self] fraction, message in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == token, self.isDownloading, !self.isCancelling else { return }
                        self.progress = fraction
                        self.status = message
                    }
                }
                if existingOnly {
                    try await engine.verifyExistingDownload(at: modelDirectory, progress: update)
                } else {
                    try await engine.download(to: modelDirectory, allowCellular: allowCellular, progress: update)
                }
                try Task.checkCancellation()
                if !existingOnly { isEnabled = true }
            } catch {
                if !Task.isCancelled {
                    if let networkError = error as? URLError,
                       [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(networkError.code) {
                        self.error = "Download paused. Connect to Wi-Fi with Low Data Mode off, or retry and choose Allow Cellular Data."
                    } else {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelDownload() {
        guard isDownloading else { return }
        isCancelling = true
        status = "Cancelling…"
        progress = nil
        downloadTask?.cancel()
    }

    func removeDownload() {
        guard !isDownloading else { return }
        do {
            if hasDownload { try FileManager.default.removeItem(at: modelDirectory) }
            isInstalled = false
            isEnabled = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
