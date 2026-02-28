import SwiftUI
import SpecttyUI
import SpecttyTransport

struct TerminalSessionView: View {
    let session: TerminalSession
    var onEdgeSwipe: ((EdgeSwipeEvent) -> Void)? = nil
    var autoFocus: Bool = true
    @AppStorage("defaultFontName") private var fontName = "Menlo"
    @AppStorage("defaultFontSize") private var fontSize = 14.0
    @AppStorage("defaultColorScheme") private var colorScheme = "Default"
    @AppStorage("cursorStyle") private var cursorStyle = "block"

    var body: some View {
        ZStack {
            TerminalView(
                emulator: session.emulator,
                font: TerminalFont(name: fontName, size: CGFloat(fontSize)),
                themeName: colorScheme,
                cursorStyle: CursorStyle(rawValue: cursorStyle) ?? .block,
                autoFocus: autoFocus,
                onKeyInput: { event in
                    session.sendKey(event)
                },
                onPaste: { data in
                    session.sendData(data)
                },
                onResize: { columns, rows in
                    session.resize(columns: columns, rows: rows)
                },
                onEdgeSwipe: onEdgeSwipe
            )

            // Connection status overlay.
            connectionOverlay
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
                showSpinner: false,
                showReconnect: true
            )
        case .disconnected:
            if !session.title.isEmpty {
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

    private func statusBanner(icon: String, text: String, showSpinner: Bool, showReconnect: Bool = false) -> some View {
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

            if showReconnect {
                Button {
                    session.retryConnection()
                } label: {
                    Text("Reconnect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial.opacity(0.9))
                        .background(Color.blue.opacity(0.4))
                        .clipShape(Capsule())
                }
            }

            Spacer()
                .frame(height: 60)
        }
        .allowsHitTesting(showReconnect)
    }
}
