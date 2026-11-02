import Foundation
@preconcurrency import TDShim

/// Where one account's TDLib data lives.
///
/// TDLib keeps paths in its file database relative to a base directory per file type:
/// photos, videos, voice and video notes, documents, music and animations under
/// `filesDirectory`; stickers, thumbnails, profile photos, stories and partial downloads
/// under `databaseDirectory` (its `store_all_files_in_files_directory` option is off).
struct TDLibStorageLayout: Equatable, Sendable {
    /// td.binlog (auth keys) and db.sqlite. Never purgeable.
    let databaseDirectory: URL
    let filesDirectory: URL

    /// True when downloads are in Caches, which the system may purge while the app is not running.
    var filesArePurgeable: Bool { filesDirectory.standardizedFileURL != databaseDirectory.standardizedFileURL }
}

enum TDLibStorage {
    struct Roots: Sendable {
        let applicationSupport: URL
        let caches: URL

        static var production: Roots {
            Roots(applicationSupport: URL.applicationSupportDirectory, caches: URL.cachesDirectory)
        }
    }

    /// Present in the database directory when the account keeps its downloads in Caches.
    static let filesInCachesMarker = ".files-in-caches"

    static func databaseDirectory(accountId: UUID, roots: Roots) -> URL {
        roots.applicationSupport
            .appendingPathComponent("tdlib", isDirectory: true)
            .appendingPathComponent(accountId.uuidString, isDirectory: true)
    }

    static func cachesFilesDirectory(accountId: UUID, roots: Roots) -> URL {
        roots.caches
            .appendingPathComponent("tdlib", isDirectory: true)
            .appendingPathComponent(accountId.uuidString, isDirectory: true)
    }

    /// Decides the layout once per account and creates its directories. Call before
    /// setTdlibParameters.
    ///
    /// A new account keeps its downloads in Caches. A directory TDLib has already used keeps
    /// them beside the database: its file database resolves each path against the files
    /// directory it was written under, so moving the base would strand those files where
    /// TDLib's optimizer no longer looks. Those accounts are bounded by the optimizer instead.
    static func prepareLayout(accountId: UUID, roots: Roots, fileManager: FileManager = .default) -> TDLibStorageLayout {
        let dbDir = databaseDirectory(accountId: accountId, roots: roots)
        let cachesDir = cachesFilesDirectory(accountId: accountId, roots: roots)
        let inDatabaseDirectory = TDLibStorageLayout(databaseDirectory: dbDir, filesDirectory: dbDir)
        let inCaches = TDLibStorageLayout(databaseDirectory: dbDir, filesDirectory: cachesDir)
        try? fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let marker = dbDir.appendingPathComponent(filesInCachesMarker, isDirectory: false)
        if isRegularFile(marker, fileManager: fileManager) {
            // TDLib recreates the directory itself if this fails.
            try? fileManager.createDirectory(at: cachesDir, withIntermediateDirectories: true)
            return inCaches
        }

        // Unreadable counts as used: never guess a directory is fresh.
        guard let contents = try? fileManager.contentsOfDirectory(atPath: dbDir.path), contents.isEmpty else {
            return inDatabaseDirectory
        }
        do {
            try fileManager.createDirectory(at: cachesDir, withIntermediateDirectories: true)
            try Data().write(to: marker, options: .atomic)
        } catch {
            // TDLib then writes into the database directory, and later launches see it used.
            return inDatabaseDirectory
        }
        return inCaches
    }

    /// Deletes everything an account stored, in both places.
    static func removeStorage(accountId: UUID, roots: Roots, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: databaseDirectory(accountId: accountId, roots: roots))
        try? fileManager.removeItem(at: cachesFilesDirectory(accountId: accountId, roots: roots))
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

/// `optimizeStorage`, which TDShim's generated subset does not include. The DTO derives the
/// TDLib type name from the Swift type name, so the name must stay `OptimizeStorage`.
struct OptimizeStorage: Codable, Equatable {
    struct FileType: Codable, Equatable {
        let type: String

        enum CodingKeys: String, CodingKey {
            case type = "@type"
        }
    }

    let size: Int64
    let ttl: Int
    let count: Int
    let immunityDelay: Int
    let fileTypes: [FileType]
    let chatIds: [Int64]
    let excludeChatIds: [Int64]
    let returnDeletedFileStatistics: Bool
    let chatLimit: Int

    /// TDLib's keys: the coders use default key strategies (see TDShim's Generated/README.md).
    enum CodingKeys: String, CodingKey {
        case size, ttl, count
        case immunityDelay = "immunity_delay"
        case fileTypes = "file_types"
        case chatIds = "chat_ids"
        case excludeChatIds = "exclude_chat_ids"
        case returnDeletedFileStatistics = "return_deleted_file_statistics"
        case chatLimit = "chat_limit"
    }
}

/// An explicit trim on top of TDLib's daily optimizer (`use_storage_optimizer`), which keeps
/// up to 100 MB and never deletes stickers, thumbnails or profile photos.
enum TDLibStorageOptimization {
    /// Files kept after the trim, least recently used deleted first.
    static let maxFilesSize: Int64 = 50 * 1024 * 1024
    /// Files not opened for a week go.
    static let ttl = 7 * 24 * 60 * 60
    static let maxFileCount = 5000
    /// At most this often per account; the trim scans every file.
    static let minimumInterval: TimeInterval = 6 * 60 * 60
    /// Waits out the launch's own loading first.
    static let startDelay: Duration = .seconds(10)

    /// Every type the watch downloads. Secret chats are off; secret thumbnails cannot be deleted.
    static let fileTypes = [
        "fileTypeAnimation", "fileTypeAudio", "fileTypeDocument", "fileTypeLivePhotoVideo",
        "fileTypeNotificationSound", "fileTypePhoto", "fileTypePhotoStory", "fileTypeProfilePhoto",
        "fileTypeSelfDestructingLivePhotoVideo", "fileTypeSelfDestructingPhoto", "fileTypeSelfDestructingVideo",
        "fileTypeSelfDestructingVideoNote", "fileTypeSelfDestructingVoiceNote", "fileTypeSticker",
        "fileTypeThumbnail", "fileTypeVideo", "fileTypeVideoNote", "fileTypeVideoStory", "fileTypeVoiceNote",
        "fileTypeWallpaper",
    ]

    static func query() -> OptimizeStorage {
        OptimizeStorage(
            size: maxFilesSize,
            ttl: ttl,
            count: maxFileCount,
            // TDLib's default: files created in the last hour stay.
            immunityDelay: -1,
            fileTypes: fileTypes.map(OptimizeStorage.FileType.init(type:)),
            chatIds: [],
            excludeChatIds: [],
            returnDeletedFileStatistics: true,
            chatLimit: 0
        )
    }

    /// What the trim deleted.
    struct Result: Codable, Equatable {
        let size: Int64
        let count: Int64
    }

    private struct TypeProbe: Decodable {
        let type: String

        enum CodingKeys: String, CodingKey {
            case type = "@type"
        }
    }

    static func decodeResult(_ data: Data, decoder: JSONDecoder) throws -> Result {
        if try decoder.decode(TypeProbe.self, from: data).type == "error" {
            throw try decoder.decode(TDError.self, from: data)
        }
        return try decoder.decode(Result.self, from: data)
    }

    /// Sends the trim; TDLib runs it on its own threads.
    static func run(client: TDLibClient) async throws -> Result {
        let query = DTO(query(), encoder: client.encoder)
        let decoder = client.decoder
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try client.send(query: query) { data in
                    continuation.resume(with: Swift.Result { try decodeResult(data, decoder: decoder) })
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Remembers the last trim per account across launches.
struct TDLibStorageOptimizationSchedule {
    let defaults: UserDefaults
    let interval: TimeInterval
    let now: () -> Date

    static func production() -> TDLibStorageOptimizationSchedule {
        TDLibStorageOptimizationSchedule(
            defaults: .standard,
            interval: TDLibStorageOptimization.minimumInterval,
            now: { Date() }
        )
    }

    private func key(_ accountId: UUID) -> String {
        "tdlib.lastStorageOptimization.\(accountId.uuidString)"
    }

    func isDue(accountId: UUID) -> Bool {
        guard let last = defaults.object(forKey: key(accountId)) as? Date else { return true }
        let elapsed = now().timeIntervalSince(last)
        // A clock set back counts as due rather than blocking for as long as it moved.
        return elapsed < 0 || elapsed >= interval
    }

    func markRun(accountId: UUID) {
        defaults.set(now(), forKey: key(accountId))
    }

    func clearRun(accountId: UUID) {
        defaults.removeObject(forKey: key(accountId))
    }
}
