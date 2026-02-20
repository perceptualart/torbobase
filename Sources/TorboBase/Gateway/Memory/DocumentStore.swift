// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Document Store (RAG)
// DocumentStore.swift — Ingests, chunks, embeds, and retrieves documents
// Uses the same embedding model as MemoryIndex (nomic-embed-text via Ollama)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Document Store

/// Persistent document store for RAG (Retrieval-Augmented Generation).
/// Ingests files (PDF, text, markdown, code), chunks them, embeds with
/// nomic-embed-text, stores in SQLite, retrieves by cosine similarity.
actor DocumentStore {
    static let shared = DocumentStore()

    private var db: OpaquePointer?
    private let dbPath: String
    private let embeddingModel = "nomic-embed-text"
    private let embeddingDim = 768

    // In-memory cache for fast search
    private var chunks: [DocChunk] = []
    private var documents: [DocMeta] = []
    private var isReady = false

    struct DocMeta {
        let id: Int64
        let path: String
        let name: String
        let fileType: String     // "pdf", "txt", "md", "swift", etc.
        let chunkCount: Int
        let ingestedAt: Date
    }

    struct DocChunk {
        let id: Int64
        let docID: Int64
        let text: String
        let chunkIndex: Int
        let embedding: [Float]
    }

    struct SearchResult {
        let text: String
        let documentName: String
        let documentPath: String
        let chunkIndex: Int
        let score: Float
    }

    init() {
        let appSupport = PlatformPaths.appSupportDir
        let dir = appSupport.appendingPathComponent("TorboBase/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("documents.db").path
    }

    // MARK: - Lifecycle

    func initialize() async {
        guard !isReady else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open database: \(dbPath)", subsystem: "DocStore")
            return
        }

        // WAL mode
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)

        // Create tables
        let createDocs = """
        CREATE TABLE IF NOT EXISTS documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            file_type TEXT NOT NULL,
            chunk_count INTEGER DEFAULT 0,
            ingested_at TEXT NOT NULL
        )
        """
        let createChunks = """
        CREATE TABLE IF NOT EXISTS document_chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id INTEGER NOT NULL,
            text TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            embedding BLOB,
            FOREIGN KEY (doc_id) REFERENCES documents(id) ON DELETE CASCADE
        )
        """
        sqlite3_exec(db, createDocs, nil, nil, nil)
        sqlite3_exec(db, createChunks, nil, nil, nil)

        // Load into memory
        await loadIntoMemory()
        isReady = true
        TorboLog.info("Ready: \(documents.count) document(s), \(chunks.count) chunk(s)", subsystem: "DocStore")
    }

    // MARK: - Ingestion

    /// Ingest a file or folder path
    func ingest(path: String) async -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir) else {
            return "File not found: \(path)"
        }

        if isDir.boolValue {
            return await ingestFolder(expandedPath)
        } else {
            return await ingestFile(expandedPath)
        }
    }

    /// Ingest a single file
    private func ingestFile(_ path: String) async -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()

        // Check if already ingested
        if documents.contains(where: { $0.path == path }) {
            // Re-ingest: remove old and re-add
            await removeDocument(path: path)
        }

        // Read content
        let content: String
        switch ext {
        case "pdf":
            content = extractPDF(path: path)
        case "txt", "md", "markdown", "text", "log", "csv", "json", "xml", "html":
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        case "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "kt", "rb", "sh", "zsh", "bash":
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        default:
            // Try reading as text
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }

        guard !content.isEmpty else {
            return "Could not read content from: \(name)"
        }

        // Chunk the content
        let textChunks = chunkText(content, maxTokens: 500)

        // Insert document record
        let docID = insertDocument(path: path, name: name, fileType: ext, chunkCount: textChunks.count)
        guard docID > 0 else {
            return "Failed to create document record for: \(name)"
        }

        // Embed and insert chunks
        var embedded = 0
        for (i, chunk) in textChunks.enumerated() {
            let embedding = await embed(chunk)
            insertChunk(docID: docID, text: chunk, index: i, embedding: embedding)
            if embedding != nil { embedded += 1 }
        }

        await loadIntoMemory()
        TorboLog.info("Ingested '\(name)': \(textChunks.count) chunks, \(embedded) embedded", subsystem: "DocStore")
        return "Ingested '\(name)': \(textChunks.count) chunks"
    }

    /// Ingest a folder recursively
    private func ingestFolder(_ path: String) async -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else {
            return "Cannot read folder: \(path)"
        }

        let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", "__pycache__", ".venv", "venv"]
        let allowedExts: Set<String> = ["txt", "md", "markdown", "pdf", "swift", "py", "js", "ts", "go", "rs",
                                         "c", "cpp", "h", "java", "kt", "rb", "sh", "json", "xml", "html",
                                         "css", "yaml", "yml", "toml", "csv", "log"]

        var files: [String] = []
        while let item = enumerator.nextObject() as? String {
            // Skip hidden and excluded directories
            let components = item.components(separatedBy: "/")
            if components.contains(where: { skipDirs.contains($0) || $0.hasPrefix(".") }) {
                continue
            }
            let ext = (item as NSString).pathExtension.lowercased()
            if allowedExts.contains(ext) {
                files.append((path as NSString).appendingPathComponent(item))
            }
        }

        guard !files.isEmpty else {
            return "No supported files found in: \(path)"
        }

        var results: [String] = []
        for file in files.prefix(100) { // Cap at 100 files
            let result = await ingestFile(file)
            results.append(result)
        }

        return "Ingested \(results.count) file(s) from \((path as NSString).lastPathComponent)"
    }

    // MARK: - Search

    /// Search documents by semantic similarity
    func search(query: String, topK: Int = 5, minScore: Float = 0.3) async -> [SearchResult] {
        guard let queryEmbedding = await embed(query) else { return [] }

        var scored: [(chunk: DocChunk, score: Float)] = []
        for chunk in chunks {
            guard !chunk.embedding.isEmpty else { continue }
            let score = cosineSimilarity(queryEmbedding, chunk.embedding)
            if score >= minScore {
                scored.append((chunk, score))
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(topK).map { item in
            let doc = documents.first(where: { $0.id == item.chunk.docID })
            return SearchResult(
                text: item.chunk.text,
                documentName: doc?.name ?? "unknown",
                documentPath: doc?.path ?? "",
                chunkIndex: item.chunk.chunkIndex,
                score: item.score
            )
        }
    }

    // MARK: - Management

    /// List all ingested documents
    func listDocuments() -> [[String: Any]] {
        documents.map { doc in
            [
                "id": doc.id,
                "name": doc.name,
                "path": doc.path,
                "type": doc.fileType,
                "chunks": doc.chunkCount,
                "ingested_at": ISO8601DateFormatter().string(from: doc.ingestedAt)
            ] as [String: Any]
        }
    }

    /// Remove a document and its chunks
    func removeDocument(path: String) async {
        guard let doc = documents.first(where: { $0.path == path }) else { return }
        await removeDocument(id: doc.id)
        TorboLog.info("Removed document: \(doc.name)", subsystem: "DocStore")
    }

    func removeDocument(id: Int64) async {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM document_chunks WHERE doc_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        stmt = nil
        if sqlite3_prepare_v2(db, "DELETE FROM documents WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        await loadIntoMemory()
    }

    /// Get stats
    func stats() -> [String: Any] {
        [
            "documents": documents.count,
            "chunks": chunks.count,
            "database": dbPath
        ]
    }

    // MARK: - Text Chunking

    /// Split text into chunks of approximately maxTokens tokens (~4 chars per token)
    private func chunkText(_ text: String, maxTokens: Int = 500) -> [String] {
        let maxChars = maxTokens * 4
        let overlap = 100  // Character overlap between chunks

        guard text.count > maxChars else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let endOffset = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex

            // Try to break at a paragraph or sentence boundary
            var end = endOffset
            if end < text.endIndex {
                let searchRange = text.index(end, offsetBy: -200, limitedBy: start) ?? start
                let window = text[searchRange..<end]
                if let para = window.range(of: "\n\n", options: .backwards) {
                    end = para.upperBound
                } else if let newline = window.range(of: "\n", options: .backwards) {
                    end = newline.upperBound
                } else if let period = window.range(of: ". ", options: .backwards) {
                    end = period.upperBound
                }
            }

            let chunk = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }

            // Move start with overlap
            if end < text.endIndex {
                start = text.index(end, offsetBy: -overlap, limitedBy: text.startIndex) ?? text.startIndex
            } else {
                break
            }
        }

        return chunks
    }

    // MARK: - PDF Extraction

    private func extractPDF(path: String) -> String {
        // Shell out to python3 (PyMuPDF/pdfminer) or /usr/bin/strings — cross-platform
        guard let pdfDoc = loadPDF(path: path) else { return "" }
        return pdfDoc
    }

    private func loadPDF(path: String) -> String? {
        // Shell out to pdftotext or use strings extraction.
        // Path is passed as sys.argv[1] — never interpolated into code.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", """
        import sys
        path = sys.argv[1]
        try:
            import fitz  # PyMuPDF
            doc = fitz.open(path)
            text = '\\n'.join(page.get_text() for page in doc)
            print(text)
        except ImportError:
            try:
                from pdfminer.high_level import extract_text
                print(extract_text(path))
            except ImportError:
                import subprocess
                result = subprocess.run(['/usr/bin/strings', path], capture_output=True, text=True)
                print(result.stdout)
        """, path]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            // Final fallback: just use strings command
            let stringsProc = Process()
            stringsProc.executableURL = URL(fileURLWithPath: "/usr/bin/strings")
            stringsProc.arguments = [path]
            let stringsPipe = Pipe()
            stringsProc.standardOutput = stringsPipe
            do {
                try stringsProc.run()
                stringsProc.waitUntilExit()
            } catch {
                TorboLog.debug("Process failed to start: \(error)", subsystem: "Documents")
                return nil
            }
            let data = stringsPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }
    }

    // MARK: - Embeddings

    private func embed(_ text: String) async -> [Float]? {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/embed") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        let body: [String: Any] = [
            "model": embeddingModel,
            "input": String(text.prefix(2048))
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let embeddings = json["embeddings"] as? [[Double]],
                  let first = embeddings.first else { return nil }
            return first.map { Float($0) }
        } catch {
            return nil
        }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - SQLite Operations

    private func insertDocument(path: String, name: String, fileType: String, chunkCount: Int) -> Int64 {
        let sql = "INSERT INTO documents (path, name, file_type, chunk_count, ingested_at) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        let ts = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (fileType as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, Int32(chunkCount))
        sqlite3_bind_text(stmt, 5, (ts as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_DONE {
            return sqlite3_last_insert_rowid(db)
        }
        return 0
    }

    private func insertChunk(docID: Int64, text: String, index: Int, embedding: [Float]?) {
        let sql = "INSERT INTO document_chunks (doc_id, text, chunk_index, embedding) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, docID)
        sqlite3_bind_text(stmt, 2, (text as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(index))

        if let emb = embedding {
            let embData = Data(bytes: emb, count: emb.count * MemoryLayout<Float>.size)
            _ = embData.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(embData.count), nil)
            }
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        sqlite3_step(stmt)
    }

    private func loadIntoMemory() async {
        documents = []
        chunks = []

        // Load documents
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, path, name, file_type, chunk_count, ingested_at FROM documents", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let path = String(cString: sqlite3_column_text(stmt, 1))
                let name = String(cString: sqlite3_column_text(stmt, 2))
                let fileType = String(cString: sqlite3_column_text(stmt, 3))
                let chunkCount = Int(sqlite3_column_int(stmt, 4))
                let ts = String(cString: sqlite3_column_text(stmt, 5))
                let date = ISO8601DateFormatter().date(from: ts) ?? Date()
                documents.append(DocMeta(id: id, path: path, name: name, fileType: fileType, chunkCount: chunkCount, ingestedAt: date))
            }
        }
        sqlite3_finalize(stmt)

        // Load chunks
        stmt = nil
        if sqlite3_prepare_v2(db, "SELECT id, doc_id, text, chunk_index, embedding FROM document_chunks", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let docID = sqlite3_column_int64(stmt, 1)
                let text = String(cString: sqlite3_column_text(stmt, 2))
                let chunkIndex = Int(sqlite3_column_int(stmt, 3))

                var embedding: [Float] = []
                if let blob = sqlite3_column_blob(stmt, 4) {
                    let blobSize = Int(sqlite3_column_bytes(stmt, 4))
                    let floatCount = blobSize / MemoryLayout<Float>.size
                    let buffer = blob.assumingMemoryBound(to: Float.self)
                    embedding = Array(UnsafeBufferPointer(start: buffer, count: floatCount))
                }

                chunks.append(DocChunk(id: id, docID: docID, text: text, chunkIndex: chunkIndex, embedding: embedding))
            }
        }
        sqlite3_finalize(stmt)
    }
}
