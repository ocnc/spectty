import Testing
import Foundation
import CryptoKit
@testable import SpecttyKeychain

// MARK: - OpenSSH Blob Builder

/// Helpers for constructing synthetic OpenSSH private key PEMs in tests.
/// This gives precise control over the binary encoding (e.g. mpint padding)
/// without depending on external tools.
private enum OpenSSHBlobBuilder {

    static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 4))
    }

    static func appendSSHBytes(_ data: inout Data, _ bytes: Data) {
        appendUInt32(&data, UInt32(bytes.count))
        data.append(bytes)
    }

    static func appendSSHString(_ data: inout Data, _ string: String) {
        appendSSHBytes(&data, Data(string.utf8))
    }

    /// Build a complete OpenSSH PEM from public key blob and private section blob.
    static func buildPEM(publicKeyBlob: Data, privateSectionBlob: Data) -> String {
        var data = Data()
        // Magic
        data.append(Data("openssh-key-v1\0".utf8))
        // ciphername: "none"
        appendSSHString(&data, "none")
        // kdfname: "none"
        appendSSHString(&data, "none")
        // kdfoptions: empty
        appendSSHBytes(&data, Data())
        // number of keys: 1
        appendUInt32(&data, 1)
        // public key blob
        appendSSHBytes(&data, publicKeyBlob)
        // private section blob
        appendSSHBytes(&data, privateSectionBlob)

        let b64 = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(b64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    /// Build an Ed25519 PEM from raw key material.
    static func ed25519PEM(publicKey: Data, seed: Data) -> String {
        // Public key blob: type string + public key
        var pubBlob = Data()
        appendSSHString(&pubBlob, "ssh-ed25519")
        appendSSHBytes(&pubBlob, publicKey)

        // Private section: check ints + type + pub + priv (seed||pub) + comment + padding
        let checkInt: UInt32 = 0x12345678
        var privSection = Data()
        appendUInt32(&privSection, checkInt)
        appendUInt32(&privSection, checkInt)
        appendSSHString(&privSection, "ssh-ed25519")
        appendSSHBytes(&privSection, publicKey)
        appendSSHBytes(&privSection, seed + publicKey) // OpenSSH stores seed(32) || public(32)
        appendSSHString(&privSection, "test@spectty")
        // Pad to 8-byte alignment
        let padLen = (8 - (privSection.count % 8)) % 8
        for i in 0..<padLen {
            privSection.append(UInt8((i + 1) & 0xFF))
        }

        return buildPEM(publicKeyBlob: pubBlob, privateSectionBlob: privSection)
    }

    /// Build an ECDSA PEM from raw key material.
    /// `privateScalar` is the raw bytes to store in the private section —
    /// pass a 33-byte array (with leading 0x00) to simulate mpint padding.
    static func ecdsaPEM(
        keyTypeName: String,
        curveName: String,
        publicPoint: Data,
        privateScalar: Data
    ) -> String {
        // Public key blob: type string + curve name + EC point
        var pubBlob = Data()
        appendSSHString(&pubBlob, keyTypeName)
        appendSSHString(&pubBlob, curveName)
        appendSSHBytes(&pubBlob, publicPoint)

        // Private section
        let checkInt: UInt32 = 0x12345678
        var privSection = Data()
        appendUInt32(&privSection, checkInt)
        appendUInt32(&privSection, checkInt)
        appendSSHString(&privSection, keyTypeName)
        appendSSHString(&privSection, curveName)
        appendSSHBytes(&privSection, publicPoint)
        appendSSHBytes(&privSection, privateScalar)
        appendSSHString(&privSection, "test@spectty")
        // Pad to 8-byte alignment
        let padLen = (8 - (privSection.count % 8)) % 8
        for i in 0..<padLen {
            privSection.append(UInt8((i + 1) & 0xFF))
        }

        return buildPEM(publicKeyBlob: pubBlob, privateSectionBlob: privSection)
    }

    static func ecdsaP256PEM(publicPoint: Data, privateScalar: Data) -> String {
        ecdsaPEM(
            keyTypeName: "ecdsa-sha2-nistp256",
            curveName: "nistp256",
            publicPoint: publicPoint,
            privateScalar: privateScalar
        )
    }

    static func ecdsaP384PEM(publicPoint: Data, privateScalar: Data) -> String {
        ecdsaPEM(
            keyTypeName: "ecdsa-sha2-nistp384",
            curveName: "nistp384",
            publicPoint: publicPoint,
            privateScalar: privateScalar
        )
    }

    /// Build a PEM with mismatched check integers (for corrupted-data error test).
    static func corruptedCheckIntsPEM() -> String {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = Data(key.publicKey.rawRepresentation)
        let seed = Data(key.rawRepresentation)

        var pubBlob = Data()
        appendSSHString(&pubBlob, "ssh-ed25519")
        appendSSHBytes(&pubBlob, publicKey)

        var privSection = Data()
        appendUInt32(&privSection, 0xAAAAAAAA)
        appendUInt32(&privSection, 0xBBBBBBBB) // Mismatch!
        appendSSHString(&privSection, "ssh-ed25519")
        appendSSHBytes(&privSection, publicKey)
        appendSSHBytes(&privSection, seed + publicKey)
        appendSSHString(&privSection, "test")

        return buildPEM(publicKeyBlob: pubBlob, privateSectionBlob: privSection)
    }
}

// MARK: - Ed25519 Import Tests

@Suite("SSHKeyImporter — Ed25519")
struct Ed25519ImportTests {

    @Test("Imports CryptoKit-generated Ed25519 key via synthetic PEM")
    func importSyntheticEd25519() throws {
        let original = Curve25519.Signing.PrivateKey()
        let seed = Data(original.rawRepresentation)
        let publicKey = Data(original.publicKey.rawRepresentation)

        let pem = OpenSSHBlobBuilder.ed25519PEM(publicKey: publicKey, seed: seed)
        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.keyType == .ed25519)
        #expect(parsed.publicKeyData == publicKey)
        #expect(parsed.privateKeyData == seed)
        #expect(parsed.privateKeyData.count == 32)
    }

    @Test("Imported Ed25519 key produces valid CryptoKit key")
    func ed25519CryptoKitRoundTrip() throws {
        let original = Curve25519.Signing.PrivateKey()
        let seed = Data(original.rawRepresentation)
        let publicKey = Data(original.publicKey.rawRepresentation)

        let pem = OpenSSHBlobBuilder.ed25519PEM(publicKey: publicKey, seed: seed)
        let parsed = try SSHKeyImporter.importKey(from: pem)

        let reconstructed = try Curve25519.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
        #expect(Data(reconstructed.publicKey.rawRepresentation) == publicKey)
    }

    @Test("Imports real ssh-keygen Ed25519 key")
    func importRealEd25519Key() throws {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACCCe7ztSqE/WbDn/Ru+j9QjSHhp7D/6OnbCrRl0R+w0awAAAJDMZW0szGVt
        LAAAAAtzc2gtZWQyNTUxOQAAACCCe7ztSqE/WbDn/Ru+j9QjSHhp7D/6OnbCrRl0R+w0aw
        AAAEDvwyTjwyUukWJIhB99y11HfH67Ac6lnXgFA+7Bh/ITxoJ7vO1KoT9ZsOf9G76P1CNI
        eGnsP/o6dsKtGXRH7DRrAAAADHRlc3RAc3BlY3R0eQE=
        -----END OPENSSH PRIVATE KEY-----
        """
        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.keyType == .ed25519)
        #expect(parsed.publicKeyData.count == 32)
        #expect(parsed.privateKeyData.count == 32)

        // Verify CryptoKit accepts the key material
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
        #expect(Data(key.publicKey.rawRepresentation) == parsed.publicKeyData)
    }
}

// MARK: - ECDSA P-256 Import Tests

@Suite("SSHKeyImporter — ECDSA P-256")
struct ECDSAP256ImportTests {

    @Test("Imports P-256 key with exact 32-byte scalar")
    func importExactWidthScalar() throws {
        let original = P256.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation) // 32 bytes
        let publicPoint = Data(original.publicKey.x963Representation) // 65 bytes

        let pem = OpenSSHBlobBuilder.ecdsaP256PEM(
            publicPoint: publicPoint,
            privateScalar: rawScalar
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.keyType == .ecdsaP256)
        #expect(parsed.privateKeyData.count == 32)
        #expect(parsed.privateKeyData == rawScalar)
        #expect(parsed.publicKeyData.count == 65)
        #expect(parsed.publicKeyData == publicPoint)
    }

    @Test("Normalizes 33-byte mpint-padded scalar to 32 bytes")
    func normalizeMpintPaddedScalar() throws {
        let original = P256.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation) // 32 bytes
        let publicPoint = Data(original.publicKey.x963Representation) // 65 bytes

        // Simulate OpenSSH mpint encoding: prepend 0x00 (happens when high bit is set)
        let mpintScalar = Data([0x00]) + rawScalar // 33 bytes

        let pem = OpenSSHBlobBuilder.ecdsaP256PEM(
            publicPoint: publicPoint,
            privateScalar: mpintScalar
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.keyType == .ecdsaP256)
        #expect(parsed.privateKeyData.count == 32)
        #expect(parsed.privateKeyData == rawScalar)
    }

    @Test("Mpint-normalized P-256 key produces valid CryptoKit key")
    func mpintNormalizedCryptoKitRoundTrip() throws {
        let original = P256.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation)
        let publicPoint = Data(original.publicKey.x963Representation)

        // 33-byte mpint
        let mpintScalar = Data([0x00]) + rawScalar

        let pem = OpenSSHBlobBuilder.ecdsaP256PEM(
            publicPoint: publicPoint,
            privateScalar: mpintScalar
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)

        // Must produce a valid CryptoKit key — this is the exact codepath that
        // failed before the mpint normalization fix.
        let reconstructed = try P256.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
        #expect(Data(reconstructed.publicKey.x963Representation) == publicPoint)
    }

    @Test("Left-pads short scalar to 32 bytes")
    func leftPadShortScalar() throws {
        let original = P256.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation)
        let publicPoint = Data(original.publicKey.x963Representation)

        // Simulate a scalar with a leading zero byte stripped (rare but valid mpint)
        // We strip the first byte (if non-zero, the normalization should left-pad it back)
        // To make this test deterministic, construct a scalar with known leading zero.
        var shortScalar = rawScalar
        // Replace first byte with 0, then drop it to simulate stripped leading zero
        shortScalar[shortScalar.startIndex] = 0x00
        let stripped = shortScalar.dropFirst() // 31 bytes

        let pem = OpenSSHBlobBuilder.ecdsaP256PEM(
            publicPoint: publicPoint,
            privateScalar: Data(stripped)
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.privateKeyData.count == 32)
        // First byte should be zero-padded back
        #expect(parsed.privateKeyData.first == 0x00)
    }

    @Test("Rejects public key point with wrong size")
    func rejectsWrongPublicPointSize() {
        let original = P256.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation)
        // Use a truncated public point (64 bytes instead of 65)
        let truncatedPoint = Data(original.publicKey.x963Representation.prefix(64))

        let pem = OpenSSHBlobBuilder.ecdsaP256PEM(
            publicPoint: truncatedPoint,
            privateScalar: rawScalar
        )

        #expect {
            try SSHKeyImporter.importKey(from: pem)
        } throws: { error in
            (error as? SSHKeyImportError).flatMap {
                if case .invalidKeyFormat = $0 { return true }
                return nil
            } ?? false
        }
    }

    @Test("Imports real ssh-keygen ECDSA P-256 key")
    func importRealP256Key() throws {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQTUhEIYX54oko+NIaGlC2C2pMaOM7ar
        0eeEpm8/Wv8sXi4/R8cRPE9UcDfxarQD6i/5IslDt0ruwzqvx9VUhQDUAAAAqBMsGs0TLB
        rNAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNSEQhhfniiSj40h
        oaULYLakxo4ztqvR54Smbz9a/yxeLj9HxxE8T1RwN/FqtAPqL/kiyUO3Su7DOq/H1VSFAN
        QAAAAhALNRTUymLunsxiELTNAHi5AGwGC1CstEoyR8nNg/ekomAAAADHRlc3RAc3BlY3R0
        eQECAw==
        -----END OPENSSH PRIVATE KEY-----
        """
        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.keyType == .ecdsaP256)
        #expect(parsed.publicKeyData.count == 65)
        #expect(parsed.privateKeyData.count == 32)

        // Verify CryptoKit accepts the key material
        let key = try P256.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
        #expect(Data(key.publicKey.x963Representation) == parsed.publicKeyData)
    }
}

// MARK: - ECDSA P-384 Import Tests

@Suite("SSHKeyImporter — ECDSA P-384")
struct ECDSAP384ImportTests {

    @Test("Imports P-384 key with exact 48-byte scalar")
    func importExactWidthScalar() throws {
        let original = P384.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation) // 48 bytes
        let publicPoint = Data(original.publicKey.x963Representation) // 97 bytes

        let pem = OpenSSHBlobBuilder.ecdsaP384PEM(
            publicPoint: publicPoint,
            privateScalar: rawScalar
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.keyType == .ecdsaP384)
        #expect(parsed.privateKeyData.count == 48)
        #expect(parsed.privateKeyData == rawScalar)
        #expect(parsed.publicKeyData.count == 97)
        #expect(parsed.publicKeyData == publicPoint)
    }

    @Test("Normalizes 49-byte mpint-padded scalar to 48 bytes")
    func normalizeMpintPaddedScalar() throws {
        let original = P384.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation) // 48 bytes
        let publicPoint = Data(original.publicKey.x963Representation) // 97 bytes

        // Simulate OpenSSH mpint encoding: prepend 0x00
        let mpintScalar = Data([0x00]) + rawScalar // 49 bytes

        let pem = OpenSSHBlobBuilder.ecdsaP384PEM(
            publicPoint: publicPoint,
            privateScalar: mpintScalar
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.keyType == .ecdsaP384)
        #expect(parsed.privateKeyData.count == 48)
        #expect(parsed.privateKeyData == rawScalar)
    }

    @Test("Mpint-normalized P-384 key produces valid CryptoKit key")
    func mpintNormalizedCryptoKitRoundTrip() throws {
        let original = P384.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation)
        let publicPoint = Data(original.publicKey.x963Representation)

        let mpintScalar = Data([0x00]) + rawScalar

        let pem = OpenSSHBlobBuilder.ecdsaP384PEM(
            publicPoint: publicPoint,
            privateScalar: mpintScalar
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)

        let reconstructed = try P384.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
        #expect(Data(reconstructed.publicKey.x963Representation) == publicPoint)
    }

    @Test("Rejects public key point with wrong size")
    func rejectsWrongPublicPointSize() {
        let original = P384.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation)
        // Use 65-byte point (P-256 size) instead of 97-byte (P-384 size)
        let wrongSizePoint = Data(repeating: 0x04, count: 65)

        let pem = OpenSSHBlobBuilder.ecdsaP384PEM(
            publicPoint: wrongSizePoint,
            privateScalar: rawScalar
        )

        #expect {
            try SSHKeyImporter.importKey(from: pem)
        } throws: { error in
            (error as? SSHKeyImportError).flatMap {
                if case .invalidKeyFormat = $0 { return true }
                return nil
            } ?? false
        }
    }

    @Test("Imports real ssh-keygen ECDSA P-384 key")
    func importRealP384Key() throws {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
        1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQRsjn+/8SQJ8CpCG0XhHiwBiCWfWsvG
        NiW9IFYInCbFkiF8NSKC2RVHYgqkl9x0vLotw8LzU+8JsF+I/8eMfQKPyUgfN7bUvqsOYn
        3Rwk9bb1dv4qv2QBb54ikc9oIyByMAAADYT3bzwE9288AAAAATZWNkc2Etc2hhMi1uaXN0
        cDM4NAAAAAhuaXN0cDM4NAAAAGEEbI5/v/EkCfAqQhtF4R4sAYgln1rLxjYlvSBWCJwmxZ
        IhfDUigtkVR2IKpJfcdLy6LcPC81PvCbBfiP/HjH0Cj8lIHze21L6rDmJ90cJPW29Xb+Kr
        9kAW+eIpHPaCMgcjAAAAMHMxYvcsZdYkW0+S5pACFVZSHl31NMLPQrxl5JaYv8+vOAamnq
        YOTnjEsU/VG6+WJwAAAAx0ZXN0QHNwZWN0dHkBAgME
        -----END OPENSSH PRIVATE KEY-----
        """
        let parsed = try SSHKeyImporter.importKey(from: pem)

        #expect(parsed.keyType == .ecdsaP384)
        #expect(parsed.publicKeyData.count == 97)
        #expect(parsed.privateKeyData.count == 48)

        // Verify CryptoKit accepts the key material
        let key = try P384.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)
        #expect(Data(key.publicKey.x963Representation) == parsed.publicKeyData)
    }
}

// MARK: - Error Handling Tests

@Suite("SSHKeyImporter — Error handling")
struct ImportErrorTests {

    @Test("Rejects text without PEM markers")
    func rejectsMissingPEMMarkers() {
        #expect {
            try SSHKeyImporter.importKey(from: "this is not a PEM key")
        } throws: { error in
            (error as? SSHKeyImportError).flatMap {
                if case .invalidPEMFormat = $0 { return true }
                return nil
            } ?? false
        }
    }

    @Test("Rejects invalid base64 within PEM markers")
    func rejectsInvalidBase64() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        !!!not-valid-base64!!!
        -----END OPENSSH PRIVATE KEY-----
        """
        #expect {
            try SSHKeyImporter.importKey(from: pem)
        } throws: { error in
            (error as? SSHKeyImportError).flatMap {
                if case .base64DecodingFailed = $0 { return true }
                return nil
            } ?? false
        }
    }

    @Test("Rejects encrypted keys")
    func rejectsEncryptedKeys() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBItPmB+S
        BVmxI1/lf6aQ/fAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAICMO4HcX6AyvXrZ2
        MRTVAw51W9lS+9H8Sf1LvvrfVs9VAAAAkITYFxZFA6ogMBJqLxHPEhVcFHsY0NtlrV/CdS
        T8IJDlpdSMlOaN0lMBvGWUo7cyIytn3SDEGxswH3VEvA05g3drfLBQtdy1lQM6aQ3udrk4
        yYtR+LxtXz/2TzqkCul/brqbOwIVYYEt02YBj7EGKtBc7VlHz1LO29yvM+tdy02WkCxgZq
        wO33rJwepfGNt1DQ==
        -----END OPENSSH PRIVATE KEY-----
        """
        #expect {
            try SSHKeyImporter.importKey(from: pem)
        } throws: { error in
            (error as? SSHKeyImportError).flatMap {
                if case .encryptedKeysNotSupported = $0 { return true }
                return nil
            } ?? false
        }
    }

    @Test("Rejects RSA keys")
    func rejectsRSAKeys() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAIEA12h9FPjbIxE/dB1IQ1/sXvGJ27BxKYYMQA91dyw/OW7cxFu9e+DQ
        dTegqOR2eIwS124bbfbFQu7yagmrUs1IYlNwjv3Hg5YpTvYS5gxeTOlq7l9LRFrQxpmeif
        +9/fpHgtIm8JK1MvTqKRTDGo4XELMc/uEilSs3GqZXlztoO+sAAAIIVt5iCVbeYgkAAAAH
        c3NoLXJzYQAAAIEA12h9FPjbIxE/dB1IQ1/sXvGJ27BxKYYMQA91dyw/OW7cxFu9e+DQdT
        egqOR2eIwS124bbfbFQu7yagmrUs1IYlNwjv3Hg5YpTvYS5gxeTOlq7l9LRFrQxpmeif+9
        /fpHgtIm8JK1MvTqKRTDGo4XELMc/uEilSs3GqZXlztoO+sAAAADAQABAAAAgQCcFMMlch
        he9X1z5k/ZOeUs+nl4rQWiH9Y6iLkFrBL3y6O9x/epjkGd3bvVBQ3u1RhF7yuC518R28/d
        E7qHGeYKvLPuZGkCfO6z2DCWayvVtV5xORrTZJWIh8cRS6mO6kFFArttERb9MVeXNtwOdT
        Yvl0L1dLyLXGWGfaCCnFcN+QAAAEAjUaanI5dimT27q1eu78vmxQUj04aQQ5FQdDF1U+zH
        oH1sFG2hDeER182uy3sooWhjltDLCyrR0A9RuGKoZwCXAAAAQQDtegUaJnQ3P0kaS2NfZv
        cQK5x1844rmwLmcCnzxn2gx0HIOf0p7zzBjuZQtE2P6IAf3LwjZ3A9jOfdMnnIg/wNAAAA
        QQDoNc0IF2LzzOQysJyfo2ukpEMl66L5aKNiiOOJ8XthUn/oc2m3XLv4n45E4OPEqZIzay
        Ww4mfwLXlXdeyQgYHXAAAADHRlc3RAc3BlY3R0eQECAwQFBg==
        -----END OPENSSH PRIVATE KEY-----
        """
        #expect {
            try SSHKeyImporter.importKey(from: pem)
        } throws: { error in
            (error as? SSHKeyImportError).flatMap {
                if case .rsaNotSupported = $0 { return true }
                return nil
            } ?? false
        }
    }

    @Test("Rejects mismatched check integers")
    func rejectsMismatchedCheckInts() {
        let pem = OpenSSHBlobBuilder.corruptedCheckIntsPEM()
        #expect {
            try SSHKeyImporter.importKey(from: pem)
        } throws: { error in
            (error as? SSHKeyImportError).flatMap {
                if case .corruptedKeyData = $0 { return true }
                return nil
            } ?? false
        }
    }

    @Test("Rejects data without OpenSSH magic")
    func rejectsMissingMagic() {
        // Valid base64 but not an OpenSSH key (just "hello world")
        let bogusB64 = Data("hello world, this is not a key".utf8).base64EncodedString()
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(bogusB64)\n-----END OPENSSH PRIVATE KEY-----\n"
        #expect {
            try SSHKeyImporter.importKey(from: pem)
        } throws: { error in
            (error as? SSHKeyImportError).flatMap {
                if case .invalidKeyFormat = $0 { return true }
                return nil
            } ?? false
        }
    }

    @Test("Rejects empty PEM content")
    func rejectsEmptyPEM() {
        #expect {
            try SSHKeyImporter.importKey(from: "")
        } throws: { error in
            error is SSHKeyImportError
        }
    }
}

// MARK: - End-to-End CryptoKit Compatibility Tests

@Suite("SSHKeyImporter — CryptoKit end-to-end")
struct CryptoKitCompatibilityTests {

    @Test("Ed25519 imported key can sign and verify")
    func ed25519SignVerify() throws {
        let original = Curve25519.Signing.PrivateKey()
        let pem = OpenSSHBlobBuilder.ed25519PEM(
            publicKey: Data(original.publicKey.rawRepresentation),
            seed: Data(original.rawRepresentation)
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)

        let message = Data("test message".utf8)
        let signature = try key.signature(for: message)
        let valid = original.publicKey.isValidSignature(signature, for: message)
        #expect(valid)
    }

    @Test("P-256 imported key (mpint-normalized) can sign and verify")
    func p256MpintSignVerify() throws {
        let original = P256.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation)
        let publicPoint = Data(original.publicKey.x963Representation)

        // Use mpint-padded scalar (33 bytes)
        let pem = OpenSSHBlobBuilder.ecdsaP256PEM(
            publicPoint: publicPoint,
            privateScalar: Data([0x00]) + rawScalar
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)
        let key = try P256.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)

        let message = Data("test message".utf8)
        let signature = try key.signature(for: SHA256.hash(data: message))
        let valid = original.publicKey.isValidSignature(signature, for: SHA256.hash(data: message))
        #expect(valid)
    }

    @Test("P-384 imported key (mpint-normalized) can sign and verify")
    func p384MpintSignVerify() throws {
        let original = P384.Signing.PrivateKey()
        let rawScalar = Data(original.rawRepresentation)
        let publicPoint = Data(original.publicKey.x963Representation)

        // Use mpint-padded scalar (49 bytes)
        let pem = OpenSSHBlobBuilder.ecdsaP384PEM(
            publicPoint: publicPoint,
            privateScalar: Data([0x00]) + rawScalar
        )

        let parsed = try SSHKeyImporter.importKey(from: pem)
        let key = try P384.Signing.PrivateKey(rawRepresentation: parsed.privateKeyData)

        let message = Data("test message".utf8)
        let signature = try key.signature(for: SHA384.hash(data: message))
        let valid = original.publicKey.isValidSignature(signature, for: SHA384.hash(data: message))
        #expect(valid)
    }
}
