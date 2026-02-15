import Foundation

/// Direction of a Mosh datagram (encoded in the nonce's MSB).
enum MoshDirection: UInt8, Sendable {
    case toServer = 0
    case toClient = 1
}

/// A decoded Mosh packet (before/after encryption).
struct MoshPacket: Sendable {
    let sequenceNumber: UInt64
    let direction: MoshDirection
    let timestamp: UInt16
    let timestampReply: UInt16
    let payload: Data

    /// Build the 12-byte OCB3 nonce from direction + sequence number.
    /// Bytes 0-3: zero. Bytes 4-11: uint64 BE with bit 63 = direction.
    var nonce: Data {
        var n = Data(repeating: 0, count: 12)
        var value = sequenceNumber & 0x7FFF_FFFF_FFFF_FFFF
        if direction == .toClient {
            value |= (1 << 63)
        }
        // Write big-endian uint64 at bytes 4-11
        for i in 0..<8 {
            n[4 + i] = UInt8((value >> (56 - i * 8)) & 0xFF)
        }
        return n
    }

    /// The 8 bytes sent on the wire (bytes 4-11 of the nonce).
    var noncePrefix: Data {
        let n = nonce
        return n[4..<12]
    }

    /// Plaintext = 2-byte timestamp + 2-byte timestamp_reply + payload.
    var plaintext: Data {
        var data = Data(capacity: 4 + payload.count)
        data.append(UInt8(timestamp >> 8))
        data.append(UInt8(timestamp & 0xFF))
        data.append(UInt8(timestampReply >> 8))
        data.append(UInt8(timestampReply & 0xFF))
        data.append(payload)
        return data
    }

    /// Parse plaintext into timestamp fields + payload.
    init(sequenceNumber: UInt64, direction: MoshDirection, plaintext: Data) {
        self.sequenceNumber = sequenceNumber
        self.direction = direction
        guard plaintext.count >= 4 else {
            self.timestamp = 0
            self.timestampReply = 0
            self.payload = Data()
            return
        }
        self.timestamp = UInt16(plaintext[0]) << 8 | UInt16(plaintext[1])
        self.timestampReply = UInt16(plaintext[2]) << 8 | UInt16(plaintext[3])
        self.payload = plaintext.count > 4 ? plaintext[4...] : Data()
    }

    init(sequenceNumber: UInt64, direction: MoshDirection, timestamp: UInt16, timestampReply: UInt16, payload: Data) {
        self.sequenceNumber = sequenceNumber
        self.direction = direction
        self.timestamp = timestamp
        self.timestampReply = timestampReply
        self.payload = payload
    }
}

// MARK: - MoshCryptoSession

/// Wraps an OCB3 cipher with the session key and handles encrypt/decrypt of full datagrams.
struct MoshCryptoSession: Sendable {
    private let cipher: OCB3

    init(key: Data) {
        self.cipher = OCB3(key: key)
    }

    /// Parse a base64-encoded key from mosh-server output (22 chars).
    init(base64Key: String) throws {
        // mosh uses base64 with standard alphabet; the key is always 22 chars + optional padding
        var padded = base64Key
        while padded.count % 4 != 0 {
            padded += "="
        }
        guard let keyData = Data(base64Encoded: padded), keyData.count == 16 else {
            throw MoshError.invalidKey
        }
        self.init(key: keyData)
    }

    /// Encrypt a packet into a wire-format datagram: [8-byte nonce-prefix][ciphertext][16-byte tag].
    func seal(packet: MoshPacket) -> Data {
        let nonce = packet.nonce
        let plaintext = packet.plaintext
        let (ciphertext, tag) = cipher.encrypt(nonce: nonce, plaintext: plaintext)

        var datagram = Data(capacity: 8 + ciphertext.count + 16)
        datagram.append(packet.noncePrefix)
        datagram.append(ciphertext)
        datagram.append(tag)
        return datagram
    }

    /// Decrypt a wire-format datagram. Returns nil if authentication fails.
    /// The `direction` indicates the expected direction of this datagram.
    func open(datagram: Data, direction: MoshDirection) -> MoshPacket? {
        // Minimum: 8 (nonce prefix) + 0 (ciphertext) + 16 (tag) = 24 bytes
        guard datagram.count >= 24 else { return nil }

        // Extract nonce prefix (8 bytes) → reconstruct 12-byte nonce
        let noncePrefix = datagram[0..<8]
        var nonce = Data(repeating: 0, count: 12)
        nonce.replaceSubrange(4..<12, with: noncePrefix)

        // Extract sequence number and direction from nonce prefix
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(noncePrefix[noncePrefix.startIndex + i])
        }
        let seq = value & 0x7FFF_FFFF_FFFF_FFFF

        let ciphertext = datagram[8..<(datagram.count - 16)]
        let tag = datagram[(datagram.count - 16)...]

        guard let plaintext = cipher.decrypt(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag)) else {
            return nil
        }

        return MoshPacket(sequenceNumber: seq, direction: direction, plaintext: plaintext)
    }
}
