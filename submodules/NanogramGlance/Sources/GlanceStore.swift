public import Foundation

public enum GlanceStore {
    public static func path(rootPath: String) -> String {
        return rootPath + "/nanogram-glance.json"
    }

    public static func read(rootPath: String) -> GlanceSnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path(rootPath: rootPath))) else {
            return nil
        }
        guard let snapshot = try? JSONDecoder().decode(GlanceSnapshot.self, from: data), snapshot.version == GlanceSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    @discardableResult
    public static func write(_ snapshot: GlanceSnapshot, rootPath: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return false
        }
        do {
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: URL(fileURLWithPath: path(rootPath: rootPath)), options: options)
            return true
        } catch {
            return false
        }
    }

    public static func remove(rootPath: String) {
        _ = try? FileManager.default.removeItem(atPath: path(rootPath: rootPath))
    }
}

public enum GlanceLocation {
    /// The app group identifiers to try for a process: its own bundle identifier, then the host app's (an extension's
    /// identifier is the app's plus one component).
    public static func groupIdentifierCandidates(bundleIdentifier: String) -> [String] {
        var result = ["group.\(bundleIdentifier)"]
        if let lastDot = bundleIdentifier.lastIndex(of: ".") {
            result.append("group.\(bundleIdentifier[bundleIdentifier.startIndex ..< lastDot])")
        }
        return result
    }

    /// `<app group>/telegram-data`, as the app, the widget and the Siri extension all use.
    public static func rootPath(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String? {
        guard let bundleIdentifier else {
            return nil
        }
        for candidate in groupIdentifierCandidates(bundleIdentifier: bundleIdentifier) {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) {
                return url.path + "/telegram-data"
            }
        }
        return nil
    }
}
