import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @AppStorage("defaultFontName") private var fontName = "Menlo"
    @AppStorage("defaultFontSize") private var fontSize = 14.0
    @AppStorage("defaultColorScheme") private var colorScheme = "Default"
    @AppStorage("scrollbackLines") private var scrollbackLines = 10_000
    @AppStorage("cursorStyle") private var cursorStyle = "block"
    @AppStorage("allowRemoteClipboardRead") private var allowRemoteClipboardRead = false
    @AppStorage("privacyModeEnabled") private var privacyModeEnabled = false
    @AppStorage("biometricUnlockEnabled") private var biometricUnlockEnabled = false

    @Environment(PrivacyLockManager.self) private var lockManager
    @State private var showPINSetup = false
    @State private var showPINChange = false
    @State private var showRemoveConfirmation = false
    @State private var pinSetupMode: PINSetupView.Mode = .create

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font", selection: $fontName) {
                    Text("Menlo").tag("Menlo")
                    Text("JetBrains Mono NF").tag("JetBrainsMonoNFM-Regular")
                }

                HStack {
                    Text("Size")
                    Spacer()
                    Stepper("\(Int(fontSize))pt", value: $fontSize, in: 8...32, step: 1)
                }
            }

            Section("Terminal") {
                Picker("Cursor Style", selection: $cursorStyle) {
                    Text("Block").tag("block")
                    Text("Underline").tag("underline")
                    Text("Bar").tag("bar")
                }

                HStack {
                    Text("Scrollback Lines")
                    Spacer()
                    TextField("10000", value: $scrollbackLines, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }

                Toggle("Allow Remote Clipboard Read (OSC 52)", isOn: $allowRemoteClipboardRead)
            }

            Section("Security") {
                Toggle("Privacy Mode", isOn: $privacyModeEnabled)
                    .onChange(of: privacyModeEnabled) { _, enabled in
                        if enabled && !lockManager.hasPIN {
                            pinSetupMode = .create
                            showPINSetup = true
                        } else if !enabled && lockManager.hasPIN {
                            showRemoveConfirmation = true
                        }
                    }

                if privacyModeEnabled && lockManager.hasPIN {
                    Button("Change PIN") {
                        pinSetupMode = .change
                        showPINChange = true
                    }
                }

                if privacyModeEnabled && lockManager.hasPIN && lockManager.biometricsAvailable {
                    let name = lockManager.biometricType == .faceID ? "Face ID" : "Touch ID"
                    Toggle("Unlock with \(name)", isOn: $biometricUnlockEnabled)
                }
            }
            .sheet(isPresented: $showPINSetup, onDismiss: {
                if !lockManager.hasPIN {
                    privacyModeEnabled = false
                }
            }) {
                PINSetupView(mode: .create)
            }
            .sheet(isPresented: $showPINChange) {
                PINSetupView(mode: .change)
            }
            .confirmationDialog(
                "Remove PIN?",
                isPresented: $showRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove PIN", role: .destructive) {
                    biometricUnlockEnabled = false
                    Task {
                        try? await lockManager.removePIN()
                    }
                }
                Button("Cancel", role: .cancel) {
                    privacyModeEnabled = true
                }
            } message: {
                Text("This will disable privacy mode and remove your PIN.")
            }

            Section("Theme") {
                Picker("Color Scheme", selection: $colorScheme) {
                    Text("Default").tag("Default")
                    Text("Catppuccin Mocha").tag("Catppuccin Mocha")
                    Text("Catppuccin Latte").tag("Catppuccin Latte")
                    Text("Tokyo Night").tag("Tokyo Night")
                    Text("Gruvbox Dark").tag("Gruvbox Dark")
                    Text("Dracula").tag("Dracula")
                    Text("Nord").tag("Nord")
                    Text("Monokai").tag("Monokai")
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
                NavigationLink("Acknowledgements") {
                    AcknowledgementsView()
                }
                Link("Privacy Policy", destination: URL(string: "https://github.com/ocnc/spectty/blob/main/PRIVACY.md")!)
                Link("Terms of Service", destination: URL(string: "https://github.com/ocnc/spectty/blob/main/TERMS.md")!)
            }
        }
        .navigationTitle("Settings")
    }
}
