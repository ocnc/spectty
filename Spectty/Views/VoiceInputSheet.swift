import SwiftUI
import AVFoundation
import SpecttyUI

struct VoiceInputSheet: View {
    let modelDirectory: URL
    let sessionName: String
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("defaultColorScheme") private var themeName = "Default"
    @State private var recording = VoiceRecording()
    @State private var detent: PresentationDetent = .height(380)

    private var theme: TerminalTheme { .named(themeName) }
    private var ink: Color { color(theme.foreground) }
    private var surface: Color { color(theme.background) }

    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Dictate").font(.title2.weight(.semibold))
                    Text("On-device · Parakeet Ultra")
                        .font(.caption).foregroundStyle(ink.opacity(0.65))
                }
                Spacer()
                Button { recording.cancel(); dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(ink.opacity(0.08), in: Circle())
                }
                .accessibilityLabel("Cancel dictation")
            }

            if recording.phase == .review {
                review
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        status
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .foregroundStyle(ink)
        .tint(ink)
        .buttonStyle(.plain)
        .presentationBackground(surface)
        .presentationCornerRadius(32)
        .presentationDetents([.height(380), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task {
            if typeSize.isAccessibilitySize { detent = .large }
            recording.start(modelDirectory: modelDirectory)
        }
        .onChange(of: typeSize) { _, size in
            if size.isAccessibilitySize { detent = .large }
        }
        .onDisappear { recording.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { recording.cancel(); dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            recording.cancel()
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            recording.cancel()
            dismiss()
        }
    }

    @ViewBuilder private var status: some View {
        switch recording.phase {
        case .idle, .requestingPermission:
            ProgressView().tint(ink).padding(20)
            Text("Getting the microphone ready…").font(.headline)
        case .recording:
            VoiceWaveform(level: recording.inputLevel, color: ink)
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("Listening").font(.headline)
                if let start = recording.startedAt {
                    Text(start, style: .timer)
                        .monospacedDigit().foregroundStyle(ink.opacity(0.65))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Text("Speak naturally. Up to 60 seconds.")
                .font(.subheadline).foregroundStyle(ink.opacity(0.65))
        case .transcribing:
            ProgressView().tint(ink).padding(20)
            Text("Turning speech into text…").font(.headline)
            Text("Everything stays on this device. The first run may take a moment.")
                .font(.subheadline).foregroundStyle(ink.opacity(0.65))
                .multilineTextAlignment(.center)
        case .failed:
            Image(systemName: "mic.slash")
                .font(.system(size: 30, weight: .light)).padding(12)
                .accessibilityHidden(true)
            Text("Let’s try that again").font(.headline)
            Text(recording.error ?? "Recording failed.")
                .font(.subheadline).foregroundStyle(ink.opacity(0.65))
                .multilineTextAlignment(.center)
        case .review:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        switch recording.phase {
        case .recording:
            Button { recording.stop(modelDirectory: modelDirectory) } label: {
                Label("Stop recording", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(surface)
                    .background(ink, in: Capsule())
            }
        case .failed:
            Button { recording.start(modelDirectory: modelDirectory) } label: {
                Text("Try again").font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(surface)
                    .background(ink, in: Capsule())
            }
        default:
            Text("You’ll review the text before inserting it.")
                .font(.footnote).foregroundStyle(ink.opacity(0.65))
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review your text").font(.headline)
            TextEditor(text: $recording.transcript)
                .font(.body).autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel("Voice transcript")
            Text("Inserts into \(sessionName) without pressing Return. Line breaks become spaces.")
                .font(.footnote).foregroundStyle(ink.opacity(0.65))
            HStack(spacing: 12) {
                Button { recording.start(modelDirectory: modelDirectory) } label: {
                    Text("Record again").font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(ink.opacity(0.08), in: Capsule())
                }
                Button {
                    onInsert(recording.textToInsert)
                    dismiss()
                } label: {
                    Label("Insert text", systemImage: "arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(surface)
                        .background(ink.opacity(recording.textToInsert.isEmpty ? 0.35 : 1), in: Capsule())
                }
                .disabled(recording.textToInsert.isEmpty)
            }
        }
    }

    private func color(_ rgb: (UInt8, UInt8, UInt8)) -> Color {
        Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }
}
