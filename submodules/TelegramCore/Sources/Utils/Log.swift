import Foundation
import SwiftSignalKit
import Postbox
internal import TelegramApi
import NetworkLogging
import ManagedFile
import DiskWriteAccounting

private let queue = DispatchQueue(label: "org.telegram.Telegram.trace", qos: .utility)

public func trace2(_ what: @autoclosure() -> String) {
    let string = what()
    var rawTime = time_t()
    time(&rawTime)
    var timeinfo = tm()
    localtime_r(&rawTime, &timeinfo)
    
    var curTime = timeval()
    gettimeofday(&curTime, nil)
    let milliseconds = curTime.tv_usec / 1000
    
    //queue.async {
        let result = String(format: "%d-%d-%d %02d:%02d:%03d %@", arguments: [Int(timeinfo.tm_year) + 1900, Int(timeinfo.tm_mon + 1), Int(timeinfo.tm_mday), Int(timeinfo.tm_hour), Int(timeinfo.tm_min), Int(milliseconds), string])
        print(result)
    //}
}

public func trace1(_ domain: String, what: @autoclosure() -> String) {
    let string = what()
    var rawTime = time_t()
    time(&rawTime)
    var timeinfo = tm()
    localtime_r(&rawTime, &timeinfo)
    
    var curTime = timeval()
    gettimeofday(&curTime, nil)
    let seconds = curTime.tv_sec
    let milliseconds = curTime.tv_usec / 1000
    
    queue.async {
        let result = String(format: "[%@] %d-%d-%d %02d:%02d:%02d.%03d %@", arguments: [domain, Int(timeinfo.tm_year) + 1900, Int(timeinfo.tm_mon + 1), Int(timeinfo.tm_mday), Int(timeinfo.tm_hour), Int(timeinfo.tm_min), Int(seconds), Int(milliseconds), string])
        
        print(result)
    }
}

public func registerLoggingFunctions() {
    setBridgingTraceFunction({ domain, what in
        if let what = what {
            if let domain = domain {
                Logger.shared.log(domain, what as String)
            } else {
                Logger.shared.log("", what as String)
            }
        }
    })
    setBridgingShortTraceFunction({ domain, what in
        if let what = what {
            if let domain = domain {
                Logger.shared.shortLog(domain, what as String)
            } else {
                Logger.shared.shortLog("", what as String)
            }
        }
    })
    setTelegramApiLogger({ what in
        Logger.shared.log("Api", what as String)
        Logger.shared.shortLog("Api", what as String)
    })
}

private var sharedLogger: Logger?

private let binaryEventMarker: UInt64 = 0xcadebabef00dcafe

public final class Logger {
    private let queue = Queue(name: "org.telegram.Telegram.log", qos: .utility)
    private let maxLength: Int = 2 * 1024 * 1024
    private let maxShortLength: Int = 1 * 1024 * 1024
    private let maxFiles: Int = 20
    
    private let rootPath: String
    private let basePath: String
    private var file: (ManagedFile, Int)?
    private var shortFile: (ManagedFile, Int)?
    
    // Short-log entries are written in batches: one write() per entry cost ~0.3 s per session on
    // device. Pending bytes always belong to `pendingShortLogFile` and reach it within
    // `shortLogFlushDelay`, on sync() and before the logs are collected.
    private let shortLogFlushDelay: Double = 0.5
    // Internal so a benchmark can compare with one write per entry (1).
    var shortLogFlushSize: Int = 32 * 1024
    private var pendingShortLogFile: ManagedFile?
    private var pendingShortLogData = Data()
    private var isShortLogFlushScheduled: Bool = false
    
    // Log lines (`log-*.txt`, only when "Log to File" is on) are buffered the same way: one write() per line was
    // ~230,000 writes a day on a device with logging on. Lines are appended to `pendingLogData` on the logger queue
    // and written, byte for byte as before, when the buffer reaches `logFlushSize`, `logFlushDelay` after the first
    // unflushed line (one timer, none while idle), on rotation, on sync(), before logs are collected, when logging
    // to file is switched off, and from `flushPendingLogs`. A crash or kill between flushes loses at most the lines
    // of the last `logFlushDelay` (1 s), or of a suspension that stops the timer.
    private let logFlushDelay: Double = 1.0
    // Internal so tests can use a small buffer.
    var logFlushSize: Int = 64 * 1024
    // Internal: schedules the one flush timer. Tests replace it with a manual clock; the callback may run on any
    // thread, it hops to the logger queue itself.
    var scheduleLogFlush: (Double, @escaping () -> Void) -> Void
    // Internal: called on the logger queue for every write() of log lines (tests count them).
    var onLogWrite: ((Int) -> Void)?
    private var pendingLogFile: ManagedFile?
    private var pendingLogData = Data()
    private var isLogFlushScheduled: Bool = false
    
    // What the logger holds that has not reached the files yet, for the memory log. `queuedEntries` counts the
    // `log`/`shortLog` calls whose closure is queued on the logger queue and has not run (a utility queue that is
    // starved while the main thread is busy lets them pile up, each holding its message); `pendingBytes` is the size
    // of the two write buffers. Readable from any thread.
    private let statsLock = NSLock()
    private var queuedEntriesValue: Int = 0
    private var queuedBytesValue: Int = 0
    private var pendingBytesValue: Int = 0

    public struct Backlog: Equatable {
        public var queuedEntries: Int
        public var queuedBytes: Int
        public var pendingBytes: Int

        public init(queuedEntries: Int, queuedBytes: Int, pendingBytes: Int) {
            self.queuedEntries = queuedEntries
            self.queuedBytes = queuedBytes
            self.pendingBytes = pendingBytes
        }
    }

    public var backlog: Backlog {
        self.statsLock.lock()
        defer {
            self.statsLock.unlock()
        }
        return Backlog(queuedEntries: self.queuedEntriesValue, queuedBytes: self.queuedBytesValue, pendingBytes: self.pendingBytesValue)
    }

    private func entryQueued(bytes: Int) {
        self.statsLock.lock()
        self.queuedEntriesValue += 1
        self.queuedBytesValue += bytes
        self.statsLock.unlock()
    }

    private func entryStarted(bytes: Int) {
        self.statsLock.lock()
        self.queuedEntriesValue -= 1
        self.queuedBytesValue -= bytes
        self.statsLock.unlock()
    }

    private func updatePendingBytes() {
        let total = self.pendingLogData.count + self.pendingShortLogData.count
        self.statsLock.lock()
        self.pendingBytesValue = total
        self.statsLock.unlock()
    }

    /// Whether MtProtoKit's verbose lines (request and response dumps) are on: only when something is logged AND the
    /// "Network protocol dumps" switch is on. Logging to file or console alone keeps MtProtoKit's short lines.
    public static func isNetworkLoggingEnabled(logToFile: Bool, logToConsole: Bool, logNetworkDumps: Bool) -> Bool {
        return (logToFile || logToConsole) && logNetworkDumps
    }

    private func updateNetworkLogging(oldLogToFile: Bool, oldLogToConsole: Bool, oldLogNetworkDumps: Bool) {
        let oldEnabled = Logger.isNetworkLoggingEnabled(logToFile: oldLogToFile, logToConsole: oldLogToConsole, logNetworkDumps: oldLogNetworkDumps)
        let newEnabled = Logger.isNetworkLoggingEnabled(logToFile: self.logToFile, logToConsole: self.logToConsole, logNetworkDumps: self.logNetworkDumps)
        if oldEnabled != newEnabled {
            NetworkSetLoggingEnabled(newEnabled)
        }
    }

    public var logToFile: Bool = true {
        didSet {
            if oldValue && !self.logToFile {
                self.queue.async {
                    self.flushLog()
                }
            }
            self.updateNetworkLogging(oldLogToFile: oldValue, oldLogToConsole: self.logToConsole, oldLogNetworkDumps: self.logNetworkDumps)
        }
    }
    public var logToConsole: Bool = true {
        didSet {
            self.updateNetworkLogging(oldLogToFile: self.logToFile, oldLogToConsole: oldValue, oldLogNetworkDumps: self.logNetworkDumps)
        }
    }
    /// Debug Settings "Network protocol dumps" (off by default): MtProtoKit's request and response dumps.
    public var logNetworkDumps: Bool = false {
        didSet {
            self.updateNetworkLogging(oldLogToFile: self.logToFile, oldLogToConsole: self.logToConsole, oldLogNetworkDumps: oldValue)
        }
    }
    public var redactSensitiveData: Bool = true
    
    public static func setSharedLogger(_ logger: Logger) {
        sharedLogger = logger
        setPostboxLogger({ s in
            Logger.shared.log("Postbox", s)
            Logger.shared.shortLog("Postbox", s)
        }, sync: {
            Logger.shared.sync()
        })
    }
    
    /// The shared logger, or nil before `setSharedLogger` (unlike `shared`, never a throwaway logger or an assertion).
    public static var sharedIfInstalled: Logger? {
        return sharedLogger
    }
    
    public static var shared: Logger {
        if let sharedLogger = sharedLogger {
            return sharedLogger
        } else {
            assertionFailure()
            let tempLogger = Logger(rootPath: "", basePath: "")
            tempLogger.logToFile = false
            tempLogger.logToConsole = false
            return tempLogger
        }
    }
    
    public init(rootPath: String, basePath: String) {
        self.rootPath = rootPath
        self.basePath = basePath
        let queue = self.queue
        self.scheduleLogFlush = { delay, f in
            queue.after(delay, f)
        }
    }
    
    public func sync() {
        self.queue.sync {
            self.flushLog()
            self.flushShortLog()
            if let (currentFile, _) = self.file {
                let _ = currentFile.sync()
            }
        }
    }
    
    /// Writes the batched log and short log lines now, without waiting for the flush timers (which do not fire
    /// while the app is suspended) and without the fsync of `sync()`: a plain write survives a kill. Call it before
    /// the app can be suspended, on memory warnings and on termination. Does not block the caller.
    public func flushPendingLogs() {
        self.queue.async {
            self.flushLog()
            self.flushShortLog()
        }
    }
    
    /// Same as `flushPendingLogs`, but returns after the lines are written. For app extensions that finish: the
    /// process can be gone right after. A few milliseconds (one write of at most 64 KB plus what the queue has
    /// queued); never call it from a path that must not wait.
    public func flushPendingLogsAndWait() {
        self.queue.sync {
            self.flushLog()
            self.flushShortLog()
        }
    }
    
    /// Waits until the logger queue ran everything queued so far, without flushing (tests).
    func drainForTesting() {
        self.queue.sync {
        }
    }
    
    private func flushLog() {
        assert(self.queue.isCurrent())
        guard let file = self.pendingLogFile, !self.pendingLogData.isEmpty else {
            self.pendingLogFile = nil
            return
        }
        let data = self.pendingLogData
        self.pendingLogData = Data()
        self.pendingLogFile = nil
        let count = data.count
        data.withUnsafeBytes { rawBytes -> Void in
            guard let baseAddress = rawBytes.baseAddress else {
                return
            }
            let _ = file.write(baseAddress, count: count)
        }
        self.onLogWrite?(count)
        DiskWriteAccounting.shared.add(DiskWriteCategory.logs, bytes: count)
        self.updatePendingBytes()
    }
    
    private func appendLog(_ data: Data, to file: ManagedFile) {
        assert(self.queue.isCurrent())
        if let pendingFile = self.pendingLogFile, pendingFile !== file {
            self.flushLog()
        }
        self.pendingLogFile = file
        self.pendingLogData.append(data)
        if self.pendingLogData.count >= self.logFlushSize {
            self.flushLog()
        } else if !self.isLogFlushScheduled {
            self.isLogFlushScheduled = true
            self.scheduleLogFlush(self.logFlushDelay, { [weak self] in
                guard let self else {
                    return
                }
                self.queue.async {
                    self.isLogFlushScheduled = false
                    self.flushLog()
                }
            })
        }
    }
    
    private func flushShortLog() {
        assert(self.queue.isCurrent())
        guard let file = self.pendingShortLogFile, !self.pendingShortLogData.isEmpty else {
            self.pendingShortLogFile = nil
            return
        }
        let data = self.pendingShortLogData
        self.pendingShortLogData = Data()
        self.pendingShortLogFile = nil
        let count = data.count
        data.withUnsafeBytes { rawBytes -> Void in
            let _ = file.write(rawBytes.baseAddress!, count: count)
        }
        DiskWriteAccounting.shared.add(DiskWriteCategory.logs, bytes: count)
        self.updatePendingBytes()
    }
    
    private func appendShortLog(_ data: Data, to file: ManagedFile) {
        assert(self.queue.isCurrent())
        if let pendingFile = self.pendingShortLogFile, pendingFile !== file {
            self.flushShortLog()
        }
        self.pendingShortLogFile = file
        self.pendingShortLogData.append(data)
        if self.pendingShortLogData.count >= self.shortLogFlushSize {
            self.flushShortLog()
        } else if !self.isShortLogFlushScheduled {
            self.isShortLogFlushScheduled = true
            self.queue.after(self.shortLogFlushDelay, { [weak self] in
                guard let self else {
                    return
                }
                self.isShortLogFlushScheduled = false
                self.flushShortLog()
            })
        }
    }
    
    public func collectLogs(prefix: String? = nil) -> Signal<[(String, String)], NoError> {
        return Signal { subscriber in
            self.queue.async {
                self.flushLog()
                let logsPath: String
                if let prefix = prefix {
                    logsPath = self.rootPath + prefix
                } else {
                    logsPath = self.basePath
                }
                
                var result: [(Date, String, String)] = []
                if let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: logsPath), includingPropertiesForKeys: [URLResourceKey.creationDateKey], options: []) {
                    for url in files {
                        if url.lastPathComponent.hasPrefix("log-") {
                            if let creationDate = (try? url.resourceValues(forKeys: Set([.creationDateKey])))?.creationDate {
                                result.append((creationDate, url.lastPathComponent, url.path))
                            }
                        }
                    }
                }
                result.sort(by: { $0.0 < $1.0 })
                subscriber.putNext(result.map { ($0.1, $0.2) })
                subscriber.putCompletion()
            }
            
            return EmptyDisposable
        }
    }
    
    public func collectLogs(basePath: String) -> Signal<[(String, String)], NoError> {
        return Signal { subscriber in
            self.queue.async {
                self.flushLog()
                let logsPath: String = basePath
                
                var result: [(Date, String, String)] = []
                if let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: logsPath), includingPropertiesForKeys: [URLResourceKey.creationDateKey], options: []) {
                    for url in files {
                        if url.lastPathComponent.hasPrefix("log-") {
                            if let creationDate = (try? url.resourceValues(forKeys: Set([.creationDateKey])))?.creationDate {
                                result.append((creationDate, url.lastPathComponent, url.path))
                            }
                        }
                    }
                }
                result.sort(by: { $0.0 < $1.0 })
                subscriber.putNext(result.map { ($0.1, $0.2) })
                subscriber.putCompletion()
            }
            
            return EmptyDisposable
        }
    }
    
    public func collectShortLogFiles() -> Signal<[(String, String)], NoError> {
        return Signal { subscriber in
            self.queue.async {
                self.flushShortLog()
                var result: [(Date, String, String)] = []
                if let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: self.basePath), includingPropertiesForKeys: [URLResourceKey.creationDateKey], options: []) {
                    for url in files {
                        if url.lastPathComponent.hasPrefix("critlog-") {
                            if let creationDate = (try? url.resourceValues(forKeys: Set([.creationDateKey])))?.creationDate {
                                result.append((creationDate, url.lastPathComponent, url.path))
                            }
                        }
                    }
                }
                result.sort(by: { $0.0 < $1.0 })
                subscriber.putNext(result.map { ($0.1, $0.2) })
                subscriber.putCompletion()
            }
            
            return EmptyDisposable
        }
    }
    
    public func collectShortLog() -> Signal<[(Double, String)], NoError> {
        return Signal { subscriber in
            self.queue.async {
                self.flushShortLog()
                var result: [(Date, String, String)] = []
                if let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: self.basePath), includingPropertiesForKeys: [URLResourceKey.creationDateKey], options: []) {
                    for url in files {
                        if url.lastPathComponent.hasPrefix("critlog-") {
                            if let creationDate = (try? url.resourceValues(forKeys: Set([.creationDateKey])))?.creationDate {
                                result.append((creationDate, url.lastPathComponent, url.path))
                            }
                        }
                    }
                }
                result.sort(by: { $0.0 < $1.0 })
                
                var events: [(Double, String)] = []
                for (_, _, filePath) in result.reversed() {
                    var fileEvents: [(Double, String)] = []
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedRead) {
                        let dataLength = data.count
                        data.withUnsafeBytes { rawBytes -> Void in
                            let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: Int8.self)

                            var offset = 0
                            while offset < dataLength {
                                let remainingLength = dataLength - offset
                                if remainingLength < 8 + 4 + 8 {
                                    break
                                }
                                var maybeMarker: UInt64 = 0
                                memcpy(&maybeMarker, bytes.advanced(by: offset), 8)
                                if maybeMarker == binaryEventMarker {
                                    var length: Int32 = 0
                                    memcpy(&length, bytes.advanced(by: offset + 8), 4)
                                    if length < 0 || length > dataLength - offset {
                                        offset += 1
                                    } else {
                                        var timestamp: Double = 0.0
                                        memcpy(&timestamp, bytes.advanced(by: offset + 8 + 4), 8)
                                        let eventStringData = Data(bytes: bytes.advanced(by: offset + 8 + 4 + 8), count: Int(length - 8))
                                        if let string = String(data: eventStringData, encoding: .utf8) {
                                            fileEvents.append((timestamp, string))
                                        }
                                        offset += 8 + 4 + Int(length)
                                    }
                                } else {
                                    offset += 1
                                }
                            }
                        }
                        
                        events.append(contentsOf: fileEvents.reversed())
                        if events.count > 1000 {
                            break
                        }
                    }
                }
                if events.count > 1000 {
                    events.removeLast(events.count - 1000)
                }
                subscriber.putNext(events)
                subscriber.putCompletion()
            }
            
            return EmptyDisposable
        }
    }
    
    public func log(_ tag: String, _ what: @autoclosure () -> String) {
        if !self.logToFile && !self.logToConsole {
            return
        }
        
        let string = what()
        
        var rawTime = time_t()
        time(&rawTime)
        var timeinfo = tm()
        localtime_r(&rawTime, &timeinfo)
        
        var curTime = timeval()
        gettimeofday(&curTime, nil)
        let milliseconds = curTime.tv_usec / 1000
        
        var consoleContent: String?
        if self.logToConsole {
            let content = String(format: "[%@] %d-%d-%d %02d:%02d:%02d.%03d %@", arguments: [tag, Int(timeinfo.tm_year) + 1900, Int(timeinfo.tm_mon + 1), Int(timeinfo.tm_mday), Int(timeinfo.tm_hour), Int(timeinfo.tm_min), Int(timeinfo.tm_sec), Int(milliseconds), string])
            consoleContent = content
            print(content)
        }
        
        if self.logToFile {
            let queuedBytes = string.utf8.count
            self.entryQueued(bytes: queuedBytes)
            self.queue.async {
                self.entryStarted(bytes: queuedBytes)
                defer {
                    self.updatePendingBytes()
                }
                let content: String
                if let consoleContent = consoleContent {
                    content = consoleContent
                } else {
                    content = String(format: "[%@] %d-%d-%d %02d:%02d:%02d.%03d %@", arguments: [tag, Int(timeinfo.tm_year) + 1900, Int(timeinfo.tm_mon + 1), Int(timeinfo.tm_mday), Int(timeinfo.tm_hour), Int(timeinfo.tm_min), Int(timeinfo.tm_sec), Int(milliseconds), string])
                }
                
                var currentFile: ManagedFile?
                var openNew = false
                if let (file, length) = self.file {
                    if length >= self.maxLength {
                        // Pending lines belong to the file being closed.
                        self.flushLog()
                        self.file = nil
                        openNew = true
                    } else {
                        currentFile = file
                    }
                } else {
                    openNew = true
                }
                if openNew {
                    let _ = try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true, attributes: nil)
                    
                    var createNew = false
                    if let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: self.basePath), includingPropertiesForKeys: [URLResourceKey.creationDateKey], options: []) {
                        var minCreationDate: (Date, URL)?
                        var maxCreationDate: (Date, URL)?
                        var count = 0
                        for url in files {
                            if url.lastPathComponent.hasPrefix("log-") {
                                if let values = try? url.resourceValues(forKeys: Set([URLResourceKey.creationDateKey])), let creationDate = values.creationDate {
                                    count += 1
                                    if minCreationDate == nil || minCreationDate!.0 > creationDate {
                                        minCreationDate = (creationDate, url)
                                    }
                                    if maxCreationDate == nil || maxCreationDate!.0 < creationDate {
                                        maxCreationDate = (creationDate, url)
                                    }
                                }
                            }
                        }
                        if let (_, url) = minCreationDate, count >= self.maxFiles {
                            let _ = try? FileManager.default.removeItem(at: url)
                        }
                        if let (_, url) = maxCreationDate {
                            var value = stat()
                            if stat(url.path, &value) == 0 && Int(value.st_size) < self.maxLength {
                                if let file = ManagedFile(queue: self.queue, path: url.path, mode: .append) {
                                    self.file = (file, Int(value.st_size))
                                    currentFile = file
                                }
                            } else {
                                createNew = true
                            }
                        } else {
                            createNew = true
                        }
                    }
                    
                    if createNew {
                        let fileName = String(format: "log-%d-%d-%d_%02d-%02d-%02d.%03d.txt", arguments: [Int(timeinfo.tm_year) + 1900, Int(timeinfo.tm_mon + 1), Int(timeinfo.tm_mday), Int(timeinfo.tm_hour), Int(timeinfo.tm_min), Int(timeinfo.tm_sec), Int(milliseconds)])
                        
                        let path = self.basePath + "/" + fileName
                        
                        if let file = ManagedFile(queue: self.queue, path: path, mode: .append) {
                            self.file = (file, 0)
                            currentFile = file
                        }
                    }
                }
                
                if let currentFile = currentFile {
                    if var data = content.data(using: .utf8) {
                        data.append(0x0a)
                        let lineLength = data.count
                        self.appendLog(data, to: currentFile)
                        if let file = self.file {
                            self.file = (file.0, file.1 + lineLength)
                        } else {
                            assertionFailure()
                        }
                    }
                }
            }
        }
    }
    
    public func shortLog(_ tag: String, _ what: @autoclosure () -> String) {
        let string = what()
        
        var rawTime = time_t()
        time(&rawTime)
        var timeinfo = tm()
        localtime_r(&rawTime, &timeinfo)
        
        var curTime = timeval()
        gettimeofday(&curTime, nil)
        let milliseconds = curTime.tv_usec / 1000
        
        let timestamp: Double = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970
        
        let queuedBytes = string.utf8.count
        self.entryQueued(bytes: queuedBytes)
        self.queue.async {
            self.entryStarted(bytes: queuedBytes)
            defer {
                self.updatePendingBytes()
            }
            let content = WriteBuffer()
            var binaryEventMarkerValue: UInt64 = binaryEventMarker
            content.write(&binaryEventMarkerValue, offset: 0, length: 8)
            let stringData = string.data(using: .utf8) ?? Data()
            var lengthValue: Int32 = 8 + Int32(stringData.count)
            content.write(&lengthValue, offset: 0, length: 4)
            var timestampValue: Double = timestamp
            content.write(&timestampValue, offset: 0, length: 8)
            content.write(stringData)
            let contentData = content.makeData()
            
            var currentFile: ManagedFile?
            var openNew = false
            if let (file, length) = self.shortFile {
                if length >= self.maxShortLength {
                    self.shortFile = nil
                    openNew = true
                } else {
                    currentFile = file
                }
            } else {
                openNew = true
            }
            if openNew {
                // Pending bytes count towards the current file's size on disk.
                self.flushShortLog()
                let _ = try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true, attributes: nil)
                
                var createNew = false
                if let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: self.basePath), includingPropertiesForKeys: [URLResourceKey.creationDateKey], options: []) {
                    var minCreationDate: (Date, URL)?
                    var maxCreationDate: (Date, URL)?
                    var count = 0
                    for url in files {
                        if url.lastPathComponent.hasPrefix("critlog-") {
                            if let values = try? url.resourceValues(forKeys: Set([URLResourceKey.creationDateKey])), let creationDate = values.creationDate {
                                count += 1
                                if minCreationDate == nil || minCreationDate!.0 > creationDate {
                                    minCreationDate = (creationDate, url)
                                }
                                if maxCreationDate == nil || maxCreationDate!.0 < creationDate {
                                    maxCreationDate = (creationDate, url)
                                }
                            }
                        }
                    }
                    if let (_, url) = minCreationDate, count >= self.maxFiles {
                        let _ = try? FileManager.default.removeItem(at: url)
                    }
                    if let (_, url) = maxCreationDate {
                        var value = stat()
                        if stat(url.path, &value) == 0 && Int(value.st_size) < self.maxShortLength {
                            if let file = ManagedFile(queue: self.queue, path: url.path, mode: .append) {
                                self.shortFile = (file, Int(value.st_size))
                                currentFile = file
                            }
                        } else {
                            createNew = true
                        }
                    } else {
                        createNew = true
                    }
                }
                
                if createNew {
                    let fileName = String(format: "critlog-%d-%d-%d_%02d-%02d-%02d.%03d.txt", arguments: [Int(timeinfo.tm_year) + 1900, Int(timeinfo.tm_mon + 1), Int(timeinfo.tm_mday), Int(timeinfo.tm_hour), Int(timeinfo.tm_min), Int(timeinfo.tm_sec), Int(milliseconds)])
                    
                    let path = self.basePath + "/" + fileName
                    
                    if let file = ManagedFile(queue: self.queue, path: path, mode: .append) {
                        self.shortFile = (file, 0)
                        currentFile = file
                    }
                }
            }
            
            if let currentFile = currentFile {
                let contentDataCount = contentData.count
                self.appendShortLog(contentData, to: currentFile)
                if let shortFile = self.shortFile {
                    self.shortFile = (shortFile.0, shortFile.1 + contentDataCount)
                } else {
                    assertionFailure()
                }
            }
        }
    }
}
