#if arch(arm64) || arch(x86_64)

import SwiftUI
import WidgetKit
import AppIntents
import NanogramGlance
import NanogramAppIntents

struct SavedMessagesControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        return StaticControlConfiguration(kind: "Nanogram_SavedMessagesControl") {
            ControlWidgetButton(action: OpenSavedMessagesIntent()) {
                Label("Saved Messages", systemImage: "bookmark.fill")
            }
        }
        .displayName("Saved Messages")
        .description("Opens your Saved Messages in Nanogram.")
    }
}

#endif
