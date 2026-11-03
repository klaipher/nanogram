import XCTest
@testable import TelegramMediaPlayer

final class GifTileHardwareDecodeTests: XCTestCase {
    func testSmallClipsStayInSoftware() {
        XCTAssertFalse(GifTileHardwareDecoding.wantsHardware(width: 240, height: 240))
        XCTAssertFalse(GifTileHardwareDecoding.wantsHardware(width: 256, height: 144))
        XCTAssertNil(GifTileHardwareDecoding.acquireSlot(width: 240, height: 240, budget: HardwareDecoderBudget(limit: 16)))
    }

    func testClipsFrom320PixelsAskForHardware() {
        for (width, height) in [(480, 270), (320, 180), (270, 480), (320, 320)] {
            XCTAssertTrue(GifTileHardwareDecoding.wantsHardware(width: width, height: height), "\(width)x\(height)")
        }
    }

    func testBudgetCapsLiveHardwareReaders() {
        let budget = HardwareDecoderBudget(limit: 16)
        var slots: [HardwareDecoderSlot] = []
        for _ in 0 ..< 20 {
            if let slot = GifTileHardwareDecoding.acquireSlot(width: 480, height: 360, budget: budget) {
                slots.append(slot)
            }
        }
        XCTAssertEqual(slots.count, 16)
        XCTAssertEqual(budget.activeCount, 16)
        XCTAssertNil(GifTileHardwareDecoding.acquireSlot(width: 480, height: 360, budget: budget))
        slots.removeFirst(4)
        XCTAssertEqual(budget.activeCount, 12)
        XCTAssertNotNil(GifTileHardwareDecoding.acquireSlot(width: 480, height: 360, budget: budget))
        XCTAssertEqual(budget.activeCount, 12)
        slots.removeAll()
        XCTAssertEqual(budget.activeCount, 0)
    }

    func testSharedBudgetIsSixteen() {
        let before = GifTileHardwareDecoding.budget.activeCount
        var slots: [HardwareDecoderSlot] = []
        while let slot = GifTileHardwareDecoding.acquireSlot(width: 640, height: 360) {
            slots.append(slot)
            if slots.count > 32 {
                break
            }
        }
        XCTAssertEqual(slots.count + before, 16)
    }
}
