import Foundation
import UIKit

/// Nanogram: remembers which widget sources were running when the app last went down without ending them, so a source
/// that crashed the process (a trap in the hardened C++ runtime, say) is not run again by the next launch, which would
/// crash again each time the chat opens.
///
/// A widget that boots is noted (`begin`) in a small file before it runs and noted again when it ends (`end`); the file
/// holds the sources running now. A launch that finds sources in the file moves them to the blocked list: the
/// registry then makes a blocked source's widget start stopped, which draws the static "Widget stopped" badge and runs
/// no script. Blocked sources are kept for `blockLifetime` and at most `maximumBlocked` of them.
///
/// While the app is in the background the running list is empty in the file, so a process the user ends from the app
/// switcher, or the system ends, is not taken for a crash; it is written again when the app comes back. An end in the
/// foreground that is not a crash (the system's memory kill) blocks the sources that were showing; the Debug switch for
/// message widgets forgets the blocked sources (`clearBlocked`).
///
/// Sources are told apart by a 64-bit FNV-1a hash of their UTF-8, stable across launches (Swift's `hashValue` is not).
public final class MessageWidgetCrashSentinel {
    public static let blockLifetime: TimeInterval = 7.0 * 24.0 * 3600.0
    public static let maximumBlocked = 64

    public static let shared = MessageWidgetCrashSentinel(url: MessageWidgetCrashSentinel.defaultURL, observesApplication: true)

    private struct Stored: Codable {
        var running: [String] = []
        var blocked: [String: Double] = [:]
    }

    private let lock = NSLock()
    private let url: URL?
    private let now: () -> Date
    /// Widgets running now per source hash (two bubbles can show one source).
    private var counts: [String: Int] = [:]
    private var blocked: [String: Double] = [:]
    private var inBackground = false
    private var observers: [NSObjectProtocol] = []

    /// `url` is the sentinel's file; nil keeps everything in memory. A file left by the last launch is read here: what it
    /// lists as running is blocked from now on.
    public init(url: URL?, now: @escaping () -> Date = { Date() }, observesApplication: Bool = false) {
        self.url = url
        self.now = now
        if let url, let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            self.blocked = stored.blocked
            let stamp = now().timeIntervalSince1970
            for hash in stored.running {
                self.blocked[hash] = stamp
            }
            self.prune()
            self.persist()
        }
        if observesApplication {
            self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.setInBackground(true)
            }))
            self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.setInBackground(false)
            }))
        }
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public static var defaultURL: URL? {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("message-widget-sentinel.json")
    }

    /// A stable 16-digit hex hash of `source`.
    public static func hash(of source: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in source.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    /// Whether `source` was running when the app went down without ending it, and is still within its blocked time.
    public func isBlocked(source: String) -> Bool {
        let hash = MessageWidgetCrashSentinel.hash(of: source)
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let stamp = self.blocked[hash] else {
            return false
        }
        return self.now().timeIntervalSince1970 - stamp < MessageWidgetCrashSentinel.blockLifetime
    }

    /// A widget of `source` is about to run.
    public func begin(source: String) {
        let hash = MessageWidgetCrashSentinel.hash(of: source)
        self.lock.lock()
        let count = (self.counts[hash] ?? 0) + 1
        self.counts[hash] = count
        if count == 1 {
            self.persist()
        }
        self.lock.unlock()
    }

    /// A widget of `source` that `begin` noted has ended.
    public func end(source: String) {
        let hash = MessageWidgetCrashSentinel.hash(of: source)
        self.lock.lock()
        if let count = self.counts[hash] {
            if count <= 1 {
                self.counts.removeValue(forKey: hash)
                self.persist()
            } else {
                self.counts[hash] = count - 1
            }
        }
        self.lock.unlock()
    }

    /// Forgets every blocked source (the Debug switch for message widgets does when it is turned on).
    public func clearBlocked() {
        self.lock.lock()
        self.blocked.removeAll()
        self.persist()
        self.lock.unlock()
    }

    /// The hashes blocked now, for tests and the Debug screen.
    public var blockedHashes: Set<String> {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return Set(self.blocked.keys)
    }

    private func setInBackground(_ inBackground: Bool) {
        self.lock.lock()
        if self.inBackground != inBackground {
            self.inBackground = inBackground
            self.persist()
        }
        self.lock.unlock()
    }

    /// Drops the expired and, past `maximumBlocked`, the oldest.
    private func prune() {
        let current = self.now().timeIntervalSince1970
        self.blocked = self.blocked.filter { current - $0.value < MessageWidgetCrashSentinel.blockLifetime }
        if self.blocked.count > MessageWidgetCrashSentinel.maximumBlocked {
            let keep = self.blocked.sorted { $0.value > $1.value }.prefix(MessageWidgetCrashSentinel.maximumBlocked)
            self.blocked = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    /// Writes the file; the caller holds the lock (or is the initializer). The running list is empty in the background.
    private func persist() {
        guard let url = self.url else {
            return
        }
        let stored = Stored(running: self.inBackground ? [] : Array(self.counts.keys).sorted(), blocked: self.blocked)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
