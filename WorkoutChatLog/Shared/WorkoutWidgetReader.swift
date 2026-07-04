import Foundation
import os

/// The widget's read path. It opens its **own** connection to the shared App Group
/// SQLite file (cross-process WAL reads are safe — the store already runs in WAL) and
/// runs only SELECTs, so it never touches the `@MainActor` write path. Open session
/// wins; otherwise the most recently finished workout; otherwise empty. Any read
/// failure degrades to `.empty` rather than crashing the widget — but is logged to the
/// unified log so a misconfigured App Group / DB open / schema regression is
/// observable (a widget is hard to attach a debugger to, so DEBUG-only prints wouldn't
/// help). Errors carry no user data, so they're logged `.public`.
enum WorkoutWidgetReader {
    private static let log = Logger(subsystem: AppGroup.identifier, category: "Widget")

    /// Convenience used by the widget's timeline provider: resolve the shared file and
    /// read it. A missing/unreadable store → `.empty` (logged).
    static func snapshot() -> WidgetWorkoutSnapshot {
        do {
            let url = try SharedDatabase.databaseURL()
            let db = try SQLiteDB(path: url.path)
            return snapshot(db: db)
        } catch {
            // String(describing:) — SharedDatabase.StoreError / SQLiteDB.DBError are
            // CustomStringConvertible (not LocalizedError), so localizedDescription
            // would drop their detailed message.
            log.error("widget couldn't open the shared store: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }

    /// Testable core: decide what to show from an open database. Only SELECTs,
    /// wrapped in a read transaction so the two queries (open-session,
    /// last-finished) see one consistent snapshot — a writer committing
    /// between them used to be able to produce "open session has N sets" +
    /// "and here's the now-finished version of that session," double-counting
    /// in degenerate timing.
    static func snapshot(db: SQLiteDB) -> WidgetWorkoutSnapshot {
        do {
            return try db.readTransaction {
                if let openSets = try openSessionSetCount(db) {
                    return .current(sets: openSets)
                }
                if let last = try lastFinishedSession(db) {
                    return last
                }
                return .empty
            }
        } catch {
            // Degrade to empty, but record it — a query failure (e.g. a schema
            // regression) shouldn't be silently indistinguishable from "no data."
            log.error("widget read failed: \(String(describing: error), privacy: .public)")
        }
        return .empty
    }

    /// Set count of the single open session (`ended_at IS NULL`), or nil if none.
    private static func openSessionSetCount(_ db: SQLiteDB) throws -> Int? {
        let stmt = try db.prepare("""
            SELECT (SELECT COUNT(*) FROM sets WHERE session_id = s.id)
            FROM workout_sessions s
            WHERE s.ended_at IS NULL
            ORDER BY s.id DESC
            LIMIT 1;
        """)
        defer { stmt.finalize() }
        guard try stmt.step() else { return nil }
        let count = Int(stmt.int(0))
        // An open session with no sets yet (opened via startSession, nothing logged)
        // isn't a meaningful "current workout" — fall through to the last finished
        // session instead of shadowing it with "0 sets · in progress".
        return count > 0 ? count : nil
    }

    /// The most recently finished session as a `.last` snapshot, or nil if none.
    private static func lastFinishedSession(_ db: SQLiteDB) throws -> WidgetWorkoutSnapshot? {
        let stmt = try db.prepare("""
            SELECT s.name, s.ended_at, (SELECT COUNT(*) FROM sets WHERE session_id = s.id)
            FROM workout_sessions s
            WHERE s.ended_at IS NOT NULL
            ORDER BY s.ended_at DESC, s.id DESC
            LIMIT 1;
        """)
        defer { stmt.finalize() }
        guard try stmt.step() else { return nil }
        // If ended_at can't be parsed, return nil rather than fall back to Date() —
        // a "last workout = now" lie would be worse than showing nothing. (The
        // parser matches WorkoutStore's exactly — [.withInternetDateTime] — so this
        // is a defensive guard, not an expected path.)
        guard let endedAt = SharedDatabase.date(stmt.text(1)) else {
            // Now that open/query failures are logged, log this too so a timestamp
            // format drift is a detectable regression, not a silent "no data."
            log.error("widget: unparseable ended_at on the last finished session")
            return nil
        }
        return .last(name: stmt.text(0), endedAt: endedAt, sets: Int(stmt.int(2)))
    }
}
