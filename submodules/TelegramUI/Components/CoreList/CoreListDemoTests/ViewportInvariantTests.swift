import XCTest
import UIKit
@testable import CoreListDemo

final class ViewportInvariantTests: XCTestCase {
    private func snapshot(_ configure: (inout CoreListViewportSnapshot) -> Void = { _ in }) -> CoreListViewportSnapshot {
        var s = CoreListViewportSnapshot(
            itemCount: 50, windowIsEmpty: false, windowStartIndex: 0, windowEndIndex: 20,
            visibleHeight: 600, windowHeight: 2000, newestEdgeGap: 0, oldestEdgeGap: 0, offset: -100,
            declaredMinEdge: -100, declaredMaxEdge: 4000,
            bottomEdgePinSlack: 0, holdSlackMin: 0, holdSlackMax: 0, stackFromBottomSlack: 0,
            hasHeldRow: false, lowestPinnedItemIndex: nil,
            anyRowIntersectsBand: true, hiddenRowsInBand: 0,
            hasActiveFlight: false, isTrackingTouch: false, rebalanceDeferredRows: false, windowRevision: 1
        )
        configure(&s)
        return s
    }

    func testHealthyListHasNoFindings() {
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot()), [])
    }

    func testNothingIsReportedWhileMovingOrEmpty() {
        let gap = { (s: inout CoreListViewportSnapshot) in s.newestEdgeGap = 400 }
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { gap(&$0); $0.hasActiveFlight = true }), [])
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { gap(&$0); $0.isTrackingTouch = true }), [])
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { gap(&$0); $0.itemCount = 0 }), [])
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { gap(&$0); $0.windowIsEmpty = true }), [])
    }

    func testNoRowInBandIsReported() {
        let findings = CoreListViewportInvariant.evaluate(snapshot { $0.anyRowIntersectsBand = false })
        XCTAssertEqual(findings, [.noRowInBand])
    }

    /// The point of the design: a gap that exactly equals the declared pin slack is the leading hypothesis, so it is reported,
    /// with the pin named as its backing.
    func testGapBackedByPinSlackIsReportedWithItsBacking() {
        let findings = CoreListViewportInvariant.evaluate(snapshot {
            $0.newestEdgeGap = 420
            $0.bottomEdgePinSlack = 420
            $0.lowestPinnedItemIndex = 0
        })
        XCTAssertEqual(findings, [.newestEdgeGap(gap: 420, backing: .pinSlack)])
    }

    func testGapBackedByHoldSlack() {
        let findings = CoreListViewportInvariant.evaluate(snapshot {
            $0.newestEdgeGap = 300
            $0.holdSlackMin = 300
            $0.hasHeldRow = true
        })
        XCTAssertEqual(findings, [.newestEdgeGap(gap: 300, backing: .holdSlack)])
    }

    func testGapBackedByStackSlack() {
        let findings = CoreListViewportInvariant.evaluate(snapshot {
            $0.newestEdgeGap = 300
            $0.stackFromBottomSlack = 300
        })
        XCTAssertEqual(findings, [.newestEdgeGap(gap: 300, backing: .stackSlack)])
    }

    func testGapWithoutAnyDeclaredTermHasNoBacking() {
        let findings = CoreListViewportInvariant.evaluate(snapshot { $0.newestEdgeGap = 300 })
        XCTAssertEqual(findings, [.newestEdgeGap(gap: 300, backing: .none)])
    }

    func testLargestTermWinsTheBacking() {
        let s = snapshot {
            $0.newestEdgeGap = 500
            $0.bottomEdgePinSlack = 100
            $0.holdSlackMin = 400
        }
        XCTAssertEqual(CoreListViewportInvariant.newestBacking(s), .holdSlack)
    }

    func testSmallGapIsOrdinary() {
        // 25% of 600 is 150.
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.newestEdgeGap = 149 }), [])
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.newestEdgeGap = 151 }).count, 1)
    }

    /// Short of index 0 a gap is not edge room: newer rows exist and are not loaded where they would be seen.
    func testNewestGapShortOfIndexZeroIsAnUnloadedGap() {
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.windowStartIndex = 5; $0.newestEdgeGap = 500 }),
                       [.unloadedGap(edge: .newest, gap: 500)])
    }

    /// The screenshot case: one bubble at the far end of the band, the rest blank, the window not reaching index 0.
    func testOneRowInBandWithBlankBelowIsReported() {
        let findings = CoreListViewportInvariant.evaluate(snapshot {
            $0.windowStartIndex = 12
            $0.newestEdgeGap = 540
            $0.anyRowIntersectsBand = true
        })
        XCTAssertEqual(findings, [.unloadedGap(edge: .newest, gap: 540)])
    }

    func testOldestGapShortOfTheLastItemIsAnUnloadedGap() {
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.oldestEdgeGap = 500 }),
                       [.unloadedGap(edge: .oldest, gap: 500)])
    }

    /// A chat with a few messages leaves blank above them by its own geometry.
    func testShortFullyLoadedCollectionHasNoOldestGapFinding() {
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot {
            $0.itemCount = 3
            $0.windowEndIndex = 2
            $0.windowHeight = 200
            $0.oldestEdgeGap = 400
        }), [])
    }

    func testSignatureIgnoresMagnitudes() {
        let a = CoreListViewportInvariant.signature([.newestEdgeGap(gap: 300, backing: .pinSlack), .hiddenRowInBand(count: 1)])
        let b = CoreListViewportInvariant.signature([.newestEdgeGap(gap: 420, backing: .pinSlack), .hiddenRowInBand(count: 3)])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, CoreListViewportInvariant.signature([.newestEdgeGap(gap: 300, backing: .holdSlack)]))
    }

    func testOldestGapWhenWindowReachesTheLastItem() {
        let findings = CoreListViewportInvariant.evaluate(snapshot {
            $0.windowStartIndex = 10
            $0.windowEndIndex = 49
            $0.oldestEdgeGap = 500
            $0.holdSlackMax = 500
        })
        XCTAssertEqual(findings, [.oldestEdgeGap(gap: 500, backing: .holdSlack)])
    }

    func testOffsetOutsideDeclaredEdges() {
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.offset = -100.4 }), [])
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.offset = -180 }), [.offsetOutsideDeclaredEdges(by: 80)])
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.offset = 4050 }), [.offsetOutsideDeclaredEdges(by: 50)])
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.declaredMinEdge = nil; $0.offset = -9000 }), [])
    }

    func testHiddenRowInBand() {
        XCTAssertEqual(CoreListViewportInvariant.evaluate(snapshot { $0.hiddenRowsInBand = 2 }), [.hiddenRowInBand(count: 2)])
    }

    func testFormattedLineHasNumbersOnly() {
        let s = snapshot { $0.newestEdgeGap = 420; $0.bottomEdgePinSlack = 420; $0.lowestPinnedItemIndex = 0 }
        let line = CoreListViewportInvariant.format(s, findings: CoreListViewportInvariant.evaluate(s), trigger: "tx-end")
        XCTAssertTrue(line.contains("trigger=tx-end"))
        XCTAssertTrue(line.contains("newestGap=420.0 backing=pinSlack"))
        XCTAssertTrue(line.contains("pinIndex=0"))
    }

    func testRateLimiterAllowsOnePerIntervalPerKey() {
        var limiter = CoreListDiagnosticRateLimiter(interval: 1.0)
        XCTAssertTrue(limiter.allow(key: "a", now: 10.0))
        XCTAssertFalse(limiter.allow(key: "a", now: 10.5))
        XCTAssertTrue(limiter.allow(key: "b", now: 10.5))
        XCTAssertTrue(limiter.allow(key: "a", now: 11.0))
        XCTAssertFalse(limiter.allow(key: "a", now: 11.9))
        // A clock that went backwards must not silence the log for good.
        XCTAssertTrue(limiter.allow(key: "a", now: 5.0))
    }

    func testRingKeepsTheLastEventsOldestFirst() {
        var ring = CoreListEventRing(capacity: 3)
        for i in 0..<5 {
            ring.record(.transaction, time: Double(i), a: CGFloat(i))
        }
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.events.map { $0.a }, [2, 3, 4])
    }

    func testRingBelowCapacityIsInOrder() {
        var ring = CoreListEventRing(capacity: 4)
        ring.record(.scrollTo, time: 1)
        ring.record(.deltaClamp, time: 2)
        XCTAssertEqual(ring.events.map { $0.kind }, [.scrollTo, .deltaClamp])
        XCTAssertTrue(ring.formatted(now: 3).contains("scrollTo@-2.00s"))
    }
}

final class RestSpringBackTests: XCTestCase {
    func testSpringsBackOnlyWhenRestingOverscrolled() {
        XCTAssertTrue(CoreListRestSpringBack.isNeeded(isFlying: false, isDecelerating: false, isTrackingTouch: false, isOverscrolled: true))
        XCTAssertFalse(CoreListRestSpringBack.isNeeded(isFlying: false, isDecelerating: false, isTrackingTouch: false, isOverscrolled: false))
        XCTAssertFalse(CoreListRestSpringBack.isNeeded(isFlying: true, isDecelerating: false, isTrackingTouch: false, isOverscrolled: true))
        XCTAssertFalse(CoreListRestSpringBack.isNeeded(isFlying: false, isDecelerating: true, isTrackingTouch: false, isOverscrolled: true))
        XCTAssertFalse(CoreListRestSpringBack.isNeeded(isFlying: false, isDecelerating: false, isTrackingTouch: true, isOverscrolled: true))
    }

    func testAtMostOncePerInterval() {
        var limiter = CoreListRestSpringBack()
        XCTAssertTrue(limiter.allow(now: 10.0))
        XCTAssertFalse(limiter.allow(now: 10.5))
        XCTAssertTrue(limiter.allow(now: 10.0 + CoreListRestSpringBack.minimumInterval))
    }
}
