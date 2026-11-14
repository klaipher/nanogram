#if arch(arm64) || arch(x86_64)

import SwiftUI
import WidgetKit
import AppIntents
import ActivityKit
import NanogramGlance
import NanogramAppIntents

private func iconName(_ kind: GlanceActivityKind) -> String {
    switch kind {
    case .liveLocation:
        return "location.fill"
    case .call:
        return "phone.fill"
    }
}

private struct GlanceStopButton: View {
    let attributes: NanogramGlanceActivityAttributes
    
    @ViewBuilder
    var body: some View {
        switch self.attributes.kind {
        case .liveLocation:
            Button(intent: StopLiveLocationIntent(accountId: self.attributes.accountId, peerId: self.attributes.peerId)) {
                Text(self.attributes.stopLabel)
            }
        case .call:
            Button(intent: EndCallIntent()) {
                Text(self.attributes.stopLabel)
            }
        }
    }
}

private struct GlanceActivityBanner: View {
    let attributes: NanogramGlanceActivityAttributes
    let state: NanogramGlanceActivityAttributes.ContentState
    
    var body: some View {
        HStack(spacing: 12.0) {
            Image(systemName: iconName(self.attributes.kind))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2.0) {
                Text(self.state.headline)
                    .font(.headline)
                    .lineLimit(1)
                Text(self.state.status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            GlanceStopButton(attributes: self.attributes)
        }
        .padding(16.0)
    }
}

struct GlanceActivityWidget: Widget {
    var body: some WidgetConfiguration {
        return ActivityConfiguration(for: NanogramGlanceActivityAttributes.self) { context in
            GlanceActivityBanner(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: iconName(context.attributes.kind))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.status)
                            .lineLimit(1)
                        Spacer()
                        GlanceStopButton(attributes: context.attributes)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(context.attributes.kind))
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .frame(maxWidth: 52.0)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: iconName(context.attributes.kind))
            }
        }
    }
}

#endif
