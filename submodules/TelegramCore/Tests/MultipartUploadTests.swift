import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

final class MultipartUploadTests: XCTestCase {
    /// A file uploaded while it is still being written (a recorded video) sends its first part last,
    /// once the file is complete. If the file can no longer be read by then, the upload failed silently
    /// and waited for ever.
    func testAnUnreadableFileFailsTheLastHeaderPartInsteadOfHanging() {
        let path = NSTemporaryDirectory() + "multipart-upload-\(UUID().uuidString)"
        let size = 256 * 1024
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(count: size)))
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let data = Promise<MultipartUploadData>()
        let uploadedParts = Atomic<[Int]>(value: [])
        let finished = expectation(description: "the upload finished")
        let result = Atomic<MultipartIntermediateResult??>(value: nil)
        let manager = MultipartUploadManager(headerSize: 32, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
            let _ = uploadedParts.modify { $0 + [part.index] }
            return .complete()
        }, progress: { _ in
        }, completed: { value in
            let _ = result.swap(.some(value))
            finished.fulfill()
        })
        manager.start()

        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(size), complete: false))))
        let deadline = Date().addingTimeInterval(5.0)
        while uploadedParts.with({ $0 }) != [1] && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(uploadedParts.with { $0 }, [1], "every part but the first goes while the file grows")

        try? FileManager.default.removeItem(atPath: path)
        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(size), complete: true))))

        wait(for: [finished], timeout: 5.0)
        XCTAssertNotNil(result.with { $0 })
        XCTAssertNil(result.with { $0 } ?? nil, "the upload fails")
        XCTAssertEqual(uploadedParts.with { $0 }, [1])
    }

    /// A conversion output uploads while it is written, so its parts start out as a small file's when its
    /// size is not yet known. If it ends up over the small-file limit, the server accepts it only as a big
    /// file: the upload starts over under a new id, and its result counts only the parts sent after that.
    func testAGrowingFileThatEndsUpOverTheSmallFileLimitIsUploadedAgainAsABigFile() {
        let path = NSTemporaryDirectory() + "multipart-upload-\(UUID().uuidString)"
        let size = 10 * 1024 * 1024 + 512 * 1024
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(count: size)))
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let data = Promise<MultipartUploadData>()
        let sentParts = Atomic<[UploadPart]>(value: [])
        let finished = expectation(description: "the upload finished")
        let result = Atomic<MultipartIntermediateResult??>(value: nil)
        let manager = MultipartUploadManager(headerSize: 32 * 1024, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
            let _ = sentParts.modify { $0 + [part] }
            return .complete()
        }, progress: { _ in
        }, completed: { value in
            let _ = result.swap(.some(value))
            finished.fulfill()
        })
        manager.start()

        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: 1024 * 1024, complete: false))))
        let deadline = Date().addingTimeInterval(5.0)
        while sentParts.with({ $0.count }) < 7 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let earlyParts = sentParts.with { $0 }
        XCTAssertEqual(earlyParts.map(\.index), Array(1 ... 7), "the growing file goes out in small parts, all but the first")
        XCTAssertTrue(earlyParts.allSatisfy { !$0.bigPart })
        let earlyFileId = earlyParts.first?.fileId

        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(size), complete: true))))
        wait(for: [finished], timeout: 5.0)

        let bigParts = sentParts.with { Array($0.dropFirst(earlyParts.count)) }
        XCTAssertEqual(bigParts.map(\.index).sorted(), Array(0 ..< 21), "every part of the big file, the first included")
        XCTAssertTrue(bigParts.allSatisfy { $0.bigPart && $0.bigTotalParts == 21 })
        XCTAssertTrue(bigParts.allSatisfy { $0.data.count == 512 * 1024 })
        XCTAssertEqual(Set(bigParts.map(\.fileId)).count, 1)
        XCTAssertNotEqual(bigParts.first?.fileId, earlyFileId, "the big file is a new upload")

        guard let completedResult = result.with({ $0 }), let value = completedResult else {
            XCTFail("the upload failed")
            return
        }
        XCTAssertEqual(value.id, bigParts.first?.fileId)
        XCTAssertEqual(value.bigTotalParts, 21)
        XCTAssertEqual(value.partCount, 21, "the abandoned small parts are not counted")
        XCTAssertEqual(value.size, Int64(size))
    }
}
