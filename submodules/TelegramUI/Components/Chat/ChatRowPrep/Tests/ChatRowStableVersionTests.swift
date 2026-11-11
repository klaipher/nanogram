import XCTest
@testable import ChatRowPrep

final class ChatRowStableVersionTests: XCTestCase {
    private typealias Inputs = ChatRowStableVersionInputs<Int, String>
    private let presentationA = NSObject()
    private let presentationB = NSObject()

    private func inputs(entry: Int = 1, presentation: NSObject? = nil, associated: String = "a", epoch: UInt64 = 5) -> Inputs {
        return Inputs(entry: entry, presentationData: ObjectIdentifier(presentation ?? self.presentationA), associatedData: associated, rowPrepEpoch: epoch)
    }

    func testIdenticalInputsKeepTheVersion() {
        XCTAssertTrue(shouldKeepStableVersion(old: self.inputs(), new: self.inputs()))
    }

    func testNoPreviousValueGetsANewVersion() {
        XCTAssertFalse(shouldKeepStableVersion(old: nil, new: self.inputs()))
    }

    func testAChangedEntryGetsANewVersion() {
        XCTAssertFalse(shouldKeepStableVersion(old: self.inputs(entry: 1), new: self.inputs(entry: 2)))
    }

    func testADifferentPresentationDataObjectGetsANewVersion() {
        XCTAssertFalse(shouldKeepStableVersion(old: self.inputs(), new: self.inputs(presentation: self.presentationB)))
    }

    func testChangedAssociatedDataGetsANewVersion() {
        XCTAssertFalse(shouldKeepStableVersion(old: self.inputs(associated: "a"), new: self.inputs(associated: "b")))
    }

    func testAMovedRowPrepEpochGetsANewVersion() {
        XCTAssertFalse(shouldKeepStableVersion(old: self.inputs(epoch: 5), new: self.inputs(epoch: 6)))
    }
}
