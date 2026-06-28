import Foundation

/// Deterministic, **never-fail** cardio extractor. Where `DeterministicParser`
/// reads the set/rep grammar and declines anything that doesn't fit, this reads
/// the cardio shapes the strength grammar can't represent — duration and
/// distance — and produces a `CardioDraft` for any input that carries a cardio
/// signal:
///
///   • an activity keyword ("bike", "ran", "row", "elliptical", …), or
///   • a duration ("30 min", "1:30:00", "45s", "1h 20min"), or
///   • a distance ("5k", "3 mi", "1000m").
///
/// It returns nil only when there is *no* cardio signal at all — that's the
/// hand-off back to the strength path. The activity always resolves to the
/// closest canonical (`CardioActivity`); when nothing matches it keeps the
/// user's own leading words, falling back to a plain "Cardio". Match to the
/// closest, never reject.
enum CardioParser {

    /// A bare number paired with a cardio activity but no explicit unit is read
    /// as minutes ("bike 30" → 30 min) only when it's a plausible duration.
    static let maxInferredMinutes = 300

    static func parse(_ entry: String) -> CardioDraft? {
        let original = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        let lower = original.lowercased().replacingOccurrences(of: "×", with: "x")

        let duration = parseDuration(lower)
        let distance = parseDistance(lower)
        let match = matchActivity(in: lower)
        let hasMetric = duration != nil || distance != nil

        // No activity, no duration, no distance → not cardio. Hand back to the
        // strength path rather than invent a bout.
        guard hasMetric || match != nil else { return nil }

        // Without an explicit duration/distance, only commit to cardio when the
        // line is essentially just the activity (+ an optional number) — so a
        // strength move that merely *contains* a cardio word ("walking lunge 20",
        // "ski squat 135") isn't mis-filed as cardio. An explicit metric is a
        // strong enough signal to accept extra words ("rowing intervals 30 min").
        if !hasMetric {
            guard let match, !hasForeignWords(lower, matched: match) else { return nil }
        }

        // Best-effort: a lone "<activity> 30" with no unit is minutes.
        var resolvedDuration = duration
        if resolvedDuration == nil, distance == nil, match != nil,
           let bare = firstBareNumber(in: lower), bare >= 1, bare <= Double(maxInferredMinutes),
           bare.rounded() == bare {
            resolvedDuration = Int(bare) * 60
        }

        return CardioDraft(activity: activityName(lower: lower, match: match),
                           durationSeconds: resolvedDuration,
                           distance: distance?.value,
                           distanceUnit: distance?.unit,
                           notes: nil,
                           sourceText: original)
    }

    // MARK: - Activity resolution

    /// Whether `lower` contains an alphabetic word that's neither part of the
    /// matched activity's keywords nor a filler/unit — i.e. a foreign exercise
    /// word that suggests this is a *named lift* containing a cardio-ish word, not
    /// a cardio bout. Used only when there's no explicit duration/distance.
    private static func hasForeignWords(_ lower: String, matched: CardioActivity) -> Bool {
        var keywordWords = Set<String>()
        for keyword in matched.keywords {
            for word in keyword.split(separator: " ") { keywordWords.insert(String(word)) }
        }
        for token in lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init) {
            guard token.first?.isNumber != true else { continue }   // numbers aren't foreign
            if keywordWords.contains(token) || isFiller(token) || isUnitWord(token) { continue }
            return true
        }
        return false
    }

    private static func matchActivity(in lower: String) -> CardioActivity? {
        for activity in CardioActivity.allCases {
            for keyword in activity.keywords where containsWholeWords(lower, keyword) {
                return activity
            }
        }
        return nil
    }

    /// The display name for the bout: the matched canonical, else the user's own
    /// leading non-numeric words (title-cased), else "Cardio". Never empty.
    private static func activityName(lower: String, match: CardioActivity?) -> String {
        if let match, match != .generic { return match.display }
        // No specific canonical: keep the user's leading words so "jazzercise
        // 30 min" reads as "Jazzercise", not a generic stub.
        let leading = leadingWords(lower)
        if !leading.isEmpty { return titleCased(leading) }
        return CardioActivity.generic.display
    }

    /// Leading run of alphabetic words before the first digit / unit / filler —
    /// the user's own name for the activity when no keyword matched.
    private static func leadingWords(_ lower: String) -> String {
        var words: [String] = []
        for token in lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init) {
            if token.first?.isNumber == true { break }
            if isFiller(token) || isUnitWord(token) { break }
            words.append(token)
        }
        return words.joined(separator: " ")
    }

    private static func titleCased(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: - Duration

    /// Total seconds, summing hours + minutes + seconds words, or a colon time
    /// ("25:00" = mm:ss, "1:30:00" = hh:mm:ss). nil when no duration is present.
    static func parseDuration(_ lower: String) -> Int? {
        // Colon time wins outright — it already encodes the whole duration.
        if let colon = firstMatch(#"(?<![0-9:])([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?(?![0-9:])"#, in: lower) {
            let a = Int(colon[1] ?? "") ?? 0
            let b = Int(colon[2] ?? "") ?? 0
            if let cString = colon[3], let c = Int(cString) {
                return a * 3600 + b * 60 + c          // hh:mm:ss
            }
            return a * 60 + b                          // mm:ss
        }

        var total = 0
        var found = false
        if let h = firstNumber(#"([0-9]+(?:\.[0-9]+)?)\s*(?:h|hr|hrs|hour|hours)\b"#, in: lower) {
            total += Int((h * 3600).rounded()); found = true
        }
        if let m = firstNumber(#"([0-9]+(?:\.[0-9]+)?)\s*(?:min|mins|minute|minutes)\b"#, in: lower) {
            total += Int((m * 60).rounded()); found = true
        }
        if let s = firstNumber(#"([0-9]+)\s*(?:sec|secs|second|seconds)\b"#, in: lower) {
            total += Int(s); found = true
        }
        return found ? total : nil
    }

    // MARK: - Distance

    /// First distance found, preferring miles → km → meters. "5k" is km.
    static func parseDistance(_ lower: String) -> (value: Double, unit: CardioDistanceUnit)? {
        if let v = firstNumber(#"([0-9]+(?:\.[0-9]+)?)\s*(?:mi|mile|miles)\b"#, in: lower) {
            return (v, .mi)
        }
        if let v = firstNumber(#"([0-9]+(?:\.[0-9]+)?)\s*(?:km|kms|kilometer|kilometers|kilometre|kilometres|k)\b"#, in: lower) {
            return (v, .km)
        }
        if let v = firstNumber(#"([0-9]+(?:\.[0-9]+)?)\s*(?:m|meter|meters|metre|metres)\b"#, in: lower) {
            return (v, .m)
        }
        return nil
    }

    // MARK: - Helpers

    private static func firstBareNumber(in lower: String) -> Double? {
        firstNumber(#"(?<![0-9.])([0-9]+(?:\.[0-9]+)?)(?![0-9.])"#, in: lower)
    }

    private static func isUnitWord(_ token: String) -> Bool {
        ["min", "mins", "minute", "minutes", "h", "hr", "hrs", "hour", "hours",
         "sec", "secs", "second", "seconds", "km", "kms", "mi", "mile", "miles",
         "m", "meter", "meters", "k", "lb", "lbs", "kg", "kgs"].contains(token)
    }

    private static func isFiller(_ token: String) -> Bool {
        ["for", "of", "at", "in", "on", "a", "an", "the", "did", "do", "done",
         "and", "then", "with", "easy", "hard", "today"].contains(token)
    }

    /// Whole-word containment: `phrase` (one or more words) appears in `text`
    /// bounded by non-alphanumerics, so "swim" matches "swim 1k" but not
    /// "swimmers press".
    private static func containsWholeWords(_ text: String, _ phrase: String) -> Bool {
        let padded = " " + String(text.map { ($0.isLetter || $0.isNumber) ? $0 : " " }) + " "
        return padded.contains(" " + phrase + " ")
    }

    // MARK: - Tiny regex layer (capture groups, which String.range can't return)

    private static func firstNumber(_ pattern: String, in text: String) -> Double? {
        guard let groups = firstMatch(pattern, in: text), let first = groups[1] else { return nil }
        return Double(first)
    }

    /// Returns the capture groups of the first match (index 0 = whole match), or
    /// nil. A missing optional group is nil at its index.
    private static func firstMatch(_ pattern: String, in text: String) -> [Int: String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var groups: [Int: String] = [:]
        for i in 0..<match.numberOfRanges {
            let r = match.range(at: i)
            if r.location != NSNotFound, let swiftRange = Range(r, in: text) {
                groups[i] = String(text[swiftRange])
            }
        }
        return groups
    }
}
