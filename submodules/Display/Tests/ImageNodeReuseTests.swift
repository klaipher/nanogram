import XCTest
import UIKit
import AsyncDisplayKit
import SwiftSignalKit
@testable import Display

final class ImageNodeReuseTests: XCTestCase {
    private func makeImage(_ color: UIColor) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 4.0, height: 4.0), true, 1.0)
        color.setFill()
        UIRectFill(CGRect(x: 0.0, y: 0.0, width: 4.0, height: 4.0))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
    
    func testLedgerMatchesStoredProperties() {
        let node = ImageNode(enableHasImage: true, enableAnimatedTransition: true)
        let names = Set(Mirror(reflecting: node).children.compactMap { $0.label })
        XCTAssertEqual(names, Set(ImageNode.reuseLedger.keys), "ImageNode changed its stored properties; decide for each in reuseLedger and prepareForReuse")
    }
    
    func testPrepareClearsContents() {
        let node = ImageNode(enableHasImage: true, enableAnimatedTransition: true)
        node.setSignal(Signal<UIImage?, NoError>.single(self.makeImage(.red)))
        let expectation = self.expectation(description: "image delivered")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        self.wait(for: [expectation], timeout: 2.0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertNotNil(node.contents)
        node.prepareForReuse()
        XCTAssertNil(node.contents)
    }
    
    func testNoCrossFadeAfterReuse() {
        let node = ImageNode(enableHasImage: true, enableAnimatedTransition: true)
        node.frame = CGRect(x: 0.0, y: 0.0, width: 40.0, height: 40.0)
        _ = node.view
        node.setSignal(Signal<UIImage?, NoError>.single(self.makeImage(.red)))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertNotNil(node.contents)
        
        node.prepareForReuse()
        
        let expectation = self.expectation(description: "second image delivered")
        let second = self.makeImage(.blue)
        let signal: Signal<UIImage?, NoError> = Signal<UIImage?, NoError>.single(second) |> delay(0.01, queue: Queue.mainQueue())
        node.setSignal(signal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        self.wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(node.contents)
        XCTAssertTrue(node.layer.sublayers?.isEmpty ?? true)
    }
}
