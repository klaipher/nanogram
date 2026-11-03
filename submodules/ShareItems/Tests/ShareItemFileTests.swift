import XCTest
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import MtProtoKit
import SwiftSignalKit
import ShareItemsImpl
import ShareItems

// I-11: attachments are loaded as files (NSItemProvider.loadFileRepresentation), cloned into a
// directory the share owns, and read from there piece by piece; nothing large is read into memory.

private func makeTemporaryDirectory(_ name: String) -> String {
    let path = NSTemporaryDirectory() + "\(name)-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// The process's footprint as jetsam counts it (dirty + compressed memory), and its peak.
private func physFootprint() -> (current: Int64, peak: Int64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
        }
    }
    XCTAssertEqual(result, KERN_SUCCESS)
    return (Int64(info.phys_footprint), Int64(info.ledger_phys_footprint_peak))
}

/// A provider that loads its attachment from a file only when asked. Its contents are mapped, so
/// the stub itself holds no memory. (A `registerFileRepresentation` stub cannot be loaded in a
/// logic-test process: NSItemProvider's own copy of the file fails there. Asked for a file, the
/// system writes a data representation to disk, which is the same path the app takes.)
///
/// The type database is not available to this process either, so only an identical identifier
/// conforms: the stubs register the generic types the share extension checks for.
private func fileProvider(url: URL, typeIdentifier: String, suggestedName: String? = nil) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = suggestedName
    provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
        completion(try? Data(contentsOf: url, options: .alwaysMapped), nil)
        return nil
    }
    return provider
}

private func extensionItems(_ providers: [NSItemProvider]) -> [NSExtensionItem] {
    let item = NSExtensionItem()
    item.attachments = providers
    return [item]
}

private func writePng(path: String, width: Int, height: Int) {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
        UIColor.blue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    try! image.pngData()!.write(to: URL(fileURLWithPath: path))
}

/// 16-bit mono PCM in a WAV container.
private func writeWav(path: String, seconds: Double) {
    let sampleRate: UInt32 = 8000
    let sampleCount = UInt32(Double(sampleRate) * seconds)
    let dataSize = sampleCount * 2
    var data = Data()
    func append<T>(_ value: T) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataSize).littleEndian)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16).littleEndian)
    append(UInt16(1).littleEndian)
    append(UInt16(1).littleEndian)
    append(sampleRate.littleEndian)
    append((sampleRate * 2).littleEndian)
    append(UInt16(2).littleEndian)
    append(UInt16(16).littleEndian)
    data.append(contentsOf: Array("data".utf8))
    append(dataSize.littleEndian)
    for i in 0 ..< Int(sampleCount) {
        append(Int16(sin(Double(i) * 0.3) * 8000.0).littleEndian)
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

/// An H.264 movie of `frameCount` frames at 10 frames per second.
func writeTestMovie(path: String, width: Int, height: Int, frameCount: Int) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: path.hasSuffix(".mov") ? .mov : .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0 ..< frameCount {
        while !input.isReadyForMoreMediaData {
            usleep(1000)
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20 % 255), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting {
        done.signal()
    }
    done.wait()
    XCTAssertEqual(writer.status, .completed)
}

final class ShareItemFileRepresentationTests: XCTestCase {
    private var sourceDirectory: String!
    private var shareDirectory: String!

    override func setUp() {
        super.setUp()
        self.sourceDirectory = makeTemporaryDirectory("ShareItemSource")
        self.shareDirectory = makeTemporaryDirectory("ShareItemFiles")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.sourceDirectory)
        try? FileManager.default.removeItem(atPath: self.shareDirectory)
        super.tearDown()
    }

    private func load(_ providers: [NSItemProvider], highQuality: Bool = false, timeout: Double = 10.0) -> [[String: Any]]? {
        let signals: [MTSignal] = TGItemProviderSignals.itemSignals(forInputItems: extensionItems(providers), highQuality: highQuality, temporaryDirectory: self.shareDirectory)
        let done = expectation(description: "loaded")
        var result: [[String: Any]]?
        let disposable = shareItemDictionaries(dataItems: signals).start(next: { items in
            result = items
        }, error: { _ in
            done.fulfill()
        }, completed: {
            done.fulfill()
        })
        wait(for: [done], timeout: timeout)
        disposable.dispose()
        return result
    }

    private func isInShareDirectory(_ path: String?) -> Bool {
        guard let path else {
            return false
        }
        return (path as NSString).standardizingPath.hasPrefix((self.shareDirectory as NSString).standardizingPath + "/")
    }

    func testFileIsClonedIntoTheShareDirectoryNotReadIntoMemory() {
        let source = self.sourceDirectory + "/Report.pdf"
        let contents = Data((0 ..< 100_000).map { UInt8($0 % 251) })
        try! contents.write(to: URL(fileURLWithPath: source))

        let items = load([fileProvider(url: URL(fileURLWithPath: source), typeIdentifier: UTType.data.identifier, suggestedName: "Report.pdf")])
        XCTAssertEqual(items?.count, 1)
        let item = items?.first ?? [:]
        XCTAssertNil(item["data"], "the attachment was read into memory")
        let path = item["path"] as? String
        XCTAssertTrue(isInShareDirectory(path), "not a copy in the share's directory: \(String(describing: path))")
        if let path {
            XCTAssertEqual(FileManager.default.contents(atPath: path), contents)
        }
        XCTAssertEqual(item["fileName"] as? String, "Report.pdf")
        XCTAssertEqual(item["mimeType"] as? String, "application/pdf")
        // The provider's own file is left alone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
    }

    func testVideoIsSentFromAFileCopy() {
        let source = self.sourceDirectory + "/clip.mp4"
        writeTestMovie(path: source, width: 320, height: 240, frameCount: 10)

        let items = load([fileProvider(url: URL(fileURLWithPath: source), typeIdentifier: UTType.movie.identifier, suggestedName: "clip.mp4")])
        let item = items?.first ?? [:]
        let asset = item["video"] as? AVURLAsset
        XCTAssertNotNil(asset)
        XCTAssertTrue(isInShareDirectory(asset?.url.path), "not a copy in the share's directory: \(String(describing: asset?.url.path))")
        XCTAssertEqual(item["width"] as? CGFloat, 320.0)
        XCTAssertEqual(item["height"] as? CGFloat, 240.0)
        XCTAssertEqual(item["mimeType"] as? String, "video/mp4")
    }

    func testAudioIsSentFromAFileCopy() {
        let source = self.sourceDirectory + "/memo.wav"
        writeWav(path: source, seconds: 2.0)

        let items = load([fileProvider(url: URL(fileURLWithPath: source), typeIdentifier: UTType.audio.identifier, suggestedName: "memo.wav")])
        let item = items?.first ?? [:]
        let url = item["audio"] as? URL
        XCTAssertTrue(isInShareDirectory(url?.path), "not a copy in the share's directory: \(String(describing: url?.path))")
        XCTAssertEqual((item["duration"] as? NSNumber)?.doubleValue ?? 0.0, 2.0, accuracy: 0.05)
    }

    // I-3/I-7: a photo is downsampled straight from the file to the long side it is sent at.
    func testPhotoIsDownsampledFromTheFile() {
        let source = self.sourceDirectory + "/photo.png"
        writePng(path: source, width: 3000, height: 2000)

        for (highQuality, expectedWidth) in [(false, 1280.0), (true, 2560.0)] {
            let items = load([fileProvider(url: URL(fileURLWithPath: source), typeIdentifier: UTType.image.identifier)], highQuality: highQuality)
            let item = items?.first ?? [:]
            XCTAssertNil(item["data"], "the photo was read into memory")
            XCTAssertNil(item["image"], "the photo was decoded at full size")
            XCTAssertEqual((item["scaledImageDimensions"] as? NSValue)?.cgSizeValue.width, CGFloat(expectedWidth))
            XCTAssertNotNil(item["scaledImageData"] as? Data)
        }
    }

    // A share of several kinds keeps its order, and each large item is its own copy.
    func testSeveralAttachmentsEachGetTheirOwnCopy() {
        let first = self.sourceDirectory + "/a.zip"
        let second = self.sourceDirectory + "/b.zip"
        try! Data("first".utf8).write(to: URL(fileURLWithPath: first))
        try! Data("second".utf8).write(to: URL(fileURLWithPath: second))

        let items = load([
            fileProvider(url: URL(fileURLWithPath: first), typeIdentifier: UTType.data.identifier, suggestedName: "same.zip"),
            fileProvider(url: URL(fileURLWithPath: second), typeIdentifier: UTType.data.identifier, suggestedName: "same.zip")
        ])
        let paths = (items ?? []).compactMap { $0["path"] as? String }
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(Set(paths).count, 2)
        XCTAssertEqual(paths.compactMap { FileManager.default.contents(atPath: $0) }, [Data("first".utf8), Data("second".utf8)])
    }

    // The extension's limit is ~120 MB: sharing a file several times that size must not grow the
    // footprint by anything like its size.
    func testLargeFileDoesNotGrowTheFootprint() {
        let size: UInt64 = 400 * 1024 * 1024
        let source = self.sourceDirectory + "/large.zip"
        FileManager.default.createFile(atPath: source, contents: nil)
        let handle = FileHandle(forWritingAtPath: source)!
        try! handle.truncate(atOffset: size)
        try! handle.close()

        let before = physFootprint()
        var items: [[String: Any]]?
        autoreleasepool {
            items = load([fileProvider(url: URL(fileURLWithPath: source), typeIdentifier: UTType.data.identifier, suggestedName: "large.zip")], timeout: 60.0)
        }
        let item = items?.first ?? [:]
        let path = item["path"] as? String
        XCTAssertTrue(isInShareDirectory(path))
        if let path {
            XCTAssertEqual(shareItemFileContent(path: path), .other)
            XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value, size)
        }
        let after = physFootprint()
        print("ShareItemFileTests: 400 MB file, footprint \((after.current - before.current) / 1024) KB, peak \((after.peak - max(before.peak, before.current)) / 1024) KB")
        let limit: Int64 = 48 * 1024 * 1024
        XCTAssertLessThan(after.current - before.current, limit, "footprint grew by \((after.current - before.current) / 1024 / 1024) MB")
        XCTAssertLessThan(after.peak - max(before.peak, before.current), limit, "peak footprint grew by \((after.peak - before.peak) / 1024 / 1024) MB")
        withExtendedLifetime(items) {}
    }
}

final class ShareItemFileContentTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        self.directory = makeTemporaryDirectory("ShareItemFileContent")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    // A shared file is sent as a photo or a GIF when it is one, as before, but decided from the
    // file's header instead of decoding it.
    func testKindIsReadFromTheFile() {
        let png = self.directory + "/a.bin"
        writePng(path: png, width: 40, height: 30)
        XCTAssertEqual(shareItemFileContent(path: png), .image)

        let gif = self.directory + "/b.bin"
        let gifData = Data(base64Encoded: "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==")!
        try! gifData.write(to: URL(fileURLWithPath: gif))
        XCTAssertEqual(shareItemFileContent(path: gif), .gif)

        let text = self.directory + "/c.txt"
        try! Data("hello".utf8).write(to: URL(fileURLWithPath: text))
        XCTAssertEqual(shareItemFileContent(path: text), .other)

        XCTAssertEqual(shareItemFileContent(path: self.directory + "/missing"), .other)
    }
}

final class ShareItemFilesLifetimeTests: XCTestCase {
    private var parent: String!

    override func setUp() {
        super.setUp()
        self.parent = makeTemporaryDirectory("ShareItemFilesLifetime")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.parent)
        super.tearDown()
    }

    private func contents() -> [String] {
        return (try? FileManager.default.contentsOfDirectory(atPath: self.parent)) ?? []
    }

    private func waitUntilEmpty(file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5.0)
        while !contents().isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(contents(), [], "the share's copies were left behind", file: file, line: line)
    }

    private func copyIn(_ directory: String) -> String {
        let path = directory + "/copy.bin"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        return path
    }

    func testCopiesAreRemovedWhenTheShareCompletes() {
        var seenPath: String?
        var existedWhileRunning = false
        let _ = withShareItemFiles(parentPath: self.parent) { directory -> Signal<Int, NoError> in
            let path = self.copyIn(directory)
            seenPath = path
            existedWhileRunning = FileManager.default.fileExists(atPath: path)
            return .single(1)
        }.start()
        XCTAssertTrue(existedWhileRunning)
        XCTAssertNotNil(seenPath)
        waitUntilEmpty()
    }

    func testCopiesAreRemovedWhenTheShareFails() {
        let _ = withShareItemFiles(parentPath: self.parent) { directory -> Signal<Int, PreparedShareItemError> in
            let _ = self.copyIn(directory)
            return .fail(.generic)
        }.start()
        waitUntilEmpty()
    }

    func testCopiesAreRemovedWhenTheShareIsCancelled() {
        let disposable = withShareItemFiles(parentPath: self.parent) { directory -> Signal<Int, NoError> in
            let _ = self.copyIn(directory)
            return .never()
        }.start()
        XCTAssertEqual(contents().count, 1)
        disposable.dispose()
        waitUntilEmpty()
    }

    // Each send attempt gets its own directory: a retry after a failure does not see, or remove,
    // another attempt's copies.
    func testEachAttemptHasItsOwnDirectory() {
        var directories: [String] = []
        let first = withShareItemFiles(parentPath: self.parent) { directory -> Signal<Int, NoError> in
            directories.append(directory)
            return .never()
        }.start()
        let second = withShareItemFiles(parentPath: self.parent) { directory -> Signal<Int, NoError> in
            directories.append(directory)
            return .never()
        }.start()
        XCTAssertEqual(Set(directories).count, 2)
        first.dispose()
        second.dispose()
        waitUntilEmpty()
    }
}

final class SharedStoryVideoMetadataTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        self.directory = makeTemporaryDirectory("SharedStoryVideoMetadata")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    private func metadata(path: String) -> SharedStoryVideoMetadata? {
        let done = expectation(description: "metadata")
        var result: SharedStoryVideoMetadata?
        let disposable = SharedStorySession.videoMetadata(path: path).start(next: { value in
            result = value
            done.fulfill()
        })
        wait(for: [done], timeout: 10.0)
        disposable.dispose()
        return result
    }

    // The values the editor got before, when they were read synchronously.
    func testValuesMatchTheSynchronousReads() {
        let path = self.directory + "/story.mp4"
        writeTestMovie(path: path, width: 320, height: 240, frameCount: 15)
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let expectedSize = asset.tracks(withMediaType: .video).first?.naturalSize
        let expectedDuration = asset.duration.seconds

        let result = metadata(path: path)
        XCTAssertNotNil(expectedSize)
        XCTAssertEqual(result?.dimensions, expectedSize)
        XCTAssertEqual(result?.duration, expectedDuration)
        XCTAssertEqual(result?.duration ?? 0.0, 1.5, accuracy: 0.01)
    }

    func testUnreadableFileHasNoDimensionsAndTheSameDuration() {
        let path = self.directory + "/broken.mp4"
        try! Data("not a movie".utf8).write(to: URL(fileURLWithPath: path))
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let expectedDuration = asset.duration.seconds

        let result = metadata(path: path)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.dimensions)
        if expectedDuration.isNaN {
            XCTAssertTrue(result?.duration.isNaN ?? false)
        } else {
            XCTAssertEqual(result?.duration, expectedDuration)
        }
    }

    // The freeze: the reads ran on the main thread while the screen waited. They now run on a
    // background thread and finish even while the main thread is blocked.
    func testNeverRunsOnTheMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        let path = self.directory + "/story.mov"
        writeTestMovie(path: path, width: 160, height: 160, frameCount: 5)

        let finished = DispatchSemaphore(value: 0)
        let deliveredOnMain = Atomic<Bool?>(value: nil)
        let disposable = SharedStorySession.videoMetadata(path: path).start(next: { _ in
            let _ = deliveredOnMain.swap(Thread.isMainThread)
            finished.signal()
        })
        XCTAssertNil(deliveredOnMain.with { $0 }, "the metadata was read synchronously on the calling (main) thread")
        // The main thread stays blocked here; the read must not need it.
        XCTAssertEqual(finished.wait(timeout: .now() + 10.0), .success)
        XCTAssertEqual(deliveredOnMain.with { $0 }, false)
        disposable.dispose()
    }
}
