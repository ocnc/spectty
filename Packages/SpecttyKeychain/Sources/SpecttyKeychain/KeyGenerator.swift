import Foundation
import CryptoKit

// MARK: - GeneratedKeyPair

/// A freshly generated SSH key pair containing both the private and public key material.
public struct GeneratedKeyPair: Sendable {
    /// The raw private key bytes.
    public let privateKeyData: Data
    /// The raw public key bytes.
    public let publicKeyData: Data
    /// The SSH key type that was generated.
    public let keyType: GeneratedKeyType
}

/// The algorithm used when generating a key pair.
public enum GeneratedKeyType: String, Sendable {
    case ed25519
    case ecdsaP256
    case secureEnclaveP256
}

// MARK: - KeyGenerator

/// Generates SSH key pairs using CryptoKit algorithms.
///
/// All methods are static and the struct carries no mutable state, so it is unconditionally
/// `Sendable`.
public struct KeyGenerator: Sendable {

    public init() {}

    // MARK: Ed25519

    /// Generate an Ed25519 key pair using `Curve25519.Signing`.
    ///
    /// - Returns: A ``GeneratedKeyPair`` whose `privateKeyData` is the 32-byte seed and
    ///            `publicKeyData` is the 32-byte public key.
    public static func generateEd25519() -> GeneratedKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        return GeneratedKeyPair(
            privateKeyData: privateKey.rawRepresentation,
            publicKeyData: privateKey.publicKey.rawRepresentation,
            keyType: .ed25519
        )
    }

    // MARK: ECDSA P-256

    /// Generate an ECDSA P-256 key pair using `P256.Signing`.
    ///
    /// - Returns: A ``GeneratedKeyPair`` whose `privateKeyData` is the x963 representation
    ///            and `publicKeyData` is the compressed public key representation.
    public static func generateP256() -> GeneratedKeyPair {
        let privateKey = P256.Signing.PrivateKey()
        return GeneratedKeyPair(
            privateKeyData: privateKey.x963Representation,
            publicKeyData: privateKey.publicKey.compressedRepresentation,
            keyType: .ecdsaP256
        )
    }

    // MARK: Secure Enclave P-256

    /// Generate an ECDSA P-256 key pair backed by the Secure Enclave.
    ///
    /// - Returns: A ``GeneratedKeyPair`` whose `privateKeyData` is the Secure Enclave data
    ///            representation (an opaque blob that can only be used on this device) and
    ///            `publicKeyData` is the compressed public key.
    /// - Throws: If the Secure Enclave is not available or key generation fails.
    public static func generateSecureEnclaveP256() throws -> GeneratedKeyPair {
        let privateKey = try SecureEnclave.P256.Signing.PrivateKey()
        return GeneratedKeyPair(
            privateKeyData: privateKey.dataRepresentation,
            publicKeyData: privateKey.publicKey.compressedRepresentation,
            keyType: .secureEnclaveP256
        )
    }

    // MARK: OpenSSH Public Key Export

    /// Format a public key as an OpenSSH `authorized_keys` line.
    ///
    /// The returned string has the form:
    /// ```
    /// ssh-ed25519 AAAA...base64... comment
    /// ```
    ///
    /// - Parameters:
    ///   - keyPair: The generated key pair whose public key will be exported.
    ///   - comment: An optional trailing comment (e.g. user@host).
    /// - Returns: A single-line string suitable for appending to `~/.ssh/authorized_keys`.
    public static func openSSHPublicKey(
        for keyPair: GeneratedKeyPair,
        comment: String = ""
    ) -> String {
        let blob: Data
        let algorithmName: String

        switch keyPair.keyType {
        case .ed25519:
            algorithmName = "ssh-ed25519"
            blob = Self.buildEd25519Blob(publicKey: keyPair.publicKeyData)

        case .ecdsaP256, .secureEnclaveP256:
            algorithmName = "ecdsa-sha2-nistp256"
            blob = Self.buildECDSAP256Blob(publicKey: keyPair.publicKeyData)
        }

        let base64 = blob.base64EncodedString()

        if comment.isEmpty {
            return "\(algorithmName) \(base64)"
        }
        return "\(algorithmName) \(base64) \(comment)"
    }

    // MARK: Wire-format helpers

    /// Build the SSH wire-format blob for an Ed25519 public key.
    ///
    /// Layout: `string "ssh-ed25519"` || `string <32-byte public key>`
    private static func buildEd25519Blob(publicKey: Data) -> Data {
        var blob = Data()
        let keyType = "ssh-ed25519"
        blob.appendSSHString(keyType)
        blob.appendSSHBytes(publicKey)
        return blob
    }

    /// Build the SSH wire-format blob for an ECDSA P-256 public key.
    ///
    /// Layout: `string "ecdsa-sha2-nistp256"` || `string "nistp256"` || `string <EC point>`
    ///
    /// The public key must be provided in compressed or uncompressed SEC1 form.  CryptoKit's
    /// `compressedRepresentation` (33 bytes, 0x02/0x03 prefix) works here, though many SSH
    /// implementations send the uncompressed form (65 bytes, 0x04 prefix).  To maximise
    /// compatibility we convert compressed to uncompressed when possible.
    private static func buildECDSAP256Blob(publicKey: Data) -> Data {
        var blob = Data()
        let keyType = "ecdsa-sha2-nistp256"
        let curveName = "nistp256"
        blob.appendSSHString(keyType)
        blob.appendSSHString(curveName)

        // If the key is in compressed form (33 bytes), attempt to expand it to uncompressed
        // form via CryptoKit for maximum interoperability.
        let ecPoint: Data
        if publicKey.count == 33,
           let full = try? P256.Signing.PublicKey(compressedRepresentation: publicKey) {
            ecPoint = Data(full.x963Representation)
        } else {
            ecPoint = publicKey
        }

        blob.appendSSHBytes(ecPoint)
        return blob
    }
}

// MARK: - Data + SSH Wire Helpers

extension Data {
    /// Append a UTF-8 string prefixed by its uint32 byte length (SSH wire format).
    mutating func appendSSHString(_ string: String) {
        let utf8 = Data(string.utf8)
        appendSSHBytes(utf8)
    }

    /// Append a data blob prefixed by its uint32 byte length (SSH wire format).
    mutating func appendSSHBytes(_ data: Data) {
        var length = UInt32(data.count).bigEndian
        append(Data(bytes: &length, count: 4))
        append(data)
    }
}
