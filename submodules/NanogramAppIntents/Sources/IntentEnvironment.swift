import Foundation
import NanogramGlance

/// Where the intents read the app's snapshot from. Tests replace the reader.
public enum NanogramIntentEnvironment {
    nonisolated(unsafe) public static var snapshotReader: @Sendable () -> GlanceSnapshot? = {
        guard let rootPath = GlanceLocation.rootPath() else {
            return nil
        }
        return GlanceStore.read(rootPath: rootPath)
    }
}
