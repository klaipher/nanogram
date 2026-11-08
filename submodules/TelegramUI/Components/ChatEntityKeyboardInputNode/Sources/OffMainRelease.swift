import Foundation
import EntityKeyboard

/// Frees plain data away from the main thread. Closing a chat released the emoji and sticker panel data
/// (thousands of `ItemGroup.Item` objects) inside `ChatControllerNode.deinit` on the main thread: ~75 ms
/// in the 202611081037 hitch log.
///
/// Only hand it plain data (values, strings, files, colors). Never a view, layer, node or a disposable.
public enum OffMainRelease {
    /// The hand-over waits a little so the caller's own remaining references (instance variables are destroyed
    /// right after `deinit`) are gone first; the background queue then holds the last one.
    public static let defaultDelay: Double = 0.5

    public static func release(_ objects: [Any], after delay: Double = OffMainRelease.defaultDelay, queue: DispatchQueue = DispatchQueue.global(qos: .utility)) {
        if objects.isEmpty {
            return
        }
        queue.asyncAfter(deadline: .now() + delay) {
            withExtendedLifetime(objects) {
            }
        }
    }
}

extension ChatEntityKeyboardInputNode.InputData {
    /// The heavy, pure-data part: the item groups of the emoji and sticker pagers. The components that own them
    /// also hold the account context and the input interaction, which stay on the main thread.
    public var itemGroupsForOffMainRelease: [Any] {
        var result: [Any] = []
        for component in [self.emoji, self.stickers] {
            if let component {
                result.append(component.panelItemGroups)
                result.append(component.contentItemGroups)
            }
        }
        return result
    }
}
