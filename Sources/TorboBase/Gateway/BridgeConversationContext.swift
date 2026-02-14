// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Bridge Conversation Context
// Per-channel rolling conversation buffers for messaging bridges
// Gives bridges multi-turn memory so users can have real conversations

import Foundation

/// Thread-safe per-channel conversation buffer for messaging bridges.
/// Each channel (phone number, chat ID, thread TS, etc.) gets a rolling window
/// of recent messages that are passed to the LLM for multi-turn context.
/// When the window overflows, old messages are summarized via local LLM
/// so context is preserved across trims.
actor BridgeConversationContext {
    static let shared = BridgeConversationContext()

    /// A single message in a conversation buffer
    private struct BufferedMessage {
        let role: String       // "user" or "assistant"
        let content: String
        let timestamp: Date
    }

    /// Per-channel conversation buffers. Key = channel identifier.
    private var channels: [String: [BufferedMessage]] = [:]

    /// Running conversation summaries per channel (preserved across window trims)
    private var channelSummaries: [String: String] = [:]

    /// Last activity time per channel (for session gap detection)
    private var lastActivityTime: [String: Date] = [:]

    /// Channels currently resuming after idle gap
    private var resumingChannels: Set<String> = []

    /// Maximum messages per channel (rolling window)
    private let maxMessagesPerChannel = 20

    /// Auto-evict channels idle longer than this (30 minutes)
    private let idleTimeout: TimeInterval = 1800

    /// Last time we ran eviction (avoid running on every call)
    private var lastEviction: Date = Date()

    /// URLSession for Ollama summarization calls
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Public API

    /// Add a message to the channel's conversation buffer.
    /// When buffer exceeds capacity, old messages are summarized before trimming.
    func addMessage(channelKey: String, role: String, content: String) async {
        // Lazy eviction check (at most once per minute)
        if Date().timeIntervalSince(lastEviction) > 60 {
            evictIdleChannels()
        }

        // Track activity for session gap detection
        let now = Date()
        let wasIdle = lastActivityTime[channelKey].map { now.timeIntervalSince($0) > idleTimeout } ?? false
        lastActivityTime[channelKey] = now

        // Mark channel as resuming if user returns after idle gap
        if wasIdle && role == "user" {
            resumingChannels.insert(channelKey)
        }

        // Cap message size to prevent memory exhaustion (32KB max per message)
        let safeContent = String(content.prefix(32768))

        var buffer = channels[channelKey] ?? []
        buffer.append(BufferedMessage(role: role, content: safeContent, timestamp: Date()))

        // Summarize before trimming if over capacity
        if buffer.count > maxMessagesPerChannel {
            let oldMessages = Array(buffer.prefix(10))
            buffer = Array(buffer.suffix(maxMessagesPerChannel - 10))

            // Fire-and-forget summarization (don't block the message flow)
            let channelKeyCapture = channelKey
            let messagesToSummarize = oldMessages
            Task {
                await self.summarizeAndStore(channelKey: channelKeyCapture, messages: messagesToSummarize)
            }
        }

        channels[channelKey] = buffer
    }

    /// Get the conversation history for a channel in OpenAI messages format.
    /// Returns array of `["role": "user"/"assistant"/"system", "content": "..."]` dicts.
    /// Prepends conversation summary if available.
    func getHistory(channelKey: String) -> [[String: String]] {
        guard let buffer = channels[channelKey] else { return [] }

        // Filter out messages older than idle timeout
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        let recentMessages = buffer
            .filter { $0.timestamp > cutoff }
            .map { ["role": $0.role, "content": $0.content] }

        var result: [[String: String]] = []

        // Prepend conversation summary if we have one
        if let summary = channelSummaries[channelKey], !summary.isEmpty {
            let isResuming = resumingChannels.contains(channelKey)
            let prefix = isResuming
                ? "[Context: This conversation is resuming after a break. Previous context: \(summary)]"
                : "[Previous conversation context: \(summary)]"
            result.append(["role": "system", "content": prefix])
        }

        result.append(contentsOf: recentMessages)

        // Clear resuming flag after first history fetch
        resumingChannels.remove(channelKey)

        return result
    }

    /// Clear a specific channel's conversation buffer.
    func clearChannel(channelKey: String) {
        channels.removeValue(forKey: channelKey)
        channelSummaries.removeValue(forKey: channelKey)
        lastActivityTime.removeValue(forKey: channelKey)
        resumingChannels.remove(channelKey)
    }

    /// Clear all conversation buffers.
    func clearAll() {
        channels.removeAll()
        channelSummaries.removeAll()
        lastActivityTime.removeAll()
        resumingChannels.removeAll()
    }

    /// Number of active channels (for diagnostics).
    var activeChannelCount: Int {
        channels.count
    }

    // MARK: - Eviction

    /// Remove channels that haven't had activity within the idle timeout.
    /// Archives summaries to long-term memory (LoA) before evicting.
    private func evictIdleChannels() {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        var keysToRemove: [String] = []

        for (key, messages) in channels {
            guard let last = messages.last else {
                keysToRemove.append(key)
                continue
            }
            if last.timestamp <= cutoff {
                keysToRemove.append(key)
                // Archive summary to long-term memory if available
                if let summary = channelSummaries[key] {
                    let archiveKey = key
                    let archiveSummary = summary
                    Task {
                        await MemoryIndex.shared.add(
                            text: "Bridge conversation (\(archiveKey)): \(archiveSummary)",
                            category: "episode",
                            source: "bridge-summary",
                            importance: 0.5
                        )
                    }
                }
            }
        }

        for key in keysToRemove {
            channels.removeValue(forKey: key)
            channelSummaries.removeValue(forKey: key)
            lastActivityTime.removeValue(forKey: key)
            resumingChannels.remove(key)
        }
        lastEviction = Date()
    }

    // MARK: - Summarization

    /// Summarize old messages and store as a running context summary.
    /// Called when the message buffer overflows — sends the oldest messages
    /// to a local LLM for condensation.
    private func summarizeAndStore(channelKey: String, messages: [BufferedMessage]) async {
        let conversation = messages.map { msg in
            "\(msg.role == "user" ? "User" : "Assistant"): \(String(msg.content.prefix(500)))"
        }.joined(separator: "\n")

        let prompt = """
        Summarize this conversation in 2-3 concise sentences. Focus on key topics discussed, decisions made, and important context:

        \(conversation.prefix(3000))

        Return ONLY the summary, nothing else.
        """

        guard let url = URL(string: OllamaManager.baseURL + "/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "llama3.2:3b",
            "prompt": prompt,
            "stream": false
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            TorboLog.error("Failed to serialize summarization request: \(error)", subsystem: "BridgeContext")
            return
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                TorboLog.warn("Failed to parse summarization response", subsystem: "BridgeContext")
                return
            }

            let summary = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return }

            // Merge with existing summary if there is one
            if let existing = channelSummaries[channelKey], !existing.isEmpty {
                channelSummaries[channelKey] = "\(existing) Then: \(summary)"
                // Cap total summary length
                if let current = channelSummaries[channelKey], current.count > 2000 {
                    channelSummaries[channelKey] = String(current.suffix(2000))
                }
            } else {
                channelSummaries[channelKey] = summary
            }

            TorboLog.info("Summarized \(messages.count) messages for \(channelKey)", subsystem: "BridgeContext")
        } catch {
            TorboLog.error("Summarization failed: \(error.localizedDescription)", subsystem: "BridgeContext")
        }
    }
}
