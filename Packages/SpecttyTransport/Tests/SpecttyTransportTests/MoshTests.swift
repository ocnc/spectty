import Testing
import Foundation
@testable import SpecttyTransport

// MARK: - OCB3 Crypto Tests

@Suite("OCB3 AES-128")
struct OCB3Tests {
    /// RFC 7253 Appendix A, Test Vector #1:
    /// K=000102030405060708090A0B0C0D0E0F, N=BBAA99887766554433221100,
    /// A="", P="" → Tag = 785407BFFFC8AD9EDCC5520AC9111EE6
    @Test("RFC 7253 empty plaintext produces correct tag")
    func emptyPlaintextTag() {
        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let nonce = Data(hex: "BBAA99887766554433221100")
        let ocb = OCB3(key: key)

        let (ciphertext, tag) = ocb.encrypt(nonce: nonce, plaintext: Data())
        #expect(ciphertext.isEmpty)
        #expect(tag.hex == "785407bfffc8ad9edcc5520ac9111ee6")
    }

    /// RFC 7253 Appendix A, Test Vector #4 (no AD, 8-byte plaintext):
    /// N=BBAA99887766554433221103, P=0001020304050607
    /// → C=45DD69F8F5AAE724, T=14054CD1F35D82760B2CD00D2F99BFA9
    @Test("RFC 7253 8-byte plaintext (vector 4)")
    func eightBytePlaintext() {
        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let nonce = Data(hex: "BBAA99887766554433221103")
        let plaintext = Data(hex: "0001020304050607")

        let ocb = OCB3(key: key)
        let (ciphertext, tag) = ocb.encrypt(nonce: nonce, plaintext: plaintext)

        #expect(ciphertext.hex == "45dd69f8f5aae724")
        #expect(tag.hex == "14054cd1f35d82760b2cd00d2f99bfa9")
    }

    /// 16-byte plaintext (full block) round-trip - verifies full-block path
    @Test("Full-block (16 bytes) encrypt/decrypt round-trip")
    func fullBlockRoundTrip() {
        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let nonce = Data(hex: "BBAA99887766554433221106")
        let plaintext = Data(hex: "000102030405060708090A0B0C0D0E0F")

        let ocb = OCB3(key: key)
        let (ciphertext, tag) = ocb.encrypt(nonce: nonce, plaintext: plaintext)

        #expect(ciphertext.count == 16)
        #expect(tag.count == 16)

        let decrypted = ocb.decrypt(nonce: nonce, ciphertext: ciphertext, tag: tag)
        #expect(decrypted == plaintext)
    }

    @Test("Encrypt then decrypt round-trips")
    func roundTrip() {
        let key = Data(repeating: 0x42, count: 16)
        let nonce = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B])
        let plaintext = Data("Hello, Mosh!".utf8)

        let ocb = OCB3(key: key)
        let (ciphertext, tag) = ocb.encrypt(nonce: nonce, plaintext: plaintext)

        #expect(ciphertext.count == plaintext.count)
        #expect(tag.count == 16)

        let decrypted = ocb.decrypt(nonce: nonce, ciphertext: ciphertext, tag: tag)
        #expect(decrypted == plaintext)
    }

    @Test("Round-trip with multi-block plaintext")
    func roundTripMultiBlock() {
        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let nonce = Data(hex: "BBAA99887766554433221104")
        // 48 bytes = 3 full AES blocks
        let plaintext = Data(hex: "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F")

        let ocb = OCB3(key: key)
        let (ct, tag) = ocb.encrypt(nonce: nonce, plaintext: plaintext)
        let result = ocb.decrypt(nonce: nonce, ciphertext: ct, tag: tag)
        #expect(result == plaintext)
    }

    @Test("Round-trip with partial block")
    func roundTripPartialBlock() {
        let key = Data(repeating: 0xAB, count: 16)
        let nonce = Data(repeating: 0x01, count: 12)
        // 21 bytes = 1 full block + 5 trailing
        let plaintext = Data(repeating: 0xCD, count: 21)

        let ocb = OCB3(key: key)
        let (ct, tag) = ocb.encrypt(nonce: nonce, plaintext: plaintext)
        let result = ocb.decrypt(nonce: nonce, ciphertext: ct, tag: tag)
        #expect(result == plaintext)
    }

    @Test("Tampered ciphertext fails authentication")
    func tamperedCiphertext() {
        let key = Data(repeating: 0x13, count: 16)
        let nonce = Data(repeating: 0x37, count: 12)
        let plaintext = Data("secret data".utf8)

        let ocb = OCB3(key: key)
        let (ct, tag) = ocb.encrypt(nonce: nonce, plaintext: plaintext)

        var tampered = ct
        tampered[0] ^= 0xFF

        let result = ocb.decrypt(nonce: nonce, ciphertext: tampered, tag: tag)
        #expect(result == nil)
    }

    @Test("Tampered tag fails authentication")
    func tamperedTag() {
        let key = Data(repeating: 0x13, count: 16)
        let nonce = Data(repeating: 0x37, count: 12)
        let plaintext = Data("secret data".utf8)

        let ocb = OCB3(key: key)
        let (ct, tag) = ocb.encrypt(nonce: nonce, plaintext: plaintext)

        var badTag = tag
        badTag[0] ^= 0x01

        let result = ocb.decrypt(nonce: nonce, ciphertext: ct, tag: badTag)
        #expect(result == nil)
    }

    @Test("Wrong nonce fails authentication")
    func wrongNonce() {
        let key = Data(repeating: 0x13, count: 16)
        let nonce1 = Data(repeating: 0x37, count: 12)
        let nonce2 = Data(repeating: 0x38, count: 12)
        let plaintext = Data("test".utf8)

        let ocb = OCB3(key: key)
        let (ct, tag) = ocb.encrypt(nonce: nonce1, plaintext: plaintext)

        let result = ocb.decrypt(nonce: nonce2, ciphertext: ct, tag: tag)
        #expect(result == nil)
    }
}

// MARK: - Packet Framing Tests

@Suite("Mosh Packet Framing")
struct PacketTests {
    @Test("Crypto session seal then open round-trips")
    func cryptoSessionRoundTrip() {
        let key = Data(repeating: 0x42, count: 16)
        let session = MoshCryptoSession(key: key)

        let packet = MoshPacket(
            sequenceNumber: 1,
            direction: .toServer,
            timestamp: 1234,
            timestampReply: 5678,
            payload: Data("hello".utf8)
        )

        let datagram = session.seal(packet: packet)
        // 8 (nonce prefix) + 9 (4 header + 5 payload) + 16 (tag) = 33
        #expect(datagram.count == 33)

        let opened = session.open(datagram: datagram, direction: .toServer)
        #expect(opened != nil)
        #expect(opened?.sequenceNumber == 1)
        #expect(opened?.timestamp == 1234)
        #expect(opened?.timestampReply == 5678)
        #expect(opened?.payload == Data("hello".utf8))
    }

    @Test("Base64 key parsing")
    func base64KeyParsing() throws {
        // 16 bytes of zeros → base64 "AAAAAAAAAAAAAAAAAAAAAA=="
        let session = try MoshCryptoSession(base64Key: "AAAAAAAAAAAAAAAAAAAAAA")
        let packet = MoshPacket(sequenceNumber: 1, direction: .toServer, timestamp: 0, timestampReply: 0, payload: Data())
        let dg = session.seal(packet: packet)
        let result = session.open(datagram: dg, direction: .toServer)
        #expect(result != nil)
    }

    @Test("Nonce encodes direction bit correctly")
    func nonceDirection() {
        let serverPacket = MoshPacket(sequenceNumber: 1, direction: .toServer, timestamp: 0, timestampReply: 0, payload: Data())
        let clientPacket = MoshPacket(sequenceNumber: 1, direction: .toClient, timestamp: 0, timestampReply: 0, payload: Data())

        // Direction bit is bit 63 of the uint64 at nonce[4..12]
        // toServer: bit 63 = 0, toClient: bit 63 = 1
        #expect(serverPacket.nonce[4] & 0x80 == 0)
        #expect(clientPacket.nonce[4] & 0x80 == 0x80)
    }
}

// MARK: - Protobuf Tests

@Suite("Protobuf Codec")
struct ProtoTests {
    @Test("TransportInstruction round-trip")
    func transportInstructionRoundTrip() {
        let inst = TransportInstruction(
            oldNum: 5,
            newNum: 10,
            ackNum: 3,
            throwawayNum: 2,
            diff: Data("some diff".utf8)
        )

        let encoded = inst.serialize()
        let decoded = TransportInstruction.deserialize(from: encoded)

        #expect(decoded != nil)
        #expect(decoded?.oldNum == 5)
        #expect(decoded?.newNum == 10)
        #expect(decoded?.ackNum == 3)
        #expect(decoded?.throwawayNum == 2)
        #expect(decoded?.diff == Data("some diff".utf8))
    }

    @Test("UserMessage with keystrokes round-trip")
    func userMessageRoundTrip() {
        var msg = UserMessage()
        msg.keystrokes = [Data("ls\n".utf8), Data("pwd\n".utf8)]
        msg.resize = ResizeMessage(width: 120, height: 40)

        let encoded = msg.serialize()
        let decoded = UserMessage.deserialize(from: encoded)

        #expect(decoded.keystrokes.count == 2)
        #expect(decoded.keystrokes[0] == Data("ls\n".utf8))
        #expect(decoded.keystrokes[1] == Data("pwd\n".utf8))
        #expect(decoded.resize?.width == 120)
        #expect(decoded.resize?.height == 40)
    }

    @Test("HostMessage deserializes nested Instructions")
    func hostMessageDeserialize() {
        // Build a HostMessage wire format manually:
        // field 1 (Instruction) { field 2 (HostBytes) { field 4 (hoststring): bytes } }
        var outer = ProtoEncoder()
        outer.writeNestedMessage(1) { instruction in
            instruction.writeNestedMessage(2) { hostBytes in
                hostBytes.writeBytes(4, Data("output line 1\r\n".utf8))
            }
        }
        outer.writeNestedMessage(1) { instruction in
            instruction.writeNestedMessage(3) { resize in
                resize.writeInt32(5, 80)
                resize.writeInt32(6, 24)
            }
        }

        let decoded = HostMessage.deserialize(from: outer.data)

        #expect(decoded.hostBytes.count == 1)
        #expect(decoded.hostBytes[0] == Data("output line 1\r\n".utf8))
        #expect(decoded.resize?.width == 80)
        #expect(decoded.resize?.height == 24)
    }

    @Test("Empty messages encode and decode")
    func emptyMessages() {
        let inst = TransportInstruction()
        let encoded = inst.serialize()
        let decoded = TransportInstruction.deserialize(from: encoded)
        #expect(decoded != nil)
        #expect(decoded?.oldNum == 0)
        #expect(decoded?.diff.isEmpty == true)
    }
}

// MARK: - Bootstrap Parser Tests

@Suite("MOSH CONNECT Parser")
struct BootstrapTests {
    @Test("Parses valid MOSH CONNECT line")
    func parsesConnectLine() throws {
        let output = """

        MOSH CONNECT 60001 ABCDEFGHIJKLMNOPQRSTUV

        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        """

        let session = try MoshBootstrap.parseMoshConnect(output: output, defaultHost: "example.com")
        #expect(session.host == "example.com")
        #expect(session.udpPort == 60001)
        #expect(session.key == "ABCDEFGHIJKLMNOPQRSTUV")
    }

    @Test("Throws on missing MOSH CONNECT")
    func throwsOnMissing() {
        let output = "some random server output\n"
        #expect(throws: MoshError.self) {
            try MoshBootstrap.parseMoshConnect(output: output, defaultHost: "example.com")
        }
    }

    @Test("Uses remote-reported IP when enabled")
    func parsesRemoteReportedHost() throws {
        let output = """

        MOSH SSH_CONNECTION 198.51.100.22 60123 203.0.113.10 22
        MOSH CONNECT 60005 ZYXWVUTSRQPONMLKJIHGFE

        """
        let session = try MoshBootstrap.parseMoshConnect(
            output: output,
            defaultHost: "example.com",
            ipResolution: .remote
        )
        #expect(session.host == "203.0.113.10")
        #expect(session.udpPort == 60005)
    }

    @Test("Uses locally resolved host when configured")
    func parsesLocalResolvedHost() throws {
        let output = "MOSH CONNECT 60005 ZYXWVUTSRQPONMLKJIHGFE"
        let session = try MoshBootstrap.parseMoshConnect(
            output: output,
            defaultHost: "example.com",
            localResolvedHost: "198.51.100.9",
            ipResolution: .local
        )
        #expect(session.host == "198.51.100.9")
        #expect(session.udpPort == 60005)
    }

    @Test("Falls back to default host when remote-reported IP is missing")
    func remoteFallbacksToDefaultHost() throws {
        let output = "MOSH CONNECT 60005 ZYXWVUTSRQPONMLKJIHGFE"
        let session = try MoshBootstrap.parseMoshConnect(
            output: output,
            defaultHost: "203.0.113.77",
            ipResolution: .remote
        )
        #expect(session.host == "203.0.113.77")
        #expect(session.udpPort == 60005)
    }

    @Test("buildServerCommand quotes custom server path safely")
    func buildServerCommandQuotesCustomPath() {
        let config = SSHConnectionConfig(
            host: "example.com",
            username: "user",
            authMethod: .password("pw")
        )
        let options = MoshBootstrapOptions(serverPath: "/opt/custom path/mosh-server")

        let command = MoshBootstrap.buildServerCommand(config: config, options: options)
        #expect(command.contains("exec '/opt/custom path/mosh-server' new -i 0.0.0.0"))
    }

    @Test("buildServerCommand includes sanitized UDP port range")
    func buildServerCommandIncludesValidPortRange() {
        let config = SSHConnectionConfig(
            host: "example.com",
            username: "user",
            authMethod: .password("pw")
        )
        let options = MoshBootstrapOptions(udpPortRange: "60001:60010")

        let command = MoshBootstrap.buildServerCommand(config: config, options: options)
        #expect(command.contains("-p 60001:60010"))
    }

    @Test("buildServerCommand drops invalid UDP port range")
    func buildServerCommandDropsInvalidPortRange() {
        let config = SSHConnectionConfig(
            host: "example.com",
            username: "user",
            authMethod: .password("pw")
        )
        let options = MoshBootstrapOptions(udpPortRange: "60001;rm -rf /")

        let command = MoshBootstrap.buildServerCommand(config: config, options: options)
        #expect(!command.contains("-p "))
    }
}

// MARK: - Fragment Framing Tests

@Suite("Fragment Framing")
struct FragmentTests {
    @Test("Fragment serialize/parse round-trip")
    func fragmentRoundTrip() {
        let frag = MoshFragment(
            instructionID: 42,
            fragmentNum: 0,
            isFinal: true,
            contents: Data("hello compressed".utf8)
        )
        let wire = frag.serialize()
        // 10 byte header + content
        #expect(wire.count == 10 + 16)

        let parsed = MoshFragment.parse(from: wire)
        #expect(parsed != nil)
        #expect(parsed?.instructionID == 42)
        #expect(parsed?.fragmentNum == 0)
        #expect(parsed?.isFinal == true)
        #expect(parsed?.contents == Data("hello compressed".utf8))
    }

    @Test("Zlib compress/decompress round-trip")
    func zlibRoundTrip() {
        let input = Data("Hello, Mosh! This is some test data for compression.".utf8)
        let compressed = zlibCompress(input)
        #expect(compressed != nil)
        #expect(compressed!.count > 0)

        let decompressed = zlibDecompress(compressed!)
        #expect(decompressed == input)
    }

    @Test("Fragmenter + Assembly round-trip")
    func fragmenterAssemblyRoundTrip() {
        let instruction = TransportInstruction(
            oldNum: 0,
            newNum: 1,
            ackNum: 0,
            throwawayNum: 0,
            diff: Data("test diff".utf8)
        )

        let fragmenter = MoshFragmenter()
        let fragments = fragmenter.makeFragments(instruction: instruction)
        #expect(fragments.count >= 1)

        let assembly = MoshFragmentAssembly()
        var result: TransportInstruction? = nil
        for frag in fragments {
            // Simulate wire: serialize then parse
            let wire = frag.serialize()
            let parsed = MoshFragment.parse(from: wire)!
            result = assembly.addFragment(parsed)
        }

        #expect(result != nil)
        #expect(result?.newNum == 1)
        #expect(result?.diff == Data("test diff".utf8))
    }

    @Test("Full SSP packet with fragment framing matches wire format")
    func fullPacketWithFragmentFraming() {
        // Simulate what SSP does: build instruction → fragment → send as packet payload
        let instruction = TransportInstruction(
            oldNum: 0,
            newNum: 1,
            ackNum: 0,
            throwawayNum: 0,
            diff: Data()
        )

        let fragmenter = MoshFragmenter()
        let fragments = fragmenter.makeFragments(instruction: instruction)
        #expect(fragments.count == 1)

        let fragmentWire = fragments[0].serialize()
        // First 8 bytes should be instruction ID (big endian)
        // Next 2 bytes should have final bit set (0x80 in high byte)
        #expect(fragmentWire.count >= 10)
        #expect(fragmentWire[8] & 0x80 == 0x80) // final bit set
    }
}

// MARK: - Helpers

extension Data {
    init(hex: String) {
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            let byte = UInt8(hex[i..<j], radix: 16)!
            data.append(byte)
            i = j
        }
        self = data
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
