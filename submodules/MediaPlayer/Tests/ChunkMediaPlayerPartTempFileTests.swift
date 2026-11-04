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

    private func makeFile() -> TempBoxFile {
        let file = TempBox.shared.tempFile(fileName: "data.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 1, count: 1024))
        return file
    }

    func testReleasedPartThatDeletesOnReleaseRemovesItsFile() {
        let file = self.makeFile()
        let count = TempBox.shared.activeContextCount
        var part: ChunkMediaPlayerPart.TempFile? = ChunkMediaPlayerPart.TempFile(file: file, ignoreAudioEditList: true, deletesFileOnRelease: true)
        XCTAssertNotNil(part)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        part = nil
        XCTAssertEqual(TempBox.shared.activeContextCount, count - 1)
    }

    func testReleasedPartKeepsItsFileByDefault() {
        let file = self.makeFile()
        let count = TempBox.shared.activeContextCount
        var part: ChunkMediaPlayerPart.TempFile? = ChunkMediaPlayerPart.TempFile(file: file, ignoreAudioEditList: true)
        XCTAssertNotNil(part)
        part = nil
        XCTAssertEqual(TempBox.shared.activeContextCount, count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        TempBox.shared.dispose(file)
    }

    func testDisposedFileLeavesNoContextBehind() {
        let file = self.makeFile()
        let count = TempBox.shared.activeContextCount
        TempBox.shared.dispose(file)
        XCTAssertEqual(TempBox.shared.activeContextCount, count - 1)
    }
}
