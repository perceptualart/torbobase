// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — BM25 Index
// Full BM25 (Best Matching 25) implementation for keyword-based memory search.
// Used alongside vector search in MemoryIndex for Reciprocal Rank Fusion (RRF).

import Foundation

/// In-memory BM25 inverted index for fast keyword scoring.
/// BM25 is the industry-standard ranking function for keyword search — it considers
/// term frequency, inverse document frequency, and document length normalization.
struct BM25Index {

    /// BM25 tuning parameters
    private let k1: Float = 1.2   // Term frequency saturation
    private let b: Float = 0.75   // Document length normalization

    /// Inverted index: term → [(entryID, term frequency in that entry)]
    private var invertedIndex: [String: [(id: Int64, tf: Int)]] = [:]

    /// Document lengths (in tokens) per entry
    private var docLengths: [Int64: Int] = [:]

    /// Average document length across all entries
    private var avgDocLength: Float = 0

    /// Total number of documents
    private var totalDocs: Int = 0

    /// IDF cache: term → IDF value
    private var idfCache: [String: Float] = [:]

    /// Common English stopwords to skip during tokenization
    private static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "need", "dare", "ought",
        "used", "to", "of", "in", "for", "on", "with", "at", "by", "from",
        "as", "into", "through", "during", "before", "after", "above", "below",
        "between", "out", "off", "over", "under", "again", "further", "then",
        "once", "here", "there", "when", "where", "why", "how", "all", "each",
        "every", "both", "few", "more", "most", "other", "some", "such", "no",
        "nor", "not", "only", "own", "same", "so", "than", "too", "very",
        "just", "because", "but", "and", "or", "if", "while", "about", "up",
        "it", "its", "i", "me", "my", "we", "our", "you", "your", "he", "him",
        "his", "she", "her", "they", "them", "their", "this", "that", "these",
        "those", "what", "which", "who", "whom"
    ]

    // MARK: - Building

    /// Build the inverted index from a set of memory entries.
    /// Call this on startup and after significant changes (debounced).
    mutating func build(entries: [(id: Int64, text: String)]) {
        invertedIndex.removeAll()
        docLengths.removeAll()
        idfCache.removeAll()

        totalDocs = entries.count
        var totalLength = 0

        for entry in entries {
            let tokens = tokenize(entry.text)
            docLengths[entry.id] = tokens.count
            totalLength += tokens.count

            // Count term frequencies for this document
            var termFreqs: [String: Int] = [:]
            for token in tokens {
                termFreqs[token, default: 0] += 1
            }

            // Add to inverted index
            for (term, freq) in termFreqs {
                invertedIndex[term, default: []].append((id: entry.id, tf: freq))
            }
        }

        avgDocLength = totalDocs > 0 ? Float(totalLength) / Float(totalDocs) : 1.0

        // Pre-compute IDF for all terms
        for (term, postings) in invertedIndex {
            let df = postings.count  // Number of documents containing this term
            // IDF formula: log((N - df + 0.5) / (df + 0.5) + 1)
            idfCache[term] = log((Float(totalDocs) - Float(df) + 0.5) / (Float(df) + 0.5) + 1.0)
        }
    }

    /// Incrementally add a single entry to the index.
    mutating func addEntry(id: Int64, text: String) {
        let tokens = tokenize(text)
        docLengths[id] = tokens.count
        totalDocs += 1

        // Update average document length
        let totalLength = docLengths.values.reduce(0, +)
        avgDocLength = totalDocs > 0 ? Float(totalLength) / Float(totalDocs) : 1.0

        // Count term frequencies
        var termFreqs: [String: Int] = [:]
        for token in tokens {
            termFreqs[token, default: 0] += 1
        }

        // Add to inverted index and recompute affected IDF values
        for (term, freq) in termFreqs {
            invertedIndex[term, default: []].append((id: id, tf: freq))
            let df = invertedIndex[term]?.count ?? 1
            idfCache[term] = log((Float(totalDocs) - Float(df) + 0.5) / (Float(df) + 0.5) + 1.0)
        }
    }

    /// Remove an entry from the index.
    mutating func removeEntry(id: Int64) {
        docLengths.removeValue(forKey: id)
        totalDocs = max(0, totalDocs - 1)

        // Remove from inverted index
        for (term, postings) in invertedIndex {
            let filtered = postings.filter { $0.id != id }
            if filtered.isEmpty {
                invertedIndex.removeValue(forKey: term)
                idfCache.removeValue(forKey: term)
            } else {
                invertedIndex[term] = filtered
                let df = filtered.count
                idfCache[term] = log((Float(totalDocs) - Float(df) + 0.5) / (Float(df) + 0.5) + 1.0)
            }
        }

        // Update average document length
        let totalLength = docLengths.values.reduce(0, +)
        avgDocLength = totalDocs > 0 ? Float(totalLength) / Float(totalDocs) : 1.0
    }

    // MARK: - Scoring

    /// Score a single document against a query. Returns 0 if document doesn't match.
    func score(query: String, entryID: Int64) -> Float {
        let queryTokens = tokenize(query)
        guard let dl = docLengths[entryID] else { return 0 }

        var total: Float = 0

        for term in queryTokens {
            guard let idf = idfCache[term],
                  let postings = invertedIndex[term],
                  let posting = postings.first(where: { $0.id == entryID }) else { continue }

            let tf = Float(posting.tf)
            let dlNorm = Float(dl)

            // BM25 score for this term:
            // IDF * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl / avgdl))
            let numerator = tf * (k1 + 1)
            let denominator = tf + k1 * (1 - b + b * dlNorm / avgDocLength)
            total += idf * numerator / denominator
        }

        return total
    }

    /// Search for the top-K entries matching a query, ranked by BM25 score.
    /// Returns entry IDs and scores, sorted by score descending.
    func search(query: String, topK: Int = 20) -> [(id: Int64, score: Float)] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        // Collect candidate documents: any doc containing at least one query term
        var candidates: Set<Int64> = []
        for term in queryTokens {
            if let postings = invertedIndex[term] {
                for posting in postings {
                    candidates.insert(posting.id)
                }
            }
        }

        // Score each candidate
        var results: [(id: Int64, score: Float)] = []
        for candidateID in candidates {
            guard let dl = docLengths[candidateID] else { continue }
            var total: Float = 0

            for term in queryTokens {
                guard let idf = idfCache[term],
                      let postings = invertedIndex[term],
                      let posting = postings.first(where: { $0.id == candidateID }) else { continue }

                let tf = Float(posting.tf)
                let dlNorm = Float(dl)
                let numerator = tf * (k1 + 1)
                let denominator = tf + k1 * (1 - b + b * dlNorm / avgDocLength)
                total += idf * numerator / denominator
            }

            if total > 0 {
                results.append((id: candidateID, score: total))
            }
        }

        // Sort by score descending, take top K
        results.sort { $0.score > $1.score }
        return Array(results.prefix(topK))
    }

    // MARK: - Tokenization

    /// Tokenize text into lowercase terms with stopword removal.
    func tokenize(_ text: String) -> [String] {
        // Split on non-alphanumeric characters
        let lower = text.lowercased()
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 && !Self.stopwords.contains($0) }
        return tokens
    }

    /// Number of unique terms in the index.
    var termCount: Int { invertedIndex.count }

    /// Number of documents in the index.
    var documentCount: Int { totalDocs }
}
