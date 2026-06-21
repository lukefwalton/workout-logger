import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Nudges the Home Screen widget to re-read the shared store after the app changes
/// session state (a save or a finish). Gated by `canImport` so the app still builds
/// where WidgetKit is absent; a no-op when no widget is installed.
enum WidgetRefresher {
    static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
