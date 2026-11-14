import Foundation

/// widget-sandbox's corpus (the submodule third-party/widget-sandbox/widget-sandbox, `corpus/`) as a test bundle has it, at
/// widget-sandbox/corpus/, by folder.
enum WidgetCorpus {
    struct File {
        let folder: String
        /// Relative to corpus/, e.g. "htmlbubbles-ported/06-trip-lisbon/04-tom.html".
        let path: String
        let source: String
    }

    static let folders = ["attacks", "bot-demos", "common", "compat", "defaults", "generated", "gestures", "htmlbubbles-ported", "interactive", "out-of-profile", "resize", "safe-area", "showcase"]

    private final class Anchor {}

    static func files(in folder: String) -> [File] {
        let bundle = Bundle(for: Anchor.self)
        guard let corpus = bundle.resourceURL?.appendingPathComponent("widget-sandbox/corpus"),
              let walk = FileManager.default.enumerator(at: corpus.appendingPathComponent(folder), includingPropertiesForKeys: nil) else {
            return []
        }
        // Standardized on both sides: the simulator's container path can come back through /private.
        let prefix = corpus.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var files: [File] = []
        for case let url as URL in walk where url.pathExtension == "html" {
            let relative = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(prefix.count))
            files.append(File(folder: folder, path: relative, source: (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        }
        return files.sorted { $0.path < $1.path }
    }
}
