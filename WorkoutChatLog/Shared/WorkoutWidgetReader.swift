import Foundation
import os

/// The widget's read path. It opens its **own** connection to the shared App Group
/// SQLite file (cross-process WAL reads are safe — the store already runs in WAL) and
/// runs only SELECTs, so it never touches the `@MainActor` write path. Open session
/// wins; otherwise the newer of the most recently finished workout and the most
/// recent cardio bout; otherwise empty. Any read failure degrades to `.empty` rather
/// than crashing the widget — but is logged to the unified log so a misconfigured
/// App Group / DB open / schema regression is observable (a widget is hard to attach
/// a debugger to, so DEBUG-only prints wouldn't help). Errors carry no user data, so
/// they're logged `.public`.
enum WorkoutWidgetReader {
    private static let log = Logger(subsystem: AppGroup.identifier, category: "Widget")

    /// A dated candidate for the "no open session" slot, so the newer-wins
    /// comparison doesn't have to destructure enum payloads back apart.
    private typealias Candidate = (snapshot: WidgetWorkoutSnapshot, when: Date)

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
    /// wrapped in a read transaction so the queries (open-session,
    /// last-finished, last-cardio) see one consistent snapshot — a writer
    /// committing between them used to be able to produce "open session has N
    /// sets" + "and here's the now-finished version of that session,"
    /// double-counting in degenerate timing.
    ///
    /// Precedence: an open strength session always wins; otherwise the *newer*
    /// of the last finished workout and the last cardio bout (tie → strength,
    /// the established surface).
    static func snapshot(db: SQLiteDB) -> WidgetWorkoutSnapshot {
        do {
            return try db.readTransaction {
                if let openSets = try openSessionSetCount(db) {
                    return .current(sets: openSets)
                }
                let strength = try lastFinishedSession(db)
                let cardio = lastCardioEntry(db)
                switch (strength, cardio) {
                case (nil, nil):
                    return .empty
                case (let strength?, nil):
                    return strength.snapshot
                case (nil, let cardio?):
                    return cardio.snapshot
                case (let strength?, let cardio?):
                    return cardio.when > strength.when ? cardio.snapshot : strength.snapshot
                }
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

    /// The most recently finished session as a dated `.last` candidate, or nil if none.
    private static func lastFinishedSession(_ db: SQLiteDB) throws -> Candidate? {
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
        return (.last(name: stmt.text(0), endedAt: endedAt, sets: Int(stmt.int(2))), endedAt)
    }

    /// The most recent cardio bout as a dated `.lastCardio` candidate, or nil if
    /// none. Never throws: cardio_entries may not exist yet — the shipped pre-v3
    /// app's store isn't migrated until its first launch after the update, and
    /// WidgetKit can refresh the widget before that — so a cardio-side failure
    /// degrades to "no cardio candidate" (logged) instead of blanking the whole
    /// snapshot and hiding the user's last workout. An unparseable logged_at also
    /// returns nil rather than fabricating a "cardio = now" lie.
    private static func lastCardioEntry(_ db: SQLiteDB) -> Candidate? {
        do {
            let stmt = try db.prepare("""
                SELECT activity, duration_seconds, distance, distance_unit, logged_at
                FROM cardio_entries
                ORDER BY logged_at DESC, id DESC
                LIMIT 1;
            """)
            defer { stmt.finalize() }
            guard try stmt.step() else { return nil }
            guard let loggedAt = SharedDatabase.date(stmt.text(4)) else {
                log.error("widget: unparseable logged_at on the last cardio bout")
                return nil
            }
            return (.lastCardio(activity: stmt.text(0) ?? "Cardio",
                                durationSeconds: stmt.optionalInt(1),
                                distance: stmt.optionalDouble(2),
                                distanceUnit: stmt.text(3).flatMap(CardioDistanceUnit.init(rawValue:)),
                                loggedAt: loggedAt), loggedAt)
        } catch {
            log.error("widget cardio read failed (pre-v3 store?): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
