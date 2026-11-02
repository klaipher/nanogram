import XCTest
import UIKit
@testable import Display

/// `keyboardGestureStart` runs on every touch-down. The first-responder lookup it is given walks the whole window
/// view tree (up to 6 ms per touch on device), and its result only matters while the keyboard is up.
final class KeyboardGestureStartTests: XCTestCase {
    private let windowSize = CGSize(width: 400.0, height: 800.0)

    // The decision as panGestureBegan made it before the guard: lookup first, then the inputHeight check.
    private func reference(location: CGPoint, inputHeight: CGFloat?, lookup: (UIView?, CGFloat?)) -> (UIView?, CGFloat?)? {
        let (firstResponder, accessoryHeight) = lookup
        if let inputHeight, !inputHeight.isZero, location.y < self.windowSize.height - inputHeight - (accessoryHeight ?? 0.0) {
            return (firstResponder, accessoryHeight)
        }
        return nil
    }

    func testNoKeyboardSkipsTheTreeWalk() {
        for inputHeight in [nil, CGFloat(0.0)] {
            var walks = 0
            let result = keyboardGestureStart(location: CGPoint(x: 10.0, y: 10.0), windowSize: self.windowSize, inputHeight: inputHeight, findFirstResponder: {
                walks += 1
                return (UIView(), 44.0)
            })
            XCTAssertNil(result)
            XCTAssertEqual(walks, 0, "inputHeight \(String(describing: inputHeight))")
        }
    }

    func testSameDecisionAsBeforeWhileTheKeyboardIsUp() {
        let responder = UIView()
        let lookups: [(UIView?, CGFloat?)] = [(nil, nil), (responder, nil), (responder, 44.0), (nil, 100.0)]
        for inputHeight in [nil, CGFloat(0.0), 300.0, 500.0] {
            for y in stride(from: CGFloat(0.0), through: 800.0, by: 50.0) {
                for lookup in lookups {
                    let location = CGPoint(x: 20.0, y: y)
                    let expected = self.reference(location: location, inputHeight: inputHeight, lookup: lookup)
                    let actual = keyboardGestureStart(location: location, windowSize: self.windowSize, inputHeight: inputHeight, findFirstResponder: { lookup })
                    XCTAssertEqual(actual == nil, expected == nil, "y \(y) inputHeight \(String(describing: inputHeight))")
                    XCTAssertTrue(actual?.firstResponder === expected?.0)
                    XCTAssertEqual(actual?.accessoryHeight, expected?.1)
                }
            }
        }
    }

    // Benchmark: the walk over a tree the size of a chat screen stack versus the guarded call with no keyboard.
    func testBenchmarkTouchDownWithoutKeyboard() {
        let root = UIView()
        func grow(_ view: UIView, depth: Int) {
            guard depth > 0 else { return }
            for _ in 0 ..< 4 {
                let child = UIView()
                view.addSubview(child)
                grow(child, depth: depth - 1)
            }
        }
        grow(root, depth: 6) // 5,460 views
        let iterations = 200
        func time(_ body: () -> Void) -> Double {
            var best = Double.infinity
            for _ in 0 ..< 5 {
                let start = CACurrentMediaTime()
                for _ in 0 ..< iterations { body() }
                best = min(best, (CACurrentMediaTime() - start) / Double(iterations))
            }
            return best * 1_000_000.0
        }
        let walk = time { _ = getFirstResponderAndAccessoryHeight(root) }
        let guarded = time { _ = keyboardGestureStart(location: .zero, windowSize: self.windowSize, inputHeight: nil, findFirstResponder: { getFirstResponderAndAccessoryHeight(root) }) }
        print("BENCH touch-down without keyboard, 5460 views: walk \(String(format: "%.1f", walk)) us, guarded \(String(format: "%.3f", guarded)) us")
        XCTAssertLessThan(guarded, walk / 100.0)
    }
}
