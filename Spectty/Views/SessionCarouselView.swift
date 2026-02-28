import SwiftUI
import SpecttyUI

struct SessionCarouselView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var dragOffset: CGFloat = 0
    @State private var adjacentSession: TerminalSession?
    @State private var swipeDirection: EdgeSwipeEvent.Direction?
    @State private var showDisconnectConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Adjacent session — only present during drag, positioned off-screen sliding in.
                if let adjacent = adjacentSession, let direction = swipeDirection {
                    TerminalSessionView(
                        session: adjacent,
                        autoFocus: false
                    )
                    .id(adjacent.id)
                    .offset(x: adjacentOffset(direction: direction, width: geo.size.width))
                }

                // Active session — always present.
                if let active = sessionManager.activeSession {
                    TerminalSessionView(
                        session: active,
                        onEdgeSwipe: { handleEdgeSwipe($0, width: geo.size.width) }
                    )
                    .id(active.id)
                    .offset(x: dragOffset)
                }
            }
        }
        .navigationBarBackButtonHidden(sessionManager.hasPreviousSession)
        .navigationTitle(activeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button {
                        dismissKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }

                    Menu {
                        Button {
                            if let session = sessionManager.activeSession {
                                UIPasteboard.general.string.map { text in
                                    session.sendData(Data(text.utf8))
                                }
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }

                        Button {
                            if let session = sessionManager.activeSession {
                                renameText = session.connectionName
                                showRenameAlert = true
                            }
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
        .confirmationDialog(
            "Disconnect from \(sessionManager.activeSession?.connectionName ?? "")?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                if let session = sessionManager.activeSession {
                    handleDisconnect(session)
                }
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
                    sessionManager.activeSession?.connectionName = trimmed
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if sessionManager.sessions.count > 1 {
                pageIndicator
                    .padding(.bottom, 4)
            }
        }
        .onChange(of: sessionManager.sessions.count) { _, newCount in
            if newCount == 0 { dismiss() }
        }
    }

    private var activeTitle: String {
        guard let session = sessionManager.activeSession else { return "" }
        return session.title.isEmpty ? session.connectionName : session.title
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - Edge Swipe

    private func handleEdgeSwipe(_ event: EdgeSwipeEvent, width: CGFloat) {
        switch event.phase {
        case .began:
            let adjacent: TerminalSession?
            switch event.direction {
            case .left:
                adjacent = sessionManager.previousSession()
            case .right:
                adjacent = sessionManager.nextSession()
            }
            guard let adjacent else { return }
            swipeDirection = event.direction
            adjacentSession = adjacent
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        case .changed:
            guard adjacentSession != nil else { return }
            dragOffset = event.translation

        case .ended:
            guard adjacentSession != nil else { return }
            let threshold = width * 0.35
            let shouldComplete = abs(event.translation) > threshold || abs(event.velocity) > 500

            if shouldComplete {
                let target: CGFloat = event.direction == .left ? width : -width
                withAnimation(.easeOut(duration: 0.25)) {
                    dragOffset = target
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    switch event.direction {
                    case .left: sessionManager.switchToPrevious()
                    case .right: sessionManager.switchToNext()
                    }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        dragOffset = 0
                        adjacentSession = nil
                        swipeDirection = nil
                    }
                }
            } else {
                bounceBack()
            }

        case .cancelled:
            bounceBack()
        }
    }

    private func bounceBack() {
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            adjacentSession = nil
            swipeDirection = nil
        }
    }

    private func adjacentOffset(direction: EdgeSwipeEvent.Direction, width: CGFloat) -> CGFloat {
        switch direction {
        case .left:
            // Previous session comes from the left.
            return -width + dragOffset
        case .right:
            // Next session comes from the right.
            return width + dragOffset
        }
    }

    // MARK: - Disconnect

    private func handleDisconnect(_ session: TerminalSession) {
        sessionManager.disconnect(session)
        // If no sessions remain, onChange will dismiss.
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(sessionManager.sessions) { session in
                Circle()
                    .fill(session.id == sessionManager.activeSessionID ? Color.white : Color.white.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.6))
        .clipShape(Capsule())
    }
}
