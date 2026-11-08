import Foundation
import sqlcipher
import DiskWriteAccounting

/// Counts what one SQLite connection makes the database write (DiskWriteAccounting): WAL frames appended by commits
/// (`sqlite.wal.<db>`) and frames copied into the database file by the checkpoints the WAL hook runs
/// (`sqlite.checkpoint.<db>`). Driven from `sqlite3_wal_hook`, which SQLite calls after every commit with the WAL's
/// current length in frames, so it costs nothing per statement. The WAL is shared with the app extensions, so frames
/// they appended between two of this connection's commits are counted here too; a WAL that was restarted in between
/// counts from its new start.
///
/// SQLite reports a checkpoint's result as the WAL's total backfilled frames, not the frames that checkpoint copied.
/// While another connection reads (an extension), the WAL cannot restart and every commit past the autocheckpoint
/// threshold checkpoints again, so only the growth of that total is looked at. A checkpoint writes the newest copy of
/// each page once, however many of the new frames carry that page, so the bytes counted are the distinct page numbers
/// in the frames backfilled since the previous checkpoint (read from the frame headers of the `-wal` file, which a
/// PASSIVE checkpoint leaves in place until the next write restarts it) times the page size. If the file cannot be
/// read, the frame count is the upper bound that is counted.
final class SqliteWalWriteAccounting {
    let walCategory: String
    let checkpointCategory: String
    let frameSize: Int
    private let walPath: String
    private var lastFrames: Int32 = 0
    private var lastBackfilledFrames: Int32 = 0
    private var lastCommitAppendedFrames: Int32 = 0
    private var hasCommitted = false
    /// A single commit, or a single checkpoint, that writes at least this many bytes gets a notice for the log.
    static let defaultLargeWriteBytes = 16 * 1024 * 1024
    private let largeWriteBytes: Int
    private let databaseName: String

    init(databasePath: String, handle: OpaquePointer?, largeWriteBytes: Int = SqliteWalWriteAccounting.defaultLargeWriteBytes) {
        let name = DiskWriteCategory.databaseName(path: (databasePath as NSString).deletingLastPathComponent)
        self.databaseName = name
        self.largeWriteBytes = largeWriteBytes
        self.walCategory = DiskWriteCategory.sqliteWal(database: name)
        self.checkpointCategory = DiskWriteCategory.sqliteCheckpoint(database: name)
        self.walPath = databasePath + "-wal"
        var pageSize = 4096
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "PRAGMA page_size", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
            pageSize = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        // Each WAL frame is a 24-byte header and one page.
        self.frameSize = 24 + max(512, pageSize)
    }

    private static func megabytes(_ bytes: Int) -> String {
        return String(format: "%.1f MB", Double(bytes) / 1048576.0)
    }

    /// Returns a line for the log when this commit made the WAL grow by `largeWriteBytes` or more, or when the WAL
    /// already held that much at this connection's first commit (written before it opened, such as by the previous
    /// process: the first commit then counts all of it, because the connection cannot tell whose frames they are).
    @discardableResult
    func committed(walFrames: Int32) -> String? {
        let isFirstCommit = !self.hasCommitted
        self.hasCommitted = true
        let appended = walFrames >= self.lastFrames ? walFrames - self.lastFrames : walFrames
        if walFrames < self.lastFrames {
            // The WAL restarted: its backfilled frames count from zero again.
            self.lastBackfilledFrames = 0
        }
        self.lastFrames = walFrames
        // Frames found at the first commit were written before this connection (the previous process, an extension):
        // they are accounted as written, but not attributed to the transaction that happened to commit first.
        self.lastCommitAppendedFrames = isFirstCommit ? 0 : appended
        if appended > 0 {
            DiskWriteAccounting.shared.add(self.walCategory, bytes: Int(appended) * self.frameSize)
        }
        let appendedBytes = Int(appended) * self.frameSize
        if appendedBytes < self.largeWriteBytes {
            return nil
        }
        if isFirstCommit {
            return "SQLite \(self.databaseName): the WAL held \(appended) frames (\(SqliteWalWriteAccounting.megabytes(appendedBytes))) at this connection's first commit; they were written before it opened (the previous process or an extension) and are counted as written now"
        }
        // Another process (an extension) writing to the same WAL between two of our commits is counted here too.
        return "SQLite \(self.databaseName): the WAL grew by \(appended) frames (\(SqliteWalWriteAccounting.megabytes(appendedBytes))) at one commit (another process's writes in between count too), the WAL is now \(walFrames) frames"
    }

    /// The frames the last commit appended, once: a second call without a commit in between gives 0. Called on the
    /// connection's queue right after `COMMIT`, which is where the WAL hook ran.
    func takeLastCommitAppendedFrames() -> Int {
        let frames = Int(self.lastCommitAppendedFrames)
        self.lastCommitAppendedFrames = 0
        return frames
    }

    /// `backfilledFrames`: the WAL's total backfilled frames after a checkpoint (`sqlite3_wal_checkpoint_v2`'s
    /// `pnCkpt`).
    @discardableResult
    func checkpointed(backfilledFrames: Int32) -> String? {
        let firstFrame = backfilledFrames >= self.lastBackfilledFrames ? self.lastBackfilledFrames : 0
        let copied = backfilledFrames - firstFrame
        self.lastBackfilledFrames = max(0, backfilledFrames)
        if copied > 0 {
            let pageSize = self.frameSize - SqliteWalWriteAccounting.frameHeaderSize
            let pages = SqliteWalWriteAccounting.distinctPages(walPath: self.walPath, frameSize: self.frameSize, firstFrame: Int(firstFrame), frameCount: Int(copied)) ?? Int(copied)
            DiskWriteAccounting.shared.add(self.checkpointCategory, bytes: pages * pageSize)
            if pages * pageSize >= self.largeWriteBytes {
                return "SQLite \(self.databaseName): a checkpoint copied \(pages) pages (\(SqliteWalWriteAccounting.megabytes(pages * pageSize))) from \(copied) WAL frames into the database file"
            }
        }
        return nil
    }

    private static let walHeaderSize = 32
    private static let frameHeaderSize = 24

    /// The number of distinct page numbers in `frameCount` frames of the WAL file after the first `firstFrame` ones,
    /// or nil when the file cannot be read. A frame starts with its page number as a big-endian 32-bit integer.
    static func distinctPages(walPath: String, frameSize: Int, firstFrame: Int, frameCount: Int) -> Int? {
        let descriptor = open(walPath, O_RDONLY)
        if descriptor < 0 {
            return nil
        }
        defer {
            close(descriptor)
        }
        var pages = Set<UInt32>()
        var bytes = [UInt8](repeating: 0, count: 4)
        for index in firstFrame ..< firstFrame + frameCount {
            let offset = off_t(SqliteWalWriteAccounting.walHeaderSize + index * frameSize)
            if pread(descriptor, &bytes, 4, offset) != 4 {
                return nil
            }
            pages.insert(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        }
        return pages.count
    }
}
