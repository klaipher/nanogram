#if arch(arm64) || arch(x86_64)

import SwiftUI
import WidgetKit
import AppIntents
import AppLockState
import WidgetItems
import NanogramGlance
import NanogramAppIntents

private final class ResumeOnce<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    
    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }
    
    func resume(_ value: T) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: value)
    }
}

@available(iOS 17.0, *)
private func peersAsync(identifiers: [String], environment: WidgetExtensionEnvironment) async -> ParsedPeers {
    if identifiers.isEmpty {
        return ParsedPeers(peers: [], updateTimestamp: Int32(clamping: Int(Date().timeIntervalSince1970)))
    }
    return await withCheckedContinuation { (continuation: CheckedContinuation<ParsedPeers, Never>) in
        let once = ResumeOnce(continuation)
        loadWidgetPeers(identifiers: identifiers, environment: environment, completion: { once.resume($0) })
    }
}

private func glanceLockPhase(_ schedule: AppLockSchedule) -> GlanceLockPhase {
    switch schedule {
    case .unlocked:
        return .unlocked
    case .locked:
        return .locked
    case let .locksIn(seconds):
        return .locksIn(seconds)
    }
}

@available(iOS 17.0, *)
struct GlanceChatsEntry: TimelineEntry {
    let date: Date
    let isEnabled: Bool
    let isLocked: Bool
    let displayNameOnLockscreen: Bool
    let peers: [ParsedPeer]
}

@available(iOS 17.0, *)
struct GlanceChatsProvider: AppIntentTimelineProvider {
    typealias Intent = SelectChatsIntent
    typealias Entry = GlanceChatsEntry
    
    func placeholder(in context: Context) -> GlanceChatsEntry {
        return GlanceChatsEntry(date: Date(), isEnabled: true, isLocked: false, displayNameOnLockscreen: true, peers: [])
    }
    
    func snapshot(for configuration: SelectChatsIntent, in context: Context) async -> GlanceChatsEntry {
        if context.isPreview {
            return self.placeholder(in: context)
        }
        return await self.timeline(for: configuration, in: context).entries.first ?? self.placeholder(in: context)
    }
    
    func timeline(for configuration: SelectChatsIntent, in context: Context) async -> Timeline<GlanceChatsEntry> {
        let now = Date()
        guard let environment = WidgetExtensionEnvironment.shared else {
            return Timeline(entries: [GlanceChatsEntry(date: now, isEnabled: false, isLocked: false, displayNameOnLockscreen: false, peers: [])], policy: .after(now.addingTimeInterval(30.0 * 60.0)))
        }
        let snapshot = GlanceStore.read(rootPath: environment.rootPath)
        guard let snapshot, snapshot.enabled else {
            return Timeline(entries: [GlanceChatsEntry(date: now, isEnabled: false, isLocked: false, displayNameOnLockscreen: false, peers: [])], policy: .after(now.addingTimeInterval(30.0 * 60.0)))
        }
        let schedule = appLockSchedule(state: readAppLockState(rootPath: environment.rootPath), now: currentMonotonicTimestamp())
        let identifiers = (configuration.chats ?? []).map { $0.id }
        let parsed = await peersAsync(identifiers: identifiers, environment: environment)
        let entries = GlanceTimeline.steps(lock: glanceLockPhase(schedule)).map { step in
            return GlanceChatsEntry(date: now.addingTimeInterval(Double(step.offsetSeconds)), isEnabled: true, isLocked: step.isLocked, displayNameOnLockscreen: snapshot.displayNameOnLockscreen, peers: parsed.peers)
        }
        return Timeline(entries: entries, policy: widgetTimelinePolicy(now: now))
    }
}

@available(iOS 17.0, *)
struct GlanceChatsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceChatsEntry
    let presentationData: WidgetPresentationData
    
    private var surface: GlanceSurface {
        switch self.family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            return .lockScreen
        default:
            return .homeScreen
        }
    }
    
    private var showsNames: Bool {
        return GlanceVisibility.showsNames(surface: self.surface, lock: self.entry.isLocked ? .locked : .unlocked, displayNameOnLockscreen: self.entry.displayNameOnLockscreen)
    }
    
    private var totalUnread: Int {
        return GlanceCount.total(self.entry.peers.map { peer -> (count: Int, isMuted: Bool) in
            return (peer.peer.badge?.count ?? 0, peer.peer.badge?.isMuted ?? false)
        })
    }
    
    private func name(of peer: ParsedPeer) -> String {
        if peer.accountPeerId == peer.peer.id {
            return self.presentationData.chatSavedMessages
        }
        var result = peer.peer.name
        if let lastName = peer.peer.lastName {
            result.append(" \(lastName)")
        }
        return result
    }
    
    private var title: String {
        let names = self.entry.peers.prefix(2).map { self.name(of: $0) }.joined(separator: ", ")
        return GlanceVisibility.title(name: names, genericTitle: self.presentationData.widgetChatsGalleryTitle, showsNames: self.showsNames)
    }
    
    private func avatar(_ peer: ParsedPeer) -> some View {
        return AvatarItemView(peer: peer, itemSize: 54.0, placeholderColor: .secondary)
            .overlay(alignment: .topTrailing) {
                if let badge = peer.peer.badge, badge.count > 0 {
                    Text(GlanceCount.text(badge.count))
                        .font(.system(size: 11.0, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5.0)
                        .frame(minWidth: 18.0, minHeight: 18.0)
                        .background(Capsule().fill(badge.isMuted ? Color.gray : Color.blue))
                        .offset(x: 6.0, y: -4.0)
                }
            }
    }
    
    @ViewBuilder
    private var small: some View {
        let shown = Array(self.entry.peers.prefix(4))
        if self.showsNames && !shown.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10.0) {
                ForEach(0 ..< shown.count, id: \.self) { index in
                    self.avatar(shown[index])
                }
            }
        } else {
            VStack(spacing: 6.0) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 30.0))
                    .foregroundColor(.blue)
                if self.entry.peers.isEmpty {
                    Text(self.presentationData.widgetLongTapToEdit)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                } else {
                    Text(self.totalUnread > 0 ? GlanceCount.text(self.totalUnread) : self.presentationData.widgetChatsGalleryTitle)
                        .font(.title2.weight(.semibold))
                }
            }
        }
    }
    
    @ViewBuilder
    private var content: some View {
        if !self.entry.isEnabled {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title2)
        } else {
            switch self.family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0.0) {
                        Image(systemName: "message.fill")
                            .font(.caption)
                        Text(GlanceCount.text(self.totalUnread))
                            .font(.headline)
                            .minimumScaleFactor(0.6)
                    }
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2.0) {
                    Text(self.title)
                        .font(.headline)
                        .lineLimit(1)
                    Label(GlanceCount.text(self.totalUnread), systemImage: "message.fill")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryInline:
                Text("\(self.title) · \(GlanceCount.text(self.totalUnread))")
            default:
                self.small
            }
        }
    }
    
    var body: some View {
        self.content
            .widgetURL(URL(string: "\(buildConfig.appSpecificUrlScheme)://"))
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

@available(iOS 17.0, *)
struct GlanceChatsWidget: Widget {
    private let kind: String = "Nanogram_GlanceChats"
    
    var body: some WidgetConfiguration {
        let presentationData = WidgetPresentationData.getForExtension()
        return AppIntentConfiguration(kind: self.kind, intent: SelectChatsIntent.self, provider: GlanceChatsProvider(), content: { entry in
            GlanceChatsView(entry: entry, presentationData: presentationData)
        })
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .configurationDisplayName(presentationData.widgetChatsGalleryTitle)
        .description(presentationData.widgetChatsGalleryDescription)
        .contentMarginsDisabled()
    }
}

#endif
