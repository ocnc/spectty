import Foundation
import NIOCore
import NIOSSH

/// A NIO `ChannelDuplexHandler` that bridges an SSH child channel with an
/// `AsyncStream` continuation, forwarding received bytes and allowing writes.
final class SSHChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let dataContinuation: AsyncStream<Data>.Continuation
    private var context: ChannelHandlerContext?

    init(dataContinuation: AsyncStream<Data>.Continuation) {
        self.dataContinuation = dataContinuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        // Only forward standard channel data (ignore stderr for now).
        guard channelData.type == .channel else { return }

        switch channelData.data {
        case .byteBuffer(let buffer):
            if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                dataContinuation.yield(Data(bytes))
            }
        case .fileRegion:
            // FileRegion is not expected over SSH channels.
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        dataContinuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        dataContinuation.finish()
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(channelData), promise: promise)
    }
}

extension SSHChannelHandler: @unchecked Sendable {}
