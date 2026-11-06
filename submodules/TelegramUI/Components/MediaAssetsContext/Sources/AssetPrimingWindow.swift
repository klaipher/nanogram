import Foundation
import Photos

/// `PHFetchResult.object(at:)` loads assets from photolibraryd in batches and blocks while it does: the
/// first cells of a picker did that on the main thread (`PHFetchResult.objectAtIndex`, 26 % of cell setup in
/// a trace). The picker primes the objects of the cells it will show first on the queue that fetched them,
/// so the cells find them loaded. Recents show from the end of the fetch result, albums from the start.
public enum AssetPrimingWindow {
    public static let perEnd = 48

    /// The index ranges to load: the first and the last `perEnd` indices, merged when they meet.
    public static func ranges(count: Int, perEnd: Int = AssetPrimingWindow.perEnd) -> [Range<Int>] {
        guard count > 0, perEnd > 0 else {
            return []
        }
        if count <= perEnd * 2 {
            return [0 ..< count]
        }
        return [0 ..< perEnd, (count - perEnd) ..< count]
    }

    /// Loads the objects. Call off the main thread.
    public static func prime(_ fetchResult: PHFetchResult<PHAsset>) {
        for range in self.ranges(count: fetchResult.count) {
            let _ = fetchResult.objects(at: IndexSet(integersIn: range))
        }
    }
}
