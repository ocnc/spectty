import Foundation
import CZlib

// MARK: - Protobuf Wire Format Helpers

/// Minimal protobuf encoder/decoder for Mosh's protocol messages.
/// Mosh uses a small number of simple protobuf messages; hand-coding
/// avoids pulling in the swift-protobuf dependency.

enum ProtoWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct ProtoEncoder {
    private(set) var data = Data()

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }

    mutating func writeTag(fieldNumber: Int, wireType: ProtoWireType) {
        writeVarint(UInt64(fieldNumber << 3 | Int(wireType.rawValue)))
    }

    mutating func writeUInt64(_ fieldNumber: Int, _ value: UInt64) {
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(value)
    }

    mutating func writeInt64(_ fieldNumber: Int, _ value: Int64) {
        writeUInt64(fieldNumber, UInt64(bitPattern: value))
    }

    mutating func writeBytes(_ fieldNumber: Int, _ value: Data) {
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeString(_ fieldNumber: Int, _ value: String) {
        writeBytes(fieldNumber, Data(value.utf8))
    }

    mutating func writeNestedMessage(_ fieldNumber: Int, _ encode: (inout ProtoEncoder) -> Void) {
        var nested = ProtoEncoder()
        encode(&nested)
        writeBytes(fieldNumber, nested.data)
    }

    mutating func writeBool(_ fieldNumber: Int, _ value: Bool) {
        writeUInt64(fieldNumber, value ? 1 : 0)
    }

    mutating func writeUInt32(_ fieldNumber: Int, _ value: UInt32) {
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(value))
    }

    mutating func writeInt32(_ fieldNumber: Int, _ value: Int32) {
        writeUInt32(fieldNumber, UInt32(bitPattern: value))
    }
}

struct ProtoDecoder {
    private let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift = 0
        while offset < data.endIndex {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    mutating func readTag() -> (fieldNumber: Int, wireType: ProtoWireType)? {
        guard let tagValue = readVarint() else { return nil }
        let wireTypeRaw = UInt8(tagValue & 0x07)
        guard let wireType = ProtoWireType(rawValue: wireTypeRaw) else { return nil }
        return (Int(tagValue >> 3), wireType)
    }

    mutating func readBytes() -> Data? {
        guard let length = readVarint() else { return nil }
        let len = Int(length)
        guard offset + len <= data.endIndex else { return nil }
        let result = data[offset..<(offset + len)]
        offset += len
        return Data(result)
    }

    mutating func skip(wireType: ProtoWireType) {
        switch wireType {
        case .varint:
            _ = readVarint()
        case .fixed64:
            offset += 8
        case .fixed32:
            offset += 4
        case .lengthDelimited:
            if let len = readVarint() {
                offset += Int(len)
            }
        }
    }
}

// MARK: - TransportInstruction (TransportBuffers.Instruction)

/// Mosh SSP transport-level instruction wrapping diffs.
/// Fields: protocol_version (1), old_num (2), new_num (3), ack_num (4),
///         throwaway_num (5), diff (6), chaff (7)
struct TransportInstruction: Sendable {
    var protocolVersion: UInt32 = 2  // MOSH_PROTOCOL_VERSION
    var oldNum: UInt64 = 0
    var newNum: UInt64 = 0
    var ackNum: UInt64 = 0
    var throwawayNum: UInt64 = 0
    var diff: Data = Data()
    var chaff: Data? = nil

    func serialize() -> Data {
        var encoder = ProtoEncoder()
        encoder.writeUInt32(1, protocolVersion)
        if oldNum != 0 { encoder.writeUInt64(2, oldNum) }
        if newNum != 0 { encoder.writeUInt64(3, newNum) }
        if ackNum != 0 { encoder.writeUInt64(4, ackNum) }
        if throwawayNum != 0 { encoder.writeUInt64(5, throwawayNum) }
        if !diff.isEmpty { encoder.writeBytes(6, diff) }
        if let chaff { encoder.writeBytes(7, chaff) }
        return encoder.data
    }

    static func deserialize(from data: Data) -> TransportInstruction? {
        var decoder = ProtoDecoder(data: data)
        var inst = TransportInstruction()

        while !decoder.isAtEnd {
            guard let (field, wireType) = decoder.readTag() else { break }
            switch field {
            case 1: inst.protocolVersion = UInt32(decoder.readVarint() ?? 0)
            case 2: inst.oldNum = decoder.readVarint() ?? 0
            case 3: inst.newNum = decoder.readVarint() ?? 0
            case 4: inst.ackNum = decoder.readVarint() ?? 0
            case 5: inst.throwawayNum = decoder.readVarint() ?? 0
            case 6: inst.diff = decoder.readBytes() ?? Data()
            case 7: inst.chaff = decoder.readBytes()
            default: decoder.skip(wireType: wireType)
            }
        }

        return inst
    }
}

// MARK: - Client→Server: UserMessage (ClientBuffers.UserMessage)

/// Wraps user input: keystrokes and resize events.
///
/// Proto schema (ClientBuffers):
///   UserMessage { repeated Instruction instruction = 1; }
///   Instruction { extensions 2 to max; }
///   extend Instruction { optional Keystroke keystroke = 2; optional ResizeMessage resize = 3; }
///   Keystroke { optional bytes keys = 4; }
///   ResizeMessage { optional int32 width = 5; optional int32 height = 6; }
///
/// Extension fields are nested messages on the Instruction:
///   Instruction field 2 → Keystroke { field 4 → keys }
///   Instruction field 3 → ResizeMessage { field 5 → width, field 6 → height }
struct UserMessage: Sendable {
    var keystrokes: [Data] = []
    var resize: ResizeMessage? = nil

    func serialize() -> Data {
        var encoder = ProtoEncoder()
        // Each keystroke → Instruction { Keystroke(field 2) { keys(field 4) } }
        for k in keystrokes {
            encoder.writeNestedMessage(1) { instruction in
                instruction.writeNestedMessage(2) { keystroke in
                    keystroke.writeBytes(4, k)
                }
            }
        }
        // Resize → Instruction { ResizeMessage(field 3) { width(5), height(6) } }
        if let resize {
            encoder.writeNestedMessage(1) { instruction in
                instruction.writeNestedMessage(3) { resizeMsg in
                    resizeMsg.writeInt32(5, resize.width)
                    resizeMsg.writeInt32(6, resize.height)
                }
            }
        }
        return encoder.data
    }

    static func deserialize(from data: Data) -> UserMessage {
        var decoder = ProtoDecoder(data: data)
        var msg = UserMessage()

        while !decoder.isAtEnd {
            guard let (field, wireType) = decoder.readTag() else { break }
            switch field {
            case 1:
                // Instruction — parse extension fields (2=Keystroke, 3=ResizeMessage)
                if let instrData = decoder.readBytes() {
                    var inner = ProtoDecoder(data: instrData)
                    while !inner.isAtEnd {
                        guard let (innerField, innerWireType) = inner.readTag() else { break }
                        switch innerField {
                        case 2: // Keystroke nested message
                            if let keystrokeData = inner.readBytes() {
                                var ksDecoder = ProtoDecoder(data: keystrokeData)
                                while !ksDecoder.isAtEnd {
                                    guard let (ksField, ksWire) = ksDecoder.readTag() else { break }
                                    if ksField == 4, let keys = ksDecoder.readBytes() {
                                        msg.keystrokes.append(keys)
                                    } else {
                                        ksDecoder.skip(wireType: ksWire)
                                    }
                                }
                            }
                        case 3: // ResizeMessage nested message
                            if let resizeData = inner.readBytes() {
                                if msg.resize == nil { msg.resize = ResizeMessage(width: 80, height: 24) }
                                var rsDecoder = ProtoDecoder(data: resizeData)
                                while !rsDecoder.isAtEnd {
                                    guard let (rsField, rsWire) = rsDecoder.readTag() else { break }
                                    switch rsField {
                                    case 5:
                                        if let v = rsDecoder.readVarint() {
                                            msg.resize?.width = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
                                        }
                                    case 6:
                                        if let v = rsDecoder.readVarint() {
                                            msg.resize?.height = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
                                        }
                                    default:
                                        rsDecoder.skip(wireType: rsWire)
                                    }
                                }
                            }
                        default:
                            inner.skip(wireType: innerWireType)
                        }
                    }
                }
            default:
                decoder.skip(wireType: wireType)
            }
        }

        return msg
    }
}

/// Terminal resize message.
struct ResizeMessage: Sendable {
    var width: Int32
    var height: Int32
}

// MARK: - Server→Client: HostMessage (HostBuffers.HostMessage)

/// Wraps server output: terminal bytes, resize, echo acks.
///
/// Proto schema (HostBuffers):
///   HostMessage { repeated Instruction instruction = 1; }
///   Instruction { extensions 2 to max; }
///   extend Instruction { optional HostBytes hostbytes = 2; optional ResizeMessage resize = 3; optional EchoAck echoack = 7; }
///   HostBytes { optional bytes hoststring = 4; }
///   ResizeMessage { optional int32 width = 5; optional int32 height = 6; }
///   EchoAck { optional uint64 echo_ack_num = 8; }
///
/// Extension fields are nested messages on the Instruction:
///   Instruction field 2 → HostBytes { field 4 → hoststring }
///   Instruction field 3 → ResizeMessage { field 5 → width, field 6 → height }
///   Instruction field 7 → EchoAck { field 8 → echo_ack_num }
struct HostMessage: Sendable {
    var hostBytes: [Data] = []
    var resize: ResizeMessage? = nil
    var echoAck: EchoAck? = nil

    static func deserialize(from data: Data) -> HostMessage {
        var decoder = ProtoDecoder(data: data)
        var msg = HostMessage()

        while !decoder.isAtEnd {
            guard let (field, wireType) = decoder.readTag() else { break }
            switch field {
            case 1:
                // Instruction — parse extension fields (2=HostBytes, 3=Resize, 7=EchoAck)
                if let instrData = decoder.readBytes() {
                    var inner = ProtoDecoder(data: instrData)
                    while !inner.isAtEnd {
                        guard let (innerField, innerWireType) = inner.readTag() else { break }
                        switch innerField {
                        case 2: // HostBytes nested message
                            if let hostBytesData = inner.readBytes() {
                                var hbDecoder = ProtoDecoder(data: hostBytesData)
                                while !hbDecoder.isAtEnd {
                                    guard let (hbField, hbWire) = hbDecoder.readTag() else { break }
                                    if hbField == 4, let bytes = hbDecoder.readBytes() {
                                        msg.hostBytes.append(bytes)
                                    } else {
                                        hbDecoder.skip(wireType: hbWire)
                                    }
                                }
                            }
                        case 3: // ResizeMessage nested message
                            if let resizeData = inner.readBytes() {
                                if msg.resize == nil { msg.resize = ResizeMessage(width: 80, height: 24) }
                                var rsDecoder = ProtoDecoder(data: resizeData)
                                while !rsDecoder.isAtEnd {
                                    guard let (rsField, rsWire) = rsDecoder.readTag() else { break }
                                    switch rsField {
                                    case 5:
                                        if let v = rsDecoder.readVarint() {
                                            msg.resize?.width = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
                                        }
                                    case 6:
                                        if let v = rsDecoder.readVarint() {
                                            msg.resize?.height = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
                                        }
                                    default:
                                        rsDecoder.skip(wireType: rsWire)
                                    }
                                }
                            }
                        case 7: // EchoAck nested message
                            if let echoData = inner.readBytes() {
                                var eaDecoder = ProtoDecoder(data: echoData)
                                while !eaDecoder.isAtEnd {
                                    guard let (eaField, eaWire) = eaDecoder.readTag() else { break }
                                    if eaField == 8, let v = eaDecoder.readVarint() {
                                        msg.echoAck = EchoAck(echoAckNum: v)
                                    } else {
                                        eaDecoder.skip(wireType: eaWire)
                                    }
                                }
                            }
                        default:
                            inner.skip(wireType: innerWireType)
                        }
                    }
                }
            default:
                decoder.skip(wireType: wireType)
            }
        }

        return msg
    }
}

struct EchoAck: Sendable {
    var echoAckNum: UInt64
}

// MARK: - Fragment Framing (transportfragment)

/// Mosh fragment header: wraps compressed protobuf in a 10-byte header.
///
/// Wire format: [8-byte instruction_id BE] [2-byte: bit15=final | bits0-14=fragment_num] [compressed content]
struct MoshFragment: Sendable {
    static let headerLength = 10

    let instructionID: UInt64
    let fragmentNum: UInt16
    let isFinal: Bool
    let contents: Data

    /// Serialize to wire format.
    func serialize() -> Data {
        var data = Data(capacity: Self.headerLength + contents.count)
        // 8-byte instruction ID (big-endian)
        var idBE = instructionID.bigEndian
        data.append(Data(bytes: &idBE, count: 8))
        // 2-byte combined: bit 15 = final, bits 0-14 = fragment_num
        var combined = fragmentNum & 0x7FFF
        if isFinal { combined |= 0x8000 }
        var combinedBE = combined.bigEndian
        data.append(Data(bytes: &combinedBE, count: 2))
        // Content
        data.append(contents)
        return data
    }

    /// Parse from wire format.
    static func parse(from data: Data) -> MoshFragment? {
        guard data.count >= headerLength else { return nil }
        let s = data.startIndex
        // Read uint64 big-endian manually to avoid alignment issues
        var id: UInt64 = 0
        for i in 0..<8 {
            id = (id << 8) | UInt64(data[s + i])
        }
        let combined = UInt16(data[s + 8]) << 8 | UInt16(data[s + 9])
        let isFinal = (combined & 0x8000) != 0
        let fragNum = combined & 0x7FFF
        let contents = data[(s + 10)...]
        return MoshFragment(instructionID: id, fragmentNum: fragNum, isFinal: isFinal, contents: Data(contents))
    }
}

/// Creates fragments from TransportInstructions (client → server).
final class MoshFragmenter: @unchecked Sendable {
    private var nextInstructionID: UInt64 = 0

    /// Fragment a TransportInstruction for sending.
    /// For typical mosh traffic, this produces a single fragment.
    func makeFragments(instruction: TransportInstruction, mtu: Int = 1280) -> [MoshFragment] {
        nextInstructionID += 1

        // Serialize protobuf and compress with zlib
        let protobuf = instruction.serialize()
        guard let compressed = zlibCompress(protobuf) else {
            print("[Mosh] Fragment: zlib compression failed")
            return []
        }

        let maxContent = mtu - MoshFragment.headerLength
        var fragments: [MoshFragment] = []
        var offset = 0
        var fragmentNum: UInt16 = 0

        while offset < compressed.count {
            let end = min(offset + maxContent, compressed.count)
            let isFinal = (end == compressed.count)
            let chunk = compressed[offset..<end]
            fragments.append(MoshFragment(
                instructionID: nextInstructionID,
                fragmentNum: fragmentNum,
                isFinal: isFinal,
                contents: Data(chunk)
            ))
            offset = end
            fragmentNum += 1
        }

        return fragments
    }
}

/// Reassembles fragments from server into TransportInstructions.
final class MoshFragmentAssembly: @unchecked Sendable {
    private var currentID: UInt64 = 0
    private var fragments: [UInt16: Data] = [:]
    private var fragmentsTotal: Int = -1

    /// Add a fragment. Returns the reassembled TransportInstruction when complete, nil otherwise.
    func addFragment(_ fragment: MoshFragment) -> TransportInstruction? {
        if fragment.instructionID != currentID {
            // New instruction — reset
            currentID = fragment.instructionID
            fragments.removeAll()
            fragmentsTotal = -1
        }

        fragments[fragment.fragmentNum] = fragment.contents

        if fragment.isFinal {
            fragmentsTotal = Int(fragment.fragmentNum) + 1
        }

        guard fragmentsTotal > 0, fragments.count == fragmentsTotal else {
            return nil
        }

        // Reassemble in order
        var assembled = Data()
        for i in 0..<fragmentsTotal {
            guard let part = fragments[UInt16(i)] else { return nil }
            assembled.append(part)
        }

        // Decompress
        guard let decompressed = zlibDecompress(assembled) else {
            print("[Mosh] Fragment: zlib decompression failed for \(assembled.count) bytes")
            return nil
        }

        // Parse protobuf
        fragments.removeAll()
        fragmentsTotal = -1
        return TransportInstruction.deserialize(from: decompressed)
    }
}

// MARK: - Zlib Compression

/// Compress data using zlib (RFC 1950 format, matches mosh's compress()).
func zlibCompress(_ input: Data) -> Data? {
    guard !input.isEmpty else {
        // zlib compress of empty data
        var destLen = CUnsignedLong(compressBound(CUnsignedLong(0)))
        var dest = Data(count: Int(destLen))
        let result = dest.withUnsafeMutableBytes { destPtr in
            input.withUnsafeBytes { srcPtr in
                CZlib.compress(
                    destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    &destLen,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    CUnsignedLong(input.count)
                )
            }
        }
        guard result == Z_OK else { return nil }
        return dest.prefix(Int(destLen))
    }

    var destLen = CUnsignedLong(compressBound(CUnsignedLong(input.count)))
    var dest = Data(count: Int(destLen))
    let result = dest.withUnsafeMutableBytes { destPtr in
        input.withUnsafeBytes { srcPtr in
            CZlib.compress(
                destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                &destLen,
                srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                CUnsignedLong(input.count)
            )
        }
    }
    guard result == Z_OK else { return nil }
    return dest.prefix(Int(destLen))
}

/// Decompress zlib-compressed data (RFC 1950 format).
func zlibDecompress(_ input: Data) -> Data? {
    guard !input.isEmpty else { return Data() }

    // Start with 4x the compressed size, grow if needed
    var destLen = CUnsignedLong(input.count * 4 + 1024)
    var dest = Data(count: Int(destLen))

    let result = dest.withUnsafeMutableBytes { destPtr in
        input.withUnsafeBytes { srcPtr in
            CZlib.uncompress(
                destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                &destLen,
                srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                CUnsignedLong(input.count)
            )
        }
    }

    if result == Z_BUF_ERROR {
        // Buffer too small, try larger
        destLen = CUnsignedLong(input.count * 16 + 4096)
        dest = Data(count: Int(destLen))
        let retry = dest.withUnsafeMutableBytes { destPtr in
            input.withUnsafeBytes { srcPtr in
                CZlib.uncompress(
                    destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    &destLen,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    CUnsignedLong(input.count)
                )
            }
        }
        guard retry == Z_OK else { return nil }
    } else if result != Z_OK {
        return nil
    }

    return dest.prefix(Int(destLen))
}
