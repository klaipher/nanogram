import XCTest
import UIKit
@testable import GlassBackgroundComponent

final class GlassStackHostGeometryTests: XCTestCase {
    func testHostCoversTheContentWithTheMargin() {
        let geometry = GlassStackHostGeometry(contentFrame: CGRect(x: 0.0, y: -160.0, width: 40.0, height: 408.0), margin: 24.0)
        XCTAssertEqual(geometry.hostFrame, CGRect(x: -24.0, y: -184.0, width: 88.0, height: 456.0))
    }

    /// The point of the geometry: a point in the owner's coordinates and the same point seen through the host (the stack
    /// view sits at `stackOrigin` in it, the host at `hostFrame.origin` in the owner) coincide.
    func testOwnerPointsAreUnchangedThroughTheHost() {
        let geometry = GlassStackHostGeometry(contentFrame: CGRect(x: 0.0, y: -160.0, width: 40.0, height: 408.0), margin: 24.0)
        for point in [CGPoint(x: 0.0, y: 0.0), CGPoint(x: 20.0, y: -160.0), CGPoint(x: 40.0, y: 248.0), CGPoint(x: -3.5, y: 7.25)] {
            let inHost = geometry.hostPoint(forOwnerPoint: point)
            let back = CGPoint(x: inHost.x + geometry.hostFrame.minX, y: inHost.y + geometry.hostFrame.minY)
            XCTAssertEqual(back.x, point.x, accuracy: 0.0001)
            XCTAssertEqual(back.y, point.y, accuracy: 0.0001)
        }
    }

    func testEveryContentPointIsInsideTheHost() {
        let content = CGRect(x: 0.0, y: -160.0, width: 40.0, height: 408.0)
        let geometry = GlassStackHostGeometry(contentFrame: content, margin: 24.0)
        let hostBounds = CGRect(origin: .zero, size: geometry.hostFrame.size)
        for corner in [CGPoint(x: content.minX, y: content.minY), CGPoint(x: content.maxX, y: content.maxY)] {
            XCTAssertTrue(hostBounds.contains(geometry.hostPoint(forOwnerPoint: corner)))
        }
    }

    func testNegativeMarginIsTreatedAsZero() {
        let content = CGRect(x: 0.0, y: 0.0, width: 40.0, height: 40.0)
        XCTAssertEqual(GlassStackHostGeometry(contentFrame: content, margin: -10.0).hostFrame, content)
    }
}
