import SwiftUI
import WidgetKit

/// The widget extension's entry point.
///
/// Reads only `widget-snapshot.json` from the App Group container and draws with the shared
/// design system in `VocabLoopShared/` — it never opens the SwiftData store, and it has no App
/// Intents (tapping opens the app through `vocabloop://` links instead).
@main
struct VocabLoopWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        MochiWidget()
        StudyLiveActivity()
    }
}
