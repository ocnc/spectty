import AVFoundation
import Foundation
import Observation
import SpecttySpeech

@MainActor @Observable
final class VoiceRecording {
    // Avoid the Swift 6.2 isolated-deinit back-deployment crash.
    nonisolated deinit {}

    enum Phase { case idle, requestingPermission, recording, transcribing, review, failed }
    private(set) var phase: Phase = .idle
    private(set) var error: String?
    private(set) var startedAt: Date?
    private(set) var inputLevel: Double = 0
    var transcript = ""
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private let engine = SpeechEngine()
    @ObservationIgnored private var generation = UUID()

    var textToInsert: String { Self.normalizedText(transcript) }

    static func normalizedInputLevel(_ decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        // Ignore quiet room noise and leave headroom for normal speech.
        return min(1, max(0, (Double(decibels) + 50) / 40))
    }

    static func normalizedText(_ text: String) -> String {
        // Terminal input must not contain Return, Escape, or other control keys.
        let cleaned = text.unicodeScalars.map { scalar -> String in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return CharacterSet.controlCharacters.contains(scalar) ? "" : String(scalar)
        }.joined()
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    func start(modelDirectory: URL) {
        cancel()
        transcript = ""
        error = nil
        phase = .requestingPermission
        let token = generation
        operation = Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard token == generation, !Task.isCancelled else { return }
            guard granted else {
                error = "Microphone access is off. Enable it for Spectty in iOS Settings."
                phase = .failed
                return
            }
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                try audioSession.setActive(true)
                let url = URL.temporaryDirectory.appendingPathComponent("spectty-voice-\(UUID()).wav")
                recorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ])
                recorder?.isMeteringEnabled = true
                guard recorder?.record() == true else {
                    throw NSError(domain: "VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not start the microphone."])
                }
                startedAt = Date()
                phase = .recording
                meterTask = Task { [weak self] in
                    while !Task.isCancelled, self?.generation == token {
                        self?.recorder?.updateMeters()
                        if let power = self?.recorder?.averagePower(forChannel: 0) {
                            self?.inputLevel = Self.normalizedInputLevel(power)
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                // shortcut: cap dictation at one minute; add streaming for longer recordings.
                limitTask = Task {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, token == generation else { return }
                    stop(modelDirectory: modelDirectory)
                }
            } catch {
                discardRecording()
                deactivateAudio()
                self.error = error.localizedDescription
                phase = .failed
            }
        }
    }

    func stop(modelDirectory: URL) {
        guard phase == .recording, let recorder else { return }
        limitTask?.cancel()
        limitTask = nil
        stopMetering()
        recorder.stop()
        self.recorder = nil
        deactivateAudio()
        let url = recorder.url
        let token = generation
        phase = .transcribing
        operation = Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try await engine.transcribe(url, modelDirectory: modelDirectory)
                guard token == generation, !Task.isCancelled else { return }
                transcript = Self.normalizedText(text)
                if transcript.isEmpty {
                    error = "No speech was detected. Try recording again."
                    phase = .failed
                } else {
                    phase = .review
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                phase = .failed
            }
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        limitTask?.cancel()
        limitTask = nil
        discardRecording()
        transcript = ""
        phase = .idle
    }

    private func discardRecording() {
        stopMetering()
        guard let recorder else { return }
        recorder.stop()
        try? FileManager.default.removeItem(at: recorder.url)
        self.recorder = nil
        deactivateAudio()
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        inputLevel = 0
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
