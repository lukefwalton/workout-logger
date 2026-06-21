import Foundation

/// Pure, **FoundationModels-free** translation of a model's described workout into
/// the app's canonical types. It lives in always-compiled code on purpose: the
/// gated `FoundationWorkoutParser` extracts plain `String`/`Int`/`Double?` fields
/// from its `@Generable` response and hands them here, so the *defensive* logic —
/// the part most likely to have a bug — is unit-tested without importing
/// FoundationModels.
///
/// The governing rule (§"PR 8") is **all-or-nothing**: if any single set is
/// unreadable (unknown enum, out-of-range reps/RIR, bad unit), the whole entry
/// declines rather than silently dropping a set. Honest data over partial data.
enum ModelDraftMapping {

    /// Map one model-described set to a flat `SetDraft`, or `nil` if any field is
    /// unreadable. Caller treats `nil` as "decline the whole entry."
    static func setDraft(amount: Double?,
                         unit: String?,
                         loadKind: String,
                         reps: Int,
                         rir: Int?,
                         setType: String,
                         exerciseName: String,
                         sourceText: String?) -> SetDraft? {
        guard WorkoutValidator.repsRange.contains(reps) else { return nil }
        if let rir, !(0...10).contains(rir) { return nil }
        guard let kind = WorkoutLoadKind(rawValue: loadKind) else { return nil }
        guard let type = SetType(rawValue: setType) else { return nil }

        let resolvedUnit: WeightUnit
        if let unit, !unit.isEmpty {
            // A stated unit that isn't one we store is an unreadable field, not a
            // value to guess at — decline wholesale.
            guard let parsed = WeightUnit(rawValue: unit.lowercased()) else { return nil }
            resolvedUnit = parsed
        } else {
            resolvedUnit = .lb
        }

        let weight = amount ?? 0
        guard weight.isFinite, weight >= 0 else { return nil }

        // Same consistency fix the confirm card applies (`TodayModel.setWeight`):
        // an "external" load with no weight is an unspecified load until the user
        // fills it in — not a fabricated 0 lb. This is normalization, not invention.
        var resolvedKind = kind
        if resolvedKind == .external, weight == 0 { resolvedKind = .unspecified }

        return SetDraft(exerciseName: exerciseName,
                        weight: weight,
                        unit: resolvedUnit,
                        loadKind: resolvedKind,
                        reps: reps,
                        rir: rir,
                        setType: type,
                        notes: nil,
                        sourceText: sourceText)
    }

    /// Assemble a `WorkoutParseResult` from already-mapped sets. Returns `nil`
    /// (→ decline) when there are no sets or **any** set failed to map — the
    /// all-or-nothing rule. The exercise name is left as-is (possibly empty) so the
    /// confirm card can name a draft the way it already names a bare scheme.
    static func result(mappedSets: [SetDraft?],
                       source: ParseSource,
                       warning: String?) -> WorkoutParseResult? {
        guard !mappedSets.isEmpty else { return nil }
        let sets = mappedSets.compactMap { $0 }
        guard sets.count == mappedSets.count else { return nil }
        let cleaned = warning?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkoutParseResult(sets: sets,
                                  source: source,
                                  warning: (cleaned?.isEmpty ?? true) ? nil : cleaned)
    }

    /// Build a `ClarificationPrompt`, or `nil` (→ decline) when the question is
    /// empty. Blank replies are dropped and the list is capped at 3; the UI adds
    /// its own "Type it manually" button on top of whatever survives.
    static func clarification(message: String, replies: [String]) -> ClarificationPrompt? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = replies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ClarificationPrompt(message: trimmed, suggestedReplies: Array(cleaned.prefix(3)))
    }
}
