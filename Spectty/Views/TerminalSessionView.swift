import SwiftUI
import SpecttyUI
import SpecttyTerminal
import SpecttyTransport

struct TerminalSessionView: View {
    let session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultFontName") private var fontName = "Menlo"
    @AppStorage("defaultFontSize") private var fontSize = 14.0
    @AppStorage("defaultColorScheme") private var colorScheme = "Default"
    @AppStorage("cursorStyle") private var cursorStyle = "block"
    @State private var showDisconnectConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    var body: some View {
        ZStack {
            TerminalView(
                emulator: session.emulator,
                font: TerminalFont(name: fontName, size: CGFloat(fontSize)),
                themeName: colorScheme,
                cursorStyle: CursorStyle(rawValue: cursorStyle) ?? .block,
                onKeyInput: { event in
                    session.sendKey(event)
                },
                onPaste: { data in
                    session.sendData(data)
                },
                onResize: { columns, rows in
                    session.resize(columns: columns, rows: rows)
                }
            )

            // Connection status overlay.
            connectionOverlay
        }
        .navigationTitle(session.title.isEmpty ? session.connectionName : session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button {
                        // Global dismiss/show — the tap gesture on the terminal view handles show.
                        dismissKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }

                    Menu {
                        Button {
                            UIPasteboard.general.string.map { text in
                                session.sendData(Data(text.utf8))
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }

                        Button {
                            renameText = session.connectionName
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showDisconnectConfirm = true
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("Disconnect from \(session.connectionName)?", isPresented: $showDisconnectConfirm, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                sessionManager.disconnect(session)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            TextField("Session name", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    session.connectionName = trimmed
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @ViewBuilder
    private var connectionOverlay: some View {
        switch session.transportState {
        case .connecting:
            statusBanner(
                icon: "antenna.radiowaves.left.and.right",
                text: "Connecting...",
                showSpinner: true
            )
        case .reconnecting:
            statusBanner(
                icon: "arrow.triangle.2.circlepath",
                text: "Reconnecting...",
                showSpinner: true
            )
        case .failed(let error):
            statusBanner(
                icon: "exclamationmark.triangle",
                text: error.localizedDescription,
                showSpinner: false
            )
        case .disconnected:
            if !session.title.isEmpty {
                // Only show if we were previously connected.
                statusBanner(
                    icon: "wifi.slash",
                    text: "Disconnected",
                    showSpinner: false
                )
            }
        case .connected:
            EmptyView()
        }
    }

    private func statusBanner(icon: String, text: String, showSpinner: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            HStack(spacing: 10) {
                if showSpinner {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                        .foregroundStyle(.white)
                }
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial.opacity(0.9))
            .background(Color.black.opacity(0.5))
            .clipShape(Capsule())
            .padding(.bottom, 80)
        }
        .allowsHitTesting(false)
    }
}
