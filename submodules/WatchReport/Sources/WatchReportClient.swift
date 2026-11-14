public import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity

/// The phone's end of the watch link. Started at launch so the watch's background transfers are received even when
/// nobody sends a report; `fetch` is what "Send Report" calls.
public final class WatchReportClient: Sendable {
    public static let shared = WatchReportClient()

    private let session = WatchSessionDelegate()

    private init() {
    }

    public func start() {
        self.session.start()
    }

    /// What "Send Report" adds: the watch's files and a README line about the watch (none when there is no watch).
    public func fetch(timeout: TimeInterval = 6, completion: @escaping @Sendable (WatchReportResult) -> Void) {
        self.session.fetch(timeout: timeout, completion: completion)
    }
}

private final class WatchSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let store: WatchReportStore
    private let lock = NSLock()
    private var started = false

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.store = WatchReportStore(directory: base.appendingPathComponent("nanogram-watch-report", isDirectory: true))
        super.init()
    }

    func start() {
        self.lock.lock()
        let shouldStart = !self.started
        self.started = true
        self.lock.unlock()
        guard shouldStart, WCSession.isSupported() else {
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func fetch(timeout: TimeInterval, completion: @escaping @Sendable (WatchReportResult) -> Void) {
        self.start()
        let finish = Once(completion)
        guard WCSession.isSupported() else {
            finish.call(WatchReportResult(choice: .none, link: .noPairedWatch))
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else {
            finish.call(WatchReportResult(choice: .none, link: .noPairedWatch))
            return
        }
        guard session.isWatchAppInstalled else {
            finish.call(WatchReportResult(choice: .none, link: .appNotInstalled))
            return
        }
        let store = self.store
        let fallback: @Sendable () -> Void = {
            let stored = store.load()
            finish.call(WatchReportResult(choice: watchReportChoose(live: nil, stored: stored), link: stored == nil ? .unreachableNoCopy : .unreachable))
        }
        guard session.isReachable else {
            fallback()
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            fallback()
        }
        session.sendMessage([WatchReportMessage.requestKey: true], replyHandler: { reply in
            if let data = reply[WatchReportMessage.payloadKey] as? Data, let payload = WatchReportPayload.decode(data) {
                store.save(data)
                finish.call(WatchReportResult(choice: .live(payload), link: .reachable))
            } else {
                fallback()
            }
        }, errorHandler: { _ in
            fallback()
        })
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?[WatchReportMessage.fileMarkerKey] != nil, let data = try? Data(contentsOf: file.fileURL) else {
            return
        }
        self.store.save(data)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo[WatchReportMessage.payloadKey] as? Data {
            self.store.save(data)
        }
    }
}

/// Calls its completion once, whichever of the reply, the failure and the timeout comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (WatchReportResult) -> Void)?

    init(_ completion: @escaping @Sendable (WatchReportResult) -> Void) {
        self.completion = completion
    }

    func call(_ result: WatchReportResult) {
        self.lock.lock()
        let completion = self.completion
        self.completion = nil
        self.lock.unlock()
        completion?(result)
    }
}
#endif

/// What the phone got from the watch and why.
public struct WatchReportResult: Sendable {
    public var files: [WatchReportFile]
    /// The line for the README.
    public var statusLine: String
    public var created: Date?

    init(choice: WatchReportChoice, link: WatchLinkState) {
        self.statusLine = watchReportStatusLine(choice, link: link)
        switch choice {
        case let .live(payload), let .stored(payload):
            self.files = payload.files
            self.created = payload.created
        case .none:
            self.files = []
            self.created = nil
        }
    }
}
