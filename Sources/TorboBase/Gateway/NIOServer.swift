// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — SwiftNIO TCP Server (Linux)
// Replaces NWListener on platforms where Network.framework isn't available.

#if canImport(NIOCore)
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

// MARK: - NIO Response Writer

/// Implements ResponseWriter for SwiftNIO channels
/// @unchecked Sendable: SwiftNIO's Channel is internally thread-safe but does not
/// formally conform to Sendable. This wrapper only stores a reference and the allocator
/// derived from it — no mutable shared state. Safe for concurrent access.
final class NIOResponseWriter: ResponseWriter, @unchecked Sendable {
    private let channel: Channel
    private let allocator: ByteBufferAllocator

    init(channel: Channel) {
        self.channel = channel
        self.allocator = channel.allocator
    }

    func sendResponse(_ response: HTTPResponse) {
        // serialize() produces the complete HTTP response (status line + headers + body)
        let serialized = response.serialize()
        var buffer = allocator.buffer(capacity: serialized.count)
        buffer.writeBytes(serialized)
        channel.writeAndFlush(NIOAny(buffer)).whenComplete { [weak self] _ in
            self?.channel.close(promise: nil)
        }
    }

    func sendRawResponse(_ data: Data) {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(NIOAny(buffer)).whenComplete { [weak self] _ in
            self?.channel.close(promise: nil)
        }
    }

    func sendStreamHeaders(origin: String? = nil) {
        var h = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n"
        if let origin = origin { h += "Access-Control-Allow-Origin: \(origin)\r\n" }
        h += "\r\n"
        var buffer = allocator.buffer(capacity: h.utf8.count)
        buffer.writeString(h)
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
        channel.writeAndFlush(NIOAny(buffer)).whenComplete { [weak self] _ in
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
    private let maxRequestSize = 20 * 1024 * 1024 // 20MB — vision payloads include base64 images

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            // Reject oversized requests to prevent memory exhaustion
            if accumulated.count + bytes.count > maxRequestSize {
                TorboLog.warn("Request too large (\(accumulated.count + bytes.count) bytes) — closing connection", subsystem: "NIO")
                accumulated = Data()
                context.close(promise: nil)
                return
            }
            accumulated.append(contentsOf: bytes)
        }

        // Check if the HTTP request is complete
        if GatewayServer.isHTTPRequestComplete(accumulated) {
            let requestData = accumulated
            accumulated = Data()

            let writer = NIOResponseWriter(channel: context.channel)
            let rawAddr = context.remoteAddress?.description ?? "unknown"
            // Strip port from address — NIO format is "[IPv4]127.0.0.1/127.0.0.1:54321"
            let remoteAddr = GatewayServer.stripPort(from: rawAddr)

            Task {
                await GatewayServer.shared.handleRequest(requestData, clientIP: remoteAddr, writer: writer)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        TorboLog.error("Error: \(error)", subsystem: "NIO")
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

        // Bind to all interfaces to allow LAN device connections (phone pairing)
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
        self.channel = channel
        TorboLog.info("Listening on port \(port)", subsystem: "NIO")
    }

    func stop() async {
        do {
            try await channel?.close()
            try await group?.shutdownGracefully()
        } catch {
            TorboLog.error("Shutdown error: \(error)", subsystem: "NIO")
        }
        channel = nil
        group = nil
        TorboLog.info("Stopped", subsystem: "NIO")
    }
}
#endif
