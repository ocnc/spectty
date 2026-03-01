import Foundation
import CryptoKit
import NIOCore
import NIOSSH

/// Lightweight tag identifying the SSH auth method (for serialisation).
public enum SSHAuthMethodType: String, Codable, Sendable {
    case password
    case publicKey
}

/// SSH authentication method offered by the client.
public enum SSHAuthMethod: Sendable {
    case password(String)
    case publicKey(NIOSSHPrivateKey)
}

// MARK: - Password Delegate

/// Client user-auth delegate that offers a password.
final class SSHPasswordDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var attempted = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // If we already tried, don't loop — auth was rejected.
        guard !attempted else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }
        attempted = true

        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
        )
    }
}

extension SSHPasswordDelegate: @unchecked Sendable {}

// MARK: - Public Key Delegate

/// Client user-auth delegate that offers a private key.
final class SSHPublicKeyDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var attempted = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !attempted else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }
        attempted = true

        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed)
            return
        }

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}

extension SSHPublicKeyDelegate: @unchecked Sendable {}

// MARK: - Host Key Delegate

/// Server authentication delegate using TOFU (Trust On First Use).
final class TOFUHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private let trustStore: SSHHostKeyTrustStore

    init(host: String, port: Int, trustStore: SSHHostKeyTrustStore = .shared) {
        self.host = host
        self.port = port
        self.trustStore = trustStore
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let presentedKey = String(openSSHPublicKey: hostKey)

        Task {
            do {
                let result = try await trustStore.validate(host: host, port: port, presentedKey: presentedKey)
                validationCompletePromise.futureResult.eventLoop.execute {
                    switch result {
                    case .trusted:
                        validationCompletePromise.succeed(())
                    case .mismatch(let expected, let presented):
                        validationCompletePromise.fail(
                            SSHTransportError.hostKeyMismatch(
                                host: self.host,
                                port: self.port,
                                expectedFingerprint: Self.fingerprint(forOpenSSHKey: expected),
                                presentedFingerprint: Self.fingerprint(forOpenSSHKey: presented)
                            )
                        )
                    }
                }
            } catch {
                validationCompletePromise.futureResult.eventLoop.execute {
                    validationCompletePromise.fail(
                        SSHTransportError.hostKeyTrustStoreFailed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private static func fingerprint(forOpenSSHKey openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let keyData = Data(base64Encoded: String(parts[1])) else {
            return "unknown"
        }

        let digest = SHA256.hash(data: keyData)
        return Data(digest).base64EncodedString()
    }
}

extension TOFUHostKeysDelegate: @unchecked Sendable {}
