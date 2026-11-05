import Foundation
import SQLite3

/// A thin, honest wrapper over the C API.
///
/// No ORM: the memory store is a handful of tables with FTS5 beside them, and
/// the queries that matter (hybrid search, graph walks) are clearer as SQL than
/// as anything an abstraction would make of them.
nonisolated final class SQLiteDB: @unchecked Sendable {
    enum Failure: LocalizedError {
        case open(String)
        case prepare(String, String)
        case step(String)

        var errorDescription: String? {
            switch self {
            case .open(let message): "Could not open the database: \(message)"
            case .prepare(let message, let sql): "SQL error: \(message) in \(sql.prefix(120))"
            case .step(let message): "SQL error: \(message)"
            }
        }
    }

    private(set) var handle: OpaquePointer?

    /// Opens `path`. `readOnly` opens other apps' databases (Messages,
    /// WhatsApp) without ever taking a write lock on them.
    init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let target = readOnly ? "file:\(path)?mode=ro" : path
        guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw Failure.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 4000)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw Failure.prepare(message, sql)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.prepare(String(cString: sqlite3_errmsg(handle)), sql)
        }
        return Statement(statement, db: handle)
    }

    /// Runs `body` in one transaction. Ingesting a hundred thousand messages
    /// one implicit transaction at a time is the difference between seconds and
    /// an hour.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    /// Convenience for a query that yields rows.
    func rows(_ sql: String, _ bindings: [Value] = [], _ each: (Statement) throws -> Void) throws {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        while try statement.step() { try each(statement) }
    }

    func run(_ sql: String, _ bindings: [Value] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        _ = try statement.step()
    }

    func scalarInt(_ sql: String, _ bindings: [Value] = []) throws -> Int {
        var result = 0
        try rows(sql, bindings) { result = $0.int(0) }
        return result
    }

    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null

        static func of(_ string: String?) -> Value { string.map(Value.text) ?? .null }
        static func of(_ int: Int) -> Value { .int(Int64(int)) }
        static func of(_ bool: Bool) -> Value { .int(bool ? 1 : 0) }
    }

    final class Statement {
        private let raw: OpaquePointer
        private let db: OpaquePointer?

        init(_ raw: OpaquePointer, db: OpaquePointer?) {
            self.raw = raw
            self.db = db
        }

        deinit { sqlite3_finalize(raw) }

        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        func bind(_ values: [Value]) throws {
            sqlite3_reset(raw)
            sqlite3_clear_bindings(raw)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .int(let v): sqlite3_bind_int64(raw, index, v)
                case .double(let v): sqlite3_bind_double(raw, index, v)
                case .text(let v): sqlite3_bind_text(raw, index, v, -1, Self.transient)
                case .blob(let v):
                    _ = v.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(raw, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                    }
                case .null: sqlite3_bind_null(raw, index)
                }
            }
        }

        /// True while there is a row to read.
        @discardableResult
        func step() throws -> Bool {
            switch sqlite3_step(raw) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw Failure.step(String(cString: sqlite3_errmsg(db)))
            }
        }

        func reset() { sqlite3_reset(raw) }

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(raw, column)) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(raw, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(raw, column) == SQLITE_NULL }

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(raw, column) else { return nil }
            return String(cString: pointer)
        }

        func blob(_ column: Int32) -> Data? {
            guard let pointer = sqlite3_column_blob(raw, column) else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(raw, column)))
        }
    }
}
