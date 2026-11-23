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
        let manager = MultipartUploadManager(headerSize: { 32 }, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
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

    /// A video handed to the uploader while it is still being exported reaches it only once it is past the small-file
    /// limit; the uploader must then use big parts, since small parts cannot carry a file over 10 MB, and still send the
    /// first part (the file's head, rewritten at the end) last.
    func testAGrowingFilePastTheSmallFileLimitUploadsInBigPartsWithTheHeadLast() {
        let path = NSTemporaryDirectory() + "multipart-upload-\(UUID().uuidString)"
        let partSize = 512 * 1024
        let finalSize = 11 * 1024 * 1024 + 100 * 1024
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(count: finalSize)))
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let data = Promise<MultipartUploadData>()
        let uploadedParts = Atomic<[(index: Int, size: Int, bigPart: Bool, bigTotalParts: Int?)]>(value: [])
        let finished = expectation(description: "the upload finished")
        let result = Atomic<MultipartIntermediateResult??>(value: nil)
        let manager = MultipartUploadManager(headerSize: { 32 }, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
            let _ = uploadedParts.modify { $0 + [(part.index, part.data.count, part.bigPart, part.bigTotalParts)] }
            return .complete() |> delay(0.001, queue: Queue.concurrentDefaultQueue())
        }, progress: { _ in
        }, completed: { value in
            let _ = result.swap(.some(value))
            finished.fulfill()
        })
        manager.start()

        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: 0, complete: false))))
        let grownSize = 10 * 1024 * 1024 + 600 * 1024
        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(grownSize), complete: false))))
        let partsWhileGrowing = grownSize / partSize - 1
        let deadline = Date().addingTimeInterval(5.0)
        while uploadedParts.with({ $0.count }) < partsWhileGrowing && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let growing = uploadedParts.with { $0 }
        XCTAssertEqual(growing.map(\.index).sorted(), Array(1 ... partsWhileGrowing), "every full part but the first goes while the file grows")
        XCTAssertTrue(growing.allSatisfy { $0.bigPart && $0.size == partSize && $0.bigTotalParts == nil })

        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(finalSize), complete: true))))
        wait(for: [finished], timeout: 5.0)

        let totalParts = (finalSize + partSize - 1) / partSize
        let all = uploadedParts.with { $0 }
        XCTAssertEqual(all.map(\.index).sorted(), Array(0 ..< totalParts))
        XCTAssertEqual(all.last?.index, 0, "the head goes last")
        XCTAssertTrue(all.allSatisfy { $0.bigPart })
        XCTAssertEqual(all.last?.bigTotalParts, totalParts)
        XCTAssertEqual((result.with { $0 } ?? nil)?.bigTotalParts, totalParts)
    }

    /// A head longer than one part (a long video's reserved `moov`) keeps every part it touches until the file is
    /// complete, and those parts carry the head as it is then, not as it was while the file grew.
    func testAHeadSpanningSeveralPartsIsHeldBackWholeAndSentAsFinallyWritten() {
        let path = NSTemporaryDirectory() + "multipart-upload-\(UUID().uuidString)"
        let partSize = 512 * 1024
        let headerSize = 2 * partSize + 100 * 1024
        let finalSize = 12 * 1024 * 1024 + 300 * 1024
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(count: finalSize)))
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let data = Promise<MultipartUploadData>()
        let uploadedParts = Atomic<[(index: Int, data: Data)]>(value: [])
        let finished = expectation(description: "the upload finished")
        let result = Atomic<MultipartIntermediateResult??>(value: nil)
        let currentHeaderSize = Atomic<Int64>(value: 32 * 1024)
        let manager = MultipartUploadManager(headerSize: { currentHeaderSize.with { $0 } }, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
            let _ = uploadedParts.modify { $0 + [(part.index, part.data)] }
            return .complete() |> delay(0.001, queue: Queue.concurrentDefaultQueue())
        }, progress: { _ in
        }, completed: { value in
            let _ = result.swap(.some(value))
            finished.fulfill()
        })
        manager.start()

        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: 0, complete: false))))
        let _ = currentHeaderSize.swap(Int64(headerSize))
        let grownSize = 11 * 1024 * 1024
        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(grownSize), complete: false))))
        let partsWhileGrowing = grownSize / partSize - 3
        let deadline = Date().addingTimeInterval(5.0)
        while uploadedParts.with({ $0.count }) < partsWhileGrowing && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(uploadedParts.with { $0.map(\.index).sorted() }, Array(3 ..< grownSize / partSize), "the parts the head touches wait")

        guard let handle = FileHandle(forWritingAtPath: path) else {
            XCTFail()
            return
        }
        handle.write(Data(repeating: 0xab, count: headerSize))
        handle.closeFile()
        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(finalSize), complete: true))))
        wait(for: [finished], timeout: 5.0)

        let totalParts = (finalSize + partSize - 1) / partSize
        let all = uploadedParts.with { $0 }
        XCTAssertEqual(all.map(\.index).sorted(), Array(0 ..< totalParts))
        XCTAssertEqual(Set(all.suffix(3).map(\.index)), [0, 1, 2], "the head goes last")
        for part in all where part.index < 3 {
            let start = part.index * partSize
            let expected = Data(repeating: 0xab, count: min(headerSize - start, partSize)) + Data(count: partSize - min(headerSize - start, partSize))
            XCTAssertEqual(part.data, expected, "part \(part.index) carries the final head")
        }
        XCTAssertEqual((result.with { $0 } ?? nil)?.bigTotalParts, totalParts)
        XCTAssertEqual((result.with { $0 } ?? nil)?.partCount, Int32(totalParts))
    }

    func testAGrowingFileWithoutBigPartsKeepsSmallPartsAndSendsTheHeadLast() {
        let path = NSTemporaryDirectory() + "multipart-upload-\(UUID().uuidString)"
        let partSize = 128 * 1024
        let headerSize = partSize + 50 * 1024
        let finalSize = 10 * 1024 * 1024 + 300 * 1024
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(count: finalSize)))
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let data = Promise<MultipartUploadData>()
        let uploadedParts = Atomic<[(index: Int, size: Int, bigPart: Bool)]>(value: [])
        let finished = expectation(description: "the upload finished")
        let result = Atomic<MultipartIntermediateResult??>(value: nil)
        let manager = MultipartUploadManager(headerSize: { Int64(headerSize) }, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: true, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
            let _ = uploadedParts.modify { $0 + [(part.index, part.data.count, part.bigPart)] }
            return .complete() |> delay(0.001, queue: Queue.concurrentDefaultQueue())
        }, progress: { _ in
        }, completed: { value in
            let _ = result.swap(.some(value))
            finished.fulfill()
        })
        manager.start()

        let grownSize = 1024 * 1024
        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(grownSize), complete: false))))
        let deadline = Date().addingTimeInterval(5.0)
        while uploadedParts.with({ $0.count }) < grownSize / partSize - 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(uploadedParts.with { $0.map(\.index).sorted() }, Array(2 ..< grownSize / partSize), "the parts the head touches wait")

        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(finalSize), complete: true))))
        wait(for: [finished], timeout: 5.0)

        let totalParts = (finalSize + partSize - 1) / partSize
        let all = uploadedParts.with { $0 }
        XCTAssertEqual(all.map(\.index).sorted(), Array(0 ..< totalParts))
        XCTAssertEqual(Set(all.suffix(2).map(\.index)), [0, 1], "the head goes last")
        XCTAssertTrue(all.allSatisfy { !$0.bigPart })
        XCTAssertTrue(all.allSatisfy { $0.size == partSize || $0.index == totalParts - 1 })
        XCTAssertNil((result.with { $0 } ?? nil)?.bigTotalParts)
        XCTAssertEqual((result.with { $0 } ?? nil)?.partCount, Int32(totalParts))
    }
    
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
        let manager = MultipartUploadManager(headerSize: { 32 * 1024 }, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
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

    /// The upload catches up with the writer while the file crosses 10 MB, with no part in flight: the early switch to
    /// big parts must not fire after small parts were committed (same file id, inflated part count).
    func testACrossingOf10MBWhileGrowingAfterSmallPartsWereSentDoesNotSwitchToBigPartsUnderTheSameId() {
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
        let manager = MultipartUploadManager(headerSize: { 32 * 1024 }, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
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
        XCTAssertEqual(earlyParts.count, 7)
        let earlyFileId = earlyParts.first?.fileId

        // Still growing, now over the small-file limit, nothing in flight.
        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: 10 * 1024 * 1024 + 1024, complete: false))))
        Thread.sleep(forTimeInterval: 0.3)
        let beforeComplete = sentParts.with { $0 }
        XCTAssertTrue(beforeComplete.allSatisfy { !$0.bigPart }, "no big part goes out under the id that holds small parts")

        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(size), complete: true))))
        wait(for: [finished], timeout: 10.0)

        let all = sentParts.with { $0 }
        XCTAssertTrue(all.filter { $0.fileId == earlyFileId }.allSatisfy { !$0.bigPart })
        let bigParts = all.filter { $0.bigPart }
        XCTAssertEqual(Set(bigParts.map(\.fileId)).count, 1)
        XCTAssertNotEqual(bigParts.first?.fileId, earlyFileId)
        XCTAssertEqual(bigParts.map(\.index).sorted(), Array(0 ..< 21))
        guard let completedResult = result.with({ $0 }), let value = completedResult else {
            XCTFail("the upload failed")
            return
        }
        XCTAssertEqual(value.id, bigParts.first?.fileId)
        XCTAssertEqual(value.bigTotalParts, 21)
        XCTAssertEqual(value.partCount, 21, "the abandoned small parts are not counted")
    }

    func testASmallFileOfKnownSizeIsUploadedIn128KBParts() {
        let size = 300 * 1024
        let sentParts = Atomic<[UploadPart]>(value: [])
        let finished = expectation(description: "the upload finished")
        let result = Atomic<MultipartIntermediateResult??>(value: nil)
        let manager = MultipartUploadManager(headerSize: { 0 }, data: .single(.data(Data(count: size))), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, uploadPart: { part in
            let _ = sentParts.modify { $0 + [part] }
            return .complete()
        }, progress: { _ in
        }, completed: { value in
            let _ = result.swap(.some(value))
            finished.fulfill()
        })
        manager.start()
        wait(for: [finished], timeout: 5.0)

        let parts = sentParts.with { $0 }.sorted(by: { $0.index < $1.index })
        XCTAssertEqual(parts.map(\.index), [0, 1, 2])
        XCTAssertEqual(parts.map(\.data.count), [128 * 1024, 128 * 1024, 44 * 1024])
        XCTAssertTrue(parts.allSatisfy { !$0.bigPart })
        XCTAssertEqual((result.with { $0 } ?? nil)?.partCount, 3)
    }

    func testPartsInFlight() {
        XCTAssertEqual(self.partsInFlight(size: 4 * 1024 * 1024, increaseParallelParts: false), 6, "parts under 512 KB")
        XCTAssertEqual(self.partsInFlight(size: 11 * 1024 * 1024, increaseParallelParts: false), 3, "512 KB parts of a big file")
        XCTAssertEqual(self.partsInFlight(size: 20 * 1024 * 1024, increaseParallelParts: true), 30)
        XCTAssertEqual(self.partsInFlight(size: 8 * 1024 * 1024, increaseParallelParts: true), 30)
    }

    /// M1: on cellular the first window is 4 parts of 128 KB.
    func testCellularStartsWithFourSmallParts() {
        XCTAssertEqual(self.partsInFlight(size: 4 * 1024 * 1024, increaseParallelParts: false, networkClass: .cellular), 4)
    }

    /// M2: and 2 big parts of 512 KB (the window restarts for the big part size before anything is sent).
    func testCellularStartsWithTwoBigParts() {
        XCTAssertEqual(self.partsInFlight(size: 11 * 1024 * 1024, increaseParallelParts: false, networkClass: .cellular), 2)
    }

    /// M4: a part with no answer after the stall timeout shrinks the window; nothing is cancelled and the upload ends.
    func testAStalledPartShrinksTheWindow() {
        let run = self.runWithSlowParts(stallTimeout: 0.2, announceRetry: false)
        XCTAssertTrue(run.completed)
        XCTAssertGreaterThan(run.callCount, 6)
        XCTAssertLessThanOrEqual(run.maxConcurrentAfterFirstSix, 3)
    }

    /// M6: a part the retry wrapper reports as retried halves the window the same way.
    func testARetriedPartShrinksTheWindow() {
        let run = self.runWithSlowParts(stallTimeout: 100.0, announceRetry: true)
        XCTAssertTrue(run.completed)
        XCTAssertLessThanOrEqual(run.maxConcurrentAfterFirstSix, 3)
    }

    private func runWithSlowParts(stallTimeout: Double, announceRetry: Bool) -> (completed: Bool, callCount: Int, maxConcurrentAfterFirstSix: Int) {
        let calls = Atomic<Int>(value: 0)
        let concurrent = Atomic<Int>(value: 0)
        let maxAfterFirstSix = Atomic<Int>(value: 0)
        let finished = expectation(description: "the upload finished")
        let result = Atomic<MultipartIntermediateResult??>(value: nil)
        let manager = MultipartUploadManager(headerSize: { 0 }, data: .single(.data(Data(count: 2 * 1024 * 1024))), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, networkClass: .wifi, stallTimeout: stallTimeout, uploadPart: { part in
            let call = calls.modify { $0 + 1 }
            let now = concurrent.modify { $0 + 1 }
            if call > 6 {
                let _ = maxAfterFirstSix.modify { max($0, now) }
            }
            if announceRetry && call <= 6 {
                part.onRetry?(0.01)
            }
            return Signal<Void, UploadPartError> { subscriber in
                let timer = SwiftSignalKit.Timer(timeout: 0.5, repeat: false, completion: {
                    let _ = concurrent.modify { $0 - 1 }
                    subscriber.putCompletion()
                }, queue: Queue.concurrentDefaultQueue())
                timer.start()
                return ActionDisposable {
                    timer.invalidate()
                }
            }
        }, progress: { _ in
        }, completed: { value in
            let _ = result.swap(.some(value))
            finished.fulfill()
        })
        manager.start()
        wait(for: [finished], timeout: 30.0)
        return (completed: (result.with { $0 } ?? nil) != nil, callCount: calls.with { $0 }, maxConcurrentAfterFirstSix: maxAfterFirstSix.with { $0 })
    }

    /// M8: one summary line per upload, on success and on failure, whatever the number of failing parts.
    func testOneFinishLinePerUpload() {
        for succeed in [true, false] {
            let lines = Atomic<[String]>(value: [])
            let finished = expectation(description: "the upload finished (\(succeed))")
            finished.assertForOverFulfill = false
            let manager = MultipartUploadManager(headerSize: { 0 }, data: .single(.data(Data(count: 300 * 1024))), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, networkClass: .wifi, finishLog: { line in
                let _ = lines.modify { $0 + [line] }
            }, uploadPart: { _ in
                return succeed ? .complete() : .fail(.generic)
            }, progress: { _ in
            }, completed: { _ in
                finished.fulfill()
            })
            manager.start()
            wait(for: [finished], timeout: 5.0)
            Thread.sleep(forTimeInterval: 0.1)
            let recorded = lines.with { $0 }
            XCTAssertEqual(recorded.count, 1)
            let line = recorded.first ?? ""
            XCTAssertTrue(line.hasPrefix("upload end ok=\(succeed ? 1 : 0) "), line)
            for key in ["parts=", "bytes=", "ms=", "part=131072", "win=", "retries=", "stalls=", "fails=", "dec=", "net=wifi>wifi"] {
                XCTAssertTrue(line.contains(key), "\(key) in \(line)")
            }
            if succeed {
                XCTAssertTrue(line.contains("parts=3 bytes=307200"), line)
            }
        }
    }

    /// M7: with a growing file whose head goes last, the window shrinking underneath changes nothing about the order.
    func testAShrinkingWindowKeepsTheHeadLast() {
        let path = NSTemporaryDirectory() + "multipart-upload-\(UUID().uuidString)"
        let size = 1024 * 1024
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(count: size)))
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let data = Promise<MultipartUploadData>()
        let order = Atomic<[Int]>(value: [])
        let concurrent = Atomic<Int>(value: 0)
        let maxConcurrent = Atomic<Int>(value: 0)
        let finished = expectation(description: "the upload finished")
        let result = Atomic<MultipartIntermediateResult??>(value: nil)
        let manager = MultipartUploadManager(headerSize: { 32 }, data: data.get(), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: false, networkClass: .wifi, stallTimeout: 0.05, uploadPart: { part in
            let _ = order.modify { $0 + [part.index] }
            let now = concurrent.modify { $0 + 1 }
            let _ = maxConcurrent.modify { max($0, now) }
            return Signal<Void, UploadPartError> { subscriber in
                let timer = SwiftSignalKit.Timer(timeout: 0.15, repeat: false, completion: {
                    let _ = concurrent.modify { $0 - 1 }
                    subscriber.putCompletion()
                }, queue: Queue.concurrentDefaultQueue())
                timer.start()
                return ActionDisposable {
                    timer.invalidate()
                }
            }
        }, progress: { _ in
        }, completed: { value in
            let _ = result.swap(.some(value))
            finished.fulfill()
        })
        manager.start()
        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(size), complete: false))))
        let deadline = Date().addingTimeInterval(10.0)
        while order.with({ $0.count }) < 7 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.5)
        data.set(.single(.resourceData(MediaResourceData(path: path, offset: 0, size: Int64(size), complete: true))))
        wait(for: [finished], timeout: 10.0)
        XCTAssertNotNil(result.with { $0 } ?? nil)
        XCTAssertEqual(order.with { $0 }.sorted(), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(order.with { $0 }.last, 0, "the head goes last")
        XCTAssertLessThanOrEqual(maxConcurrent.with { $0 }, 6)
    }

    private func partsInFlight(size: Int, increaseParallelParts: Bool, networkClass: UploadPartWindow.NetworkClass? = nil) -> Int {
        let sentParts = Atomic<Int>(value: 0)
        let manager = MultipartUploadManager(headerSize: { 0 }, data: .single(.data(Data(count: size))), encryptionKey: nil, hintFileSize: nil, hintFileIsLarge: false, forceNoBigParts: false, useLargerParts: false, increaseParallelParts: increaseParallelParts, networkClass: networkClass, uploadPart: { _ in
            let _ = sentParts.modify { $0 + 1 }
            return .never()
        }, progress: { _ in
        }, completed: { _ in
        })
        manager.start()
        let deadline = Date().addingTimeInterval(3.0)
        var last = -1
        var stableSamples = 0
        while Date() < deadline && stableSamples < 5 {
            Thread.sleep(forTimeInterval: 0.05)
            let current = sentParts.with { $0 }
            if current == last && current > 0 {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            last = current
        }
        manager.cancel()
        return sentParts.with { $0 }
    }
}
