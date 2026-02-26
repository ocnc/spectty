import SwiftUI
import LocalAuthentication

struct LockScreenView: View {
    @Environment(PrivacyLockManager.self) private var lockManager
    @State private var enteredPIN = ""
    @AppStorage("biometricUnlockEnabled") private var biometricUnlockEnabled = false
    @State private var shakeOffset: CGFloat = 0
    @State private var isWrong = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Spectty is Locked")
                .font(.title2.weight(.semibold))

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
            .modifier(ShakeEffect(offset: shakeOffset))

            // Number pad
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 24) {
                        ForEach(1...3, id: \.self) { col in
                            let digit = row * 3 + col
                            PINButton(label: "\(digit)") {
                                appendDigit("\(digit)")
                            }
                        }
                    }
                }

                HStack(spacing: 24) {
                    // Biometric button (only if user opted in)
                    if biometricUnlockEnabled && lockManager.biometricsAvailable {
                        PINButton(
                            systemImage: lockManager.biometricType == .faceID ? "faceid" : "touchid"
                        ) {
                            lockManager.attemptBiometricUnlock()
                        }
                    } else {
                        Color.clear.frame(width: 72, height: 72)
                    }

                    PINButton(label: "0") {
                        appendDigit("0")
                    }

                    PINButton(systemImage: "delete.backward") {
                        if !enteredPIN.isEmpty {
                            enteredPIN.removeLast()
                        }
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func appendDigit(_ digit: String) {
        guard enteredPIN.count < 4 else { return }
        enteredPIN += digit

        if enteredPIN.count == 4 {
            Task {
                let success = await lockManager.unlockWithPIN(enteredPIN)
                if !success {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.error)
                    withAnimation(.default.speed(3).repeatCount(3, autoreverses: true)) {
                        shakeOffset = 10
                    }
                    isWrong = true
                    try? await Task.sleep(for: .milliseconds(500))
                    withAnimation {
                        shakeOffset = 0
                    }
                    enteredPIN = ""
                    isWrong = false
                }
            }
        }
    }
}

// MARK: - Shake Effect

private struct ShakeEffect: GeometryEffect {
    var offset: CGFloat
    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - PIN Button

private struct PINButton: View {
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
