import Foundation
import UniformTypeIdentifiers

/// Media the Share extension hands to the app for a new story: copies under
/// `<root>/share/stories/<session id>/<index>.<extension>` in the app group, which the app reads
/// when it opens `tg://shareStory?session=<id>` and then deletes.
public enum SharedStorySession {
    /// Whether a session file is a photo (otherwise a video), from its extension.
    public static func isImage(path: String) -> Bool {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if pathExtension.isEmpty {
            return false
        }
        // The common ones by name: the type database is not always available to a process.
        if imageExtensions.contains(pathExtension) {
            return true
        }
        guard let type = UTType(filenameExtension: pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "bmp", "webp", "avif", "dng"]

    /// The session's files in the order they were shared.
    public static func filePaths(sessionPath: String) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: sessionPath) else {
            return []
        }
        var paths: [String] = []
        for item in contents {
            let fullPath = sessionPath + "/" + item
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && !isDirectory.boolValue {
                paths.append(fullPath)
            }
        }
        paths.sort { lhs, rhs in
            let lhsName = ((lhs as NSString).lastPathComponent as NSString).deletingPathExtension
            let rhsName = ((rhs as NSString).lastPathComponent as NSString).deletingPathExtension
            if let lhsValue = Int(lhsName), let rhsValue = Int(rhsName) {
                return lhsValue < rhsValue
            }
            return lhsName < rhsName
        }
        return paths
    }
}

/// Deletes session directories under `path` last modified more than `olderThan` seconds before
/// `now`: what a share left behind when the app never opened it or was killed in between.
public func removeStaleSharedStorySessions(path: String, olderThan: TimeInterval, now: Date = Date()) {
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
        return
    }
    for item in contents {
        let fullPath = path + "/" + item
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath), let modified = attributes[.modificationDate] as? Date else {
            continue
        }
        if now.timeIntervalSince(modified) > olderThan {
            try? FileManager.default.removeItem(atPath: fullPath)
        }
    }
}
