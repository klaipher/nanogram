import Foundation

// Which assets the photo grid asks Photos to prepare thumbnails for: the visible ones plus one screen on each side.
// Apple (PHCachingImageManager): call startCachingImages for the images you expect to need soon, with the size, content
// mode and options you will request them with, and stop for the ones that are no longer needed.
public enum AssetCachingWindow {
    // The indices to keep cached for a visible range: the range plus its own length again on each side (one screen),
    // clamped to the fetch result.
    public static func window(visible: ClosedRange<Int>, count: Int) -> Range<Int> {
        guard count > 0 else {
            return 0 ..< 0
        }
        let length = visible.upperBound - visible.lowerBound + 1
        let lower = max(0, visible.lowerBound - length)
        let upper = min(count, visible.upperBound + 1 + length)
        if lower >= upper {
            return 0 ..< 0
        }
        return lower ..< upper
    }

    // The window for a grid that is being scrolled: one screen ahead in the scroll direction (`direction` > 0 means
    // towards higher indices, < 0 towards lower, 0 unknown) and half a screen behind, so a reversal still finds the
    // cells it just left. Unknown direction: half a screen on each side. Clamped to the fetch result.
    public static func directionalWindow(visible: ClosedRange<Int>, count: Int, direction: Int) -> Range<Int> {
        guard count > 0 else {
            return 0 ..< 0
        }
        let length = visible.upperBound - visible.lowerBound + 1
        let half = (length + 1) / 2
        // How far the window reaches below the first and above the last visible index.
        let below: Int
        let above: Int
        if direction > 0 {
            below = half
            above = length
        } else if direction < 0 {
            below = length
            above = half
        } else {
            below = half
            above = half
        }
        let lower = max(0, visible.lowerBound - below)
        let upper = min(count, visible.upperBound + 1 + above)
        if lower >= upper {
            return 0 ..< 0
        }
        return lower ..< upper
    }

    // The scroll direction in index space from the previous and the new first visible index.
    public static func direction(previousLower: Int?, lower: Int, previousDirection: Int) -> Int {
        guard let previousLower, previousLower != lower else {
            return previousDirection
        }
        return lower > previousLower ? 1 : -1
    }

    // The ranges to start and to stop when the window moves from `previous` to `next`.
    public static func diff(previous: Range<Int>?, next: Range<Int>?) -> (start: [Range<Int>], stop: [Range<Int>]) {
        let previous = previous.flatMap { $0.isEmpty ? nil : $0 }
        let next = next.flatMap { $0.isEmpty ? nil : $0 }
        switch (previous, next) {
        case (nil, nil):
            return ([], [])
        case let (nil, next?):
            return ([next], [])
        case let (previous?, nil):
            return ([], [previous])
        case let (previous?, next?):
            return (subtract(next, previous), subtract(previous, next))
        }
    }

    // `range` without `other`: at most two pieces.
    private static func subtract(_ range: Range<Int>, _ other: Range<Int>) -> [Range<Int>] {
        if other.upperBound <= range.lowerBound || other.lowerBound >= range.upperBound {
            return [range]
        }
        var result: [Range<Int>] = []
        if range.lowerBound < other.lowerBound {
            result.append(range.lowerBound ..< other.lowerBound)
        }
        if other.upperBound < range.upperBound {
            result.append(other.upperBound ..< range.upperBound)
        }
        return result
    }
}
