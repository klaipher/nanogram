import Foundation

/// A memory-limit kill reported by MetricKit (iOS 27 `MemoryExceptionDiagnostic`), shaped like a crash diagnostic so
/// it appears in the Crash Logs list.
public enum MemoryExceptionReport {
    public static let exceptionTitle = "Memory limit exceeded"

    /// `encodedDiagnostic` is the JSON of the MetricKit diagnostic (its call stack tree). Throws if it is not a JSON
    /// object.
    public static func input(encodedDiagnostic: Data, metadata: CrashReportMetadata) throws -> CrashReportInput {
        guard let object = try JSONSerialization.jsonObject(with: encodedDiagnostic) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        var report: [String: Any] = [
            "isMemoryException": true,
            "diagnosticMetaData": [
                "exceptionType": exceptionTitle,
                "terminationReason": "The system ended the app because it used more memory than it is allowed"
            ]
        ]
        let tree = object["callStackTree"] ?? object
        if let tree = tree as? [String: Any], let converted = crashLayoutTree(tree) {
            report["callStackTree"] = converted
        } else {
            report["callStackTree"] = tree
        }
        return CrashReportInput(diagnosticJSON: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), metadata: metadata)
    }

    /// The iOS 27 `CallStackTree` keeps its threads in `callStackThreads`, their frames in `rootFrames`, and names a
    /// frame's binary only by UUID through the `binaryInfo` table. `CrashReport.text` renders the MXCrashDiagnostic
    /// layout (`callStacks`, `callStackRootFrames`, `binaryName` on every frame), so the tree is converted to that.
    /// Returns nil when `tree` is not in the iOS 27 layout; it is then stored as it is.
    static func crashLayoutTree(_ tree: [String: Any]) -> [String: Any]? {
        guard tree["callStacks"] == nil, let threads = tree["callStackThreads"] as? [[String: Any]] else {
            return nil
        }
        var names: [String: String] = [:]
        for binary in tree["binaryInfo"] as? [[String: Any]] ?? [] {
            if let uuid = binary["uuid"] as? String, let name = binary["name"] as? String {
                names[uuid.uppercased()] = name
            }
        }
        let stacks: [[String: Any]] = threads.map { thread -> [String: Any] in
            var stack = thread
            stack["rootFrames"] = nil
            stack["callStackRootFrames"] = namedFrames(thread["rootFrames"] as? [[String: Any]] ?? [], names: names)
            return stack
        }
        var result = tree
        result["callStackThreads"] = nil
        result["callStacks"] = stacks
        return result
    }

    /// Copies a frame tree, adding `binaryName` from `names` (keyed by upper-cased UUID) to every frame that has none.
    /// Walks with an explicit stack: MetricKit trees can be deep.
    private static func namedFrames(_ roots: [[String: Any]], names: [String: String]) -> [[String: Any]] {
        var frames: [[String: Any]] = []
        var children: [[Int]] = []
        var rootIndices: [Int] = []
        var pending: [(frame: [String: Any], parent: Int?)] = roots.reversed().map { (frame: $0, parent: nil) }
        while let (frame, parent) = pending.popLast() {
            let index = frames.count
            frames.append(frame)
            children.append([])
            if let parent = parent {
                children[parent].append(index)
            } else {
                rootIndices.append(index)
            }
            for child in (frame["subFrames"] as? [[String: Any]] ?? []).reversed() {
                pending.append((frame: child, parent: index))
            }
        }
        // Frames are numbered in pre-order, so every child comes after its parent: building from the end finds each
        // frame's children already built.
        var built = [[String: Any]](repeating: [:], count: frames.count)
        for index in frames.indices.reversed() {
            var frame = frames[index]
            if frame["binaryName"] == nil, let uuid = frame["binaryUUID"] as? String, let name = names[uuid.uppercased()] {
                frame["binaryName"] = name
            }
            if !children[index].isEmpty {
                frame["subFrames"] = children[index].map { built[$0] }
            }
            built[index] = frame
        }
        return rootIndices.map { built[$0] }
    }
}
