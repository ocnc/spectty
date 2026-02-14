import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Configuration for an SSH connection.
public struct SSHConnectionConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod

    public init(host: String, port: Int = 22, username: String, authMethod: SSHAuthMethod) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }
}

/// Errors specific to the SSH transport layer.
public enum SSHTransportError: Error, LocalizedError {
    case notConnected
    case alreadyConnected
    case authenticationFailed
    case channelCreationFailed
    case connectionClosed
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH transport is not connected"
        case .alreadyConnected: return "SSH transport is already connected"
        case .authenticationFailed: return "SSH authentication failed — check username and password"
        case .channelCreationFailed: return "Failed to create SSH channel"
        case .connectionClosed: return "SSH connection was closed"
        case .connectionFailed(let detail): return "SSH connection failed: \(detail)"
        }
    }
}

/// A fully functional SSH transport using SwiftNIO and NIOSSH.
///
/// Creates a TCP connection, performs SSH handshake, opens a session channel
/// with a PTY allocation, starts a shell, and pipes data bidirectionally.
public final class SSHTransport: TerminalTransport, @unchecked Sendable {
    public let state: AsyncStream<TransportState>
    public let incomingData: AsyncStream<Data>

    private let config: SSHConnectionConfig
    private let stateContinuation: AsyncStream<TransportState>.Continuation
    private let dataContinuation: AsyncStream<Data>.Continuation

    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let ownsEventLoopGroup: Bool

    // Mutable connection state -- guarded by @unchecked Sendable because
    // all mutation happens in a serialized fashion (connect/disconnect are
    // called sequentially by the consumer, and NIO channel operations are
    // dispatched to the event loop).
    nonisolated(unsafe) private var parentChannel: Channel?
    nonisolated(unsafe) private var childChannel: Channel?

    /// Create an SSH transport.
    ///
    /// - Parameters:
    ///   - config: The SSH connection configuration.
    ///   - eventLoopGroup: An optional NIO event loop group. If `nil`, the
    ///     transport creates its own single-threaded group and shuts it down
    ///     on disconnect.
    public init(config: SSHConnectionConfig, eventLoopGroup: MultiThreadedEventLoopGroup? = nil) {
        self.config = config

        if let group = eventLoopGroup {
            self.eventLoopGroup = group
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsEventLoopGroup = true
        }

        var sc: AsyncStream<TransportState>.Continuation!
        self.state = AsyncStream { sc = $0 }
        self.stateContinuation = sc

        var dc: AsyncStream<Data>.Continuation!
        self.incomingData = AsyncStream { dc = $0 }
        self.dataContinuation = dc
    }

    deinit {
        stateContinuation.finish()
        dataContinuation.finish()
        if ownsEventLoopGroup {
            eventLoopGroup.shutdownGracefully { _ in }
        }
    }

    // MARK: - TerminalTransport

    public func connect() async throws {
        guard parentChannel == nil else {
            throw SSHTransportError.alreadyConnected
        }

        stateContinuation.yield(.connecting)

        nonisolated(unsafe) let authDelegate = makeAuthDelegate()
        let serverAuthDelegate = AcceptAllHostKeysDelegate()

        // Build the NIO client bootstrap with the SSH handler.
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: authDelegate,
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

        // Establish TCP connection and SSH handshake.
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: config.host, port: config.port).get()
        } catch {
            let wrapped = SSHTransportError.connectionFailed(
                "Could not connect to \(config.host):\(config.port) — \(error)"
            )
            stateContinuation.yield(.failed(wrapped))
            throw wrapped
        }

        self.parentChannel = channel

        // Open an SSH session child channel with PTY and shell.
        do {
            try await openSessionChannel(on: channel)
        } catch {
            stateContinuation.yield(.failed(error))
            try? await channel.close()
            self.parentChannel = nil
            throw error
        }

        stateContinuation.yield(.connected)

        // Monitor the parent channel's close future so we can update state.
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.parentChannel = nil
            self.childChannel = nil
            self.stateContinuation.yield(.disconnected)
            self.dataContinuation.finish()
        }
    }

    public func disconnect() async throws {
        guard let parent = parentChannel else {
            return // Already disconnected; no-op.
        }

        if let child = childChannel {
            try? await child.close()
            self.childChannel = nil
        }

        try await parent.close()
        self.parentChannel = nil

        if ownsEventLoopGroup {
            try await eventLoopGroup.shutdownGracefully()
        }
    }

    public func send(_ data: Data) async throws {
        guard let child = childChannel else {
            throw SSHTransportError.notConnected
        }

        var buffer = child.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        try await child.writeAndFlush(buffer)
    }

    public func resize(columns: Int, rows: Int) async throws {
        guard let child = childChannel else {
            throw SSHTransportError.notConnected
        }

        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )

        let promise = child.eventLoop.makePromise(of: Void.self)
        child.triggerUserOutboundEvent(request, promise: promise)
        try await promise.futureResult.get()
    }

    // MARK: - Private

    private func makeAuthDelegate() -> NIOSSHClientUserAuthenticationDelegate {
        switch config.authMethod {
        case .password(let password):
            return SSHPasswordDelegate(username: config.username, password: password)
        case .publicKey(let key):
            return SSHPublicKeyDelegate(username: config.username, privateKey: key)
        }
    }

    /// Opens an SSH session child channel, requests a PTY, and starts a shell.
    private func openSessionChannel(on parentChannel: Channel) async throws {
        let dataContinuation = self.dataContinuation

        // Perform all SSH handler interaction on the event loop to avoid
        // crossing NIOSSHHandler across an async boundary (its Sendable
        // conformance is explicitly unavailable).
        let childChannel: Channel = try await parentChannel.eventLoop.flatSubmit {
            let childPromise = parentChannel.eventLoop.makePromise(of: Channel.self)

            parentChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                switch result {
                case .failure(let error):
                    childPromise.fail(error)
                case .success(let sshHandler):
                    let channelHandler = SSHChannelHandler(dataContinuation: dataContinuation)

                    sshHandler.createChannel(childPromise, channelType: .session) { childChannel, channelType in
                        guard channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(SSHTransportError.channelCreationFailed)
                        }

                        return childChannel.eventLoop.makeCompletedFuture {
                            try childChannel.pipeline.syncOperations.addHandler(channelHandler)
                        }
                    }
                }
            }

            return childPromise.futureResult
        }.get()

        self.childChannel = childChannel

        // Request PTY allocation.
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
        try await ptyPromise.futureResult.get()

        // Request shell.
        let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        let shellPromise = childChannel.eventLoop.makePromise(of: Void.self)
        childChannel.triggerUserOutboundEvent(shellRequest, promise: shellPromise)
        try await shellPromise.futureResult.get()
    }
}

