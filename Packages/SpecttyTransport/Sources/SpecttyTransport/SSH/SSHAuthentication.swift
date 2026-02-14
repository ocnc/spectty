import Foundation
import NIOCore
import NIOSSH

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

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
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

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
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

/// Placeholder server authentication delegate that accepts all host keys.
///
/// **WARNING**: This is insecure. A real implementation should verify the
/// host key against a known-hosts database.
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // TODO: Replace with real host key verification (known_hosts, TOFU, etc.)
        validationCompletePromise.succeed(())
    }
}

extension AcceptAllHostKeysDelegate: @unchecked Sendable {}
