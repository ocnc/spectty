import XCTest
import SwiftUI
@testable import Spectty

final class VoiceInputTests: XCTestCase {
    func testWaveformIsFlatInSilenceAndStaysWithinItsFrame() {
        let frame = CGRect(x: 10, y: 20, width: 260, height: 72)
        let quiet = VoiceWave(level: 0, phase: 1).path(in: frame).boundingRect
        XCTAssertEqual(quiet.height, 0, accuracy: 0.001)
        XCTAssertEqual(quiet.midY, frame.midY, accuracy: 0.001)
        for phase in [0.0, 1, 3, 6] {
            let bounds = VoiceWave(level: 1, phase: phase).path(in: frame).boundingRect
            XCTAssertGreaterThan(bounds.height, 10)
            XCTAssertTrue(frame.contains(bounds))
        }
    }

    @MainActor func testInputLevelClampsSilenceAndLoudAudio() {
        XCTAssertEqual(VoiceRecording.normalizedInputLevel(-160), 0)
        XCTAssertEqual(VoiceRecording.normalizedInputLevel(-50), 0)
        XCTAssertEqual(VoiceRecording.normalizedInputLevel(-30), 0.5)
        XCTAssertEqual(VoiceRecording.normalizedInputLevel(-10), 1)
        XCTAssertEqual(VoiceRecording.normalizedInputLevel(0), 1)
        XCTAssertEqual(VoiceRecording.normalizedInputLevel(.nan), 0)
        XCTAssertEqual(VoiceRecording.normalizedInputLevel(-.infinity), 0)
    }

    @MainActor func testTranscriptCannotSendTerminalControlKeys() {
        XCTAssertEqual(VoiceRecording.normalizedText("  hello\r\nworld\t🙂  "), "hello world 🙂")
        XCTAssertEqual(VoiceRecording.normalizedText("a\u{1B}\u{00}\u{7F}\u{90}b"), "ab")
        XCTAssertEqual(VoiceRecording.normalizedText("\n\t "), "")
    }

    @MainActor func testVoiceIsOptInAndRemovingDownloadDisablesIt() throws {
        let suite = "VoiceInputTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceInputStore(defaults: defaults, modelDirectory: directory)
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.isInstalled)
        XCTAssertFalse(store.isDownloading)
        XCTAssertFalse(store.hasDownload)
        store.isEnabled = true
        XCTAssertFalse(store.isReady)
        XCTAssertTrue(defaults.bool(forKey: "voiceInputEnabled"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store.removeDownload()
        XCTAssertFalse(store.hasDownload)
        XCTAssertFalse(store.isEnabled)
    }

    @MainActor func testExistingDownloadWithoutReadyMarkerIsVerified() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = VoiceInputStore(modelDirectory: directory)
        store.verifyExistingDownload()
        XCTAssertTrue(store.isDownloading)
        store.cancelDownload()
    }

    @MainActor func testCancellationClearsDraft() {
        let recording = VoiceRecording()
        recording.transcript = "do not send"
        recording.cancel()
        XCTAssertEqual(recording.phase, .idle)
        XCTAssertEqual(recording.textToInsert, "")
        XCTAssertEqual(recording.inputLevel, 0)
    }
}
