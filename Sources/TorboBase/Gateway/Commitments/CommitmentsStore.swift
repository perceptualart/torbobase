// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Commitments Store
// SQLite-backed persistence for user commitments and accountability tracking.

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// A single tracked commitment.
struct Commitment: Sendable {
    let id: Int64
    let text: String
    let extractedAt: Date
    let dueDate: Date?
    let dueText: String?
    let status: Status
    let reminderCount: Int
    let lastReminded: Date?
    let resolvedAt: Date?
    let resolutionNote: String?

    enum Status: String, Sendable {
        case open
        case resolved
        case dismissed
        case failed
    }

    func toDict() -> [String: Any] {
        let fmt = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id": id,
            "text": text,
            "extracted_at": fmt.string(from: extractedAt),
            "status": status.rawValue,
            "reminder_count": reminderCount
        ]
        if let dd = dueDate { d["due_date"] = fmt.string(from: dd) }
        if let dt = dueText { d["due_text"] = dt }
        if let lr = lastReminded { d["last_reminded"] = fmt.string(from: lr) }
        if let ra = resolvedAt { d["resolved_at"] = fmt.string(from: ra) }
        if let rn = resolutionNote { d["resolution_note"] = rn }
        return d
    }
}

/// SQLite-backed actor for commitment persistence.
actor CommitmentsStore {
    static let shared = CommitmentsStore()

    private var db: OpaquePointer?
    private var isReady = false

    private var dbPath: String {
        PlatformPaths.dataDir + "/commitments/commitments.db"
    }

    // MARK: - Lifecycle

    func initialize() {
        guard !isReady else { return }

        let dir = PlatformPaths.dataDir + "/commitments"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        guard sqlite3_open(dbPath, &handle) == SQLITE_OK else {
            TorboLog.error("Failed to open commitments DB at \(dbPath)", subsystem: "Commitments")
            return
        }
        db = handle

        // WAL mode + NORMAL synchronous for performance
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)

        let createTable = """
        CREATE TABLE IF NOT EXISTS commitments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            extracted_at REAL NOT NULL,
            due_date REAL,
            due_text TEXT,
            status TEXT NOT NULL DEFAULT 'open',
            reminder_count INTEGER NOT NULL DEFAULT 0,
            last_reminded REAL,
            resolved_at REAL,
            resolution_note TEXT
        )
        """
        guard sqlite3_exec(db, createTable, nil, nil, nil) == SQLITE_OK else {
            TorboLog.error("Failed to create commitments table", subsystem: "Commitments")
            return
        }

        // Index for common queries
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_commitments_status ON commitments(status)", nil, nil, nil)

        isReady = true
        TorboLog.info("Initialized (\(dbPath))", subsystem: "Commitments")
    }

    // MARK: - CRUD

    @discardableResult
    func add(text: String, dueDate: Date? = nil, dueText: String? = nil) -> Int64? {
        guard let db else { return nil }

        let sql = "INSERT INTO commitments (text, extracted_at, due_date, due_text) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (text as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        if let dd = dueDate {
            sqlite3_bind_double(stmt, 3, dd.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let dt = dueText {
            sqlite3_bind_text(stmt, 4, (dt as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        let rowID = sqlite3_last_insert_rowid(db)
        TorboLog.info("Added commitment #\(rowID): \(text.prefix(60))", subsystem: "Commitments")
        return rowID
    }

    func updateStatus(id: Int64, status: Commitment.Status, note: String? = nil) {
        guard let db else { return }

        let sql: String
        if status == .resolved || status == .dismissed || status == .failed {
            sql = "UPDATE commitments SET status = ?, resolution_note = ?, resolved_at = ? WHERE id = ?"
        } else {
            sql = "UPDATE commitments SET status = ? WHERE id = ?"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (status.rawValue as NSString).utf8String, -1, nil)

        if status == .resolved || status == .dismissed || status == .failed {
            if let n = note {
                sqlite3_bind_text(stmt, 2, (n as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 4, id)
        } else {
            sqlite3_bind_int64(stmt, 2, id)
        }

        sqlite3_step(stmt)
    }

    func recordReminder(id: Int64) {
        guard let db else { return }

        let sql = "UPDATE commitments SET reminder_count = reminder_count + 1, last_reminded = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    // MARK: - Queries

    func allOpen() -> [Commitment] {
        query("SELECT * FROM commitments WHERE status = 'open' ORDER BY extracted_at DESC")
    }

    func overdue() -> [Commitment] {
        let now = Date().timeIntervalSince1970
        return query("SELECT * FROM commitments WHERE status = 'open' AND due_date IS NOT NULL AND due_date < \(now) ORDER BY due_date ASC")
    }

    func overdueNeedingReminder() -> [Commitment] {
        let now = Date().timeIntervalSince1970
        let dayAgo = now - 86400
        return query("""
            SELECT * FROM commitments
            WHERE status = 'open'
            AND due_date IS NOT NULL AND due_date < \(now)
            AND (last_reminded IS NULL OR last_reminded < \(dayAgo))
            ORDER BY due_date ASC
        """)
    }

    func get(id: Int64) -> Commitment? {
        let results = query("SELECT * FROM commitments WHERE id = \(id) LIMIT 1")
        return results.first
    }

    func countOpen() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM commitments WHERE status = 'open'", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func all(limit: Int = 100) -> [Commitment] {
        query("SELECT * FROM commitments ORDER BY extracted_at DESC LIMIT \(limit)")
    }

    func search(text: String) -> [Commitment] {
        guard let db else { return [] }
        let sql = "SELECT * FROM commitments WHERE text LIKE ? ORDER BY extracted_at DESC LIMIT 50"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(text)%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)

        var results: [Commitment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = parseRow(stmt) { results.append(c) }
        }
        return results
    }

    func stats() -> [String: Any] {
        guard let db else { return [:] }
        var result: [String: Any] = [:]

        // Count by status
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT status, COUNT(*) FROM commitments GROUP BY status", -1, &stmt, nil) == SQLITE_OK {
            var counts: [String: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let s = sqlite3_column_text(stmt, 0) {
                    counts[String(cString: s)] = Int(sqlite3_column_int(stmt, 1))
                }
            }
            result["by_status"] = counts
            sqlite3_finalize(stmt)
        }

        result["total_open"] = countOpen()
        result["total_overdue"] = overdue().count

        return result
    }

    // MARK: - Internal

    private func query(_ sql: String) -> [Commitment] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [Commitment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = parseRow(stmt) { results.append(c) }
        }
        return results
    }

    private func parseRow(_ stmt: OpaquePointer?) -> Commitment? {
        guard let stmt else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        guard let textPtr = sqlite3_column_text(stmt, 1) else { return nil }
        let text = String(cString: textPtr)
        let extractedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))

        let dueDate: Date? = sqlite3_column_type(stmt, 3) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)) : nil
        let dueText: String? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 4)) : nil

        let statusStr = sqlite3_column_type(stmt, 5) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 5)) : "open"
        let status = Commitment.Status(rawValue: statusStr) ?? .open

        let reminderCount = Int(sqlite3_column_int(stmt, 6))
        let lastReminded: Date? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)) : nil
        let resolvedAt: Date? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)) : nil
        let resolutionNote: String? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 9)) : nil

        return Commitment(
            id: id, text: text, extractedAt: extractedAt, dueDate: dueDate, dueText: dueText,
            status: status, reminderCount: reminderCount, lastReminded: lastReminded,
            resolvedAt: resolvedAt, resolutionNote: resolutionNote
        )
    }
}
