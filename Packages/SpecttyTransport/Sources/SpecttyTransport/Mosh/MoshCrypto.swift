import Foundation
import CommonCrypto

/// AES-128-OCB3 authenticated encryption per RFC 7253.
///
/// Uses CommonCrypto's AES-ECB as the raw block cipher and implements the
/// OCB3 mode manually. This avoids any GPL-licensed code while providing
/// the exact cipher Mosh requires.
struct OCB3 {
    static let blockSize = 16
    static let tagLength = 16

    private let key: Data
    /// L_* = ENCIPHER(K, zeros)
    private let lStar: Block
    /// L_$ = double(L_*)
    private let lDollar: Block
    /// Precomputed L_i = double^i(L_$) for i = 0..15
    private let lTable: [Block]

    init(key: Data) {
        precondition(key.count == 16, "OCB3 requires a 16-byte key")
        self.key = key

        let zero = Block.zero
        self.lStar = Self.aesEncryptBlock(key: key, block: zero)
        self.lDollar = self.lStar.doubled()

        // Precompute L_0 through L_15 (more than enough for any realistic message)
        var table: [Block] = []
        var current = self.lDollar
        for _ in 0..<16 {
            current = current.doubled()
            table.append(current)
        }
        self.lTable = table
    }

    /// Returns L_i from the precomputed table.
    private func l(_ i: Int) -> Block {
        return lTable[i]
    }

    /// Encrypt plaintext with the given nonce (12 bytes).
    /// Returns (ciphertext, 16-byte tag).
    func encrypt(nonce: Data, plaintext: Data) -> (ciphertext: Data, tag: Data) {
        precondition(nonce.count == 12, "OCB3 nonce must be 12 bytes")

        let (offset0, stretch) = computeInitialOffset(nonce: nonce)
        _ = stretch // offset0 already computed from stretch

        let blocks = plaintext.count / Self.blockSize
        let trailingBytes = plaintext.count % Self.blockSize

        var offset = offset0
        var checksum = Block.zero
        var ciphertext = Data(capacity: plaintext.count)

        // Process full blocks
        for i in 0..<blocks {
            let ntz = Self.numberOfTrailingZeros(i + 1)
            offset = offset ^ l(ntz)
            let plaintextBlock = Block(data: plaintext, offset: i * Self.blockSize)
            let encrypted = Self.aesEncryptBlock(key: key, block: offset ^ plaintextBlock) ^ offset
            ciphertext.append(encrypted.data)
            checksum = checksum ^ plaintextBlock
        }

        // Process final (possibly partial) block
        if trailingBytes > 0 {
            offset = offset ^ lStar
            let pad = Self.aesEncryptBlock(key: key, block: offset)
            let start = blocks * Self.blockSize
            var lastBlock = Data(repeating: 0, count: Self.blockSize)
            lastBlock.replaceSubrange(0..<trailingBytes, with: plaintext[start..<(start + trailingBytes)])

            // XOR plaintext with pad for ciphertext
            var ciphertextFragment = Data(count: trailingBytes)
            for j in 0..<trailingBytes {
                ciphertextFragment[j] = lastBlock[j] ^ pad.bytes[j]
            }
            ciphertext.append(ciphertextFragment)

            // Checksum includes the padded last block (10* padding)
            lastBlock[trailingBytes] = 0x80
            checksum = checksum ^ Block(bytes: [UInt8](lastBlock))
        } else if plaintext.isEmpty {
            // Empty plaintext: no blocks processed, checksum stays zero
        }

        // Tag = ENCIPHER(K, Checksum ^ Offset ^ L_$)
        let tagBlock = Self.aesEncryptBlock(key: key, block: checksum ^ offset ^ lDollar)
        return (ciphertext, tagBlock.data)
    }

    /// Decrypt ciphertext with the given nonce (12 bytes) and tag (16 bytes).
    /// Returns plaintext on success, nil if authentication fails.
    func decrypt(nonce: Data, ciphertext: Data, tag: Data) -> Data? {
        precondition(nonce.count == 12, "OCB3 nonce must be 12 bytes")
        precondition(tag.count == 16, "OCB3 tag must be 16 bytes")

        let (offset0, _) = computeInitialOffset(nonce: nonce)

        let blocks = ciphertext.count / Self.blockSize
        let trailingBytes = ciphertext.count % Self.blockSize

        var offset = offset0
        var checksum = Block.zero
        var plaintext = Data(capacity: ciphertext.count)

        for i in 0..<blocks {
            let ntz = Self.numberOfTrailingZeros(i + 1)
            offset = offset ^ l(ntz)
            let ciphertextBlock = Block(data: ciphertext, offset: i * Self.blockSize)
            let decrypted = Self.aesDecryptBlock(key: key, block: offset ^ ciphertextBlock) ^ offset
            plaintext.append(decrypted.data)
            checksum = checksum ^ decrypted
        }

        if trailingBytes > 0 {
            offset = offset ^ lStar
            let pad = Self.aesEncryptBlock(key: key, block: offset)
            let start = blocks * Self.blockSize
            var lastPlain = Data(count: Self.blockSize)

            for j in 0..<trailingBytes {
                lastPlain[j] = ciphertext[start + j] ^ pad.bytes[j]
            }
            plaintext.append(lastPlain[0..<trailingBytes])

            // Pad the plaintext for checksum (10* padding)
            lastPlain[trailingBytes] = 0x80
            for j in (trailingBytes + 1)..<Self.blockSize {
                lastPlain[j] = 0
            }
            checksum = checksum ^ Block(bytes: [UInt8](lastPlain))
        }

        let expectedTag = Self.aesEncryptBlock(key: key, block: checksum ^ offset ^ lDollar)

        // Constant-time tag comparison
        var diff: UInt8 = 0
        let tagBytes = [UInt8](tag)
        for i in 0..<Self.tagLength {
            diff |= expectedTag.bytes[i] ^ tagBytes[i]
        }

        guard diff == 0 else { return nil }
        return plaintext
    }

    // MARK: - Internals

    /// Compute the initial offset (Offset_0) from a 12-byte nonce.
    /// Uses the "stretch then shift" approach from RFC 7253 Section 4.2 with taglen=128.
    private func computeInitialOffset(nonce: Data) -> (Block, Block) {
        // Build the 16-byte Nonce block: [0x00 | taglen_mod_128(=0) | 7 zero bits] [nonce bytes] with bottom 6 bits separated
        // For TAGLEN=128: first byte = (128 % 128) << 1 = 0, then OR in bit to mark nonce length
        // Full construction: pad nonce to 16 bytes: 0^(127-|nonce|*8) || 1 || nonce
        var nonceBlock = [UInt8](repeating: 0, count: 16)
        // For 96-bit nonce: first 3 bytes are 0, byte 3 gets 0x01 to mark boundary, bytes 4-15 = nonce
        nonceBlock[3] = 0x01
        let nonceBytes = [UInt8](nonce)
        for i in 0..<12 {
            nonceBlock[4 + i] = nonceBytes[i]
        }

        let bottom = Int(nonceBlock[15] & 0x3F) // bottom 6 bits
        nonceBlock[15] &= 0xC0 // clear bottom 6 bits

        let ktop = Self.aesEncryptBlock(key: key, block: Block(bytes: nonceBlock))

        // Stretch = Ktop || (Ktop[1..64] XOR Ktop[9..72])
        // We need 24 bytes of stretch, then extract 16 bytes starting at bit position `bottom`
        var stretchBytes = [UInt8](repeating: 0, count: 24)
        for i in 0..<16 {
            stretchBytes[i] = ktop.bytes[i]
        }
        // XOR bytes 1..8 with bytes 2..9 (shifted by 8 bits)
        for i in 0..<8 {
            stretchBytes[16 + i] = ktop.bytes[i] ^ ktop.bytes[i + 1]
        }

        // Extract 128 bits starting at bit position `bottom`
        var offsetBytes = [UInt8](repeating: 0, count: 16)
        let byteShift = bottom / 8
        let bitShift = bottom % 8

        for i in 0..<16 {
            let srcIdx = byteShift + i
            offsetBytes[i] = stretchBytes[srcIdx] << bitShift
            if bitShift > 0 && srcIdx + 1 < stretchBytes.count {
                offsetBytes[i] |= stretchBytes[srcIdx + 1] >> (8 - bitShift)
            }
        }

        return (Block(bytes: offsetBytes), ktop)
    }

    /// Single-block AES-128 encryption using CommonCrypto ECB mode.
    static func aesEncryptBlock(key: Data, block: Block) -> Block {
        var outBuffer = [UInt8](repeating: 0, count: blockSize + kCCBlockSizeAES128)
        var outLength = 0

        let status = key.withUnsafeBytes { keyPtr in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionECBMode),
                keyPtr.baseAddress, kCCKeySizeAES128,
                nil, // no IV for ECB
                block.bytes, blockSize,
                &outBuffer, outBuffer.count,
                &outLength
            )
        }

        precondition(status == kCCSuccess, "AES encryption failed: \(status)")
        return Block(bytes: Array(outBuffer[0..<blockSize]))
    }

    /// Single-block AES-128 decryption using CommonCrypto ECB mode.
    /// Used only for OCB3 full-block decryption (DECIPHER).
    static func aesDecryptBlock(key: Data, block: Block) -> Block {
        var outBuffer = [UInt8](repeating: 0, count: blockSize + kCCBlockSizeAES128)
        var outLength = 0

        let status = key.withUnsafeBytes { keyPtr in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionECBMode),
                keyPtr.baseAddress, kCCKeySizeAES128,
                nil,
                block.bytes, blockSize,
                &outBuffer, outBuffer.count,
                &outLength
            )
        }

        precondition(status == kCCSuccess, "AES decryption failed: \(status)")
        return Block(bytes: Array(outBuffer[0..<blockSize]))
    }

    /// Count trailing zero bits of a positive integer (1-indexed block number).
    static func numberOfTrailingZeros(_ n: Int) -> Int {
        precondition(n > 0)
        var count = 0
        var val = n
        while val & 1 == 0 {
            count += 1
            val >>= 1
        }
        return count
    }
}

// MARK: - Block (128-bit value)

/// A 128-bit block for AES/OCB3 operations.
struct Block: Sendable {
    var bytes: [UInt8] // Always 16 bytes

    static let zero = Block(bytes: [UInt8](repeating: 0, count: 16))

    init(bytes: [UInt8]) {
        precondition(bytes.count == 16)
        self.bytes = bytes
    }

    init(data: Data, offset: Int = 0) {
        self.bytes = [UInt8](data[offset..<(offset + 16)])
    }

    var data: Data {
        Data(bytes)
    }

    /// GF(2^128) doubling: shift left by 1, XOR with 0x87 if MSB was set.
    func doubled() -> Block {
        var result = [UInt8](repeating: 0, count: 16)
        let carry = bytes[0] >> 7 // MSB
        for i in 0..<15 {
            result[i] = (bytes[i] << 1) | (bytes[i + 1] >> 7)
        }
        result[15] = (bytes[15] << 1) ^ (carry == 1 ? 0x87 : 0x00)
        return Block(bytes: result)
    }

    static func ^ (lhs: Block, rhs: Block) -> Block {
        var result = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            result[i] = lhs.bytes[i] ^ rhs.bytes[i]
        }
        return Block(bytes: result)
    }
}
