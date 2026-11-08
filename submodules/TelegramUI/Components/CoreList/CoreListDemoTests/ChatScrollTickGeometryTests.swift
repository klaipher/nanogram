import XCTest
import UIKit
@testable import CoreListDemo

/// The per-frame host reads added for the chat scroll tick: `withPresentedFrames` (the viewport delta computed once per
/// pass) and `loadedIndex(ofItemView:)` (O(1) inverse of `loadedItemView(at:)`). Both must answer exactly what the
/// per-call APIs answer.
final class ChatScrollTickGeometryTests: XCTestCase {
    private func midFlightFixture() -> PhysicsListFixture {
        let items: [CoreListItem] = (0..<200).map { _ in IdentifiableFixedHeightItem(id: UUID(), height: 50) }
        let f = PhysicsListFixture(items: items, decelerationMode: .keyframe, clock: SyntheticClock())
        f.listView.applyChanges(scrollTo: .init(index: 60, pointOffset: 0), transition: .easeInOut(duration: 0))
        f.simulateFlick(offsetVelocity: 9000)
        for _ in 0..<6 { f.tick(dt: 1.0 / 120) }
        return f
    }

    func test_withPresentedFrames_matchesPresentedFrameForEveryLoadedRow_midFlight() {
        let f = midFlightFixture()
        let views = f.activeWindow.items.map { $0.view }
        XCTAssertFalse(views.isEmpty)
        let expected = views.map { f.listView.presentedFrame(of: $0) }
        let actual = f.listView.withPresentedFrames { read in views.map { read($0) } }
        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.minY, e.minY, accuracy: 0.001)
            XCTAssertEqual(a.minX, e.minX, accuracy: 0.001)
            XCTAssertEqual(a.size, e.size)
        }
        // And the flight really moved the rows away from the model position, so the test is not vacuous.
        let converted = f.listView.convert(views[0].bounds, from: views[0])
        XCTAssertGreaterThan(abs(converted.minY - actual[0].minY), 100)
    }

    func test_withPresentedFrames_computesTheViewportDeltaOncePerPass() {
        let f = midFlightFixture()
        let views = f.activeWindow.items.map { $0.view }
        XCTAssertGreaterThan(views.count, 3)

        let before = f.listView.modelToPresentedViewportDeltaReadCount
        _ = f.listView.withPresentedFrames { read in views.map { read($0) } }
        XCTAssertEqual(f.listView.modelToPresentedViewportDeltaReadCount - before, 1)

        let beforePerCall = f.listView.modelToPresentedViewportDeltaReadCount
        _ = views.map { f.listView.presentedFrame(of: $0) }
        XCTAssertEqual(f.listView.modelToPresentedViewportDeltaReadCount - beforePerCall, views.count,
                       "the per-call API still reads it per row (unchanged)")
    }

    func test_loadedIndexOfItemView_matchesTheWindow() {
        let f = PhysicsListFixture(itemCount: 50)
        let items = f.activeWindow.items
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertEqual(f.listView.loadedIndex(ofItemView: item.view), item.index)
        }
        XCTAssertNil(f.listView.loadedIndex(ofItemView: UIView()))
    }

    func test_loadedIndexOfItemView_isBuiltOncePerWindowRevision() {
        let f = PhysicsListFixture(itemCount: 50)
        let items = f.activeWindow.items
        let before = f.listView.loadedIndexByViewRebuildCount
        for _ in 0..<5 {
            for item in items { _ = f.listView.loadedIndex(ofItemView: item.view) }
        }
        XCTAssertEqual(f.listView.loadedIndexByViewRebuildCount - before, 1)
    }

    func test_loadedIndexOfItemView_followsTheWindowAfterScrolling() {
        let f = PhysicsListFixture(itemCount: 200)
        let firstLoaded = f.activeWindow.items.map { $0.view }
        _ = f.listView.loadedIndex(ofItemView: firstLoaded[0])

        f.simulateFlick(offsetVelocity: 4_000)
        _ = f.runUntilSettled(max: 5.0)

        for item in f.activeWindow.items {
            XCTAssertEqual(f.listView.loadedIndex(ofItemView: item.view), item.index)
        }
        // Views that left the window no longer resolve.
        let stillLoaded = Set(f.activeWindow.items.map { ObjectIdentifier($0.view) })
        for view in firstLoaded where !stillLoaded.contains(ObjectIdentifier(view)) {
            XCTAssertNil(f.listView.loadedIndex(ofItemView: view))
        }
    }
}
