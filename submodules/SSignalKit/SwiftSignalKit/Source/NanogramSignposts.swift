import Foundation
import os

/// A signpost interval a person would name ("open a chat", "launch to chat list"). It is emitted twice, in category
/// `Performance` and in `.pointsOfInterest`, so it shows in every Instruments template and gives Run Comparisons a
/// range. At most 6 exist; both apps (iOS and macOS) emit exactly these names.
public struct UserSignpost: Sendable {
    public let name: StaticString

    public init(_ name: StaticString) {
        self.name = name
    }

    /// Launch (process start in `didFinishLaunching`) until the chat list is ready and drawn.
    public static let launchToChatListReady = UserSignpost("launchToChatListReady")
    /// Tap on a chat until the first messages are drawn.
    public static let chatOpenToReady = UserSignpost("chatOpenToReady")
    /// A navigation push until the pushed screen is ready (macOS) or the push has completed (iOS).
    public static let navigationPushToReady = UserSignpost("navigationPushToReady")
    /// A chat list is created until its first rows are applied.
    public static let chatListFirstFrame = UserSignpost("chatListFirstFrame")
    /// A chat folder is selected until its list is applied.
    public static let chatListFolderSwitch = UserSignpost("chatListFolderSwitch")
    /// Outgoing call tap or incoming answer until the call is connected.
    public static let callConnect = UserSignpost("callConnect")

    public static let all: [UserSignpost] = [
        .launchToChatListReady,
        .chatOpenToReady,
        .navigationPushToReady,
        .chatListFirstFrame,
        .chatListFolderSwitch,
        .callConnect
    ]
}

/// Names of the hot-path intervals that stay in category `Performance` only (they can run per frame or per keystroke).
public enum PerformanceSignpostName {
    public static let chatHistoryEntriesForView: StaticString = "chatHistoryEntriesForView"
    public static let chatListPrepareEntries: StaticString = "chatListPrepareEntries"
    public static let composerKeystroke: StaticString = "composerKeystroke"
    public static let composerTextDidChange: StaticString = "composerTextDidChange"
    public static let tableMerge: StaticString = "tableMerge"
    public static let lottieRenderFrame: StaticString = "lottieRenderFrame"
    /// One pass of the time-based cache cleanup over the cached files (once a day at most).
    public static let cacheCleanupScan: StaticString = "cacheCleanupScan"
    /// One run of the automatic cache eviction over the stored resources of an account (once a day at most).
    public static let automaticCacheEviction: StaticString = "automaticCacheEviction"
    /// One batch of cache file touches (a `stat` per file and a `utime` for the stale ones).
    public static let cacheTouchBatch: StaticString = "cacheTouchBatch"
    /// A ChatController is created / deallocated (macOS; unmatched creations show a leak). Events.
    public static let chatControllerCreated: StaticString = "chatControllerCreated"
    public static let chatControllerDeinit: StaticString = "chatControllerDeinit"
    /// One scroll tick of a table view (macOS). Interval.
    public static let panelScrollTick: StaticString = "panelScrollTick"
    /// One dispatch of a mouse-moved event through the responder tree (macOS). Interval.
    public static let mouseMovedDispatch: StaticString = "mouseMovedDispatch"
    /// A modal is requested until its first committed frame (macOS). Interval.
    public static let modalOpenToVisible: StaticString = "modalOpenToVisible"
    /// Launch until the chat list is usable, i.e. committed to the screen. Interval.
    public static let launchToChatListUsable: StaticString = "launchToChatListUsable"
    /// The app becomes active again until the first committed frame. Interval.
    public static let resumeToFirstFrame: StaticString = "resumeToFirstFrame"
    /// The replay of skipped frames after a hardware VP9 session is resumed. Interval.
    public static let vp9ResumeCatchUp: StaticString = "vp9ResumeCatchUp"
    /// A media box file had to be opened again after its handle was evicted. Event.
    public static let mediaBoxReopen: StaticString = "mediaBoxReopen"
    /// A chat list row is tapped, before the open is dispatched (iOS). Event.
    public static let chatListRowTap: StaticString = "chatListRowTap"
    /// A view controller push starts (iOS and macOS, `NavigationController.pushViewController`). Event.
    public static let navigationPush: StaticString = "navigationPush"
    /// The first history transition with messages is applied in a chat. Event.
    public static let historyFirstContent: StaticString = "historyFirstContent"
}

/// Signposts shared by the iOS and macOS apps: subsystem = the bundle id, category `Performance`, plus a
/// `.pointsOfInterest` signposter for the `UserSignpost` intervals.
///
/// Rules: names are `StaticString`; begin and end on the same signposter; never put names, text or other personal
/// data in metadata (this API has none; counts and hashed ids would be the most that is allowed). When nothing records,
/// an interval costs one enabled check per signposter.
public enum NanogramSignposts {
    public static let category = "Performance"

    private static let subsystem = Bundle.main.bundleIdentifier ?? "Telegram"

    @available(macOS 12.0, iOS 15.0, *)
    private static let performanceSignposter = OSSignposter(subsystem: NanogramSignposts.subsystem, category: NanogramSignposts.category)

    @available(macOS 12.0, iOS 15.0, *)
    private static let pointsOfInterestSignposter = OSSignposter(logHandle: OSLog(subsystem: NanogramSignposts.subsystem, category: .pointsOfInterest))

    public struct State {
        fileprivate let name: StaticString
        fileprivate let performance: Any?
        fileprivate let pointsOfInterest: Any?
    }

    private static func begin(_ name: StaticString, userLevel: Bool) -> State {
        if #available(macOS 12.0, iOS 15.0, *) {
            var performance: Any?
            var pointsOfInterest: Any?
            let signposter = NanogramSignposts.performanceSignposter
            if signposter.isEnabled {
                performance = signposter.beginInterval(name)
            }
            if userLevel {
                let userSignposter = NanogramSignposts.pointsOfInterestSignposter
                if userSignposter.isEnabled {
                    pointsOfInterest = userSignposter.beginInterval(name)
                }
            }
            return State(name: name, performance: performance, pointsOfInterest: pointsOfInterest)
        } else {
            return State(name: name, performance: nil, pointsOfInterest: nil)
        }
    }

    public static func begin(_ name: StaticString) -> State {
        return NanogramSignposts.begin(name, userLevel: false)
    }

    public static func begin(_ signpost: UserSignpost) -> State {
        return NanogramSignposts.begin(signpost.name, userLevel: true)
    }

    public static func end(_ name: StaticString, _ state: State) {
        if #available(macOS 12.0, iOS 15.0, *) {
            if let value = state.performance as? OSSignpostIntervalState {
                NanogramSignposts.performanceSignposter.endInterval(state.name, value)
            }
            if let value = state.pointsOfInterest as? OSSignpostIntervalState {
                NanogramSignposts.pointsOfInterestSignposter.endInterval(state.name, value)
            }
        }
    }

    public static func end(_ signpost: UserSignpost, _ state: State) {
        NanogramSignposts.end(signpost.name, state)
    }

    /// A point event in category `Performance`. No metadata.
    public static func event(_ name: StaticString) {
        if #available(macOS 12.0, iOS 15.0, *) {
            let signposter = NanogramSignposts.performanceSignposter
            if signposter.isEnabled {
                signposter.emitEvent(name)
            }
        }
    }

    @inline(__always)
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = NanogramSignposts.begin(name)
        defer {
            NanogramSignposts.end(name, state)
        }
        return try body()
    }

    @inline(__always)
    public static func interval<T>(_ signpost: UserSignpost, _ body: () throws -> T) rethrows -> T {
        let state = NanogramSignposts.begin(signpost)
        defer {
            NanogramSignposts.end(signpost, state)
        }
        return try body()
    }

    /// An interval that is ended once from any thread, by whoever finishes the work.
    public final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private let name: StaticString
        private var state: State?

        public init(_ name: StaticString) {
            self.name = name
            self.state = NanogramSignposts.begin(name)
        }

        public init(_ signpost: UserSignpost) {
            self.name = signpost.name
            self.state = NanogramSignposts.begin(signpost)
        }

        public func end() {
            self.lock.lock()
            let current = self.state
            self.state = nil
            self.lock.unlock()
            if let current {
                NanogramSignposts.end(self.name, current)
            }
        }
    }

    private static let pendingLock = NSLock()
    // Guarded by pendingLock.
    nonisolated(unsafe) private static var pending: [String: OneShot] = [:]

    /// Begins a user-level interval whose start and end are in different places that share no object (a tap in one
    /// module, the first drawn frame in another). One interval per name is open at a time: beginning again closes the
    /// previous one, `endPending` without a begin does nothing.
    public static func beginPending(_ signpost: UserSignpost) {
        let key = "\(signpost.name)"
        let shot = OneShot(signpost)
        NanogramSignposts.pendingLock.lock()
        let previous = NanogramSignposts.pending.updateValue(shot, forKey: key)
        NanogramSignposts.pendingLock.unlock()
        previous?.end()
    }

    public static func endPending(_ signpost: UserSignpost) {
        let key = "\(signpost.name)"
        NanogramSignposts.pendingLock.lock()
        let shot = NanogramSignposts.pending.removeValue(forKey: key)
        NanogramSignposts.pendingLock.unlock()
        shot?.end()
    }

    public static func hasPending(_ signpost: UserSignpost) -> Bool {
        NanogramSignposts.pendingLock.lock()
        defer {
            NanogramSignposts.pendingLock.unlock()
        }
        return NanogramSignposts.pending["\(signpost.name)"] != nil
    }
}
