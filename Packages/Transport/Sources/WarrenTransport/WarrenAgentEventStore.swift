import Foundation
import SQLite3

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

public enum WarrenAgentEventStoreError: Error, Equatable, Sendable {
    case unavailable
    case invalidNamespace
    case invalidEvent
    case invalidStream
    case sequenceConflict(streamID: String, sequence: UInt64)
    case eventConflict(streamID: String, eventID: String)
}

/// The local append-only replica of one authenticated Host visibility scope.
/// Host ID and access scope are deliberately part of every key: a Session ID
/// can be reused by another Host or become visible under another permission
/// scope, while a canonical stream ID is only unique inside this namespace.
public actor WarrenAgentEventStore {
    public static let shared = WarrenAgentEventStore()

    public struct Namespace: Hashable, Sendable {
        public let hostID: String
        public let accessScopeID: String

        public init(hostID: String, accessScopeID: String) {
            self.hostID = hostID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.accessScopeID = accessScopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        fileprivate var isValid: Bool { !hostID.isEmpty && !accessScopeID.isEmpty }
    }

    public struct SyncState: Equatable, Sendable {
        public let namespace: Namespace
        public let streamID: String
        public let retainedFromSequence: UInt64
        public let headSequence: UInt64
        public let contiguousThrough: UInt64
        public let checkpointSequence: UInt64
        public let checkpoint: [String: WarrenRemoteJSONValue]?
        public let hasMoreBefore: Bool

        public init(
            namespace: Namespace,
            streamID: String,
            retainedFromSequence: UInt64 = 0,
            headSequence: UInt64 = 0,
            contiguousThrough: UInt64 = 0,
            checkpointSequence: UInt64 = 0,
            checkpoint: [String: WarrenRemoteJSONValue]? = nil,
            hasMoreBefore: Bool = false
        ) {
            self.namespace = namespace
            self.streamID = streamID
            self.retainedFromSequence = retainedFromSequence
            self.headSequence = headSequence
            self.contiguousThrough = contiguousThrough
            self.checkpointSequence = checkpointSequence
            self.checkpoint = checkpoint
            self.hasMoreBefore = hasMoreBefore
        }
    }

    private let handle: SQLiteHandle?
    private var db: OpaquePointer? { handle?.pointer }
    private let maxEventsPerStream = 5_000
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databasePath: String? = nil) {
        let path: String
        if let databasePath {
            path = databasePath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let directory = appSupport.appendingPathComponent("Warren", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("warren-agent.sqlite3").path
        }
        handle = SQLiteHandle(Self.openDatabase(at: path))
    }

    private static func openDatabase(at path: String) -> OpaquePointer? {
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK else {
            if let pointer { sqlite3_close(pointer) }
            return nil
        }
        sqlite3_exec(pointer, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(pointer, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(pointer, "PRAGMA busy_timeout=5000;", nil, nil, nil)

        // The old session/epoch cache is intentionally disposable. Dropping it
        // avoids guessing how a provider projection maps to a canonical stream.
        sqlite3_exec(pointer, "DROP TABLE IF EXISTS ios_agent_events;", nil, nil, nil)
        sqlite3_exec(pointer, "DROP TABLE IF EXISTS ios_agent_sync_state;", nil, nil, nil)
        let schema = """
        CREATE TABLE IF NOT EXISTS agent_events (
            host_id          TEXT NOT NULL,
            access_scope_id  TEXT NOT NULL,
            stream_id        TEXT NOT NULL,
            execution_id     TEXT NOT NULL,
            sequence         INTEGER NOT NULL,
            event_id         TEXT NOT NULL,
            event_type       TEXT NOT NULL,
            event_json       TEXT NOT NULL,
            recorded_at      TEXT,
            PRIMARY KEY (host_id, access_scope_id, stream_id, sequence),
            UNIQUE (host_id, access_scope_id, stream_id, event_id)
        );
        CREATE INDEX IF NOT EXISTS idx_agent_events_stream_sequence
            ON agent_events(host_id, access_scope_id, stream_id, sequence);
        CREATE INDEX IF NOT EXISTS idx_agent_events_stream_event
            ON agent_events(host_id, access_scope_id, stream_id, event_id);
        CREATE TABLE IF NOT EXISTS agent_stream_state (
            host_id                  TEXT NOT NULL,
            access_scope_id          TEXT NOT NULL,
            stream_id                TEXT NOT NULL,
            retained_from_sequence   INTEGER NOT NULL DEFAULT 0,
            head_sequence            INTEGER NOT NULL DEFAULT 0,
            contiguous_through       INTEGER NOT NULL DEFAULT 0,
            checkpoint_sequence      INTEGER NOT NULL DEFAULT 0,
            checkpoint_json          TEXT,
            has_more_before          INTEGER NOT NULL DEFAULT 0,
            updated_at               REAL NOT NULL,
            PRIMARY KEY (host_id, access_scope_id, stream_id)
        );
        """
        guard sqlite3_exec(pointer, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(pointer)
            return nil
        }
        return pointer
    }

    public func saveEvents(
        _ events: [WarrenRemoteAgentEvent],
        namespace: Namespace,
        streamID: String,
        checkpointSequence: UInt64 = 0,
        checkpoint: [String: WarrenRemoteJSONValue]? = nil,
        retainedFromSequence: UInt64? = nil
    ) throws -> SyncState {
        guard namespace.isValid else { throw WarrenAgentEventStoreError.invalidNamespace }
        let streamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamID.isEmpty else { throw WarrenAgentEventStoreError.invalidStream }
        guard let db else { throw WarrenAgentEventStoreError.unavailable }

        try exec(db, "BEGIN IMMEDIATE TRANSACTION;")
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
        }

        for event in events {
            guard event.sequence > 0, event.sequence <= UInt64(Int64.max), !event.eventID.isEmpty, event.streamID == streamID, event.executionID?.isEmpty == false else { throw WarrenAgentEventStoreError.invalidEvent }
            let eventID = event.eventID
            let data = try encoder.encode(event)
            guard let json = String(data: data, encoding: .utf8) else {
                throw WarrenAgentEventStoreError.unavailable
            }
            if let existing = queryEvent(db, namespace: namespace, streamID: streamID, sequence: event.sequence) {
                guard existing.eventID == eventID,
                      eventsEquivalent(existing.json, json) else {
                    throw WarrenAgentEventStoreError.sequenceConflict(streamID: streamID, sequence: event.sequence)
                }
                continue
            }
            if let existing = queryEventID(db, namespace: namespace, streamID: streamID, eventID: eventID) {
                guard existing.sequence == event.sequence,
                      eventsEquivalent(existing.json, json) else {
                    throw WarrenAgentEventStoreError.eventConflict(streamID: streamID, eventID: eventID)
                }
                continue
            }
            let sql = """
            INSERT INTO agent_events
                (host_id, access_scope_id, stream_id, execution_id, sequence, event_id, event_type, event_json, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw WarrenAgentEventStoreError.unavailable
            }
            bind(statement, 1, namespace.hostID)
            bind(statement, 2, namespace.accessScopeID)
            bind(statement, 3, streamID)
            bind(statement, 4, event.executionID ?? streamID)
            sqlite3_bind_int64(statement, 5, Int64(event.sequence))
            bind(statement, 6, eventID)
            bind(statement, 7, event.type)
            bind(statement, 8, json)
            if let recordedAt = event.recordedAt { bind(statement, 9, recordedAt) } else { sqlite3_bind_null(statement, 9) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw WarrenAgentEventStoreError.unavailable
            }
            sqlite3_finalize(statement)
        }

        var state = readState(db, namespace: namespace, streamID: streamID)
            ?? SyncState(namespace: namespace, streamID: streamID)
        let rows = loadAll(db, namespace: namespace, streamID: streamID)
        let explicitBoundary = retainedFromSequence.map { min($0, UInt64(Int64.max)) }
        if let maxSequence = rows.map(\.sequence).max() {
            let localRetained = rows.map(\.sequence).min() ?? maxSequence
            // A page returned by a modern Host carries its authoritative
            // retention boundary. When that metadata is absent (older Host
            // or a live batch), keep the smallest locally observed sequence
            // only until a boundary has been established. Once a boundary is
            // known, never replace it with a local cache minimum: the cache
            // may be evicted independently of Host history.
            let boundaryIsAuthoritative = explicitBoundary != nil || state.retainedFromSequence > 0
            let retained = explicitBoundary
                ?? (state.retainedFromSequence > 0 ? state.retainedFromSequence : localRetained)
            let baseline = explicitBoundary.map { max(0, $0 - 1) } ?? state.contiguousThrough
            state = SyncState(
                namespace: namespace,
                streamID: streamID,
                retainedFromSequence: retained,
                headSequence: max(state.headSequence, maxSequence),
                contiguousThrough: contiguousThrough(
                    after: baseline,
                    sequences: Set(rows.map(\.sequence))
                ),
                checkpointSequence: state.checkpointSequence,
                checkpoint: state.checkpoint,
                hasMoreBefore: boundaryIsAuthoritative
                    ? localRetained > retained
                    : localRetained > 1
            )
        } else if let explicitBoundary {
            state = SyncState(
                namespace: namespace,
                streamID: streamID,
                retainedFromSequence: explicitBoundary,
                headSequence: state.headSequence,
                contiguousThrough: max(state.contiguousThrough, max(0, explicitBoundary - 1)),
                checkpointSequence: state.checkpointSequence,
                checkpoint: state.checkpoint,
                hasMoreBefore: false
            )
        }
        if let checkpoint {
            let checkpointSequence = min(checkpointSequence, UInt64(Int64.max))
            state = SyncState(
                namespace: namespace,
                streamID: streamID,
                retainedFromSequence: state.retainedFromSequence,
                headSequence: max(state.headSequence, checkpointSequence),
                // A projection checkpoint does not prove that every event row
                // before it is present locally. Keep the contiguous cursor
                // derived from the actual immutable rows; the checkpoint is
                // separately available for cold-start rendering.
                contiguousThrough: state.contiguousThrough,
                checkpointSequence: checkpointSequence,
                checkpoint: checkpoint,
                hasMoreBefore: state.hasMoreBefore
            )
        }

        if rows.count > maxEventsPerStream {
            let cutoff = rows.sorted { $0.sequence > $1.sequence }.dropFirst(maxEventsPerStream).map(\.sequence).filter { $0 <= state.contiguousThrough }
            for sequence in cutoff {
                deleteEvent(db, namespace: namespace, streamID: streamID, sequence: sequence)
            }
            let localRetained = loadAll(db, namespace: namespace, streamID: streamID).map(\.sequence).min() ?? 0
            let retained = state.retainedFromSequence > 0
                ? state.retainedFromSequence
                : localRetained
            state = SyncState(
                namespace: namespace,
                streamID: streamID,
                retainedFromSequence: retained,
                headSequence: state.headSequence,
                contiguousThrough: contiguousThrough(
                    after: state.contiguousThrough,
                    sequences: Set(loadAll(db, namespace: namespace, streamID: streamID).map(\.sequence))
                ),
                checkpointSequence: state.checkpointSequence,
                checkpoint: state.checkpoint,
                hasMoreBefore: localRetained > retained
            )
        }
        try writeState(db, state)
        try exec(db, "COMMIT;")
        committed = true
        return state
    }

    /// Installs the replacement snapshot supplied by a Host
    /// `history_boundary` error. Local rows before the Host's retained prefix
    /// are disposable cache data and are removed atomically with the cursor.
    public func installHistoryBoundary(
        namespace: Namespace,
        streamID: String,
        retainedFromSequence: UInt64,
        headSequence: UInt64,
        checkpointSequence: UInt64,
        checkpoint: [String: WarrenRemoteJSONValue]?
    ) throws -> SyncState {
        guard namespace.isValid else { throw WarrenAgentEventStoreError.invalidNamespace }
        let streamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamID.isEmpty else { throw WarrenAgentEventStoreError.invalidStream }
        guard let db else { throw WarrenAgentEventStoreError.unavailable }
        let retained = min(retainedFromSequence, UInt64(Int64.max))
        let head = min(headSequence, UInt64(Int64.max))
        let checkpointSequence = min(checkpointSequence, UInt64(Int64.max))
        try exec(db, "BEGIN IMMEDIATE TRANSACTION;")
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
        }
        if retained > 0 {
            let sql = "DELETE FROM agent_events WHERE host_id = ? AND access_scope_id = ? AND stream_id = ? AND sequence < ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw WarrenAgentEventStoreError.unavailable
            }
            bind(statement, 1, namespace.hostID)
            bind(statement, 2, namespace.accessScopeID)
            bind(statement, 3, streamID)
            sqlite3_bind_int64(statement, 4, Int64(retained))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw WarrenAgentEventStoreError.unavailable
            }
            sqlite3_finalize(statement)
        }
        let state = SyncState(
            namespace: namespace,
            streamID: streamID,
            retainedFromSequence: retained,
            headSequence: max(head, checkpointSequence),
            // A projection checkpoint describes replaceable status only; it
            // does not prove that journal rows up to that sequence exist on
            // this device. Resume from the retained prefix and fetch the
            // immutable rows explicitly.
            contiguousThrough: min(max(0, retained - 1), max(head, checkpointSequence)),
            checkpointSequence: checkpointSequence,
            checkpoint: checkpoint,
            hasMoreBefore: false
        )
        try writeState(db, state)
        try exec(db, "COMMIT;")
        committed = true
        return state
    }

    public func loadRecentEvents(namespace: Namespace, streamID: String, limit: Int = 100) -> [WarrenRemoteAgentEvent] {
        let streamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard namespace.isValid, !streamID.isEmpty, let db else { return [] }
        return loadAll(db, namespace: namespace, streamID: streamID)
            .sorted { $0.sequence > $1.sequence }
            .prefix(max(0, limit))
            .reversed()
            .compactMap { decodeEvent($0.json) }
    }

    public func loadEvents(
        namespace: Namespace,
        streamID: String,
        afterSequence: UInt64 = 0,
        beforeSequence: UInt64 = 0,
        limit: Int = 100
    ) -> [WarrenRemoteAgentEvent] {
        let streamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard namespace.isValid, !streamID.isEmpty, let db else { return [] }
        return loadAll(db, namespace: namespace, streamID: streamID)
            .filter { $0.sequence > afterSequence && (beforeSequence == 0 || $0.sequence < beforeSequence) }
            .sorted { $0.sequence < $1.sequence }
            .prefix(max(0, limit))
            .compactMap { decodeEvent($0.json) }
    }

    public func syncState(namespace: Namespace, streamID: String) -> SyncState? {
        let streamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard namespace.isValid, !streamID.isEmpty, let db else { return nil }
        return readState(db, namespace: namespace, streamID: streamID)
    }

    public func clearStream(namespace: Namespace, streamID: String) {
        let streamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard namespace.isValid, !streamID.isEmpty, let db else { return }
        deleteAll(db, namespace: namespace, streamID: streamID)
    }

    public func clearNamespace(_ namespace: Namespace) {
        guard namespace.isValid, let db else { return }
        deleteRows(db, "DELETE FROM agent_events WHERE host_id = ? AND access_scope_id = ?;", namespace: namespace)
        deleteRows(db, "DELETE FROM agent_stream_state WHERE host_id = ? AND access_scope_id = ?;", namespace: namespace)
    }

    /// Removes every visibility scope cached for one Host installation. This
    /// is used only when the user deletes a saved endpoint; a live connection
    /// normally clears its exact `(hostId, accessScopeId)` namespace.
    public func clearHost(hostID: String) {
        let hostID = hostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostID.isEmpty, let db else { return }
        deleteRows(db, "DELETE FROM agent_events WHERE host_id = ?;", hostID: hostID)
        deleteRows(db, "DELETE FROM agent_stream_state WHERE host_id = ?;", hostID: hostID)
    }

    public func purgeOrphanStreams(namespace: Namespace, activeStreamIDs: Set<String>) {
        guard namespace.isValid, let db else { return }
        let sql = "SELECT DISTINCT stream_id FROM agent_stream_state WHERE host_id = ? AND access_scope_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bind(statement, 1, namespace.hostID)
        bind(statement, 2, namespace.accessScopeID)
        var streams: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
            streams.append(String(cString: value))
        }
        sqlite3_finalize(statement)
        for streamID in streams where !activeStreamIDs.contains(streamID) {
            clearStream(namespace: namespace, streamID: streamID)
        }
    }

    public func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM agent_events;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM agent_stream_state;", nil, nil, nil)
    }

    private struct Row {
        let sequence: UInt64
        let eventID: String
        let json: String
    }

    private func loadAll(_ db: OpaquePointer, namespace: Namespace, streamID: String) -> [Row] {
        let sql = "SELECT sequence, event_id, event_json FROM agent_events WHERE host_id = ? AND access_scope_id = ? AND stream_id = ? ORDER BY sequence ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, namespace.hostID)
        bind(statement, 2, namespace.accessScopeID)
        bind(statement, 3, streamID)
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let sequence = UInt64(max(0, sqlite3_column_int64(statement, 0)))
            guard let eventID = sqlite3_column_text(statement, 1),
                  let json = sqlite3_column_text(statement, 2) else { continue }
            rows.append(Row(sequence: sequence, eventID: String(cString: eventID), json: String(cString: json)))
        }
        return rows
    }

    private func readState(_ db: OpaquePointer, namespace: Namespace, streamID: String) -> SyncState? {
        let sql = "SELECT retained_from_sequence, head_sequence, contiguous_through, checkpoint_sequence, checkpoint_json, has_more_before FROM agent_stream_state WHERE host_id = ? AND access_scope_id = ? AND stream_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, namespace.hostID)
        bind(statement, 2, namespace.accessScopeID)
        bind(statement, 3, streamID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let checkpoint: [String: WarrenRemoteJSONValue]? = {
            guard let value = sqlite3_column_text(statement, 4),
                  let data = String(cString: value).data(using: .utf8) else { return nil }
            return try? decoder.decode([String: WarrenRemoteJSONValue].self, from: data)
        }()
        return SyncState(
            namespace: namespace,
            streamID: streamID,
            retainedFromSequence: UInt64(max(0, sqlite3_column_int64(statement, 0))),
            headSequence: UInt64(max(0, sqlite3_column_int64(statement, 1))),
            contiguousThrough: UInt64(max(0, sqlite3_column_int64(statement, 2))),
            checkpointSequence: UInt64(max(0, sqlite3_column_int64(statement, 3))),
            checkpoint: checkpoint,
            hasMoreBefore: sqlite3_column_int(statement, 5) != 0
        )
    }

    private func writeState(_ db: OpaquePointer, _ state: SyncState) throws {
        let checkpointJSON: String? = {
            guard let checkpoint = state.checkpoint,
                  let data = try? encoder.encode(checkpoint) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        let sql = """
        INSERT INTO agent_stream_state
            (host_id, access_scope_id, stream_id, retained_from_sequence, head_sequence, contiguous_through, checkpoint_sequence, checkpoint_json, has_more_before, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(host_id, access_scope_id, stream_id) DO UPDATE SET
            retained_from_sequence = excluded.retained_from_sequence,
            head_sequence = excluded.head_sequence,
            contiguous_through = excluded.contiguous_through,
            checkpoint_sequence = excluded.checkpoint_sequence,
            checkpoint_json = excluded.checkpoint_json,
            has_more_before = excluded.has_more_before,
            updated_at = excluded.updated_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WarrenAgentEventStoreError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, state.namespace.hostID)
        bind(statement, 2, state.namespace.accessScopeID)
        bind(statement, 3, state.streamID)
        sqlite3_bind_int64(statement, 4, Int64(state.retainedFromSequence))
        sqlite3_bind_int64(statement, 5, Int64(state.headSequence))
        sqlite3_bind_int64(statement, 6, Int64(state.contiguousThrough))
        sqlite3_bind_int64(statement, 7, Int64(state.checkpointSequence))
        if let checkpointJSON { bind(statement, 8, checkpointJSON) } else { sqlite3_bind_null(statement, 8) }
        sqlite3_bind_int(statement, 9, state.hasMoreBefore ? 1 : 0)
        sqlite3_bind_double(statement, 10, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw WarrenAgentEventStoreError.unavailable }
    }

    private func queryEvent(_ db: OpaquePointer, namespace: Namespace, streamID: String, sequence: UInt64) -> Row? {
        queryRow(db, sql: "SELECT event_id, event_json FROM agent_events WHERE host_id = ? AND access_scope_id = ? AND stream_id = ? AND sequence = ?;", namespace: namespace, streamID: streamID, sequence: sequence)
    }

    private func queryEventID(_ db: OpaquePointer, namespace: Namespace, streamID: String, eventID: String) -> Row? {
        let sql = "SELECT sequence, event_json FROM agent_events WHERE host_id = ? AND access_scope_id = ? AND stream_id = ? AND event_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, namespace.hostID)
        bind(statement, 2, namespace.accessScopeID)
        bind(statement, 3, streamID)
        bind(statement, 4, eventID)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let json = sqlite3_column_text(statement, 1) else { return nil }
        return Row(
            sequence: UInt64(max(0, sqlite3_column_int64(statement, 0))),
            eventID: eventID,
            json: String(cString: json)
        )
    }

    private func queryRow(_ db: OpaquePointer, sql: String, namespace: Namespace, streamID: String, sequence: UInt64) -> Row? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, namespace.hostID)
        bind(statement, 2, namespace.accessScopeID)
        bind(statement, 3, streamID)
        sqlite3_bind_int64(statement, 4, Int64(sequence))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let eventID = sqlite3_column_text(statement, 0),
              let json = sqlite3_column_text(statement, 1) else { return nil }
        return Row(sequence: sequence, eventID: String(cString: eventID), json: String(cString: json))
    }

    private func deleteEvent(_ db: OpaquePointer, namespace: Namespace, streamID: String, sequence: UInt64) {
        let sql = "DELETE FROM agent_events WHERE host_id = ? AND access_scope_id = ? AND stream_id = ? AND sequence = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, namespace.hostID)
        bind(statement, 2, namespace.accessScopeID)
        bind(statement, 3, streamID)
        sqlite3_bind_int64(statement, 4, Int64(sequence))
        _ = sqlite3_step(statement)
    }

    private func deleteAll(_ db: OpaquePointer, namespace: Namespace, streamID: String) {
        deleteRows(db, "DELETE FROM agent_events WHERE host_id = ? AND access_scope_id = ? AND stream_id = ?;", namespace: namespace, streamID: streamID)
        deleteRows(db, "DELETE FROM agent_stream_state WHERE host_id = ? AND access_scope_id = ? AND stream_id = ?;", namespace: namespace, streamID: streamID)
    }

    private func deleteRows(
        _ db: OpaquePointer,
        _ sql: String,
        namespace: Namespace? = nil,
        streamID: String? = nil,
        hostID: String? = nil
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        if let hostID {
            bind(statement, 1, hostID)
        } else if let namespace {
            bind(statement, 1, namespace.hostID)
            bind(statement, 2, namespace.accessScopeID)
            if let streamID { bind(statement, 3, streamID) }
        } else {
            sqlite3_finalize(statement)
            return
        }
        _ = sqlite3_step(statement)
    }

    private func decodeEvent(_ json: String) -> WarrenRemoteAgentEvent? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(WarrenRemoteAgentEvent.self, from: data)
    }

    private func eventsEquivalent(_ left: String, _ right: String) -> Bool {
        guard let leftData = left.data(using: .utf8), let rightData = right.data(using: .utf8),
              let lhs = try? decoder.decode(WarrenRemoteAgentEvent.self, from: leftData),
              let rhs = try? decoder.decode(WarrenRemoteAgentEvent.self, from: rightData) else { return left == right }
        return lhs == rhs
    }

    private func contiguousThrough(after: UInt64, sequences: Set<UInt64>) -> UInt64 {
        var cursor = after
        while sequences.contains(cursor + 1) { cursor += 1 }
        return cursor
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw WarrenAgentEventStoreError.unavailable
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
    }
}
