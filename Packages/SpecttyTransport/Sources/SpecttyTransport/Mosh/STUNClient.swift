import Foundation
import Network

/// Minimal STUN Binding Request client per RFC 5389.
/// Discovers the client's public (mapped) IP:port as seen by a STUN server.
public enum STUNClient {

    /// Result of a STUN Binding Request.
    public struct BindingResult: Sendable {
        public let publicAddress: String
        public let publicPort: UInt16
    }

    /// NAT type classification.
    public enum NATType: String, Sendable {
        case coneNAT = "Cone NAT"       // Same mapped address from different servers (good)
        case symmetricNAT = "Symmetric NAT"  // Different mapped address per destination (problematic)
        case unknown = "Unknown"
    }

    // MARK: - Constants

    private static let magicCookie: UInt32 = 0x2112_A442
    private static let bindingRequest: UInt16 = 0x0001
    private static let bindingResponse: UInt16 = 0x0101
    private static let xorMappedAddressType: UInt16 = 0x0020
    private static let mappedAddressType: UInt16 = 0x0001

    /// Discover the client's public address by sending a STUN Binding Request.
    public static func discoverPublicAddress(
        stunServer: String = "stun.l.google.com",
        port: UInt16 = 19302,
        timeout: TimeInterval = 5
    ) async throws -> BindingResult {
        let connection = NWConnection(
            host: NWEndpoint.Host(stunServer),
            port: NWEndpoint.Port(integerLiteral: port),
            using: .udp
        )

        return try await withCheckedThrowingContinuation { cont in
            nonisolated(unsafe) var resumed = false

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send Binding Request
                    let request = buildBindingRequest()
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error, !resumed {
                            resumed = true
                            cont.resume(throwing: error)
                            connection.cancel()
                        }
                    })

                    // Receive response
                    connection.receiveMessage { data, _, _, error in
                        defer { connection.cancel() }
                        guard !resumed else { return }
                        resumed = true

                        if let error {
                            cont.resume(throwing: error)
                            return
                        }
                        guard let data else {
                            cont.resume(throwing: STUNError.noResponse)
                            return
                        }
                        do {
                            let result = try parseBindingResponse(data)
                            cont.resume(returning: result)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }

                case .failed(let error):
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: error)
                    }
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !resumed {
                    resumed = true
                    cont.resume(throwing: STUNError.timeout)
                    connection.cancel()
                }
            }
        }
    }

    /// Detect NAT type by querying two different STUN servers and comparing results.
    /// Same mapped address:port = Cone NAT (good), different = Symmetric NAT (problematic).
    public static func detectNATType() async -> NATType {
        async let result1 = try discoverPublicAddress(stunServer: "stun.l.google.com", port: 19302)
        async let result2 = try discoverPublicAddress(stunServer: "stun1.l.google.com", port: 19302)

        do {
            let r1 = try await result1
            let r2 = try await result2

            if r1.publicAddress == r2.publicAddress && r1.publicPort == r2.publicPort {
                return .coneNAT
            } else {
                return .symmetricNAT
            }
        } catch {
            return .unknown
        }
    }

    // MARK: - Packet Construction

    /// Build a 20-byte STUN Binding Request.
    /// Format: [2 type][2 length][4 magic cookie][12 transaction ID]
    private static func buildBindingRequest() -> Data {
        var data = Data(capacity: 20)

        // Message Type: Binding Request (0x0001)
        data.append(UInt8(bindingRequest >> 8))
        data.append(UInt8(bindingRequest & 0xFF))

        // Message Length: 0 (no attributes)
        data.append(0)
        data.append(0)

        // Magic Cookie
        data.append(UInt8((magicCookie >> 24) & 0xFF))
        data.append(UInt8((magicCookie >> 16) & 0xFF))
        data.append(UInt8((magicCookie >> 8) & 0xFF))
        data.append(UInt8(magicCookie & 0xFF))

        // 12-byte Transaction ID (random)
        for _ in 0..<12 {
            data.append(UInt8.random(in: 0...255))
        }

        return data
    }

    // MARK: - Response Parsing

    /// Parse a STUN Binding Response to extract the mapped address.
    private static func parseBindingResponse(_ data: Data) throws -> BindingResult {
        guard data.count >= 20 else {
            throw STUNError.malformedResponse
        }

        // Verify message type is Binding Response
        let messageType = UInt16(data[0]) << 8 | UInt16(data[1])
        guard messageType == bindingResponse else {
            throw STUNError.unexpectedMessageType(messageType)
        }

        let messageLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        guard data.count >= 20 + messageLength else {
            throw STUNError.malformedResponse
        }

        // Parse attributes looking for XOR-MAPPED-ADDRESS or MAPPED-ADDRESS
        var offset = 20
        let end = 20 + messageLength

        while offset + 4 <= end {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4

            guard offset + attrLength <= end else { break }

            if attrType == xorMappedAddressType {
                return try parseXORMappedAddress(data: data, offset: offset, length: attrLength)
            } else if attrType == mappedAddressType {
                return try parseMappedAddress(data: data, offset: offset, length: attrLength)
            }

            // Attributes are padded to 4-byte boundaries
            offset += attrLength
            offset = (offset + 3) & ~3
        }

        throw STUNError.noMappedAddress
    }

    /// Parse XOR-MAPPED-ADDRESS attribute (type 0x0020).
    private static func parseXORMappedAddress(data: Data, offset: Int, length: Int) throws -> BindingResult {
        guard length >= 8 else { throw STUNError.malformedResponse }

        let family = data[offset + 1]
        let xPort = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
        let port = xPort ^ UInt16(magicCookie >> 16)

        if family == 0x01 {
            // IPv4: XOR with magic cookie
            let cookieBytes = [
                UInt8((magicCookie >> 24) & 0xFF),
                UInt8((magicCookie >> 16) & 0xFF),
                UInt8((magicCookie >> 8) & 0xFF),
                UInt8(magicCookie & 0xFF),
            ]
            let ip = "\(data[offset + 4] ^ cookieBytes[0]).\(data[offset + 5] ^ cookieBytes[1]).\(data[offset + 6] ^ cookieBytes[2]).\(data[offset + 7] ^ cookieBytes[3])"
            return BindingResult(publicAddress: ip, publicPort: port)
        } else if family == 0x02 {
            // IPv6: XOR with magic cookie + transaction ID
            guard length >= 20 else { throw STUNError.malformedResponse }
            var ipBytes = [UInt8](repeating: 0, count: 16)
            // XOR key: 4 bytes magic cookie + 12 bytes transaction ID (from header bytes 8..19)
            var xorKey = [UInt8](repeating: 0, count: 16)
            xorKey[0] = UInt8((magicCookie >> 24) & 0xFF)
            xorKey[1] = UInt8((magicCookie >> 16) & 0xFF)
            xorKey[2] = UInt8((magicCookie >> 8) & 0xFF)
            xorKey[3] = UInt8(magicCookie & 0xFF)
            for i in 0..<12 {
                xorKey[4 + i] = data[8 + i]
            }
            for i in 0..<16 {
                ipBytes[i] = data[offset + 4 + i] ^ xorKey[i]
            }
            let groups = stride(from: 0, to: 16, by: 2).map { i in
                String(format: "%x", UInt16(ipBytes[i]) << 8 | UInt16(ipBytes[i + 1]))
            }
            let ip = groups.joined(separator: ":")
            return BindingResult(publicAddress: ip, publicPort: port)
        }

        throw STUNError.unsupportedAddressFamily(family)
    }

    /// Parse MAPPED-ADDRESS attribute (type 0x0001) — fallback for older servers.
    private static func parseMappedAddress(data: Data, offset: Int, length: Int) throws -> BindingResult {
        guard length >= 8 else { throw STUNError.malformedResponse }

        let family = data[offset + 1]
        let port = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])

        if family == 0x01 {
            let ip = "\(data[offset + 4]).\(data[offset + 5]).\(data[offset + 6]).\(data[offset + 7])"
            return BindingResult(publicAddress: ip, publicPort: port)
        }

        throw STUNError.unsupportedAddressFamily(family)
    }
}

// MARK: - Errors

public enum STUNError: Error, LocalizedError {
    case timeout
    case noResponse
    case malformedResponse
    case unexpectedMessageType(UInt16)
    case noMappedAddress
    case unsupportedAddressFamily(UInt8)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "STUN request timed out"
        case .noResponse:
            return "No response from STUN server"
        case .malformedResponse:
            return "Malformed STUN response"
        case .unexpectedMessageType(let type):
            return "Unexpected STUN message type: 0x\(String(format: "%04x", type))"
        case .noMappedAddress:
            return "No mapped address in STUN response"
        case .unsupportedAddressFamily(let family):
            return "Unsupported address family: \(family)"
        }
    }
}
