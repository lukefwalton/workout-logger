import Foundation

/// Splits one raw input line into candidate per-exercise segments, so a
/// multi-entry breath — "bench 135x8 + curl 30x10", a pasted multi-line log,
/// "bench 135x8 squat 225x5" — can be logged as a *sequence* of single-exercise
/// confirms instead of dead-ending. The confirm card holds exactly one exercise
/// by design (every mutator is entry-wide), so splitting is how flexibility is
/// added *around* that invariant rather than by weakening it.
///
/// This type only proposes boundaries; it never decides whether the segments
/// are actually loggable. `TodayModel` gates the split (every segment must
/// independently parse, read as cardio, or recover honestly) and drives the
/// confirm-then-queue sequencing. All-or-nothing lives there, not here.
///
/// Boundary rules, deliberately conservative:
///   • newline / ";" — always a boundary (a pasted log's natural shape);
///   • "+" or "," — a boundary only when the text so far carries a number
///     (there's a spec to close) and the next word reads like a fresh exercise
///     name, so rep lists ("135 for 8, 8, 7", "chinups 7+3") never split;
///   • a bare space — a boundary only before a fresh name word once the running
///     segment already contains a *complete* spec (`135x8`, `@ 135`, `for 8`,
///     `2 sets`/`8 reps`), which is what separates "bench 135x8 squat 225x5"
///     from "close grip bench 135x8".
/// Modifier / unit / filler words (rpe, kg, sets, warmup, min, then, …) never
/// start a segment — they belong to the entry in progress.
enum EntrySplitter {

    /// Candidate segments for `raw`, trimmed and non-empty. A line with no safe
    /// boundary comes back as a single segment (the original, trimmed).
    static func segments(_ raw: String) -> [String] {
        let pieces = hardPieces(raw).flatMap(softPieces)
        let cleaned = pieces
            .map { trimConnectors($0) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty {
            let whole = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [whole]
        }
        return cleaned
    }

    // MARK: - Hard separators (newline · ";" · "+" · ",")

    private static func hardPieces(_ raw: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNewline || c == ";" {
                pieces.append(current)
                current = ""
                i += 1
                continue
            }
            // "+"/"," split only between a numbered span and a fresh name word;
            // "7+3" and "8, 8, 7" are rep lists and must stay whole.
            if c == "+" || c == "," {
                if current.contains(where: { $0.isNumber }),
                   let word = nextWord(chars, after: i),
                   isSegmentStarterWord(word) {
                    pieces.append(current)
                    current = ""
                    i += 1
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        pieces.append(current)
        return pieces
    }

    private static func nextWord(_ chars: [Character], after index: Int) -> String? {
        var j = index + 1
        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
        var word = ""
        while j < chars.count, !chars[j].isWhitespace,
              chars[j] != ";", chars[j] != "+", chars[j] != "," {
            word.append(chars[j])
            j += 1
        }
        return word.isEmpty ? nil : word
    }

    // MARK: - Soft (space) boundaries — "bench 135x8 squat 225x5"

    private static func softPieces(_ piece: String) -> [String] {
        let words = piece.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 2 else { return [piece] }
        var segments: [String] = []
        var current: [String] = []
        for word in words {
            if !current.isEmpty, isSegmentStarterWord(word),
               hasCompleteSpec(current.joined(separator: " ")) {
                segments.append(current.joined(separator: " "))
                current = []
            }
            current.append(word)
        }
        segments.append(current.joined(separator: " "))
        return segments
    }

    /// Whether the running text already contains a spec a new exercise could
    /// follow: `WxR`, an `@`-introduced load, `for REPS`, or a sets/reps word.
    /// Without one, a fresh name word is just more of the current name
    /// ("close grip bench …"), never a boundary.
    private static func hasCompleteSpec(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "×", with: "x")
        let patterns = [
            #"\d\s*x\s*\d"#,
            #"@\s*\d"#,
            #"\bfor\s+\d"#,
            #"\d\s*(reps?|sets?)\b"#
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// A word that plausibly *starts a new exercise name*: letter-led, no
    /// digits, and not a modifier/unit/filler word that belongs to the entry
    /// in progress.
    private static func isSegmentStarterWord(_ raw: String) -> Bool {
        let word = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        guard let first = word.first, first.isLetter else { return false }
        guard !word.contains(where: { $0.isNumber }) else { return false }
        return !continuationWords.contains(word)
    }

    /// Words that continue the current entry rather than open a new one. Keep
    /// this superset-generous: a missed split degrades to today's behavior,
    /// while a false split chops a real entry in half.
    private static let continuationWords: Set<String> = [
        // operators / prose glue
        "x", "@", "for", "at", "with", "of", "to", "then", "and", "them",
        "each", "more", "did", "got", "another", "the", "a", "an", "plus",
        "total", "per",
        // set/rep words + intensity
        "set", "sets", "rep", "reps", "rpe", "rir",
        // loads / units
        "kg", "kgs", "lb", "lbs", "pound", "pounds", "kilo", "kilos",
        "bw", "bodyweight",
        // set types (the deterministic grammar's modifier keywords)
        "warmup", "warm-up", "dropset", "myorep", "myoreps", "amrap",
        "backoff", "back-off", "working",
        // cardio metrics — "run 5k 25 min" is one bout, not two entries
        "min", "mins", "minute", "minutes", "sec", "secs", "second", "seconds",
        "hr", "hrs", "hour", "hours",
        "mi", "km", "k", "m", "mile", "miles", "meter", "meters", "metre", "metres"
    ]

    /// Trim whitespace plus trailing connector words a boundary can strand
    /// ("bench 135x8 and | curl 30x10" → "bench 135x8").
    private static func trimConnectors(_ segment: String) -> String {
        var words = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let connectors: Set<String> = ["and", "then", "plus", "&", ","]
        while let last = words.last?.lowercased(), connectors.contains(last) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }
}
