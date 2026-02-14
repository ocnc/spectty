import SwiftUI
import SpecttyUI
import SpecttyTerminal
import SpecttyTransport

struct TerminalSessionView: View {
    let session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        ZStack {
            TerminalView(
                emulator: session.emulator,
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
            .ignoresSafeArea(.keyboard)

            // Connection status overlay.
            connectionOverlay
        }
        .navigationTitle(session.title.isEmpty ? session.connectionName : session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        UIPasteboard.general.string.map { text in
                            session.sendData(Data(text.utf8))
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }

                    Button(role: .destructive) {
                        sessionManager.disconnect(session)
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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
