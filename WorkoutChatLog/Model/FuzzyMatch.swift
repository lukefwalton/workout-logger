import Foundation

/// Deterministic fuzzy string similarity — Layer 2 of the resolution stack
/// (§1.1). Jaro-Winkler handles short typos ("bnch"→"bench"); a token average
/// handles multi-word names and a short query matching one word of a longer name
/// ("dops"→the "dip" in "Chest Dip"). Combined generously on purpose: nothing
/// here auto-applies — it only *proposes* candidates a human confirms.
///
/// Pure and unit-tested; the threshold lives with the suggester, calibrated so
/// real typos surface and garbage ("asdfqwer") returns nothing.
enum FuzzyMatch {
    /// 0…1 similarity of a query to one candidate string.
    static func similarity(_ query: String, _ candidate: String) -> Double {
        max(jaroWinkler(normalize(query), normalize(candidate)), tokenSimilarity(query, candidate))
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Average over query tokens of the best Jaro-Winkler match among candidate
    /// tokens.
    static func tokenSimilarity(_ query: String, _ candidate: String) -> Double {
        let queryTokens = tokens(query), candidateTokens = tokens(candidate)
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }
        let total = queryTokens.reduce(0.0) { sum, q in
            sum + (candidateTokens.map { jaroWinkler(q, $0) }.max() ?? 0)
        }
        return total / Double(queryTokens.count)
    }

    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let j = jaro(a, b)
        var prefix = 0
        for (x, y) in zip(a, b) {
            if x == y && prefix < 4 { prefix += 1 } else { break }
        }
        return j + Double(prefix) * 0.1 * (1 - j)
    }

    static func jaro(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let s1 = Array(a), s2 = Array(b)
        if s1.isEmpty || s2.isEmpty { return 0 }
        let matchDistance = max(max(s1.count, s2.count) / 2 - 1, 0)
        var s1Matched = [Bool](repeating: false, count: s1.count)
        var s2Matched = [Bool](repeating: false, count: s2.count)
        var matches = 0
        for i in s1.indices {
            let lo = max(0, i - matchDistance)
            let hi = min(i + matchDistance + 1, s2.count)
            var j = lo
            while j < hi {
                if !s2Matched[j], s2[j] == s1[i] {
                    s1Matched[i] = true; s2Matched[j] = true; matches += 1; break
                }
                j += 1
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0, k = 0
        for i in s1.indices where s1Matched[i] {
            while !s2Matched[k] { k += 1 }
            if s1[i] != s2[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let halfTranspositions = Double(transpositions) / 2.0
        return (m / Double(s1.count) + m / Double(s2.count) + (m - halfTranspositions) / m) / 3
    }
}

/// A proposed canonical for an unrecognized token (resolution Layer ≥ 2). It
/// *proposes* — the user confirms; it never auto-applies, and it never merges two
/// distinct canonicals (§1.1). `familyKey` lets the UI group variants of the same
/// family together for the choice.
struct ExerciseSuggestion: Equatable, Identifiable {
    let exerciseID: Int64
    let canonicalName: String
    let familyKey: String?
    let score: Double
    let via: Via

    enum Via: String, Equatable { case fuzzy, semantic }

    var id: Int64 { exerciseID }
}
