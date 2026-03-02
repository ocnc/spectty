import Foundation
import CryptoKit

// MARK: - SSHKeyType

/// The algorithm family of an imported SSH key.
public enum SSHKeyType: String, Sendable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case rsa
}

// MARK: - ParsedSSHKey

/// The result of parsing an OpenSSH private key file.
public struct ParsedSSHKey: Sendable {
    /// The algorithm family.
    public let keyType: SSHKeyType
    /// Raw public key bytes (algorithm-specific).
    public let publicKeyData: Data
    /// Raw private key bytes (algorithm-specific).
    public let privateKeyData: Data
}

// MARK: - SSHKeyImportError

/// Errors raised while importing an OpenSSH private key.
public enum SSHKeyImportError: Error, Sendable {
    /// The PEM envelope is missing or malformed.
    case invalidPEMFormat
    /// The binary payload could not be decoded from base64.
    case base64DecodingFailed
    /// The binary structure does not match the expected OpenSSH format.
    case invalidKeyFormat
    /// The file contains an encrypted key; decryption is not yet implemented.
    case encryptedKeysNotSupported
    /// The key uses RSA, which is not supported.
    case rsaNotSupported
    /// The key uses an algorithm that this importer does not handle.
    case unsupportedKeyType(String)
    /// An internal consistency check failed (e.g. check-int mismatch).
    case corruptedKeyData
}

// MARK: - SSHKeyImporter

/// Parses OpenSSH private key files (the `-----BEGIN OPENSSH PRIVATE KEY-----` PEM format)
/// and returns the raw key material suitable for use with CryptoKit.
///
/// Only **unencrypted** Ed25519 and ECDSA (P-256/P-384) keys are currently supported.
public struct SSHKeyImporter: Sendable {

    public init() {}

    // MARK: Public API

    /// Parse an OpenSSH private key from its PEM-encoded text representation.
    ///
    /// - Parameter pemString: The full contents of an OpenSSH private key file, including the
    ///                        `BEGIN` / `END` markers.
    /// - Returns: A ``ParsedSSHKey`` with the extracted key material.
    /// - Throws: An ``SSHKeyImportError`` describing why parsing failed.
    public static func importKey(from pemString: String) throws -> ParsedSSHKey {
        let binaryData = try decodePEM(pemString)
        return try parseOpenSSHKey(binaryData)
    }

    /// Parse an OpenSSH private key from raw `Data` that has already been base64-decoded.
    ///
    /// - Parameter data: The binary content between the PEM markers.
    /// - Returns: A ``ParsedSSHKey`` with the extracted key material.
    /// - Throws: An ``SSHKeyImportError`` describing why parsing failed.
    public static func importKey(from data: Data) throws -> ParsedSSHKey {
        try parseOpenSSHKey(data)
    }

    // MARK: PEM Decoding

    /// Strip the PEM envelope and base64-decode the payload.
    private static func decodePEM(_ pem: String) throws -> Data {
        let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let endMarker = "-----END OPENSSH PRIVATE KEY-----"

        guard let beginRange = pem.range(of: beginMarker),
              let endRange = pem.range(of: endMarker) else {
            throw SSHKeyImportError.invalidPEMFormat
        }

        let base64Body = pem[beginRange.upperBound..<endRange.lowerBound]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard let data = Data(base64Encoded: base64Body) else {
            throw SSHKeyImportError.base64DecodingFailed
        }

        return data
    }

    // MARK: Binary Parsing

    /// Parse the decoded OpenSSH key binary format.
    ///
    /// Reference: https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key
    ///
    /// ```
    /// "openssh-key-v1\0"      magic
    /// string  ciphername      (e.g. "none")
    /// string  kdfname         (e.g. "none")
    /// string  kdfoptions      (empty string for "none")
    /// uint32  number-of-keys  (always 1 for files we support)
    /// string  public-key-blob
    /// string  private-key-blob  (possibly encrypted)
    /// ```
    private static func parseOpenSSHKey(_ data: Data) throws -> ParsedSSHKey {
        let magic = "openssh-key-v1\0"
        let magicData = Data(magic.utf8)

        guard data.count > magicData.count,
              data.prefix(magicData.count) == magicData else {
            throw SSHKeyImportError.invalidKeyFormat
        }

        var reader = SSHDataReader(data: data, offset: magicData.count)

        // ciphername
        let cipherName = try reader.readString()
        // kdfname
        let kdfName = try reader.readString()
        // kdfoptions (ignored)
        _ = try reader.readBytes()

        // Reject encrypted keys.
        if cipherName != "none" || kdfName != "none" {
            throw SSHKeyImportError.encryptedKeysNotSupported
        }

        // number of keys
        let numberOfKeys = try reader.readUInt32()
        guard numberOfKeys >= 1 else {
            throw SSHKeyImportError.invalidKeyFormat
        }

        // public key blob (we parse the type from this)
        let publicKeyBlob = try reader.readBytes()

        // private section blob
        let privateSectionBlob = try reader.readBytes()

        // Parse the public key blob to determine type.
        var pubReader = SSHDataReader(data: publicKeyBlob, offset: 0)
        let keyTypeName = try pubReader.readString()

        // Determine SSHKeyType
        let sshKeyType: SSHKeyType
        switch keyTypeName {
        case "ssh-ed25519":
            sshKeyType = .ed25519
        case "ecdsa-sha2-nistp256":
            sshKeyType = .ecdsaP256
        case "ecdsa-sha2-nistp384":
            sshKeyType = .ecdsaP384
        case "ssh-rsa":
            throw SSHKeyImportError.rsaNotSupported
        default:
            throw SSHKeyImportError.unsupportedKeyType(keyTypeName)
        }

        // Parse the private section.
        var privReader = SSHDataReader(data: privateSectionBlob, offset: 0)

        // Two uint32 check integers that must match.
        let checkInt1 = try privReader.readUInt32()
        let checkInt2 = try privReader.readUInt32()
        guard checkInt1 == checkInt2 else {
            throw SSHKeyImportError.corruptedKeyData
        }

        // Key type string (again).
        let privKeyTypeName = try privReader.readString()
        guard privKeyTypeName == keyTypeName else {
            throw SSHKeyImportError.invalidKeyFormat
        }

        switch sshKeyType {
        case .ed25519:
            return try parseEd25519PrivateSection(&privReader)
        case .ecdsaP256:
            return try parseECDSAPrivateSection(&privReader, keyType: .ecdsaP256)
        case .ecdsaP384:
            return try parseECDSAPrivateSection(&privReader, keyType: .ecdsaP384)
        case .rsa:
            throw SSHKeyImportError.rsaNotSupported
        }
    }

    // MARK: Ed25519 Private Section

    /// Parse the private section for an Ed25519 key.
    ///
    /// Layout after key-type string:
    /// ```
    /// string  public-key  (32 bytes)
    /// string  private-key (64 bytes: 32-byte seed || 32-byte public key)
    /// string  comment
    /// ```
    private static func parseEd25519PrivateSection(
        _ reader: inout SSHDataReader
    ) throws -> ParsedSSHKey {
        let publicKey = try reader.readBytes()
        let privateKeyFull = try reader.readBytes()
        // comment (ignored)
        _ = try? reader.readString()

        // The "private key" in OpenSSH format is seed (32) || public (32). We want the seed.
        guard publicKey.count == 32, privateKeyFull.count == 64 else {
            throw SSHKeyImportError.invalidKeyFormat
        }

        let seed = privateKeyFull.prefix(32)

        return ParsedSSHKey(
            keyType: .ed25519,
            publicKeyData: publicKey,
            privateKeyData: Data(seed)
        )
    }

    // MARK: ECDSA Private Section

    /// Parse the private section for an ECDSA key.
    ///
    /// Layout after key-type string:
    /// ```
    /// string  curve-name   (e.g. "nistp256")
    /// string  public-key   (uncompressed EC point, 65 bytes for P-256)
    /// string  private-key  (big-endian scalar, 32 bytes for P-256)
    /// string  comment
    /// ```
    private static func parseECDSAPrivateSection(
        _ reader: inout SSHDataReader,
        keyType: SSHKeyType
    ) throws -> ParsedSSHKey {
        // curve identifier
        _ = try reader.readString()
        let publicKey = try reader.readBytes()
        let privateKeyRaw = try reader.readBytes()
        // comment (ignored)
        _ = try? reader.readString()

        // Determine the expected sizes for this curve.
        let scalarLength: Int
        let uncompressedPointLength: Int
        switch keyType {
        case .ecdsaP256:
            scalarLength = 32
            uncompressedPointLength = 65  // 0x04 + 32 + 32
        case .ecdsaP384:
            scalarLength = 48
            uncompressedPointLength = 97  // 0x04 + 48 + 48
        default:
            throw SSHKeyImportError.invalidKeyFormat
        }

        // Validate the uncompressed EC public key point size.
        guard publicKey.count == uncompressedPointLength else {
            throw SSHKeyImportError.invalidKeyFormat
        }

        // OpenSSH encodes the private scalar as an mpint (SSH bignum2):
        // - A leading 0x00 byte is prepended when the high bit is set (~50% of keys).
        // - Leading zero bytes may be stripped (rare).
        // Normalize to the exact fixed-width scalar CryptoKit expects.
        let privateKey = normalizeMpint(privateKeyRaw, toLength: scalarLength)
        guard privateKey.count == scalarLength else {
            throw SSHKeyImportError.invalidKeyFormat
        }

        return ParsedSSHKey(
            keyType: keyType,
            publicKeyData: publicKey,
            privateKeyData: privateKey
        )
    }

    /// Normalize an SSH mpint-encoded scalar to a fixed-width byte array.
    ///
    /// Strips a leading `0x00` sign byte (added when the high bit is set) and
    /// left-pads short representations to the required length.
    private static func normalizeMpint(_ data: Data, toLength length: Int) -> Data {
        var trimmed = data[...]
        // Strip leading zero bytes that exceed the target length (mpint sign padding).
        while trimmed.count > length, trimmed.first == 0x00 {
            trimmed = trimmed.dropFirst()
        }
        // Left-pad if the scalar is shorter than expected (rare but valid).
        if trimmed.count < length {
            return Data(repeating: 0, count: length - trimmed.count) + trimmed
        }
        return Data(trimmed)
    }
}

// MARK: - SSHDataReader

/// A simple cursor-based reader for SSH binary wire format data.
///
/// SSH wire format uses big-endian uint32 length prefixes before strings and byte blobs.
private struct SSHDataReader: Sendable {
    let data: Data
    var offset: Int

    init(data: Data, offset: Int) {
        self.data = data
        self.offset = offset
    }

    /// Read a big-endian `UInt32` and advance the cursor.
    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SSHKeyImportError.invalidKeyFormat
        }
        let value: UInt32 = data.withUnsafeBytes { buf in
            let start = buf.baseAddress!.advanced(by: offset)
            return start.loadUnaligned(as: UInt32.self)
        }
        offset += 4
        return UInt32(bigEndian: value)
    }

    /// Read a length-prefixed byte blob and advance the cursor.
    mutating func readBytes() throws -> Data {
        let length = Int(try readUInt32())
        guard length >= 0, offset + length <= data.count else {
            throw SSHKeyImportError.invalidKeyFormat
        }
        let bytes = data[offset..<(offset + length)]
        offset += length
        return Data(bytes)
    }

    /// Read a length-prefixed UTF-8 string and advance the cursor.
    mutating func readString() throws -> String {
        let bytes = try readBytes()
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw SSHKeyImportError.invalidKeyFormat
        }
        return string
    }
}
