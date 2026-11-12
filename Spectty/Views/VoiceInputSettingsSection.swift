import SwiftUI

struct VoiceInputSettingsSection: View {
    @Environment(VoiceInputStore.self) private var voice
    @State private var confirmDownload = false
    @State private var confirmRemoval = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { voice.isEnabled }, set: { enabled in
                if enabled && !voice.isInstalled {
                    confirmDownload = true
                } else {
                    voice.isEnabled = enabled
                }
            })) {
                Label("Voice Input", systemImage: "mic.fill")
            }
            .disabled(voice.isDownloading)

            HStack {
                Text("Parakeet Ultra")
                Spacer()
                Text(voice.isInstalled ? "Downloaded" : "~630 MB")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            if voice.isDownloading {
                VStack(alignment: .leading, spacing: 8) {
                    if let progress = voice.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                    Text(voice.status).font(.caption).foregroundStyle(.secondary)
                    Text("Keep Spectty open. Interrupted downloads can be resumed by retrying.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel Download", role: .cancel) { voice.cancelDownload() }
                    .disabled(voice.isCancelling)
            } else {
                if !voice.isInstalled {
                    Button(voice.error == nil ? "Download & Enable" : "Retry Download") { confirmDownload = true }
                }
                if voice.hasDownload {
                    Button("Remove Download", role: .destructive) { confirmRemoval = true }
                }
            }

            if let error = voice.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Once enabled, tap the microphone in the bottom input bar of a connected terminal. Dictate on your device, then review before inserting into the terminal. Optional download; no audio is sent to a transcription service. Disabling voice keeps the model for next time.")
        }
        .confirmationDialog("Download Parakeet Ultra?", isPresented: $confirmDownload, titleVisibility: .visible) {
            Button("Download on Wi-Fi") { voice.download() }
            Button("Allow Cellular Data") { voice.download(allowCellular: true) }
        } message: {
            Text("Downloads approximately 630 MB from Hugging Face. Setup also reserves 1 GB of free space for preparation. Cellular data is blocked unless you allow it for this download. Low Data Mode is respected. After setup, transcription works offline.")
        }
        .confirmationDialog("Remove voice model?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { voice.removeDownload() }
        } message: {
            Text("This disables voice input and removes its downloaded files. You can download it again later.")
        }
    }
}
