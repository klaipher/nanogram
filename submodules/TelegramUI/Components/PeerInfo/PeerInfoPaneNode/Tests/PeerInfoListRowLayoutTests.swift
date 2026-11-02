import XCTest
import UIKit
import PeerInfoPaneNode

/// Profile list rows (Files/Music/Voice/Links) are asked to update on every scroll tick with the size and insets they
/// already have. Laying the fixed message item out again for them produced the same layout and cost up to 12 ms per tick.
final class PeerInfoListRowLayoutTests: XCTestCase {
    private let size = CGSize(width: 390.0, height: 56.0)
    private let insets = UIEdgeInsets(top: 0.0, left: 16.0, bottom: 0.0, right: 0.0)

    func testUnboundRowNeedsLayout() {
        XCTAssertTrue(PeerInfoListRowLayout().needsLayout(size: self.size, insets: self.insets))
    }

    func testScrollTicksWithUnchangedGeometryDoNotRelayout() {
        var layout = PeerInfoListRowLayout()
        layout.didLayout(size: self.size, insets: self.insets)
        // Benchmark proxy: a 300-tick scroll gesture used to run 300 full row layouts per visible row.
        var layouts = 0
        for _ in 0 ..< 300 {
            if layout.needsLayout(size: self.size, insets: self.insets) {
                layouts += 1
                layout.didLayout(size: self.size, insets: self.insets)
            }
        }
        print("BENCH profile list row: \(layouts) layouts per 300 unchanged scroll ticks (was 300)")
        XCTAssertEqual(layouts, 0)
    }

    func testChangedGeometryRelayouts() {
        var layout = PeerInfoListRowLayout()
        layout.didLayout(size: self.size, insets: self.insets)
        XCTAssertTrue(layout.needsLayout(size: CGSize(width: 391.0, height: 56.0), insets: self.insets))
        XCTAssertTrue(layout.needsLayout(size: CGSize(width: 390.0, height: 57.0), insets: self.insets))
        XCTAssertTrue(layout.needsLayout(size: self.size, insets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)))
        XCTAssertTrue(layout.needsLayout(size: self.size, insets: UIEdgeInsets(top: 0.0, left: 16.0, bottom: 0.0, right: 59.0)))
        layout.didLayout(size: CGSize(width: 391.0, height: 56.0), insets: self.insets)
        XCTAssertFalse(layout.needsLayout(size: CGSize(width: 391.0, height: 56.0), insets: self.insets))
        XCTAssertTrue(layout.needsLayout(size: self.size, insets: self.insets))
    }
}
