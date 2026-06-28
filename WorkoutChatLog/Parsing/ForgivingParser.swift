import Foundation

/// The "do your best, never dead-end" strength extractor. `DeterministicParser`
/// is deliberately strict — it declines anything ambiguous so a wrong silent
/// parse can't happen, handing off to the (often-absent) on-device model. When
/// that hand-off has nowhere to land, this stands in: it pulls weight, unit,
/// sets, reps, and an exercise name out of free-form text in **any order**, with
/// generous filler tolerance, and produces editable `SetDraft`s the user fixes
/// on the confirm card. It never fabricates reps it didn't read (they stay 0, the
/// unset sentinel, so Save stays disabled), but it always recovers *something*
/// when there's a real logging signal.
///
/// Shapes it recovers that the strict grammar declines:
///   • weight-first prose:        "120 lbs leg ext 3 set"
///   • the ambiguous x-triple:    "leg curl 8x160x3"  → 160 lb, 8 reps, 3 sets
///   • per-set rep lists:         "chinups 7,3" · "chin ups 7 then 3"
///   • bodyweight defaulting:     a chin-up / push-up / dip with no load → BW
///
/// Returns nil only when there's no usable signal at all (pure prose). The
/// caller still gates *whether* to recover (a recognizable lift, a real weight)
/// — this only decides *what* the text most likely meant.
enum ForgivingParser {

    static func parse(_ rawInput: String, defaultUnit: WeightUnit = .lb) -> [SetDraft]? {
        let original = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        var tokens = tokenize(original)
        guard !tokens.isEmpty else { return nil }

        // Pull modifiers out wherever they sit, like the strict parser does.
        var setType: SetType = .working
        if let i = tokens.firstIndex(where: { setTypeKeyword($0) != nil }) {
            setType = setTypeKeyword(tokens[i])!
            tokens.remove(at: i)
        }
        var rir: Int?
        if let i = tokens.firstIndex(where: { $0 == "rpe" || $0 == "rir" }),
           i + 1 < tokens.count, let raw = Int(tokens[i + 1]) {
            if tokens[i] == "rpe", (1...10).contains(raw) { rir = 10 - raw }
            else if tokens[i] == "rir", (0...10).contains(raw) { rir = raw }
            tokens.removeSubrange(i...(i + 1))
        }

        // `consumed[i] == true` once a token has been claimed (weight, operator,
        // structural number); whatever's left and alphabetic becomes the name.
        var consumed = [Bool](repeating: false, count: tokens.count)

        var weight: Double?
        var unit: WeightUnit?
        var loadIsBodyweight = false
        var setCount: Int?
        var reps: [Int] = []

        // ── 1. An x-chain anchors the most info: "135x8", "3x10", "8x160x3" ──
        if let chain = firstXChain(tokens, consumed: &consumed) {
            let parsed = interpretXChain(chain.values, defaultUnit: defaultUnit)
            weight = parsed.weight; unit = parsed.unit
            setCount = parsed.setCount; reps = parsed.reps
        }

        // ── 2. Explicit weight elsewhere: "135lb", "60 kg", "@135", "bw" ──
        if weight == nil, !loadIsBodyweight {
            if let bw = tokens.firstIndex(where: { isBodyweightToken($0) }), !consumed[bw] {
                loadIsBodyweight = true; weight = 0; consumed[bw] = true
            } else if let found = findExplicitWeight(tokens, consumed: &consumed, defaultUnit: defaultUnit) {
                weight = found.weight; unit = found.unit
            }
        }

        // ── 3. "N set(s)" / "N rep(s)" words, then bare rep lists ──
        if setCount == nil { setCount = findCounted(tokens, words: ["set", "sets"], consumed: &consumed) }
        if reps.isEmpty {
            if let r = findCounted(tokens, words: ["rep", "reps"], consumed: &consumed), validReps(r) {
                reps = [r]
            }
        }
        if reps.isEmpty {
            reps = remainingNumberList(tokens, consumed: &consumed, defaultUnit: defaultUnit)
        }

        // ── 4. A lone leftover number with no role yet ──
        if reps.isEmpty, weight == nil {
            if let only = lastBareNumber(tokens, consumed: &consumed) {
                if only > Double(DeterministicParser.maxPlausibleSetCount) {
                    weight = only           // "bench 135" → load, reps left unset
                } else if validReps(Int(only)) {
                    reps = [Int(only)]      // small lone number → reps
                }
            }
        }

        let name = cleanName(tokens, consumed: consumed)

        // Nothing structural at all and no name → not a workout line.
        if reps.isEmpty && weight == nil && setCount == nil && name.isEmpty { return nil }

        return buildSets(name: name, weight: weight, unit: unit ?? defaultUnit,
                         bodyweight: loadIsBodyweight, reps: reps, setCount: setCount,
                         rir: rir, setType: setType, source: original)
    }

    // MARK: - Build

    private static func buildSets(name: String, weight: Double?, unit: WeightUnit, bodyweight: Bool,
                                  reps: [Int], setCount: Int?, rir: Int?, setType: SetType,
                                  source: String) -> [SetDraft] {
        let load = weight ?? 0
        let kind: WorkoutLoadKind
        if bodyweight { kind = .bodyweight }
        else if load > 0 { kind = .external }
        else if likelyBodyweightExercise(name) { kind = .bodyweight }
        else { kind = .unspecified }

        func make(_ repCount: Int) -> SetDraft {
            SetDraft(exerciseName: name, weight: load, unit: unit, loadKind: kind,
                     reps: repCount, rir: rir, setType: setType, notes: nil, sourceText: source)
        }

        if !reps.isEmpty {
            if reps.count == 1, let count = setCount, (1...99).contains(count) {
                return Array(repeating: make(reps[0]), count: count)
            }
            return reps.map(make)
        }
        // No reps read — keep them unset (0) so Save stays disabled until filled.
        let count = setCount.map { max(1, min(99, $0)) } ?? 1
        return Array(repeating: make(0), count: count)
    }

    // MARK: - x-chain

    private struct XChain { let values: [String]; let range: Range<Int> }

    private static func firstXChain(_ tokens: [String], consumed: inout [Bool]) -> XChain? {
        var i = 0
        while i + 2 < tokens.count + 1 {
            if i + 2 <= tokens.count - 1,
               weightToken(tokens[i]) != nil, tokens[i + 1] == "x", weightToken(tokens[i + 2]) != nil {
                var values = [tokens[i]]
                var j = i + 1
                while j + 1 <= tokens.count - 1, tokens[j] == "x", weightToken(tokens[j + 1]) != nil {
                    values.append(tokens[j + 1]); j += 2
                }
                for k in i..<j { consumed[k] = true }
                return XChain(values: values, range: i..<j)
            }
            i += 1
        }
        return nil
    }

    /// Interpret a 2- or 3-number x-chain into (weight, sets, reps). The number
    /// carrying a unit — or, failing that, the one too large to be a count — is
    /// the weight; the remaining numbers are reps (earlier) and sets (later).
    private static func interpretXChain(_ values: [String], defaultUnit: WeightUnit)
        -> (weight: Double?, unit: WeightUnit?, setCount: Int?, reps: [Int]) {
        let parsed = values.map { weightToken($0) }
        let nums = parsed.map { $0?.weight ?? 0 }

        if values.count >= 3 {
            // Pick the weight slot: a unit'd number, else the first one > a plausible count.
            let weightIdx = parsed.firstIndex(where: { $0?.unit != nil })
                ?? nums.firstIndex(where: { $0 > Double(DeterministicParser.maxPlausibleSetCount) })
            if let wi = weightIdx {
                let others = values.indices.filter { $0 != wi }
                let repVal = Int(nums[others[0]])
                let setVal = Int(nums[others[1]])
                let reps = validReps(repVal) ? [repVal] : []
                return (nums[wi], parsed[wi]?.unit ?? defaultUnit,
                        (1...99).contains(setVal) ? setVal : nil, reps)
            }
            // All small, no unit ("5x5x5"): sets × reps, drop the genuinely
            // ambiguous third number.
            let setVal = Int(nums[0]); let repVal = Int(nums[1])
            return (nil, nil, (1...99).contains(setVal) ? setVal : nil,
                    validReps(repVal) ? [repVal] : [])
        }

        // Two numbers: "135x8" (weight×reps) vs "3x10" (sets×reps).
        let firstUnit = parsed[0]?.unit
        if firstUnit != nil || nums[0] > Double(DeterministicParser.maxPlausibleSetCount) {
            let repVal = Int(nums[1])
            return (nums[0], firstUnit ?? defaultUnit, nil, validReps(repVal) ? [repVal] : [])
        }
        let setVal = Int(nums[0]); let repVal = Int(nums[1])
        return (nil, nil, (1...99).contains(setVal) ? setVal : nil, validReps(repVal) ? [repVal] : [])
    }

    // MARK: - Token scanners

    /// First number that is a weight by evidence: a glued/spaced unit, or an "@"
    /// introducer. Consumes the number (and unit / "@").
    private static func findExplicitWeight(_ tokens: [String], consumed: inout [Bool],
                                           defaultUnit: WeightUnit) -> (weight: Double, unit: WeightUnit)? {
        for i in tokens.indices where !consumed[i] {
            guard let raw = weightToken(tokens[i]), !isBodyweightToken(tokens[i]) else { continue }
            // glued unit ("135lb")
            if let u = raw.unit { consumed[i] = true; return (raw.weight, u) }
            // spaced unit ("135 lb")
            if i + 1 < tokens.count, !consumed[i + 1], let u = unitKeyword(tokens[i + 1]) {
                consumed[i] = true; consumed[i + 1] = true; return (raw.weight, u)
            }
            // "@" introducer, glued or spaced
            if i > 0, tokens[i - 1] == "@" {
                consumed[i] = true; consumed[i - 1] = true; return (raw.weight, defaultUnit)
            }
        }
        return nil
    }

    /// A number directly followed by one of `words` ("3 set", "8 reps").
    private static func findCounted(_ tokens: [String], words: [String], consumed: inout [Bool]) -> Int? {
        for i in tokens.indices where !consumed[i] {
            guard i + 1 < tokens.count, words.contains(tokens[i + 1]), !consumed[i + 1] else { continue }
            guard let n = Int(tokens[i]) else { continue }
            consumed[i] = true; consumed[i + 1] = true
            return n
        }
        return nil
    }

    /// A run of leftover bare integers separated only by commas / "then" / "and"
    /// — a per-set rep list ("7,3", "7 then 3", "12, 10, 8"). Requires ≥1, all
    /// valid reps; consumes them. Returns [] when the leftovers aren't a clean list.
    private static func remainingNumberList(_ tokens: [String], consumed: inout [Bool],
                                            defaultUnit: WeightUnit) -> [Int] {
        var values: [Int] = []
        var indices: [Int] = []
        var sawSeparatorRun = false
        for i in tokens.indices where !consumed[i] {
            if let n = Int(tokens[i]) {
                // a separator between numbers, or contiguous, keeps the run going
                values.append(n); indices.append(i)
            } else if isRepListSeparator(tokens[i]) {
                if !values.isEmpty { sawSeparatorRun = true }
            } else if isFiller(tokens[i]) {
                continue   // "of them" between counts
            } else if values.isEmpty {
                continue   // still in the leading name span — skip name words
            } else {
                break      // a real word after the numbers ends the trailing run
            }
        }
        // One bare number with no separator is handled elsewhere (could be a
        // weight); only commit here for an actual list, or a single explicit rep.
        guard !values.isEmpty, values.allSatisfy(validReps) else { return [] }
        if values.count == 1 && !sawSeparatorRun { return [] }
        for idx in indices { consumed[idx] = true }
        return values
    }

    private static func lastBareNumber(_ tokens: [String], consumed: inout [Bool]) -> Double? {
        for i in tokens.indices.reversed() where !consumed[i] {
            if let raw = weightToken(tokens[i]), !isBodyweightToken(tokens[i]) {
                consumed[i] = true
                return raw.weight
            }
        }
        return nil
    }

    private static func cleanName(_ tokens: [String], consumed: [Bool]) -> String {
        let nameTokens = tokens.indices.filter { !consumed[$0] }.map { tokens[$0] }
            .filter { isNameWord($0) }
        return cleanExerciseName(nameTokens.joined(separator: " "))
    }

    // MARK: - Bodyweight heuristic (shared with TodayModel's strict-draft default)

    /// Spans that usually mean a bodyweight movement, so a load-less entry
    /// defaults to BW rather than "unspecified". Mirrors the strict parser's
    /// list and is the single source of truth the model reuses.
    static func likelyBodyweightExercise(_ name: String) -> Bool {
        let n = name.lowercased()
        let phrases = [
            "pull up", "pull-up", "pullup", "pull ups", "pullups",
            "chin up", "chin-up", "chinup", "chin ups", "chinups",
            "push up", "push-up", "pushup", "push ups", "pushups",
            "muscle up", "muscle-up",
            "air squat", "bodyweight squat", "pistol squat",
            "inverted row", "hanging leg raise", "leg raise",
            "sit up", "sit-up", "situp", "sit ups", "situps",
            "burpee", "burpees", "plank", "dip", "dips"
        ]
        if phrases.contains(where: { n.contains($0) }) { return true }
        let tokens = n.split(separator: " ").map(String.init)
        if tokens == ["dip"] || tokens == ["dips"] { return true }
        return false
    }

    // MARK: - Token helpers (parallel to DeterministicParser's private set)

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
        return out.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func cleanExerciseName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n,.;:!?-–—"))
        name = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return name
    }

    /// A token that should become part of the exercise name — alphabetic-ish and
    /// not a stray operator or filler word the user typed around the numbers.
    private static func isNameWord(_ token: String) -> Bool {
        if token == "x" || token == "@" || token == "," || token == "for" { return false }
        if isRepListSeparator(token) || isFiller(token) { return false }
        if ["set", "sets", "rep", "reps"].contains(token) { return false }
        if unitKeyword(token) != nil || isBodyweightToken(token) { return false }
        if token == "rpe" || token == "rir" { return false }
        // A pure number is never a name; a number-led alias word ("45" in "45
        // degree …") is kept because it carries a letter tail.
        if Int(token) != nil || Double(token) != nil { return false }
        return token.contains(where: { $0.isLetter })
    }

    private static func isRepListSeparator(_ token: String) -> Bool {
        token == "," || token == "then" || token == "and" || token == "&" || token == "+"
    }

    private static func isFiller(_ token: String) -> Bool {
        ["of", "them", "did", "got", "another", "more", "the", "a", "an", "with",
         "at", "plus", "each", "total"].contains(token)
    }

    private static func isBodyweightToken(_ token: String) -> Bool {
        token == "bw" || token == "bodyweight"
    }

    private static func weightToken(_ rawToken: String) -> (weight: Double, unit: WeightUnit?)? {
        // Tolerate chat punctuation stuck to a token ("60kg?", "135.") so a load
        // isn't lost to a stray "?" — commas are already their own token.
        let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ",;:?!"))
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

    private static func validReps(_ reps: Int) -> Bool { WorkoutValidator.repsRange.contains(reps) }
}
