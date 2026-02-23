import SwiftUI
import CryptoKit
import SpecttyKeychain

struct ConnectionEditorView: View {
    @Bindable var connection: ServerConnection
    let isNew: Bool
    let onSave: (ServerConnection) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var keyValidationError: String?
    @State private var derivedPublicKey: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $connection.name)
                        .textInputAutocapitalization(.never)
                    TextField("Host", text: $connection.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $connection.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section("Authentication") {
                    TextField("Username", text: $connection.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Method", selection: $connection.authMethod) {
                        ForEach(AuthMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }

                    if connection.authMethod == .password {
                        SecureField("Password", text: $connection.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if connection.authMethod == .publicKey {
                        TextEditor(text: $connection.privateKeyPEM)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(minHeight: 120)
                            .overlay(alignment: .topLeading) {
                                if connection.privateKeyPEM.isEmpty {
                                    Text("Paste private key (PEM format)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                            .onChange(of: connection.privateKeyPEM) {
                                validatePrivateKey()
                            }

                        if let error = keyValidationError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let pubKey = derivedPublicKey {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Public Key")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = pubKey
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                            .font(.caption)
                                    }
                                }
                                Text(pubKey)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                Section("Transport") {
                    Picker("Protocol", selection: $connection.transport) {
                        ForEach(TransportType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("e.g. tmux new-session -A -s main", text: startupCommandBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Startup Command")
                } footer: {
                    Text("Runs automatically after connecting. Useful for attaching to tmux or screen sessions.")
                }
            }
            .navigationTitle(isNew ? "New Connection" : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await saveCredentialsToKeychain()
                            onSave(connection)
                            dismiss()
                        }
                    }
                    .disabled(!isSaveEnabled)
                }
            }
            .onAppear {
                loadExistingKey()
            }
        }
    }

    private var isSaveEnabled: Bool {
        guard !connection.host.isEmpty, !connection.username.isEmpty else { return false }
        if connection.authMethod == .publicKey {
            return !connection.privateKeyPEM.isEmpty && keyValidationError == nil && derivedPublicKey != nil
        }
        return true
    }

    private var startupCommandBinding: Binding<String> {
        Binding(
            get: { connection.startupCommand ?? "" },
            set: { connection.startupCommand = $0.isEmpty ? nil : $0 }
        )
    }

    private func validatePrivateKey() {
        let pem = connection.privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pem.isEmpty else {
            keyValidationError = nil
            derivedPublicKey = nil
            return
        }

        do {
            let parsed = try SSHKeyImporter.importKey(from: pem)

            // Check for RSA (not supported by NIOSSH)
            if parsed.keyType == .rsa {
                keyValidationError = "RSA keys are not supported. Use Ed25519 or ECDSA."
                derivedPublicKey = nil
                return
            }

            // Trial CryptoKit construction — surface encoding errors at edit time,
            // not at connection time.
            switch parsed.keyType {
            case .ed25519:
                _ = try Curve25519.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
            case .ecdsaP256:
                _ = try P256.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
            case .ecdsaP384:
                _ = try P384.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
            case .rsa:
                break // Already rejected above
            }

            keyValidationError = nil

            // Derive OpenSSH public key for display
            switch parsed.keyType {
            case .ed25519:
                let keyPair = GeneratedKeyPair(
                    privateKeyData: parsed.privateKeyData,
                    publicKeyData: parsed.publicKeyData,
                    keyType: .ed25519
                )
                derivedPublicKey = KeyGenerator.openSSHPublicKey(for: keyPair)
            case .ecdsaP256:
                let keyPair = GeneratedKeyPair(
                    privateKeyData: parsed.privateKeyData,
                    publicKeyData: parsed.publicKeyData,
                    keyType: .ecdsaP256
                )
                derivedPublicKey = KeyGenerator.openSSHPublicKey(for: keyPair)
            case .ecdsaP384:
                let keyPair = GeneratedKeyPair(
                    privateKeyData: parsed.privateKeyData,
                    publicKeyData: parsed.publicKeyData,
                    keyType: .ecdsaP384
                )
                derivedPublicKey = KeyGenerator.openSSHPublicKey(for: keyPair)
            case .rsa:
                break // Already handled above
            }
        } catch let error as SSHKeyImportError {
            derivedPublicKey = nil
            switch error {
            case .invalidPEMFormat:
                keyValidationError = "Invalid format. Paste the full private key including -----BEGIN OPENSSH PRIVATE KEY----- markers."
            case .base64DecodingFailed:
                keyValidationError = "Invalid key data — base64 decoding failed."
            case .invalidKeyFormat:
                keyValidationError = "Invalid OpenSSH key format."
            case .encryptedKeysNotSupported:
                keyValidationError = "Encrypted keys are not supported. Decrypt with:\nssh-keygen -p -f your_key"
            case .rsaNotSupported:
                keyValidationError = "RSA keys are not supported. Use Ed25519 or ECDSA."
            case .unsupportedKeyType(let type):
                keyValidationError = "Unsupported key type: \(type)"
            case .corruptedKeyData:
                keyValidationError = "Key data appears corrupted."
            }
        } catch {
            derivedPublicKey = nil
            keyValidationError = "Failed to parse key: \(error.localizedDescription)"
        }
    }

    private func loadExistingKey() {
        guard !isNew,
              connection.authMethod == .publicKey,
              connection.privateKeyKeychainAccount != nil else { return }
        let account = "private-key-\(connection.id.uuidString)"
        Task {
            let keychain = KeychainManager()
            if let data = try? await keychain.load(account: account),
               let pem = String(data: data, encoding: .utf8) {
                connection.privateKeyPEM = pem
                validatePrivateKey()
            }
        }
    }

    private func saveCredentialsToKeychain() async {
        let keychain = KeychainManager()
        let uuid = connection.id.uuidString

        switch connection.authMethod {
        case .password:
            // Clean up the key from the other auth method.
            try? await keychain.delete(account: "private-key-\(uuid)")
            connection.privateKeyKeychainAccount = nil

            guard !connection.password.isEmpty else { return }
            let account = "password-\(uuid)"
            try? await keychain.saveOrUpdate(
                key: Data(connection.password.utf8),
                account: account
            )

        case .publicKey:
            // Clean up the credential from the other auth method.
            try? await keychain.delete(account: "password-\(uuid)")

            guard !connection.privateKeyPEM.isEmpty else { return }
            let account = "private-key-\(uuid)"
            try? await keychain.saveOrUpdate(
                key: Data(connection.privateKeyPEM.utf8),
                account: account
            )
            connection.privateKeyKeychainAccount = account

        case .keyboardInteractive:
            // Clean up credentials from both other methods.
            try? await keychain.delete(account: "password-\(uuid)")
            try? await keychain.delete(account: "private-key-\(uuid)")
            connection.privateKeyKeychainAccount = nil
        }
    }
}
