import Foundation

/// Pure tokenizer for the Today tab input line. Splits it into a leading
/// "name span" (everything up to the first character that looks like the
/// start of the numeric/operator core) and the rest. The name span is what
/// fuzzy autocomplete searches against; `applyInputSuggestion` rewrites it
/// without touching the trailing spec (`135x8`).
///
/// Lives outside `TodayModel` so it's testable in isolation and so the model
/// stops growing static helpers that have nothing to do with its observable
/// state.
enum TodayInputTokenizer {
    /// The leading "name span" of an input line: everything up to (but not
    /// including) the first character that looks like the start of the
    /// numeric/operator core (`@`, digit, or an `x`/`for` token boundary —
    /// including glued forms like `x12`). Returns the trimmed, whitespace-
    /// normalized prefix used for the fuzzy autocomplete lookup. Empty when
    /// the line opens with a number.
    static func leadingNamePrefix(_ raw: String) -> String {
        let endIndex = leadingNamePrefixEndIndex(in: raw)
        return raw[..<endIndex]
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The `String.Index` in `raw` where the leading name span ends — i.e.
    /// where the numeric/operator core would start. `applyInputSuggestion`
    /// uses this directly (not a normalized substring length) so the rewrite
    /// can't desync from the original whitespace. A token starting with a
    /// digit, `@`, or an `x` followed by a digit (`x12`) — or a standalone
    /// `"x"`, `"for"`, `","` — closes the name span.
    static func leadingNamePrefixEndIndex(in raw: String) -> String.Index {
        var index = raw.startIndex
        var lastNameTokenEnd = raw.startIndex
        while index < raw.endIndex {
            while index < raw.endIndex, raw[index].isWhitespace {
                index = raw.index(after: index)
            }
            guard index < raw.endIndex else { break }
            let tokenStart = index
            while index < raw.endIndex, !raw[index].isWhitespace {
                index = raw.index(after: index)
            }
            let token = raw[tokenStart..<index]
            if isCoreBoundaryToken(token) { return tokenStart }
            lastNameTokenEnd = index
        }
        return lastNameTokenEnd
    }

    /// Whether `token` starts the numeric/operator core, ending the name
    /// span. Catches the audit's `bench x12` regression: a glued `x<digit>`
    /// is just as much a core token as the standalone `x`.
    private static func isCoreBoundaryToken(_ token: Substring) -> Bool {
        guard let first = token.first else { return false }
        if first.isNumber || first == "@" { return true }
        let lower = token.lowercased()
        if lower == "x" || lower == "for" || lower == "," { return true }
        // Glued `x<digit>` — `x12`, `x8x3` — the parser treats this as
        // shorthand for "× <reps>", so autocomplete must stop here.
        if first == "x" || first == "X" {
            let rest = token.dropFirst()
            return rest.first?.isNumber == true
        }
        return false
    }
}
