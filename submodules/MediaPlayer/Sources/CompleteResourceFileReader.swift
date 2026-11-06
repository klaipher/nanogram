import Foundation

/// Reads ranges of a fully downloaded resource straight into the caller's buffer through one open handle. Going through
/// `MediaBox.resourceData` opens and stats the file for every read and returns a freshly allocated `Data` that is then
/// copied once more into the demuxer's buffer.
final class CompleteResourceFileReader {
    private let size: Int64
    private let readAt: (UnsafeMutableRawPointer, Int, Int64) -> Int

    init(size: Int64, readAt: @escaping (UnsafeMutableRawPointer, Int, Int64) -> Int) {
        self.size = size
        self.readAt = readAt
    }

    /// Bytes read into `buffer` (at most `maxCount`), or 0 at the end of the file.
    func read(into buffer: UnsafeMutableRawPointer, offset: Int64, maxCount: Int) -> Int {
        if offset < 0 || offset >= self.size || maxCount <= 0 {
            return 0
        }
        let count = Int(min(Int64(maxCount), self.size - offset))
        return max(0, self.readAt(buffer, count, offset))
    }
}
