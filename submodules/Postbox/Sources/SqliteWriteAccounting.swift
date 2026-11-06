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
/// threshold checkpoints again, so only the growth of that total is counted.
final class SqliteWalWriteAccounting {
    let walCategory: String
    let checkpointCategory: String
    let frameSize: Int
    private var lastFrames: Int32 = 0
    private var lastBackfilledFrames: Int32 = 0
    private var lastCommitAppendedFrames: Int32 = 0

    init(databasePath: String, handle: OpaquePointer?) {
        let name = DiskWriteCategory.databaseName(path: (databasePath as NSString).deletingLastPathComponent)
        self.walCategory = DiskWriteCategory.sqliteWal(database: name)
        self.checkpointCategory = DiskWriteCategory.sqliteCheckpoint(database: name)
        var pageSize = 4096
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "PRAGMA page_size", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
            pageSize = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        // Each WAL frame is a 24-byte header and one page.
        self.frameSize = 24 + max(512, pageSize)
    }

    func committed(walFrames: Int32) {
        let appended = walFrames >= self.lastFrames ? walFrames - self.lastFrames : walFrames
        if walFrames < self.lastFrames {
            // The WAL restarted: its backfilled frames count from zero again.
            self.lastBackfilledFrames = 0
        }
        self.lastFrames = walFrames
        self.lastCommitAppendedFrames = appended
        if appended > 0 {
            DiskWriteAccounting.shared.add(self.walCategory, bytes: Int(appended) * self.frameSize)
        }
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
    func checkpointed(backfilledFrames: Int32) {
        let copied = backfilledFrames >= self.lastBackfilledFrames ? backfilledFrames - self.lastBackfilledFrames : backfilledFrames
        self.lastBackfilledFrames = max(0, backfilledFrames)
        if copied > 0 {
            DiskWriteAccounting.shared.add(self.checkpointCategory, bytes: Int(copied) * (self.frameSize - 24))
        }
    }
}
