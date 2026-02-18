// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
//
// URLSessionCompat.swift — Async/await URLSession shims for Linux
// swift-corelibs-foundation does not include the async convenience methods
// (data(for:), data(from:), bytes(for:)) that Apple platforms provide.

#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

extension URLSession {

    // MARK: - data(for:) / data(from:)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: url) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }

    // MARK: - bytes(for:)  —  Buffered shim

    /// Minimal AsyncBytes for Linux. Buffers the full HTTP response, then yields
    /// bytes one at a time through an AsyncSequence.
    ///
    /// On Apple platforms the real URLSession.AsyncBytes streams data as it
    /// arrives. This shim waits for the complete response — acceptable for most
    /// API calls but means streaming LLM output arrives all-at-once. A future
    /// enhancement could use URLSessionDataDelegate + AsyncStream for true
    /// streaming on Linux.
    struct AsyncBytes: AsyncSequence {
        typealias Element = UInt8

        let data: Data

        struct AsyncIterator: AsyncIteratorProtocol {
            var index: Data.Index
            let endIndex: Data.Index
            let data: Data

            mutating func next() async -> UInt8? {
                guard index < endIndex else { return nil }
                let byte = data[index]
                index = data.index(after: index)
                return byte
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(index: data.startIndex, endIndex: data.endIndex, data: data)
        }
    }

    func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
        let (data, response) = try await self.data(for: request)
        return (AsyncBytes(data: data), response)
    }
}
#endif
