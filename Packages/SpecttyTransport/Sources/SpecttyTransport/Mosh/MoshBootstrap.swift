import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Result of bootstrapping a Mosh session via SSH.
/// After bootstrap, SSH is closed — mosh communicates entirely over UDP.
struct MoshSession: Sendable {
    let host: String
    let udpPort: Int
    let key: String // base64-encoded 128-bit key
}

/// SSH exec helper that starts `mosh-server` on a remote host and parses
/// the `MOSH CONNECT <port> <key>` response.
enum MoshBootstrap {
    /// Connect via SSH, exec `mosh-server`, parse the response, then
    /// gracefully close SSH. Mosh communicates entirely over UDP after this.
    ///
    /// Matches the real mosh client's behavior: allocates a PTY (-tt) before
    /// exec, runs mosh-server directly, reads MOSH CONNECT, then closes SSH.
    static func start(config: SSHConnectionConfig, options: MoshBootstrapOptions = .init()) async throws -> MoshSession {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let authDelegate: NIOSSHClientUserAuthenticationDelegate = switch config.authMethod {
        case .password(let password):
            SSHPasswordDelegate(username: config.username, password: password)
        case .publicKey(let key):
            SSHPublicKeyDelegate(username: config.username, privateKey: key)
        }
        nonisolated(unsafe) let authDelegateRef = authDelegate
        let serverAuthDelegate = AcceptAllHostKeysDelegate()

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: authDelegateRef,
                                serverAuthDelegate: serverAuthDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let parentChannel: Channel
        do {
            parentChannel = try await bootstrap.connect(host: config.host, port: config.port).get()
        } catch {
            group.shutdownGracefully { _ in }
            throw MoshError.bootstrapFailed("SSH connection failed: \(error)")
        }

        // Collect stdout from the exec channel
        let outputCollector = ExecOutputCollector()
        let collectorRef = outputCollector

        // Open session channel
        let childChannel: Channel
        do {
            childChannel = try await parentChannel.eventLoop.flatSubmit {
                let childPromise = parentChannel.eventLoop.makePromise(of: Channel.self)

                parentChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                    switch result {
                    case .failure(let error):
                        childPromise.fail(error)
                    case .success(let sshHandler):
                        sshHandler.createChannel(childPromise, channelType: .session) { childChannel, channelType in
                            guard channelType == .session else {
                                return childChannel.eventLoop.makeFailedFuture(SSHTransportError.channelCreationFailed)
                            }
                            return childChannel.eventLoop.makeCompletedFuture {
                                try childChannel.pipeline.syncOperations.addHandler(collectorRef)
                            }
                        }
                    }
                }

                return childPromise.futureResult
            }.get()
        } catch {
            parentChannel.close(promise: nil)
            group.shutdownGracefully { _ in }
            throw MoshError.bootstrapFailed("Failed to open SSH channel: \(error)")
        }

        if options.allocatePTY {
            // Request PTY allocation before exec, matching the real mosh client's
            // `-tt` SSH flag. This creates a proper session with a controlling
            // terminal on the server side, which is how mosh-server expects to run.
            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: 80,
                terminalRowHeight: 24,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            let ptyPromise = childChannel.eventLoop.makePromise(of: Void.self)
            childChannel.triggerUserOutboundEvent(ptyRequest, promise: ptyPromise)

            do {
                try await ptyPromise.futureResult.get()
            } catch {
                parentChannel.close(promise: nil)
                group.shutdownGracefully { _ in }
                throw MoshError.bootstrapFailed("PTY allocation failed: \(error)")
            }
        }

        // Exec mosh-server directly (like the real mosh client).
        // Prepend common install locations so mosh-server is found on
        // macOS (Homebrew ARM + Intel, MacPorts) and Linux (apt, snap, nix).
        // Use -i to bind the correct address family for our SSH connection,
        // since macOS sets IPV6_V6ONLY=1 by default (IPv6 sockets reject IPv4).
        //
        // MOSH_SERVER_NETWORK_TMOUT: auto-exit after 10 min of no client
        // packets. Prevents orphaned mosh-servers from accumulating when
        // the app crashes, is killed, or the network changes permanently.
        // During active use, heartbeats every 3s keep the server alive.
        let command = buildServerCommand(config: config, options: options)
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )

        let execPromise = childChannel.eventLoop.makePromise(of: Void.self)
        childChannel.triggerUserOutboundEvent(execRequest, promise: execPromise)

        do {
            try await execPromise.futureResult.get()
        } catch {
            parentChannel.close(promise: nil)
            group.shutdownGracefully { _ in }
            throw MoshError.bootstrapFailed("SSH exec failed: \(error)")
        }

        // Wait for MOSH CONNECT output with a timeout.
        // ExecOutputCollector returns eagerly once it sees MOSH CONNECT.
        let output: String
        do {
            output = try await withThrowingTaskGroup(of: String.self) { taskGroup in
                taskGroup.addTask {
                    try await outputCollector.waitForOutput()
                }
                taskGroup.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw MoshError.bootstrapFailed("Timed out waiting for mosh-server response")
                }
                let result = try await taskGroup.next()!
                taskGroup.cancelAll()
                return result
            }
        } catch {
            parentChannel.close(promise: nil)
            group.shutdownGracefully { _ in }
            throw error
        }

        // Parse "MOSH CONNECT <port> <key>"
        let parsed: ParsedConnect
        do {
            let defaultResolvedHost = parentChannel.remoteAddress?.ipAddress ?? config.host
            let localResolvedHost = resolveHostLocally(host: config.host)
            parsed = try parseMoshConnect(
                output: output,
                defaultHost: defaultResolvedHost,
                localResolvedHost: localResolvedHost,
                ipResolution: options.ipResolution
            )
        } catch {
            parentChannel.close(promise: nil)
            group.shutdownGracefully { _ in }
            throw error
        }

        // Close SSH in the background. mosh-server has already daemonized
        // (forked, parent exited) and communicates entirely over UDP.
        let channel = parentChannel
        let g = group
        Task.detached {
            // Brief delay to let mosh-server's daemon fully initialize
            try? await Task.sleep(for: .seconds(1))
            let p = channel.eventLoop.makePromise(of: Void.self)
            channel.close(promise: p)
            try? await p.futureResult.get()
            try? await g.shutdownGracefully()
        }

        return MoshSession(
            host: parsed.host,
            udpPort: parsed.udpPort,
            key: parsed.key
        )
    }

    /// Kill a remote mosh-server by SSH-ing back and sending a kill command.
    /// Best-effort: if SSH fails, the server's network timeout will clean it up.
    static func killServer(config: SSHConnectionConfig, udpPort: Int) {
        Task.detached {
            do {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                defer { group.shutdownGracefully { _ in } }

                let authDelegate: NIOSSHClientUserAuthenticationDelegate = switch config.authMethod {
                case .password(let password):
                    SSHPasswordDelegate(username: config.username, password: password)
                case .publicKey(let key):
                    SSHPublicKeyDelegate(username: config.username, privateKey: key)
                }
                nonisolated(unsafe) let authDelegateRef = authDelegate
                let serverAuthDelegate = AcceptAllHostKeysDelegate()

                let bootstrap = ClientBootstrap(group: group)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let sshHandler = NIOSSHHandler(
                                role: .client(.init(
                                    userAuthDelegate: authDelegateRef,
                                    serverAuthDelegate: serverAuthDelegate
                                )),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            )
                            try channel.pipeline.syncOperations.addHandler(sshHandler)
                        }
                    }

                let parentChannel = try await bootstrap.connect(host: config.host, port: config.port).get()

                // Open a session channel and exec a kill command targeting
                // the mosh-server listening on the known UDP port.
                let childChannel: Channel = try await parentChannel.eventLoop.flatSubmit {
                    let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
                    parentChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                        switch result {
                        case .failure(let error):
                            promise.fail(error)
                        case .success(let sshHandler):
                            sshHandler.createChannel(promise, channelType: .session) { child, _ in
                                child.eventLoop.makeSucceededVoidFuture()
                            }
                        }
                    }
                    return promise.futureResult
                }.get()

                let killCmd = "kill $(lsof -t -i UDP:\(udpPort)) 2>/dev/null; exit 0"
                let execRequest = SSHChannelRequestEvent.ExecRequest(command: killCmd, wantReply: true)
                let execPromise = childChannel.eventLoop.makePromise(of: Void.self)
                childChannel.triggerUserOutboundEvent(execRequest, promise: execPromise)
                try await execPromise.futureResult.get()

                // Wait briefly for the kill to take effect, then close
                try? await Task.sleep(for: .milliseconds(500))
                parentChannel.close(promise: nil)
            } catch {
                // Best-effort: MOSH_SERVER_NETWORK_TMOUT will clean up eventually
            }
        }
    }

    struct ParsedConnect {
        let host: String
        let udpPort: Int
        let key: String
    }

    /// Parse mosh-server output for the MOSH CONNECT line.
    /// Handles PTY output which may contain `\r` characters from TTY line discipline.
    static func parseMoshConnect(
        output: String,
        defaultHost: String,
        localResolvedHost: String? = nil,
        ipResolution: MoshIPResolution = .default
    ) throws -> ParsedConnect {
        let targetHost: String = switch ipResolution {
        case .default:
            defaultHost
        case .local:
            localResolvedHost ?? defaultHost
        case .remote:
            parseRemoteHostFromSSHConnection(output: output) ?? defaultHost
        }

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("MOSH CONNECT") {
                let parts = trimmed.split(separator: " ")
                guard parts.count >= 4 else {
                    throw MoshError.bootstrapFailed("Malformed MOSH CONNECT line: \(trimmed)")
                }
                guard let port = Int(parts[2]) else {
                    throw MoshError.bootstrapFailed("Invalid port in MOSH CONNECT: \(parts[2])")
                }
                let key = String(parts[3])
                return ParsedConnect(host: targetHost, udpPort: port, key: key)
            }
        }
        throw MoshError.bootstrapFailed("No MOSH CONNECT line in server output: \(output)")
    }

    private static func parseRemoteHostFromSSHConnection(output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("MOSH SSH_CONNECTION") else { continue }
            let parts = trimmed.split(separator: " ")
            // MOSH SSH_CONNECTION <client_ip> <client_port> <server_ip> <server_port>
            guard parts.count >= 6 else { continue }
            return String(parts[4])
        }
        return nil
    }

    private static func buildServerCommand(config: SSHConnectionConfig, options: MoshBootstrapOptions) -> String {
        let bindAddr = bindAddress(for: config.host, family: options.bindFamily)
        let serverPath = sanitized(options.serverPath) ?? "mosh-server"

        var args: [String] = ["new", "-i", bindAddr]
        if let udpPortRange = sanitizedUDPPortRange(options.udpPortRange) {
            args.append(contentsOf: ["-p", udpPortRange])
        }
        args.append(contentsOf: ["-c", "256", "-l", "LANG=en_US.UTF-8"])

        let env = "export PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/snap/bin:/nix/var/nix/profiles/default/bin:$PATH\" MOSH_SERVER_NETWORK_TMOUT=600;"
        let runServer = "exec \(shellQuote(serverPath)) \(args.joined(separator: " "))"
        if options.ipResolution == .remote {
            return "\(env) echo \"MOSH SSH_CONNECTION $SSH_CONNECTION\"; \(runServer)"
        } else {
            return "\(env) \(runServer)"
        }
    }

    private static func bindAddress(for host: String, family: MoshBindFamily) -> String {
        switch family {
        case .automatic:
            return host.contains(":") ? "::" : "0.0.0.0"
        case .ipv4:
            return "0.0.0.0"
        case .ipv6:
            return "::"
        }
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveHostLocally(host: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if let parsed = try? SocketAddress(ipAddress: trimmedHost, port: 0),
           let ip = parsed.ipAddress {
            return ip
        }

        if let resolved = try? SocketAddress.makeAddressResolvingHost(trimmedHost, port: 0),
           let ip = resolved.ipAddress {
            return ip
        }

        return nil
    }

    private static func sanitizedUDPPortRange(_ value: String?) -> String? {
        guard let value = sanitized(value) else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789:")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return value
    }

    private static func shellQuote(_ raw: String) -> String {
        // POSIX shell single-quote escaping.
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

// MARK: - ExecOutputCollector

/// NIO channel handler that collects stdout from an SSH exec channel.
/// Returns output as soon as the `MOSH CONNECT` line is seen,
/// or when the channel closes — whichever comes first.
private final class ExecOutputCollector: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private var buffer = Data()
    private var continuation: CheckedContinuation<String, any Error>?
    private var delivered = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel || channelData.type == .stdErr else { return }

        switch channelData.data {
        case .byteBuffer(let buf):
            if let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) {
                buffer.append(contentsOf: bytes)
            }
        case .fileRegion:
            break
        }

        // Deliver eagerly once we see the MOSH CONNECT line
        if !delivered, let output = String(data: buffer, encoding: .utf8),
           output.contains("MOSH CONNECT") {
            delivered = true
            continuation?.resume(returning: output)
            continuation = nil
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !delivered {
            delivered = true
            let output = String(data: buffer, encoding: .utf8) ?? ""
            continuation?.resume(returning: output)
            continuation = nil
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !delivered {
            delivered = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
        context.close(promise: nil)
    }

    /// Wait for MOSH CONNECT output (or channel close).
    func waitForOutput() async throws -> String {
        if delivered {
            return String(data: buffer, encoding: .utf8) ?? ""
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
            }
        } onCancel: {
            self.cancelContinuation()
        }
    }

    private func cancelContinuation() {
        guard !delivered else { return }
        delivered = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

extension ExecOutputCollector: @unchecked Sendable {}
