import SwiftUI
import WidgetKit

/// Nanogram's watch widget extension (IOS-WATCH-WIDGET-1). Not part of the default build: it is generated only into
/// the widget variant project (`project-widget.yml`, see OWNER-STEPS.md) because it needs a new App ID, a profile and
/// an App Group in the developer portal.
@main
struct WatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        UnreadWidget()
    }
}
