import SwiftUI
import LFWDesignSystem

/// App-side alias for the shared family palette. Every color here forwards to
/// `LFWDesignSystem.LFWColors` so the workout app stays in lockstep with the
/// other apps in the family; only add a new key here if it's genuinely
/// workout-specific.
///
/// Compiled into the `WorkoutChatLog` app target only — the
/// `WorkoutWidgetExtension` target's `sources:` are `WorkoutWidget` +
/// `WorkoutChatLog/Shared` + `WorkoutChatLog/Storage/SQLiteDB.swift`, none of
/// which contain `App/`, so the widget never sees this file or its
/// `import LFWDesignSystem`.
enum Theme {
    static let deepSea = LFWColors.deepSea
    static let ocean = LFWColors.ocean
    static let traveler = LFWColors.traveler
    static let nebula = LFWColors.nebula
    static let kelp = LFWColors.kelp
    static let gold = LFWColors.gold
    static let steel = LFWColors.steel
    static let paper = LFWColors.paper
    static let ink = LFWColors.ink

    /// App-wide accent.
    static let tint = LFWColors.tint
}
