import Foundation
import SQLite3

// SQLite wants to know whether it may free a bound string itself. TRANSIENT
// tells it to copy immediately, which is what we want for Swift `String`s whose
// backing buffer only lives for the duration of the bind call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin, dependency-free wrapper over the SQLite C API that iOS already
/// bundles. Deliberately small: it knows about statements and transactions, not
/// about workouts. The domain SQL lives in `WorkoutStore`.
///
/// `@unchecked Sendable` rests on two layers. `SQLITE_OPEN_FULLMUTEX` (see
/// `init(path:)`) makes each individual C call thread-safe, but it does NOT
/// make a multi-statement Swift closure atomic: another thread's statement
/// could run between BEGIN and COMMIT on the same connection and observe (or
/// join) the half-applied transaction. So on top of the mutex, a recursive
/// `connectionLock` serializes `transaction` and `readTransaction` closures —
/// while any transaction is open on this connection, no other thread can run
/// one. Off-main reads (`WorkoutStore.setHistory`, `sessionSetSpans`, …) stay
/// legal; they go through `readTransaction` and simply wait their turn.
final class SQLiteDB: @unchecked Sendable {
    enum DBError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)
        case exec(String)

        var description: String {
            switch self {
            case .open(let m): return "SQLite open failed: \(m)"
            case .prepare(let m): return "SQLite prepare failed: \(m)"
            case .step(let m): return "SQLite step failed: \(m)"
            case .exec(let m): return "SQLite exec failed: \(m)"
            }
        }
    }

    private let handle: OpaquePointer

    /// Serializes whole transaction closures (not just single C calls) on this
    /// connection. Recursive because store reads compose: a read wrapped in
    /// `readTransaction` may be called from inside an open `transaction` body
    /// on the same thread (e.g. `resolveExercise` inside `save`).
    private let connectionLock = NSRecursiveLock()

    /// True while a top-level `readTransaction` snapshot is open. Only ever
    /// read or written under `connectionLock`, so inside `prepare` a true
    /// value can only mean the CURRENT thread's snapshot (any other thread
    /// would still be blocked on the lock) — which makes the reads-only check
    /// below race-free without thread bookkeeping.
    private var inReadTransaction = false

    /// Opens (creating if needed) the database at `path`. Pass ":memory:" for an
    /// ephemeral DB.
    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw DBError.open(message)
        }
        self.handle = db
        sqlite3_busy_timeout(handle, 5_000)
        // WAL must be set outside a transaction. Foreign-key enforcement is
        // per-connection and OFF by default in SQLite — without this, every
        // `ON DELETE CASCADE` in the schema silently does nothing.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit { sqlite3_close(handle) }

    /// Runs one or more semicolon-separated statements that return no rows
    /// (DDL, pragmas, BEGIN/COMMIT).
    func execute(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errmsg)
            throw DBError.exec(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.prepare(lastErrorMessage())
        }
        // The reads-only snapshot contract, enforced at the statement level:
        // the nested-BEGIN diagnostic in `transaction` catches writes that go
        // through the write path, but a raw INSERT/UPDATE/DELETE prepared
        // directly inside a snapshot would silently upgrade the deferred
        // transaction instead. `sqlite3_stmt_readonly` knows exactly which
        // statements write, so those are refused here before they can run.
        if inReadTransaction, sqlite3_stmt_readonly(stmt) == 0 {
            sqlite3_finalize(stmt)
            throw DBError.prepare("""
                write statement prepared inside readTransaction/snapshot — snapshots are reads-only
                """)
        }
        return Statement(stmt: stmt, db: handle)
    }

    /// BEGIN IMMEDIATE -> body -> COMMIT, rolling back if `body` throws. The
    /// single atomic boundary every write passes through, so a partial workout
    /// never lands.
    ///
    /// IMMEDIATE acquires the write lock at BEGIN time rather than at the first
    /// write inside the transaction. Without it, a long detached reader (e.g.
    /// `HistoryModel.load` on a Task.detached) holding the read lock can force
    /// a deferred-transaction writer that has already issued INSERTs to
    /// SQLITE_BUSY after the busy_timeout — even though the writer started
    /// first. IMMEDIATE makes the writer wait once at BEGIN; once it has the
    /// lock, subsequent writes can't be starved.
    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        // Catch misuse with a precise diagnostic before the generic BEGIN
        // failure: we hold the recursive lock, so an already-open transaction
        // here can only be our own thread's — either a write attempted inside
        // `readTransaction`/`WorkoutStore.snapshot` (reads-only by contract),
        // or a nested `transaction` (they don't nest; the import path inserts
        // raw rows for exactly this reason — learnings/027).
        guard sqlite3_get_autocommit(handle) != 0 else {
            throw DBError.exec("""
                write transaction opened inside an open transaction — writes are \
                not allowed inside readTransaction/snapshot, and transactions do not nest
                """)
        }
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Read-only transaction (BEGIN DEFERRED -> body -> COMMIT). Used by
    /// read-only clients (the Home Screen widget, and every `WorkoutStore`
    /// read) that need a consistent snapshot — without it, a writer can
    /// commit between two queries and the second SELECT can see a different
    /// state, and on *this* connection a bare read could even land inside
    /// another thread's open write transaction and see half a workout.
    /// Cannot be used for writes (the deferred transaction would upgrade to a
    /// write lock on the first write and is the variant the main `transaction`
    /// helper warns about).
    ///
    /// Nesting-aware: when a transaction is already open on this connection
    /// (we hold the recursive lock, so it can only be our own thread's — e.g.
    /// a wrapped read helper called from inside `save`), the enclosing
    /// transaction is already the snapshot boundary and the body just runs;
    /// issuing a second BEGIN would be an error.
    @discardableResult
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard sqlite3_get_autocommit(handle) != 0 else { return try body() }
        try execute("BEGIN DEFERRED;")
        inReadTransaction = true
        defer { inReadTransaction = false }
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func userVersion() throws -> Int {
        let stmt = try prepare("PRAGMA user_version;")
        defer { stmt.finalize() }
        return try stmt.step() ? Int(stmt.int(0)) : 0
    }

    func setUserVersion(_ version: Int) throws {
        // PRAGMA does not accept bound parameters; `version` is an Int we own.
        try execute("PRAGMA user_version = \(version);")
    }

    private func lastErrorMessage() -> String { String(cString: sqlite3_errmsg(handle)) }
}

/// A prepared statement. Bind indices are 1-based, column indices 0-based —
/// matching the C API so the call sites read like the SQL.
final class Statement {
    private let stmt: OpaquePointer
    private let db: OpaquePointer

    init(stmt: OpaquePointer, db: OpaquePointer) {
        self.stmt = stmt
        self.db = db
    }

    func bind(text value: String, at index: Int32) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    func bind(optionalText value: String?, at index: Int32) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bind(int value: Int64, at index: Int32) {
        sqlite3_bind_int64(stmt, index, value)
    }

    func bind(double value: Double, at index: Int32) {
        sqlite3_bind_double(stmt, index, value)
    }

    func bind(optionalDouble value: Double?, at index: Int32) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bind(optionalInt value: Int?, at index: Int32) {
        if let value {
            sqlite3_bind_int64(stmt, index, Int64(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Advances one row. Returns true on SQLITE_ROW, false on SQLITE_DONE. For
    /// INSERT/UPDATE the result can be ignored.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteDB.DBError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(stmt, column) }

    func text(_ column: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: c)
    }

    func optionalInt(_ column: Int32) -> Int? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, column))
    }

    func optionalDouble(_ column: Int32) -> Double? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, column)
    }

    func finalize() { sqlite3_finalize(stmt) }
}
