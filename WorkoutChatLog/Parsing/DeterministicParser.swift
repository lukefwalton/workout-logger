import Foundation

/// Track 1: a deterministic parser for the numeric/syntactic part of a workout
/// log — the part that's a grammar, not ML. It returns `[SetDraft]` with the
/// exercise span left as raw lowercase text (resolved later by `WorkoutStore`),
/// or `nil` when it can't *confidently* parse. That `nil` is the precise hand-off
/// to the on-device LLM fallback (Track 2): a wrong silent parse is worse than
/// deferring.
///
/// Recognized shapes (case-insensitive, spacing-insensitive):
///   135x8 · 135 x 8 · 135x8x3 · 135 for 8,8,7 · 135x8,8,7 ·
///   3x10 @ 135 · 8 @ 135 · 225x5 rpe 8 · 60kg x 8 · warmup 95x10 ·
///   bw x12 · 3x10 · 2 sets of 8 reps · 8 reps at 135 ·
///   pull up 15 (bare rep count on likely bodyweight lifts)
/// Anything else (multi-exercise lines, conversational text, ambiguous small
/// 3-number forms like 5x5x5) returns nil by design — that's Track 2's job.
///
/// A bare spec with no exercise (`3x10`, `135x8`) parses with an **empty**
/// `exerciseName`: it's a valid parse of a spec whose exercise comes from context
/// (a preselected lift, a chat continuation). Such a draft won't survive
/// `WorkoutStore.save` until an exercise is attached — parser generous, saver strict.
enum DeterministicParser {

    /// For an ambiguous `A x B` with no unit and no `@`, A in 1...this is read as
    /// a set count ("3x10"); above it, as a weight ("135x8"). A leading number
    /// with a unit ("10lb x 12") is always a weight. Tunable by hand (spec §13).
    static let maxPlausibleSetCount = 10

    static func parse(_ entry: String, defaultUnit: WeightUnit = .lb) -> [SetDraft]? {
        let original = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }

        var tokens = tokenize(original)

        // Pull modifiers out of the stream wherever they sit, so what's left is
        // "<name tokens> <numeric core>".
        var setType: SetType = .working
        if let idx = tokens.firstIndex(where: { setTypeKeyword($0) != nil }) {
            setType = setTypeKeyword(tokens[idx])!
            tokens.remove(at: idx)
        }

        var rir: Int?
        if let idx = tokens.firstIndex(where: { $0 == "rpe" || $0 == "rir" }) {
            // Confident-or-decline: require a clean integer (RPE 1...10, RIR 0...10). A decimal
            // ("rpe 7.5") or out-of-range value ("rpe 12", "rir 11") declines the
            // whole entry rather than being silently rounded/clamped into a
            // different number — RIR feeds analytics directly, so no fabrication.
            guard idx + 1 < tokens.count, let raw = Int(tokens[idx + 1]) else {
                return nil
            }
            if tokens[idx] == "rpe" {
                guard (1...10).contains(raw) else { return nil }
                rir = 10 - raw   // RIR = 10 − RPE (RPE 8 ≈ 2 RIR)
            } else {
                guard (0...10).contains(raw) else { return nil }
                rir = raw
            }
            tokens.removeSubrange(idx...(idx + 1))
        }

        if let phrase = parseSetRepPhrase(tokens, unit: defaultUnit) {
            return phrase.sets.map {
                SetDraft(exerciseName: phrase.name, weight: $0.weight, unit: $0.unit,
                         loadKind: $0.loadKind,
                         reps: $0.reps, rir: rir, setType: setType,
                         notes: nil, sourceText: original)
            }
        }

        // The numeric core is the *trailing* run of spec tokens; the exercise
        // name is everything before it. Scanning from the end (not the first
        // number) lets names that contain digits — like the seeded alias
        // "45 degree back extension" — keep them instead of having the leading
        // number mistaken for the start of the spec.
        var specStart = tokens.count
        while specStart > 0, isCoreToken(tokens[specStart - 1]) { specStart -= 1 }
        let core = Array(tokens[specStart...]).filter { $0 != "," }
        guard core.contains(where: { weightToken($0) != nil }) else {
            return nil   // no number/bw in the trailing run → not a set log
        }
        let nameTokens = Array(tokens[0..<specStart])
        guard !containsPriorCoreSyntax(nameTokens) else { return nil }
        let name = cleanExerciseName(nameTokens.joined(separator: " "))

        if let sets = parseCore(core, unit: defaultUnit), !sets.isEmpty {
            return sets.map { mapCoreSet($0, name: name, setType: setType, rir: rir, source: original) }
        }

        // `<likely-bw exercise> REPS` with no `x`/`@`/`for` — "pull up 15". The
        // name must read like a plain lift: a digit inside it ("chin ups 7 then")
        // means there's more structure we shouldn't flatten to one set — decline
        // so the forgiving recovery can read the full rep list instead.
        if core.count == 1, let reps = Int(core[0]), validReps(reps), !name.isEmpty,
           !name.contains(where: { $0.isNumber }),
           likelyBodyweightExercise(name) {
            let set = CoreSet(weight: 0, reps: reps, unit: defaultUnit, loadKind: .bodyweight)
            return [mapCoreSet(set, name: name, setType: setType, rir: rir, source: original)]
        }

        return nil
    }

    private static func mapCoreSet(_ set: CoreSet, name: String, setType: SetType, rir: Int?, source: String) -> SetDraft {
        SetDraft(exerciseName: name, weight: set.weight, unit: set.unit,
                 loadKind: set.loadKind,
                 reps: set.reps, rir: rir, setType: setType,
                 notes: nil, sourceText: source)
    }

    // MARK: - Core numeric grammar

    private struct CoreSet {
        let weight: Double
        let reps: Int
        let unit: WeightUnit
        let loadKind: WorkoutLoadKind
    }
    private struct CoreLoad {
        let weight: Double
        let unit: WeightUnit
        let hadExplicitUnit: Bool
        let isBodyweight: Bool
        let kind: WorkoutLoadKind
    }

    private static func parseSetRepPhrase(_ tokens: [String], unit: WeightUnit) -> (name: String, sets: [CoreSet])? {
        // Common prose-y suffixes:
        //   "<exercise> 2 sets of 8 reps"
        //   "<exercise> 2 sets of 8 at 135"
        //   "<exercise> 8 reps with 135"
        // Weight stays 0 when absent so confirmation can fill it in.
        var working = tokens
        var load = CoreLoad(weight: 0, unit: unit, hadExplicitUnit: false, isBodyweight: false, kind: .unspecified)

        if let loadRange = trailingIntroducedLoadRange(in: working),
           let parsedLoad = parseLoad(Array(working[loadRange.load]), defaultUnit: unit) {
            load = parsedLoad
            working.removeSubrange(loadRange.introducerAndLoad)
        }

        let hadRepWord = working.last.map(isRepWord) ?? false
        if hadRepWord { working.removeLast() }

        guard let repsToken = working.last, let reps = Int(repsToken), reps >= 1 else { return nil }
        working.removeLast()

        let setCount: Int
        if working.last == "of" { working.removeLast() }
        if let setWord = working.last, isSetWord(setWord) {
            working.removeLast()
            guard let countToken = working.last,
                  let parsedSetCount = Int(countToken),
                  (1...99).contains(parsedSetCount) else { return nil }
            setCount = parsedSetCount
            working.removeLast()
        } else {
            guard hadRepWord else { return nil }
            setCount = 1
        }

        if working.last == "for" { working.removeLast() }
        let name = cleanExerciseName(working.joined(separator: " "))
        guard validReps(reps) else { return nil }
        return (name, Array(repeating: CoreSet(weight: load.weight, reps: reps, unit: load.unit, loadKind: load.kind),
                            count: setCount))
    }

    private static func parseCore(_ core: [String], unit: WeightUnit) -> [CoreSet]? {
        // A) [SETS x] REPS @ WEIGHT
        if let at = core.firstIndex(of: "@") {
            let left = Array(core[0..<at])
            let right = Array(core[(at + 1)...])
            guard let load = parseLoad(right, defaultUnit: unit) else { return nil }
            let sets: Int
            let reps: Int
            if left.count == 3, left[1] == "x", let s = Int(left[0]), let r = Int(left[2]) {
                sets = s; reps = r
            } else if left.count == 1, let r = Int(left[0]) {
                sets = 1; reps = r
            } else {
                return nil
            }
            if !load.hadExplicitUnit, reps > Int(load.weight) { return nil }
            guard (1...99).contains(sets), validReps(reps) else { return nil }
            return Array(repeating: CoreSet(weight: load.weight, reps: reps, unit: load.unit, loadKind: load.kind),
                         count: sets)
        }

        // B) WEIGHT for REPS[,REPS...]
        if let f = core.firstIndex(of: "for") {
            let left = Array(core[0..<f])
            let repTokens = Array(core[(f + 1)...]).filter { $0 != "," }
            guard let load = parseLoad(left, defaultUnit: unit) else { return nil }
            let reps = repTokens.compactMap { Int($0) }
            guard !reps.isEmpty, reps.count == repTokens.count, reps.allSatisfy(validReps) else { return nil }
            return reps.map { CoreSet(weight: load.weight, reps: $0, unit: load.unit, loadKind: load.kind) }
        }

        // C) WEIGHT x REPS x SETS. Common shorthand, but only accepted when the
        // first number is confidently a weight; small 3-number forms like 5x5x5
        // stay declined instead of being guessed.
        let xPositions = core.indices.filter { core[$0] == "x" }
        if xPositions.count == 2 {
            let firstX = xPositions[0]
            let secondX = xPositions[1]
            let loadTokens = Array(core[0..<firstX])
            let repsIndex = firstX + 1
            let setsIndex = secondX + 1
            guard let load = parseLoad(loadTokens, defaultUnit: unit),
                  repsIndex == secondX - 1,
                  setsIndex == core.count - 1,
                  let reps = Int(core[repsIndex]),
                  let sets = Int(core[setsIndex]) else { return nil }
            guard isConfidentWeight(load), (1...99).contains(sets), validReps(reps) else { return nil }
            return Array(repeating: CoreSet(weight: load.weight, reps: reps, unit: load.unit, loadKind: load.kind),
                         count: sets)
        }

        // D) A x REPS[,REPS...]
        if let x = core.firstIndex(of: "x") {
            let left = Array(core[0..<x])
            let repTokens = Array(core[(x + 1)...]).filter { $0 != "," }
            guard let a = parseLoad(left, defaultUnit: unit) else { return nil }
            let reps = repTokens.compactMap { Int($0) }
            guard !reps.isEmpty, reps.count == repTokens.count, reps.allSatisfy(validReps) else { return nil }

            // A standalone unit ("10 kg x 12") makes the leading number a weight
            // just as a glued one ("10kg x 12") does — otherwise a small weight
            // would be misread as a set count.
            if reps.count == 1, !isConfidentWeight(a), left.count == 1, let count = Int(left[0]),
               (1...maxPlausibleSetCount).contains(count) {
                // SETS x REPS — load intentionally left unspecified until confirmed.
                return Array(repeating: CoreSet(weight: 0, reps: reps[0], unit: unit, loadKind: .unspecified), count: count)
            }
            // WEIGHT x REP(S) — one set per rep value
            return reps.map { CoreSet(weight: a.weight, reps: $0, unit: a.unit, loadKind: a.kind) }
        }

        return nil
    }

    /// Bare `<exercise> REPS` is accepted only for spans that usually mean
    /// bodyweight — keeps "bench 135" declined while "pull up 15" parses.
    private static func likelyBodyweightExercise(_ name: String) -> Bool {
        let n = name.lowercased()
        let phrases = [
            "pull up", "pull-up", "pullup",
            "chin up", "chin-up", "chinup",
            "push up", "push-up", "pushup",
            "muscle up", "muscle-up",
            "air squat", "bodyweight squat", "pistol squat",
            "inverted row", "hanging leg raise",
            "sit up", "sit-up", "situp",
            "burpee"
        ]
        if phrases.contains(where: { n.contains($0) }) { return true }
        // Short standalone names — "dips 12", not "tricep pushdown 12".
        let tokens = n.split(separator: " ").map(String.init)
        if tokens == ["dip"] || tokens == ["dips"] { return true }
        return false
    }

    private static func parseLoad(_ tokens: [String], defaultUnit: WeightUnit) -> CoreLoad? {
        guard !tokens.isEmpty else { return nil }

        if tokens.count == 1, let raw = weightToken(tokens[0]) {
            return CoreLoad(weight: raw.weight,
                            unit: raw.unit ?? defaultUnit,
                            hadExplicitUnit: raw.unit != nil,
                            isBodyweight: isBodyweightToken(tokens[0]),
                            kind: isBodyweightToken(tokens[0]) ? .bodyweight : .external)
        }

        if tokens.count == 2,
           let raw = weightToken(tokens[0]),
           raw.unit == nil,
           !isBodyweightToken(tokens[0]),
           let unit = unitKeyword(tokens[1]) {
            return CoreLoad(weight: raw.weight, unit: unit, hadExplicitUnit: true, isBodyweight: false, kind: .external)
        }

        return nil
    }

    private static func isConfidentWeight(_ load: CoreLoad) -> Bool {
        load.hadExplicitUnit || load.isBodyweight || load.weight > Double(maxPlausibleSetCount)
    }

    private static func validReps(_ reps: Int) -> Bool {
        WorkoutValidator.repsRange.contains(reps)
    }

    private static func trailingIntroducedLoadRange(in tokens: [String]) -> (introducerAndLoad: Range<Int>, load: Range<Int>)? {
        guard tokens.count >= 3 else { return nil }

        let oneTokenIntroducer = tokens.count - 2
        if isLoadIntroducer(tokens[oneTokenIntroducer]) {
            return (oneTokenIntroducer..<tokens.count, (oneTokenIntroducer + 1)..<tokens.count)
        }

        guard tokens.count >= 4 else { return nil }
        let twoTokenIntroducer = tokens.count - 3
        if isLoadIntroducer(tokens[twoTokenIntroducer]) {
            return (twoTokenIntroducer..<tokens.count, (twoTokenIntroducer + 1)..<tokens.count)
        }

        return nil
    }

    private static func containsPriorCoreSyntax(_ tokens: [String]) -> Bool {
        guard tokens.count >= 3 else { return false }

        for index in tokens.indices {
            if tokens[index] == "x",
               index > tokens.startIndex,
               tokens.index(after: index) < tokens.endIndex,
               loadEndingBefore(index, in: tokens) != nil,
               Int(tokens[tokens.index(after: index)]) != nil {
                return true
            }

            if tokens[index] == "for",
               index > tokens.startIndex,
               tokens.index(after: index) < tokens.endIndex,
               loadEndingBefore(index, in: tokens) != nil,
               Int(tokens[tokens.index(after: index)]) != nil {
                return true
            }

            if tokens[index] == "@",
               index > tokens.startIndex,
               tokens.index(after: index) < tokens.endIndex,
               Int(tokens[tokens.index(before: index)]) != nil,
               loadStartingAfter(index, in: tokens) != nil {
                return true
            }
        }

        return false
    }

    private static func loadEndingBefore(_ index: Int, in tokens: [String]) -> CoreLoad? {
        guard index > tokens.startIndex else { return nil }

        if let load = parseLoad([tokens[tokens.index(before: index)]], defaultUnit: .lb) {
            return load
        }

        guard index >= tokens.startIndex + 2 else { return nil }
        return parseLoad(Array(tokens[(index - 2)..<index]), defaultUnit: .lb)
    }

    private static func loadStartingAfter(_ index: Int, in tokens: [String]) -> CoreLoad? {
        let first = tokens.index(after: index)
        guard first < tokens.endIndex else { return nil }

        if let load = parseLoad([tokens[first]], defaultUnit: .lb) {
            return load
        }

        let second = tokens.index(after: first)
        guard second < tokens.endIndex else { return nil }
        return parseLoad(Array(tokens[first...second]), defaultUnit: .lb)
    }

    // MARK: - Tokenizing

    /// Splits on whitespace, but first spaces out the operators that get glued to
    /// numbers in real shorthand: `x`/`X` between/`@`/`,`. Everything is lowercased
    /// (the exercise name resolves case-insensitively). The Unicode multiplication
    /// sign `×` — what the confirm card itself displays, so it's easy to paste back
    /// in — is folded to `x` first so it's a first-class synonym everywhere.
    private static func tokenize(_ raw: String) -> [String] {
        let chars = Array(raw.lowercased().replacingOccurrences(of: "×", with: "x"))
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == "x" {
                let nextDigit = i + 1 < chars.count && chars[i + 1].isNumber
                let prevLetter = i > 0 && chars[i - 1].isLetter
                let prefix = String(chars[..<i])
                let followsGluedUnit = ["kg", "kgs", "lb", "lbs"].contains { prefix.hasSuffix($0) }
                if nextDigit && (!prevLetter || followsGluedUnit) { out += " x "; continue }
            }
            if c == "@" || c == "," { out += " \(c) "; continue }
            out.append(c)
        }
        // Split on ALL whitespace, newlines included. Space/tab-only splitting
        // let a pasted "bench 135x8\nsquat 225x5" glue "8\nsquat" into one
        // token and *silently parse* as a single garbled exercise — the worst
        // outcome the confident-or-decline contract exists to prevent.
        return out.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func cleanExerciseName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while [":", "-", "–", "—"].contains(where: { name.hasSuffix($0) }) {
            name.removeLast()
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name
    }

    // MARK: - Token helpers

    /// A token that can belong to the trailing numeric core: an operator or a
    /// weight/number. Anything else marks the boundary back into the name.
    private static func isCoreToken(_ token: String) -> Bool {
        token == "x" || token == "@" || token == "for" || token == ","
            || weightToken(token) != nil || unitKeyword(token) != nil
    }

    private static func isSetWord(_ token: String) -> Bool {
        token == "set" || token == "sets"
    }

    private static func isRepWord(_ token: String) -> Bool {
        token == "rep" || token == "reps"
    }

    private static func isLoadIntroducer(_ token: String) -> Bool {
        token == "@" || token == "at" || token == "with"
    }

    private static func isBodyweightToken(_ token: String) -> Bool {
        token == "bw" || token == "bodyweight"
    }

    /// A weight token: `bw`/`bodyweight` → 0, or a number with an optional glued
    /// unit (`135`, `135.5`, `60kg`, `225lb`). Returns nil for anything else.
    private static func weightToken(_ token: String) -> (weight: Double, unit: WeightUnit?)? {
        if token == "bw" || token == "bodyweight" { return (0, nil) }
        let chars = Array(token)
        var i = 0
        while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
        guard i > 0, let value = Double(String(chars[0..<i])) else { return nil }
        let suffix = String(chars[i...])
        if suffix.isEmpty { return (value, nil) }
        guard let unit = unitKeyword(suffix) else { return nil }
        return (value, unit)
    }

    private static func setTypeKeyword(_ token: String) -> SetType? {
        switch token {
        case "warmup", "warm-up": return .warmup
        case "dropset": return .dropset
        case "myorep", "myoreps": return .myorep
        case "amrap": return .amrap
        case "backoff", "back-off": return .backoff
        case "working": return .working
        default: return nil
        }
    }

    private static func unitKeyword(_ token: String) -> WeightUnit? {
        switch token {
        case "lb", "lbs", "pound", "pounds": return .lb
        case "kg", "kgs", "kilo", "kilos": return .kg
        default: return nil
        }
    }

    // MARK: - Decline diagnosis

    /// Best-effort diagnosis for *why* an entry the parser declined would have
    /// declined — surfaced in the status card so the user sees a real reason
    /// ("rep ranges aren't supported yet") instead of the generic prompt. Purely
    /// heuristic: a `nil` return means no specific diagnosis (fall back to the
    /// generic message). Called only when `parse(_:defaultUnit:)` returned nil,
    /// so this never overrides a successful parse.
    static func diagnoseDecline(_ entry: String) -> ParseDeclineReason? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Fold `×` to `x` so the diagnosis regexes (e.g. the 5×5×5 triple) see the
        // same shorthand the grammar does.
        let lower = trimmed.lowercased().replacingOccurrences(of: "×", with: "x")

        // Cardio shorthand: distance (5k / 5km) or `min`/`mins`/`minutes` near a
        // number. The schema is set/rep based, so call it out instead of guessing
        // a weight or rep count.
        if matchesCardio(lower) { return .cardio }

        // `8-10`, `8–10`, `8 to 10` etc. Range shapes don't fit the one-rep-per-set
        // contract; decline cleanly so the user picks a target.
        if matchesRepRange(lower) { return .repRange }

        // Multi-exercise on one line: `bench 135x8, curl 30x10` or
        // `bench 135x8 + curl 30x10` or two exercise-followed-by-spec runs.
        if matchesMultiExercise(lower) { return .multiExercise }

        // `bench 135` — load but no reps.
        if matchesIncompleteWeight(lower) { return .incompleteWeight }

        // `5x5x5`, `8x8x8` — the ambiguous triple-x form `parse` already declines.
        if matchesAmbiguousTripleX(lower) { return .ambiguousTripleX }

        return nil
    }

    private static func matchesCardio(_ lower: String) -> Bool {
        // `5k`/`5km`/`5.0km` distance, or a minutes word adjacent to a number.
        let distance = #"(?<![A-Za-z])\d+(\.\d+)?\s*k(m)?(?![A-Za-z])"#
        if lower.range(of: distance, options: .regularExpression) != nil { return true }
        let minutes = #"\d+\s*(min|mins|minute|minutes)\b"#
        if lower.range(of: minutes, options: .regularExpression) != nil { return true }
        return false
    }

    private static func matchesRepRange(_ lower: String) -> Bool {
        // Hyphen / en-dash / em-dash / "to" between two integers (no decimal points
        // — `1.5x10` isn't a range, it's a weight). `\b` boundaries keep the match
        // off of phone-number-like sequences.
        let dashRange = #"\b\d{1,3}\s*[-–—]\s*\d{1,3}\b"#
        if lower.range(of: dashRange, options: .regularExpression) != nil { return true }
        let wordRange = #"\b\d+\s*to\s*\d+\b"#
        return lower.range(of: wordRange, options: .regularExpression) != nil
    }

    private static func matchesMultiExercise(_ lower: String) -> Bool {
        // `+` before a fresh name word (`bench 135x8 + curl 30x10`) is the most
        // common superset marker. A `+` between numbers ("chinups 7+3") is a
        // rep list, not a second exercise — flagging it here would block the
        // forgiving recovery that reads it.
        if lower.range(of: #"\+\s*[a-z]"#, options: .regularExpression) != nil { return true }
        // Two distinct `<word> <number>x<number>` runs separated by a non-comma —
        // a `WORD NUMxNUM WORD NUMxNUM` shape we can't safely split.
        let twoSpecs = #"[a-z]{2,}[^,@]*?\d+\s*x\s*\d+[^,@]*?[a-z]{2,}[^,@]*?\d+\s*x\s*\d+"#
        return lower.range(of: twoSpecs, options: .regularExpression) != nil
    }

    private static func matchesIncompleteWeight(_ lower: String) -> Bool {
        // A name + a single trailing number with no `x`, `for`, `@`, or rep word.
        // The `parse` path already declines these, but call it out here so the
        // user sees "no reps" instead of the generic message.
        let tokens = lower.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2, let last = tokens.last else { return false }
        guard Double(last) != nil || weightToken(last) != nil else { return false }
        let body = tokens.dropLast()
        let hasGrammar = body.contains { ["x", "@", "for", "of"].contains($0) || isRepWord($0) || isSetWord($0) }
        guard !hasGrammar else { return false }
        let name = cleanExerciseName(body.joined(separator: " "))
        if likelyBodyweightExercise(name), let reps = Int(last), validReps(reps) { return false }
        return Double(last) != nil || weightToken(last) != nil
    }

    private static func matchesAmbiguousTripleX(_ lower: String) -> Bool {
        // `A x B x C` where A is small (<=10) so the parser can't tell which axis
        // is set count vs weight — the grammar already refuses this. Reported as a
        // distinct reason so the user knows to add a unit or rephrase.
        let pattern = #"(?<![0-9])\d{1,2}\s*x\s*\d{1,2}\s*x\s*\d{1,2}(?![0-9])"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }
}
