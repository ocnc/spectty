import Foundation

/// State Synchronization Protocol (SSP) for Mosh.
///
/// SSP maintains synchronized state between client and server by exchanging
/// diffs. The client sends `UserMessage` diffs (keystrokes, resizes), and
/// the server sends `HostMessage` diffs (terminal output bytes).
///
/// Each side tracks: the last state number acknowledged by the remote,
/// the current state number being sent, and uses these to determine what
/// diffs to include in each packet.
///
/// All mutable state is protected by a serial DispatchQueue to ensure
/// thread safety across heartbeat Task, NWConnection callbacks, and caller threads.
final class MoshSSP: @unchecked Sendable {
    private let network: MoshNetwork
    private let queue = DispatchQueue(label: "com.spectty.mosh.ssp")

    // Sender state (client → server)
    private var senderCurrentNum: UInt64 = 0
    private var senderAckedNum: UInt64 = 0
    // Unacked content: accumulates until server acknowledges
    private var unackedKeystrokes: Data = Data()
    private var unackedResize: ResizeMessage? = nil

    // Receiver state (server → client)
    private var receiverCurrentNum: UInt64 = 0

    // Fragment framing (compress + fragment header)
    private let fragmenter = MoshFragmenter()
    private let fragmentAssembly = MoshFragmentAssembly()

    // Timestamp management
    private let epoch = Date()
    private var lastRemoteTimestamp: UInt16 = 0
    private var lastRemoteTimestampReceived: Date? = nil

    // Heartbeat / retransmit
    private var heartbeatTask: Task<Void, Never>?
    private static let heartbeatInterval: TimeInterval = 3.0
    private static let retransmitInterval: TimeInterval = 1.0
    private var lastSendTime: Date = .distantPast

    /// Called when host bytes are received from the server.
    var onHostBytes: ((Data) -> Void)?

    /// Called when the server requests a resize.
    var onResize: ((Int, Int) -> Void)?

    init(network: MoshNetwork) {
        self.network = network
    }

    /// Start the SSP: set up receive handling and heartbeat.
    func start() {
        network.onReceive = { [weak self] packet in
            self?.handleServerPacket(packet)
        }
        startHeartbeat()
        // Send an initial empty packet to establish the connection
        queue.sync { sendPacket() }
    }

    /// Stop the SSP.
    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        network.onReceive = nil
    }

    /// Queue keystrokes to be sent to the server.
    func queueKeystrokes(_ data: Data) {
        queue.sync {
            unackedKeystrokes.append(data)
            // New content → advance state number
            if senderCurrentNum == senderAckedNum {
                senderCurrentNum = senderAckedNum + 1
            }
            sendPacket()
        }
    }

    /// Queue a resize event.
    func queueResize(columns: Int, rows: Int) {
        queue.sync {
            unackedResize = ResizeMessage(width: Int32(columns), height: Int32(rows))
            if senderCurrentNum == senderAckedNum {
                senderCurrentNum = senderAckedNum + 1
            }
            sendPacket()
        }
    }

    // MARK: - Sending

    /// Send the current state to the server.
    /// The diff always contains ALL unacked content (keystrokes + resize).
    /// State number only advances when new content is added, not on retransmits.
    /// Must be called on `queue`.
    private func sendPacket() {
        // Build UserMessage with all unacked content
        var userMsg = UserMessage()
        if !unackedKeystrokes.isEmpty {
            userMsg.keystrokes.append(unackedKeystrokes)
        }
        if let resize = unackedResize {
            userMsg.resize = resize
        }

        let userDiff = userMsg.serialize()

        // Build TransportInstruction
        // throwawayNum = senderAckedNum (our sender's oldest state, in client state namespace)
        let instruction = TransportInstruction(
            oldNum: senderAckedNum,
            newNum: senderCurrentNum,
            ackNum: receiverCurrentNum,
            throwawayNum: senderAckedNum,
            diff: userDiff
        )

        // Fragment: serialize protobuf → zlib compress → add fragment header
        let fragments = fragmenter.makeFragments(instruction: instruction)
        let ts = currentTimestamp()
        let tsReply = computeTimestampReply()

        for fragment in fragments {
            let payload = fragment.serialize()
            network.send(payload: payload, timestamp: ts, timestampReply: tsReply)
        }
        lastSendTime = Date()
    }

    // MARK: - Receiving

    private func handleServerPacket(_ packet: MoshPacket) {
        queue.sync {
            // Update remote timestamp tracking for RTT
            lastRemoteTimestamp = packet.timestamp
            lastRemoteTimestampReceived = Date()

            // Parse fragment header
            guard let fragment = MoshFragment.parse(from: packet.payload) else { return }

            // Reassemble fragments → decompress → parse protobuf
            guard let instruction = fragmentAssembly.addFragment(fragment) else {
                return
            }
            // Update sender ack: the server tells us it has received up to ackNum
            if instruction.ackNum > senderAckedNum {
                senderAckedNum = instruction.ackNum
                // Server has seen our current state — clear unacked content
                if senderAckedNum >= senderCurrentNum {
                    unackedKeystrokes = Data()
                    unackedResize = nil
                    senderCurrentNum = senderAckedNum
                }
            }

            // Process diff if this is a new state
            if instruction.newNum > receiverCurrentNum {
                receiverCurrentNum = instruction.newNum

                // Decode HostMessage from diff
                if !instruction.diff.isEmpty {
                    let hostMsg = HostMessage.deserialize(from: instruction.diff)

                    // Emit host bytes (terminal output) to the terminal emulator
                    for bytes in hostMsg.hostBytes {
                        onHostBytes?(bytes)
                    }

                    // Handle server-initiated resize
                    if let resize = hostMsg.resize {
                        onResize?(Int(resize.width), Int(resize.height))
                    }
                }

                // Send immediate ack so the server updates its base state for
                // future diffs. Without this, the server keeps diffing from an
                // old base, causing overlapping ANSI output that doubles characters.
                sendPacket()
            }
        }
    }

    // MARK: - Timestamps

    /// Mosh timestamp: milliseconds since session start, modulo 65536.
    private func currentTimestamp() -> UInt16 {
        let ms = Date().timeIntervalSince(epoch) * 1000.0
        return UInt16(UInt64(ms) % 65536)
    }

    /// Compute reply timestamp: last remote timestamp + elapsed time since we received it.
    /// Must be called on `queue`.
    private func computeTimestampReply() -> UInt16 {
        guard let received = lastRemoteTimestampReceived else {
            return 0
        }
        let elapsed = Date().timeIntervalSince(received) * 1000.0
        let reply = (UInt64(lastRemoteTimestamp) + UInt64(elapsed)) % 65536
        return UInt16(reply)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }

                self.queue.sync {
                    let now = Date()
                    let timeSinceLastSend = now.timeIntervalSince(self.lastSendTime)

                    // Retransmit if we have unacked state
                    if self.senderAckedNum < self.senderCurrentNum,
                       timeSinceLastSend > Self.retransmitInterval {
                        self.sendPacket()
                    }
                    // Heartbeat if idle
                    else if timeSinceLastSend > Self.heartbeatInterval {
                        self.sendPacket()
                    }
                }
            }
        }
    }
}
