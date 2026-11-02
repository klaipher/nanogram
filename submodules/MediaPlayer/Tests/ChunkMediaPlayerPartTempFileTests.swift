import XCTest
import Postbox
@testable import TelegramMediaPlayer

final class ChunkMediaPlayerPartTempFileTests: XCTestCase {
    private static let initializeTempBox: Void = {
        TempBox.initializeShared(basePath: NSTemporaryDirectory() + "ChunkMediaPlayerPartTempFileTests-TempBox", processType: "tests", launchSpecificId: Int64(Date().timeIntervalSince1970 * 1000))
    }()

    override func setUp() {
        super.setUp()
        _ = ChunkMediaPlayerPartTempFileTests.initializeTempBox
    }

    private func waitUntilRemoved(_ path: String, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while FileManager.default.fileExists(atPath: path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    private func makeFile() -> TempBoxFile {
        let file = TempBox.shared.tempFile(fileName: "data.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 1, count: 1024))
        return file
    }

    func testReleasedPartThatDeletesOnReleaseRemovesItsFile() {
        let file = self.makeFile()
        var part: ChunkMediaPlayerPart.TempFile? = ChunkMediaPlayerPart.TempFile(file: file, ignoreAudioEditList: true, deletesFileOnRelease: true)
        XCTAssertNotNil(part)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        part = nil
        XCTAssertTrue(self.waitUntilRemoved(file.path))
    }

    func testReleasedPartKeepsItsFileByDefault() {
        let file = self.makeFile()
        var part: ChunkMediaPlayerPart.TempFile? = ChunkMediaPlayerPart.TempFile(file: file, ignoreAudioEditList: true)
        XCTAssertNotNil(part)
        part = nil
        XCTAssertFalse(self.waitUntilRemoved(file.path, timeout: 0.3))
        TempBox.shared.dispose(file)
    }

    func testDisposedFileLeavesNoContextBehind() {
        let file = self.makeFile()
        let directory = (file.path as NSString).deletingLastPathComponent
        TempBox.shared.dispose(file)
        XCTAssertTrue(self.waitUntilRemoved(directory))
    }
}
