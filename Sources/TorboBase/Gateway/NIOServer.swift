// Torbo Base — SwiftNIO TCP Server (Linux)
// Replaces NWListener on platforms where Network.framework isn't available.

#if canImport(NIOCore)
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

// MARK: - NIO Response Writer

/// Implements ResponseWriter for SwiftNIO channels
final class NIOResponseWriter: ResponseWriter, @unchecked Sendable {
    private let channel: Channel
    private let allocator: ByteBufferAllocator

    init(channel: Channel) {
        self.channel = channel
        self.allocator = channel.allocator
    }

    func sendResponse(_ response: HTTPResponse) {
        let serialized = response.serialize()
        var buffer = allocator.buffer(capacity: serialized.count)
        buffer.writeBytes(serialized)
        let head = HTTPResponseHead(version: .http1_1, status: .ok)
        // Write raw bytes (HTTPResponse.serialize() includes the full HTTP response)
        channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        channel.close(promise: nil)
    }

    func sendRawResponse(_ data: Data) {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(NIOAny(buffer), promise: nil).whenComplete { [weak self] _ in
            self?.channel.close(promise: nil)
        }
    }

    func sendStreamHeaders() {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        var buffer = allocator.buffer(capacity: headers.utf8.count)
        buffer.writeString(headers)
        channel.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    func sendSSEChunk(_ data: String) {
        let chunk = "data: \(data)\n\n"
        var buffer = allocator.buffer(capacity: chunk.utf8.count)
        buffer.writeString(chunk)
        channel.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    func sendSSEDone() {
        let done = "data: [DONE]\n\n"
        var buffer = allocator.buffer(capacity: done.utf8.count)
        buffer.writeString(done)
        channel.writeAndFlush(NIOAny(buffer), promise: nil).whenComplete { [weak self] _ in
            self?.channel.close(promise: nil)
        }
    }
}

// MARK: - HTTP Request Handler

/// Handles incoming HTTP requests via SwiftNIO and forwards them to GatewayServer
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var accumulated = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            accumulated.append(contentsOf: bytes)
        }

        // Check if the HTTP request is complete
        if GatewayServer.isHTTPRequestComplete(accumulated) {
            let requestData = accumulated
            accumulated = Data()

            let writer = NIOResponseWriter(channel: context.channel)
            let remoteAddr = context.remoteAddress?.description ?? "unknown"

            Task {
                await GatewayServer.shared.handleRequest(requestData, clientIP: remoteAddr, writer: writer)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[NIOServer] Error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - NIO Server

/// SwiftNIO-based TCP server for Linux — replacement for NWListener
actor NIOServer {
    private var channel: Channel?
    private var group: EventLoopGroup?

    func start(port: UInt16) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(HTTPHandler())
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
        self.channel = channel
        print("[NIOServer] Listening on port \(port)")
    }

    func stop() async {
        do {
            try await channel?.close()
            try await group?.shutdownGracefully()
        } catch {
            print("[NIOServer] Shutdown error: \(error)")
        }
        channel = nil
        group = nil
        print("[NIOServer] Stopped")
    }
}
#endif
