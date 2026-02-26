import SwiftUI

struct PINSetupView: View {
    enum Mode { case create, change }

    let mode: Mode
    @Environment(PrivacyLockManager.self) private var lockManager
    @Environment(\.dismiss) private var dismiss

    private enum Step { case verifyOld, enterNew, confirmNew }

    @State private var step: Step
    @State private var enteredPIN = ""
    @State private var newPIN = ""
    @State private var errorMessage: String?
    @State private var shakeOffset: CGFloat = 0

    init(mode: Mode) {
        self.mode = mode
        _step = State(initialValue: mode == .change ? .verifyOld : .enterNew)
    }

    private var title: String {
        switch step {
        case .verifyOld: "Enter Current PIN"
        case .enterNew: "Enter New PIN"
        case .confirmNew: "Confirm PIN"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Text(title)
                    .font(.title2.weight(.semibold))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // PIN dots
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < enteredPIN.count ? Color.primary : Color.clear)
                            .overlay(
                                Circle().stroke(Color.primary, lineWidth: 2)
                            )
                            .frame(width: 16, height: 16)
                    }
                }
                .modifier(SetupShakeEffect(offset: shakeOffset))

                // Number pad
                VStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 24) {
                            ForEach(1...3, id: \.self) { col in
                                let digit = row * 3 + col
                                SetupPINButton(label: "\(digit)") {
                                    appendDigit("\(digit)")
                                }
                            }
                        }
                    }

                    HStack(spacing: 24) {
                        Color.clear.frame(width: 72, height: 72)

                        SetupPINButton(label: "0") {
                            appendDigit("0")
                        }

                        SetupPINButton(systemImage: "delete.backward") {
                            if !enteredPIN.isEmpty {
                                enteredPIN.removeLast()
                            }
                        }
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func appendDigit(_ digit: String) {
        guard enteredPIN.count < 4 else { return }
        enteredPIN += digit

        if enteredPIN.count == 4 {
            Task {
                await handleComplete()
            }
        }
    }

    private func handleComplete() async {
        switch step {
        case .verifyOld:
            let correct = await lockManager.verifyPIN(enteredPIN)
            if correct {
                errorMessage = nil
                enteredPIN = ""
                step = .enterNew
            } else {
                await shakeAndClear("Incorrect PIN")
            }

        case .enterNew:
            newPIN = enteredPIN
            errorMessage = nil
            enteredPIN = ""
            step = .confirmNew

        case .confirmNew:
            if enteredPIN == newPIN {
                try? await lockManager.setPIN(newPIN)
                dismiss()
            } else {
                newPIN = ""
                step = .enterNew
                await shakeAndClear("PINs didn't match. Try again.")
            }
        }
    }

    private func shakeAndClear(_ message: String) async {
        errorMessage = message
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        withAnimation(.default.speed(3).repeatCount(3, autoreverses: true)) {
            shakeOffset = 10
        }
        try? await Task.sleep(for: .milliseconds(500))
        withAnimation {
            shakeOffset = 0
        }
        enteredPIN = ""
    }
}

// MARK: - Helpers

private struct SetupShakeEffect: GeometryEffect {
    var offset: CGFloat
    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

private struct SetupPINButton: View {
    var label: String?
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label)
                        .font(.title)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title2)
                }
            }
            .frame(width: 72, height: 72)
            .background(.ultraThinMaterial)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
