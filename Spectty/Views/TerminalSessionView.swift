import SwiftUI
import SpecttyUI
import SpecttyTerminal

struct TerminalSessionView: View {
    let session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        TerminalView(
            emulator: session.emulator,
            onKeyInput: { event in
                session.sendKey(event)
            },
            onResize: { columns, rows in
                session.resize(columns: columns, rows: rows)
            }
        )
        .ignoresSafeArea(.keyboard)
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
}
