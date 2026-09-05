import Foundation
import SQLite3
import WarrenTransport

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer?
    init(_ pointer: OpaquePointer?) {
        self.pointer = pointer
    }
    deinit {
        if let pointer {
            sqlite3_close(pointer)
        }
    }
}

/// A durable, thread-safe SQLite event store for iOS that acts as a local replica
/// of the Headless Agent Event Store. Provides instantaneous cold start (<10ms)
/// and contiguous sequence gap detection.
public actor IOSAgentEventStore {
    public static let shared = IOSAgentEventStore()

    private let handle: SQLiteHandle?
    private var db: OpaquePointer? { handle?.pointer }
    private let databasePath: String
    private let maxEventsPerSession: Int = 5000
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(databasePath: String? = nil) {
        let resolvedPath: String
        if let databasePath {
            resolvedPath = databasePath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let warrenDir = appSupport.appendingPathComponent("Warren", isDirectory: true)
            try? FileManager.default.createDirectory(at: warrenDir, withIntermediateDirectories: true)
            resolvedPath = warrenDir.appendingPathComponent("warren-agent.sqlite3").path
        }
        self.databasePath = resolvedPath
        let openedPointer = IOSAgentEventStore.openDatabase(at: resolvedPath)
        self.handle = SQLiteHandle(openedPointer)
    }

    private static func openDatabase(at path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            return nil
        }

        sqlite3_exec(handle, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA busy_timeout = 5000;", nil, nil, nil)

        let schema = """
        CREATE TABLE IF NOT EXISTS ios_agent_events (
            session_id    TEXT NOT NULL,
            epoch         INTEGER NOT NULL,
            sequence      INTEGER NOT NULL,
            turn          INTEGER,
            id            TEXT,
            type          TEXT NOT NULL,
            role          TEXT,
            content       TEXT,
            content_delta INTEGER DEFAULT 0,
            tool_name     TEXT,
            tool_status   TEXT,
            call_id       TEXT,
            raw_json      TEXT NOT NULL,
            created_at    REAL NOT NULL,
            PRIMARY KEY (session_id, epoch, sequence)
        );

        CREATE INDEX IF NOT EXISTS idx_ios_agent_seq 
        ON ios_agent_events(session_id, epoch, sequence ASC);

        CREATE INDEX IF NOT EXISTS idx_ios_agent_recent
        ON ios_agent_events(session_id, epoch, sequence DESC);

        CREATE TABLE IF NOT EXISTS ios_agent_sync_state (
            session_id      TEXT NOT NULL,
            epoch           INTEGER NOT NULL,
            max_sequence    INTEGER NOT NULL DEFAULT 0,
            has_more_before INTEGER NOT NULL DEFAULT 1,
            updated_at      REAL NOT NULL,
            PRIMARY KEY (session_id)
        );
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
        return handle
    }

    // MARK: - Save

    public func saveEvents(
        _ events: [WarrenRemoteAgentEvent],
        sessionID: String,
        epoch: UInt64
    ) throws {
        guard let db, !events.isEmpty else { return }

        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT;", nil, nil, nil) }

        let insertSQL = """
        INSERT OR REPLACE INTO ios_agent_events (
            session_id, epoch, sequence, turn, id, type, role,
            content, content_delta, tool_name, tool_status, call_id,
            raw_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(insertStmt) }

        var maxSeq: UInt64 = 0
        let now = Date().timeIntervalSince1970

        for rawEvent in events {
            let event = rawEvent.clipped(limit: 4096)
            if event.sequence > maxSeq {
                maxSeq = event.sequence
            }

            guard let jsonData = try? jsonEncoder.encode(event),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                continue
            }

            sqlite3_reset(insertStmt)
            sqlite3_bind_text(insertStmt, 1, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(insertStmt, 2, Int64(epoch))
            sqlite3_bind_int64(insertStmt, 3, Int64(event.sequence))
            if let turn = event.turn {
                sqlite3_bind_int64(insertStmt, 4, Int64(turn))
            } else {
                sqlite3_bind_null(insertStmt, 4)
            }
            if !event.id.isEmpty {
                sqlite3_bind_text(insertStmt, 5, (event.id as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 5)
            }
            sqlite3_bind_text(insertStmt, 6, (event.type as NSString).utf8String, -1, nil)
            if let role = event.role {
                sqlite3_bind_text(insertStmt, 7, (role as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 7)
            }
            if let content = event.content {
                sqlite3_bind_text(insertStmt, 8, (content as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 8)
            }
            sqlite3_bind_int(insertStmt, 9, event.contentDelta ? 1 : 0)
            if let toolName = event.toolName {
                sqlite3_bind_text(insertStmt, 10, (toolName as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 10)
            }
            if let toolStatus = event.toolStatus {
                sqlite3_bind_text(insertStmt, 11, (toolStatus as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 11)
            }
            if let callID = event.callID {
                sqlite3_bind_text(insertStmt, 12, (callID as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insertStmt, 12)
            }
            sqlite3_bind_text(insertStmt, 13, (jsonString as NSString).utf8String, -1, nil)
            sqlite3_bind_double(insertStmt, 14, now)

            sqlite3_step(insertStmt)
        }

        // Update sync state
        let updateSyncSQL = """
        INSERT INTO ios_agent_sync_state (session_id, epoch, max_sequence, has_more_before, updated_at)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(session_id) DO UPDATE SET
            epoch = excluded.epoch,
            max_sequence = CASE
                WHEN ios_agent_sync_state.epoch = excluded.epoch
                THEN MAX(ios_agent_sync_state.max_sequence, excluded.max_sequence)
                ELSE excluded.max_sequence
            END,
            has_more_before = CASE
                WHEN ios_agent_sync_state.epoch = excluded.epoch
                THEN ios_agent_sync_state.has_more_before
                ELSE 1
            END,
            updated_at = excluded.updated_at;
        """
        var syncStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSyncSQL, -1, &syncStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(syncStmt, 1, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(syncStmt, 2, Int64(epoch))
            sqlite3_bind_int64(syncStmt, 3, Int64(maxSeq))
            sqlite3_bind_double(syncStmt, 4, now)
            sqlite3_step(syncStmt)
            sqlite3_finalize(syncStmt)
        }

        // Pruning if exceeding maxEventsPerSession. The COUNT probe keeps
        // every streaming delta from paying for the NOT IN subquery when the
        // transcript is still small.
        let countSQL = "SELECT COUNT(*) FROM ios_agent_events WHERE session_id = ? AND epoch = ?;"
        var countStmt: OpaquePointer?
        var storedCount = 0
        if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(countStmt, 1, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(countStmt, 2, Int64(epoch))
            if sqlite3_step(countStmt) == SQLITE_ROW {
                storedCount = Int(sqlite3_column_int64(countStmt, 0))
            }
            sqlite3_finalize(countStmt)
        }
        guard storedCount > maxEventsPerSession else { return }
        let pruneSQL = """
        DELETE FROM ios_agent_events
        WHERE session_id = ? AND epoch = ? AND sequence NOT IN (
            SELECT sequence FROM ios_agent_events
            WHERE session_id = ? AND epoch = ?
            ORDER BY sequence DESC
            LIMIT ?
        );
        """
        var pruneStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, pruneSQL, -1, &pruneStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(pruneStmt, 1, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(pruneStmt, 2, Int64(epoch))
            sqlite3_bind_text(pruneStmt, 3, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(pruneStmt, 4, Int64(epoch))
            sqlite3_bind_int(pruneStmt, 5, Int32(maxEventsPerSession))
            sqlite3_step(pruneStmt)
            sqlite3_finalize(pruneStmt)
        }
    }

    // MARK: - Query

    public func loadRecentEvents(
        sessionID: String,
        epoch: UInt64? = nil,
        limit: Int = 100
    ) -> [WarrenRemoteAgentEvent] {
        guard let db else { return [] }

        var querySQL = """
        SELECT raw_json FROM (
            SELECT sequence, raw_json FROM ios_agent_events
            WHERE session_id = ?
        """
        if epoch != nil {
            querySQL += " AND epoch = ?"
        }
        querySQL += """
            ORDER BY sequence DESC
            LIMIT ?
        )
        ORDER BY sequence ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        sqlite3_bind_text(stmt, bindIndex, (sessionID as NSString).utf8String, -1, nil)
        bindIndex += 1
        if let epoch {
            sqlite3_bind_int64(stmt, bindIndex, Int64(epoch))
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit))

        var results: [WarrenRemoteAgentEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                let jsonString = String(cString: cString)
                if let data = jsonString.data(using: .utf8),
                   let event = try? jsonDecoder.decode(WarrenRemoteAgentEvent.self, from: data) {
                    results.append(event)
                }
            }
        }
        return results
    }

    public func loadEvents(
        sessionID: String,
        epoch: UInt64? = nil,
        since: UInt64? = nil,
        before: UInt64? = nil,
        limit: Int = 100
    ) -> [WarrenRemoteAgentEvent] {
        guard let db else { return [] }

        var sql = "SELECT raw_json FROM ios_agent_events WHERE session_id = ?"
        var bindEpoch: UInt64?
        var bindSince: UInt64?
        var bindBefore: UInt64?
        let bindLimit = limit
        if epoch != nil { sql += " AND epoch = ?" ; bindEpoch = epoch }
        if since != nil { sql += " AND sequence >= ?"; bindSince = since }
        if before != nil { sql += " AND sequence < ?"; bindBefore = before }
        sql += " ORDER BY sequence ASC LIMIT ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        sqlite3_bind_text(stmt, bindIndex, (sessionID as NSString).utf8String, -1, nil)
        bindIndex += 1
        if let bindEpoch {
            sqlite3_bind_int64(stmt, bindIndex, Int64(bindEpoch))
            bindIndex += 1
        }
        if let bindSince {
            sqlite3_bind_int64(stmt, bindIndex, Int64(bindSince))
            bindIndex += 1
        }
        if let bindBefore {
            sqlite3_bind_int64(stmt, bindIndex, Int64(bindBefore))
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(bindLimit))

        var results: [WarrenRemoteAgentEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                let jsonString = String(cString: cString)
                if let data = jsonString.data(using: .utf8),
                   let event = try? jsonDecoder.decode(WarrenRemoteAgentEvent.self, from: data) {
                    results.append(event)
                }
            }
        }
        return results
    }

    public func maxSequence(sessionID: String, epoch: UInt64) -> UInt64 {
        guard let db else { return 0 }

        let querySQL = "SELECT MAX(sequence) FROM ios_agent_events WHERE session_id = ? AND epoch = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, Int64(epoch))

        if sqlite3_step(stmt) == SQLITE_ROW {
            let val = sqlite3_column_int64(stmt, 0)
            return val > 0 ? UInt64(val) : 0
        }
        return 0
    }

    public func syncState(sessionID: String) -> (epoch: UInt64, maxSequence: UInt64, hasMoreBefore: Bool)? {
        guard let db else { return nil }

        let querySQL = "SELECT epoch, max_sequence, has_more_before FROM ios_agent_sync_state WHERE session_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let epoch = UInt64(sqlite3_column_int64(stmt, 0))
            let maxSeq = UInt64(sqlite3_column_int64(stmt, 1))
            let hasMore = sqlite3_column_int(stmt, 2) != 0
            return (epoch, maxSeq, hasMore)
        }
        return nil
    }

    public func clearSession(sessionID: String) {
        guard let db else { return }

        let deleteEventsSQL = "DELETE FROM ios_agent_events WHERE session_id = ?;"
        var stmt1: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteEventsSQL, -1, &stmt1, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt1, 1, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_step(stmt1)
            sqlite3_finalize(stmt1)
        }

        let deleteStateSQL = "DELETE FROM ios_agent_sync_state WHERE session_id = ?;"
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteStateSQL, -1, &stmt2, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt2, 1, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_step(stmt2)
            sqlite3_finalize(stmt2)
        }
    }

    /// Purges all events and sync states for sessions that no longer exist on the Host.
    /// Runs silently on the actor's background executor without blocking the main actor.
    public func purgeOrphanSessions(activeSessionIDs: Set<String>) {
        guard let db else { return }

        let querySQL = "SELECT DISTINCT session_id FROM ios_agent_sync_state UNION SELECT DISTINCT session_id FROM ios_agent_events;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK else { return }
        var storedIDs: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                storedIDs.append(String(cString: cStr))
            }
        }
        sqlite3_finalize(stmt)

        for sessionID in storedIDs where !activeSessionIDs.contains(sessionID) {
            clearSession(sessionID: sessionID)
        }
    }

    /// Purges all events and sync states for a specific list of session IDs.
    public func clearSessions(_ sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else { return }
        for sessionID in sessionIDs {
            clearSession(sessionID: sessionID)
        }
    }

    /// Clears all agent events and sync states across all sessions.
    public func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM ios_agent_events;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM ios_agent_sync_state;", nil, nil, nil)
    }
}
