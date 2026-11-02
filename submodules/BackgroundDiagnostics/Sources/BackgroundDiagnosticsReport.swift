/// One line about what the app still holds a few seconds after entering the background, for the log file: why the
/// process may not suspend (background tasks, an active audio session, running display links) and what memory it
/// keeps (footprint by kind, and the caches the app can measure). Nothing is uploaded.
public struct BackgroundDiagnosticsReport: Sendable, Equatable {
    /// Seconds since the app entered the background when the report was taken. Much more than the scheduled delay
    /// means the process was suspended in between, which answers the suspension question by itself.
    public var secondsInBackground: Double
    public var memory: ProcessMemory?
    /// `UIApplication.backgroundTimeRemaining`; very large while the app holds no background time.
    public var backgroundTimeRemaining: Double
    /// Names of the app's own background tasks still held.
    public var backgroundTasks: [String]
    public var audioSessionActive: Bool
    public var displayLinks: DisplayLinkCounts?
    /// Named cache sizes, in the order given; a nil size means the cache cannot measure itself.
    public var caches: [CacheSize]

    public struct CacheSize: Sendable, Equatable {
        public var name: String
        public var bytes: UInt64?

        public init(name: String, bytes: UInt64?) {
            self.name = name
            self.bytes = bytes
        }
    }

    public struct DisplayLinkCounts: Sendable, Equatable {
        public var registered: Int
        public var running: Int
        public var driverRunning: Bool

        public init(registered: Int, running: Int, driverRunning: Bool) {
            self.registered = registered
            self.running = running
            self.driverRunning = driverRunning
        }
    }

    public init(secondsInBackground: Double, memory: ProcessMemory?, backgroundTimeRemaining: Double, backgroundTasks: [String], audioSessionActive: Bool, displayLinks: DisplayLinkCounts?, caches: [CacheSize]) {
        self.secondsInBackground = secondsInBackground
        self.memory = memory
        self.backgroundTimeRemaining = backgroundTimeRemaining
        self.backgroundTasks = backgroundTasks
        self.audioSessionActive = audioSessionActive
        self.displayLinks = displayLinks
        self.caches = caches
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        let tenths = (bytes * 10 + 512 * 1024) / (1024 * 1024)
        return "\(tenths / 10).\(tenths % 10) MB"
    }

    private static func seconds(_ value: Double) -> String {
        if value > 1.0e6 {
            return "none"
        }
        let tenths = Int((value * 10.0).rounded())
        return "\(tenths / 10).\(abs(tenths % 10)) s"
    }

    public var logLine: String {
        var parts: [String] = []
        parts.append("after \(Self.seconds(self.secondsInBackground))")
        if let memory = self.memory {
            parts.append("footprint \(Self.megabytes(memory.footprint)) (peak \(Self.megabytes(memory.footprintPeak)), internal \(Self.megabytes(memory.internalBytes)), compressed \(Self.megabytes(memory.compressed)), graphics \(Self.megabytes(memory.graphics)), media \(Self.megabytes(memory.media)), purgeable \(Self.megabytes(memory.purgeableVolatile)), malloc \(Self.megabytes(memory.mallocInUse)))")
        } else {
            parts.append("footprint unavailable")
        }
        parts.append("background time remaining \(Self.seconds(self.backgroundTimeRemaining))")
        parts.append("background tasks [\(self.backgroundTasks.joined(separator: ", "))]")
        parts.append("audio session \(self.audioSessionActive ? "active" : "inactive")")
        if let displayLinks = self.displayLinks {
            parts.append("display links \(displayLinks.running) running of \(displayLinks.registered), driver \(displayLinks.driverRunning ? "running" : "stopped")")
        }
        if !self.caches.isEmpty {
            parts.append("caches [" + self.caches.map { "\($0.name) \($0.bytes.map(Self.megabytes) ?? "?")" }.joined(separator: ", ") + "]")
        }
        return "Background diagnostic: " + parts.joined(separator: "; ")
    }
}
