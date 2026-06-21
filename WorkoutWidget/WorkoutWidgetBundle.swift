import WidgetKit
import SwiftUI

/// The widget extension's entry point. One widget for now; a `WidgetBundle` leaves
/// room to add more (e.g. a weekly-volume widget) without restructuring.
@main
struct WorkoutWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkoutWidget()
    }
}
